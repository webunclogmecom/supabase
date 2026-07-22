-- 2026-07-22  dump_manifest_handout_list: hide a handed-out visit UNTIL its manifest is filed,
--             not for a fixed 7 days.
--
-- ============================================================================
-- WHY (Fred, "go with #1")
-- ============================================================================
-- The crib sheet tells a dump driver which clients to write on the DERM Address manifest for this
-- load. The "ONCE" rule: a client handed to one driver must NOT show up on another dump's crib
-- sheet, or the same grease pickup gets written on two papers and DOUBLE-REPORTED to the city.
--
-- The old hide used a 7-day TTL: a visit reappeared 7 days after being handed out. But the real lag
-- from a completed visit to its manifest actually being filed is a MEDIAN of 19 days (p90 98 days),
-- and 64% of manifests are filed later than 7 days. So for most visits the lock lapsed while the
-- paper was still out at the city, and the client could be handed to a second dump. The TTL can
-- never be "right" because the filing lag is wildly variable.
--
-- ============================================================================
-- THE FIX: release on the REAL event, not a clock
-- ============================================================================
-- A visit leaves the outstanding list the instant its manifest is filed: the base view
-- public.manifest_pickable_visits already excludes any visit with a live manifest_visits link
-- (verified: 11 outstanding, 0 of them manifested). That filing is the true "done" signal, and it
-- matches Fred's paper flow exactly: driver writes the client -> paper goes to the city -> comes
-- back -> Diego reads it and uploads the manifest -> manifest_visits link appears -> visit drops off.
--
-- So the hand-out hide no longer needs a time limit at all. A visit handed out on ANY other dump
-- stays off this crib sheet until it is filed (at which point the base list drops it anyway). One
-- line removed: the `handed_at > now() - ttl` clause. Everything else is byte-for-byte identical.
--
-- p_ttl_days is kept in the signature (so no caller breaks; the edge fn passes only the default) but
-- is now IGNORED. Do not re-introduce a time-based expiry here: it is the exact bug this fixes.
--
-- ============================================================================
-- SAFETY: what happens to a handed-out visit whose paper is lost / never filed?
-- ============================================================================
-- It stays hidden from DRIVERS' crib sheets (correct: we don't want it re-handed blindly), but it
-- remains fully visible to the OFFICE: the browse path (VIEW ADDRESSES -> OLDER VISITS) reads
-- public.dump_outstanding_visits directly, which applies NO hand-out hide, and flags anything older
-- than 14 days as needs_office=true. So a stuck hand-out surfaces in the office queue for Diego to
-- resolve, rather than silently re-reporting. A cancelled dump also releases its hand-outs (the
-- dump_manifest_handout.dump_visit_id FK is ON DELETE CASCADE), so a soft-deleted dump frees them.
--
-- ⚠ CONSEQUENCE worth stating: without the 7-day auto-expiry, a hand-out recorded BY MISTAKE (the
-- list is recorded the moment the receipt screen is fetched) now sticks until filed instead of
-- clearing itself in a week. That is the open "#2" (record-on-tap + a release path); this migration
-- does not address it. The office browse remains the backstop until #2 is decided.
--
-- ============================================================================
-- The hand-out ledger is empty (0 rows) — the feature has never run for a real driver — so there is
-- no data to migrate and nothing to backfill. AUDIT (ADR 010): read-mostly SECDEF function, no table
-- structure change; dump_manifest_handout keeps its existing audit posture.

CREATE OR REPLACE FUNCTION public.dump_manifest_handout_list(p_driver_id bigint, p_dump_visit_id bigint, p_ttl_days integer DEFAULT 7)
 RETURNS TABLE(bucket text, visit_id bigint, client_code text, client_name text, address text, city text, visit_date date, completed_at timestamp with time zone, age_days integer, truck text, gdo_number text, needs_office boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- The RETURNS TABLE columns are also plpgsql variables, so unqualified references inside the query are
-- ambiguous and Postgres RAISES 42702 (hit on the ON CONFLICT target). Resolve to the COLUMN.
#variable_conflict use_column
DECLARE
  v_truck_id bigint;
  v_since    timestamptz;
BEGIN
  SELECT o.vehicle_id INTO v_truck_id FROM public.dump_driver_origin(p_driver_id) o;

  SELECT max(v.start_at) INTO v_since
  FROM public.visits v
  WHERE v.assigned_driver_id = p_driver_id
    AND v.client_id IN (76, 365)          -- 000-DP, 000-DH
    AND v.deleted_at IS NULL
    AND v.id <> p_dump_visit_id;

  v_since := COALESCE(v_since, now() - interval '7 days');

  RETURN QUERY
  WITH candidate AS (
    SELECT o.*
    FROM public.dump_outstanding_visits o
    -- Hidden while handed out on a DIFFERENT dump. NO time limit: it stays hidden until the manifest
    -- is filed, at which point manifest_pickable_visits (behind dump_outstanding_visits) drops it on
    -- its own. p_ttl_days is intentionally NOT used here (see migration header). Handing it out on
    -- THIS dump does not hide it, so re-opening THIS receipt shows the same list.
    WHERE NOT EXISTS (
      SELECT 1 FROM public.dump_manifest_handout h
      WHERE h.visit_id = o.visit_id
        AND h.dump_visit_id <> p_dump_visit_id
    )
  ),
  bucketed AS (
    SELECT c.*,
      CASE
        WHEN v_truck_id IS NOT NULL
         AND c.vehicle_id = v_truck_id
         AND c.completed_at IS NOT NULL
         AND c.completed_at > v_since
        THEN 'load' ELSE 'outstanding'
      END AS bucket
    FROM candidate c
  ),
  recorded AS (
    INSERT INTO public.dump_manifest_handout (visit_id, dump_visit_id, driver_id)
    SELECT b.visit_id, p_dump_visit_id, p_driver_id FROM bucketed b
    ON CONFLICT (visit_id, dump_visit_id) DO NOTHING
    RETURNING 1
  )
  SELECT b.bucket, b.visit_id, b.client_code, b.client_name, b.address, b.city, b.visit_date,
         b.completed_at, b.age_days, b.truck, b.gdo_number, b.needs_office
  FROM bucketed b
  ORDER BY (b.bucket = 'load') DESC,
           CASE WHEN b.bucket = 'load' THEN b.completed_at END ASC,
           CASE WHEN b.bucket <> 'load' THEN b.completed_at END DESC NULLS LAST;
END;
$function$;
