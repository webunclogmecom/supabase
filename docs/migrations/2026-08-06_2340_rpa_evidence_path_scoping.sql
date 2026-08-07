-- 2026-08-06_2340_rpa_evidence_path_scoping.sql
--
-- WHAT: path-scope the staff INSERT and UPDATE policies on the private 'rpa-evidence' bucket, so a
--       staff session can only write the evidence object of a REAL, LIVE GDO report.
--
-- WHY: Fred, 2026-08-06: "fix the path scoping on rpa_evidence_staff_insert/update".
--      Both policies checked ONLY `bucket_id = 'rpa-evidence'` for role `authenticated`, with no
--      constraint on `name`. So any of the 6 staff users (or any of the 6 staff apps sharing that
--      JWT) could create or overwrite ANY object anywhere in this bucket. I proved it by accident
--      while testing PNG support: an upload to '_probe/mime.png' succeeded, and I needed
--      service_role to clean it up because there is no DELETE policy.
--      This matters more than a normal bucket because `get-derm-doc` signs objects from here and
--      serves them TO CUSTOMERS (kind='gdo_report'), and the bucket has no versioning, no audit
--      trigger and no delete path, so a bad write is silent and unrecoverable.
--
-- 🛑 THE POLICY CANNOT REFERENCE derm_portal_submissions DIRECTLY. RLS policy expressions execute
--    with the CALLER's privileges, and measured: has_table_privilege('authenticated',
--    'public.derm_portal_submissions','SELECT') = FALSE, with RLS enabled on that table. An inline
--    subquery would therefore fail for exactly the role the policy is written for. Hence the
--    SECURITY DEFINER helper below with a pinned search_path. This is the view/function asymmetry
--    documented in CLAUDE.md, in its policy form.
--
-- ✅ THE BOT IS UNAFFECTED. Measured: service_role has rolbypassrls = true, and `rpa-derm-result`
--    writes with the service key, so it never evaluates these policies. Verified separately that
--    postgres also holds rolbypassrls, which is why the SECDEF helper can read the table at all.
--
-- WHAT THE PREDICATE ALLOWS: exactly '<visit_id>/<run_id>.jpg' and '<visit_id>/<run_id>.png' for a
--    row in public.derm_portal_submissions with dry_run IS NOT TRUE. Two paths per live report,
--    which is precisely what the DERM Tracker needs for the same-format overwrite AND for the
--    jpg->png format change (see 2026-08-06_2210).
--
-- ⚠ WHAT THIS DOES **NOT** FIX, and nobody should read it as fixed:
--    a staff member can still overwrite ANOTHER visit's evidence, because RLS has no way to know
--    which visit the user is currently editing. The honest gain is narrower and still worth having:
--      - arbitrary paths are now impossible (no '_probe/', no 'exports/', no junk prefixes);
--      - objects cannot be created for a visit that has no live report;
--      - the 25 DRY-RUN objects become unwritable by staff (they are QA artefacts, and
--        get-derm-doc's own comment says the dry-run frame is the full preview form that must never
--        reach a customer);
--      - a bug in any OTHER staff app (Calendar, Client App, Stamp Studio, Admin Review) can no
--        longer scribble into this compliance bucket, since none of them can produce a valid path.
--
-- ⚠ THE READ POLICY IS DELIBERATELY LEFT ALONE. Scoping SELECT would make the dry-run objects
--    unreadable by staff for no security gain (they are already staff-only, the bucket is private),
--    and it is the read path the app depends on for signing. Fred asked for insert/update.
--
-- AUDIT (ADR 010): storage.objects carries no audit trigger and cannot get one (Supabase-managed,
--    and it already carries protect_objects_delete + update_objects_updated_at). This file is the
--    record. Noted rather than silently accepted: an evidence overwrite still leaves no audit row.

BEGIN;

