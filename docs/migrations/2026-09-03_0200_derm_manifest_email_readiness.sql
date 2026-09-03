-- 2026-09-03_0200_derm_manifest_email_readiness.sql
--
-- WHAT: public.v_derm_manifest_email_readiness. One row per live manifest, telling the DERM Tracker
--       whether it may be emailed at all and whether the photos checkbox can do anything.
--
-- WHY:  Fred, 2026-09-03: *"we shouldn't be able to send an email from the DERM App if the manifest
--       isn't blackedout meaning we also need a way to verify if the manifest is blackedout"*, and
--       the photos checkbox *"should be checked by default, but we should have a verification to
--       make sure we first have images classified, if we don't then disable it."*
--
--       The app cannot answer either question today. It reads `public` only, and it holds no grant
--       on derm.redacted_manifest_docs, so "is this blacked out" is simply unavailable to it.
--
-- 🛑 WHY A VIEW AND NOT A JOIN IN THE APP. `authenticated` has NO SELECT on
--    derm.redacted_manifest_docs (verified, not assumed). An owner-rights view launders that grant,
--    which is the schema-per-app pattern this estate already uses for customer.* and client.*.
--
-- 🛑 NO SECURITY INVOKER FUNCTION MAY GO IN HERE. One inside a view adds an invoker-side EXECUTE
--    check to the READ path and returned 42501 to pg_read_all_data once already (2026-08-25_1400).
--    Plain SQL only, which is why is_blacked_out is an EXISTS and not a helper call.
--
-- ⚠ send_blocker DELIBERATELY DOES NOT INCLUDE "no classified photos". That is not a reason to stop
--    an email; it is a reason to disable one checkbox. Conflating the two would refuse to send 665
--    perfectly good manifests because nobody had classified their photos.
--
-- ⚠ classified_images COUNTS public.photo_classifications, NOT photo_links.role. Every role in the
--    estate is 'other' or 'attachment'; the before/after split lives in service_phase. Getting this
--    wrong is what made an earlier test of the photos flag unable to discriminate: visit 6347 has 42
--    photos, 0 classified, and renders a byte-identical PDF either way.
--
-- RULE 8 (audit): no table or column changes. A view only.
-- RULE 2/3: nothing stored or copied; both facts are derived on read from their own sources.

BEGIN;

CREATE OR REPLACE VIEW public.v_derm_manifest_email_readiness AS
SELECT
  m.id                                   AS manifest_id,
  m.client_id,
  m.white_manifest_number,
  EXISTS (
    SELECT 1 FROM derm.redacted_manifest_docs d WHERE d.manifest_id = m.id
  )                                      AS is_blacked_out,
  COALESCE(pc.classified_images, 0)      AS classified_images,
  COALESCE(pc.classified_images, 0) > 0  AS has_classified_photos,
  CASE
    WHEN NOT EXISTS (SELECT 1 FROM derm.redacted_manifest_docs d WHERE d.manifest_id = m.id)
      THEN 'not_blacked_out'
    ELSE NULL
  END                                    AS send_blocker
FROM public.derm_manifests m
LEFT JOIN LATERAL (
  SELECT SUM(vp.classified_images)::int AS classified_images
    FROM public.manifest_visits mv
    JOIN public.v_visit_photo_counts vp ON vp.visit_id = mv.visit_id
   WHERE mv.manifest_id = m.id
) pc ON TRUE
WHERE m.deleted_at IS NULL;

COMMENT ON VIEW public.v_derm_manifest_email_readiness IS
  'Per live manifest: may it be emailed (is_blacked_out / send_blocker), and can the photos checkbox do anything (has_classified_photos). Owner-rights on purpose: authenticated holds no grant on derm.redacted_manifest_docs. send_blocker covers ONLY reasons to refuse a send; a lack of classified photos disables a checkbox, it does not block an email.';

GRANT SELECT ON public.v_derm_manifest_email_readiness TO authenticated;

