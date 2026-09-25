-- ============================================================================
-- 2026-09-25 · DERM Tracker "Send to city" never offers a grey water pair, and says why
-- ============================================================================
-- THE ASK
--   Fred, 2026-09-25: "yes, fix the DERM Tracker one too." (after "No, grey water reports don't go to the city",
--   enforced server-side by 2026-09-24_2110 and taught to Admin Review by 2026-09-25_0045).
--   The DERM Tracker decides who "Send to city" offers from three views, and none knew the rule:
--     derm.manifest_recipients.has_city_email / municipality   the Send to city dialog (row enabled, To line,
--                                                             Send button) and the Manifests list
--     derm.manifests.city_total_count                         the Manifests list city counts
--     derm.visits.has_city_email / municipality               the visit page ("Send to city" button, status line)
--   A grey water pair whose property had a city inbox would have been offered, then refused by send-derm-email
--   as "skipped: grey_water". Measured before this file: no grey water pair has an inbox, so nothing is offered
--   today; this closes it for good.
--
-- WHAT CHANGES (all spliced from the live text, md5 pinned; no column moves, no grant changes)
--   1. derm.manifest_recipients: has_city_email and municipality count only visits NOT on
--      public.v_visit_not_for_city; NEW last column not_for_city = the client has live visits on the manifest
--      and every one is on that list (the same test as derm.v_city_email_candidates' 'grey_water').
--   2. derm.manifests.city_total_count counts only clients with a city-reportable visit.
--   3. derm.visits: has_city_email and municipality are false / NULL for a listed visit; NEW last column
--      not_for_city (after grey_water_pumping, which stays; the Visits list selects by name, the visit page
--      reads select("*")).
--   4. derm.v_manifest_recipient_city_emails (the dialog's "To:" line) lists only the inboxes of visits NOT on the
--      list, so on a mixed pair it names exactly the addresses send-derm-email will mail.
--   So by default every DERM Tracker surface stops offering a grey water pair (the row is disabled, no To line,
--   no Send to city button). The app then only needs not_for_city to say WHY ("grey water") instead of
--   "No city program", which would invite someone to add one. That label is the Lovable half of this change.
--   Mixed pairs (a grey water visit and a grease trap visit of one client on one manifest; 0 today) keep their
--   city route through the grease trap visit, as in the send path and the candidates view.
--
-- WHAT MOVES (measured in the dry run 2026-09-25 ~01:10 ET, re-asserted below)
--   - derm.manifest_recipients: 29 pairs not_for_city; 0 of them had or have a city route (no grey water client has
--     a city inbox), so no has_city_email or municipality value moves today. Every other pair is byte-identical.
--   - derm.manifests: no city_total_count moves today. derm.visits: 33 rows not_for_city, nothing else moves
--     (grey_water_pumping included). derm.v_manifest_recipient_city_emails: no row moves today.
--   - Cost, every row fully built (sum of to_jsonb lengths; a bare count(*) lets the planner skip the select list):
--     derm.visits 2113 ms (was 1955), manifest_recipients 298 (was 100), manifests 126 (was 68), city emails 39 (was 22).
--     What the app loads moves little: a 1,000-row Visits page 547 -> 552 ms, one visit by id 429 -> 444 ms (review).
--   - With a city inbox put on 214-MYK property 30 (rolled back): 0 of its 18 grey water pairs and 19 grey water
--     visits are offered, 10 of its other visits become sendable (the control), no manifest counts it, and the
--     automatic email keeps reading grey_water.
--
-- NOT CHANGED: any grant, any stored value, the edge functions, the client send.
-- LOCKS: the four CREATE OR REPLACE run back to back (milliseconds), so a DERM Tracker read that takes the views in
-- another order can deadlock only inside that window; the loser is one aborted read or this file, re-run. From the
-- first DDL to COMMIT the views are exclusively locked and Tracker reads wait (seconds; the VERIFY). Run off hours.
-- 🛑 Do not SET search_path in this file: the derm views name public tables unqualified (manifest_visits,
-- visits, properties exist in derm too), and the EXECUTE must resolve them exactly as before.
-- AUDIT-TRAIL STANDING CHECK (rule 8): no table changes; views are not audited.
-- ORDER: apply this BEFORE the DERM Tracker build that selects not_for_city.
-- ROLLBACK: the app must stop selecting not_for_city first. CREATE OR REPLACE cannot drop the appended columns;
-- restoring the old has_city_email / municipality / city_total_count expressions means re-splicing them back
-- (the old text of all four views is in docs/migrations/_baseline/2026-09-25_derm_city_send.before.sql).
-- ============================================================================

BEGIN;

DO $pre$
BEGIN
  IF md5(pg_get_viewdef('derm.manifest_recipients'::regclass)) <> '3fa2f794a646afdfa4de29c3cd506aa7' THEN
    RAISE EXCEPTION 'derm.manifest_recipients changed since this migration was built; rebuild it'; END IF;
  IF md5(pg_get_viewdef('derm.manifests'::regclass)) <> '06811164b7fe32967cdaf4ac2005916a' THEN
    RAISE EXCEPTION 'derm.manifests changed since this migration was built; rebuild it'; END IF;
  IF md5(pg_get_viewdef('derm.visits'::regclass)) <> '4c29a393235e59c9b1b64d8ae001e000' THEN
    RAISE EXCEPTION 'derm.visits changed since this migration was built; rebuild it'; END IF;
  IF md5(pg_get_viewdef('derm.v_manifest_recipient_city_emails'::regclass)) <> '5442ef0a129e4a426feee17c32caa217' THEN
    RAISE EXCEPTION 'derm.v_manifest_recipient_city_emails changed since this migration was built; rebuild it'; END IF;
  IF to_regclass('public.v_visit_not_for_city') IS NULL THEN
    RAISE EXCEPTION 'public.v_visit_not_for_city is missing (2026-09-24_2110 first)'; END IF;
END
$pre$;

-- ---------- the "before" cost (the same statement V7 times after) and the snapshots
CREATE TEMP TABLE _ms (dv int, mr int, mf int, ce int) ON COMMIT DROP;
DO $cost$
DECLARE t0 timestamptz; s bigint; a int; b int; c int; e int;
BEGIN
  t0 := clock_timestamp(); SELECT sum(length(to_jsonb(d)::text)) INTO s FROM derm.visits d; a := extract(epoch FROM clock_timestamp() - t0) * 1000;
  t0 := clock_timestamp(); SELECT sum(length(to_jsonb(r)::text)) INTO s FROM derm.manifest_recipients r; b := extract(epoch FROM clock_timestamp() - t0) * 1000;
  t0 := clock_timestamp(); SELECT sum(length(to_jsonb(m)::text)) INTO s FROM derm.manifests m; c := extract(epoch FROM clock_timestamp() - t0) * 1000;
  t0 := clock_timestamp(); SELECT sum(length(to_jsonb(x)::text)) INTO s FROM derm.v_manifest_recipient_city_emails x; e := extract(epoch FROM clock_timestamp() - t0) * 1000;
  INSERT INTO _ms VALUES (a, b, c, e);
END
$cost$;
CREATE TEMP TABLE _dv_before ON COMMIT DROP AS SELECT id, to_jsonb(d) AS j FROM derm.visits d;
CREATE TEMP TABLE _ce_before ON COMMIT DROP AS SELECT manifest_id, client_id, city_emails, municipality FROM derm.v_manifest_recipient_city_emails;
CREATE TEMP TABLE _mr_before ON COMMIT DROP AS SELECT manifest_id, client_id, to_jsonb(r) AS j FROM derm.manifest_recipients r;
CREATE TEMP TABLE _mf_before ON COMMIT DROP AS SELECT id, to_jsonb(m) AS j FROM derm.manifests m;
CREATE TEMP TABLE _rel_before ON COMMIT DROP AS
  SELECT oid AS reloid, relacl::text AS acl, reloptions::text AS opts FROM pg_class
   WHERE oid IN ('derm.manifest_recipients'::regclass, 'derm.manifests'::regclass, 'derm.visits'::regclass,
                 'derm.v_manifest_recipient_city_emails'::regclass);
CREATE TEMP TABLE _cols_before ON COMMIT DROP AS
  SELECT attrelid, attnum, attname, atttypid FROM pg_attribute
   WHERE attrelid IN ('derm.manifest_recipients'::regclass, 'derm.manifests'::regclass, 'derm.visits'::regclass,
                      'derm.v_manifest_recipient_city_emails'::regclass)
     AND attnum > 0 AND NOT attisdropped;

-- ---------- 1. derm.manifests (read by derm.manifest_recipients, so first)
DO $mf$
DECLARE d text := pg_get_viewdef('derm.manifests'::regclass); a text := $mfa$                  WHERE ((p.id = vv.property_id) AND (p.deleted_at IS NULL) AND (cardinality(COALESCE(p.city_emails, '{}'::text[])) > 0)))))) AS city_total_count,
$mfa$; b text := $mfb$                  WHERE ((p.id = vv.property_id) AND (p.deleted_at IS NULL) AND (cardinality(COALESCE(p.city_emails, '{}'::text[])) > 0)))) AND (NOT (EXISTS ( SELECT 1
                   FROM public.v_visit_not_for_city nfc
                   WHERE (nfc.visit_id = vv.id)))))) AS city_total_count,
