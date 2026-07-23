-- ============================================================================
-- 2026-07-23 - GDO reporting queue: dedup to ONE row per manifest (dump ticket)
-- ============================================================================
-- WHY: John's first bot dry-run (2026-07-22) surfaced the same GDO report twice --
-- GDO-14117 / white manifest 815951 (Mila) appeared under TWO visits (1353 Feb-4 +
-- 1360 Feb-5) because the queue grain was per code-27 VISIT and both visits were
-- linked to the one Feb-5 dump manifest (919). The root cause of the pair was a
-- Jobber-side DUPLICATE visit on Mila's monthly job 4301 (two completed visits one
-- day apart); the Feb-4 duplicate (1353) was soft-deleted separately (DB-only, its
-- source='jobber' so no Jobber push; neither visit was invoiced). The bot's own
-- idempotency (permit+manifest) caught the double, but our queue must not depend on
-- the consumer to dedup a compliance submission.
--
-- WHAT: v_derm_portal_queue + v_derm_portal_dryrun now emit ONE row per
-- derm_manifests.id (a dump ticket = the unit of a DERM online report), choosing the
-- representative visit whose service date is CLOSEST to the dump date (tie-break
-- lowest visit_id). The four queue gates (already-reported / 20h cooldown /
-- non-retryable-fail hold / dispense lease) are made MANIFEST-SCOPED: once ANY visit
-- sharing the manifest is reported or leased, the whole manifest drops from the queue.
-- Previously each gate keyed on the single visit_id, so after one sibling was filed a
-- second sibling could re-surface the already-filed dump -> double county filing.
--
-- Dedup key = manifest_id (NOT gdo_number+white_manifest_number): manifest_id is NOT
-- NULL in this view and is the true report identity. Co-loaded dumps across DIFFERENT
-- clients keep DIFFERENT manifest rows (sibling-manifest model), so they are NOT
-- collapsed -- each permit still gets its own report. Rows collapse only when they are
-- the SAME manifest.
--
-- v_derm_portal_fields is UNCHANGED (still per-visit) so its dependent
-- v_rpa_derm_health and any future per-visit consumer keep working; only that health
-- view's queue_depth shifts from counting per-visit rows to counting deduped reports
-- (more correct). Column contract of both views is unchanged (21 cols, same
-- names/types/order) so CREATE OR REPLACE succeeds under the dependent. Edge functions
-- rpa-derm-queue / rpa-derm-result are untouched. Views -> no audit trigger.
-- ============================================================================

create or replace view public.v_derm_portal_dryrun as
select distinct on (f.manifest_id)
    f.visit_id, f.visit_date, f.client_id, f.client_code, f.client_name, f.client_email,
    f.address, f.city, f.zip, f.county, f.gdo_number, f.manifest_id, f.white_manifest_number,
    f.dump_ticket_date, f.disposal_facility, f.derm_address_url, f.derm_address_extra_urls,
    f.derm_manifest_url, f.derm_manifest_extra_urls, f.updated_at, f.linked_at
from v_derm_portal_fields f
where f.visit_date < rpa_launch_cutoff()
order by f.manifest_id,
    abs(f.visit_date - f.dump_ticket_date) asc nulls last,   -- representative = service closest to the dump
    f.visit_id asc;

create or replace view public.v_derm_portal_queue as
select distinct on (f.manifest_id)
    f.visit_id, f.visit_date, f.client_id, f.client_code, f.client_name, f.client_email,
    f.address, f.city, f.zip, f.county, f.gdo_number, f.manifest_id, f.white_manifest_number,
    f.dump_ticket_date, f.disposal_facility, f.derm_address_url, f.derm_address_extra_urls,
    f.derm_manifest_url, f.derm_manifest_extra_urls, f.updated_at, f.linked_at
from v_derm_portal_fields f
where f.visit_date >= rpa_launch_cutoff()
  -- (1) manifest already reported successfully by ANY sibling visit -> permanent skip
  and not exists (
    select 1 from derm_portal_submissions s
    join manifest_visits smv on smv.visit_id = s.visit_id
    where smv.manifest_id = f.manifest_id
      and not s.dry_run and (s.status = 'SUCCESS' or s.portal_confirmation is not null))
  -- (2) 20h attempt cooldown across ANY sibling visit
  and not exists (
    select 1 from derm_portal_submissions s
    join manifest_visits smv on smv.visit_id = s.visit_id
    where smv.manifest_id = f.manifest_id
      and not s.dry_run and s.created_at > (now() - '20:00:00'::interval))
  -- (3) data-error hold: a non-retryable failure recorded after the manifest link
  --     freshened, on ANY sibling visit (held until the manifest changes again)
  and not exists (
    select 1 from derm_portal_submissions s
    join manifest_visits smv on smv.visit_id = s.visit_id
    where smv.manifest_id = f.manifest_id
      and not s.dry_run and not s.retryable and s.status <> 'SUCCESS' and s.created_at > f.updated_at)
  -- (4) dispense lease held on ANY sibling visit within 20h
  and not exists (
    select 1 from derm_portal_leases l
    join manifest_visits lmv on lmv.visit_id = l.visit_id
    where lmv.manifest_id = f.manifest_id
      and l.leased_at > (now() - '20:00:00'::interval))
order by f.manifest_id,
    abs(f.visit_date - f.dump_ticket_date) asc nulls last,
    f.visit_id asc;
