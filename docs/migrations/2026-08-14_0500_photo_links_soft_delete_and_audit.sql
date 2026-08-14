-- ============================================================================
-- 2026-08-14_0500: soft-delete + audit trail on public.photo_links
-- ============================================================================
-- Fred, 2026-08-14: "we should be able to also delete an image ... when deleting we need to
-- have a confirmation dialog for it, so add the delete functionality, add the warning when
-- using it, and do a soft delete, remember we need an audit trail for this kind of thing too."
--
-- This is the DB half. The Admin Review UI (confirmation dialog + warning) is separate.
--
-- 🛑 WHY THIS ALSO RESCUES THE CLEANUP. The 3,455 surplus links from the job-note
-- over-attachment (docs/audits/2026-08-14_photo_note_linking_audit.md) were going to have to be
-- HARD deleted, and `photo_classifications_photo_link_id_fkey` is ON DELETE CASCADE, so that
-- would have silently destroyed 140 classifications including 72 deliberate "internal, do not
-- show the customer" markings, with no audit trail because this table had NO triggers at all.
-- A soft delete keeps every classification intact and is reversible by clearing one column.
--
-- WHAT THIS ADDS
--   1. deleted_at / deleted_by / deleted_reason on public.photo_links
--   2. an audit.log_change trigger (rule 8) — the table had ZERO triggers before today
--   3. a BEFORE UPDATE trigger to stamp deleted_by from auth.uid()
--   4. public.soft_delete_photo_link(bigint, text) — the ONLY app-facing write path
--   5. `deleted_at IS NULL` on all three reader views AND on both SELECT policies
--
-- ⚠ WHY deleted_by IS A TRIGGER AND NOT A COLUMN DEFAULT. A DEFAULT fires only on INSERT, and
-- a soft delete is an UPDATE, so the default would never fire and the column would sit empty
-- while looking correct on a freshly inserted row. This is the exact trap already documented for
-- photo_classifications.classified_by_user_id in Admin Review's 09-known-issues.md.
--
-- 🛑 BOTH SELECT POLICIES MUST FILTER, NOT ONE. `photo_links` carries two PERMISSIVE SELECT
-- policies for `authenticated` and permissive policies OR together:
--     "photo_links_authenticated_read"  USING (true)
--     "Authenticated read photo_links"  USING ((SELECT auth.uid()) IS NOT NULL)
-- Filtering only one leaves the other passing every soft-deleted row straight through, and the
-- broader one is USING(true). Both are narrowed below. This is the permissive-OR trap in
-- CLAUDE.md, and it is why the app needs no change to stop showing deleted photos.
--
-- ⚠ THE RPC IS SECURITY DEFINER, WHICH BYPASSES RLS, SO IT IS DELIBERATELY NARROW.
-- `authenticated` today holds no UPDATE policy on photo_links at all, so this genuinely grants
-- reach it did not have. It therefore: touches only the three delete columns, only rows with
-- entity_type='visit', refuses an already-deleted row, and cannot un-delete. Un-deleting stays a
-- deliberate service_role/SQL action.
--
-- AUDIT-TRAIL STANDING CHECK (rule 8): opt-IN, and this is the first audit coverage this table
-- has ever had. Every soft delete lands in audit.logs with old_row intact.
-- ============================================================================

-- ── 1. columns ───────────────────────────────────────────────────────────────
alter table public.photo_links
  add column if not exists deleted_at     timestamptz,
  add column if not exists deleted_by     uuid,
  add column if not exists deleted_reason text;

create index if not exists photo_links_alive_visit_idx
  on public.photo_links (entity_type, entity_id) where deleted_at is null;

comment on column public.photo_links.deleted_at is
  'Soft delete. EVERY reader must filter deleted_at IS NULL. Both authenticated SELECT policies already do, so PostgREST callers are covered automatically.';

