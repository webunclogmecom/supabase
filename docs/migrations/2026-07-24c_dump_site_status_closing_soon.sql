-- 2026-07-24c  DUMP three-tier hours model: add the CLOSING_SOON tier to dump_site_status
--
-- WHY (Fred 2026-07-24): the DUMP app needs an explicit three-tier read of "can I dump here right now"
-- so the phone can (a) let normal dumps through, (b) warn on the about-to-close / after-hours window,
-- and (c) HARD-BLOCK a fully-closed no-go dump instead of creating a phantom visit. The no-go block and
-- the after-hours call-ahead already fall out of the existing statuses:
--   * OPEN        -> normal, create freely.
--   * AFTER_HOURS -> Homestead after last intake: sanctioned call-ahead path (786-268-5623). Still go.
--   * CLOSED      -> Pompano outside hours (no after-hours drop-off): NO-GO. The app blocks creation.
-- This migration adds the missing middle rung on the OPEN side:
--   * CLOSING_SOON -> inside hours but within 30 min of last intake. Still open (create allowed), but the
--     app shows a "closes soon, head straight there" heads-up so a driver 45 min out does not make a
--     wasted drive. It is NOT a call-ahead and NOT a block — purely a warning tier.
--
-- Hours are unchanged and already correct in dump_site_hours (verified 2026-07-24):
--   * DH (Homestead): every day 05:00 open, 22:00 last intake, 22:30 close. After 22:00 -> AFTER_HOURS
--     (callable) — Homestead is never CLOSED/no-go.
--   * DP (Pompano): Mon-Thu 07:45-17:00, Fri 07:45-15:30, Sat/Sun closed. Outside hours -> CLOSED (no-go);
--     the whole Fri-15:30 -> Mon-07:45 window is no-go. Pompano has no after-hours phone.
--
-- CLOSING_SOON carries NO after_hours_phone (it is still open, no call needed); only AFTER_HOURS does, so
-- status and phone still can never contradict. Pure read function (STABLE, SECURITY DEFINER) — no grants
-- change, no audit impact.

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
        -- Inside [opens_at, last_intake] on this ET day = open. Split the last 30 min out as CLOSING_SOON
        -- so the app can nudge without blocking. Everything else is the untouched OPEN case.
        WHEN h.opens_at IS NOT NULL
             AND a.et::time >= h.opens_at
             AND a.et::time <= h.intake THEN
          CASE
            WHEN a.et::time >= (h.intake - interval '30 minutes') THEN 'CLOSING_SOON'
            ELSE 'OPEN'
          END
        -- Outside hours. Homestead has a sanctioned call-ahead path at ANY hour (the whole point of the
        -- after-hours flow). Pompano has none -> CLOSED is the no-go tier the app hard-blocks on.
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
