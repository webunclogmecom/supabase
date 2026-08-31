-- 2026-08-31_0932  The DRY-RUN queue had the same one-permit-per-ticket bug.
--
-- Companion to 2026-08-31_0914, which widened the LIVE queue to serve every GDO
-- permit on a manifest. v_derm_portal_dryrun is the QA queue the bot reads in
-- `?dry_run=true` mode, and it carried the identical `DISTINCT ON (manifest_id)`.
--
-- 🛑 THIS IS NOT COSMETIC PARITY. The dry-run view is how the multi-permit path
-- gets TESTED without filing to the county. Left as it was, a dry run over a
-- three-permit ticket would still have returned one item, and the obvious reading
-- of that is "the fix did not work" rather than "the test queue was not fixed".
-- A test instrument that cannot see the behaviour under test is the failure mode
-- this repo keeps re-learning.
--
-- No lease or submission gates here on purpose: this view is deliberately
-- gate-free (`visit_date < rpa_launch_cutoff()` is its whole WHERE clause), so
-- dry runs are repeatable and never consume live queue state. Only the DISTINCT
-- key changes.
--
-- CREATE OR REPLACE, not DROP: same grant-preservation reason as 0914.

begin;

create or replace view public.v_derm_portal_dryrun as
 select distinct on (manifest_id, gdo_id) visit_id,
    visit_date, client_id, client_code, client_name, client_email,
    address, city, zip, county, gdo_number, manifest_id,
    white_manifest_number, dump_ticket_date, disposal_facility,
    derm_address_url, derm_address_extra_urls, derm_manifest_url,
    derm_manifest_extra_urls, updated_at, linked_at, ticket_number,
    jurisdiction, gdo_id
   from v_derm_portal_fields f
  where visit_date < rpa_launch_cutoff()
  order by manifest_id, gdo_id, (abs(visit_date - dump_ticket_date)), visit_id;

do $$
declare
  v_def   text;
  v_multi int;
  v_total int;
begin
  select pg_get_viewdef('public.v_derm_portal_dryrun'::regclass, true) into v_def;
  if position('DISTINCT ON (manifest_id, gdo_id)' in v_def) = 0 then
    raise exception 'dryrun queue is still keyed on manifest_id alone';
  end if;

  -- POSITIVE CONTROL: the point of the change is that a multi-permit ticket now
  -- yields more than one row. 043-MIL has two ACTIVE permits and pre-cutoff
  -- manifests, so at least one ticket in this view must expose 2+ permits. An
  -- assertion that only reads the view definition would pass on an empty view.
  select count(*) into v_total from public.v_derm_portal_dryrun;
  select count(*) into v_multi from (
    select manifest_id from public.v_derm_portal_dryrun
     group by manifest_id having count(distinct gdo_id) > 1) t;
  if v_total = 0 then
    raise exception 'control failed: dryrun queue is empty, the assertion above is vacuous';
  end if;
  if v_multi = 0 then
    raise exception 'control failed: no ticket in the dryrun queue exposes 2+ permits, so the widening is unproven';
  end if;

  raise notice 'VERIFY OK: dryrun keyed on (manifest_id, gdo_id); % rows, % tickets carry more than one permit', v_total, v_multi;
end $$;

commit;
