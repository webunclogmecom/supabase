-- ============================================================================================
-- 2026-09-07_1700_dump_sites_registry.sql
--
-- public.dump_sites: the per-site ATTRIBUTES that a membership list cannot carry. Completes the
-- "one source of truth" work started in 2026-09-07_1520.
--
-- WHY (Fred, 2026-09-07): "yes do the registry."
--
-- Membership ("is this client a dump?") was solved by public.non_customer_clients. Four functions
-- still hardcode literals because they ask something a list cannot answer:
--   fn_dump_site_accepts         which COUNTIES this site takes      CASE WHEN client_id = 365 ...
--   dump_site_status             call-ahead behaviour + phone        WHEN p_dump_key = 'DH' ...
--   dump_manifest_handout_list   which clients are dump sites        client_id IN (76, 365)
--   dump_investigate             the site COORDINATES                lat/lng literals in an IF
--
-- 🛑 THE FAIL-OPEN THIS CLOSES. fn_dump_site_accepts reads
--       CASE WHEN p_dump_client_id = 365 THEN <Dade gate> ELSE true END
-- The ELSE is correct for Pompano today and means a THIRD dump site would silently accept
-- everything, including waste it may not be permitted to take. `accepted_county_buckets` is
-- NOT NULL, so a new site cannot be added without declaring what it takes. The bucket domain is
-- exactly three values (read from fn_dump_county_bucket: DADE, BROWARD, UNKNOWN), so the column is
-- an explicit enumeration and needs no "accepts everything" sentinel.
--
-- ⚠ A SITE CAN HAVE TWO TIP POINTS, and that is not redundancy. Pompano is 3100 N Powerline Road
-- (the one we frequent) AND 2401 N Powerline Road; they are ~600 m apart, so a radius around one
-- EXCLUDES the other and dump_investigate measures to both and takes the nearer. Homestead has one,
-- and the existing code sets site2 = site1 so the LEAST() is a no-op. The registry keeps lat2/lng2
-- nullable and callers coalesce, rather than duplicating the row.
--
-- ⚠ public.dump_site_hours ALREADY EXISTS and is already per-site, keyed on dump_key. It is NOT
-- absorbed here: hours are a 7-row-per-site schedule and belong in their own table. This migration
-- only gives dump_key an owner, via an FK, so a key cannot exist without a site.
--
-- RULE 8: OPT IN. It carries a compliance-relevant county gate and is human-edited.
--
-- NOTHING IS REPOINTED HERE. The four functions still hold their literals; moving them is
-- 2026-09-07_1720 so the registry can be reviewed on its own.
-- ============================================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.dump_sites (
  client_id               bigint      PRIMARY KEY REFERENCES public.clients(id),
  dump_key                text        NOT NULL UNIQUE,
  short_name              text        NOT NULL,
  label                   text        NOT NULL,
  accepted_county_buckets text[]      NOT NULL,
  after_hours_phone       text,
  lat                     double precision NOT NULL,
  lng                     double precision NOT NULL,
  lat2                    double precision,
  lng2                    double precision,
  is_active               boolean     NOT NULL DEFAULT true,
  notes                   text,
  CONSTRAINT dump_sites_dump_key_chk  CHECK (dump_key ~ '^[A-Z]{2}$'),
  -- 🛑 The whole point: a new site must SAY what it accepts. An empty list would be a site that
  --    takes nothing, which is not a thing, so it is rejected too.
  -- ⚠ cardinality(), NOT array_length(). array_length(ARRAY[]::text[], 1) returns **NULL**, not 0,
  --    and a CHECK constraint PASSES on NULL, so the first draft of this constraint accepted an
  --    empty county list: the guard written to close a fail-open was itself failing open. Its own
  --    VERIFY caught it. cardinality() returns 0 for an empty array and 0 >= 1 is false.
  CONSTRAINT dump_sites_counties_chk   CHECK (
    cardinality(accepted_county_buckets) >= 1
    AND accepted_county_buckets <@ ARRAY['DADE','BROWARD','UNKNOWN']),
  -- A second tip point is optional, but half of one is a bug.
  CONSTRAINT dump_sites_site2_pair_chk CHECK ((lat2 IS NULL) = (lng2 IS NULL))
);

