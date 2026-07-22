-- 2026-07-22c  DUMP app: passive device identification + activity trail (Fred).
--
-- ============================================================================
-- WHY + THE APPROACH (researched 2026-07-22, best practice)
-- ============================================================================
-- Goal: know which driver is on a phone WITHOUT a login, and keep an accountability trail of who did
-- each dump. The naive idea is a browser fingerprint, but current best practice says fingerprinting is
-- unreliable as an identity (accuracy < 50% beyond short windows; hashes drift; Safari/Brave inject
-- noise). So identity is a first-party PERSISTENT TOKEN the app stores in the phone's localStorage,
-- bound to the driver the first time they pick their name. The fingerprint (IP + screen + user-agent +
-- timezone + platform) is the BACKUP lane (re-recognize a phone whose storage was cleared) and
-- corroboration in the trail — never the primary id.
--
-- Fred's concern — "what if a driver picks the wrong name at first?" — is handled by TRANSPARENCY, not
-- by trusting the first pick: the app always shows "You're [Name] — Switch", the confirm is "as
-- [Name]", and every bind + every switch (old driver -> new) is logged here with the device, IP and
-- fingerprint. A mis-bound window is therefore always visible and reattributable, never silent.
--
-- Privacy posture (these are employees, so proportionality + transparency matter): minimal signals,
-- stored SERVER-SIDE only, purpose-limited to dump accountability. Nothing here goes in the (public)
-- repo — this is schema; the data lives only in Prod.
--
-- ============================================================================
-- TWO TABLES
-- ============================================================================
--  dump_device   — one row per phone (device_token PK) -> the currently-bound driver + last-seen
--                  fingerprint. Re-picking ("Switch") re-binds and bumps switch_count.
--  dump_activity — append-only trail: one row per app action (identify / bind / switch / create /
--                  confirm / release) with driver, device, dump visit, and the fingerprint signals.
--
-- AUDIT (ADR 010): both tables are OPTED OUT of audit.logs, documented here per the standing rule.
-- dump_activity IS the trail (auditing the audit is circular and doubles the write); dump_device's
-- only meaningful mutation — a driver switch — is itself recorded as a 'switch' row in dump_activity
-- with old+new driver. Neither holds customer/billing/DERM/secret data. If that ever changes, revisit.

-- ---------------------------------------------------------------------------
-- dump_device: phone -> driver binding + last fingerprint
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.dump_device (
  device_token   text PRIMARY KEY,                 -- random uuid the app stores in localStorage
  driver_id      bigint REFERENCES public.employees(id),
  first_seen     timestamptz NOT NULL DEFAULT now(),
  last_seen      timestamptz NOT NULL DEFAULT now(),
  switch_count   integer NOT NULL DEFAULT 0,        -- how many times this phone was re-bound to a new driver
  last_ip        text,
  last_user_agent text,
  last_screen    text,                              -- e.g. "390x844 @3x"
  last_timezone  text,
  last_platform  text
);
CREATE INDEX IF NOT EXISTS idx_dump_device_driver ON public.dump_device(driver_id);

-- ---------------------------------------------------------------------------
-- dump_activity: append-only per-action trail
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.dump_activity (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  at            timestamptz NOT NULL DEFAULT now(),
  action        text NOT NULL,                      -- identify | bind | switch | create | confirm | release
  driver_id     bigint REFERENCES public.employees(id),
  device_token  text,
  dump_visit_id bigint,                             -- nullable (identify/bind have no dump yet)
  ip            text,
  user_agent    text,
  screen        text,
  timezone      text,
  platform      text,
  detail        jsonb                               -- e.g. {"from_driver":12,"to_driver":35} on switch
);
CREATE INDEX IF NOT EXISTS idx_dump_activity_at ON public.dump_activity(at DESC);
CREATE INDEX IF NOT EXISTS idx_dump_activity_device ON public.dump_activity(device_token);
CREATE INDEX IF NOT EXISTS idx_dump_activity_dump_visit ON public.dump_activity(dump_visit_id) WHERE dump_visit_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Lock down: service_role only (the dump edge fn holds it; anon is read-only, must never touch these)
-- ---------------------------------------------------------------------------
ALTER TABLE public.dump_device   ENABLE ROW LEVEL SECURITY;   -- no policies => only service_role (bypasses RLS)
ALTER TABLE public.dump_activity ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.dump_device, public.dump_activity FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.dump_device, public.dump_activity TO service_role;

