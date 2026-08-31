-- 2026-08-31_0914  Serve EVERY GDO permit on a manifest, not one per 20 hours.
--
-- WHY
-- ---
-- 009-CN Casa Neos has three ACTIVE permits (GDO-10877 Kitchens, GDO-15062 Bars,
-- GDO-16389 Lounge) on three client_locations. One pumping visit produces one
-- manifest, and DERM wants a report per permit. All three DID file off manifest
-- 1763, but one per run, 20h29m and 20h15m apart:
--
--     gdo 63  GDO-10877   filed 2026-08-27 16:32 ET
--     gdo 64  GDO-15062   filed 2026-08-28 13:01 ET   (+20h29m)
--     gdo 65  GDO-16389   filed 2026-08-29 09:17 ET   (+20h15m)
--
-- Jonathan asked whether the visit could carry all three permits comma-separated.
-- It must NOT: v_derm_portal_fields filters permits on '^GDO-[0-9]+$', so a
-- combined string matches nothing and would file ZERO, and it recreates gdos id
-- 164 ('GDO-10877, GDO-15062, GDO-16389'), demoted to INACTIVE in July precisely
-- because it passes the pdf-service GDO- filter and can print verbatim on an
-- official county sheet. 043-MIL is the precedent: that one was SPLIT into two
-- proper rows, not merged into one string.
--
-- The permits were never the problem. Three of OUR objects are keyed on the VISIT
-- rather than the (visit, permit) pair, and each one alone produces the symptom:
--
--   1. v_derm_portal_queue        DISTINCT ON (manifest_id)      offers 1 permit
--   2. its lease gate             no gdo_id at all               hides the rest 20h
--   3. derm_portal_submissions    UNIQUE (visit_id, run_id)      2nd result in a run dies
--
-- 🛑 ORDER IS A SAFETY PROPERTY. Step 1 below (the unique index) MUST land before
-- the queue widens. If the queue serves three permits while UNIQUE (visit_id,
-- run_id) still stands, the 2nd and 3rd results in one run are REJECTED, and
-- rpa-derm-result's own comments call that the catastrophic path: "a rejected
-- result is a county filing we have no record of, which then gets served and
-- filed AGAIN". Widening the index first is purely permissive and changes no
-- behaviour on its own, so it is safe to land alone.

begin;

-- ---------------------------------------------------------------------------
-- 1. The result endpoint must be able to record one row per PERMIT per run.
--    NULLS NOT DISTINCT is load-bearing: 524 of 542 existing rows have a NULL
--    gdo_id (dry-runs and everything before the permit column existed), and a
--    plain UNIQUE treats every NULL as distinct, which would silently stop
--    deduplicating all of them. PG 17.6, so the clause is available.
-- ---------------------------------------------------------------------------
-- ⚠ It is a CONSTRAINT, not a bare index, so it must be dropped as one. It is
--    recreated as a plain unique INDEX rather than a constraint, because that is
--    what NULLS NOT DISTINCT needs here and nothing references it by constraint
--    name (rpa-derm-result INSERTs, it does not upsert on this key).
alter table public.derm_portal_submissions
  drop constraint if exists derm_portal_submissions_visit_attempt_uniq;
drop index if exists public.derm_portal_submissions_visit_attempt_uniq;
create unique index derm_portal_submissions_visit_attempt_uniq
  on public.derm_portal_submissions (visit_id, gdo_id, run_id) nulls not distinct;

-- ---------------------------------------------------------------------------
-- 2. A lease is per (visit, permit), not per visit.
--    gdo_id stays NULLABLE and a NULL lease deliberately still blocks every
--    permit on the ticket: that is the conservative direction (under-serve,
--    never double-file), and it keeps every lease written before this migration
--    behaving exactly as it did. A PK cannot hold a nullable column, so the
--    primary key is replaced by a unique index with the same NULLS NOT DISTINCT
--    semantics as step 1.
-- ---------------------------------------------------------------------------
alter table public.derm_portal_leases
  add column if not exists gdo_id bigint references public.gdos(id);

alter table public.derm_portal_leases
  drop constraint if exists derm_portal_leases_pkey;

drop index if exists public.derm_portal_leases_visit_gdo_uniq;
create unique index derm_portal_leases_visit_gdo_uniq
  on public.derm_portal_leases (visit_id, gdo_id) nulls not distinct;

comment on column public.derm_portal_leases.gdo_id is
  'The permit this lease holds. NULL = a legacy visit-wide lease, which still '
  'blocks every permit on the ticket. Written by rpa-derm-queue when it '
  'dispenses. See migration 2026-08-31_0914.';