$mfb$;
BEGIN
  IF length(d) - length(replace(d, a, '')) <> length(a) THEN RAISE EXCEPTION 'manifests: anchor not found exactly once'; END IF;
  EXECUTE 'CREATE OR REPLACE VIEW derm.manifests AS ' || rtrim(replace(d, a, b), ';');
END
$mf$;

-- ---------- 2. derm.manifest_recipients
DO $mr$
DECLARE d text := pg_get_viewdef('derm.manifest_recipients'::regclass);
  a1 text := $mra1$          WHERE ((mv.manifest_id = w.manifest_id) AND (cardinality(COALESCE(p.city_emails, '{}'::text[])) > 0)))) AS has_city_email,
$mra1$; b1 text := $mrb1$          WHERE ((mv.manifest_id = w.manifest_id) AND (cardinality(COALESCE(p.city_emails, '{}'::text[])) > 0) AND (NOT (EXISTS ( SELECT 1
                   FROM public.v_visit_not_for_city nfc
                   WHERE (nfc.visit_id = v.id))))))) AS has_city_email,
$mrb1$; a2 text := $mra2$          WHERE ((mv.manifest_id = w.manifest_id) AND (cardinality(COALESCE(p.city_emails, '{}'::text[])) > 0) AND (NULLIF(btrim(p.city), ''::text) IS NOT NULL))) AS municipality,
$mra2$; b2 text := $mrb2$          WHERE ((mv.manifest_id = w.manifest_id) AND (cardinality(COALESCE(p.city_emails, '{}'::text[])) > 0) AND (NULLIF(btrim(p.city), ''::text) IS NOT NULL) AND (NOT (EXISTS ( SELECT 1
                   FROM public.v_visit_not_for_city nfc
                   WHERE (nfc.visit_id = v.id)))))) AS municipality,
