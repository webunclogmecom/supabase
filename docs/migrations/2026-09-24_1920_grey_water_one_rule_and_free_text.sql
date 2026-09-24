-- ============================================================================
-- 2026-09-24 · Grey water: ONE rule for "is this visit grey water pumping", and free-text grey water is
--              not DERM required
-- ============================================================================
-- APPLIED 2026-09-24 ~19:52 ET, after A (2026-09-24_1910). Live read after: grey water rule 33 visits in
-- derm.visits (was 27), 65 in the shared view (it has no status filter), work orders 799 (unchanged), LWT 0,
-- permits 133 row-identical (V8), ops.v_derm_human_override_conflict 63 (was 64), 253-CG no DERM activity,
-- "Grey Water Pumping" FALSE, "GT & grey water pumping" and "Grease trap & grey water pumping" still TRUE.
-- THE ASK
--   Fred, 2026-09-24: "Go ahead with all these, but skip 11." Two of those items are this file:
--   10. "A grey water line typed as free text (no code, like 'Grey Water Pumping') still reads as DERM
--       required."
--   12. "The grey water rule now exists in two places: the Field Portal view and the new DERM column. A
--       future change to one must change the other." Measured while building this: THREE places. The LWT
--       tracker view derm.v_lwt_grey_water_unlinked (2026-09-24_1220) carried its own, looser copy (any 03/10
--       line on the visit, its job or its invoice; no own-lines-first; no free text).
--
-- WHAT CHANGES
--   1. NEW public.fn_line_item_is_free_text_grey_water(text): IMMUTABLE, pure (no table). An EXACT-PHRASE
--      ALLOWLIST, anchored at both ends: the WHOLE line must be "grey water pumping" in one of its spellings
--      (grey or gray, "greywater" or "grey-water", pump / pumps / pumped / pumping, an optional "out"), or the
--      reverse order ("pump out the grey water"). Anything else on the line ("GT & grey water pumping",
--      "Grease trap & grey water pumping", "Grey water pumping (GT)") is NOT matched and keeps its old answer,
--      because a mixed line may be a grease trap too and the county then needs its manifest. A permissive
--      "names grey water and no other vessel" test was drafted first and rejected in review: it read "GT" and
--      "Grease" as no vessel and moved mixed lines TRUE -> FALSE. Live data holds exactly two matching names
--      today, "Grey Water Pumping" and "Grey water pumping". EXECUTE to PUBLIC because
--      fn_line_item_requires_derm (SECURITY INVOKER, EXECUTE to PUBLIC) now calls it, so every caller of the
--      classifier needs it; it reads nothing, so the grant exposes nothing.
--   2. public.fn_line_item_requires_derm: one new arm (b0) before the free-text pumping arm: such a line
--      answers what the CATALOGUE says for grey water pumping (bool_and of requires_derm over the Pumping +
--      Grey Water codes, FALSE today since 2026-09-24_1220), so the policy still lives in one place, the
--      catalogue flag, and flipping 03/10 back would carry the free text with it. Spliced, md5 pinned.
--   3. NEW public.v_visit_grey_water_pumping (visit_id): THE grey water rule, once. A live (not soft-deleted)
--      visit is grey water pumping when, among the service lines it reaches, those on the nearest tier (its
--      own lines, else its job's, else its invoice's) include grey water pumping: catalogue Pumping + Grey
--      Water (03, 10), or a free-text grey water line (1.). Fee/admin codes (reason fee/other) abstain. Same
--      rule as 2026-09-24_1353 plus the free-text arm. owner-rights view, SELECT to service_role only: the three
--      consumers are owner-rights views too, so they read it with their owner's rights and no role needs a
--      grant on it. (Nested views are checked as the outer view's owner; a FUNCTION would have been checked
--      as the caller, the trap Supabase CLAUDE.md records five times.)
--   4. The three copies become `EXISTS (SELECT 1 FROM public.v_visit_grey_water_pumping gwp WHERE
--      gwp.visit_id = <visit>)`, each spliced from its live text (md5 pinned, the old rule counted to once):
--        customer.work_orders            (the Field Portal's WHERE arm)
--        derm.visits.grey_water_pumping  (the DERM Tracker bulk dialog)
--        derm.v_lwt_grey_water_unlinked  (the LWT tracker; now own-lines-first + free text, like the others)
--      Columns, ACLs and reloptions are unchanged (asserted).
--
-- WHAT MOVES, measured 2026-09-24 ~19:00 ET and re-asserted below
--   - fn_line_item_requires_derm: TRUE -> FALSE on the two free-text names only (asserted over every distinct
--     line name in the database and every catalogue title).
--   - fn_visit_requires_derm: TRUE -> FALSE on the 11 COMPLETED visits that reach those lines. No stored value
--     changes: the automatic writers never demote a TRUE, and 10 of the 11 are filed (manifest linked), which
--     Fred said to leave alone. No pending visit moves (asserted; if one ever does, this file refuses and must be
--     rebuilt with a backfill, as 2026-09-24_1220 did).
--   - The grey water rule: FALSE -> TRUE on 6 filed visits whose own line is free-text grey water (209-TRUE and
--     212-TRUE on 5/8, 084-ULT x4), so the DERM Tracker bulk dialog now warns about their filed paperwork
--     instead of saying it will hide them. All 6 are stored TRUE, so the Field Portal is unchanged (asserted).
--   - derm.v_lwt_grey_water_unlinked is empty before and after (no grey water pickup has completed since 9/24).
--   - Two other readers of the classifier move, both measured before shipping and both correct:
--       client.fn_client_has_derm_activity: 253-CG (client 208) TRUE -> FALSE. Its only DERM-looking work is
--         free-text grey water, so the Client App stops showing the "DERM service report" warning when its
--         contact email is edited. Right: grey water reports no longer go to the city.
--       ops.v_derm_human_override_conflict: 64 -> 63 rows. The view lists completed, locked visits a person
--         set to "not required" while the derive says "required". Visit 5159 (free-text grey water, stored
--         FALSE, locked) now derives FALSE, so the person and the derive agree and it leaves the list. Right.
--   - customer.permits (the Field Portal permit card, whose job fallback reads fn_line_item_requires_derm) is
--     asserted row-identical before and after (V8).
--
-- NOT CHANGED: fn_visit_requires_derm (its any-path fold is a different question), customer.work_orders_all
-- (it has no grey arm), the catalogue, any stored value, any grant on an existing object.
-- 🛑 Do not SET search_path in this file: pg_get_viewdef leaves names unqualified that resolve on the
-- current path, and the EXECUTEs must resolve them the same way.
-- AUDIT-TRAIL STANDING CHECK (rule 8): no table changes; views and functions are not audited.
-- ROLLBACK: run docs/migrations/_baseline/2026-09-24_grey_water_one_rule.before.sql as a whole. It re-creates the
-- three views and the classifier from their pre-change text, restores the 1615 column comment, then drops the
-- shared view and the helper, in that order. Proven before apply: this file then the baseline, in one rolled-back
-- transaction, put all four objects back on their md5 pins with ACLs, comment and counts; the same check without
-- the baseline failed 9 of its 11 assertions (the control).
-- ============================================================================

BEGIN;

-- ---------- pre-flight: the objects are exactly what this file was built against
DO $pre$
BEGIN
  IF md5(pg_get_functiondef('public.fn_line_item_requires_derm(text)'::regprocedure)) <> '8c272167ef33ef1751a237bd71a09341' THEN
    RAISE EXCEPTION 'fn_line_item_requires_derm changed since this migration was built; rebuild it'; END IF;
  IF md5(pg_get_functiondef('public.fn_visit_requires_derm(bigint)'::regprocedure)) <> '0183ea6412123ee4c0fd5c7663142221' THEN
    RAISE EXCEPTION 'fn_visit_requires_derm changed since this migration was built; rebuild it'; END IF;
  IF md5(pg_get_viewdef('customer.work_orders'::regclass)) <> '8691c35a57b742d45deff6d2d50e892a' THEN
    RAISE EXCEPTION 'customer.work_orders changed since this migration was built; rebuild it'; END IF;
  IF md5(pg_get_viewdef('derm.visits'::regclass)) <> '70ff5ed14c907d1f64010d6acfbaaaa0' THEN
    RAISE EXCEPTION 'derm.visits changed since this migration was built; rebuild it'; END IF;
  IF md5(pg_get_viewdef('derm.v_lwt_grey_water_unlinked'::regclass)) <> 'da1355a9d4f764210fa6a812a1f51509' THEN
    RAISE EXCEPTION 'derm.v_lwt_grey_water_unlinked changed since this migration was built; rebuild it'; END IF;
  IF to_regclass('public.v_visit_grey_water_pumping') IS NOT NULL
     OR to_regprocedure('public.fn_line_item_is_free_text_grey_water(text)') IS NOT NULL THEN
    RAISE EXCEPTION 'the new objects already exist'; END IF;
  IF (SELECT array_agg(code::text ORDER BY code) FROM public.service_line_items
       WHERE service_type = 'Pumping' AND location_target = 'Grey Water') IS DISTINCT FROM ARRAY['03','10'] THEN
    RAISE EXCEPTION 'grey water pumping catalogue is no longer exactly {03,10}; re-measure before shipping'; END IF;
END
$pre$;

-- ---------- snapshots (before any change)
CREATE TEMP TABLE _gw_before ON COMMIT DROP AS SELECT id, grey_water_pumping FROM derm.visits;
CREATE TEMP TABLE _wo_before ON COMMIT DROP AS SELECT id FROM customer.work_orders;
CREATE TEMP TABLE _lwt_before ON COMMIT DROP AS SELECT visit_id FROM derm.v_lwt_grey_water_unlinked;
CREATE TEMP TABLE _stored_before ON COMMIT DROP AS SELECT id, derm_required, derm_required_locked FROM public.visits;
CREATE TEMP TABLE _permits_before ON COMMIT DROP AS SELECT to_jsonb(p) AS j FROM customer.permits p;
CREATE TEMP TABLE _acl_before ON COMMIT DROP AS
  SELECT oid AS reloid, relacl::text AS acl, reloptions::text AS opts FROM pg_class
   WHERE oid IN ('customer.work_orders'::regclass, 'derm.visits'::regclass, 'derm.v_lwt_grey_water_unlinked'::regclass);
CREATE TEMP TABLE _cols_before ON COMMIT DROP AS
  SELECT attrelid, attnum, attname, atttypid FROM pg_attribute
   WHERE attrelid IN ('customer.work_orders'::regclass, 'derm.visits'::regclass, 'derm.v_lwt_grey_water_unlinked'::regclass)
     AND attnum > 0 AND NOT attisdropped;

-- ---------- the previous classifiers, kept under temp names for the comparisons below
DO $old$
DECLARE
  dl text := pg_get_functiondef('public.fn_line_item_requires_derm(text)'::regprocedure);
  dv text := pg_get_functiondef('public.fn_visit_requires_derm(bigint)'::regprocedure);
BEGIN
  EXECUTE replace(dl, 'CREATE OR REPLACE FUNCTION public.fn_line_item_requires_derm(', 'CREATE FUNCTION pg_temp.old_line_derm(');
  EXECUTE replace(replace(dv, 'CREATE OR REPLACE FUNCTION public.fn_visit_requires_derm(', 'CREATE FUNCTION pg_temp.old_visit_derm('),
                  'public.fn_line_item_requires_derm(', 'pg_temp.old_line_derm(');
END
$old$;

-- ---------- 1. the free-text grey water test (pure)
CREATE FUNCTION public.fn_line_item_is_free_text_grey_water(p_name text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
  -- 2026-09-24 (Fred, item 10). An UNCODED line whose WHOLE text is "grey water pumping" in one of its
  -- spellings: grey/gray, "grey water"/"greywater"/"grey-water", pump/pumps/pumped/pumping, an optional
  -- "out", or the reverse order ("pump out the grey water"). An ALLOWLIST anchored at both ends, on purpose:
  -- a line naming anything else too ("GT & grey water pumping") may be a grease trap and keeps its old answer.
  -- A code-prefixed line ("03 - ...") never matches (it starts with a digit).
  -- Read by fn_line_item_requires_derm (arm b0: the catalogue's grey water flag) and
  -- public.v_visit_grey_water_pumping (counts as grey water pumping). One definition; change it here only.
  SELECT COALESCE(btrim(p_name) ~* '^(gr[ae]y[-[:space:]]*water[[:space:]]+pump(ing|ed|s)?([[:space:]]*-?[[:space:]]*out)?|pump(ing|ed)?([[:space:]]+out)?[[:space:]]+(the[[:space:]]+)?gr[ae]y[-[:space:]]*water)$', false)
$function$;
COMMENT ON FUNCTION public.fn_line_item_is_free_text_grey_water(text) IS
  'TRUE when an uncoded line''s whole text is grey (or gray) water pumping, exact phrase list anchored at both ends; a line naming anything else too keeps its old answer. Pure. Read by fn_line_item_requires_derm (arm b0: answers the catalogue grey water flag, FALSE since 2026-09-24_1220) and public.v_visit_grey_water_pumping. 2026-09-24.';
GRANT EXECUTE ON FUNCTION public.fn_line_item_is_free_text_grey_water(text) TO PUBLIC;

-- ---------- 2. fn_line_item_requires_derm: free-text grey water answers what the catalogue says for grey water
DO $cls$
DECLARE
  d text := pg_get_functiondef('public.fn_line_item_requires_derm(text)'::regprocedure);
  a text := '    -- (b) free-text PUMPING:';
  b text := '    -- (b0) 2026-09-24: a free-text line that is exactly GREY WATER pumping answers what the catalogue' || chr(10)
         || '    --      says for grey water pumping (codes 03 and 10; FALSE since 2026-09-24_1220), so the policy' || chr(10)
         || '    --      stays in one place. The phrase list is public.fn_line_item_is_free_text_grey_water.' || chr(10)
         || '    WHEN public.fn_line_item_is_free_text_grey_water(p_name) THEN' || chr(10)
         || '      (SELECT bool_and(s.requires_derm) FROM public.service_line_items s' || chr(10)
         || '        WHERE s.service_type = ''Pumping'' AND s.location_target = ''Grey Water'')' || chr(10)
         || '    -- (b) free-text PUMPING:';
BEGIN
  IF length(d) - length(replace(d, a, '')) <> length(a) THEN RAISE EXCEPTION 'classifier anchor is not unique'; END IF;
  EXECUTE replace(d, a, b);
END
$cls$;

-- ---------- 3. the ONE grey water rule
CREATE VIEW public.v_visit_grey_water_pumping AS
SELECT v.id AS visit_id
  FROM public.visits v
 WHERE v.deleted_at IS NULL
   AND EXISTS (
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
   SELECT 1 FROM svc
    WHERE svc.tier = (SELECT min(svc2.tier) FROM svc svc2)
      AND svc.grey);
COMMENT ON VIEW public.v_visit_grey_water_pumping IS
  'THE grey water pumping rule, once (2026-09-24): live (not soft-deleted) visits only; among the service lines a visit reaches, those on the nearest tier (own lines, else job, else invoice) include catalogue Pumping + Grey Water (03, 10) or a free-text grey water line (fn_line_item_is_free_text_grey_water); fee/admin codes abstain. No status filter: consumers add their own. Read by customer.work_orders (Field Portal keeps grey water visible), derm.visits.grey_water_pumping (DERM Tracker bulk dialog) and derm.v_lwt_grey_water_unlinked (LWT tracker). Owner-rights consumers read it; no app role needs a grant.';
-- Supabase default privileges grant BY NAME on every new view (service_role ALL, yannick_readonly SELECT); revoke
-- them by name, then grant back the one read the edge functions may need. V6 asserts the resulting ACL.
REVOKE ALL ON public.v_visit_grey_water_pumping FROM PUBLIC, anon, authenticated, service_role, yannick_readonly;
GRANT SELECT ON public.v_visit_grey_water_pumping TO service_role;

-- ---------- 4. the three copies read it
DO $views$
DECLARE
  d_wo  text := pg_get_viewdef('customer.work_orders'::regclass);
  d_dv  text := pg_get_viewdef('derm.visits'::regclass);
  d_lwt text := pg_get_viewdef('derm.v_lwt_grey_water_unlinked'::regclass);
  a_wo  text := $woarm$(EXISTS ( WITH lc AS (
                 SELECT lpad("substring"(btrim(li.name), '^([0-9]{1,2})[[:space:]]*-[[:space:]]'::text), 2, '0'::text) AS code,
                        CASE
                            WHEN (li.visit_id = v.id) THEN 1
                            WHEN ((v.job_id IS NOT NULL) AND (li.job_id = v.job_id)) THEN 2
                            ELSE 3
                        END AS tier
                   FROM line_items li
                  WHERE ((li.name IS NOT NULL) AND ((li.visit_id = v.id) OR ((v.job_id IS NOT NULL) AND (li.job_id = v.job_id)) OR ((v.invoice_id IS NOT NULL) AND (li.invoice_id = v.invoice_id))))
                ), svc AS (
                 SELECT lc.code,
                    lc.tier
                   FROM (lc
                     JOIN service_line_items s ON ((s.code = lc.code)))
                  WHERE (s.reason <> ALL (ARRAY['fee'::text, 'other'::text]))
                )
         SELECT 1
           FROM svc
          WHERE ((svc.tier = ( SELECT min(svc_1.tier) AS min
                   FROM svc svc_1)) AND (svc.code IN ( SELECT service_line_items.code
                   FROM service_line_items
                  WHERE ((service_line_items.service_type = 'Pumping'::text) AND (service_line_items.location_target = 'Grey Water'::text)))))))$woarm$;
  a_dv  text := $dvarm$
    (EXISTS ( SELECT 1
           FROM visits gv
          WHERE ((gv.id = w3.id) AND (EXISTS ( WITH gw_lc AS (
                         SELECT lpad("substring"(btrim(li.name), '^([0-9]{1,2})[[:space:]]*-[[:space:]]'::text), 2, '0'::text) AS code,
                                CASE
                                    WHEN (li.visit_id = gv.id) THEN 1
                                    WHEN ((gv.job_id IS NOT NULL) AND (li.job_id = gv.job_id)) THEN 2
                                    ELSE 3
                                END AS tier
                           FROM line_items li
                          WHERE ((li.name IS NOT NULL) AND ((li.visit_id = gv.id) OR ((gv.job_id IS NOT NULL) AND (li.job_id = gv.job_id)) OR ((gv.invoice_id IS NOT NULL) AND (li.invoice_id = gv.invoice_id))))
                        ), gw_svc AS (
                         SELECT gw_lc.code,
                            gw_lc.tier
                           FROM (gw_lc
                             JOIN service_line_items s ON ((s.code = gw_lc.code)))
                          WHERE (s.reason <> ALL (ARRAY['fee'::text, 'other'::text]))
                        )
                 SELECT 1
                   FROM gw_svc
                  WHERE ((gw_svc.tier = ( SELECT min(gw_svc_1.tier) AS min
                           FROM gw_svc gw_svc_1)) AND (gw_svc.code IN ( SELECT service_line_items.code
                           FROM service_line_items
                          WHERE ((service_line_items.service_type = 'Pumping'::text) AND (service_line_items.location_target = 'Grey Water'::text))))))))))$dvarm$;
  a_lwt text := $lwtarm$(EXISTS ( SELECT 1
           FROM line_items li
          WHERE ((li.name IS NOT NULL) AND ((li.visit_id = v.id) OR ((v.invoice_id IS NOT NULL) AND (li.invoice_id = v.invoice_id)) OR ((v.job_id IS NOT NULL) AND (li.job_id = v.job_id))) AND (lpad("substring"(btrim(li.name), '^([0-9]{1,2})[[:space:]]*-[[:space:]]'::text), 2, '0'::text) IN ( SELECT service_line_items.code
                   FROM service_line_items
                  WHERE ((service_line_items.service_type = 'Pumping'::text) AND (service_line_items.location_target = 'Grey Water'::text)))))))$lwtarm$;
  n_wo  text := '(EXISTS ( SELECT 1 FROM public.v_visit_grey_water_pumping gwp WHERE (gwp.visit_id = v.id)))';
  n_dv  text := chr(10) || '    (EXISTS ( SELECT 1 FROM public.v_visit_grey_water_pumping gwp WHERE (gwp.visit_id = w3.id)))';
  n_lwt text := '(EXISTS ( SELECT 1 FROM public.v_visit_grey_water_pumping gwp WHERE (gwp.visit_id = v.id)))';
BEGIN
  IF length(d_wo)  - length(replace(d_wo,  a_wo,  '')) <> length(a_wo)  THEN RAISE EXCEPTION 'work_orders: rule text not found exactly once'; END IF;
  IF length(d_dv)  - length(replace(d_dv,  a_dv,  '')) <> length(a_dv)  THEN RAISE EXCEPTION 'derm.visits: rule text not found exactly once'; END IF;
  IF length(d_lwt) - length(replace(d_lwt, a_lwt, '')) <> length(a_lwt) THEN RAISE EXCEPTION 'v_lwt: rule text not found exactly once'; END IF;
  EXECUTE 'CREATE OR REPLACE VIEW customer.work_orders AS '            || rtrim(replace(d_wo,  a_wo,  n_wo),  ';');
  EXECUTE 'CREATE OR REPLACE VIEW derm.visits AS '                     || rtrim(replace(d_dv,  a_dv,  n_dv),  ';');
  EXECUTE 'CREATE OR REPLACE VIEW derm.v_lwt_grey_water_unlinked AS '  || rtrim(replace(d_lwt, a_lwt, n_lwt), ';');
END
$views$;

COMMENT ON COLUMN derm.visits.grey_water_pumping IS
  'TRUE when public.v_visit_grey_water_pumping lists the visit (the one grey water rule, 2026-09-24_1920). Such a visit stays in the client''s Field Portal when DERM not required, so the DERM Tracker bulk dialog does not count it as hidden. Never NULL.';

-- ---------- VERIFY
DO $verify$
DECLARE
  n int; n2 int; n_ctl int; n_cls int; r text; t0 timestamptz; ms_wo int; ms_dv int;
  t6507 text := (SELECT public_id FROM public.visits WHERE id = 6507);
  today date := (now() AT TIME ZONE 'America/New_York')::date;
BEGIN
  -- V1 the classifier moves ONLY on free-text grey water names, and only to FALSE. Over every distinct line name
  -- in the database plus every catalogue title plus the fixtures below.
  WITH names AS (
    SELECT DISTINCT name AS nm FROM public.line_items WHERE name IS NOT NULL
    UNION SELECT title FROM public.service_line_items
    UNION SELECT unnest(ARRAY['Grey Water Pumping','Grey water pumping','Gray water pump out','Greywater pumping',
      'Grey-water pumped','Pump out the grey water','  gray water pumps  ',
      'Grease trap & grey water pumping','Grey water interceptor pump out','Lift station and grey water pumping',
      'GT & grey water pumping','Grease & grey water pumping','Grey water pumping (GT)',
      'Grease Trap pump out','Pump out','Grey water line cleaning','Hydrojet cleaning','Service'])
  ), cmp AS (
    SELECT nm, pg_temp.old_line_derm(nm) o, public.fn_line_item_requires_derm(nm) nw,
           public.fn_line_item_is_free_text_grey_water(nm) ft FROM names
  )
  SELECT count(*) FILTER (WHERE o IS DISTINCT FROM nw AND NOT (ft AND nw IS FALSE)),
         count(*) FILTER (WHERE o IS DISTINCT FROM nw)
    INTO n, n_cls FROM cmp;
  IF n <> 0 THEN RAISE EXCEPTION 'V1: % names changed classification for another reason', n; END IF;
  IF n_cls < 2 THEN RAISE EXCEPTION 'V1 control: only % names changed (the two live free-text names must)', n_cls; END IF;
  -- fixtures, each with its expected answer
  SELECT string_agg(format('%s=%s(want %s)', f.nm, public.fn_line_item_requires_derm(f.nm), f.want), '; ') INTO r
    FROM (VALUES ('Grey Water Pumping', false), ('Grey water pumping', false), ('Gray water pump out', false),
                 ('Greywater pumping', false), ('Grey-water pumped', false), ('Pump out the grey water', false),
                 ('  gray water pumps  ', false), ('Grease trap & grey water pumping', true),
                 ('Grey water interceptor pump out', true), ('Lift station and grey water pumping', true),
                 -- the review's three: a mixed line may be a grease trap too, so it keeps its old TRUE
                 ('GT & grey water pumping', true), ('Grease & grey water pumping', true), ('Grey water pumping (GT)', true),
                 ('Grease Trap pump out', true), ('Pump out', true), ('Grey water line cleaning', false),
                 ('03 - Service Agreement - Pumping - Grey Water', false), ('10 - Service Call - Pumping - Grey Water', false),
                 ('01 - Service Agreement - Pumping - Grease Trap & Tank Cleaning', true)) f(nm, want)
   WHERE public.fn_line_item_requires_derm(f.nm) IS DISTINCT FROM f.want;
  IF r IS NOT NULL THEN RAISE EXCEPTION 'V1 fixtures: %', r; END IF;
  IF pg_temp.old_line_derm('Grey Water Pumping') IS NOT TRUE THEN RAISE EXCEPTION 'V1 control: the old classifier did not say TRUE'; END IF;
  IF public.fn_line_item_is_free_text_grey_water(NULL) IS NOT FALSE THEN RAISE EXCEPTION 'V1: NULL input must answer false'; END IF;
  -- (b0) answers the catalogue's grey water flag, not a literal: equal to what code 03 answers, and to the flag
  IF public.fn_line_item_requires_derm('Grey Water Pumping') IS DISTINCT FROM
       (SELECT bool_and(s.requires_derm) FROM public.service_line_items s WHERE s.service_type = 'Pumping' AND s.location_target = 'Grey Water')
     OR public.fn_line_item_requires_derm('Grey Water Pumping') IS DISTINCT FROM
       public.fn_line_item_requires_derm('03 - Service Agreement - Pumping - Grey Water') THEN
    RAISE EXCEPTION 'V1: arm (b0) does not answer the catalogue grey water flag'; END IF;

  -- V2 visit derive: moves only on visits that reach a free-text grey water line; no PENDING visit would now be
  -- demoted by a backfill-worthy change (scheduled, dated today or later, unlocked, stored TRUE, now FALSE).
  CREATE TEMP TABLE _touched ON COMMIT DROP AS
    SELECT DISTINCT v.id FROM public.visits v JOIN public.line_items li
      ON li.name IS NOT NULL AND public.fn_line_item_is_free_text_grey_water(li.name)
     AND (li.visit_id = v.id OR (v.job_id IS NOT NULL AND li.job_id = v.job_id) OR (v.invoice_id IS NOT NULL AND li.invoice_id = v.invoice_id));
  SELECT count(*) INTO n_ctl FROM _touched;
  IF n_ctl < 1 THEN RAISE EXCEPTION 'V2 control: no visit reaches a free-text grey water line'; END IF;
  SELECT count(*) FILTER (WHERE pg_temp.old_visit_derm(v.id) IS DISTINCT FROM public.fn_visit_requires_derm(v.id)),
         count(*) FILTER (WHERE v.visit_status = 'scheduled' AND v.visit_date >= today AND v.deleted_at IS NULL
                            AND v.derm_required IS TRUE AND v.derm_required_locked IS NOT TRUE
                            AND public.fn_visit_requires_derm(v.id) IS FALSE)
    INTO n, n2 FROM public.visits v JOIN _touched t ON t.id = v.id;
  IF n < 1 THEN RAISE EXCEPTION 'V2 control: no derive moved'; END IF;
  IF n2 <> 0 THEN RAISE EXCEPTION 'V2: % pending visits would now derive FALSE while stored TRUE: rebuild this file with a backfill', n2; END IF;
  -- a visit reaching no free-text grey water line cannot move (proved by V1: only those names changed); spot-check
  -- the controls the earlier migrations used
  IF public.fn_visit_requires_derm(7849) IS NOT TRUE THEN RAISE EXCEPTION 'V2: 7849 (grease trap) no longer derives TRUE'; END IF;
  IF public.fn_visit_requires_derm(5159) IS NOT FALSE THEN RAISE EXCEPTION 'V2: 5159 (free-text grey water) does not derive FALSE'; END IF;
  -- stored values untouched by this file
  IF EXISTS (SELECT 1 FROM _stored_before b JOIN public.visits v ON v.id = b.id
              WHERE v.derm_required IS DISTINCT FROM b.derm_required OR v.derm_required_locked IS DISTINCT FROM b.derm_required_locked) THEN
    RAISE EXCEPTION 'V2: a stored derm_required changed'; END IF;

  -- V3 the rule: never loses a visit; gains only visits that reach a free-text grey water line.
  SELECT count(*) INTO n FROM _gw_before b WHERE b.grey_water_pumping
     AND NOT EXISTS (SELECT 1 FROM public.v_visit_grey_water_pumping g WHERE g.visit_id = b.id);
  IF n <> 0 THEN RAISE EXCEPTION 'V3: % visits stopped being grey water pumping', n; END IF;
  SELECT count(*), count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM _touched t WHERE t.id = b.id)) INTO n2, n
    FROM _gw_before b WHERE NOT b.grey_water_pumping
     AND EXISTS (SELECT 1 FROM public.v_visit_grey_water_pumping g WHERE g.visit_id = b.id);
  IF n <> 0 THEN RAISE EXCEPTION 'V3: % visits became grey water without a free-text grey water line', n; END IF;
  IF n2 < 1 THEN RAISE EXCEPTION 'V3 control: the free-text arm added no visit (expected the 5/8 TRUE visits and 084-ULT)'; END IF;
  -- named controls
  IF (SELECT count(*) FROM derm.visits WHERE id IN (6507, 6508, 7085, 5159, 3931, 3932) AND grey_water_pumping) <> 6 THEN
    RAISE EXCEPTION 'V3: a grey water control (6507, 6508, 7085, 5159, 3931, 3932) is not grey_water_pumping'; END IF;
  IF (SELECT count(*) FROM derm.visits WHERE id IN (7849, 8117, 7323) AND NOT grey_water_pumping) <> 3 THEN
    RAISE EXCEPTION 'V3: control 7849, 8117 or 7323 reads grey_water_pumping'; END IF;

  -- V4 the three consumers agree with the one rule
  SELECT count(*) INTO n FROM derm.visits d
   WHERE d.grey_water_pumping IS DISTINCT FROM EXISTS (SELECT 1 FROM public.v_visit_grey_water_pumping g WHERE g.visit_id = d.id);
  IF n <> 0 THEN RAISE EXCEPTION 'V4: derm.visits disagrees with the rule on % rows', n; END IF;
  SELECT count(*), count(*) FILTER (WHERE (EXISTS (SELECT 1 FROM customer.work_orders wo WHERE wo.id = v.public_id))
                                          IS DISTINCT FROM d.grey_water_pumping)
    INTO n_ctl, n FROM derm.visits d JOIN public.visits v ON v.id = d.id
   WHERE v.derm_required IS FALSE AND v.client_id IS NOT NULL AND v.deleted_at IS NULL;
  IF n_ctl < 100 THEN RAISE EXCEPTION 'V4 control: only % stored-FALSE rows', n_ctl; END IF;
  IF n <> 0 THEN RAISE EXCEPTION 'V4: the Field Portal disagrees with grey_water_pumping on % stored-FALSE rows', n; END IF;
  -- the Field Portal loses nothing; anything it gains is a stored-FALSE visit the rule newly admits
  IF EXISTS (SELECT 1 FROM _wo_before b WHERE NOT EXISTS (SELECT 1 FROM customer.work_orders w WHERE w.id = b.id)) THEN
    RAISE EXCEPTION 'V4: a work order left the Field Portal'; END IF;
  SELECT count(*) INTO n FROM customer.work_orders w JOIN public.visits v ON v.public_id = w.id
   WHERE NOT EXISTS (SELECT 1 FROM _wo_before b WHERE b.id = w.id)
     AND NOT (v.derm_required IS FALSE AND EXISTS (SELECT 1 FROM _touched t WHERE t.id = v.id));
  IF n <> 0 THEN RAISE EXCEPTION 'V4: % work orders appeared that are not stored-FALSE free-text grey water', n; END IF;
  -- LWT: every row still a completed, unlinked, since-9/24 grey water visit by the one rule
  SELECT count(*) INTO n FROM derm.v_lwt_grey_water_unlinked l
   WHERE NOT EXISTS (SELECT 1 FROM public.v_visit_grey_water_pumping g WHERE g.visit_id = l.visit_id);
  IF n <> 0 THEN RAISE EXCEPTION 'V4: % LWT rows are not grey water by the rule', n; END IF;

  -- V5 the rule text lives ONCE: 'Grey Water' appears in the shared view and in none of the three consumers,
  -- and each consumer depends on the shared view.
  IF position('Grey Water' in pg_get_viewdef('public.v_visit_grey_water_pumping'::regclass)) = 0 THEN
    RAISE EXCEPTION 'V5 control: the shared view does not carry the rule'; END IF;
  IF position('Grey Water' in pg_get_viewdef('customer.work_orders'::regclass)) > 0
     OR position('Grey Water' in pg_get_viewdef('derm.visits'::regclass)) > 0
     OR position('Grey Water' in pg_get_viewdef('derm.v_lwt_grey_water_unlinked'::regclass)) > 0 THEN
    RAISE EXCEPTION 'V5: a consumer still carries its own copy of the rule'; END IF;
  SELECT count(DISTINCT r.ev_class) INTO n FROM pg_depend dp JOIN pg_rewrite r ON r.oid = dp.objid
   WHERE dp.refobjid = 'public.v_visit_grey_water_pumping'::regclass
     AND r.ev_class IN ('customer.work_orders'::regclass, 'derm.visits'::regclass, 'derm.v_lwt_grey_water_unlinked'::regclass);
  IF n <> 3 THEN RAISE EXCEPTION 'V5: only % of the 3 consumers depend on the shared view', n; END IF;

  -- V6 grants, columns, ACLs
  IF (SELECT relacl::text FROM pg_class WHERE oid = 'public.v_visit_grey_water_pumping'::regclass)
     IS DISTINCT FROM '{postgres=arwdDxtm/postgres,service_role=r/postgres}' THEN
    RAISE EXCEPTION 'V6: the shared view ACL is %', (SELECT relacl::text FROM pg_class WHERE oid = 'public.v_visit_grey_water_pumping'::regclass); END IF;
  IF EXISTS (SELECT 1 FROM _acl_before a JOIN pg_class c ON c.oid = a.reloid
              WHERE c.relacl::text IS DISTINCT FROM a.acl OR c.reloptions::text IS DISTINCT FROM a.opts) THEN
    RAISE EXCEPTION 'V6: a consumer ACL or reloptions changed'; END IF;
  IF EXISTS (SELECT 1 FROM _cols_before b FULL JOIN (SELECT attrelid, attnum, attname, atttypid FROM pg_attribute
               WHERE attrelid IN ('customer.work_orders'::regclass, 'derm.visits'::regclass, 'derm.v_lwt_grey_water_unlinked'::regclass)
                 AND attnum > 0 AND NOT attisdropped) a USING (attrelid, attnum)
              WHERE a.attname IS DISTINCT FROM b.attname OR a.atttypid IS DISTINCT FROM b.atttypid) THEN
    RAISE EXCEPTION 'V6: a consumer column list changed'; END IF;
  IF NOT has_function_privilege('anon', 'public.fn_line_item_is_free_text_grey_water(text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.fn_line_item_is_free_text_grey_water(text)', 'EXECUTE')
     OR NOT has_function_privilege('pg_read_all_data', 'public.fn_line_item_is_free_text_grey_water(text)', 'EXECUTE')
     OR NOT has_function_privilege('yannick_readonly', 'public.fn_line_item_is_free_text_grey_water(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'V6: a reader of the consumers cannot execute the pure helper'; END IF;
  IF has_table_privilege('anon', 'public.v_visit_grey_water_pumping', 'SELECT')
     OR has_table_privilege('authenticated', 'public.v_visit_grey_water_pumping', 'SELECT') THEN
    RAISE EXCEPTION 'V6: an app role can read the shared view directly'; END IF;
  -- the real paths, as the real roles
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO n  FROM customer.work_orders;
  SELECT count(*) FILTER (WHERE grey_water_pumping) INTO n2 FROM derm.visits;
  SELECT count(*) INTO n_ctl FROM customer.permits;
  EXECUTE 'RESET ROLE';
  IF n < 700 OR n2 < 27 OR n_ctl < 100 THEN RAISE EXCEPTION 'V6: authenticated reads % work orders, % grey visits, % permits', n, n2, n_ctl; END IF;
  EXECUTE 'SET LOCAL ROLE anon';
  IF customer.get_work_order(t6507) IS NULL THEN RAISE EXCEPTION 'V6: anon no longer gets 6507 through get_work_order'; END IF;
  EXECUTE 'RESET ROLE';

  -- V8 the Field Portal permit card (its job fallback reads fn_line_item_requires_derm) is row-identical
  SELECT count(*) INTO n_ctl FROM _permits_before;
  IF n_ctl < 100 THEN RAISE EXCEPTION 'V8 control: only % permit rows snapshotted', n_ctl; END IF;
  SELECT count(*) INTO n FROM (
    (SELECT j FROM _permits_before EXCEPT ALL SELECT to_jsonb(p) FROM customer.permits p)
    UNION ALL
    (SELECT to_jsonb(p) FROM customer.permits p EXCEPT ALL SELECT j FROM _permits_before)) x;
  IF n <> 0 THEN RAISE EXCEPTION 'V8: customer.permits changed on % rows', n; END IF;

  -- V7 cost of the two consumers the apps read in full
  t0 := clock_timestamp(); PERFORM count(*) FROM customer.work_orders; ms_wo := extract(epoch FROM clock_timestamp() - t0) * 1000;
  t0 := clock_timestamp(); PERFORM count(*) FILTER (WHERE grey_water_pumping) + count(*) FILTER (WHERE line_items IS NOT NULL) FROM derm.visits;
  ms_dv := extract(epoch FROM clock_timestamp() - t0) * 1000;
  IF ms_wo > 5000 OR ms_dv > 5000 THEN RAISE EXCEPTION 'V7: work_orders % ms, derm.visits % ms', ms_wo, ms_dv; END IF;

  SELECT count(*) INTO n FROM derm.visits WHERE grey_water_pumping;
  RAISE NOTICE 'OK: classifier moved % names; % visits reach free-text grey water; grey water rule now % visits (was %); work orders % -> %; LWT rows % -> %; work_orders scan % ms, derm.visits scan % ms',
    n_cls, (SELECT count(*) FROM _touched), n, (SELECT count(*) FROM _gw_before WHERE grey_water_pumping),
    (SELECT count(*) FROM _wo_before), (SELECT count(*) FROM customer.work_orders),
    (SELECT count(*) FROM _lwt_before), (SELECT count(*) FROM derm.v_lwt_grey_water_unlinked), ms_wo, ms_dv;
END
$verify$;

NOTIFY pgrst, 'reload schema';

COMMIT;
