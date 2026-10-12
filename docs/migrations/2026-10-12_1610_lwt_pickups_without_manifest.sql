-- ============================================================================
-- 2026-10-12_1610 derm.v_lwt_pickups_without_manifest: ONE list of pickups missing from the LWT filing
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-12, on the grey water list (derm.v_lwt_grey_water_unlinked) and lift station stopping being DERM
--   required (2026-10-12_1600): "yes put the LS in that list, but then we'd need to change that list to be more
--   semantic, have better naming", then "go ahead with that name".
--   derm.v_lwt_monthly_rows (the Miami-Dade Liquid Waste Transporter monthly filing, served to Jonathan's bot by
--   rpa-derm-monthly) is built from MANIFEST LINKS. A pickup whose service no longer needs DERM, and that got no
--   (optional) manifest, therefore never reaches the filing. This view lists them, by pickup type.
--
-- WHAT CHANGES
--   NEW derm.v_lwt_pickups_without_manifest: one row per (visit, pickup type), columns
--     visit_id, pickup_type ('grey water' | 'lift station'), client_code, client_name, visit_date, county,
--     derm_required, not_required_since (the day that pickup type stopped being DERM required).
--   Grey water rows are exactly derm.v_lwt_grey_water_unlinked (since 2026-09-24, public.v_visit_grey_water_pumping,
--   completed, no live manifest link); the VERIFY proves the two sets equal before the old view is dropped.
--   Lift station rows use public.v_visit_lift_station_pumping (2026-10-12_1600), completed, no live manifest link,
--   since the day 1600 was applied (read from the audit row of the 04/11 catalogue change, max(changed_at), so a
--   rollback and re-apply uses the latest date).
--   DROP derm.v_lwt_grey_water_unlinked: no view, function, app or edge function reads it (pg_depend, pg_proc,
--   grep of Supabase, Building Apps and the GDO bot repo, 2026-10-12); only docs and past migrations name it.
--   This replaces the optional 2026-10-12_1605 (derm.v_lwt_lift_station_unlinked), which was never applied.
--   A row with derm_required TRUE also does work that still needs a manifest (it is in DERM Tracker Missing Docs).
--
-- AUDIT-TRAIL STANDING CHECK (rule 8): read-only views, no table, nothing to audit.
-- GRANTS: owner-rights view, SELECT to service_role only, as the view it replaces (derm default privileges grant
--   authenticated by name: revoked and asserted).
-- ROLLBACK: recreate derm.v_lwt_grey_water_unlinked from docs/migrations/2026-09-24_2110_grey_water_not_for_city.sql
--   (2026-09-24 body), then DROP VIEW derm.v_lwt_pickups_without_manifest. Roll this file back BEFORE the 1600
--   rollback: this view reads public.v_visit_lift_station_pumping, so the 1600 rollback cannot drop that view first.
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pre$
BEGIN
  IF to_regclass('public.v_visit_lift_station_pumping') IS NULL THEN
    RAISE EXCEPTION '1610: apply 2026-10-12_1600 first (public.v_visit_lift_station_pumping is missing)'; END IF;
  IF to_regclass('derm.v_lwt_pickups_without_manifest') IS NOT NULL THEN
    RAISE EXCEPTION '1610: derm.v_lwt_pickups_without_manifest already exists'; END IF;
  IF to_regclass('derm.v_lwt_lift_station_unlinked') IS NOT NULL THEN
    RAISE EXCEPTION '1610: derm.v_lwt_lift_station_unlinked exists (1605 was applied): fold it in by hand first'; END IF;
  IF md5(pg_get_viewdef('derm.v_lwt_grey_water_unlinked'::regclass)) <> 'ed335c18d8d3d8f037b273204144f544' THEN
    RAISE EXCEPTION '1610: derm.v_lwt_grey_water_unlinked changed since this file was written: re-read it'; END IF;
  IF EXISTS (SELECT 1 FROM pg_depend d JOIN pg_rewrite rw ON rw.oid = d.objid
              WHERE d.refobjid = 'derm.v_lwt_grey_water_unlinked'::regclass AND rw.ev_class <> d.refobjid)
     OR EXISTS (SELECT 1 FROM pg_proc WHERE prosrc LIKE '%v_lwt_grey_water_unlinked%') THEN
    RAISE EXCEPTION '1610: something reads derm.v_lwt_grey_water_unlinked: do not drop it'; END IF;
END $pre$;