$mrb2$; a3 text := $mra3$ AS city_last_emailed_at
   FROM ( SELECT sub.manifest_id,
$mra3$; b3 text := $mrb3$ AS city_last_emailed_at,
    ((EXISTS ( SELECT 1
           FROM (public.manifest_visits mv
             JOIN public.visits v ON (((v.id = mv.visit_id) AND (v.deleted_at IS NULL) AND (v.client_id = w.client_id))))
          WHERE (mv.manifest_id = w.manifest_id))) AND (NOT (EXISTS ( SELECT 1
           FROM (public.manifest_visits mv
             JOIN public.visits v ON (((v.id = mv.visit_id) AND (v.deleted_at IS NULL) AND (v.client_id = w.client_id))))
          WHERE ((mv.manifest_id = w.manifest_id) AND (NOT (EXISTS ( SELECT 1
                   FROM public.v_visit_not_for_city nfc
                   WHERE (nfc.visit_id = v.id))))))))) AS not_for_city
   FROM ( SELECT sub.manifest_id,
$mrb3$;
BEGIN
  IF length(d) - length(replace(d, a1, '')) <> length(a1) THEN RAISE EXCEPTION 'manifest_recipients: has_city_email anchor'; END IF;
  IF length(d) - length(replace(d, a2, '')) <> length(a2) THEN RAISE EXCEPTION 'manifest_recipients: municipality anchor'; END IF;
  IF length(d) - length(replace(d, a3, '')) <> length(a3) THEN RAISE EXCEPTION 'manifest_recipients: last column anchor'; END IF;
  EXECUTE 'CREATE OR REPLACE VIEW derm.manifest_recipients AS ' || rtrim(replace(replace(replace(d, a1, b1), a2, b2), a3, b3), ';');
END
$mr$;

-- ---------- 3. derm.visits
DO $dv$
DECLARE d text := pg_get_viewdef('derm.visits'::regclass);
  a1 text := $dva1$            COALESCE(vp.has_city_email, false) AS has_city_email,
            vp.municipality
$dva1$; b1 text := $dvb1$            COALESCE(vp.has_city_email, false) AS has_city_email,
            vp.municipality,
            COALESCE(vp.not_for_city, false) AS not_for_city
$dvb1$; a2 text := $dva2$             LEFT JOIN LATERAL ( SELECT (cardinality(COALESCE(p.city_emails, '{}'::text[])) > 0) AS has_city_email,
                        CASE
                            WHEN (cardinality(COALESCE(p.city_emails, '{}'::text[])) > 0) THEN NULLIF(btrim(p.city), ''::text)
                            ELSE NULL::text
                        END AS municipality
                   FROM (visits v3
                     LEFT JOIN properties p ON (((p.id = v3.property_id) AND (p.deleted_at IS NULL))))
                  WHERE (v3.id = w2.id)) vp ON (true))) w3