-- ---------------------------------------------------------------------------------------------
-- 1. the predicate, as a SECDEF helper (see the 42501 note above)
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_is_gdo_evidence_path(p_name text)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
STABLE
AS $fn$
  SELECT EXISTS (
    SELECT 1
      FROM public.derm_portal_submissions s
     WHERE s.dry_run IS NOT TRUE
       AND p_name IN (s.visit_id::text || '/' || s.run_id || '.jpg',
                      s.visit_id::text || '/' || s.run_id || '.png')
  );
$fn$;

COMMENT ON FUNCTION public.fn_is_gdo_evidence_path(text) IS
  'True when the storage path is the evidence object of a LIVE (non dry-run) GDO report: exactly '
  '<visit_id>/<run_id>.jpg or .png. Used by the rpa-evidence INSERT/UPDATE policies. SECURITY '
  'DEFINER because an RLS policy runs as the caller and `authenticated` holds no SELECT on '
  'derm_portal_submissions, so an inline subquery would 42501 for the very role it guards.';

REVOKE ALL ON FUNCTION public.fn_is_gdo_evidence_path(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_is_gdo_evidence_path(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.fn_is_gdo_evidence_path(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_is_gdo_evidence_path(text) TO service_role;

-- ---------------------------------------------------------------------------------------------
-- 2. the two write policies
-- ---------------------------------------------------------------------------------------------
DROP POLICY IF EXISTS rpa_evidence_staff_insert ON storage.objects;
CREATE POLICY rpa_evidence_staff_insert ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'rpa-evidence' AND public.fn_is_gdo_evidence_path(name));

DROP POLICY IF EXISTS rpa_evidence_staff_update ON storage.objects;
CREATE POLICY rpa_evidence_staff_update ON storage.objects
  FOR UPDATE TO authenticated
  USING      (bucket_id = 'rpa-evidence' AND public.fn_is_gdo_evidence_path(name))
  WITH CHECK (bucket_id = 'rpa-evidence' AND public.fn_is_gdo_evidence_path(name));

-- ---------------------------------------------------------------------------------------------
-- 3. assertions
-- ---------------------------------------------------------------------------------------------
DO $$
DECLARE
  r record; n int;
  v_live text; v_png text; v_dry text;
  ok_live boolean; ok_png boolean; ok_dry boolean;
  ok_probe boolean; ok_traverse boolean; ok_other boolean;
BEGIN
  -- (a) the helper is shaped the way a policy helper must be
  SELECT p.prosecdef, p.proconfig::text AS cfg, p.provolatile
    INTO r
    FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
   WHERE ns.nspname='public' AND p.proname='fn_is_gdo_evidence_path';
  IF NOT FOUND THEN RAISE EXCEPTION 'fn_is_gdo_evidence_path was not created'; END IF;
  IF NOT r.prosecdef THEN RAISE EXCEPTION 'helper is not SECURITY DEFINER - it would 42501 for authenticated'; END IF;
  IF r.cfg NOT LIKE '%search_path%' THEN
    RAISE EXCEPTION 'helper has no pinned search_path - SECDEF without it is the footgun'; END IF;
  IF has_function_privilege('anon','public.fn_is_gdo_evidence_path(text)','EXECUTE') THEN
    RAISE EXCEPTION 'anon can EXECUTE the helper'; END IF;

  -- pick real paths out of the live data rather than hardcoding them
  SELECT s.visit_id::text||'/'||s.run_id||'.jpg', s.visit_id::text||'/'||s.run_id||'.png'
    INTO v_live, v_png
    FROM public.derm_portal_submissions s WHERE s.dry_run IS NOT TRUE ORDER BY s.visit_id LIMIT 1;
  SELECT o.name INTO v_dry FROM storage.objects o
   WHERE o.bucket_id='rpa-evidence' AND o.name LIKE '%dryrun%' LIMIT 1;
  IF v_live IS NULL OR v_dry IS NULL THEN
    RAISE EXCEPTION 'CONTROL FAILED: could not find a live path (%) or a dry-run path (%)', v_live, v_dry;
  END IF;

  -- (b) evaluate the predicate AS THE ROLE THE POLICY IS FOR. If the helper were not SECDEF this
  --     is the step that would raise 42501, which is the whole reason it exists.
  EXECUTE 'SET LOCAL ROLE authenticated';
  ok_live      := public.fn_is_gdo_evidence_path(v_live);
  ok_png       := public.fn_is_gdo_evidence_path(v_png);
  ok_dry       := public.fn_is_gdo_evidence_path(v_dry);
  ok_probe     := public.fn_is_gdo_evidence_path('_probe/mime.png');
  ok_traverse  := public.fn_is_gdo_evidence_path('6719/../secrets.jpg');
  ok_other     := public.fn_is_gdo_evidence_path('9999999/not-a-run.jpg');
  EXECUTE 'RESET ROLE';

  IF NOT ok_live THEN RAISE EXCEPTION 'MUST ALLOW the live jpg path % but predicate said false', v_live; END IF;
  IF NOT ok_png  THEN RAISE EXCEPTION 'MUST ALLOW the png sibling % (the format-change flow) but said false', v_png; END IF;
  IF ok_dry      THEN RAISE EXCEPTION 'MUST REJECT the dry-run path %', v_dry; END IF;
  IF ok_probe    THEN RAISE EXCEPTION 'MUST REJECT an arbitrary prefix (_probe/mime.png)'; END IF;
  IF ok_traverse THEN RAISE EXCEPTION 'MUST REJECT a traversal-shaped path'; END IF;
  IF ok_other    THEN RAISE EXCEPTION 'MUST REJECT a path for a visit with no live report'; END IF;

  -- (c) EVERY existing live object must still be writable, or a replace would start 403-ing
  SELECT count(*) INTO n
    FROM storage.objects o
   WHERE o.bucket_id='rpa-evidence' AND o.name NOT LIKE '%dryrun%'
     AND NOT public.fn_is_gdo_evidence_path(o.name);
  IF n <> 0 THEN RAISE EXCEPTION '% existing live evidence object(s) would become unwritable', n; END IF;

  -- (d) the policies carry the new predicate, and the OLD unscoped form is gone
  SELECT count(*) INTO n FROM pg_policy pol
   WHERE pol.polrelid='storage.objects'::regclass
     AND pol.polname IN ('rpa_evidence_staff_insert','rpa_evidence_staff_update')
     AND coalesce(pg_get_expr(pol.polqual,pol.polrelid),'')||coalesce(pg_get_expr(pol.polwithcheck,pol.polrelid),'')
         LIKE '%fn_is_gdo_evidence_path%';
  IF n <> 2 THEN RAISE EXCEPTION 'expected 2 scoped policies, found %', n; END IF;

  -- CONTROL: prove (d) can fail. The READ policy is intentionally NOT scoped, so it must NOT match.
  SELECT count(*) INTO n FROM pg_policy pol
   WHERE pol.polrelid='storage.objects'::regclass AND pol.polname='rpa_evidence_staff_read'
     AND coalesce(pg_get_expr(pol.polqual,pol.polrelid),'') LIKE '%fn_is_gdo_evidence_path%';
  IF n <> 0 THEN RAISE EXCEPTION 'CONTROL FAILED: the read policy was scoped too - not intended'; END IF;

  -- (e) roles unchanged: still authenticated only, and anon gained nothing
  SELECT count(*) INTO n FROM pg_policy pol
   WHERE pol.polrelid='storage.objects'::regclass
     AND pol.polname LIKE 'rpa_evidence%'
     AND EXISTS (SELECT 1 FROM pg_roles ro WHERE ro.oid = ANY(pol.polroles) AND ro.rolname='anon');
  IF n <> 0 THEN RAISE EXCEPTION 'an rpa_evidence policy now names anon'; END IF;

  RAISE NOTICE 'OK: insert+update scoped to <visit_id>/<run_id>.(jpg|png) of live reports; % live objects still writable',
    (SELECT count(*) FROM storage.objects WHERE bucket_id='rpa-evidence' AND name NOT LIKE '%dryrun%');
END $$;

COMMIT;
