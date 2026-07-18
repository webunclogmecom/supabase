-- 2026-07-18 dump_eta_cache: make repeated dump taps free
--
-- WHY: measured 2026-07-18 against the live endpoint using the daily counter as a money meter, tapping
-- the SAME dump 6 times in a row cost 6 Google Routes calls, not 1. The in-function 20-second throttle
-- (an in-memory Map in dump-visit-create) is effectively dead in production: Supabase edge instances do
-- not share or persist memory between requests, so the cache almost never hits. Every tap was $0.01.
--
-- This is the SAME lesson as dump_eta_usage: if it must hold across instances, it lives in Postgres.
--
-- WHAT: a short-lived cache of computed ETAs keyed by (dump, rounded origin). Coordinates are rounded to
-- 3 decimal places (~110 m), which does two useful things:
--   1. repeat taps from the same spot reuse one answer instead of re-billing;
--   2. DIFFERENT drivers sitting at the same yard share one answer, because their origins round to the
--      same cell. That is the common case at shift start.
-- A truck that has genuinely moved more than ~110 m lands in a new cell and correctly gets a fresh ETA,
-- so this never serves a stale distance to someone who has actually driven off.
--
-- TTL is applied by the reader (5 minutes), not stored here, so it stays one tunable constant in the
-- edge function. Traffic does not shift meaningfully inside 5 minutes on a 40-minute haul.
--
-- A cache HIT costs neither money nor a daily-cap token, so idle browsing can no longer drain the $2/day
-- budget that real dump runs need.
--
-- AUDIT (ADR 010): opt-OUT. Machine-written derived cache, no human-editable fields, no customer,
-- billing, DERM or secret data. Rows are disposable by definition.

CREATE TABLE IF NOT EXISTS public.dump_eta_cache (
  dump_key     text        NOT NULL,
  lat_r        numeric(9,3) NOT NULL,
  lng_r        numeric(9,3) NOT NULL,
  eta_minutes  integer     NOT NULL,
  distance_mi  numeric(6,1),
  computed_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (dump_key, lat_r, lng_r)
);

COMMENT ON TABLE public.dump_eta_cache IS
  'Short-lived cache of Google Routes ETAs for the DUMP app, keyed by dump + origin rounded to ~110m. '
  'A hit costs neither a Routes call nor a daily-cap token. Reader applies the TTL. Audit-exempt (ADR 010).';

CREATE INDEX IF NOT EXISTS dump_eta_cache_computed_at_idx ON public.dump_eta_cache (computed_at);

ALTER TABLE public.dump_eta_cache ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.dump_eta_cache FROM PUBLIC;
REVOKE ALL ON TABLE public.dump_eta_cache FROM anon;
REVOKE ALL ON TABLE public.dump_eta_cache FROM authenticated;
GRANT ALL ON TABLE public.dump_eta_cache TO service_role;
