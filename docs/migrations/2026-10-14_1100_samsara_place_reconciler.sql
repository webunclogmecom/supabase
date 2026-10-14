-- ============================================================================
-- 2026-10-14_1100 Time on site, step 7: a Samsara Place edit no longer moves our map point
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-14: "go ahead with step 7" (plan samsara-checks/time_on_site_fix_plan_2026-10-13.md, outside the
--   repos; default approved: "build the reconciler from the geofencing plan before any Place edit"). This is Phase 4 of
--   docs/reference/samsara-geofencing-plan.md: the inbound address webhook records the difference, a person resolves.
--
-- WHY
--   webhook-samsara's handleAddress overwrote the client's primary property (latitude, longitude, address, geofence)
--   from every Samsara Place edit, and on a missing link it guessed the client by a fuzzy name match. Addresses and map
--   points are Jobber's (CLAUDE.md rule 4). Measured over the 497 live service properties: one had drifted, 210 (105-CU),
--   moved 13.4 km to 955 Alton Road by the 2026-10-08 Place edit while Jobber still says 1195 East 11th Avenue, Hialeah
--   (the hourly Jobber sweep only rewrites a property when Jobber's own copy changes, so it never came back). Two more
--   (91, 102) took Samsara's formatted address text and a point a few metres off.
--
-- WHAT CHANGES
--   1. public.samsara_place_observations: one row per Place event (append-only evidence: the Place, the property it
--      resolves to, our point at that moment, distance, inside or not, verdict same / moved / unlinked / deleted).
--      Audit opt-out (rule 8): an append-only sync log, each row is itself the record. service_role only.
--   2. public.fn_record_samsara_place(p_address jsonb, p_action text): the reconciler. Resolves the Place to a property
--      by its property link (bare or addr_ id), else its client link (client with one live service property), else the
--      client code the name starts with ("166-SPA Spaguetto"; proposed only, never linked). Writes ONLY the observation.
--      webhook-samsara calls it instead of writing properties.
--   3. public.fn_link_samsara_place(p_samsara_address_id, p_property_id): the explicit linking step for a new Place.
--   4. public.v_samsara_place_review: the latest observation per Place that needs a person (moved, unlinked, deleted).
--   5. Properties 210, 91, 102 back to Jobber's street and point (labelled samsara-reconcile).
--   6. Samsara property links left on property rows deleted by the 2026-09-22 one-property-per-address cleanup:
--      33 repointed to the client's one live service property, 31 removed because that property already carries the same
--      Place (entity_source_links has no audit trigger: the rows are in backups/2026-10-14_properties_geo_and_samsara_
--      links_before_step7.json, workspace, outside the repos). 3 others are left for a person (review list).
--   Nothing reaches Jobber or Samsara.
-- ROLLBACK: redeploy webhook-samsara's previous handleAddress, drop the objects above, restore the links and the three
--   properties from the backup file.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

CREATE TABLE public.samsara_place_observations (
  id bigserial PRIMARY KEY,
  samsara_address_id text NOT NULL,
  action text NOT NULL CHECK (action IN ('created', 'updated', 'deleted')),
  observed_at timestamptz NOT NULL DEFAULT now(),
  place_name text,
  place_formatted_address text,
  place_latitude numeric,
  place_longitude numeric,
  place_geofence jsonb,
  property_id bigint REFERENCES public.properties(id) ON DELETE RESTRICT,
  client_id bigint REFERENCES public.clients(id) ON DELETE RESTRICT,
  match_method text NOT NULL CHECK (match_method IN ('property_link', 'client_link', 'client_code_prefix', 'none')),
  our_latitude numeric,
  our_longitude numeric,
  our_address text,
  distance_m numeric,
  our_point_inside boolean,
  verdict text NOT NULL CHECK (verdict IN ('same', 'moved', 'unlinked', 'deleted')),
  note text);
CREATE INDEX samsara_place_observations_place_idx ON public.samsara_place_observations (samsara_address_id, observed_at DESC);
ALTER TABLE public.samsara_place_observations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.samsara_place_observations FROM public, anon, authenticated;
REVOKE ALL ON SEQUENCE public.samsara_place_observations_id_seq FROM public, anon, authenticated;
GRANT SELECT, INSERT ON public.samsara_place_observations TO service_role;
COMMENT ON TABLE public.samsara_place_observations IS 'Every Samsara Place (address) event as observed, compared with our property (2026-10-14_1100). Append-only evidence; written only by fn_record_samsara_place. Our map point is Jobber''s and is never changed from here. Audit opt-out: an append-only sync log.';

CREATE FUNCTION public.fn_point_in_samsara_geofence(p_lat numeric, p_lng numeric, p_geofence jsonb)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE SET search_path TO ''
AS $f$
DECLARE v jsonb := p_geofence->'polygon'->'vertices'; n int; i int; j int; inside boolean := false;
        xi numeric; yi numeric; xj numeric; yj numeric;
BEGIN
  IF p_lat IS NULL OR p_lng IS NULL OR p_geofence IS NULL THEN RETURN NULL; END IF;
  IF p_geofence ? 'circle' THEN
    RETURN ops.fn_haversine_km(p_lat, p_lng, (p_geofence#>>'{circle,latitude}')::numeric, (p_geofence#>>'{circle,longitude}')::numeric) * 1000
           <= (p_geofence#>>'{circle,radiusMeters}')::numeric;
  END IF;
  n := coalesce(jsonb_array_length(v), 0);
  IF n < 3 THEN RETURN NULL; END IF;
  j := n - 1;
  FOR i IN 0 .. n - 1 LOOP   -- ray casting on (longitude, latitude)
    xi := (v->i->>'longitude')::numeric; yi := (v->i->>'latitude')::numeric;
    xj := (v->j->>'longitude')::numeric; yj := (v->j->>'latitude')::numeric;
    IF ((yi > p_lat) <> (yj > p_lat)) AND (p_lng < (xj - xi) * (p_lat - yi) / (yj - yi) + xi) THEN inside := NOT inside; END IF;
    j := i;
  END LOOP;
  RETURN inside;
END $f$;
REVOKE ALL ON FUNCTION public.fn_point_in_samsara_geofence(numeric, numeric, jsonb) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_point_in_samsara_geofence(numeric, numeric, jsonb) TO service_role;

CREATE FUNCTION public.fn_record_samsara_place(p_address jsonb, p_action text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $f$
DECLARE
  v_sid text := p_address->>'id';
  v_name text := coalesce(p_address->>'name', p_address->>'formattedAddress');
  v_lat numeric := coalesce((p_address->>'latitude')::numeric, (p_address#>>'{geofence,circle,latitude}')::numeric);
  v_lng numeric := coalesce((p_address->>'longitude')::numeric, (p_address#>>'{geofence,circle,longitude}')::numeric);
  v_prop bigint; v_client bigint; v_method text := 'none'; v_verdict text; v_note text; v_code text;
  v_plat numeric; v_plng numeric; v_paddr text; v_pclient bigint; v_dist numeric; v_inside boolean; v_id bigint; n int;
BEGIN
  IF v_sid IS NULL THEN RAISE EXCEPTION 'a Samsara address without an id' USING ERRCODE = '22023'; END IF;
  -- 1. the Place's own property link (bare or addr_ id), live rows only
  SELECT e.entity_id INTO v_prop FROM public.entity_source_links e JOIN public.properties pp ON pp.id = e.entity_id
   WHERE e.entity_type = 'property' AND e.source_system = 'samsara' AND regexp_replace(e.source_id, '^addr_', '') = v_sid
     AND pp.deleted_at IS NULL ORDER BY e.id LIMIT 1;
  IF v_prop IS NOT NULL THEN v_method := 'property_link'; END IF;
  -- 2. its client link: the client's one live service property
  IF v_prop IS NULL THEN
    SELECT e.entity_id INTO v_client FROM public.entity_source_links e
     WHERE e.entity_type = 'client' AND e.source_system = 'samsara' AND e.source_id = v_sid LIMIT 1;
    IF v_client IS NOT NULL THEN
      v_method := 'client_link';
      SELECT count(*), min(id) INTO n, v_prop FROM public.properties
       WHERE client_id = v_client AND deleted_at IS NULL AND NOT is_billing;
      IF n <> 1 THEN v_note := format('the client has %s live properties: link the Place to one', n); v_prop := NULL; END IF;
    END IF;
  END IF;
  -- 3. a new Place named after a client code ("166-SPA Spaguetto"): proposed, never linked automatically
  IF v_prop IS NULL AND v_client IS NULL THEN
    v_code := upper(substring(v_name FROM '^\s*([0-9]{3}-[A-Za-z0-9]+)'));
    IF v_code IS NOT NULL THEN
      SELECT id INTO v_client FROM public.clients WHERE upper(client_code) = v_code LIMIT 1;
      IF v_client IS NOT NULL THEN
        v_method := 'client_code_prefix';
        SELECT count(*), min(id) INTO n, v_prop FROM public.properties
         WHERE client_id = v_client AND deleted_at IS NULL AND NOT is_billing;
        IF n <> 1 THEN v_prop := NULL; END IF;
        v_note := 'not linked yet: confirm with fn_link_samsara_place' || CASE WHEN n <> 1 THEN format(' (the client has %s live properties)', n) ELSE '' END;
      END IF;
    END IF;
  END IF;
  IF v_prop IS NOT NULL THEN
    SELECT client_id, latitude, longitude, address INTO v_pclient, v_plat, v_plng, v_paddr FROM public.properties WHERE id = v_prop;
    v_client := coalesce(v_client, v_pclient);
    IF v_plat IS NOT NULL AND v_lat IS NOT NULL THEN
      v_dist := round((ops.fn_haversine_km(v_plat, v_plng, v_lat, v_lng) * 1000)::numeric, 1);
    END IF;
    v_inside := public.fn_point_in_samsara_geofence(v_plat, v_plng, p_address->'geofence');
  END IF;
  v_verdict := CASE WHEN p_action = 'deleted' THEN 'deleted'
                    WHEN v_method IN ('none', 'client_code_prefix') OR v_prop IS NULL THEN 'unlinked'
                    -- same unless our point is outside the Place AND over 150 m from its centre (a polygon drawn up to
                    -- our point can leave it a few cm outside); the outside flag stays on the row
                    WHEN v_inside OR v_dist <= 150 THEN 'same'
                    ELSE 'moved' END;
  INSERT INTO public.samsara_place_observations (samsara_address_id, action, place_name, place_formatted_address,
         place_latitude, place_longitude, place_geofence, property_id, client_id, match_method, our_latitude, our_longitude,
         our_address, distance_m, our_point_inside, verdict, note)
  VALUES (v_sid, p_action, v_name, p_address->>'formattedAddress', v_lat, v_lng, p_address->'geofence', v_prop, v_client,
          v_method, v_plat, v_plng, v_paddr, v_dist, v_inside, v_verdict, v_note)
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('observation_id', v_id, 'property_id', v_prop, 'client_id', v_client, 'match_method', v_method,
                            'verdict', v_verdict, 'distance_m', v_dist, 'inside', v_inside, 'note', v_note);
END $f$;
REVOKE ALL ON FUNCTION public.fn_record_samsara_place(jsonb, text) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_record_samsara_place(jsonb, text) TO service_role;
COMMENT ON FUNCTION public.fn_record_samsara_place(jsonb, text) IS 'The Samsara Place reconciler (2026-10-14_1100), called by webhook-samsara for AddressCreated/Updated/Deleted: resolves the Place to a property and records an observation. It never writes properties or links: our map point is Jobber''s.';

CREATE FUNCTION public.fn_link_samsara_place(p_samsara_address_id text, p_property_id bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $f$
DECLARE v_name text; v_existing text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.properties WHERE id = p_property_id AND deleted_at IS NULL AND NOT is_billing) THEN
    RAISE EXCEPTION 'property % is not a live service property', p_property_id USING ERRCODE = '22023'; END IF;
  SELECT source_id INTO v_existing FROM public.entity_source_links
   WHERE entity_type = 'property' AND entity_id = p_property_id AND source_system = 'samsara';
  IF v_existing IS NOT NULL THEN
    RAISE EXCEPTION 'property % already carries Samsara Place %', p_property_id, v_existing USING ERRCODE = '22023'; END IF;
  IF EXISTS (SELECT 1 FROM public.entity_source_links e JOIN public.properties pp ON pp.id = e.entity_id
              WHERE e.entity_type = 'property' AND e.source_system = 'samsara' AND pp.deleted_at IS NULL
                AND regexp_replace(e.source_id, '^addr_', '') = p_samsara_address_id) THEN
    RAISE EXCEPTION 'Samsara Place % is already linked to a live property', p_samsara_address_id USING ERRCODE = '22023'; END IF;
  SELECT place_name INTO v_name FROM public.samsara_place_observations
   WHERE samsara_address_id = p_samsara_address_id ORDER BY observed_at DESC LIMIT 1;
  INSERT INTO public.entity_source_links (entity_type, entity_id, source_system, source_id, source_name, match_method)
  VALUES ('property', p_property_id, 'samsara', p_samsara_address_id, v_name, 'manual');
  RETURN jsonb_build_object('linked', true, 'property_id', p_property_id, 'samsara_address_id', p_samsara_address_id);
END $f$;
REVOKE ALL ON FUNCTION public.fn_link_samsara_place(text, bigint) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_link_samsara_place(text, bigint) TO service_role;

CREATE VIEW public.v_samsara_place_review AS
SELECT DISTINCT ON (o.samsara_address_id) o.*
  FROM public.samsara_place_observations o
 ORDER BY o.samsara_address_id, o.observed_at DESC, o.id DESC;
REVOKE ALL ON public.v_samsara_place_review FROM public, anon, authenticated;
GRANT SELECT ON public.v_samsara_place_review TO service_role;
COMMENT ON VIEW public.v_samsara_place_review IS 'The latest observation of each Samsara Place (2026-10-14_1100). A verdict of moved, unlinked or deleted needs a person.';

-- 5. the three properties back to Jobber's street and point
CREATE TEMP TABLE _jb ON COMMIT DROP AS
SELECT p.id, r.data#>>'{address,street}' AS street, (r.data#>>'{address,coordinates,latitude}')::numeric AS lat,
       (r.data#>>'{address,coordinates,longitude}')::numeric AS lng
  FROM public.properties p
  JOIN public.entity_source_links e ON e.entity_type = 'property' AND e.entity_id = p.id AND e.source_system = 'jobber'
   AND e.source_id NOT LIKE '%\_billing'
  JOIN raw.jobber_pull_properties r ON r.data->>'id' = e.source_id
 WHERE p.id IN (210, 91, 102);
DO $c$ BEGIN
  IF (SELECT count(*) FROM _jb WHERE street IS NOT NULL AND lat IS NOT NULL) <> 3 THEN RAISE EXCEPTION 'Jobber copy missing'; END IF;
END $c$;
SELECT set_config('request.headers', jsonb_build_object('x-app-source', 'samsara-reconcile',
  'x-change-reason', 'Address and map point put back to Jobber''s: a Samsara Place edit had overwritten them (time on site plan step 7).')::text, true);
UPDATE public.properties p SET address = j.street, latitude = j.lat, longitude = j.lng
  FROM _jb j WHERE p.id = j.id;
SELECT set_config('request.headers', '', true);

-- 6. Samsara property links on deleted rows
CREATE TEMP TABLE _sl ON COMMIT DROP AS
SELECT e.id AS link_id, e.entity_id AS pid, regexp_replace(e.source_id, '^addr_', '') AS sid, pp.client_id,
       (SELECT array_agg(t.id) FROM public.properties t WHERE t.client_id = pp.client_id AND t.deleted_at IS NULL AND NOT t.is_billing) AS twins
  FROM public.entity_source_links e JOIN public.properties pp ON pp.id = e.entity_id
 WHERE e.entity_type = 'property' AND e.source_system = 'samsara' AND pp.deleted_at IS NOT NULL;
CREATE TEMP TABLE _sl2 ON COMMIT DROP AS
SELECT s.*, CASE WHEN cardinality(s.twins) = 1 THEN s.twins[1] END AS twin,
       (SELECT regexp_replace(e2.source_id, '^addr_', '') FROM public.entity_source_links e2
         WHERE e2.entity_type = 'property' AND e2.source_system = 'samsara' AND cardinality(s.twins) = 1 AND e2.entity_id = s.twins[1]) AS twin_sid
  FROM _sl s;
DO $c$ BEGIN
  IF (SELECT count(*) FROM _sl2 WHERE twin IS NOT NULL AND twin_sid IS NULL) <> 33
     OR (SELECT count(*) FROM _sl2 WHERE twin_sid = sid) <> 31 THEN
    RAISE EXCEPTION 'the link counts moved since 2026-10-14 10:50 (expected 33 to repoint, 31 duplicates): re-measure';
  END IF;
END $c$;
UPDATE public.entity_source_links e SET entity_id = s.twin, match_method = 'repointed_2026_10_14'
  FROM _sl2 s WHERE e.id = s.link_id AND s.twin IS NOT NULL AND s.twin_sid IS NULL;
DELETE FROM public.entity_source_links e USING _sl2 s
 WHERE e.id = s.link_id AND s.twin_sid = s.sid
   AND EXISTS (SELECT 1 FROM public.properties pp WHERE pp.id = e.entity_id AND pp.deleted_at IS NOT NULL);

DO $v$
DECLARE r jsonb; ev record; n int;
BEGIN
  -- V1 the three properties match Jobber again
  IF EXISTS (SELECT 1 FROM public.properties p JOIN _jb j ON j.id = p.id
              WHERE p.address <> j.street OR p.latitude <> j.lat OR p.longitude <> j.lng) THEN RAISE EXCEPTION 'V1: restore'; END IF;
  -- V2 links: none left on deleted rows except the 3 for a person
  SELECT count(*) INTO n FROM public.entity_source_links e JOIN public.properties pp ON pp.id = e.entity_id
   WHERE e.entity_type = 'property' AND e.source_system = 'samsara' AND pp.deleted_at IS NOT NULL;
  IF n <> 3 THEN RAISE EXCEPTION 'V2: % links still on deleted rows (expected 3)', n; END IF;
  -- V3 replay the real Place events of the last 30 days through the reconciler: it writes no property and gives the
  -- expected verdicts (105-CU moved 13 km; 192-FRK and 012-DKC same; 166-SPA now resolved through its repointed link)
  BEGIN
    FOR ev IN SELECT e.event_type, e.payload->'data'->'address' AS a FROM public.webhook_events_log e
               WHERE e.source_system = 'samsara' AND e.event_type LIKE 'Address%' ORDER BY e.created_at LOOP
      PERFORM public.fn_record_samsara_place(ev.a, lower(replace(ev.event_type, 'Address', '')));
    END LOOP;
    IF EXISTS (SELECT 1 FROM audit.logs a WHERE a.table_name = 'properties' AND a.txid = txid_current()
                AND a.app_source IS DISTINCT FROM 'samsara-reconcile') THEN RAISE EXCEPTION 'V3: the reconciler wrote a property'; END IF;
    IF (SELECT verdict FROM public.v_samsara_place_review WHERE samsara_address_id = '322485303') IS DISTINCT FROM 'moved'
       OR (SELECT property_id FROM public.v_samsara_place_review WHERE samsara_address_id = '322485303') IS DISTINCT FROM 210 THEN
      RAISE EXCEPTION 'V3: 105-CU'; END IF;
    IF (SELECT verdict FROM public.v_samsara_place_review WHERE samsara_address_id = '4000001011504') IS DISTINCT FROM 'same'
       OR (SELECT verdict FROM public.v_samsara_place_review WHERE samsara_address_id = '322485301') IS DISTINCT FROM 'same' THEN
      RAISE EXCEPTION 'V3: 192-FRK / 012-DKC'; END IF;
    IF (SELECT property_id FROM public.v_samsara_place_review WHERE samsara_address_id = '4000001011468') IS DISTINCT FROM 218 THEN
      RAISE EXCEPTION 'V3: 166-SPA'; END IF;
    -- a new Place named after a client code is proposed, not linked
    r := public.fn_record_samsara_place('{"id":"999999999001","name":"112-YA Test Place","latitude":25.8346,"longitude":-80.2596,"geofence":{"circle":{"latitude":25.8346,"longitude":-80.2596,"radiusMeters":100}}}', 'created');
    IF r->>'match_method' <> 'client_code_prefix' OR r->>'verdict' <> 'unlinked'
       OR EXISTS (SELECT 1 FROM public.entity_source_links WHERE source_system = 'samsara' AND source_id = '999999999001') THEN
      RAISE EXCEPTION 'V3: the new Place %', r; END IF;
    -- the explicit link works once, and refuses twice
    PERFORM public.fn_link_samsara_place('999999999001', (SELECT id FROM public.properties WHERE client_id = 381 AND deleted_at IS NULL AND NOT is_billing
                                                           AND NOT EXISTS (SELECT 1 FROM public.entity_source_links e WHERE e.entity_type = 'property' AND e.entity_id = properties.id AND e.source_system = 'samsara') LIMIT 1));
    RAISE EXCEPTION USING ERRCODE = 'P0901', MESSAGE = 'probe rolled back';
  EXCEPTION WHEN SQLSTATE 'P0901' THEN NULL;
  END;
  -- V4 the polygon test, with a control on each side (192-FRK's polygon)
  IF public.fn_point_in_samsara_geofence(25.9514, -80.1432, '{"polygon":{"vertices":[{"latitude":25.951203,"longitude":-80.143353},{"latitude":25.951751,"longitude":-80.143353},{"latitude":25.951751,"longitude":-80.143141},{"latitude":25.951203,"longitude":-80.143141}]}}') IS NOT TRUE
     OR public.fn_point_in_samsara_geofence(25.9530, -80.1432, '{"polygon":{"vertices":[{"latitude":25.951203,"longitude":-80.143353},{"latitude":25.951751,"longitude":-80.143353},{"latitude":25.951751,"longitude":-80.143141},{"latitude":25.951203,"longitude":-80.143141}]}}') IS NOT FALSE THEN
    RAISE EXCEPTION 'V4: polygon test'; END IF;
  IF has_table_privilege('authenticated', 'public.samsara_place_observations', 'SELECT')
     OR has_function_privilege('authenticated', 'public.fn_record_samsara_place(jsonb, text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'V5: grants'; END IF;
END $v$;

COMMIT;