-- ---------------------------------------------------------------------------
-- dump_device_identify(token) — read-only: who is this phone bound to?
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.dump_device_identify(p_device_token text)
 RETURNS TABLE(driver_id bigint, full_name text, switch_count integer)
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT d.driver_id, e.full_name, d.switch_count
  FROM public.dump_device d
  LEFT JOIN public.employees e ON e.id = d.driver_id
  WHERE d.device_token = p_device_token;
$function$;

-- ---------------------------------------------------------------------------
-- dump_device_bind(token, driver, signals...) — upsert the binding, detect a SWITCH, log it.
-- Returns the effective driver + whether this call changed the bound driver (a switch).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.dump_device_bind(
  p_device_token text,
  p_driver_id bigint,
  p_ip text DEFAULT NULL,
  p_user_agent text DEFAULT NULL,
  p_screen text DEFAULT NULL,
  p_timezone text DEFAULT NULL,
  p_platform text DEFAULT NULL
)
 RETURNS TABLE(driver_id bigint, full_name text, was_switch boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_prev bigint;
  v_switch boolean;
BEGIN
  IF coalesce(btrim(p_device_token), '') = '' OR p_driver_id IS NULL THEN
    RAISE EXCEPTION 'dump_device_bind: device token and driver are required' USING ERRCODE = '22023';
  END IF;

  SELECT d.driver_id INTO v_prev FROM public.dump_device d WHERE d.device_token = p_device_token;
  v_switch := (v_prev IS NOT NULL AND v_prev IS DISTINCT FROM p_driver_id);

  INSERT INTO public.dump_device AS d
    (device_token, driver_id, last_seen, last_ip, last_user_agent, last_screen, last_timezone, last_platform)
  VALUES
    (p_device_token, p_driver_id, now(), p_ip, p_user_agent, p_screen, p_timezone, p_platform)
  ON CONFLICT (device_token) DO UPDATE SET
    driver_id     = EXCLUDED.driver_id,
    last_seen     = now(),
    switch_count  = d.switch_count + CASE WHEN d.driver_id IS DISTINCT FROM EXCLUDED.driver_id THEN 1 ELSE 0 END,
    last_ip       = COALESCE(EXCLUDED.last_ip, d.last_ip),
    last_user_agent = COALESCE(EXCLUDED.last_user_agent, d.last_user_agent),
    last_screen   = COALESCE(EXCLUDED.last_screen, d.last_screen),
    last_timezone = COALESCE(EXCLUDED.last_timezone, d.last_timezone),
    last_platform = COALESCE(EXCLUDED.last_platform, d.last_platform);

  INSERT INTO public.dump_activity (action, driver_id, device_token, ip, user_agent, screen, timezone, platform, detail)
  VALUES (CASE WHEN v_switch THEN 'switch' ELSE 'bind' END, p_driver_id, p_device_token,
          p_ip, p_user_agent, p_screen, p_timezone, p_platform,
          CASE WHEN v_switch THEN jsonb_build_object('from_driver', v_prev, 'to_driver', p_driver_id) ELSE NULL END);

  RETURN QUERY
  SELECT p_driver_id, (SELECT e.full_name FROM public.employees e WHERE e.id = p_driver_id), v_switch;
END;
$function$;

REVOKE ALL ON FUNCTION public.dump_device_identify(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.dump_device_bind(text, bigint, text, text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.dump_device_identify(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.dump_device_bind(text, bigint, text, text, text, text, text) TO service_role;
