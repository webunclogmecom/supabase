-- 2026-07-20 dump_manifest_handout + dump_manifest_handout_list
--
-- WHY (Yan, Slack 2026-07-17): when a driver logs a dump he should be told which pumped locations to
-- write on his DERM manifest, and "app can ONLY give the visits to add to manifest ONCE".
--
-- ⚠ THIS FEATURE WRITES NO DERM DATA. It never inserts, updates or deletes public.manifest_visits or
-- public.derm_manifests. Fred confirmed (2026-07-20) the driver fills the paper sheet AT the dump, so the
-- app is a read-only crib sheet. That is what makes this safe, and it is not a style preference:
--   1. manifest_visits.manifest_id is NOT NULL with an FK to derm_manifests, so recording a "claim" there
--      would require a placeholder manifest. A placeholder has a NULL ticket key, and
--      trg_ab_link_one_white RETURNS EARLY WITHOUT CHECKING when the ticket key is NULL. The obvious
--      implementation would therefore disable the exact guard that keeps double-reporting at zero
--      (verified 2026-07-20: zero visits sit on more than one live ticket key).
--   2. trg_ac_link_visit_not_after_dump RAISES when visit_date > dump_ticket_date + 1, which would put a
--      raw Postgres error in front of a driver at 2 AM.
--   3. manifest_visits has exactly two columns and no timestamp, so a bad claim could never be aged out.
-- The ledger below is OUR bookkeeping, not compliance data. If it is wrong the worst case is a visit
-- shown twice or hidden for a few days; DERM Tracker and Stamp Studio still read the truth from
-- manifest_visits.
--
-- AUDIT (ADR 010): opt-OUT. Machine-written bookkeeping, no human-editable fields, and explicitly NOT a
-- compliance table (it records what the app displayed, never what was reported to DERM).

CREATE TABLE IF NOT EXISTS public.dump_manifest_handout (
  visit_id      bigint      NOT NULL REFERENCES public.visits(id) ON DELETE CASCADE,
  dump_visit_id bigint      NOT NULL REFERENCES public.visits(id) ON DELETE CASCADE,
  driver_id     bigint      NULL,
  handed_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (visit_id, dump_visit_id)
);

COMMENT ON TABLE public.dump_manifest_handout IS
  'Ledger of which outstanding visits the DUMP app displayed to a driver for a given dump run. Enforces '
  '"hand out once" WITHOUT touching DERM tables. A visit hidden by this ledger returns to the list after '
  'HANDOUT_TTL_DAYS if it still has no live manifest link. Audit-exempt per ADR 010.';

CREATE INDEX IF NOT EXISTS dump_manifest_handout_visit_idx
  ON public.dump_manifest_handout (visit_id, handed_at DESC);

ALTER TABLE public.dump_manifest_handout ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.dump_manifest_handout FROM PUBLIC;
REVOKE ALL ON TABLE public.dump_manifest_handout FROM anon;
REVOKE ALL ON TABLE public.dump_manifest_handout FROM authenticated;
GRANT ALL ON TABLE public.dump_manifest_handout TO service_role;

-- Returns the two buckets AND records the hand-out, atomically, in one call.
--
-- Bucket 'load'        = this driver's truck (resolved from live GPS), completed since his previous dump.
-- Bucket 'outstanding' = everything else still undocumented (older, or another truck). Fred 2026-07-20:
--                        "an extra list down for the previous of the last dump that hasn't been
--                        documented yet".
--
-- HIDE RULE: a visit is hidden when it was handed out on a DIFFERENT dump within p_ttl_days. Rows handed
-- out on THIS dump are always returned, so re-opening the receipt or double-tapping shows the same list
-- instead of an alarming empty screen. "Still unfiled" needs no check because manifest_pickable_visits
-- already excludes anything with a live manifest link.
DROP FUNCTION IF EXISTS public.dump_manifest_handout_list(bigint, bigint, int);
DROP FUNCTION IF EXISTS public.dump_manifest_handout_list(bigint, bigint);

