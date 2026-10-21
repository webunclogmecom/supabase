-- 2026-10-21_1624 ET · Revoke anon's last table privileges: REFERENCES, TRIGGER, MAINTAIN (the ACL letters x, t, m)
--
-- Fred, 2026-10-21: public.shift_reviews and public.inspections_with_review carry `anon=xtm/postgres`. "TRUNCATE/
-- REFERENCES/TRIGGER are not reachable through PostgREST, but they should not be granted to anon at all."
--
-- ⚠ On this server (Postgres 17.6) the letter `m` is MAINTAIN, not TRUNCATE (TRUNCATE is `D`). Measured with
-- aclexplode(relacl): `anon=xtm` explodes to REFERENCES, TRIGGER, MAINTAIN. anon holds TRUNCATE on nothing. MAINTAIN
-- (new in PG17) is VACUUM, ANALYZE, CLUSTER, REINDEX, REFRESH MATERIALIZED VIEW and LOCK TABLE, which is the one of
-- the three that could actually hurt (an ACCESS EXCLUSIVE lock), so it is revoked here too. TRUNCATE stays in the
-- statement as asked; on these objects it is a no-op.
--
-- Sweep, 2026-10-21 16:15 ET, every table and view in public, ops, client, derm, customer, hr (336 objects: 148
-- tables, 188 views), aclexplode on relacl, grantee anon or PUBLIC, has_table_privilege agreeing on every count:
--   TRUNCATE 0 · REFERENCES 22 · TRIGGER 22 · MAINTAIN 34 · SELECT/INSERT/UPDATE/DELETE 0 · PUBLIC 0 · column REFERENCES 0
-- All 34 hits are in public. ops, client, derm, customer and hr have none.
--   anon=xtm (22): tables client_locations, derm_manifest_number_proposals, derm_required_backfill_snapshot_2026_06_24,
--     service_line_items, shift_reviews, visit_locations, visit_reviews, visit_team; views client_services_flat,
--     clients_due_service, driver_inspection_status, inspections_with_review, manifest_detail, manifest_pickable_visits,
--     v_gdo_reporting_derm_mismatch, v_vehicle_telemetry_latest, v_visits_live, visit_manhole_options, visits_recent,
--     visits_with_review, visits_with_status, zones_with_usage
--   anon=m (12, tables): client_groups, disposal_facilities, gdos, jobber_oversized_attachments, notes,
--     photo_classifications, photo_links, photos, vehicle_telemetry_readings, visit_recommendations, visit_sync_flags,
--     webhook_events_log
--
-- Why they were left: every earlier anon revoke named its privileges. 2026-07-12_anon_surface_harden revoked INSERT,
-- UPDATE, DELETE; 2026-07-28y_public_revoke_anon revoked SELECT; lists such as 2026-06-10_batch_a ("INSERT, UPDATE,
-- DELETE, TRUNCATE, TRIGGER, REFERENCES") were the whole of ALL before Postgres 17 and miss MAINTAIN since. The rule
-- for the next one: take a role off an object with REVOKE ALL, never a list (CLAUDE.md, "anon READS NOTHING TODAY").
--
-- What this changes: anon's REFERENCES, TRIGGER, MAINTAIN (and TRUNCATE) on the 34 objects above, named one by one.
-- Nothing else: no other role, no other schema, no policy, no function, no object. VERIFY proves it by comparing every
-- non-anon ACL entry of all 336 objects before and after.
-- Not covered, on purpose: authenticated still holds arwdDxtm on most of these (a separate question); anon holds
-- Dxtm on net._http_response and net.http_request_queue (pg_net's own tables, outside the six schemas); the
-- supabase_admin default ACL in public still grants anon ALL on tables supabase_admin creates (postgres-created tables
-- get nothing). No schema change, so rule 8 (audit opt-in) does not apply.
--
-- Rollback (puts back exactly what was there):
--   grant references, trigger, maintain on table public.client_locations, public.derm_manifest_number_proposals,
--     public.derm_required_backfill_snapshot_2026_06_24, public.service_line_items, public.shift_reviews,
--     public.visit_locations, public.visit_reviews, public.visit_team, public.client_services_flat,
--     public.clients_due_service, public.driver_inspection_status, public.inspections_with_review, public.manifest_detail,
--     public.manifest_pickable_visits, public.v_gdo_reporting_derm_mismatch, public.v_vehicle_telemetry_latest,
--     public.v_visits_live, public.visit_manhole_options, public.visits_recent, public.visits_with_review,
--     public.visits_with_status, public.zones_with_usage to anon;
--   grant maintain on table public.client_groups, public.disposal_facilities, public.gdos,
--     public.jobber_oversized_attachments, public.notes, public.photo_classifications, public.photo_links, public.photos,
--     public.vehicle_telemetry_readings, public.visit_recommendations, public.visit_sync_flags,
--     public.webhook_events_log to anon;

BEGIN;
SET LOCAL lock_timeout = '3s';

-- every object's ACL entries for roles other than anon, to prove afterwards that nothing else moved
create temp table _acl_before on commit drop as
select c.oid, array(select x from unnest(c.relacl::text[]) x where x not like 'anon=%' order by x) as others
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where c.relkind in ('r','v','m','p','f') and n.nspname in ('public','ops','client','derm','customer','hr');

-- instrument control: the check below must see anon's privilege while it is still there
do $control$
begin
  if not has_table_privilege('anon', 'public.shift_reviews', 'TRIGGER')
     or not has_table_privilege('anon', 'public.gdos', 'MAINTAIN') then
    raise exception 'CONTROL: anon does not hold TRIGGER on shift_reviews / MAINTAIN on gdos before the revoke; state changed, re-sweep';
  end if;
end $control$;

revoke truncate, references, trigger, maintain on table
  public.client_locations, public.derm_manifest_number_proposals, public.derm_required_backfill_snapshot_2026_06_24,
  public.service_line_items, public.shift_reviews, public.visit_locations, public.visit_reviews, public.visit_team,
  public.client_services_flat, public.clients_due_service, public.driver_inspection_status,
  public.inspections_with_review, public.manifest_detail, public.manifest_pickable_visits,
  public.v_gdo_reporting_derm_mismatch, public.v_vehicle_telemetry_latest, public.v_visits_live,
  public.visit_manhole_options, public.visits_recent, public.visits_with_review, public.visits_with_status,
  public.zones_with_usage,
  public.client_groups, public.disposal_facilities, public.gdos, public.jobber_oversized_attachments, public.notes,
  public.photo_classifications, public.photo_links, public.photos, public.vehicle_telemetry_readings,
  public.visit_recommendations, public.visit_sync_flags, public.webhook_events_log
from anon;

do $verify$
declare t text; p text; v_n int; v_bad text;
begin
  -- 1. the 34 named objects: anon holds nothing at all
  foreach t in array array[
    'public.client_locations','public.derm_manifest_number_proposals','public.derm_required_backfill_snapshot_2026_06_24',
    'public.service_line_items','public.shift_reviews','public.visit_locations','public.visit_reviews','public.visit_team',
    'public.client_services_flat','public.clients_due_service','public.driver_inspection_status',
    'public.inspections_with_review','public.manifest_detail','public.manifest_pickable_visits',
    'public.v_gdo_reporting_derm_mismatch','public.v_vehicle_telemetry_latest','public.v_visits_live',
    'public.visit_manhole_options','public.visits_recent','public.visits_with_review','public.visits_with_status',
    'public.zones_with_usage',
    'public.client_groups','public.disposal_facilities','public.gdos','public.jobber_oversized_attachments','public.notes',
    'public.photo_classifications','public.photo_links','public.photos','public.vehicle_telemetry_readings',
    'public.visit_recommendations','public.visit_sync_flags','public.webhook_events_log'] loop
    foreach p in array array['TRUNCATE','REFERENCES','TRIGGER','MAINTAIN','SELECT','INSERT','UPDATE','DELETE'] loop
      if has_table_privilege('anon', t, p) then raise exception 'VERIFY: anon still holds % on %', p, t; end if;
    end loop;
  end loop;

  -- 2. the whole sweep is clean: no anon or PUBLIC entry left on any table or view in the six schemas
  select count(*), string_agg(n.nspname||'.'||c.relname, ', ') into v_n, v_bad
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where c.relkind in ('r','v','m','p','f') and n.nspname in ('public','ops','client','derm','customer','hr')
    and exists (select 1 from unnest(c.relacl::text[]) x where x like 'anon=%' or x like '=%');
  if v_n > 0 then raise exception 'VERIFY: % object(s) still carry an anon or PUBLIC entry: %', v_n, v_bad; end if;

  -- 3. nothing else moved: every other role's entries are identical on every object
  select count(*) into v_n from _acl_before;
  if v_n < 300 then raise exception 'VERIFY: compared only % objects, expected 336', v_n; end if;
  select count(*), string_agg(b.oid::regclass::text, ', ') into v_n, v_bad
  from _acl_before b left join pg_class c on c.oid = b.oid
  where c.oid is null
     or b.others is distinct from array(select x from unnest(c.relacl::text[]) x where x not like 'anon=%' order by x);
  if v_n > 0 then raise exception 'VERIFY: % object(s) changed for a role other than anon: %', v_n, v_bad; end if;

  -- 4. the instrument still answers true where a privilege is held
  if not has_table_privilege('authenticated', 'public.shift_reviews', 'TRIGGER')
     or not has_table_privilege('service_role', 'public.gdos', 'MAINTAIN') then
    raise exception 'VERIFY: control failed, authenticated TRIGGER on shift_reviews / service_role MAINTAIN on gdos';
  end if;
  raise notice 'VERIFY ok';
end $verify$;

COMMIT;
