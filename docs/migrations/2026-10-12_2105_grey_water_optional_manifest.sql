-- ============================================================================
-- 2026-10-12_2105 Grey water visits can take an OPTIONAL manifest again (the picker offers them)
-- ============================================================================
-- THE ASK
--   Asked "Grey water: do you want an optional manifest for grey water visits?", Fred, 2026-10-12: "yes".
--   Same shape as lift station (2026-10-12_1600 part 6): grey water stays NOT DERM required, but the office can
--   still file a manifest on a grey water visit when one exists.
--
-- WHAT CHANGES
--   1. public.manifest_pickable_visits (DERM Tracker /upload matcher and "Adding a visit" picker; Stamp Studio
--      Add-client modal through derm.v_stamp_unlinked_visits) gains a grey water arm next to the lift station one:
--        derm_required IS NULL OR TRUE OR <lift station> OR <grey water>
--      so a completed, unlinked grey water visit stored FALSE is offered. Grey water left the picker on 2026-09-24
--      (_1220) only because it went FALSE; nobody asked for it to leave.
--      🛑 security_invoker=true is restated: CREATE OR REPLACE replaces reloptions (asserted below).
--   2. GRANT SELECT ON public.v_visit_grey_water_pumping TO authenticated: the picker runs as the caller, so the
--      DERM Tracker needs to read the rule view, exactly as v_visit_lift_station_pumping already allows. It exposes
--      visit_id and tier only. Its comment is corrected (it named the dropped derm.v_lwt_grey_water_unlinked and said
--      no app role needs a grant).
--
-- WHAT FILING ONE DOES (unchanged rules, read before relying on this)
--   - trg_zy_link_marks_derm_required turns the visit DERM required and LOCKED (set_visit_derm_required_manual),
--     like a person pressing "DERM required". Undo is the DERM Tracker's "Mark DERM Not Required".
--   - It still NEVER goes to the city: public.v_visit_not_for_city is built from the line items, not from
--     derm_required, and both mailers refuse those visits (2026-09-24_2110). v_visit_city_email_state reads
--     not_for_city for it.
--   - It reaches the Miami-Dade LWT monthly filing (derm.v_lwt_monthly_rows is built from manifest links) and
--     leaves derm.v_lwt_pickups_without_manifest. That is the point.
--   - It does NOT reach the GDO portal queue: v_derm_portal_fields needs fn_visit_is_gdo_reporting (a 27 line),
--     which 0 of the 97 grey water visits have ever had (measured 2026-10-12 21:00 ET).
--   - The DUMP app is unchanged: dump_outstanding_visits keeps `derm_required IS NOT FALSE` (1600 part 7), so a
--     driver cannot attach an optional manifest there; office only (asserted set-equal below).
--   ⚠ The picker still has no derm_required column, so the DERM Tracker cannot badge an optional visit (Stamp
--     Studio can: v_stamp_unlinked_visits has one). A mis-pick turns that visit TRUE and locked.
--
-- WHAT MOVES (measured 2026-10-12 ~21:00 ET): the picker 30 -> 40. The 10 added are all Miami-Dade:
--   214-MYK 6507, 6509, 6510, 6511; 320-MGF 8571, 8585, 8586, 8729; 239-COM 7085; 253-CG 5159.
--   30 grey water visits already have a manifest, 31 are stored TRUE (mixed services, already offered).
--
-- HOW TO RUN: one call (one transaction, COMMIT last). Rehearse with apply_sql_file.mjs <file> rehearse.
-- ROLLBACK: 2026-10-12_rollback_grey_water_optional_manifest.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';   -- the picker is read by the DERM Tracker; the checks below take ~0.3 s

DO $g$
BEGIN
  IF md5(pg_get_viewdef('public.manifest_pickable_visits'::regclass)) <> '09c9282e54442afea7c5412741e8476f' THEN
    RAISE EXCEPTION 'manifest_pickable_visits changed since 2026-10-12_1600: copy the live body again'; END IF;
END $g$;

CREATE TEMP TABLE _gw_mpv0   ON COMMIT DROP AS SELECT * FROM public.manifest_pickable_visits;
CREATE TEMP TABLE _gw_dov0   ON COMMIT DROP AS SELECT * FROM public.dump_outstanding_visits;
CREATE TEMP TABLE _gw_stamp0 ON COMMIT DROP AS SELECT * FROM derm.v_stamp_unlinked_visits;
CREATE TEMP TABLE _gw_want   ON COMMIT DROP AS
  SELECT v.id AS visit_id
    FROM public.visits v
   WHERE v.visit_status = 'completed' AND v.deleted_at IS NULL AND v.derm_required IS FALSE
     AND EXISTS (SELECT 1 FROM public.v_visit_grey_water_pumping g WHERE g.visit_id = v.id)
     AND NOT EXISTS (SELECT 1 FROM public.v_visit_lift_station_pumping l WHERE l.visit_id = v.id)
     AND NOT EXISTS (SELECT 1 FROM public.manifest_visits mv JOIN public.derm_manifests dm ON dm.id = mv.manifest_id
                      WHERE mv.visit_id = v.id AND dm.deleted_at IS NULL)
     AND NOT public.fn_is_non_customer(v.client_id, ARRAY['dump_site'::text]);

