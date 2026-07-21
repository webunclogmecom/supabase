-- 2026-07-21c  dump_site_status: Homestead call-ahead must survive midnight
--
-- ============================================================================
-- THE BUG
-- ============================================================================
-- The CASE evaluated "too early for today's open" BEFORE it ever reached the Homestead
-- call-ahead branch:
--
--     WHEN a.et::time < h.opens_at THEN 'CLOSED'     -- 00:00..04:59 short-circuits here
--     ...
--     WHEN p_dump_key = 'DH'      THEN 'AFTER_HOURS' -- unreachable before 05:00
--
-- So once the ET date rolled at midnight, every Homestead arrival until 05:00 was classified
-- as "too early", and the AFTER_HOURS banner (with the phone and the procedure) was reachable
-- only in a two-hour sliver, 22:00 to 23:59. Measured on Prod before the fix:
--
--     Sun 23:59 -> AFTER_HOURS + phone
--     Mon 00:01 -> CLOSED
--     Mon 02:00 -> CLOSED
--     Mon 04:59 -> CLOSED
--     Mon 05:00 -> OPEN
--
-- ============================================================================
-- WHY IT MATTERS: THIS IS THE MIDDLE OF THE SHIFT, NOT AN EDGE CASE
-- ============================================================================
-- Commercial overnight routes run ~8PM into the next ~6AM. Completed visits in the 120 days to
-- 2026-07-21, by ET hour: 00h=48, 01h=51, 02h=44, 03h=40, 04h=36. That is 219 completions inside
-- the dead window, against 86 across the whole 20:00-23:59 band. Real Homestead dumps already sit
-- in it (visit 7280 at 00:59 ET on 2026-07-21, visit 7094 at 04:45 ET). The app told those drivers
-- "Closed when you arrive", with no number and no procedure, at a site that would have taken them.
--
-- ============================================================================
-- THE RULE, FROM THE PEOPLE WHO OWN IT (Slack #C0BD3VDPB9S, 2026-07-17)
-- ============================================================================
-- Diego, 20:06:  "Homestead: Monday-Sunday 5:00AM - 10:30PM"
-- Yan,   20:11:  "Homestead stop receiving ppl at 10pm"
-- Diego, 20:34:  "In case you arrive after 10 pm, you call this phone number 786-268-5623 and
--                 request an after-hours dump for UNCLOGME. You need to give them an ETA, and they
--                 will give you approval on the phone. Remember, you must always call up front."
--
-- The two accounts agree: Yan supplied the 22:00 intake boundary, Diego restated the rule already
-- carrying that correction and added the procedure hanging off it. NEITHER PUT A MIDNIGHT CUTOFF
-- ON IT. "After 10 pm" means after 10 pm; a 02:00 arrival is after 10 pm. The gate close (22:30)
-- and the last intake (22:00) remain separate columns because they are separate facts.
--
-- ============================================================================
-- WHAT CHANGES
-- ============================================================================
-- Status is now derived from a single positive test: OPEN iff the arrival falls inside
-- [opens_at, last_intake]. Everything else is outside hours, and what "outside hours" means then
-- depends only on whether the site has a sanctioned call-ahead path. Homestead does, Pompano does
-- not. Ordering can no longer hide the after-hours branch behind the pre-opening branch, because
-- there is no longer a pre-opening branch.
--
-- Second fix: after_hours_phone was a CASE on dump_key ALONE, so the payload could read
-- {status: 'CLOSED', after_hours_phone: '786-268-5623'} - a self-contradicting pair. The UI happens
-- to ignore it today, but any future consumer treating "phone is present" as "call-ahead applies"
-- would get the opposite answer from status. The phone is now returned only with AFTER_HOURS.
--
-- DELIBERATE: a Homestead row missing from dump_site_hours now yields AFTER_HOURS rather than
-- CLOSED. Homestead operates 7 days, so a missing row is a data fault, and the safe failure for a
-- driver already at the gate is "call this number", not "go home". Pompano keeps failing to CLOSED
-- because it has no call-ahead path to offer.
--
-- NOT CHANGED: the dump_site_hours data (14 rows, untouched), the OPEN/AFTER_HOURS/CLOSED
-- vocabulary (no new status values, so no app change is required for this fix), the signature,
-- volatility, security, search_path, or grants.
--
-- STILL MISSING FROM DIEGO'S PROCEDURE, deliberately out of scope here and reported separately:
-- the banner never tells the driver to "request an after-hours dump for UNCLOGME", and nothing in
-- the system represents "they will give you approval on the phone". Those are app-copy and
-- data-model changes, not a status-logic fix.
--
-- AUDIT (ADR 010): read-only function, no table touched, audit posture unchanged.

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
        -- Outside hours. Homestead has a sanctioned call-ahead path at ANY hour, including after
        -- midnight, which is the whole point of this migration. Pompano has none.
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