COMMENT ON TABLE public.dump_sites IS
  'Per-site facts about our own dump sites: which counties each accepts, its call-ahead phone, and '
  'its tip coordinates. Membership ("is this client a dump") lives in public.non_customer_clients '
  'with kind=dump_site; this table is the ATTRIBUTES a list cannot carry. accepted_county_buckets '
  'is NOT NULL on purpose: the old fn_dump_site_accepts defaulted an unknown site to "accepts '
  'everything", so a third site would have silently taken waste it may not be permitted to take.';

COMMENT ON COLUMN public.dump_sites.lat2 IS
  'Optional SECOND tip point. Pompano has two entrances ~600m apart (3100 and 2401 N Powerline '
  'Road) and a radius around one excludes the other, so callers measure to both and take the '
  'nearer. NULL means the site has one point; callers coalesce lat2 to lat.';
COMMENT ON COLUMN public.dump_sites.after_hours_phone IS
  'NULL means the site has NO sanctioned after-hours path and arriving outside hours is CLOSED. '
  'A number means AFTER_HOURS with a call-ahead. Homestead has one, Pompano does not.';

DROP TRIGGER IF EXISTS audit_dump_sites ON public.dump_sites;
CREATE TRIGGER audit_dump_sites
  AFTER INSERT OR UPDATE OR DELETE ON public.dump_sites
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

REVOKE ALL ON public.dump_sites FROM PUBLIC, anon;
GRANT SELECT ON public.dump_sites TO authenticated, service_role;

-- Values below are lifted verbatim from the function bodies they will replace, never re-derived.
INSERT INTO public.dump_sites
  (client_id, dump_key, short_name, label, accepted_county_buckets, after_hours_phone,
   lat, lng, lat2, lng2, notes)
VALUES
  (365, 'DH', 'Homestead', 'Homestead (000-DH)',
   ARRAY['DADE','UNKNOWN'], '786-268-5623',
   25.5517444, -80.3368324, NULL, NULL,
   'Dade (or unknown-county) work only. Sanctioned call-ahead path at ANY hour. Single tip point.'),
  (76,  'DP', 'Pompano',   'Pompano (000-DP)',
   ARRAY['DADE','BROWARD','UNKNOWN'], NULL,
   26.2683192, -80.1506092, 26.2632563, -80.1552085,
   'Takes every county. No after-hours path: outside hours is CLOSED. Two tip points, '
   '3100 N Powerline Road (frequented) and 2401 N Powerline Road, ~600m apart.')
ON CONFLICT (client_id) DO NOTHING;

-- Give dump_key an owner. NOT VALID would be pointless here: it is checked below and the existing
-- rows are exactly the two seeded keys.
ALTER TABLE public.dump_site_hours
  DROP CONSTRAINT IF EXISTS dump_site_hours_dump_key_fkey;
ALTER TABLE public.dump_site_hours
  ADD CONSTRAINT dump_site_hours_dump_key_fkey
  FOREIGN KEY (dump_key) REFERENCES public.dump_sites (dump_key);