-- ── 2. audit trigger (rule 8) ────────────────────────────────────────────────
drop trigger if exists audit_photo_links on public.photo_links;
create trigger audit_photo_links
  after insert or update or delete on public.photo_links
  for each row execute function audit.log_change();

-- ── 3. stamp deleted_by on the NULL -> non-NULL transition ───────────────────
create or replace function public.fn_stamp_photo_link_deleted_by()
returns trigger language plpgsql security invoker
set search_path = pg_catalog, public
as $fn$
begin
  -- only on the transition into deleted, and never blank an explicit value
  if new.deleted_at is not null and old.deleted_at is null then
    if new.deleted_by is null then new.deleted_by := auth.uid(); end if;
  end if;
  return new;
end
$fn$;

drop trigger if exists trg_photo_link_deleted_by on public.photo_links;
create trigger trg_photo_link_deleted_by
  before update on public.photo_links
  for each row execute function public.fn_stamp_photo_link_deleted_by();

-- ── 4. the one app-facing write path ─────────────────────────────────────────
create or replace function public.soft_delete_photo_link(p_link_id bigint, p_reason text default null)
returns public.photo_links
language plpgsql security definer
set search_path = pg_catalog, public
as $fn$
declare v_row public.photo_links;
begin
  select * into v_row from public.photo_links where id = p_link_id;
  if not found then
    raise exception 'photo link % does not exist', p_link_id using errcode = '22023';
  end if;
  if v_row.entity_type <> 'visit' then
    raise exception 'soft_delete_photo_link only handles visit links, this one is %', v_row.entity_type
      using errcode = '22023';
  end if;
  if v_row.deleted_at is not null then
    raise exception 'photo link % is already deleted', p_link_id using errcode = '22023';
  end if;

  update public.photo_links
     set deleted_at = now(), deleted_by = auth.uid(), deleted_reason = nullif(btrim(coalesce(p_reason,'')),'')
   where id = p_link_id
  returning * into v_row;

  return v_row;
end
$fn$;

revoke all on function public.soft_delete_photo_link(bigint, text) from public;
revoke all on function public.soft_delete_photo_link(bigint, text) from anon;
grant execute on function public.soft_delete_photo_link(bigint, text) to authenticated;
grant execute on function public.soft_delete_photo_link(bigint, text) to service_role;

-- ── 5a. every reader view filters ────────────────────────────────────────────
create or replace view client.photo_links as
 SELECT id, photo_id, entity_type, entity_id, role, caption, created_at
   FROM public.photo_links
  WHERE deleted_at IS NULL;

create or replace view customer.wo_photos as
 SELECT customer.uuid_from_bigint(pl.id) AS id,
    v.public_id AS work_order_id,
    pc.service_phase AS variant,
    customer.public_url(ph.storage_path) AS url,
    NULL::text AS caption,
    (row_number() OVER (PARTITION BY pl.entity_id ORDER BY ph.created_at) - 1)::integer AS "position",
    customer.thumbnail_url(ph.storage_path, 400) AS thumbnail_url
   FROM public.photo_links pl
     JOIN public.photos ph ON ph.id = pl.photo_id
     JOIN public.photo_classifications pc ON pc.photo_link_id = pl.id
     JOIN public.visits v ON v.id = pl.entity_id AND v.deleted_at IS NULL
  WHERE pl.entity_type = 'visit'::text
    AND pl.deleted_at IS NULL
    AND (pc.service_phase = ANY (ARRAY['before'::text, 'after'::text, 'extra'::text]));

