-- 2026-07-24d  DUMP: drop the CLOSING_SOON tier — back to three states OPEN / AFTER_HOURS / CLOSED
--
-- WHY (Fred 2026-07-24): "we don't need CLOSING SOON — the other 3 (open, after hours, closed) are good
-- enough." The 30-min-before-last-intake heads-up added noise without value; a driver inside receiving
-- hours is simply OPEN. This reverts 2026-07-24c (which had split the last 30 min of the open window into
-- CLOSING_SOON) back to the exact pre-c function, so within-hours = OPEN, Homestead-outside-hours =
-- AFTER_HOURS (callable), everything-else = CLOSED (no-go). Frontend drops the CLOSING_SOON dialog variant
-- + the "Closing Soon" testing scenario in the same cycle.
--
-- Hours are unchanged (dump_site_hours): DH 05:00–22:00 last intake (after → AFTER_HOURS, callable
-- 786-268-5623, never no-go); DP Mon-Thu 07:45–17:00, Fri 07:45–15:30, Sat/Sun closed → outside = CLOSED.
-- Pure read function (STABLE, SECURITY DEFINER); no grants/audit impact. The edge fn only branches on
-- CLOSED (no-go gate) and never referenced CLOSING_SOON, so no redeploy is required.

CREATE OR REPLACE FUNCTION public.dump_site_status(p_dump_key text, p_arrival timestamp with time zone)
 RETURNS TABLE(status text, arrival_et timestamp without time zone, opens_at time without time zone, last_intake_at time without time zone, after_hours_phone text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH a AS (
    SELECT (p_arrival AT TIME ZONE 'America/New_York') AS et
  ),
  h AS (
    SELECT s.opens_at, s.closes_at, COALESCE(s.last_intake_at, s.closes_at) AS intake
    FROM public.dump_site_hours s, a
    WHERE s.dump_key = p_dump_key
      AND s.dow = EXTRACT(DOW FROM a.et)::int
  ),
  st AS (
    SELECT
      CASE
        -- OPEN is the ONLY positive case: inside [opens_at, last_intake] on this ET day.
        WHEN h.opens_at IS NOT NULL
             AND a.et::time >= h.opens_at
             AND a.et::time <= h.intake              THEN 'OPEN'
        -- Outside hours. Homestead has a sanctioned call-ahead path at ANY hour; Pompano has none.
        WHEN p_dump_key = 'DH'                       THEN 'AFTER_HOURS'
        ELSE 'CLOSED'
      END AS status,
      a.et AS arrival_et,
      h.opens_at,
      h.intake AS last_intake_at
    FROM a LEFT JOIN h ON true
  )
  SELECT
    st.status,
    st.arrival_et,
    st.opens_at,
    st.last_intake_at,
    -- Only ever alongside AFTER_HOURS, so status and phone can never contradict each other.
    CASE WHEN st.status = 'AFTER_HOURS' THEN '786-268-5623' ELSE NULL END AS after_hours_phone
  FROM st;
$function$;