DO $mk$
DECLARE v_ls_since date;
BEGIN
  SELECT (max(changed_at) AT TIME ZONE 'America/New_York')::date INTO v_ls_since FROM audit.logs
   WHERE table_schema = 'public' AND table_name = 'service_line_items' AND operation = 'UPDATE'
     AND new_row->>'code' IN ('04','11') AND old_row->>'requires_derm' = 'true' AND new_row->>'requires_derm' = 'false';
  IF v_ls_since IS NULL THEN RAISE EXCEPTION '1610: no audit row of the 04/11 catalogue change: was 1600 applied?'; END IF;

  EXECUTE format($v$CREATE VIEW derm.v_lwt_pickups_without_manifest AS
WITH unlinked AS (
  SELECT v.id, v.client_id, v.property_id, v.visit_date, v.derm_required
    FROM public.visits v
   WHERE v.deleted_at IS NULL AND v.visit_status = 'completed'
     AND NOT EXISTS (SELECT 1 FROM public.manifest_visits mv JOIN public.derm_manifests m ON m.id = mv.manifest_id
                      WHERE mv.visit_id = v.id AND m.deleted_at IS NULL)
), typed AS (
  SELECT u.*, 'grey water'::text AS pickup_type, DATE '2026-09-24' AS not_required_since
    FROM unlinked u
   WHERE u.visit_date >= DATE '2026-09-24'
     AND EXISTS (SELECT 1 FROM public.v_visit_grey_water_pumping g WHERE g.visit_id = u.id)
  UNION ALL
  SELECT u.*, 'lift station'::text, %L::date
    FROM unlinked u
   WHERE u.visit_date >= %L::date
     AND EXISTS (SELECT 1 FROM public.v_visit_lift_station_pumping l WHERE l.visit_id = u.id)
)
SELECT t.id AS visit_id, t.pickup_type, c.client_code, c.name AS client_name, t.visit_date, p.county,
       t.derm_required, t.not_required_since
  FROM typed t
  LEFT JOIN public.clients c ON c.id = t.client_id
  LEFT JOIN public.properties p ON p.id = t.property_id$v$, v_ls_since, v_ls_since);

  EXECUTE format('COMMENT ON VIEW derm.v_lwt_pickups_without_manifest IS %L',
    'Completed pickups whose service is no longer DERM required (grey water since 2026-09-24, lift station since '
    || v_ls_since || ') and that have no manifest link, so they are NOT on the Miami-Dade LWT monthly filing '
    || '(derm.v_lwt_monthly_rows is built from manifest links). One row per visit and pickup_type. A row with '
    || 'derm_required true also does work that still needs a manifest. Open question for Jonathan and Fred: must these '
    || 'pickups be filed? Empty means nothing is missing. Replaces derm.v_lwt_grey_water_unlinked (2026-10-12_1610).');
END $mk$;

REVOKE ALL ON derm.v_lwt_pickups_without_manifest FROM PUBLIC, anon, authenticated;
GRANT SELECT ON derm.v_lwt_pickups_without_manifest TO service_role;

DO $verify$
DECLARE n_old int; n_new_gw int; n_diff int; n_bad int;
BEGIN
  -- the grey water half equals the view it replaces, both ways
  SELECT count(*) INTO n_old FROM derm.v_lwt_grey_water_unlinked;
  SELECT count(*) INTO n_new_gw FROM derm.v_lwt_pickups_without_manifest WHERE pickup_type = 'grey water';
  SELECT count(*) INTO n_diff FROM (
    (SELECT visit_id, client_code, client_name, visit_date, county, derm_required FROM derm.v_lwt_grey_water_unlinked
     EXCEPT SELECT visit_id, client_code, client_name, visit_date, county, derm_required
              FROM derm.v_lwt_pickups_without_manifest WHERE pickup_type = 'grey water')
    UNION ALL
    (SELECT visit_id, client_code, client_name, visit_date, county, derm_required
       FROM derm.v_lwt_pickups_without_manifest WHERE pickup_type = 'grey water'
     EXCEPT SELECT visit_id, client_code, client_name, visit_date, county, derm_required FROM derm.v_lwt_grey_water_unlinked)) d;
  IF n_diff <> 0 OR n_old <> n_new_gw THEN
    RAISE EXCEPTION 'VERIFY: grey water rows differ from derm.v_lwt_grey_water_unlinked (% vs %, % differ)', n_old, n_new_gw, n_diff; END IF;
  IF n_old < 1 THEN RAISE EXCEPTION 'VERIFY control: the grey water list is empty, so the equality proves nothing'; END IF;
  -- every lift station row is a completed, unlinked visit in the lift station rule
  SELECT count(*) INTO n_bad FROM derm.v_lwt_pickups_without_manifest l JOIN public.visits v ON v.id = l.visit_id
   WHERE l.pickup_type = 'lift station'
     AND (v.visit_status <> 'completed' OR v.deleted_at IS NOT NULL
          OR NOT EXISTS (SELECT 1 FROM public.v_visit_lift_station_pumping x WHERE x.visit_id = v.id)
          OR EXISTS (SELECT 1 FROM public.manifest_visits mv JOIN public.derm_manifests m ON m.id = mv.manifest_id
                      AND m.deleted_at IS NULL WHERE mv.visit_id = v.id));
  IF n_bad <> 0 THEN RAISE EXCEPTION 'VERIFY: % lift station rows are not completed, unlinked lift station visits', n_bad; END IF;
  -- only the two pickup types
  IF EXISTS (SELECT 1 FROM derm.v_lwt_pickups_without_manifest WHERE pickup_type NOT IN ('grey water', 'lift station')) THEN
    RAISE EXCEPTION 'VERIFY: unexpected pickup_type'; END IF;
  -- grants, as the roles
  IF has_table_privilege('anon', 'derm.v_lwt_pickups_without_manifest', 'SELECT')
     OR has_table_privilege('authenticated', 'derm.v_lwt_pickups_without_manifest', 'SELECT')
     OR NOT has_table_privilege('service_role', 'derm.v_lwt_pickups_without_manifest', 'SELECT') THEN
    RAISE EXCEPTION 'VERIFY: grants are not service_role only: %',
      (SELECT relacl::text FROM pg_class WHERE oid = 'derm.v_lwt_pickups_without_manifest'::regclass); END IF;
  RAISE NOTICE '1610: % grey water + % lift station rows', n_new_gw,
    (SELECT count(*) FROM derm.v_lwt_pickups_without_manifest WHERE pickup_type = 'lift station');
END $verify$;

DROP VIEW derm.v_lwt_grey_water_unlinked;

COMMIT;