create or replace view customer.client_access_photos as
 WITH resolved AS (
         SELECT pl.id AS link_id, pl.caption, ph.storage_path, ph.created_at,
            COALESCE(CASE WHEN pl.entity_type = 'client'::text THEN pl.entity_id ELSE NULL::bigint END,
                     p.client_id) AS client_id_resolved
           FROM public.photo_links pl
             JOIN public.photos ph ON ph.id = pl.photo_id
             LEFT JOIN public.properties p ON p.id = pl.entity_id AND pl.entity_type = 'property'::text
          WHERE pl.entity_type = ANY (ARRAY['client'::text, 'property'::text])
            AND pl.deleted_at IS NULL
        )
 SELECT customer.uuid_from_bigint(link_id) AS id,
    customer.uuid_from_bigint(client_id_resolved) AS client_id,
    customer.public_url(storage_path) AS url,
    caption,
    (row_number() OVER (PARTITION BY client_id_resolved ORDER BY created_at) - 1)::integer AS "position",
    created_at,
    customer.thumbnail_url(storage_path, 400) AS thumbnail_url
   FROM resolved
  WHERE client_id_resolved IS NOT NULL;

-- ── 5b. BOTH permissive SELECT policies ──────────────────────────────────────
alter policy "photo_links_authenticated_read" on public.photo_links
  using (deleted_at is null);
alter policy "Authenticated read photo_links" on public.photo_links
  using (((select auth.uid()) is not null) and deleted_at is null);

-- ── verification ─────────────────────────────────────────────────────────────
do $verify$
declare v_n int; v_txt text;
begin
  -- (a) columns exist
  select count(*) into v_n from information_schema.columns
   where table_schema='public' and table_name='photo_links'
     and column_name in ('deleted_at','deleted_by','deleted_reason');
  if v_n <> 3 then raise exception 'expected 3 soft-delete columns, found %', v_n; end if;

  -- (b) the table is audited for the first time
  select count(*) into v_n from pg_trigger t join pg_class c on c.oid=t.tgrelid
    join pg_proc p on p.oid=t.tgfoid join pg_namespace pn on pn.oid=p.pronamespace
   where c.relname='photo_links' and pn.nspname='audit' and p.proname='log_change' and not t.tgisinternal;
  if v_n <> 1 then raise exception 'audit trigger not installed on photo_links (found %)', v_n; end if;

  -- (c) EVERY permissive SELECT policy filters. One unfiltered policy defeats all the others.
  select count(*) into v_n from pg_policy p join pg_class c on c.oid=p.polrelid
   where c.relname='photo_links' and p.polcmd='r' and p.polpermissive
     and pg_get_expr(p.polqual,p.polrelid) not like '%deleted_at%';
  if v_n <> 0 then raise exception '% permissive SELECT policies still do not filter deleted_at', v_n; end if;

  -- (d) all three reader views filter
  select count(*) into v_n from pg_class c join pg_namespace n on n.oid=c.relnamespace
   where c.relkind='v' and pg_get_viewdef(c.oid) ilike '%photo_links%'
     and pg_get_viewdef(c.oid) not ilike '%deleted_at is null%';
  if v_n <> 0 then raise exception '% views read photo_links without filtering deleted_at', v_n; end if;

  -- (e) the RPC is not reachable by anon
  if has_function_privilege('anon','public.soft_delete_photo_link(bigint,text)','EXECUTE') then
    raise exception 'anon can execute soft_delete_photo_link';
  end if;
  if not has_function_privilege('authenticated','public.soft_delete_photo_link(bigint,text)','EXECUTE') then
    raise exception 'authenticated cannot execute soft_delete_photo_link';
  end if;

  -- (f) POSITIVE CONTROL. Everything above passes on a table where nothing was soft-deleted yet.
  -- Assert the column actually defaults to NULL so no existing row was accidentally marked.
  select count(*) into v_n from public.photo_links where deleted_at is not null;
  if v_n <> 0 then raise exception '% rows are already soft-deleted; this migration should mark none', v_n; end if;
  select count(*) into v_n from public.photo_links;
  if v_n < 1000 then raise exception 'photo_links has only % rows - wrong database?', v_n; end if;

  raise notice 'photo_links: soft-delete columns + first-ever audit trigger + RPC; 3 views and 2 policies filter';
end
$verify$;