CREATE FUNCTION public.dump_manifest_handout_list(
  p_driver_id     bigint,
  p_dump_visit_id bigint,
  p_ttl_days      int DEFAULT 7
)
RETURNS TABLE (
  bucket       text,
  visit_id     bigint,
  client_code  text,
  client_name  text,
  address      text,
  city         text,
  visit_date   date,
  completed_at timestamptz,
  age_days     int,
  truck        text,
  gdo_number   text,
  needs_office boolean
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
-- The RETURNS TABLE columns (visit_id, bucket, ...) are also plpgsql variables, so any unqualified
-- reference to them inside the query body is ambiguous and Postgres RAISES 42702 (hit on first apply,
-- specifically on the ON CONFLICT target). Resolve ambiguity to the COLUMN. Renaming the OUT params
-- would fix it too but would change the response field names the app reads.
#variable_conflict use_column
DECLARE
  v_truck_id bigint;
  v_since    timestamptz;
BEGIN
  -- Truck currently reporting GPS for this driver (the ETA feature's resolver, ~3ms).
  SELECT o.vehicle_id INTO v_truck_id FROM public.dump_driver_origin(p_driver_id) o;

  -- His PREVIOUS dump run, excluding the one just created. NULL when he has never dumped.
  SELECT max(v.start_at) INTO v_since
  FROM public.visits v
  WHERE v.assigned_driver_id = p_driver_id
    AND v.client_id IN (76, 365)          -- 000-DP, 000-DH
    AND v.deleted_at IS NULL
    AND v.id <> p_dump_visit_id;

  -- No previous dump: fall back to a 7 day window so a first-ever run is neither empty nor unbounded.
  v_since := COALESCE(v_since, now() - interval '7 days');

  RETURN QUERY
  WITH candidate AS (
    SELECT
      p.visit_id, p.client_code, p.client_name,
      -- The driver COPIES this onto a DERM sheet, so it must read cleanly. Two fixes, both observed on
      -- the live list: some addresses carry a ", Boca Raton, Florida 33432, USA" tail (strip from USA
      -- onward, same rule the route screen already uses), and when the address already names the city as
      -- its own comma-separated segment, return city NULL so the app does not append it twice
      -- ("...Boca Raton, Florida 33432, USA, Boca Raton"). A street merely CONTAINING the city name,
      -- like "105 East Hallandale Beach Boulevard" in Hallandale Beach, is not a duplicate and keeps its
      -- city, which is why the test is on a comma-delimited segment rather than a bare substring.
      regexp_replace(p.address, ',\s*USA.*$', '', 'i') AS address,
      CASE
        WHEN p.city IS NOT NULL
         AND regexp_replace(p.address, ',\s*USA.*$', '', 'i') ~* (',\s*' || p.city || '(\s*,|\s*$)')
        THEN NULL ELSE p.city
      END AS city,
      p.visit_date, p.completed_at,
      vis.vehicle_id,
      veh.name AS truck_name,
      gd.gdo_number,
      GREATEST(0, ((now() AT TIME ZONE 'America/New_York')::date - p.visit_date))::int AS age_days
    FROM public.manifest_pickable_visits p
    JOIN public.visits vis ON vis.id = p.visit_id
    LEFT JOIN public.vehicles veh ON veh.id = vis.vehicle_id
    -- ⚠ LATERAL top-1, NOT a plain join: public.gdos has MULTIPLE rows per client (009-CN has 4,
    -- including a comma-joined "GDO-a, GDO-b, GDO-c" string). A plain join duplicates list rows and the
    -- driver sees the same restaurant several times. Only a clean single ACTIVE permit is surfaced.
    LEFT JOIN LATERAL (
      SELECT g.gdo_number
      FROM public.gdos g
      WHERE g.client_id = p.client_id
        AND g.status = 'ACTIVE'
        AND g.gdo_number ~ '^GDO-[0-9]+$'
      ORDER BY g.gdo_number
      LIMIT 1
    ) gd ON true
    WHERE NOT EXISTS (
      SELECT 1 FROM public.dump_manifest_handout h
      WHERE h.visit_id = p.visit_id
        AND h.dump_visit_id <> p_dump_visit_id
        AND h.handed_at > now() - make_interval(days => p_ttl_days)
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
         b.completed_at, b.age_days, b.truck_name, b.gdo_number, (b.age_days > 14) AS needs_office
  FROM bucketed b
  -- 'load' first, then oldest-first within the load (the order he pumped them), newest-first for the rest.
  ORDER BY (b.bucket = 'load') DESC,
           CASE WHEN b.bucket = 'load' THEN b.completed_at END ASC,
           CASE WHEN b.bucket <> 'load' THEN b.completed_at END DESC NULLS LAST;
END;
$$;

REVOKE ALL ON FUNCTION public.dump_manifest_handout_list(bigint, bigint, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.dump_manifest_handout_list(bigint, bigint, int) FROM anon;
REVOKE ALL ON FUNCTION public.dump_manifest_handout_list(bigint, bigint, int) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.dump_manifest_handout_list(bigint, bigint, int) TO service_role;
