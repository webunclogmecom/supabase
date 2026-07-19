-- 2026-07-18b dump_eta_cache: separate cached answers by routing mode
--
-- WHY: the ETA now picks its Google routing mode by the hour (see dump-visit-create). Overnight, when
-- the dump runs actually happen, traffic-aware routing tells us nothing a traffic-free route does not,
-- and it is what puts the call in Google's expensive Pro SKU ($10/1k, 5k free) instead of Essentials
-- ($5/1k, 10k free). So overnight we route TRAFFIC_UNAWARE and pay half for the same answer.
--
-- A traffic-aware answer and a traffic-free answer are NOT interchangeable, so they must not collide in
-- the cache: serving a cached 3 AM free-flow ETA to a 5 PM rush-hour request would understate the drive.
-- traffic_aware therefore joins the primary key.
--
-- Cache rows are disposable by definition, so this recreates the table rather than migrating rows.
--
-- AUDIT (ADR 010): opt-OUT, unchanged. Machine-written derived cache, no human-editable fields.

DROP TABLE IF EXISTS public.dump_eta_cache;

CREATE TABLE public.dump_eta_cache (
  dump_key      text         NOT NULL,
  lat_r         numeric(9,2) NOT NULL,   -- ~1.1 km cell; see the rounding note in dump-visit-create
  lng_r         numeric(9,2) NOT NULL,
  traffic_aware boolean      NOT NULL,
  eta_minutes   integer      NOT NULL,
  distance_mi   numeric(6,1),
  computed_at   timestamptz  NOT NULL DEFAULT now(),
  PRIMARY KEY (dump_key, lat_r, lng_r, traffic_aware)
);

COMMENT ON TABLE public.dump_eta_cache IS
  'Short-lived cache of Google Routes ETAs for the DUMP app, keyed by dump + origin cell (~1.1km) + '
  'routing mode. A hit costs neither a Routes call nor a daily-cap token. Reader applies the TTL. '
  'Audit-exempt (ADR 010).';

CREATE INDEX dump_eta_cache_computed_at_idx ON public.dump_eta_cache (computed_at);

ALTER TABLE public.dump_eta_cache ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.dump_eta_cache FROM PUBLIC;
REVOKE ALL ON TABLE public.dump_eta_cache FROM anon;
REVOKE ALL ON TABLE public.dump_eta_cache FROM authenticated;
GRANT ALL ON TABLE public.dump_eta_cache TO service_role;
