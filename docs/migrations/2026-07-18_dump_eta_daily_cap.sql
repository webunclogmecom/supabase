-- 2026-07-18 dump_eta_usage + dump_eta_take_token: hard daily spend cap for the DUMP ETA
--
-- WHY: the ETA feature calls the Google Routes API, billed at the Pro SKU ($10 per 1,000 requests, so
-- $0.01 per call). Fred (2026-07-18) wants a hard guarantee that it can never cost more than $2.00/day,
-- i.e. at most 200 Routes calls per day. The Google Cloud Console quota was the first choice, but it
-- could not be set reliably, so the cap lives here where we control and can test it.
--
-- WHY DB-BACKED AND NOT IN-MEMORY: edge function instances do not share memory. An in-process counter
-- bounds each instance, not the total, so N cold-started instances would each happily count to 200. A
-- single row in Postgres is the only place all instances agree.
--
-- HOW: dump_eta_take_token is an atomic take-or-refuse. The INSERT ... ON CONFLICT DO UPDATE carries a
-- WHERE on the existing row, so when the day's count has already reached the cap the UPDATE matches
-- nothing, RETURNING yields no row, and the function returns NULL. The caller treats NULL as "refused"
-- and returns no ETA. Because it is one statement it is safe under concurrency: two simultaneous callers
-- cannot both take the last token.
--
-- The day key is the ET calendar date, matching how the rest of this codebase reasons about operating
-- days. A token is taken BEFORE the Routes call, so it counts ATTEMPTS, not successes. That is the
-- deliberate direction for a spend guard: better to slightly over-count than to under-count and bill.
-- Cache/throttle hits never reach this function, so they cost neither money nor a token.
--
-- AUDIT (ADR 010): opt-OUT. This is a machine-written counter with no human-editable fields and no
-- customer, billing, DERM or secret data. Auditing every increment would add a row per API call for no
-- investigative value. Documented here as the rule requires.

CREATE TABLE IF NOT EXISTS public.dump_eta_usage (
  day          date PRIMARY KEY,
  calls        integer NOT NULL DEFAULT 0,
  last_call_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.dump_eta_usage IS
  'Per-ET-day counter of Google Routes API calls made by the DUMP ETA feature. Enforces a hard daily '
  'spend cap (see public.dump_eta_take_token). Machine-written only; audit-exempt per ADR 010.';

-- Belt and braces: RLS on with NO policies means anon/authenticated cannot read or write this even if a
-- future default-privilege grant sneaks in. service_role (the edge function) bypasses RLS.
ALTER TABLE public.dump_eta_usage ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.dump_eta_usage FROM PUBLIC;
REVOKE ALL ON TABLE public.dump_eta_usage FROM anon;
REVOKE ALL ON TABLE public.dump_eta_usage FROM authenticated;
GRANT ALL ON TABLE public.dump_eta_usage TO service_role;

-- Returns the day's new call count when a token is granted, or NULL when the cap is already reached.
DROP FUNCTION IF EXISTS public.dump_eta_take_token(integer);

CREATE FUNCTION public.dump_eta_take_token(p_cap integer)
RETURNS integer
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  INSERT INTO public.dump_eta_usage AS u (day, calls, last_call_at)
  VALUES ((now() AT TIME ZONE 'America/New_York')::date, 1, now())
  ON CONFLICT (day) DO UPDATE
     SET calls = u.calls + 1,
         last_call_at = now()
   WHERE u.calls < p_cap
  RETURNING u.calls;
$$;

-- Default privileges auto-grant anon/authenticated on new public functions, so REVOKE FROM PUBLIC alone
-- is NOT enough (see memory: reference_supabase_function_default_privileges).
REVOKE ALL ON FUNCTION public.dump_eta_take_token(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.dump_eta_take_token(integer) FROM anon;
REVOKE ALL ON FUNCTION public.dump_eta_take_token(integer) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.dump_eta_take_token(integer) TO service_role;
