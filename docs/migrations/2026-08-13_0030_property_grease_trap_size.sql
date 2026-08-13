-- 2026-08-13_0030_property_grease_trap_size.sql
--
-- WHAT: move the grease-trap capacity to public.properties.grease_trap_size_gallons, backfill it,
--       point client.update_property_capacity at it, and make client.properties read it.
--
-- WHY, Serena via Fred 2026-08-12: "I also tried to update Aroma Del Peru #227 with the actual grease
--      trap capacity and it didn't." She got:
--          duplicate key value violates unique constraint "service_configs_client_id_service_type_key"
--      Reproduced live the same day on client 450: HTTP 409.
--
-- 🛑 THE DEFECT IS A GRAIN MISMATCH, NOT A CODING SLIP. client.update_property_capacity looked up
--    service_configs BY PROPERTY (`where property_id = p_property_id and service_type='Pumping'`) and,
--    finding none, INSERTed. But the constraint is UNIQUE (client_id, service_type) -- BY CLIENT. So
--    any property whose client already holds a Pumping config on a DIFFERENT property could never be
--    given a capacity. Measured: 209 properties, 184 clients.
--
-- ⚠ AND THE FIELD WAS BLANK BEFORE SHE TYPED, WHICH IS THE OTHER HALF. client.properties derives
--    grease_capacity_gallons from `service_configs where property_id = p.id`. Aromas' only config is
--    attached to property 521 -- the SYNTHETIC JOBBER BILLING property -- so the real service property
--    (659) showed nothing. She was not overwriting 1200; she was filling a blank that should not have
--    been blank. 14 Pumping configs estate-wide sit on a billing property, 19 on no property at all.
--
-- WHY A COLUMN ON properties RATHER THAN RELAXING THE CONSTRAINT (Fred's decision, 2026-08-13):
--    Relaxing UNIQUE(client_id, service_type) to include property_id was the other candidate. It was
--    REJECTED after measuring it in a rolled-back transaction: allowing one extra Pumping config for
--    client 450 took ops.v_calendar_visit from 7 rows to 12 (duplicate visits on the Calendar) and
--    customer.clients from 1 row to 2 -- and customer.* is CUSTOMER-FACING. Seven live views join
--    service_configs assuming one row per client per service. Adding a per-property column multiplies
--    nothing.
--    It is also what repo rule #2 (3NF standing check) requires: capacity depends on the PROPERTY, not
--    on (client_id, service_type). properties already carries grease_trap_manhole_count and
--    sample_port_count, which are per-property and written by the SAME dialog.
--
-- ⚠ SCOPE, STATED SO NOBODY OVER-READS IT. This migration does NOT drop
--    service_configs.equipment_size_gallons and does NOT repoint the other readers. Nine views still
--    read the old column and will keep serving the backfilled value:
--        client.client_services_flat, client.service_configs, customer.clients, ops.service_configs,
--        ops.v_calendar_visit, ops.v_derm_compliance, ops.v_gdo_expiry, ops.v_route_today,
--        ops.v_service_due  (+ public.client_services_flat, public.service_configs)
--    Backfill makes the two equal TODAY, so nothing changes for them on apply. They will drift the
--    first time someone edits a capacity through the app. **Repointing them is the next step and is
--    deliberately not bundled here** -- rewriting nine view bodies in one pass is the exact
--    "CREATE OR REPLACE, copy don't retype" hazard documented in CLAUDE.md, and this migration is
--    already the difference between "ops cannot save" and "ops can save".
--
-- AUDIT (ADR 010): public.properties already carries audit_properties, so the new column is captured
--    automatically in the full-row JSONB. No trigger change needed. service_configs keeps its trigger.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. the column
-- ---------------------------------------------------------------------------
ALTER TABLE public.properties
  ADD COLUMN IF NOT EXISTS grease_trap_size_gallons integer;

ALTER TABLE public.properties DROP CONSTRAINT IF EXISTS properties_grease_trap_size_chk;
ALTER TABLE public.properties
  ADD CONSTRAINT properties_grease_trap_size_chk
  CHECK (grease_trap_size_gallons IS NULL
         OR (grease_trap_size_gallons >= 0 AND grease_trap_size_gallons <= 20000));

COMMENT ON COLUMN public.properties.grease_trap_size_gallons IS
  'Grease trap capacity in gallons AT THIS PROPERTY. Authoritative as of 2026-08-13. '
  'Supersedes service_configs.equipment_size_gallons, which is kept in step by nothing and is still '
  'read by nine reporting views pending a separate repoint. We maintain this ourselves; permit GT '
  'sizes are unreliable.';

-- ---------------------------------------------------------------------------
-- 2. backfill
-- ---------------------------------------------------------------------------
-- 115 configs carry BOTH a capacity and a property_id. 6 carry a capacity with no property and
-- cannot be placed; they stay in service_configs only. Verified 0 properties would receive two
-- DIFFERENT capacities, so this is unambiguous.
UPDATE public.properties p
   SET grease_trap_size_gallons = sc.equipment_size_gallons
  FROM (
    SELECT DISTINCT ON (property_id) property_id, equipment_size_gallons
      FROM public.service_configs
     WHERE property_id IS NOT NULL
       AND equipment_size_gallons IS NOT NULL
       AND service_type = 'Pumping'
     ORDER BY property_id, id
  ) sc
 WHERE p.id = sc.property_id
   AND p.grease_trap_size_gallons IS DISTINCT FROM sc.equipment_size_gallons;

-- ---------------------------------------------------------------------------
-- 3. the app's own read: prefer the property value, fall back to the legacy one
-- ---------------------------------------------------------------------------
-- 🛑 COPIED from the live pg_get_viewdef output. The ONLY change is the
--    grease_capacity_gallons expression, which becomes COALESCE(new, old). Every other byte is the
--    previous definition. Backfill makes the two equal today, so this is a no-op on apply and stays
--    correct afterwards.
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
    COALESCE(p.grease_trap_size_gallons,
      ( SELECT sc.equipment_size_gallons
           FROM service_configs sc
          WHERE sc.property_id = p.id AND sc.service_type = 'Pumping'::text
          ORDER BY sc.id
         LIMIT 1)) AS grease_capacity_gallons,
    access_schedule
   FROM properties p;

-- ---------------------------------------------------------------------------
-- 4. the writer: one UPDATE, on the property. It can no longer 23505.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION client.update_property_capacity(p_property_id bigint, p_gallons integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_client bigint;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_gallons is not null and (p_gallons < 0 or p_gallons > 20000) then
    raise exception 'Capacity must be between 0 and 20,000 gallons.' using errcode = '22023';
  end if;

  -- 🛑 Writes public.properties, NOT service_configs. The previous body looked up service_configs by
  -- property and INSERTed when it found none, which violated UNIQUE(client_id, service_type) for any
  -- client that already had a Pumping config on a different property (209 properties, 184 clients).
  -- A single UPDATE on the property has no uniqueness to violate.
  update public.properties
     set grease_trap_size_gallons = p_gallons
   where id = p_property_id
  returning client_id into v_client;

  if v_client is null then
    raise exception 'property % not found', p_property_id using errcode = 'P0002';
  end if;

  return jsonb_build_object('property_id', p_property_id, 'gallons', p_gallons);
end
$function$;

REVOKE ALL ON FUNCTION client.update_property_capacity(bigint, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION client.update_property_capacity(bigint, integer) FROM anon;
GRANT EXECUTE ON FUNCTION client.update_property_capacity(bigint, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION client.update_property_capacity(bigint, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. assertions. EXERCISE the fix; do not assert the statements above back at ourselves.
-- ---------------------------------------------------------------------------
DO $$
DECLARE n int; v_before int; v_after int;
BEGIN
  -- (a) the backfill landed on the expected number of rows
  SELECT count(*) INTO n FROM public.properties WHERE grease_trap_size_gallons IS NOT NULL;
  IF n < 100 THEN RAISE EXCEPTION 'backfill looks wrong: only % properties carry a capacity', n; END IF;

  -- (b) every backfilled value matches its source exactly
  SELECT count(*) INTO n
    FROM public.properties p
    JOIN public.service_configs sc
      ON sc.property_id = p.id AND sc.service_type = 'Pumping'
   WHERE sc.equipment_size_gallons IS NOT NULL
     AND p.grease_trap_size_gallons IS DISTINCT FROM sc.equipment_size_gallons;
  IF n <> 0 THEN RAISE EXCEPTION '% properties disagree with their service_configs source', n; END IF;

  -- (c) 🛑 THE ACTUAL BUG. Property 659 (Aromas del Peru, client 450) is the row that 409'd. Writing a
  --     capacity to it must now succeed. This is the case the old body could not do.
  SELECT grease_trap_size_gallons INTO v_before FROM public.properties WHERE id = 659;
  UPDATE public.properties SET grease_trap_size_gallons = 895 WHERE id = 659;
  SELECT grease_trap_size_gallons INTO v_after FROM public.properties WHERE id = 659;
  IF v_after <> 895 THEN RAISE EXCEPTION 'the previously-failing property still cannot take a capacity'; END IF;
  UPDATE public.properties SET grease_trap_size_gallons = v_before WHERE id = 659;   -- restore

  -- (d) POSITIVE CONTROL: the CHECK still rejects an out-of-range value, so (c) is not passing
  --     because the constraint is inert.
  BEGIN
    UPDATE public.properties SET grease_trap_size_gallons = 999999 WHERE id = 659;
    RAISE EXCEPTION 'GUARD FAILED: the range CHECK accepted 999999';
  EXCEPTION
    WHEN check_violation THEN NULL;
    WHEN OTHERS THEN IF SQLERRM LIKE 'GUARD FAILED%' THEN RAISE; END IF;
  END;

  -- (e) the view serves the property value, and still falls back for a property that has only the
  --     legacy row (Aromas' billing property 521 keeps its 1200 through the fallback)
  SELECT grease_capacity_gallons INTO n FROM client.properties WHERE id = 521;
  IF n IS DISTINCT FROM 1200 THEN RAISE EXCEPTION 'the legacy fallback broke: property 521 reads %', n; END IF;

  -- (f) 🛑 THE COLUMN-GRANT TRAP. ADD COLUMN must not have handed `authenticated` a direct UPDATE.
  --     grease_trap_manhole_count and sample_port_count DO carry column grants, so this is a live
  --     pattern on this very table and worth asserting rather than assuming.
  IF has_column_privilege('authenticated','public.properties','grease_trap_size_gallons','UPDATE') THEN
    RAISE EXCEPTION 'authenticated can UPDATE the new column directly; it must go through the RPC';
  END IF;
  -- POSITIVE CONTROL: the same probe must return TRUE for a column that really is grantable.
  IF NOT has_column_privilege('authenticated','public.properties','grease_trap_manhole_count','UPDATE') THEN
    RAISE EXCEPTION 'CONTROL FAILED: the column-privilege probe is not discriminating';
  END IF;

  RAISE NOTICE 'OK: capacity is per-property, the 409 case now writes, fallback intact, no column grant';
END $$;

COMMIT;
