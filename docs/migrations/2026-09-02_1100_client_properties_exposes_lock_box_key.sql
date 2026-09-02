-- 2026-09-02_1100_client_properties_exposes_lock_box_key.sql
--
-- WHY. `2026-09-02_1000` added public.properties.lock_box_key and taught
-- client.update_property_operational to WRITE it, and then I stopped. The Client App
-- does not read the base table: it reads the `client.properties` VIEW (that is why its
-- modal binds `grease_capacity_gallons`, a name that exists only there). The view was
-- never widened, so the column was invisible to the app.
--
-- HOW IT PRESENTED, and it is worth keeping because it looked like an app bug:
-- the published modal rendered "Lock Box / Key" with an empty box for property 32
-- (017-FIA) while the base table held '5713'. Manholes (3) and the grease trap size (90)
-- rendered correctly in the same modal, which is what proved the modal was on the right
-- property and the READ was the thing at fault.
--
-- ✅ NO DATA WAS AT RISK, and this was checked rather than assumed. The bundle
-- dirty-checks every field before building the patch:
--     O.trim() !== S.lock_box_key.trim() && (P.lock_box_key = ...)
-- With the column absent the baseline is "" and the input is "", so they match and the
-- key is simply never sent. A save could not have wiped the 28 imported values. Had the
-- app instead sent every field on every save, this omission would have cleared them all
-- on the first edit of any property - which is the "clearing is the untested half of
-- every field" shape this repo documents.
--
-- CREATE OR REPLACE with the new column APPENDED at the end: Postgres permits adding
-- trailing columns to a view in place, and that keeps the grants. Dropping and recreating
-- would discard them (see the DROP VIEW note in CLAUDE.md).
--
-- Rule 8: no table change, no trigger change. Nothing to opt into.

create or replace view client.properties as
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
           FROM service_configs sc
          WHERE sc.property_id = p.id AND sc.service_type = 'Pumping'::text
          ORDER BY sc.id
         LIMIT 1)) AS grease_capacity_gallons,
    access_schedule,
    city_emails,
    lock_box_key
   FROM properties p
  WHERE deleted_at IS NULL;
DO $verify$
DECLARE fails text := ''; v text;
BEGIN
  -- 1. the view now exposes it
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema='client' AND table_name='properties' AND column_name='lock_box_key') THEN
    fails := fails || '1: client.properties still lacks lock_box_key; ';
  END IF;

  -- 2. it carries the real value, not a NULL placeholder. Property 32 is 017-FIA, the
  --    property whose empty modal box exposed this.
  SELECT lock_box_key INTO v FROM client.properties WHERE id = 32;
  IF v IS DISTINCT FROM '5713' THEN
    fails := fails || format('2: client.properties.lock_box_key for 32 reads %L, expected 5713; ', v);
  END IF;

  -- 3. CONTROL: the base table agrees. If this disagreed, assertion 2 would be measuring
  --    the view against nothing.
  SELECT lock_box_key INTO v FROM public.properties WHERE id = 32;
  IF v IS DISTINCT FROM '5713' THEN
    fails := fails || '3: CONTROL failed, the base table does not hold 5713; ';
  END IF;

  -- 4. the whole imported set is visible through the view, not just one row
  IF (SELECT count(*) FROM client.properties WHERE lock_box_key IS NOT NULL) <> 28 THEN
    fails := fails || format('4: view shows %s lock box values, expected 28; ',
      (SELECT count(*) FROM client.properties WHERE lock_box_key IS NOT NULL));
  END IF;

  -- 5. grants survived the replace (a DROP+CREATE would have discarded them)
  IF NOT has_table_privilege('authenticated','client.properties','SELECT') THEN
    fails := fails || '5: authenticated lost SELECT on client.properties; ';
  END IF;

  IF fails <> '' THEN RAISE EXCEPTION 'VERIFY FAILED >>> %', fails; END IF;
  RAISE NOTICE 'VERIFY OK';
END $verify$;