DO $$
DECLARE
  v_rows int; v_live int; v_blk int; v_notblk int;
  r1763 record; r1750 record; r1719 record;
  v_authn boolean; v_anon boolean; v_mismatch int;
BEGIN
  -- 1. one row per LIVE manifest, no more and no fewer
  SELECT count(*) INTO v_rows FROM public.v_derm_manifest_email_readiness;
  SELECT count(*) INTO v_live FROM public.derm_manifests WHERE deleted_at IS NULL;
  IF v_rows <> v_live THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: view has % rows, % live manifests', v_rows, v_live;
  END IF;

  -- 2. the blackout split matches an INDEPENDENT recomputation, not the view's own expression
  SELECT count(*) FILTER (WHERE is_blacked_out), count(*) FILTER (WHERE NOT is_blacked_out)
    INTO v_blk, v_notblk FROM public.v_derm_manifest_email_readiness;
  SELECT count(*) INTO v_mismatch
    FROM public.v_derm_manifest_email_readiness v
    JOIN public.derm_manifests m ON m.id = v.manifest_id
   WHERE v.is_blacked_out
     IS DISTINCT FROM EXISTS (SELECT 1 FROM derm.redacted_manifest_docs d WHERE d.manifest_id = m.id);
  IF v_mismatch <> 0 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: % rows disagree with a direct recomputation', v_mismatch;
  END IF;
  IF v_notblk = 0 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: no manifest reports NOT blacked out, so the flag is untested';
  END IF;

  -- 3. THE THREE FIXTURES. A view that returned a constant would pass counts; these do not.
  SELECT * INTO r1763 FROM public.v_derm_manifest_email_readiness WHERE manifest_id = 1763;
  SELECT * INTO r1750 FROM public.v_derm_manifest_email_readiness WHERE manifest_id = 1750;
  SELECT * INTO r1719 FROM public.v_derm_manifest_email_readiness WHERE manifest_id = 1719;

  IF NOT r1763.is_blacked_out OR NOT r1763.has_classified_photos OR r1763.send_blocker IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: 1763 should be sendable with photos, got blacked=% photos=% blocker=%',
      r1763.is_blacked_out, r1763.classified_images, r1763.send_blocker;
  END IF;
  IF NOT r1750.is_blacked_out OR r1750.has_classified_photos OR r1750.send_blocker IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: 1750 should be sendable with NO photos, got blacked=% photos=% blocker=%',
      r1750.is_blacked_out, r1750.classified_images, r1750.send_blocker;
  END IF;
  IF r1719.is_blacked_out OR r1719.send_blocker IS DISTINCT FROM 'not_blacked_out' THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: 1719 should be blocked, got blacked=% blocker=%',
      r1719.is_blacked_out, r1719.send_blocker;
  END IF;

  -- 4. CONTROL: the two flags are INDEPENDENT. 1750 proves a blacked-out manifest can have no
  --    photos, and it must NOT be blocked for that. Without this the two could be conflated and
  --    every unclassified manifest would silently become unsendable.
  IF r1750.send_blocker IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: a manifest with no classified photos was marked unsendable';
  END IF;

  -- 5. grants: the app can read it, anon cannot
  SELECT has_table_privilege('authenticated','public.v_derm_manifest_email_readiness','SELECT'),
         has_table_privilege('anon','public.v_derm_manifest_email_readiness','SELECT')
    INTO v_authn, v_anon;
  IF NOT v_authn THEN RAISE EXCEPTION 'VERIFY 5 FAILED: authenticated cannot read the view'; END IF;
  IF v_anon THEN RAISE EXCEPTION 'VERIFY 5 FAILED: anon can read the view'; END IF;

  RAISE NOTICE 'OK: % manifests, % blacked out, % not; fixtures 1763/1750/1719 behave as specified.',
    v_rows, v_blk, v_notblk;
END $$;

COMMIT;
