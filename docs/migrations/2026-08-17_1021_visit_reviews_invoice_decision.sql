-- ============================================================================
-- 2026-08-17_1021 — persist the reviewer's "Ready for Invoice" decision
-- ============================================================================
-- Fred, 2026-08-16, on the Admin Review queue chip: *"it's the reviewer decision,
-- point it at that field"*.
--
-- 🛑 THERE WAS NO FIELD. That is the whole reason this migration exists, and it is
-- worse than a missing column: the DECISION HAS BEEN SILENTLY DISCARDED ALL ALONG.
-- Measured in the live bundle before writing this:
--   * the visit review page renders "Ready for Invoice" with "Yes, Ready" / "Not Yet"
--     buttons that set an `invoiceDecision` value of 'ready' / 'not_ready',
--   * the Save handler upserts to public.visit_reviews with exactly
--       review_status, quality_flag_note, bonus_status, bonus_denial_note,
--       bonus_decided_at, reviewed_at
--     and NO invoice field,
--   * public.visit_reviews had no invoice column, and a search of the whole `public`
--     schema for %invoice% returned only the Jobber invoice (invoices.*, jobs.*,
--     line_items.invoice_id, visits.invoice_id) — none of which is a review judgement.
-- ⇒ Every "Yes, Ready" anyone has ever clicked lived in React state and died on unmount.
-- The queue chip was hard-coded to "Invoice pending" for the same reason: there was
-- nothing to read.
--
-- 🛑 THIS IS NOT visits.invoice_id, AND CONFLATING THEM IS THE TRAP.
--   visits.invoice_id            = a Jobber invoice EXISTS (a billing fact)
--   visit_reviews.invoice_status = a reviewer SAYS it is ready to invoice (a judgement)
-- A visit can be reviewed-ready and not yet invoiced, or invoiced without review. I
-- shipped the queue chip against invoice_id first and it was the wrong question: it
-- read "Invoiced" on visits nobody had reviewed. Fred's ruling settles it as the
-- judgement. Do not "simplify" this column away later by pointing at invoice_id.
--
-- VOCABULARY mirrors the sibling columns rather than inventing one: bonus_status is
-- pending/approved/denied and review_status is pending/approved/flagged, both plain
-- text with a CHECK. So invoice_status is text + CHECK, and the values are the ones
-- the existing UI already emits ('ready' / 'not_ready') plus 'pending' as the default,
-- so no app-side translation layer is needed.
--
-- AUDIT-TRAIL STANDING CHECK (rule 8): public.visit_reviews ALREADY carries the
-- audit.log_change trigger (verified: 1 trigger). Adding a column to an audited table
-- is captured automatically in the full-row JSONB, so no trigger work is required and
-- none is done. Recorded here rather than silently skipped.
--
-- 3NF: invoice_status depends on the whole key (visit_id) and on nothing else.
-- invoice_decided_at / invoice_decided_by are decision METADATA, not derivable from
-- the status, exactly as bonus_decided_at / bonus_decided_by already are.
-- ============================================================================

do $do$
begin
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='visit_reviews'
                and column_name='invoice_status') then
    raise exception 'public.visit_reviews.invoice_status already exists';
  end if;
end
$do$;

alter table public.visit_reviews
  add column invoice_status     text        not null default 'pending',
  add column invoice_decided_at timestamptz,
  add column invoice_decided_by uuid;

alter table public.visit_reviews
  add constraint visit_reviews_invoice_status_check
  check (invoice_status = any (array['pending'::text, 'ready'::text, 'not_ready'::text]));

comment on column public.visit_reviews.invoice_status is
  'Reviewer judgement: is this visit ready to invoice. pending | ready | not_ready. NOT visits.invoice_id, which is whether a Jobber invoice exists.';

