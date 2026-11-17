-- Rollback of 2026-11-17_0405_client_properties_jobber_url.sql: client.properties without jobber_url.
-- A view cannot drop a column through CREATE OR REPLACE, so drop and recreate (nothing depends on it), same grants.
begin;
set local lock_timeout = '3s';
drop view client.properties;
CREATE OR REPLACE VIEW client.properties AS
 SELECT id,
    client_id,
    name,
    address,
    city,
    state,
    zip,
    country,
    is_billing,
    created_at,
    updated_at,
    latitude,
    longitude,
    geofence_radius_meters,
    geofence_type,
    fn_sched_open(access_schedule) AS access_hours_start,
    fn_sched_close(access_schedule) AS access_hours_end,
    fn_sched_days(access_schedule) AS access_days,
    is_primary,
    notes,
    county,
    grease_trap_manhole_count,
    access_notes,
    default_disposal_facility_id,
    zone_id,
    sample_port_count,
    ( SELECT z.code
           FROM zones z
          WHERE z.id = p.zone_id) AS zone,
    (( SELECT count(*) AS count
           FROM jobs j
          WHERE j.property_id = p.id))::integer AS job_count,
    (EXISTS ( SELECT 1
           FROM entity_source_links l
          WHERE l.entity_type = 'property'::text AND l.source_system = 'jobber'::text AND l.entity_id = p.id)) AS jobber_linked,
    COALESCE(grease_trap_size_gallons::numeric, ( SELECT sc.equipment_size_gallons
           FROM v_client_agreement_services sc
          WHERE sc.property_id = p.id AND sc.service_type = 'Pumping'::text
          ORDER BY sc.id
         LIMIT 1)) AS grease_capacity_gallons,
    access_schedule,
    city_emails,
    lock_box_key,
    grease_trap_location
   FROM properties p
  WHERE deleted_at IS NULL;
revoke all on client.properties from public, anon;
grant select on client.properties to authenticated, service_role, db_backup_reader;
do $v$ begin if md5(pg_get_viewdef('client.properties'::regclass, true)) <> 'e0ebba96fec2e1da1e2cf6a957a48495' then raise exception 'ROLLBACK VERIFY: body differs'; end if; end $v$;
commit;
