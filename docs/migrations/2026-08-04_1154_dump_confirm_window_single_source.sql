-- DUMP app: single-source the confirm window and expose how much of it is left
--
-- Fred 2026-08-04: "when a driver selects a visit for the manifest, it gets an interval, which right now
-- is 6 hours, in which said interval the visit is visible selected (by whom) to make sure the driver can
-- unselect it later on in case he made a mistake ... also in that 6 hour interval he can add a visit to
-- the current Dump Visit in case he forgot to add one too."
--
-- SCOPE, per Fred in the same message: this covers only visits the DUMP app can see. Visits already on a
-- generated DERM address sheet stay excluded by the 2026-08-03_1945 WHERE and are explicitly out of scope
-- ("the filtered visits ... which doesn't shows up on the app we don't care"). That WHERE is UNCHANGED.
--
-- TWO CHANGES.
--
-- 1. public.fn_dump_confirm_window() — the window in ONE place. It was a bare `interval '6 hours'` inside
--    the view, so changing it meant rewriting the view. "which right now is 6 hours" says plainly that it
--    will move; now it is a one-line CREATE OR REPLACE.
--    ⚠ Supabase's ALTER DEFAULT PRIVILEGES hands new public functions to anon/authenticated automatically,
--    so REVOKE FROM PUBLIC alone is not enough. Verified after applying:
--    anon=false, authenticated=false, service_role=true.
--
-- 2. Two APPENDED columns on public.dump_outstanding_visits (20 -> 22):
--      confirm_expires_at   = handed_at + fn_dump_confirm_window()
--      confirm_minutes_left = whole minutes remaining, floored at 0, NULL when unmarked
--    The view already exposed marked_by (who selected it) and marked_at, but the app never read marked_at,
--    so a driver could not tell how much of his window was left. Serving the remaining minutes from the
--    view keeps the arithmetic on one clock (the database's) instead of the phone's.
--
-- APPEND-ONLY. CREATE OR REPLACE VIEW rejects a changed column list (42P16) but silently accepts a
-- REORDER, so this was generated from the LIVE pg_get_viewdef immediately before applying, never from a
-- copy captured earlier, and the first 20 columns were checked to be byte-identical in order afterwards.
-- Grants are preserved by CREATE OR REPLACE and were re-checked (postgres, service_role, yannick_readonly).
--
-- ROLLED-BACK PROBE, every control fired:
--   baseline view rows                          0   (empty today: all 11 pickable visits are sheeted)
--   POSITIVE CONTROL, sheets soft-deleted      11   (the view CAN return rows, so the 0 above is data)
--   mark ~1h old                     not hidden, 255 min left, expires 20:08Z
--   same mark backdated to 7h            hidden,   0 min left
--   every mark aged past the window   total 11, flagged 6, app shows 5, badge 6
--   window widened to 12h in ONE place   same row un-hides, 300 min left  <- single-sourcing proven
-- Nothing committed: view still 0 rows, 17 live sheets, window still 06:00:00.
--
-- ADR 010 rule 8: no new table and no column on a table, view + function only -> no audit-trigger decision.
--
-- REVERSIBLE: drop the two appended columns and inline `interval '6 hours'` again.


BEGIN;

-- The confirm window in ONE place. Fred 2026-08-04: "it gets an interval, which right now is 6 hours".
-- Changing the window is now a single CREATE OR REPLACE here, not a view rewrite.
CREATE OR REPLACE FUNCTION public.fn_dump_confirm_window()
RETURNS interval LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path TO ''
AS $fn$ SELECT interval '6 hours' $fn$;

COMMENT ON FUNCTION public.fn_dump_confirm_window() IS
  'How long a driver-selected visit stays visible-and-changeable in the DUMP app before it hides. Single source of truth for the window; dump_outstanding_visits reads it. Fred 2026-08-04.';

-- Supabase default privileges auto-grant new functions to anon/authenticated/service_role, so REVOKE FROM
-- PUBLIC alone is not enough (repo memory: reference_supabase_function_default_privileges).
REVOKE ALL     ON FUNCTION public.fn_dump_confirm_window() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.fn_dump_confirm_window() TO service_role;

CREATE OR REPLACE VIEW public.dump_outstanding_visits AS
 SELECT p.visit_id,
    p.client_code,
    p.client_name,
    regexp_replace(p.address, ',\s*USA.*$'::text, ''::text, 'i'::text) AS address,
        CASE
            WHEN p.city IS NOT NULL AND regexp_replace(p.address, ',\s*USA.*$'::text, ''::text, 'i'::text) ~* ((',\s*'::text || p.city) || '(\s*,|\s*$)'::text) THEN NULL::text
            ELSE p.city
        END AS city,
    p.visit_date,
    p.completed_at,
    vis.vehicle_id,
    veh.name AS truck,
    gd.gdo_number,
    GREATEST(0, (now() AT TIME ZONE 'America/New_York'::text)::date - p.visit_date) AS age_days,
    GREATEST(0, (now() AT TIME ZONE 'America/New_York'::text)::date - p.visit_date) > 14 AS needs_office,
    h.visit_id IS NOT NULL AS on_sheet,
    emp.full_name AS marked_by,
    h.handed_at AS marked_at,
    vis.assigned_driver_id,
    p.county,
    fn_dump_county_bucket(p.county) AS county_bucket,
    h.visit_id IS NOT NULL AND h.handed_at < (now() - public.fn_dump_confirm_window()) AS confirmed_hidden,
    h.dump_visit_id AS marked_dump_visit_id,
    (h.handed_at + public.fn_dump_confirm_window()) AS confirm_expires_at,
        CASE
            WHEN h.handed_at IS NULL THEN NULL::integer
            ELSE GREATEST(0, (EXTRACT(epoch FROM ((h.handed_at + public.fn_dump_confirm_window()) - now())) / 60::numeric)::integer)
        END AS confirm_minutes_left
   FROM manifest_pickable_visits p
     JOIN visits vis ON vis.id = p.visit_id
     LEFT JOIN vehicles veh ON veh.id = vis.vehicle_id
     LEFT JOIN LATERAL ( SELECT fn_resolve_gdo_number(p.client_id, vis.property_id, p.visit_id) AS gdo_number) gd ON true
     LEFT JOIN dump_manifest_handout h ON h.visit_id = p.visit_id
     LEFT JOIN employees emp ON emp.id = h.driver_id
  WHERE NOT (EXISTS ( SELECT 1
           FROM derm.address_sheet_clients a
             JOIN derm.address_sheets s ON s.id = a.sheet_id
          WHERE a.visit_id = p.visit_id AND s.deleted_at IS NULL));

COMMIT;