-- The queue reads the review through this view, so the column has to surface there.
--
-- 🛑 THIS BODY IS COPIED FROM pg_get_viewdef, NOT RETYPED. My first draft retyped it and
-- silently changed three things, any one of which would have been a real regression:
--   * it read `FROM v_visits_live` instead of `FROM visits`
--   * it used `v.*` instead of the explicit column list, changing the column set/order
--   * it dropped the COALESCE(...,'pending') defaults on review_status and bonus_status,
--     which is what makes an unreviewed visit read 'pending' rather than NULL
-- Same trap as 2026-08-06_1316 in CLAUDE.md: CREATE OR REPLACE takes the WHOLE body, so
-- everything you fail to reproduce is deleted. Only the last three lines are new.
--
-- ⚠ AND NOTE WHAT IS *NOT* CHANGED HERE: this view reads `visits`, NOT `v_visits_live`,
-- so it does not filter `deleted_at`. That is a pre-existing gap already listed as a
-- pending follow-up in CLAUDE.md ("Soft-delete on visits"). It is NOT fixed in this
-- migration on purpose: repointing the view is a separate behaviour change that would
-- alter which rows the whole Admin Review queue sees, and bundling it into a column
-- addition would hide it. Flagged, not smuggled.
create or replace view public.visits_with_review as
 SELECT v.id,
    v.client_id,
    v.property_id,
    v.job_id,
    v.vehicle_id,
    v.visit_date,
    v.start_at,
    v.end_at,
    v.completed_at,
    v.duration_minutes,
    v.title,
    v.service_type,
    v.visit_status,
    v.actual_arrival_at,
    v.actual_departure_at,
    v.is_gps_confirmed,
    v.created_at,
    v.updated_at,
    v.invoice_id,
    v.completed_by,
    COALESCE(vr.review_status, 'pending'::text) AS review_status,
    vr.reviewed_at,
    vr.reviewed_by,
    COALESCE(vr.bonus_status, 'pending'::text) AS bonus_status,
    vr.bonus_decided_at,
    vr.bonus_decided_by,
    vr.bonus_denial_note,
    vr.quality_flag_note,
    v.public_id,
    COALESCE(vr.invoice_status, 'pending'::text) AS invoice_status,
    vr.invoice_decided_at,
    vr.invoice_decided_by
   FROM visits v
     LEFT JOIN visit_reviews vr ON vr.visit_id = v.id;

-- ============================================================================
-- VERIFY
-- ============================================================================
do $do$
declare v_cols int; v_default text; v_bad boolean; v_view int; v_audit int;
begin
  select count(*) into v_cols from information_schema.columns
   where table_schema='public' and table_name='visit_reviews'
     and column_name in ('invoice_status','invoice_decided_at','invoice_decided_by');
  if v_cols <> 3 then raise exception 'expected 3 new columns, found %', v_cols; end if;

  -- existing rows must default to pending, never to a decision nobody made
  select column_default into v_default from information_schema.columns
   where table_schema='public' and table_name='visit_reviews' and column_name='invoice_status';
  if v_default not like '%pending%' then raise exception 'default is % , expected pending', v_default; end if;

  -- the CHECK must actually bite, or the vocabulary is decoration
  begin
    insert into public.visit_reviews (visit_id, invoice_status)
    values ((select id from public.v_visits_live order by id limit 1), 'nonsense_value');
    v_bad := false;
  exception when others then v_bad := true;
  end;
  if not v_bad then raise exception 'the invoice_status CHECK does not bite'; end if;

  -- the view must expose all three, or the app cannot read the decision
  select count(*) into v_view from information_schema.columns
   where table_schema='public' and table_name='visits_with_review'
     and column_name in ('invoice_status','invoice_decided_at','invoice_decided_by');
  if v_view <> 3 then raise exception 'view exposes % of 3 new columns', v_view; end if;

  -- rule 8: the pre-existing audit trigger must have survived
  select count(*) into v_audit from pg_trigger t
    join pg_proc p on p.oid=t.tgfoid join pg_namespace pn on pn.oid=p.pronamespace
   where t.tgrelid='public.visit_reviews'::regclass and pn.nspname='audit'
     and p.proname='log_change' and not t.tgisinternal;
  if v_audit <> 1 then raise exception 'audit trigger count is %, expected 1', v_audit; end if;

  raise notice 'invoice_status added, CHECK bites, view exposes 3, audit intact';
end
$do$;

-- every existing review row must read 'pending': nobody has made this decision yet,
-- because until now there was nowhere to record one.
do $do$
declare n int; p int;
begin
  select count(*), count(*) filter (where invoice_status='pending') into n, p from public.visit_reviews;
  if n <> p then raise exception '% of % existing rows are not pending', n-p, n; end if;
  raise notice 'all % existing review rows default to pending', n;
end
$do$;