CREATE OR REPLACE VIEW public.manifest_pickable_visits WITH (security_invoker = true) AS
 SELECT visit_id, visit_date, start_at, completed_at, service_type, title, client_id, client_code, client_name,
        address, city, county, public.fn_dump_county_bucket(county) AS county_bucket
   FROM ( SELECT v.id AS visit_id, v.visit_date, v.start_at, v.completed_at, v.service_type, v.title,
                 c.id AS client_id, c.client_code, c.name AS client_name,
                 COALESCE(p.address, primary_p.address) AS address,
                 COALESCE(p.city, primary_p.city) AS city,
                 COALESCE(p.county, primary_p.county) AS county
            FROM public.visits v
            JOIN public.clients c ON c.id = v.client_id
            LEFT JOIN public.properties p ON p.id = v.property_id
            LEFT JOIN public.properties primary_p ON primary_p.client_id = v.client_id AND primary_p.is_primary = true
           WHERE v.visit_status = 'completed'
             AND (v.derm_required IS NULL OR v.derm_required = true
                  OR EXISTS (SELECT 1 FROM public.v_visit_lift_station_pumping lsp WHERE lsp.visit_id = v.id)
                  OR EXISTS (SELECT 1 FROM public.v_visit_grey_water_pumping gwp WHERE gwp.visit_id = v.id))
             AND v.deleted_at IS NULL
             AND NOT EXISTS (SELECT 1 FROM public.manifest_visits mv JOIN public.derm_manifests dm ON dm.id = mv.manifest_id
                              WHERE mv.visit_id = v.id AND dm.deleted_at IS NULL)) _pv
  WHERE NOT (client_id IN (SELECT clients.id FROM public.clients WHERE public.fn_is_non_customer(clients.id, ARRAY['dump_site'::text])));

COMMENT ON VIEW public.manifest_pickable_visits IS 'Completed, unlinked, live visits that can take a DERM manifest: DERM required or unknown, plus lift station and grey water pumping stored FALSE (the manifest is optional, Fred 2026-10-12; filing one turns the visit DERM required and locked; grey water still never goes to the city). security_invoker. Read by the DERM Tracker /upload matcher and "Adding a visit" picker, derm.v_stamp_unlinked_visits and public.dump_outstanding_visits (which leaves the optional ones out).';

GRANT SELECT ON public.v_visit_grey_water_pumping TO authenticated;
COMMENT ON VIEW public.v_visit_grey_water_pumping IS 'THE grey water pumping rule, once (2026-09-24): live (not soft-deleted) visits only; among the service lines a visit reaches, those on the nearest tier (own lines, else job, else invoice) include catalogue Pumping + Grey Water (03, 10) or a free-text grey water line (fn_line_item_is_free_text_grey_water); fee/admin codes abstain. `tier` is that nearest tier (1 own, 2 job, 3 invoice; 2026-09-24_2110). No status filter: consumers add their own. Read by customer.work_orders (Field Portal keeps grey water visible), derm.visits.grey_water_pumping (DERM Tracker bulk dialog), derm.v_lwt_pickups_without_manifest (LWT gap list), public.v_visit_not_for_city and public.manifest_pickable_visits (optional manifest, 2026-10-12_2105). SELECT to authenticated because that picker is security_invoker.';

DO $a$
DECLARE n_lost int; n_extra int; n_want int; n_dov int; n_stamp_lost int; n_stamp_extra int;
BEGIN
  IF (SELECT reloptions::text FROM pg_class WHERE oid = 'public.manifest_pickable_visits'::regclass) IS DISTINCT FROM '{security_invoker=true}' THEN
    RAISE EXCEPTION 'picker lost security_invoker'; END IF;
  SELECT count(*) INTO n_lost FROM (SELECT * FROM _gw_mpv0 EXCEPT SELECT * FROM public.manifest_pickable_visits) x;
  IF n_lost <> 0 THEN RAISE EXCEPTION 'picker lost or changed % rows', n_lost; END IF;
  SELECT count(*) INTO n_want FROM _gw_want;
  IF n_want = 0 THEN RAISE EXCEPTION 'no grey water visit to add: the control is empty, re-measure'; END IF;
  SELECT count(*) INTO n_extra FROM (
    (SELECT visit_id FROM public.manifest_pickable_visits EXCEPT SELECT visit_id FROM _gw_mpv0)
    EXCEPT SELECT visit_id FROM _gw_want) x;
  IF n_extra <> 0 THEN RAISE EXCEPTION 'picker gained % rows that are not grey water stored FALSE', n_extra; END IF;
  IF (SELECT count(*) FROM public.manifest_pickable_visits) <> (SELECT count(*) FROM _gw_mpv0) + n_want THEN
    RAISE EXCEPTION 'picker did not gain exactly the % grey water visits', n_want; END IF;
  SELECT count(*) INTO n_dov FROM ((SELECT * FROM _gw_dov0 EXCEPT SELECT * FROM public.dump_outstanding_visits)
                                    UNION ALL (SELECT * FROM public.dump_outstanding_visits EXCEPT SELECT * FROM _gw_dov0)) x;
  IF n_dov <> 0 THEN RAISE EXCEPTION 'DUMP lists moved by % rows', n_dov; END IF;
  SELECT count(*) INTO n_stamp_lost FROM (SELECT visit_id FROM _gw_stamp0 EXCEPT SELECT visit_id FROM derm.v_stamp_unlinked_visits) x;
  SELECT count(*) INTO n_stamp_extra FROM ((SELECT visit_id FROM derm.v_stamp_unlinked_visits EXCEPT SELECT visit_id FROM _gw_stamp0)
                                           EXCEPT SELECT visit_id FROM _gw_want) x;
  IF n_stamp_lost <> 0 OR n_stamp_extra <> 0 THEN
    RAISE EXCEPTION 'Stamp Studio list: lost %, gained % outside the grey water set', n_stamp_lost, n_stamp_extra; END IF;
  -- the app role can read the picker (it would raise "permission denied" without the grant)
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM count(*) FROM public.manifest_pickable_visits;
  EXECUTE 'RESET ROLE';
END $a$;

COMMIT;
