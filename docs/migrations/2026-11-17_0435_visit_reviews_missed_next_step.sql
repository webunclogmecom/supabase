-- 2026-11-17_0435_visit_reviews_missed_next_step.sql
-- Trello #208 LlqVVAVP (Ops Portal, Reviews): a missed visit's "What should happen next?" (Skip, Reschedule, Invoice
-- (Customer Fault), Send Note (No Charge)) was kept nowhere: the saved review had the reason in its flag note but not
-- the next step, so a reopened review could not show it again.
-- Fred, 2026-11-17: "Keep it on the review" (show it again when the review reopens; nothing acts on it automatically).
--
-- What changes:
--   1. public.visit_reviews.missed_next_step text, NULL or one of the four values the app offers
--      (skip, reschedule, invoice_customer_fault, send_note_no_charge), CHECK-pinned.
--   2. public.visits_with_review gains vr.missed_next_step as its LAST column (the app reads reviews through it).
--      Every other column is the live body byte for byte (pg_get_viewdef, md5-guarded below).
-- Audit (rule 8): public.visit_reviews is already audited (audit_visit_reviews, full-row JSONB), so the new column is
-- captured with no action. Grants: authenticated already holds table-level INSERT/UPDATE/SELECT on visit_reviews
-- (no column grants), so the new column is writable by the same people as every other review column, and the
-- table's access trigger (aa_access_admin_review) still checks Admin Review Edit on every write.
-- Nothing acts on the value: it is a record for the office. 0 missed-visit reviews existed when this was written.
-- Rollback: 2026-11-17_0435_visit_reviews_missed_next_step_rollback.sql.

begin;
set local lock_timeout = '3s';

do $guard$
begin
  if md5(pg_get_viewdef('public.visits_with_review'::regclass, true)) <> '5c92d7fc5eb2d12cf7017c02fec62c8a' then
    raise exception 'public.visits_with_review changed since this migration was written; rebuild it from the live body';
  end if;
end $guard$;

alter table public.visit_reviews
  add column missed_next_step text
  constraint visit_reviews_missed_next_step_chk
  check (missed_next_step in ('skip', 'reschedule', 'invoice_customer_fault', 'send_note_no_charge'));

comment on column public.visit_reviews.missed_next_step is
  'Missed visit: what the reviewer chose should happen next (Trello #208). A record only; nothing acts on it.';

CREATE OR REPLACE VIEW public.visits_with_review AS
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
    vr.invoice_decided_by,
    v.derm_required,
    COALESCE((j.title ~~* 'Service Agreement%'::text OR j.title ~~* 'Service Call%'::text) AND j.title !~~* '%[OLD]%'::text, false) AS job_is_sa_sc,
    COALESCE(j.job_status <> ALL (ARRAY['archived'::text, 'closed'::text, 'destroyed'::text]), false) OR w.started OR inc.visit_id IS NOT NULL AND inc.removed_at IS NULL AS in_review_scope,
        CASE
            WHEN COALESCE(j.job_status <> ALL (ARRAY['archived'::text, 'closed'::text, 'destroyed'::text]), false) THEN 'open_job'::text
            WHEN inc.visit_id IS NOT NULL AND inc.removed_at IS NULL THEN 'manual'::text
            WHEN w.started THEN 'work_started'::text
            ELSE NULL::text
        END AS scope_source,
    w.started AS review_work_started,
    j.title AS job_title,
    COALESCE(j.job_status <> ALL (ARRAY['archived'::text, 'closed'::text, 'destroyed'::text]), false) AS job_is_open,
        CASE
            WHEN j.title ~~* '%[OLD]%'::text THEN 'other'::text
            WHEN j.title ~~* 'Service Agreement%'::text THEN 'SA'::text
            WHEN j.title ~~* 'Service Call%'::text THEN 'SC'::text
            ELSE 'other'::text
        END AS job_kind,
    vr.missed_next_step
   FROM v_visits_live v
     LEFT JOIN visit_reviews vr ON vr.visit_id = v.id
     LEFT JOIN jobs j ON j.id = v.job_id
     LEFT JOIN review_scope_inclusions inc ON inc.visit_id = v.id
     LEFT JOIN LATERAL ( SELECT (EXISTS ( SELECT 1
                   FROM photo_links pl
                     JOIN photo_classifications pc ON pc.photo_link_id = pl.id
                  WHERE pl.entity_type = 'visit'::text AND pl.entity_id = v.id AND pl.deleted_at IS NULL)) OR (EXISTS ( SELECT 1
                   FROM visit_reviews r
                  WHERE r.visit_id = v.id AND (COALESCE(r.review_status, 'pending'::text) <> 'pending'::text OR COALESCE(r.bonus_status, 'pending'::text) <> 'pending'::text OR COALESCE(r.invoice_status, 'pending'::text) <> 'pending'::text OR r.quality_flag_note IS NOT NULL OR r.reviewed_at IS NOT NULL))) AS started) w ON true;

do $verify$
declare v_last text; v_acl text;
begin
  select attname into v_last from pg_attribute where attrelid = 'public.visits_with_review'::regclass and attnum > 0 and not attisdropped order by attnum desc limit 1;
  if v_last <> 'missed_next_step' then raise exception 'VERIFY: last view column is %', v_last; end if;
  if not exists (select 1 from pg_constraint where conname = 'visit_reviews_missed_next_step_chk' and conrelid = 'public.visit_reviews'::regclass) then
    raise exception 'VERIFY: CHECK missing';
  end if;
  if not (has_column_privilege('authenticated', 'public.visit_reviews', 'missed_next_step', 'INSERT')
      and has_column_privilege('authenticated', 'public.visit_reviews', 'missed_next_step', 'UPDATE')
      and has_column_privilege('authenticated', 'public.visits_with_review', 'missed_next_step', 'SELECT')) then
    raise exception 'VERIFY: authenticated cannot write or read the new column';
  end if;
  if has_table_privilege('anon', 'public.visit_reviews', 'SELECT') or has_table_privilege('anon', 'public.visits_with_review', 'SELECT') then
    raise exception 'VERIFY: anon reads reviews';
  end if;
  select relacl::text into v_acl from pg_class where oid = 'public.visits_with_review'::regclass;
  if v_acl <> '{postgres=arwdDxtm/postgres,authenticated=arwdDxtm/postgres,service_role=arwdDxtm/postgres,yannick_readonly=r/postgres,db_backup_reader=r/postgres}' then
    raise exception 'VERIFY: view grants changed: %', v_acl;
  end if;
  if md5(pg_get_viewdef('public.v_review_scope_picker'::regclass, true)) <> '28df2c76f072c0b0aeae63d2d0b2e1e2' then
    raise exception 'VERIFY: the dependant view changed';
  end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'public.visit_reviews'::regclass and tgname = 'audit_visit_reviews') then
    raise exception 'VERIFY: audit trigger gone';
  end if;
  perform set_config('verify.summary', 'column, CHECK, grants, dependant and audit trigger all as intended', true);
end $verify$;

commit;
