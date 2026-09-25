-- ============================================================================
-- 2026-09-25 · public.v_visit_city_email gains `not_for_city`, so Admin Review can say "grey water" first
-- ============================================================================
-- APPLIED 2026-09-25 ~00:50 ET (dry run first: 65 flagged = the list, rows unchanged, authenticated reads it in
-- 4 ms). Then Admin Review 8eec2ff9 published (SendCityEmailButton.tsx, live chunk App-CDAKbMfY.js). Verified
-- live in the app: 6710 (grey water) shows the grey water sentence, no dialog, no server call; controls 7849
-- (grease trap, no inbox) still shows "no City email on file" and 8133 (grease trap with an inbox) still opens
-- the dialog (Cancelled; 0 send calls in all three).
-- THE ASK
--   Fred, 2026-09-24, after "No, grey water reports don't go to the city" shipped server-side
--   (2026-09-24_2110): "yes, fix the Admin Review message too."
--   Admin Review's "Send email to City" button checks two things BEFORE it calls the server: stored
--   derm_required = false ("doesn't need a City report") and v_visit_city_email.city_email_on_file = false
--   ("This property has no City email on file ... Add the email on the property first."). Every grey water
--   visit has no city inbox today, so the button told the operator to add one: the one action that points the
--   wrong way. The server refuses grey water anyway (409 grey_water); the app never got that far.
--
-- WHAT CHANGES
--   public.v_visit_city_email gets one LAST column: not_for_city boolean, never NULL =
--   EXISTS (public.v_visit_not_for_city for this visit). The app reads it with the three columns it already
--   selects and checks it first. The first five columns and the rows are unchanged (asserted). Spliced from the
--   live text, md5 pinned.
--   Privilege path: the view is owner-rights, so authenticated reads public.v_visit_not_for_city with the
--   owner's rights (it holds no grant on it); the SECURITY INVOKER functions inside that list
--   (fn_line_item_requires_derm, fn_line_item_is_free_text_grey_water, both EXECUTE to PUBLIC) run as the
--   caller and read public.service_line_items, which authenticated can read. VERIFY reads the column
--   SET LOCAL ROLE authenticated, because an invoker function inside a view is the trap Supabase/CLAUDE.md
--   records five times.
-- ORDER: apply this BEFORE the Admin Review build that selects not_for_city (a select of a missing column
-- fails the whole query, and the dialog's To line would go blank).
-- NOT CHANGED: any grant, any other view, the edge functions.
-- AUDIT-TRAIL STANDING CHECK (rule 8): no table changes.
-- ROLLBACK: the app must stop selecting not_for_city first. Then the column cannot be dropped by CREATE OR
-- REPLACE; leave it (it changes no row), or DROP and re-CREATE the view from
-- docs/migrations/_baseline/2026-09-25_v_visit_city_email.before.sql and re-apply its grants.
-- ============================================================================

BEGIN;

DO $pre$
BEGIN
  IF md5(pg_get_viewdef('public.v_visit_city_email'::regclass)) <> 'f2c63cd8df1e4cd70ce73e4ea7f03d8a' THEN
    RAISE EXCEPTION 'public.v_visit_city_email changed since this migration was built; rebuild it'; END IF;
  IF to_regclass('public.v_visit_not_for_city') IS NULL THEN
    RAISE EXCEPTION 'public.v_visit_not_for_city is missing (2026-09-24_2110 must be applied first)'; END IF;
END
$pre$;

CREATE TEMP TABLE _vce_before ON COMMIT DROP AS SELECT visit_id, to_jsonb(c) AS j FROM public.v_visit_city_email c;
CREATE TEMP TABLE _vce_rel ON COMMIT DROP AS
  SELECT relacl::text AS acl, reloptions::text AS opts FROM pg_class WHERE oid = 'public.v_visit_city_email'::regclass;
CREATE TEMP TABLE _vce_cols ON COMMIT DROP AS
  SELECT attnum, attname, atttypid FROM pg_attribute
   WHERE attrelid = 'public.v_visit_city_email'::regclass AND attnum > 0 AND NOT attisdropped;

DO $vce$
DECLARE
  d text := pg_get_viewdef('public.v_visit_city_email'::regclass);
  a text := $a$) AS city_emails
   FROM (v_visits_live v
$a$;
  b text := $b$) AS city_emails,
    (EXISTS ( SELECT 1
           FROM public.v_visit_not_for_city n
          WHERE (n.visit_id = v.id))) AS not_for_city
   FROM (v_visits_live v
$b$;
BEGIN
  IF length(d) - length(replace(d, a, '')) <> length(a) THEN RAISE EXCEPTION 'v_visit_city_email: anchor not found exactly once'; END IF;
  EXECUTE 'CREATE OR REPLACE VIEW public.v_visit_city_email AS ' || rtrim(replace(d, a, b), ';');
END
$vce$;

DO $verify$
DECLARE n int; n2 int; t0 timestamptz; ms int; f6710 boolean; f7849 boolean; f7085 boolean;
BEGIN
  -- the first five columns and every row are unchanged; one boolean column appended
  IF EXISTS (SELECT 1 FROM _vce_cols b LEFT JOIN pg_attribute a
               ON a.attrelid = 'public.v_visit_city_email'::regclass AND a.attnum = b.attnum AND NOT a.attisdropped
              WHERE a.attname IS DISTINCT FROM b.attname OR a.atttypid IS DISTINCT FROM b.atttypid) THEN
    RAISE EXCEPTION 'V1: an existing column moved or changed'; END IF;
  IF (SELECT format('%s:%s', attname, atttypid::regtype) FROM pg_attribute
       WHERE attrelid = 'public.v_visit_city_email'::regclass AND attnum = (SELECT max(attnum) + 1 FROM _vce_cols))
     IS DISTINCT FROM 'not_for_city:boolean' THEN
    RAISE EXCEPTION 'V1: the appended column is not not_for_city boolean'; END IF;
  IF EXISTS ((SELECT visit_id, j FROM _vce_before
              EXCEPT SELECT visit_id, to_jsonb(c) - 'not_for_city' FROM public.v_visit_city_email c)
             UNION ALL (SELECT visit_id, to_jsonb(c) - 'not_for_city' FROM public.v_visit_city_email c
              EXCEPT SELECT visit_id, j FROM _vce_before)) THEN
    RAISE EXCEPTION 'V1: a row changed'; END IF;
  -- the flag is exactly the list, never NULL
  SELECT count(*) FILTER (WHERE not_for_city), count(*) FILTER (WHERE not_for_city IS NULL) INTO n, n2 FROM public.v_visit_city_email;
  IF n2 <> 0 THEN RAISE EXCEPTION 'V2: % rows have a NULL not_for_city', n2; END IF;
  IF n <> (SELECT count(*) FROM public.v_visit_not_for_city) THEN
    RAISE EXCEPTION 'V2: % flagged rows against % listed visits', n, (SELECT count(*) FROM public.v_visit_not_for_city); END IF;
  IF n < 60 THEN RAISE EXCEPTION 'V2 control: only % flagged', n; END IF;
  -- ACL and reloptions kept
  IF EXISTS (SELECT 1 FROM _vce_rel b JOIN pg_class c ON c.oid = 'public.v_visit_city_email'::regclass
              WHERE c.relacl::text IS DISTINCT FROM b.acl OR c.reloptions::text IS DISTINCT FROM b.opts) THEN
    RAISE EXCEPTION 'V3: the ACL or reloptions changed'; END IF;
  -- the app's real path: authenticated, one visit, the four columns it will select
  EXECUTE 'SET LOCAL ROLE authenticated';
  t0 := clock_timestamp();
  SELECT not_for_city INTO f6710 FROM public.v_visit_city_email WHERE visit_id = 6710;
  ms := extract(epoch FROM clock_timestamp() - t0) * 1000;
  SELECT not_for_city INTO f7849 FROM public.v_visit_city_email WHERE visit_id = 7849;
  SELECT not_for_city INTO f7085 FROM public.v_visit_city_email WHERE visit_id = 7085;
  EXECUTE 'RESET ROLE';
  IF f6710 IS NOT TRUE OR f7085 IS NOT TRUE THEN RAISE EXCEPTION 'V4: grey water visits 6710 / 7085 read % / %', f6710, f7085; END IF;
  IF f7849 IS NOT FALSE THEN RAISE EXCEPTION 'V4: grease trap visit 7849 reads %', f7849; END IF;
  IF ms > 1000 THEN RAISE EXCEPTION 'V4: one-visit read took % ms', ms; END IF;
  RAISE NOTICE 'OK: % visits flagged not_for_city (= the list), rows and first five columns unchanged, authenticated reads it (6710 %, 7085 %, 7849 %), one-visit read % ms',
    n, f6710, f7085, f7849, ms;
END
$verify$;

NOTIFY pgrst, 'reload schema';

COMMIT;