$dva2$; b2 text := $dvb2$             LEFT JOIN LATERAL ( SELECT (x.has_inbox AND (NOT x.not_for_city)) AS has_city_email,
                        CASE
                            WHEN (x.has_inbox AND (NOT x.not_for_city)) THEN x.city
                            ELSE NULL::text
                        END AS municipality,
                    x.not_for_city
                   FROM ( SELECT (cardinality(COALESCE(p.city_emails, '{}'::text[])) > 0) AS has_inbox,
                            NULLIF(btrim(p.city), ''::text) AS city,
                            (EXISTS ( SELECT 1
                                   FROM public.v_visit_not_for_city nfc
                                  WHERE (nfc.visit_id = v3.id))) AS not_for_city
                           FROM (visits v3
                             LEFT JOIN properties p ON (((p.id = v3.property_id) AND (p.deleted_at IS NULL))))
                          WHERE (v3.id = w2.id)) x) vp ON (true))) w3
$dvb2$; a3 text := $dva3$          WHERE (gwp.visit_id = w3.id))) AS grey_water_pumping
   FROM ((((( SELECT w2.id,
$dva3$; b3 text := $dvb3$          WHERE (gwp.visit_id = w3.id))) AS grey_water_pumping,
    w3.not_for_city
   FROM ((((( SELECT w2.id,
$dvb3$;
BEGIN
  IF length(d) - length(replace(d, a1, '')) <> length(a1) THEN RAISE EXCEPTION 'visits: w3 select anchor'; END IF;
  IF length(d) - length(replace(d, a2, '')) <> length(a2) THEN RAISE EXCEPTION 'visits: vp lateral anchor'; END IF;
  IF length(d) - length(replace(d, a3, '')) <> length(a3) THEN RAISE EXCEPTION 'visits: last column anchor'; END IF;
  EXECUTE 'CREATE OR REPLACE VIEW derm.visits AS ' || rtrim(replace(replace(replace(d, a1, b1), a2, b2), a3, b3), ';');
END
$dv$;

-- ---------- 4. derm.v_manifest_recipient_city_emails (reads derm.manifest_recipients, so after it)
DO $ce$
DECLARE d text := pg_get_viewdef('derm.v_manifest_recipient_city_emails'::regclass); a text := $cea$          WHERE (mv.manifest_id = mr.manifest_id)) x ON (true))$cea$; b text := $ceb$          WHERE ((mv.manifest_id = mr.manifest_id) AND (NOT (EXISTS ( SELECT 1
                   FROM public.v_visit_not_for_city nfc
                   WHERE (nfc.visit_id = v.id)))))) x ON (true))$ceb$;
BEGIN
  IF length(d) - length(replace(d, a, '')) <> length(a) THEN RAISE EXCEPTION 'v_manifest_recipient_city_emails: anchor not found exactly once'; END IF;
  EXECUTE 'CREATE OR REPLACE VIEW derm.v_manifest_recipient_city_emails AS ' || rtrim(replace(d, a, b), ';');
END
$ce$;

-- ---------- VERIFY
DO $verify$
DECLARE
  n int; n2 int; n3 int; t0 timestamptz; dv_ms int; mr_ms int; mf_ms int;
  fx_inbox boolean; fx_dv_ok int; fx_ce_nfc int; fx_ce_ok int; fx_ce_route int; fx_ce_raw int; ce_ms int; s bigint; fx_mr_true int; fx_mr_nfc int; fx_dv_true int; fx_dv_nfc int; fx_mf int; fx_cand text; ctl_mr int; ctl_dv int;
BEGIN
  -- V1 columns: everything kept in place; exactly one boolean appended to manifest_recipients and derm.visits
  IF EXISTS (SELECT 1 FROM _cols_before b LEFT JOIN pg_attribute a
               ON a.attrelid = b.attrelid AND a.attnum = b.attnum AND NOT a.attisdropped
              WHERE a.attname IS DISTINCT FROM b.attname OR a.atttypid IS DISTINCT FROM b.atttypid) THEN
    RAISE EXCEPTION 'V1: an existing column moved or changed'; END IF;
  IF (SELECT string_agg(format('%s.%s:%s', attrelid::regclass, attname, atttypid::regtype), ', ' ORDER BY attrelid::regclass::text)
        FROM pg_attribute a WHERE attrelid IN ('derm.manifest_recipients'::regclass, 'derm.manifests'::regclass, 'derm.visits'::regclass,
                                               'derm.v_manifest_recipient_city_emails'::regclass)
         AND attnum > 0 AND NOT attisdropped
         AND NOT EXISTS (SELECT 1 FROM _cols_before b WHERE b.attrelid = a.attrelid AND b.attnum = a.attnum))
     IS DISTINCT FROM 'derm.manifest_recipients.not_for_city:boolean, derm.visits.not_for_city:boolean' THEN
    RAISE EXCEPTION 'V1: the appended columns are not exactly the two not_for_city booleans'; END IF;

  -- V2 derm.manifest_recipients: pairs with no listed visit are byte-identical; others move only
  -- has_city_email true->false and municipality -> NULL; not_for_city is exactly "all live visits listed"
  CREATE TEMP TABLE _pairs ON COMMIT DROP AS
    SELECT b.manifest_id, b.client_id, count(v.id) AS n_visits, count(x.visit_id) AS n_nfc
      FROM _mr_before b
      LEFT JOIN public.manifest_visits mv ON mv.manifest_id = b.manifest_id
      LEFT JOIN public.visits v ON v.id = mv.visit_id AND v.deleted_at IS NULL AND v.client_id = b.client_id
      LEFT JOIN public.v_visit_not_for_city x ON x.visit_id = v.id
     GROUP BY 1, 2;
  IF (SELECT count(*) FROM derm.manifest_recipients) <> (SELECT count(*) FROM _mr_before) THEN
    RAISE EXCEPTION 'V2: manifest_recipients row count changed'; END IF;
  SELECT count(*) INTO n FROM _mr_before b JOIN _pairs p USING (manifest_id, client_id)
    JOIN derm.manifest_recipients r USING (manifest_id, client_id)
   WHERE p.n_nfc = 0 AND (to_jsonb(r) - 'not_for_city') IS DISTINCT FROM b.j;
  IF n <> 0 THEN RAISE EXCEPTION 'V2: % pairs with no listed visit changed', n; END IF;
  SELECT count(*) INTO n FROM _mr_before b JOIN _pairs p USING (manifest_id, client_id)
    JOIN derm.manifest_recipients r USING (manifest_id, client_id)
   WHERE p.n_nfc > 0 AND ((to_jsonb(r) - 'not_for_city' - 'has_city_email' - 'municipality') IS DISTINCT FROM (b.j - 'has_city_email' - 'municipality')
      OR (r.has_city_email AND NOT (b.j->>'has_city_email')::boolean));
  IF n <> 0 THEN RAISE EXCEPTION 'V2: % pairs with a listed visit changed something else, or gained a city route', n; END IF;
  SELECT count(*) INTO n FROM derm.manifest_recipients r JOIN _pairs p USING (manifest_id, client_id)
   WHERE r.not_for_city IS DISTINCT FROM (p.n_visits > 0 AND p.n_nfc = p.n_visits);
  IF n <> 0 THEN RAISE EXCEPTION 'V2: not_for_city disagrees with the list on % pairs', n; END IF;
  SELECT count(*) FILTER (WHERE not_for_city), count(*) FILTER (WHERE not_for_city AND has_city_email) INTO n, n2 FROM derm.manifest_recipients;
  IF n < 20 THEN RAISE EXCEPTION 'V2 control: only % pairs are not_for_city', n; END IF;
  IF n2 <> 0 THEN RAISE EXCEPTION 'V2: % not_for_city pairs still offer a city route', n2; END IF;

  -- V3 derm.manifests: only city_total_count may move, only down, only on manifests with a listed visit
  IF (SELECT count(*) FROM derm.manifests) <> (SELECT count(*) FROM _mf_before) THEN RAISE EXCEPTION 'V3: manifests row count changed'; END IF;
  SELECT count(*) INTO n FROM _mf_before b JOIN derm.manifests m ON m.id = b.id
   WHERE (to_jsonb(m) - 'city_total_count') IS DISTINCT FROM (b.j - 'city_total_count')
      OR (m.city_total_count > (b.j->>'city_total_count')::int)
      OR (m.city_total_count <> (b.j->>'city_total_count')::int AND NOT EXISTS (
            SELECT 1 FROM _pairs p WHERE p.manifest_id = m.id AND p.n_nfc > 0));
  IF n <> 0 THEN RAISE EXCEPTION 'V3: % manifests changed beyond a lower city count on a grey water manifest', n; END IF;

  -- V4 derm.visits: rows identical except has_city_email / municipality on listed visits; not_for_city = the list
  IF (SELECT count(*) FROM derm.visits) <> (SELECT count(*) FROM _dv_before) THEN RAISE EXCEPTION 'V4: derm.visits row count changed'; END IF;
  SELECT count(*) INTO n FROM _dv_before b JOIN derm.visits d ON d.id = b.id
   WHERE NOT EXISTS (SELECT 1 FROM public.v_visit_not_for_city x WHERE x.visit_id = d.id)
     AND (to_jsonb(d) - 'not_for_city') IS DISTINCT FROM b.j;
  IF n <> 0 THEN RAISE EXCEPTION 'V4: % unlisted visits changed in derm.visits', n; END IF;
  SELECT count(*) INTO n FROM _dv_before b JOIN derm.visits d ON d.id = b.id
   WHERE EXISTS (SELECT 1 FROM public.v_visit_not_for_city x WHERE x.visit_id = d.id)
     AND ((to_jsonb(d) - 'not_for_city' - 'has_city_email' - 'municipality') IS DISTINCT FROM (b.j - 'has_city_email' - 'municipality')
          OR d.has_city_email);
  IF n <> 0 THEN RAISE EXCEPTION 'V4: % listed visits changed something else, or still offer a city route', n; END IF;
  SELECT count(*) FILTER (WHERE d.not_for_city IS DISTINCT FROM EXISTS (SELECT 1 FROM public.v_visit_not_for_city x WHERE x.visit_id = d.id)),
         count(*) FILTER (WHERE d.not_for_city)
    INTO n, n2 FROM derm.visits d;
  IF n <> 0 THEN RAISE EXCEPTION 'V4: derm.visits.not_for_city disagrees with the list on % rows', n; END IF;
  IF n2 < 30 THEN RAISE EXCEPTION 'V4 control: only % derm.visits rows are not_for_city', n2; END IF;
  SELECT count(*) INTO n FROM _dv_before b JOIN derm.visits d ON d.id = b.id
   WHERE d.grey_water_pumping IS DISTINCT FROM (b.j->>'grey_water_pumping')::boolean;
  IF n <> 0 THEN RAISE EXCEPTION 'V4: grey_water_pumping moved on % rows', n; END IF;

  -- V8 derm.v_manifest_recipient_city_emails: same rows; pairs with no listed visit identical; others only lose
  -- addresses; no pair lists an address without a city route (the To line never names an inbox the send skips)
  IF (SELECT count(*) FROM derm.v_manifest_recipient_city_emails) <> (SELECT count(*) FROM _ce_before) THEN
    RAISE EXCEPTION 'V8: v_manifest_recipient_city_emails row count changed'; END IF;
  SELECT count(*) INTO n FROM _ce_before b JOIN _pairs p USING (manifest_id, client_id)
    JOIN derm.v_manifest_recipient_city_emails c USING (manifest_id, client_id)
   WHERE (p.n_nfc = 0 AND (c.city_emails IS DISTINCT FROM b.city_emails OR c.municipality IS DISTINCT FROM b.municipality))
      OR (p.n_nfc > 0 AND NOT (c.city_emails <@ b.city_emails));
  IF n <> 0 THEN RAISE EXCEPTION 'V8: % To-line rows changed beyond dropping a grey water inbox', n; END IF;
  SELECT count(*) INTO n FROM derm.v_manifest_recipient_city_emails c JOIN derm.manifest_recipients r USING (manifest_id, client_id)
   WHERE cardinality(c.city_emails) > 0 AND NOT r.has_city_email;
  IF n <> 0 THEN RAISE EXCEPTION 'V8: % pairs list a To address with no city route', n; END IF;
  IF (SELECT count(*) FROM derm.v_manifest_recipient_city_emails WHERE cardinality(city_emails) > 0) < 10 THEN
    RAISE EXCEPTION 'V8 control: fewer than 10 pairs list a To address'; END IF;

  -- V5 the fixture: give 214-MYK's property 30 a city inbox inside a rolled-back subtransaction. The raw inbox
  -- must be there (so the old views WOULD have offered it), yet every DERM Tracker surface refuses it, the
  -- automatic email keeps reading grey_water, and a grease trap pair with an inbox still reads has_city_email.
  SELECT count(*) INTO ctl_mr FROM derm.manifest_recipients WHERE has_city_email AND NOT not_for_city;
  SELECT count(*) INTO ctl_dv FROM derm.visits WHERE has_city_email;
  IF ctl_mr < 10 OR ctl_dv < 10 THEN RAISE EXCEPTION 'V5 control: only % pairs / % visits offer a city route', ctl_mr, ctl_dv; END IF;
  BEGIN
    UPDATE public.properties SET city_emails = ARRAY['probe@example.invalid'] WHERE id = 30 AND client_id = 348;
    SELECT cardinality(city_emails) > 0 INTO fx_inbox FROM public.properties WHERE id = 30;
    SELECT count(*) FILTER (WHERE has_city_email AND not_for_city), count(*) FILTER (WHERE not_for_city) INTO fx_mr_true, fx_mr_nfc
      FROM derm.manifest_recipients WHERE client_id = 348;
    SELECT count(*) FILTER (WHERE has_city_email AND not_for_city), count(*) FILTER (WHERE not_for_city),
           count(*) FILTER (WHERE has_city_email AND NOT not_for_city) INTO fx_dv_true, fx_dv_nfc, fx_dv_ok
      FROM derm.visits d JOIN public.visits v ON v.id = d.id WHERE v.client_id = 348 AND v.property_id = 30;
    SELECT count(*) INTO fx_mf FROM derm.manifests m
     WHERE m.city_total_count <> (SELECT (b.j->>'city_total_count')::int FROM _mf_before b WHERE b.id = m.id);
    SELECT string_agg(DISTINCT status, ',') INTO fx_cand FROM derm.v_city_email_candidates WHERE client_id = 348;
    SELECT count(*) FILTER (WHERE r.not_for_city AND cardinality(c.city_emails) > 0),
           count(*) FILTER (WHERE 'probe@example.invalid' = ANY (c.city_emails)),
           count(*) FILTER (WHERE r.has_city_email)
      INTO fx_ce_nfc, fx_ce_ok, fx_ce_route
      FROM derm.v_manifest_recipient_city_emails c JOIN derm.manifest_recipients r USING (manifest_id, client_id)
     WHERE c.client_id = 348;
    -- what the old To line would have listed: every 214-MYK pair with a live visit on property 30
    SELECT count(DISTINCT mv.manifest_id) INTO fx_ce_raw
      FROM public.manifest_visits mv
      JOIN public.visits v ON v.id = mv.visit_id AND v.deleted_at IS NULL AND v.client_id = 348 AND v.property_id = 30
     WHERE EXISTS (SELECT 1 FROM derm.manifest_recipients r WHERE r.manifest_id = mv.manifest_id AND r.client_id = 348);
    IF (SELECT count(*) FROM derm.manifest_recipients WHERE has_city_email AND NOT not_for_city) <> ctl_mr THEN
      RAISE EXCEPTION 'V5: the fixture changed a grease trap pair'; END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
  END;
  IF fx_inbox IS NOT TRUE THEN RAISE EXCEPTION 'V5 control: the fixture inbox did not take'; END IF;
  IF fx_mr_true <> 0 OR fx_mr_nfc < 10 THEN RAISE EXCEPTION 'V5: 214-MYK pairs with an inbox: % offered, % not_for_city', fx_mr_true, fx_mr_nfc; END IF;
  IF fx_dv_true <> 0 OR fx_dv_nfc < 10 THEN RAISE EXCEPTION 'V5: 214-MYK grey water visits with an inbox: % offered, % not_for_city', fx_dv_true, fx_dv_nfc; END IF;
  -- positive control: the same inbox DOES make 214-MYK's non-grey-water visits sendable, so the rule, not the data, is what refuses
  IF fx_dv_ok < 1 THEN RAISE EXCEPTION 'V5 control: the inbox made no 214-MYK non-grey-water visit sendable'; END IF;
  IF fx_mf <> 0 THEN RAISE EXCEPTION 'V5: % manifests counted 214-MYK as a city recipient', fx_mf; END IF;
  IF fx_ce_nfc <> 0 THEN RAISE EXCEPTION 'V5: % grey water pairs of 214-MYK list the inbox on the To line', fx_ce_nfc; END IF;
  -- control: the old To line would have shown the inbox on these pairs (the rule, not the data, removes it), and a
  -- 214-MYK pair with a city route (none today: all its manifest pairs are grey water) must show it
  IF fx_ce_raw < 10 THEN RAISE EXCEPTION 'V5 control: only % 214-MYK pairs sit on property 30', fx_ce_raw; END IF;
  IF fx_ce_ok <> fx_ce_route THEN
    RAISE EXCEPTION 'V5: % 214-MYK pairs have a city route, % show the inbox', fx_ce_route, fx_ce_ok; END IF;
  IF fx_cand IS DISTINCT FROM 'grey_water' THEN RAISE EXCEPTION 'V5: 214-MYK candidates read % with an inbox', fx_cand; END IF;
  IF (SELECT cardinality(coalesce(city_emails, '{}')) FROM public.properties WHERE id = 30) <> 0 THEN
    RAISE EXCEPTION 'V5: the fixture inbox survived the rollback'; END IF;

  -- V6 grants kept; the app role reads the new columns (invoker functions inside the list run as the caller)
  IF EXISTS (SELECT 1 FROM _rel_before b JOIN pg_class c ON c.oid = b.reloid
              WHERE c.relacl::text IS DISTINCT FROM b.acl OR c.reloptions::text IS DISTINCT FROM b.opts) THEN
    RAISE EXCEPTION 'V6: an ACL or reloptions changed'; END IF;
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) FILTER (WHERE not_for_city) INTO n FROM derm.manifest_recipients;
  SELECT count(*) FILTER (WHERE not_for_city) INTO n2 FROM derm.visits;
  SELECT count(*) INTO n3 FROM derm.manifests WHERE city_total_count > 0;
  EXECUTE 'RESET ROLE';
  IF n < 20 OR n2 < 30 OR n3 < 10 THEN RAISE EXCEPTION 'V6: authenticated reads % pairs, % visits, % manifests', n, n2, n3; END IF;

  -- V7 cost: every row fully built, the same statement as before the change (a bare count(*) over to_jsonb lets the
  -- planner drop the select list, so none of the new expressions would run)
  t0 := clock_timestamp(); SELECT sum(length(to_jsonb(d)::text)) INTO s FROM derm.visits d; dv_ms := extract(epoch FROM clock_timestamp() - t0) * 1000;
  t0 := clock_timestamp(); SELECT sum(length(to_jsonb(r)::text)) INTO s FROM derm.manifest_recipients r; mr_ms := extract(epoch FROM clock_timestamp() - t0) * 1000;
  t0 := clock_timestamp(); SELECT sum(length(to_jsonb(m)::text)) INTO s FROM derm.manifests m; mf_ms := extract(epoch FROM clock_timestamp() - t0) * 1000;
  t0 := clock_timestamp(); SELECT sum(length(to_jsonb(x)::text)) INTO s FROM derm.v_manifest_recipient_city_emails x; ce_ms := extract(epoch FROM clock_timestamp() - t0) * 1000;
  IF dv_ms > 5000 OR mr_ms > 5000 OR mf_ms > 5000 OR ce_ms > 5000 THEN
    RAISE EXCEPTION 'V7: derm.visits % ms, manifest_recipients % ms, manifests % ms, city emails % ms', dv_ms, mr_ms, mf_ms, ce_ms; END IF;

  RAISE NOTICE 'OK: % pairs and % visits are not_for_city; 0 of them offer a city route; everything else unchanged; with an inbox on 214-MYK property 30 the Tracker offers 0 of its % grey water pairs / % grey water visits (and % of its other visits, the control) and the candidates stay grey_water and the To line shows the inbox on exactly its % routed pairs; full builds: derm.visits % ms (was %), manifest_recipients % ms (was %), manifests % ms (was %), city emails % ms (was %)',
    (SELECT count(*) FROM derm.manifest_recipients WHERE not_for_city), (SELECT count(*) FROM derm.visits WHERE not_for_city),
    fx_mr_nfc, fx_dv_nfc, fx_dv_ok, fx_ce_ok, dv_ms, (SELECT dv FROM _ms), mr_ms, (SELECT mr FROM _ms), mf_ms, (SELECT mf FROM _ms), ce_ms, (SELECT ce FROM _ms);
END
$verify$;

NOTIFY pgrst, 'reload schema';

COMMIT;
