-- 2026-08-06_2210_rpa_evidence_accept_png.sql
--
-- WHAT: (1) let the private 'rpa-evidence' bucket accept PNG as well as JPEG, and
--       (2) add public.fn_set_gdo_evidence_ext so the DERM Tracker can keep screenshot_path's
--           EXTENSION honest when a staff member replaces a JPEG evidence photo with a PNG.
--
-- WHY: Fred, 2026-08-06, on the DERM Tracker visit page's evidence photo:
--      "first to be able to put png image too, not only jpg, that means we might need to change
--       the type of saved photos in the DB".
--      He is right on both halves. The blocker is the bucket, and the DB does need to change.
--
-- ⚠ MEASURED, NOT ASSUMED. Every link was probed live before this was written:
--   1. A browser upload declares the File's REAL mime type. Proof: object
--      '6719/aa69c87c-....jpg' has updated_at > created_at with owner = a real signed-in user
--      (the two bot objects have owner IS NULL), so a JPEG replace already succeeded through the
--      app against a jpeg-only bucket. It could only pass by declaring image/jpeg.
--   2. A PNG was therefore rejected. Proof: POST of PNG bytes as the signed-in staff user returned
--      400 {"statusCode":"415","error":"invalid_mime_type","code":"InvalidMimeType"}. The rejected
--      request created NOTHING.
--   3. The mime check runs on the DECLARED Content-Type, not the extension. Proof (this was the
--      control for #2): the SAME bytes declared image/jpeg at a path ending '.png' returned 200.
--      ⇒ widening this list is sufficient; no app-side contentType change is needed.
--   4. After widening: PNG -> 200; PNG at a '.jpg' path -> 200, stored as mimetype 'image/png',
--      and a signed URL serves it with 'Content-Type: image/png'. Negative control: image/gif
--      still 415, so the list is still enforced.
--
-- ============================================================================================
-- 🛑 WHY THE EXTENSION MUST STILL MATCH THE BYTES. I FIRST PLANNED THE OPPOSITE AND WAS WRONG.
-- ============================================================================================
-- Probe #4 above says PNG bytes render fine at a '.jpg' path, and I reasoned from it that
-- screenshot_path is "a LOCATOR, not a type declaration" and could keep its .jpg suffix forever.
-- The measurement was right. The sentence built on it was false, and an adversarial review found
-- the counter-example in a LIVE, CUSTOMER-FACING path:
--
--   Field Portal -> "Online Report" -> preview dialog -> **Download**. Its filename builder reads
--   the extension straight off the storage path:
--       new URL(s,'http://x').pathname.match(/\.([A-Za-z0-9]{1,5})$/)  -> appended to the name,
--   then passed as ?download=<name>. Supabase answers with
--       content-disposition: attachment; filename=110-CLA-...-Aug-6-2026.jpg
--   Content-Disposition wins over Content-Type for naming, so a customer would receive PNG bytes
--   in a file named .jpg. That is exactly the precedent failure this codebase already paid for
--   once (the DERM email that attached a JPEG named .pdf and opened broken).
--   Reachable TODAY for the 3 visits where customer.gdo_reports.has_report_image is true.
--
--   Two more consumers read the path as a type declaration: send-derm-email's fetchAttachment
--   (extension FIRST, Content-Type only as fallback) and the FP previewer's /\.pdf($|\?)/i branch.
--
-- ⇒ "the extension is inert" is empirically FALSE in this codebase. Keep the path honest.
--
-- HOW THE APP USES THIS (and why there is still no DELETE policy and no orphan sweep):
--   same format  (jpg->jpg, png->png)  = true overwrite in place. No DB write, nothing orphaned.
--                                        This is the common case and the behaviour Fred chose.
--   format changes (jpg->png, png->jpg) = upload the new path, then call this function.
--                                        The superseded object is LEFT IN STORAGE, unreferenced.
--   Leaving it is deliberate, not an oversight:
--     - `authenticated` has NO DELETE policy on this bucket. Probed: DELETE returns
--       403 {"error":"Unauthorized"}. Granting one would hand every staff user the power to
--       ERASE any evidence object (INSERT/UPDATE checks are only `bucket_id=...`, no path scope),
--       which is strictly more destructive than what they can do today.
--     - Storage has no versioning and nothing backs this bucket up, so the stranded original is
--       the only recovery path that exists for a mistaken replace.
--     - Cost is ~60 KB per format-changing replace, by two people, a few times a year.
--
-- ⚠ THE JUSTIFICATION I ALMOST BORROWED AND MUST NOT. fn_correct_gdo_report deliberately cannot
--   write status/dry_run/portal_confirmation because those re-open public.v_derm_portal_queue and
--   cause a DUPLICATE Miami-Dade filing. That reasoning does NOT extend to screenshot_path:
--     pg_get_viewdef('public.v_derm_portal_queue') ~ 'screenshot_path'      -> FALSE
--     pg_get_viewdef('public.v_derm_portal_queue') ~ 'portal_confirmation'  -> TRUE  (control)
--   The queue cannot see this column, so writing it carries none of that risk. Two different
--   restrictions; do not collapse them into one rule.
--
-- SIZE LIMIT: DELIBERATELY LEFT AT 5 MB. An earlier draft of this file raised it to 10 MB
--   "because a high-DPI PNG screenshot is commonly 2-6 MB". That was wrong for THIS artifact and
--   is reverted here. The artifact is a screenshot of the county portal's flat, text-heavy
--   "Report Submitted" page; PNG filters plus DEFLATE handle that near-optimally (the 3 live
--   JPEGs are 59-69 KB, the 25 dry-run frames 81-82 KB), so even a 4K capture stays well under
--   3 MB. The only input that exceeds 5 MB is a phone photo of paper, which is the wrong artifact
--   for this field and carries EXIF into a bucket with no redaction pass and no delete path.
--   🛑 AND 5 MB IS LOAD-BEARING: it currently EQUALS MAX_SCREENSHOT_BYTES in
--   supabase/functions/rpa-derm-result/index.ts (line 30). Desyncing them would leave the bucket
--   advertising 10 MB while the bot still hard-caps at 5 MB, and an oversize bot capture is
--   accept-and-flagged as screenshot_missing_reason='SCREENSHOT_TOO_LARGE' -- i.e. it records
--   "evidence missing" on a county filing that actually succeeded. Keep these two numbers equal.
--   The app validates type and size client-side so the user gets a specific message, not a 415.
--
-- AUDIT (ADR 010): storage.buckets is Supabase-managed infrastructure config, carries no audit
--   trigger, and cannot get one; this file is the only record the change happened.
--
-- 🛑 CORRECTION, 2026-08-07. THE SENTENCE THAT USED TO FOLLOW HERE WAS FACTUALLY WRONG.
--   It read: "public.derm_portal_submissions is likewise unaudited (verified: no audit_* trigger),
--   so a screenshot_path change leaves no audit row." That is FALSE. Only the storage.buckets half
--   of this paragraph was ever correct.
--
--   MEASURED LIVE against Prod:
--     trigger audit_derm_portal_submissions -> audit.log_change ....... PRESENT, tgenabled='O'
--     created in .................................................. 2026-07-21e, lines 210-213
--       (opted IN under CLAUDE.md Rule 8: "no table that touches DERM compliance skips audit")
--     dropped since ................................................ never, in any migration
--     audit.logs rows for the table ................................ 657
--     of which, written by assertion block (g) IN THIS FILE ........... 2
--       at 2026-08-06 21:06:37.752074+00, app_source='sql', the .jpg -> .png -> .jpg round trip
--     real app writes, app_source='derm-tracker' ...................... 3 (one at 21:31 that evening)
--
--   So the probe further down this same file generated the very audit rows the header claimed
--   could not exist. The claim was restated from memory and never checked.
--
--   🛑 THE RULE: NEVER RESTATE ANOTHER TABLE'S AUDIT STATUS FROM MEMORY IN A MIGRATION HEADER.
--   Grep the migrations for the trigger name first (`audit_<table>`), or run the generator query in
--   CLAUDE.md rule 8. A wrong "unaudited" claim is not cosmetic: it converts a later audit.logs
--   SILENCE from evidence into a FALSE ALL-CLEAR, which is exactly the detector failure that root
--   CLAUDE.md 5.5(b) exists to prevent, produced by the rule's own paperwork.
--
--   ⚠ AND IT CUTS THE OTHER WAY TOO. Because the table IS audited, "zero audit rows were written,
--   therefore the write never happened" is a VALID instrument here: it could have fired and did
--   not. Do not revise the DERM Tracker changelog entry that rests on it
--   (Building Apps/DERM Tracker/docs/08-changelog.md line 174). That evidence stands, and it
--   stands precisely BECAUSE the trigger is present.

BEGIN;

-- ---------------------------------------------------------------------------------------------
-- 1. the bucket
-- ---------------------------------------------------------------------------------------------
UPDATE storage.buckets
   SET allowed_mime_types = ARRAY['image/jpeg', 'image/png'],
       file_size_limit    = 5242880          -- unchanged on purpose; see SIZE LIMIT above
 WHERE id = 'rpa-evidence';

-- ---------------------------------------------------------------------------------------------
-- 2. the narrow path writer
-- ---------------------------------------------------------------------------------------------
-- Takes an EXTENSION, never a path. The caller cannot express an arbitrary location: the function
-- rebuilds '<visit_id>/<run_id>.<ext>' itself from the row it just verified. That is the whole
-- point of the signature -- a p_path parameter would let any staff user re-point a report at any
-- object in the bucket.
CREATE OR REPLACE FUNCTION public.fn_set_gdo_evidence_ext(
  p_visit_id bigint,
  p_run_id   text,
  p_ext      text
)
RETURNS TABLE (visit_id bigint, run_id text, screenshot_path text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_old text;
  v_new text;
BEGIN
  IF p_ext NOT IN ('jpg', 'png') THEN
    RAISE EXCEPTION 'extension must be jpg or png, got %', p_ext USING ERRCODE = '22023';
  END IF;

  -- Must be a LIVE row. Dry-run rows are test artefacts against a separate QA queue and the app
  -- never renders them (derm.visit_gdo_report filters them out).
  SELECT s.screenshot_path INTO v_old
    FROM public.derm_portal_submissions s
   WHERE s.visit_id = p_visit_id
     AND s.run_id   = p_run_id
     AND s.dry_run IS NOT TRUE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no live GDO report for visit % run %', p_visit_id, p_run_id
      USING ERRCODE = '22023';
  END IF;

  v_new := format('%s/%s.%s', p_visit_id, p_run_id, p_ext);

  UPDATE public.derm_portal_submissions s
     SET screenshot_path = v_new
   WHERE s.visit_id = p_visit_id
     AND s.run_id   = p_run_id
     AND s.dry_run IS NOT TRUE;

  RETURN QUERY SELECT p_visit_id, p_run_id, v_new;
END
$fn$;

COMMENT ON FUNCTION public.fn_set_gdo_evidence_ext(bigint, text, text) IS
  'Repoint a live GDO report''s evidence object at the same run_id under a different image '
  'extension, after the DERM Tracker has uploaded the new bytes there. Takes an EXTENSION, not a '
  'path, so a caller cannot re-point a report at an arbitrary object. Writes screenshot_path and '
  'nothing else -- notably NOT status, dry_run or portal_confirmation, which drive '
  'v_derm_portal_queue and would cause a duplicate county filing. The extension must match the '
  'stored bytes because Field Portal derives the customer download filename from it.';

-- Supabase hands new public functions an EXECUTE grant nobody wrote. Be explicit.
REVOKE ALL ON FUNCTION public.fn_set_gdo_evidence_ext(bigint, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_set_gdo_evidence_ext(bigint, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.fn_set_gdo_evidence_ext(bigint, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_set_gdo_evidence_ext(bigint, text, text) TO service_role;

-- ---------------------------------------------------------------------------------------------
-- 3. assertions
-- ---------------------------------------------------------------------------------------------
DO $$
DECLARE b record; n int; r record; v_before text;
BEGIN
  SELECT * INTO b FROM storage.buckets WHERE id = 'rpa-evidence';
  IF b.id IS NULL THEN RAISE EXCEPTION 'bucket rpa-evidence does not exist - wrong project?'; END IF;

  -- (a) the widening landed, and jpeg was NOT dropped (every existing object and every bot write
  --     is jpeg, so losing it would break the bot mid-flight)
  IF NOT ('image/png'  = ANY(b.allowed_mime_types)) THEN
    RAISE EXCEPTION 'image/png missing from allowed_mime_types (got %)', b.allowed_mime_types; END IF;
  IF NOT ('image/jpeg' = ANY(b.allowed_mime_types)) THEN
    RAISE EXCEPTION 'image/jpeg was DROPPED (got %)', b.allowed_mime_types; END IF;
  IF array_length(b.allowed_mime_types, 1) <> 2 THEN
    RAISE EXCEPTION 'expected exactly 2 allowed types, got %', b.allowed_mime_types; END IF;

  -- (b) size stayed equal to MAX_SCREENSHOT_BYTES in rpa-derm-result. If you change one, change both.
  IF b.file_size_limit <> 5242880 THEN
    RAISE EXCEPTION 'file_size_limit is %, expected 5242880 to stay equal to MAX_SCREENSHOT_BYTES',
      b.file_size_limit; END IF;

  -- (c) the actual security property. The mime list is a convenience filter; THIS is the control.
  IF b.public IS TRUE THEN
    RAISE EXCEPTION 'rpa-evidence went PUBLIC - evidence screenshots would be world-readable'; END IF;

  -- (d) CONTROL: prove the UPDATE was scoped. Without this, an unscoped UPDATE would satisfy
  --     every assertion above while silently rewriting every other bucket.
  SELECT count(*) INTO n FROM storage.buckets
   WHERE id <> 'rpa-evidence'
     AND allowed_mime_types @> ARRAY['image/jpeg','image/png']
     AND array_length(allowed_mime_types, 1) = 2;
  IF n <> 0 THEN
    RAISE EXCEPTION 'CONTROL FAILED: % other bucket(s) match the new list - UPDATE was not scoped', n;
  END IF;

  -- (e) the live evidence is intact. >= not =, because the bot appends a live object on every real
  --     filing and an earlier draft of this file hardcoded 3, which would abort on the 4th.
  SELECT count(*) INTO n FROM storage.objects
   WHERE bucket_id = 'rpa-evidence' AND name NOT LIKE '%dryrun%' AND name NOT LIKE '\_%';
  IF n < 3 THEN RAISE EXCEPTION 'expected at least 3 live evidence objects, found %', n; END IF;

  -- (f) the function exists, is SECDEF, has a pinned search_path, and anon cannot call it
  SELECT p.prosecdef, p.proconfig INTO r
    FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
   WHERE ns.nspname = 'public' AND p.proname = 'fn_set_gdo_evidence_ext';
  IF NOT FOUND THEN RAISE EXCEPTION 'fn_set_gdo_evidence_ext was not created'; END IF;
  IF NOT r.prosecdef THEN RAISE EXCEPTION 'fn_set_gdo_evidence_ext is not SECURITY DEFINER'; END IF;
  IF NOT (r.proconfig::text LIKE '%search_path%') THEN
    RAISE EXCEPTION 'fn_set_gdo_evidence_ext has no pinned search_path - SECDEF without it is the footgun';
  END IF;
  IF has_function_privilege('anon', 'public.fn_set_gdo_evidence_ext(bigint,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon can EXECUTE fn_set_gdo_evidence_ext'; END IF;
  IF NOT has_function_privilege('authenticated', 'public.fn_set_gdo_evidence_ext(bigint,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated cannot EXECUTE fn_set_gdo_evidence_ext - the app could not use it'; END IF;

  -- (g) EXERCISE IT, then put it back. A function that has never run is an untested instrument.
  SELECT screenshot_path INTO v_before
    FROM public.derm_portal_submissions WHERE visit_id = 6719 AND dry_run IS NOT TRUE;

  PERFORM public.fn_set_gdo_evidence_ext(6719, 'aa69c87c-42db-417a-8d5c-3ca9dea83661', 'png');
  IF (SELECT screenshot_path FROM public.derm_portal_submissions
       WHERE visit_id = 6719 AND dry_run IS NOT TRUE)
     <> '6719/aa69c87c-42db-417a-8d5c-3ca9dea83661.png' THEN
    RAISE EXCEPTION 'fn_set_gdo_evidence_ext did not write the png path';
  END IF;

  PERFORM public.fn_set_gdo_evidence_ext(6719, 'aa69c87c-42db-417a-8d5c-3ca9dea83661', 'jpg');
  IF (SELECT screenshot_path FROM public.derm_portal_submissions
       WHERE visit_id = 6719 AND dry_run IS NOT TRUE) <> v_before THEN
    RAISE EXCEPTION 'failed to restore screenshot_path to % (the bytes on disk are still .jpg)', v_before;
  END IF;

  -- (h) it must REFUSE a bad extension and an unknown row.
  --     ⚠ Catch OTHERS, not raise_exception: the guards use `USING ERRCODE='22023'`, which raises
  --     invalid_text_representation. A handler naming raise_exception does NOT catch them, and the
  --     block then fails on the guard WORKING. (That is what happened on the first apply of this
  --     file - the guard was right and the test was wrong.)
  BEGIN
    PERFORM public.fn_set_gdo_evidence_ext(6719, 'aa69c87c-42db-417a-8d5c-3ca9dea83661', 'svg');
    RAISE EXCEPTION 'GUARD FAILED: accepted extension svg';
  EXCEPTION WHEN OTHERS THEN
    IF sqlerrm LIKE 'GUARD FAILED%' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.fn_set_gdo_evidence_ext(6719, 'not-a-real-run-id', 'png');
    RAISE EXCEPTION 'GUARD FAILED: accepted a run_id that does not belong to the visit';
  EXCEPTION WHEN OTHERS THEN
    IF sqlerrm LIKE 'GUARD FAILED%' THEN RAISE; END IF;
  END;
  -- and it must ACCEPT the good case, or the two blocks above would pass on a function that
  -- rejects everything.
  BEGIN
    PERFORM public.fn_set_gdo_evidence_ext(6719, 'aa69c87c-42db-417a-8d5c-3ca9dea83661', 'jpg');
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'CONTROL FAILED: the function rejected a VALID call (%)', sqlerrm;
  END;

  RAISE NOTICE 'OK: rpa-evidence accepts % at % bytes, private; fn_set_gdo_evidence_ext exercised and restored to %',
    b.allowed_mime_types, b.file_size_limit, v_before;
END $$;

COMMIT;
