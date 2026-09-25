-- ============================================================================
-- 2026-09-24 · Grey water reports do not go to the city; the automatic city email stops using the test inbox
-- ============================================================================
-- THE ASK
--   Fred, 2026-09-24, asked whether a grey water visit's report should ever go to the city: "No, grey water
--   reports don't go to the city."
--
-- WHAT A READ-ONLY AUDIT FOUND FIRST (9 agents, each finding re-checked by a second one)
--   1. Nothing enforced that rule. No city mailer, view or DB function tested grey water. The only test near it
--      was send-visit-photos-email GATE 1 (stored derm_required = false), and the 30 completed grey water
--      visits deliberately kept stored TRUE (Fred: "leave the filed ones alone") pass it; the DERM email's
--      city arm and the hourly sweep had no test at all. It held only because none of the 8 grey water clients
--      has a city inbox on the property their visits are on. Proof the paths deliver grey water: test visit
--      8108 (112-YA, code 10) went through both city paths on 2026-09-15 (visit_photo_email_sends 179,
--      derm_email_sends 175), stopped only by the test gate of that morning.
--   2. Separate and worse: since 2026-09-22 10:36 ET app_config.city_email_test_recipient holds a staff
--      address (set on purpose that day to arm send-derm-email's fail-closed path for when live sending is
--      switched off). public.fn_request_city_email_sweep forwarded that key in EVERY request whatever the live
--      gate said, and send-derm-email honours a test_recipient in the body, so the next automatic city email
--      would have gone to that inbox as a test, logged is_test, never counted as sent, and been retried every
--      20 hours. Nothing was due since (0 ready, 0 waiting), so nothing was misdirected yet.
--
-- WHAT CHANGES
--   0. public.v_visit_grey_water_pumping gains a last column `tier` (1 own lines, 2 job, 3 invoice): the tier
--      whose lines decided "grey water". Same rule, same rows (asserted), rewritten from WHERE EXISTS to a
--      LATERAL so the tier can be returned. Its three readers use EXISTS on visit_id and are unchanged.
--   1. NEW public.v_visit_not_for_city (visit_id): the visits whose report never goes to a city inbox. Today
--      that is grey water pumping with NO line, on its deciding tier or nearer, that requires DERM or might
--      (fn_line_item_requires_derm IS NOT FALSE; fee/admin codes abstain). So a visit whose own lines are
--      grey water AND grease trap still reports (its report is a grease trap report too), an unknown line
--      keeps it reporting (the fail-safe reading), and a grease trap line that belongs to a SIBLING visit on
--      a shared invoice does not count (visit 7085: its own line is code 10; the 09 on invoice 2299 is
--      visits 6860 and 7323's). The first draft keyed this on fn_visit_requires_derm, which folds every tier
--      together and wrongly kept 7085 reporting; the review caught it.
--      Owner-rights view, SELECT to service_role only (both mailers use the service role; the derm view
--      below reads it with its owner's rights).
--   2. derm.v_city_email_candidates: a (manifest, client) pair whose live visits on the manifest are ALL on
--      that list gets the new status 'grey_water' (after already_sent and suppressed_manual, before every
--      other reason, so the reason shown is the rule and never "no city email", which would invite someone to
--      add one). No row is filtered away. A listed visit sharing a pair with a reporting visit is left out
--      of the pair's property resolution (properties, city_properties, property_id). Spliced from the live
--      text, md5 pinned; the column list is unchanged, so derm.v_city_email_queue (status = 'ready') is
--      untouched.
--   3. public.fn_request_city_email_sweep no longer puts test_recipient in the body at all. send-derm-email
--      reads city_email_test_recipient itself whenever city_email_live_sends is not true, so forwarding it
--      bought nothing while off and redirected everything while live. (A first draft gated the forward on
--      the live flag; the review showed SQL btrim and JS trim disagree on a stray tab or newline, which
--      would bring the redirect back.) The key's value is not touched. Spliced, md5 pinned; ACL, SECURITY
--      DEFINER, search_path and owner unchanged (asserted).
--   The two edge functions refuse the same visits in the same order (send-visit-photos-email before its
--   GATE 0; send-derm-email city arm before its property checks).
--
-- ORDER: apply THIS FILE FIRST, then deploy send-visit-photos-email and send-derm-email. Both read
-- public.v_visit_not_for_city and fail closed without it (Admin Review answers 503; the DERM city arm logs an
-- error, and three errors park a pair at too_many_errors for good). Old functions against the new DB are fine.
--
-- WHAT MOVES (measured in the dry run 2026-09-24 ~22:20 ET, re-asserted below)
--   - public.v_visit_not_for_city lists 65 visits: every grey water visit (33 completed, 30 of them stored TRUE
--     and filed; 32 scheduled). None is a grease trap visit (7849, 6860 and 7323 checked by name).
--   - public.v_visit_grey_water_pumping: the same 65 rows; 33 decided on tier 1 (own lines), the rest on the job.
--   - derm.v_city_email_candidates: 27 pairs now read grey_water; they read no_city_email (23) and no_property
--     (4). 0 mixed pairs. Every other pair is byte-identical. The queue is unchanged (empty).
--   - The sweep, run as throwaway copies: the OLD body forwarded the test recipient while live (the bug
--     reproduces); the new one forwards none, live or not.
--   - Cost: the sweep read (status = ready) 120 ms, derm.visits 515 ms (was about 500), work_orders 51 ms (same).
--
-- NOT CHANGED: any stored value, any city_emails, the client DERM email, the Field Portal, the LWT filing, the
-- GDO portal bot. Not changed and known: what the apps show BEFORE they call the server (Admin Review's
-- public.v_visit_city_email pre-check still says "no City email on file" for a grey water visit, and the DERM
-- Tracker's has_city_email flags do not know the rule); the server refusal is what enforces it.
-- 🛑 Do not SET search_path in this file: pg_get_viewdef leaves names unqualified that resolve on the current
-- path, and the EXECUTE must resolve them the same way.
-- AUDIT-TRAIL STANDING CHECK (rule 8): no table changes; views and functions are not audited.
-- ROLLBACK: FIRST redeploy send-visit-photos-email and send-derm-email from the commit before this one (they
-- read the view this rollback drops). THEN run docs/migrations/_baseline/2026-09-24_grey_water_not_for_city.before.sql
-- as a whole. It restores the candidates view and the sweep and drops the new view. The grey water view keeps
-- its `tier` column (CREATE OR REPLACE cannot drop a column; the rows are the same).
-- ============================================================================

BEGIN;

-- ---------- pre-flight
DO $pre$
BEGIN
  IF md5(pg_get_viewdef('derm.v_city_email_candidates'::regclass)) <> '67f6be35a8124f6844b5035bdf1ca5c8' THEN
    RAISE EXCEPTION 'derm.v_city_email_candidates changed since this migration was built; rebuild it'; END IF;
  IF md5(pg_get_viewdef('derm.v_city_email_queue'::regclass)) <> 'bbc0d0b8b3d8b23f119e0d2ee5280008' THEN
    RAISE EXCEPTION 'derm.v_city_email_queue changed since this migration was built; rebuild it'; END IF;
  IF md5(pg_get_functiondef('public.fn_request_city_email_sweep()'::regprocedure)) <> '71a71ffdb864367b5c0de0c2390c5471' THEN
    RAISE EXCEPTION 'fn_request_city_email_sweep changed since this migration was built; rebuild it'; END IF;
  IF md5(pg_get_viewdef('public.v_visit_grey_water_pumping'::regclass)) <> 'f1d733fbe1db7330cd11ef6112263393' THEN
    RAISE EXCEPTION 'public.v_visit_grey_water_pumping changed since this migration was built; rebuild it'; END IF;
  IF to_regclass('public.v_visit_not_for_city') IS NOT NULL THEN
    RAISE EXCEPTION 'public.v_visit_not_for_city already exists'; END IF;
END
$pre$;

-- ---------- snapshots
CREATE TEMP TABLE _cfg_before ON COMMIT DROP AS SELECT key, value FROM public.app_config;
CREATE TEMP TABLE _grey_before ON COMMIT DROP AS SELECT visit_id FROM public.v_visit_grey_water_pumping;
CREATE TEMP TABLE _dv_before ON COMMIT DROP AS SELECT id, grey_water_pumping FROM derm.visits;
CREATE TEMP TABLE _wo_before ON COMMIT DROP AS SELECT id FROM customer.work_orders;
CREATE TEMP TABLE _lwt_before ON COMMIT DROP AS SELECT visit_id FROM derm.v_lwt_grey_water_unlinked;
CREATE TEMP TABLE _grey_rel_before ON COMMIT DROP AS
  SELECT relacl::text AS acl, reloptions::text AS opts FROM pg_class
   WHERE oid = 'public.v_visit_grey_water_pumping'::regclass;
CREATE TEMP TABLE _cand_before ON COMMIT DROP AS
  SELECT c.manifest_id, c.client_id, c.status, to_jsonb(c) AS j FROM derm.v_city_email_candidates c;
CREATE TEMP TABLE _queue_before ON COMMIT DROP AS SELECT to_jsonb(q) AS j FROM derm.v_city_email_queue q;
CREATE TEMP TABLE _sweep_before ON COMMIT DROP AS
  SELECT pg_get_functiondef(p.oid) AS d, p.proacl::text AS acl, p.prosecdef AS secdef, p.proconfig::text AS cfg, p.proowner AS owner
    FROM pg_proc p WHERE p.oid = 'public.fn_request_city_email_sweep()'::regprocedure;
CREATE TEMP TABLE _rel_before ON COMMIT DROP AS
  SELECT oid AS reloid, relacl::text AS acl, reloptions::text AS opts FROM pg_class
   WHERE oid IN ('derm.v_city_email_candidates'::regclass, 'derm.v_city_email_queue'::regclass);
CREATE TEMP TABLE _cols_before ON COMMIT DROP AS
  SELECT attnum, attname, atttypid FROM pg_attribute
   WHERE attrelid = 'derm.v_city_email_candidates'::regclass AND attnum > 0 AND NOT attisdropped;

-- ---------- 0. the grey water rule returns the tier that decided it
CREATE OR REPLACE VIEW public.v_visit_grey_water_pumping AS
SELECT v.id AS visit_id, t.tier
  FROM public.visits v
  CROSS JOIN LATERAL (
   WITH lc AS (
     SELECT lpad(substring(btrim(li.name) from '^([0-9]{1,2})[[:space:]]*-[[:space:]]'), 2, '0') AS code,
            public.fn_line_item_is_free_text_grey_water(li.name) AS free_text_grey,
            CASE WHEN li.visit_id = v.id THEN 1 WHEN v.job_id IS NOT NULL AND li.job_id = v.job_id THEN 2 ELSE 3 END AS tier
       FROM public.line_items li
      WHERE li.name IS NOT NULL
        AND (li.visit_id = v.id OR (v.job_id IS NOT NULL AND li.job_id = v.job_id)
             OR (v.invoice_id IS NOT NULL AND li.invoice_id = v.invoice_id))
   ), svc AS (
     SELECT lc.tier, (s.service_type = 'Pumping' AND s.location_target = 'Grey Water') AS grey
       FROM lc JOIN public.service_line_items s ON s.code = lc.code
      WHERE s.reason NOT IN ('fee','other')
     UNION ALL
     SELECT lc.tier, true AS grey FROM lc WHERE lc.free_text_grey
   )
   SELECT min(svc.tier) AS tier
     FROM svc
    WHERE svc.tier = (SELECT min(svc2.tier) FROM svc svc2)
      AND svc.grey
  ) t
 WHERE v.deleted_at IS NULL
   AND t.tier IS NOT NULL;
COMMENT ON VIEW public.v_visit_grey_water_pumping IS
  'THE grey water pumping rule, once (2026-09-24): live (not soft-deleted) visits only; among the service lines a visit reaches, those on the nearest tier (own lines, else job, else invoice) include catalogue Pumping + Grey Water (03, 10) or a free-text grey water line (fn_line_item_is_free_text_grey_water); fee/admin codes abstain. `tier` is that nearest tier (1 own, 2 job, 3 invoice; 2026-09-24_2110). No status filter: consumers add their own. Read by customer.work_orders (Field Portal keeps grey water visible), derm.visits.grey_water_pumping (DERM Tracker bulk dialog), derm.v_lwt_grey_water_unlinked (LWT tracker) and public.v_visit_not_for_city. Owner-rights consumers read it; no app role needs a grant.';

-- ---------- 1. the list
CREATE VIEW public.v_visit_not_for_city AS
SELECT g.visit_id
  FROM public.v_visit_grey_water_pumping g
  JOIN public.visits v ON v.id = g.visit_id
 WHERE NOT EXISTS (
   SELECT 1
     FROM public.line_items li
     LEFT JOIN public.service_line_items s
       ON s.code = lpad(substring(btrim(li.name) from '^([0-9]{1,2})[[:space:]]*-[[:space:]]'), 2, '0')
    WHERE li.name IS NOT NULL
      AND (li.visit_id = v.id OR (v.job_id IS NOT NULL AND li.job_id = v.job_id)
           OR (v.invoice_id IS NOT NULL AND li.invoice_id = v.invoice_id))
      AND CASE WHEN li.visit_id = v.id THEN 1 WHEN v.job_id IS NOT NULL AND li.job_id = v.job_id THEN 2 ELSE 3 END <= g.tier
      AND s.reason IS DISTINCT FROM 'fee' AND s.reason IS DISTINCT FROM 'other'
      AND public.fn_line_item_requires_derm(li.name) IS NOT FALSE);
COMMENT ON VIEW public.v_visit_not_for_city IS
  'Visits whose report never goes to a city inbox (Fred, 2026-09-24: "No, grey water reports don''t go to the city"). Today: grey water pumping (public.v_visit_grey_water_pumping) with no line, on its deciding tier or nearer, that requires DERM or might (fn_line_item_requires_derm IS NOT FALSE; fee/admin codes abstain). A visit whose own lines are grey water and grease trap still reports. Read by send-visit-photos-email, send-derm-email (city arm) and derm.v_city_email_candidates (status grey_water). 2026-09-24_2110.';
-- Supabase default privileges grant BY NAME on every new view; revoke them by name, grant back the one read.
REVOKE ALL ON public.v_visit_not_for_city FROM PUBLIC, anon, authenticated, service_role, yannick_readonly;
GRANT SELECT ON public.v_visit_not_for_city TO service_role;

-- ---------- 2. the candidates view
DO $cand$
DECLARE
  d  text := pg_get_viewdef('derm.v_city_email_candidates'::regclass);
  a1 text := $oldres$        ), resolved AS (
         SELECT d.manifest_id,
            d.client_id,
            d.blacked_at,
            d.pages,
            count(DISTINCT v.property_id) AS properties,
            count(DISTINCT p.id) AS city_properties,
            min(p.id) AS property_id
           FROM (((docs d
             LEFT JOIN manifest_visits mv ON ((mv.manifest_id = d.manifest_id)))
             LEFT JOIN visits v ON (((v.id = mv.visit_id) AND (v.deleted_at IS NULL) AND (v.client_id = d.client_id))))
             LEFT JOIN properties p ON (((p.id = v.property_id) AND (p.deleted_at IS NULL) AND (p.city_emails IS NOT NULL) AND (cardinality(p.city_emails) > 0))))
          GROUP BY d.manifest_id, d.client_id, d.blacked_at, d.pages
$oldres$;
  b1 text := $newres$        ), resolved AS (
         SELECT d.manifest_id,
            d.client_id,
            d.blacked_at,
            d.pages,
            count(DISTINCT v.property_id) FILTER (WHERE (nfc.visit_id IS NULL)) AS properties,
            count(DISTINCT p.id) FILTER (WHERE (nfc.visit_id IS NULL)) AS city_properties,
            min(p.id) FILTER (WHERE (nfc.visit_id IS NULL)) AS property_id,
            count(DISTINCT v.id) AS visits,
            count(DISTINCT v.id) FILTER (WHERE (nfc.visit_id IS NULL)) AS city_visits
           FROM ((((docs d
             LEFT JOIN manifest_visits mv ON ((mv.manifest_id = d.manifest_id)))
             LEFT JOIN visits v ON (((v.id = mv.visit_id) AND (v.deleted_at IS NULL) AND (v.client_id = d.client_id))))
             LEFT JOIN public.v_visit_not_for_city nfc ON ((nfc.visit_id = v.id)))
             LEFT JOIN properties p ON (((p.id = v.property_id) AND (p.deleted_at IS NULL) AND (p.city_emails IS NOT NULL) AND (cardinality(p.city_emails) > 0))))
          GROUP BY d.manifest_id, d.client_id, d.blacked_at, d.pages
$newres$;
  a2 text := $oldcase$            WHEN (sup.manifest_id IS NOT NULL) THEN 'suppressed_manual'::text
$oldcase$;
  b2 text := $newcase$            WHEN (sup.manifest_id IS NOT NULL) THEN 'suppressed_manual'::text
            WHEN ((r.visits > 0) AND (r.city_visits = 0)) THEN 'grey_water'::text
$newcase$;
BEGIN
  IF length(d) - length(replace(d, a1, '')) <> length(a1) THEN RAISE EXCEPTION 'candidates: resolved CTE not found exactly once'; END IF;
  IF length(d) - length(replace(d, a2, '')) <> length(a2) THEN RAISE EXCEPTION 'candidates: status anchor not found exactly once'; END IF;
  EXECUTE 'CREATE OR REPLACE VIEW derm.v_city_email_candidates AS ' || rtrim(replace(replace(d, a1, b1), a2, b2), ';');
END
$cand$;

-- ---------- 3. the sweep
DO $sweep$
DECLARE
  d  text := pg_get_functiondef('public.fn_request_city_email_sweep()'::regprocedure);
  a  text := $oldsw$  select nullif(btrim(value), '') into v_test
    from public.app_config where key = 'city_email_test_recipient';
  if v_test is not null then
    v_body := v_body || jsonb_build_object('test_recipient', v_test);
  end if;
$oldsw$;
  b  text := $newsw$  -- 2026-09-24_2110: no test_recipient in the body. send-derm-email reads city_email_test_recipient itself
  -- whenever city_email_live_sends is not true (and refuses if it is unusable), so forwarding it bought
  -- nothing while off, and while live it redirected every automatic city email to that inbox as a test
  -- (the key holds a staff address since 2026-09-22, arming the mailer fail-closed path).
$newsw$;
  a2 text := $olddecl$  v_test  text;
$olddecl$;
BEGIN
  IF length(d) - length(replace(d, a, '')) <> length(a) THEN RAISE EXCEPTION 'sweep: test-recipient block not found exactly once'; END IF;
  IF length(d) - length(replace(d, a2, '')) <> length(a2) THEN RAISE EXCEPTION 'sweep: v_test declaration not found exactly once'; END IF;
  EXECUTE replace(replace(d, a, b), a2, '');
END
$sweep$;

-- ---------- VERIFY
DO $verify$
DECLARE
  n int; n2 int; n3 int; r text; t0 timestamptz; ms_cand int; ms_dv int; ms_wo int;
  sweep_old text := (SELECT d FROM _sweep_before);
  sweep_new text := pg_get_functiondef('public.fn_request_city_email_sweep()'::regprocedure);
  new_live boolean; old_live boolean; new_off boolean; probe_rows int;
  inv7085 bigint := (SELECT invoice_id FROM public.visits WHERE id = 7085);
  vA bigint; vB bigint; vC bigint; vD bigint; vE bigint; fx text;
BEGIN
  -- V0 the grey water rule: same rows, a tier on every row, readers unchanged, ACL and reloptions kept
  IF EXISTS ((SELECT visit_id FROM _grey_before EXCEPT SELECT visit_id FROM public.v_visit_grey_water_pumping)
             UNION ALL (SELECT visit_id FROM public.v_visit_grey_water_pumping EXCEPT SELECT visit_id FROM _grey_before)) THEN
    RAISE EXCEPTION 'V0: the grey water rows changed'; END IF;
  IF (SELECT count(*) FROM _grey_before) < 60 THEN RAISE EXCEPTION 'V0 control: only % grey water rows', (SELECT count(*) FROM _grey_before); END IF;
  IF EXISTS (SELECT 1 FROM public.v_visit_grey_water_pumping WHERE tier IS NULL OR tier NOT IN (1, 2, 3)) THEN
    RAISE EXCEPTION 'V0: a grey water row has no valid tier'; END IF;
  IF (SELECT tier FROM public.v_visit_grey_water_pumping WHERE visit_id = 7085) IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'V0: 7085 (own line 10) is not decided on tier 1'; END IF;
  IF EXISTS (SELECT 1 FROM _dv_before b JOIN derm.visits d ON d.id = b.id WHERE d.grey_water_pumping IS DISTINCT FROM b.grey_water_pumping)
     OR (SELECT count(*) FROM derm.visits) <> (SELECT count(*) FROM _dv_before) THEN
    RAISE EXCEPTION 'V0: derm.visits.grey_water_pumping changed'; END IF;
  IF EXISTS ((SELECT id FROM _wo_before EXCEPT SELECT id FROM customer.work_orders)
             UNION ALL (SELECT id FROM customer.work_orders EXCEPT SELECT id FROM _wo_before)) THEN
    RAISE EXCEPTION 'V0: customer.work_orders changed'; END IF;
  IF EXISTS ((SELECT visit_id FROM _lwt_before EXCEPT SELECT visit_id FROM derm.v_lwt_grey_water_unlinked)
             UNION ALL (SELECT visit_id FROM derm.v_lwt_grey_water_unlinked EXCEPT SELECT visit_id FROM _lwt_before)) THEN
    RAISE EXCEPTION 'V0: derm.v_lwt_grey_water_unlinked changed'; END IF;
  IF EXISTS (SELECT 1 FROM _grey_rel_before b JOIN pg_class c ON c.oid = 'public.v_visit_grey_water_pumping'::regclass
              WHERE c.relacl::text IS DISTINCT FROM b.acl OR c.reloptions::text IS DISTINCT FROM b.opts) THEN
    RAISE EXCEPTION 'V0: the grey water view ACL or reloptions changed'; END IF;

  -- V1 the list: named members and non-members, then rolled-back fixtures for five shapes
  SELECT count(*) INTO n FROM public.v_visit_not_for_city;
  IF n < 60 THEN RAISE EXCEPTION 'V1 control: only % visits on the list (65 measured)', n; END IF;
  IF (SELECT count(*) FROM public.v_visit_not_for_city WHERE visit_id IN (6710, 6497, 3931, 5159, 6507, 8185, 7085)) <> 7 THEN
    RAISE EXCEPTION 'V1: a grey water control (6710, 6497, 3931, 5159, 6507, 8185, 7085) is not on the list'; END IF;
  IF EXISTS (SELECT 1 FROM public.v_visit_not_for_city WHERE visit_id IN (7849, 6860, 7323)) THEN
    RAISE EXCEPTION 'V1: a grease trap visit (7849, or 6860 / 7323 on invoice 2299) is on the list'; END IF;
  IF EXISTS (SELECT 1 FROM public.v_visit_not_for_city n1 WHERE NOT EXISTS (SELECT 1 FROM public.v_visit_grey_water_pumping g WHERE g.visit_id = n1.visit_id)) THEN
    RAISE EXCEPTION 'V1: a listed visit is not grey water pumping'; END IF;
  IF inv7085 IS NULL THEN RAISE EXCEPTION 'V1: 7085 has no invoice to model the shared-invoice fixture on'; END IF;
  BEGIN
    EXECUTE 'SET LOCAL app.suppress_jobber_push = ''on''';
    INSERT INTO public.visits (client_id, property_id, visit_date, visit_status, title, completed_at)
      VALUES (381, 162, DATE '2026-09-20', 'completed', '[TEST] not-for-city fixture A', now()) RETURNING id INTO vA;
    INSERT INTO public.visits (client_id, property_id, visit_date, visit_status, title, completed_at)
      VALUES (381, 162, DATE '2026-09-20', 'completed', '[TEST] not-for-city fixture B', now()) RETURNING id INTO vB;
    INSERT INTO public.visits (client_id, property_id, visit_date, visit_status, title, completed_at)
      VALUES (381, 162, DATE '2026-09-20', 'completed', '[TEST] not-for-city fixture C', now()) RETURNING id INTO vC;
    INSERT INTO public.visits (client_id, property_id, visit_date, visit_status, title, completed_at)
      VALUES (381, 162, DATE '2026-09-20', 'completed', '[TEST] not-for-city fixture D', now()) RETURNING id INTO vD;
    INSERT INTO public.visits (client_id, property_id, visit_date, visit_status, title, completed_at, invoice_id)
      VALUES (381, 162, DATE '2026-09-20', 'completed', '[TEST] not-for-city fixture E', now(), inv7085) RETURNING id INTO vE;
    INSERT INTO public.line_items (visit_id, name, quantity, unit_price, total_price) VALUES
      (vA, '03 - Service Agreement - Pumping - Grey Water', 1, 0, 0),
      (vB, '03 - Service Agreement - Pumping - Grey Water', 1, 0, 0),
      (vB, '01 - Service Agreement - Pumping - Grease Trap & Tank Cleaning', 1, 0, 0),
      (vC, 'Grey Water Pumping', 1, 0, 0),
      (vD, '01 - Service Agreement - Pumping - Grease Trap & Tank Cleaning', 1, 0, 0),
      (vE, '10 - Service Call - Pumping - Grey Water', 1, 0, 0);
    SELECT string_agg(format('%s=%s(want %s)', f.lbl, EXISTS (SELECT 1 FROM public.v_visit_not_for_city x WHERE x.visit_id = f.vid), f.want), '; ')
      INTO fx
      FROM (VALUES ('A coded grey water', vA, true), ('B own grey water + grease trap', vB, false),
                   ('C typed grey water', vC, true), ('D grease trap', vD, false),
                   ('E grey water on a shared GT invoice', vE, true)) f(lbl, vid, want)
     WHERE EXISTS (SELECT 1 FROM public.v_visit_not_for_city x WHERE x.visit_id = f.vid) IS DISTINCT FROM f.want;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
  END;
  IF fx IS NOT NULL THEN RAISE EXCEPTION 'V1 fixtures: %', fx; END IF;

  -- V2 the candidates view: same pairs; a pair with no listed visit is byte-identical; a pair whose visits are
  -- all listed reads grey_water (unless it was already sent or suppressed); a mixed pair never reads grey_water.
  IF (SELECT count(*) FROM derm.v_city_email_candidates) <> (SELECT count(*) FROM _cand_before) THEN
    RAISE EXCEPTION 'V2: candidate row count changed'; END IF;
  IF EXISTS (SELECT 1 FROM _cand_before b FULL JOIN derm.v_city_email_candidates c USING (manifest_id, client_id)
              WHERE b.manifest_id IS NULL OR c.manifest_id IS NULL) THEN
    RAISE EXCEPTION 'V2: the set of (manifest, client) pairs changed'; END IF;
  CREATE TEMP TABLE _pair_nfc ON COMMIT DROP AS
    SELECT b.manifest_id, b.client_id, count(v.id) AS n_visits, count(x.visit_id) AS n_nfc
      FROM _cand_before b
      LEFT JOIN public.manifest_visits mv ON mv.manifest_id = b.manifest_id
      LEFT JOIN public.visits v ON v.id = mv.visit_id AND v.deleted_at IS NULL AND v.client_id = b.client_id
      LEFT JOIN public.v_visit_not_for_city x ON x.visit_id = v.id
     GROUP BY 1, 2;
  SELECT count(*) INTO n FROM _pair_nfc p JOIN _cand_before b USING (manifest_id, client_id)
    JOIN derm.v_city_email_candidates c USING (manifest_id, client_id)
   WHERE p.n_nfc = 0 AND to_jsonb(c) IS DISTINCT FROM b.j;
  IF n <> 0 THEN RAISE EXCEPTION 'V2: % pairs with no listed visit changed', n; END IF;
  SELECT count(*) INTO n FROM _pair_nfc p JOIN derm.v_city_email_candidates c USING (manifest_id, client_id)
    JOIN _cand_before b USING (manifest_id, client_id)
   WHERE p.n_visits > 0 AND p.n_nfc = p.n_visits
     AND c.status IS DISTINCT FROM (CASE WHEN b.status IN ('already_sent', 'suppressed_manual') THEN b.status ELSE 'grey_water' END);
  IF n <> 0 THEN RAISE EXCEPTION 'V2: % all-grey-water pairs do not read grey_water', n; END IF;
  SELECT count(*) INTO n2 FROM derm.v_city_email_candidates WHERE status = 'grey_water';
  IF n2 < 20 THEN RAISE EXCEPTION 'V2 control: only % pairs read grey_water (about 27 expected)', n2; END IF;
  SELECT count(*) INTO n3 FROM _pair_nfc WHERE n_nfc > 0 AND n_nfc < n_visits;
  IF EXISTS (SELECT 1 FROM _pair_nfc p JOIN derm.v_city_email_candidates c USING (manifest_id, client_id)
              WHERE p.n_nfc > 0 AND p.n_nfc < p.n_visits AND c.status = 'grey_water') THEN
    RAISE EXCEPTION 'V2: a mixed pair reads grey_water'; END IF;
  -- no send that was due or waiting is silently cancelled today (0 expected; if this fires, look before shipping)
  SELECT count(*) INTO n FROM _cand_before b JOIN derm.v_city_email_candidates c USING (manifest_id, client_id)
   WHERE c.status = 'grey_water' AND b.status IN ('ready', 'waiting', 'before_go_live');
  IF n <> 0 THEN RAISE EXCEPTION 'V2: % pairs that were due, waiting or before go-live now read grey_water: review them first', n; END IF;
  SELECT string_agg(format('%s %s', s, k), ', ' ORDER BY s) INTO r
    FROM (SELECT b.status s, count(*) k FROM _cand_before b JOIN derm.v_city_email_candidates c USING (manifest_id, client_id)
           WHERE c.status = 'grey_water' GROUP BY 1) z;

  -- V3 the queue is unchanged
  IF EXISTS ((SELECT j FROM _queue_before EXCEPT ALL SELECT to_jsonb(q) FROM derm.v_city_email_queue q)
             UNION ALL (SELECT to_jsonb(q) FROM derm.v_city_email_queue q EXCEPT ALL SELECT j FROM _queue_before)) THEN
    RAISE EXCEPTION 'V3: derm.v_city_email_queue changed'; END IF;

  -- V4 the sweep: attributes kept; no test_recipient left in the body text; then the old and new bodies run
  -- as throwaway copies whose URL is https://probe.invalid/..., whose key is a dummy and whose queue is one
  -- fake row, inside a rolled-back subtransaction. pg_net only sends committed queue rows, and even a
  -- committed one would go nowhere.
  IF EXISTS (SELECT 1 FROM _sweep_before s JOIN pg_proc p ON p.oid = 'public.fn_request_city_email_sweep()'::regprocedure
              WHERE p.proacl::text IS DISTINCT FROM s.acl OR p.prosecdef IS DISTINCT FROM s.secdef
                 OR p.proconfig::text IS DISTINCT FROM s.cfg OR p.proowner IS DISTINCT FROM s.owner) THEN
    RAISE EXCEPTION 'V4: the sweep lost its ACL, SECURITY DEFINER, search_path or owner'; END IF;
  IF md5(sweep_new) = md5(sweep_old) THEN RAISE EXCEPTION 'V4: the sweep did not change'; END IF;
  IF position('jsonb_build_object(''test_recipient''' in sweep_new) > 0 OR position('v_test' in sweep_new) > 0 THEN
    RAISE EXCEPTION 'V4: the new sweep still builds a test_recipient'; END IF;
  IF position('jsonb_build_object(''test_recipient''' in sweep_old) = 0 THEN
    RAISE EXCEPTION 'V4 control: the old sweep text does not build a test_recipient'; END IF;
  BEGIN
    CREATE TEMP TABLE _fake_queue (manifest_id bigint, client_id bigint, property_id bigint,
                                   manual_include_photos boolean, manual_visit_id bigint);
    INSERT INTO _fake_queue VALUES (-1, 381, 162, true, -1);
    DECLARE
      probe text;
      nm text;
      src text;
    BEGIN
      FOR nm, src IN SELECT * FROM (VALUES ('probe_sweep_old', sweep_old), ('probe_sweep_new', sweep_new)) z LOOP
        probe := src;
        IF (length(probe) - length(replace(probe, 'CREATE OR REPLACE FUNCTION public.fn_request_city_email_sweep()', ''))) / length('CREATE OR REPLACE FUNCTION public.fn_request_city_email_sweep()') <> 1
           OR (length(probe) - length(replace(probe, 'from (select * from derm.v_city_email_queue order by blacked_at limit v_limit) q;', ''))) / length('from (select * from derm.v_city_email_queue order by blacked_at limit v_limit) q;') <> 1
           OR (length(probe) - length(replace(probe, E'select decrypted_secret into v_key\n    from vault.decrypted_secrets where name = ''edge_invoke_service_key'';', ''))) / length(E'select decrypted_secret into v_key\n    from vault.decrypted_secrets where name = ''edge_invoke_service_key'';') <> 1
           OR (length(probe) - length(replace(probe, 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/send-derm-email', ''))) / length('https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/send-derm-email') <> 1 THEN
          RAISE EXCEPTION 'V4: a probe anchor is not unique in %', nm;
        END IF;
        probe := replace(probe, 'CREATE OR REPLACE FUNCTION public.fn_request_city_email_sweep()', 'CREATE FUNCTION pg_temp.' || nm || '()');
        probe := replace(probe, 'from (select * from derm.v_city_email_queue order by blacked_at limit v_limit) q;', 'from (select * from pg_temp._fake_queue) q;');
        probe := replace(probe, E'select decrypted_secret into v_key\n    from vault.decrypted_secrets where name = ''edge_invoke_service_key'';', 'v_key := ''probe-not-a-key'';');
        probe := replace(probe, 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/send-derm-email', 'https://probe.invalid/send-derm-email');
        EXECUTE probe;
      END LOOP;
    END;
    UPDATE public.app_config SET value = 'probe@ayache.com' WHERE key = 'city_email_test_recipient';
    UPDATE public.app_config SET value = 'true' WHERE key = 'city_email_live_sends';
    PERFORM pg_temp.probe_sweep_new();
    SELECT convert_from(body, 'UTF8')::jsonb ? 'test_recipient' INTO new_live FROM net.http_request_queue
     WHERE url = 'https://probe.invalid/send-derm-email' ORDER BY id DESC LIMIT 1;
    PERFORM pg_temp.probe_sweep_old();
    SELECT convert_from(body, 'UTF8')::jsonb ? 'test_recipient' INTO old_live FROM net.http_request_queue
     WHERE url = 'https://probe.invalid/send-derm-email' ORDER BY id DESC LIMIT 1;
    UPDATE public.app_config SET value = 'false' WHERE key = 'city_email_live_sends';
    PERFORM pg_temp.probe_sweep_new();
    SELECT convert_from(body, 'UTF8')::jsonb ? 'test_recipient' INTO new_off FROM net.http_request_queue
     WHERE url = 'https://probe.invalid/send-derm-email' ORDER BY id DESC LIMIT 1;
    SELECT count(*) INTO probe_rows FROM net.http_request_queue WHERE url = 'https://probe.invalid/send-derm-email';
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
  END;
  IF probe_rows IS DISTINCT FROM 3 THEN RAISE EXCEPTION 'V4 control: % probe requests queued, expected 3', probe_rows; END IF;
  IF old_live IS NOT TRUE THEN RAISE EXCEPTION 'V4 control: the OLD sweep did not forward the test recipient while live (the bug must reproduce)'; END IF;
  IF new_live IS NOT FALSE OR new_off IS NOT FALSE THEN RAISE EXCEPTION 'V4: the new sweep still forwards a test recipient'; END IF;
  IF EXISTS (SELECT 1 FROM net.http_request_queue WHERE url LIKE 'https://probe.invalid/%') THEN
    RAISE EXCEPTION 'V4: a probe request survived the rollback'; END IF;
  IF EXISTS ((SELECT key, value FROM _cfg_before EXCEPT SELECT key, value FROM public.app_config)
             UNION ALL (SELECT key, value FROM public.app_config EXCEPT SELECT key, value FROM _cfg_before)) THEN
    RAISE EXCEPTION 'V4: app_config did not come back to its values before the probe'; END IF;

  -- V5 grants, columns
  IF (SELECT relacl::text FROM pg_class WHERE oid = 'public.v_visit_not_for_city'::regclass)
     IS DISTINCT FROM '{postgres=arwdDxtm/postgres,service_role=r/postgres}' THEN
    RAISE EXCEPTION 'V5: the new view ACL is %', (SELECT relacl::text FROM pg_class WHERE oid = 'public.v_visit_not_for_city'::regclass); END IF;
  IF has_table_privilege('anon', 'public.v_visit_not_for_city', 'SELECT') OR has_table_privilege('authenticated', 'public.v_visit_not_for_city', 'SELECT') THEN
    RAISE EXCEPTION 'V5: an app role can read the new view'; END IF;
  IF EXISTS (SELECT 1 FROM _rel_before b JOIN pg_class c ON c.oid = b.reloid
              WHERE c.relacl::text IS DISTINCT FROM b.acl OR c.reloptions::text IS DISTINCT FROM b.opts) THEN
    RAISE EXCEPTION 'V5: the candidates or queue ACL changed'; END IF;
  IF EXISTS (SELECT 1 FROM _cols_before b FULL JOIN (SELECT attnum, attname, atttypid FROM pg_attribute
               WHERE attrelid = 'derm.v_city_email_candidates'::regclass AND attnum > 0 AND NOT attisdropped) a USING (attnum)
              WHERE a.attname IS DISTINCT FROM b.attname OR a.atttypid IS DISTINCT FROM b.atttypid) THEN
    RAISE EXCEPTION 'V5: the candidates column list changed'; END IF;
  EXECUTE 'SET LOCAL ROLE service_role';
  SELECT count(*) INTO n FROM public.v_visit_not_for_city;
  SELECT count(*) INTO n2 FROM derm.v_city_email_candidates WHERE status = 'grey_water';
  EXECUTE 'RESET ROLE';
  IF n < 60 OR n2 < 20 THEN RAISE EXCEPTION 'V5: service_role reads % listed visits and % grey_water pairs', n, n2; END IF;
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO n FROM customer.work_orders;
  SELECT count(*) FILTER (WHERE grey_water_pumping) INTO n2 FROM derm.visits;
  EXECUTE 'RESET ROLE';
  IF n < 700 OR n2 < 27 THEN RAISE EXCEPTION 'V5: authenticated reads % work orders and % grey visits', n, n2; END IF;

  -- V6 cost: reads that NEED the status and the join (the sweep's own read), and the two app readers of the grey view
  t0 := clock_timestamp(); PERFORM count(*) FROM derm.v_city_email_candidates WHERE status = 'ready';
  PERFORM * FROM derm.v_city_email_queue ORDER BY blacked_at LIMIT 50;
  ms_cand := extract(epoch FROM clock_timestamp() - t0) * 1000;
  t0 := clock_timestamp(); PERFORM count(*) FILTER (WHERE grey_water_pumping) + count(*) FILTER (WHERE line_items IS NOT NULL) FROM derm.visits;
  ms_dv := extract(epoch FROM clock_timestamp() - t0) * 1000;
  t0 := clock_timestamp(); PERFORM count(*) FROM customer.work_orders; ms_wo := extract(epoch FROM clock_timestamp() - t0) * 1000;
  IF ms_cand > 5000 OR ms_dv > 5000 OR ms_wo > 5000 THEN RAISE EXCEPTION 'V6: candidates % ms, derm.visits % ms, work_orders % ms', ms_cand, ms_dv, ms_wo; END IF;

  RAISE NOTICE 'OK: % visits not for the city; % pairs now grey_water (they were: %); % mixed pairs; queue unchanged; grey rule rows unchanged (% with tier 1); sweep never forwards a test recipient (old body did while live: %); status read % ms, derm.visits % ms, work_orders % ms',
    (SELECT count(*) FROM public.v_visit_not_for_city), (SELECT count(*) FROM derm.v_city_email_candidates WHERE status = 'grey_water'), r, n3,
    (SELECT count(*) FROM public.v_visit_grey_water_pumping WHERE tier = 1), old_live, ms_cand, ms_dv, ms_wo;
END
$verify$;

NOTIFY pgrst, 'reload schema';

COMMIT;