-- ---------------------------------------------------------------------------
-- 3. The queue serves one row per (manifest, permit), and its lease gate gains
--    the permit dimension so holding one permit no longer hides its siblings.
--
--    CREATE OR REPLACE, never DROP: v_derm_portal_queue_held and
--    v_rpa_derm_health depend on it, and a DROP would discard the
--    yannick_readonly + service_role grants. The column list is unchanged, so
--    REPLACE is legal.
--
--    The other three gates already carry
--        (s.gdo_id is null or s.gdo_id is not distinct from f.gdo_id)
--    and are copied through verbatim. Only the ORDER BY key and the lease gate
--    change.
-- ---------------------------------------------------------------------------
create or replace view public.v_derm_portal_queue as
 select distinct on (manifest_id, gdo_id) visit_id,
    visit_date, client_id, client_code, client_name, client_email,
    address, city, zip, county, gdo_number, manifest_id,
    white_manifest_number, dump_ticket_date, disposal_facility,
    derm_address_url, derm_address_extra_urls, derm_manifest_url,
    derm_manifest_extra_urls, updated_at, linked_at, ticket_number,
    jurisdiction, gdo_id
   from v_derm_portal_fields f
  where visit_date >= rpa_launch_cutoff()
    and not exists (
      select 1 from derm_portal_submissions s
        join manifest_visits smv on smv.visit_id = s.visit_id
       where smv.manifest_id = f.manifest_id and not s.dry_run
         and (s.gdo_id is null or s.gdo_id is not distinct from f.gdo_id)
         and (s.status = 'SUCCESS'::text or s.portal_confirmation is not null))
    and not exists (
      select 1 from derm_portal_submissions s
        join manifest_visits smv on smv.visit_id = s.visit_id
       where smv.manifest_id = f.manifest_id and not s.dry_run
         and (s.gdo_id is null or s.gdo_id is not distinct from f.gdo_id)
         and s.created_at > (now() - '20:00:00'::interval))
    and not exists (
      select 1 from derm_portal_submissions s
        join manifest_visits smv on smv.visit_id = s.visit_id
       where smv.manifest_id = f.manifest_id and not s.dry_run
         and (s.gdo_id is null or s.gdo_id is not distinct from f.gdo_id)
         and not s.retryable and s.status <> 'SUCCESS'::text
         and s.created_at > greatest(f.updated_at, coalesce((
              select max(rq.requeued_at) from derm_portal_requeue rq
               where rq.manifest_id = f.manifest_id
                 and (rq.gdo_id is null or rq.gdo_id is not distinct from f.gdo_id)),
             '-infinity'::timestamp with time zone)))
    and not exists (
      select 1 from derm_portal_leases l
        join manifest_visits lmv on lmv.visit_id = l.visit_id
       where lmv.manifest_id = f.manifest_id
         and (l.gdo_id is null or l.gdo_id is not distinct from f.gdo_id)
         and l.leased_at > (now() - '20:00:00'::interval))
  order by manifest_id, gdo_id, (abs(visit_date - dump_ticket_date)), visit_id;

-- ---------------------------------------------------------------------------
-- VERIFY. Raises and rolls the whole migration back on any failure.
-- ---------------------------------------------------------------------------
do $$
declare
  v_idx        text;
  v_lease_idx  int;
  v_def        text;
  v_queued_now int;
  v_multi      int;
begin
  -- 1. the submissions index really carries the permit
  select indexdef into v_idx from pg_indexes
   where schemaname='public' and indexname='derm_portal_submissions_visit_attempt_uniq';
  if v_idx is null or position('gdo_id' in v_idx) = 0 then
    raise exception 'submissions unique index does not carry gdo_id: %', coalesce(v_idx,'<missing>');
  end if;
  if position('NULLS NOT DISTINCT' in upper(v_idx)) = 0 then
    raise exception 'submissions unique index lost NULLS NOT DISTINCT, 524 null-permit rows would stop deduplicating';
  end if;

  -- 2. the lease is per (visit, permit)
  select count(*) into v_lease_idx from pg_indexes
   where schemaname='public' and indexname='derm_portal_leases_visit_gdo_uniq';
  if v_lease_idx <> 1 then
    raise exception 'derm_portal_leases_visit_gdo_uniq missing';
  end if;

  -- 3. the queue is keyed on the pair, and its lease gate is permit-aware
  select pg_get_viewdef('public.v_derm_portal_queue'::regclass, true) into v_def;
  if position('DISTINCT ON (manifest_id, gdo_id)' in v_def) = 0 then
    raise exception 'queue is not keyed on (manifest_id, gdo_id)';
  end if;
  if position('l.gdo_id' in v_def) = 0 then
    raise exception 'queue lease gate is still permit-blind';
  end if;

  -- 4. 🛑 THE REGRESSION THAT MATTERS. Everything eligible is already filed, so
  --    the queue must still be EMPTY. If widening the key re-serves anything that
  --    has a SUCCESS against it, that is a double-filing to the county.
  select count(*) into v_queued_now from public.v_derm_portal_queue;
  if v_queued_now <> 0 then
    raise exception 'queue went from 0 rows to % after widening: a filed permit is being re-served', v_queued_now;
  end if;

  -- 5. POSITIVE CONTROL. An assertion that something is empty passes vacuously if
  --    the instrument is broken, so prove the view can still SEE multi-permit work:
  --    ignoring only the already-filed gate, manifest 1763 must expose 3 permits.
  select count(*) into v_multi from public.v_derm_portal_fields where manifest_id = 1763;
  if v_multi <> 3 then
    raise exception 'control failed: manifest 1763 exposes % permits, expected 3', v_multi;
  end if;

  raise notice 'VERIFY OK: index carries gdo_id, lease is per permit, queue keyed on (manifest_id, gdo_id), queue still 0 rows, control sees 3 permits on manifest 1763';
end $$;

commit;