-- ============================================================================================
-- VERIFY. The registry must reproduce, exactly, what the four functions currently hardcode.
-- ============================================================================================
DO $verify$
DECLARE r record; v_n int; v_ok boolean;
BEGIN
  -- 1. Both sites seeded and joined to membership. A registry row for a client that is not a
  --    dump_site member would mean the two halves disagree on day one.
  SELECT count(*) INTO v_n FROM public.dump_sites;
  IF v_n <> 2 THEN RAISE EXCEPTION 'VERIFY 1 FAILED: % sites, expected 2', v_n; END IF;
  SELECT count(*) INTO v_n FROM public.dump_sites ds
   WHERE NOT public.fn_is_non_customer(ds.client_id, ARRAY['dump_site']);
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: % registry site(s) are not dump_site members, so membership '
                    'and attributes already disagree.', v_n;
  END IF;

  -- 2. THE COUNTY GATE REPRODUCES THE LIVE FUNCTION EXACTLY. This is the compliance-relevant one,
  --    so it is proven against every (site, county) pair rather than spot-checked.
  FOR r IN
    SELECT ds.client_id, ds.short_name, c.county,
           public.fn_dump_site_accepts(ds.client_id, c.county)                        AS live,
           (public.fn_dump_county_bucket(c.county) = ANY (ds.accepted_county_buckets)) AS from_registry
      FROM public.dump_sites ds
      CROSS JOIN (VALUES ('Dade'),('Miami-Dade'),('Broward'),('Palm Beach'),(NULL),(''),('none'),
                         ('Monroe')) AS c(county)
  LOOP
    IF r.live IS DISTINCT FROM r.from_registry THEN
      RAISE EXCEPTION 'VERIFY 2 FAILED: % / county % -> live=% registry=%. The registry does not '
                      'reproduce the county gate.', r.short_name, coalesce(r.county,'(null)'),
                      r.live, r.from_registry;
    END IF;
  END LOOP;

  -- 3. The call-ahead phone matches what dump_site_status emits. Proven by calling the live
  --    function at an hour both sites are shut, so the AFTER_HOURS branch is the one exercised.
  SELECT after_hours_phone IS NOT NULL INTO v_ok FROM public.dump_sites WHERE dump_key = 'DH';
  IF NOT v_ok THEN RAISE EXCEPTION 'VERIFY 3 FAILED: Homestead has no after-hours phone.'; END IF;
  SELECT after_hours_phone IS NULL INTO v_ok FROM public.dump_sites WHERE dump_key = 'DP';
  IF NOT v_ok THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: Pompano has an after-hours phone, but it has no sanctioned '
                    'after-hours path and must read CLOSED.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.dump_site_status('DH', timestamptz '2026-09-07 03:00:00-04') s
     JOIN public.dump_sites ds ON ds.dump_key = 'DH'
    WHERE s.status = 'AFTER_HOURS' AND s.after_hours_phone = ds.after_hours_phone) THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: the seeded phone does not match what dump_site_status emits '
                    'on the AFTER_HOURS branch.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.dump_site_status('DP', timestamptz '2026-09-07 03:00:00-04') s
    WHERE s.status = 'CLOSED' AND s.after_hours_phone IS NULL) THEN
    RAISE EXCEPTION 'VERIFY 3 CONTROL FAILED: Pompano did not read CLOSED at 03:00, so the '
                    'assertion above is not discriminating between the two sites.';
  END IF;

  -- 4. dump_site_hours now has an owner, and every key resolves.
  SELECT count(DISTINCT h.dump_key) INTO v_n FROM public.dump_site_hours h
   WHERE NOT EXISTS (SELECT 1 FROM public.dump_sites ds WHERE ds.dump_key = h.dump_key);
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 4 FAILED: % orphan dump_key(s)', v_n; END IF;

  -- 5. THE CONSTRAINT THAT CLOSES THE FAIL-OPEN actually bites. A new site with no declared
  --    counties must be refused, or the whole point of the NOT NULL is lost.
  BEGIN
    INSERT INTO public.dump_sites (client_id, dump_key, short_name, label,
      accepted_county_buckets, lat, lng)
    VALUES (2, 'ZZ', 'probe', 'probe', ARRAY[]::text[], 0, 0);
    RAISE EXCEPTION 'VERIFY 5 FAILED: a site with an empty county list was accepted.';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.dump_sites (client_id, dump_key, short_name, label,
      accepted_county_buckets, lat, lng, lat2)
    VALUES (2, 'ZZ', 'probe', 'probe', ARRAY['DADE'], 0, 0, 1.0);
    RAISE EXCEPTION 'VERIFY 5 FAILED: a half-specified second tip point was accepted.';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  RAISE NOTICE 'ALL VERIFY PASSED (2 sites, county gate reproduced on 16 pairs, constraints bite)';
END
$verify$;

COMMIT;
