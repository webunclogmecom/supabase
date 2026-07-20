-- 2026-07-20 dump_site_hours + dump_site_status
--
-- WHY: Diego posted the disposal-site hours in Slack (thread 1784311568.829669, 2026-07-17) and Yan
-- corrected that Homestead "stop receiving ppl at 10pm" even though the gate closes 22:30. Arriving
-- outside those hours is not a minor inconvenience: Homestead requires the driver to CALL 786-268-5623
-- UP FRONT, request an after-hours dump for UNCLOGME, and GIVE THEM AN ETA to get phone approval. The
-- DUMP app now computes an ETA, so it can tell him this before he drives.
--
-- WHY A TABLE AND NOT A CASE STATEMENT: Pompano's Friday close (15:30) differs from Mon-Thu (17:00) and
-- it is shut all weekend, while Homestead needs THREE times (opens 05:00, stops receiving 22:00, gate
-- 22:30). Encoding that as branches guarantees someone "simplifies" it and it is silently wrong every
-- Friday. As data it is one row per site per weekday and the odd cases are visible.
--
-- last_intake_at is the honest field: Homestead's 22:00 is when they STOP RECEIVING, which is the time
-- that matters to a driver, not the 22:30 gate close.
--
-- AUDIT (ADR 010): opt-OUT. Reference/config data with no customer, billing, DERM or secret content.
-- It is human-editable in principle, so if hours ever start changing often, revisit and add the trigger.

CREATE TABLE IF NOT EXISTS public.dump_site_hours (
  dump_key       text    NOT NULL CHECK (dump_key IN ('DH','DP')),
  dow            int     NOT NULL CHECK (dow BETWEEN 0 AND 6),  -- 0 = Sunday, matches EXTRACT(DOW)
  opens_at       time    NULL,   -- NULL = closed all day
  closes_at      time    NULL,
  last_intake_at time    NULL,   -- last time they accept a truck; defaults to closes_at when NULL
  PRIMARY KEY (dump_key, dow)
);

COMMENT ON TABLE public.dump_site_hours IS
  'Receiving hours for the two disposal sites, from Diego + Yan in Slack 2026-07-17. NULL opens_at means '
  'closed that day. last_intake_at is when they stop accepting trucks (Homestead 22:00) which can be '
  'earlier than the gate close (22:30). Audit-exempt per ADR 010.';

ALTER TABLE public.dump_site_hours ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.dump_site_hours FROM PUBLIC;
REVOKE ALL ON TABLE public.dump_site_hours FROM anon;
REVOKE ALL ON TABLE public.dump_site_hours FROM authenticated;
GRANT ALL ON TABLE public.dump_site_hours TO service_role;

-- Homestead: every day 05:00-22:30, stops receiving 22:00.
INSERT INTO public.dump_site_hours (dump_key, dow, opens_at, closes_at, last_intake_at)
SELECT 'DH', d, TIME '05:00', TIME '22:30', TIME '22:00' FROM generate_series(0,6) d
ON CONFLICT (dump_key, dow) DO UPDATE
  SET opens_at=EXCLUDED.opens_at, closes_at=EXCLUDED.closes_at, last_intake_at=EXCLUDED.last_intake_at;

-- Pompano: Mon-Thu 07:45-17:00, Fri 07:45-15:30, Sat+Sun closed.
INSERT INTO public.dump_site_hours (dump_key, dow, opens_at, closes_at, last_intake_at) VALUES
  ('DP', 0, NULL, NULL, NULL),                              -- Sunday closed
  ('DP', 1, TIME '07:45', TIME '17:00', TIME '17:00'),
  ('DP', 2, TIME '07:45', TIME '17:00', TIME '17:00'),
  ('DP', 3, TIME '07:45', TIME '17:00', TIME '17:00'),
  ('DP', 4, TIME '07:45', TIME '17:00', TIME '17:00'),
  ('DP', 5, TIME '07:45', TIME '15:30', TIME '15:30'),       -- Friday closes early
  ('DP', 6, NULL, NULL, NULL)                                -- Saturday closed
ON CONFLICT (dump_key, dow) DO UPDATE
  SET opens_at=EXCLUDED.opens_at, closes_at=EXCLUDED.closes_at, last_intake_at=EXCLUDED.last_intake_at;

-- Verdict for an arrival instant. Everything is evaluated in ET so it is DST-safe: we convert the
-- timestamptz to America/New_York once and read the weekday and wall-clock from THAT.
DROP FUNCTION IF EXISTS public.dump_site_status(text, timestamptz);

CREATE FUNCTION public.dump_site_status(p_dump_key text, p_arrival timestamptz)
RETURNS TABLE (
  status            text,   -- 'OPEN' | 'AFTER_HOURS' | 'CLOSED'
  arrival_et        timestamp,
  opens_at          time,
  last_intake_at    time,
  after_hours_phone text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH a AS (
    SELECT (p_arrival AT TIME ZONE 'America/New_York') AS et
  ),
  h AS (
    SELECT s.opens_at, s.closes_at, COALESCE(s.last_intake_at, s.closes_at) AS intake
    FROM public.dump_site_hours s, a
    WHERE s.dump_key = p_dump_key
      AND s.dow = EXTRACT(DOW FROM a.et)::int
  )
  SELECT
    CASE
      WHEN h.opens_at IS NULL THEN 'CLOSED'                       -- closed all day
      WHEN a.et::time < h.opens_at THEN 'CLOSED'                  -- too early
      WHEN a.et::time <= h.intake THEN 'OPEN'
      -- Past last intake. Homestead has a sanctioned call-ahead path; Pompano does not.
      WHEN p_dump_key = 'DH' THEN 'AFTER_HOURS'
      ELSE 'CLOSED'
    END AS status,
    a.et AS arrival_et,
    h.opens_at,
    h.intake AS last_intake_at,
    CASE WHEN p_dump_key = 'DH' THEN '786-268-5623' ELSE NULL END AS after_hours_phone
  FROM a LEFT JOIN h ON true;
$$;

-- Default privileges auto-grant anon/authenticated on new public functions, so REVOKE FROM PUBLIC alone
-- is NOT enough (see memory: reference_supabase_function_default_privileges).
REVOKE ALL ON FUNCTION public.dump_site_status(text, timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.dump_site_status(text, timestamptz) FROM anon;
REVOKE ALL ON FUNCTION public.dump_site_status(text, timestamptz) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.dump_site_status(text, timestamptz) TO service_role;
