-- 2026-11-17_0405_client_properties_jobber_url.sql
-- Trello #202 McQOTwnN (Ops Portal, Clients): a contact card's "Open in Jobber" opened the CLIENT for every contact.
-- Fred, 2026-11-17 ("yes, go in that order"; #202 needed no pick): Jobber has NO page for a contact (introspected:
-- ContactModel has no web address field; Property and Client do), so a contact that belongs to a site opens that SITE's
-- page, and every other contact opens the client with a button that says so.
--
-- What changes: ONE column appended to client.properties, `jobber_url`, Jobber's own site page address
-- https://secure.getjobber.com/clients/<client number>/properties/<site number> (format read from Jobber's
-- Property.jobberWebUri for 112-YA's site 1164). Built from entity_source_links like client.clients.jobber_url.
-- A billing twin's link ("<client gid>_billing") fails the base64 test, so it gets NULL, never a dead link.
-- Every other column is byte for byte the live definition (copied from pg_get_viewdef, md5-guarded below).
-- Audit (rule 8): a view, no data written; nothing to opt in.
-- Grants: CREATE OR REPLACE keeps the ACL; VERIFY checks it is unchanged and that authenticated reads the new column.
-- Nothing depends on client.properties (pg_depend, 2026-11-17).
-- Rollback: 2026-11-17_0405_client_properties_jobber_url_rollback.sql (a view cannot lose a column by REPLACE, so it
-- drops and recreates with the same grants).

begin;
set local lock_timeout = '3s';

create temp table _before on commit drop as
  select id, md5(to_jsonb(t)::text) as h from client.properties t;

do $guard$
begin
  if md5(pg_get_viewdef('client.properties'::regclass, true)) <> 'e0ebba96fec2e1da1e2cf6a957a48495' then
    raise exception 'client.properties changed since this migration was written; rebuild it from the live body';
  end if;
end $guard$;

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
    grease_trap_location,
    ( SELECT
                CASE
                    WHEN (length(lp.source_id) % 4) = 0 AND lp.source_id ~ '^[A-Za-z0-9+/]+={0,2}$'::text
                     AND (length(lc.source_id) % 4) = 0 AND lc.source_id ~ '^[A-Za-z0-9+/]+={0,2}$'::text
                    THEN 'https://secure.getjobber.com/clients/'::text
                      || split_part(convert_from(decode(lc.source_id, 'base64'::text), 'UTF8'::name), '/'::text, '-1'::integer)
                      || '/properties/'::text
                      || split_part(convert_from(decode(lp.source_id, 'base64'::text), 'UTF8'::name), '/'::text, '-1'::integer)
                    ELSE NULL::text
                END AS "case"
           FROM entity_source_links lp
             JOIN entity_source_links lc ON lc.entity_type = 'client'::text AND lc.source_system = 'jobber'::text AND lc.entity_id = p.client_id
          WHERE lp.entity_type = 'property'::text AND lp.source_system = 'jobber'::text AND lp.entity_id = p.id
         LIMIT 1) AS jobber_url
   FROM properties p
  WHERE deleted_at IS NULL;

do $verify$
declare n_before int; n_after int; n_diff int; n_billing int; n_url int; v_acl text;
begin
  select count(*) into n_before from _before;
  select count(*) into n_after from client.properties;
  if n_before <> n_after then raise exception 'VERIFY: row count % -> %', n_before, n_after; end if;
  select count(*) into n_diff from _before b join client.properties t on t.id = b.id
   where md5((to_jsonb(t) - 'jobber_url')::text) <> b.h;
  if n_diff <> 0 then raise exception 'VERIFY: % rows changed outside jobber_url', n_diff; end if;
  if (select jobber_url from client.properties where id = 1164)
     is distinct from 'https://secure.getjobber.com/clients/106567404/properties/159593031' then
    raise exception 'VERIFY: 112-YA site 1164 url is %', (select jobber_url from client.properties where id = 1164);
  end if;
  select count(*) into n_billing from client.properties where is_billing and jobber_url is not null;
  if n_billing <> 0 then raise exception 'VERIFY: % billing twins got a url', n_billing; end if;
  select count(*) into n_url from client.properties where jobber_url is not null;
  if n_url < 400 then raise exception 'VERIFY: only % sites got a url', n_url; end if;
  select relacl::text into v_acl from pg_class where oid = 'client.properties'::regclass;
  if v_acl <> '{postgres=arwdDxtm/postgres,authenticated=r/postgres,service_role=r/postgres,db_backup_reader=r/postgres}' then
    raise exception 'VERIFY: grants changed: %', v_acl;
  end if;
  if not has_column_privilege('authenticated', 'client.properties', 'jobber_url', 'SELECT')
     or has_table_privilege('anon', 'client.properties', 'SELECT') then
    raise exception 'VERIFY: wrong read rights on the new column';
  end if;
  perform set_config('verify.summary', format('rows %s, unchanged %s, with url %s, billing with url %s', n_after, n_after - n_diff, n_url, n_billing), true);
end $verify$;

commit;
