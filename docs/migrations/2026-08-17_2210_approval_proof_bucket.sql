-- 2026-08-17_2210_approval_proof_bucket.sql
--
-- WHAT: the storage + link layer for approval-proof images on a job frequency change.
--         1. private bucket `approval-proof`
--         2. 'job_frequency_change' added to photo_links_entity_type_chk
--         3. one SELECT policy so staff can SIGN a URL; writes stay service_role-only
--
-- WHY: Yannick asked for proof of approval on a cadence change, "the slack link OR a screenshot of
--      whatsapp". Fred: any image, and "something must be required, either they put a photo, or a
--      text". Text-only shipped 2026-08-17; this is the image half.
--      Design: docs/superpowers/specs/2026-08-17-frequency-change-proof-upload-design.md
--
-- 🛑 NO NEW TABLES. ADR 009 is explicit — "No new per-entity photo tables", "No inline photo URL
--      columns". An image is a `photos` row plus a polymorphic `photo_links` row. This migration adds
--      a CHECK value, not a table.
--      ⚠ ADR 009 also claims "zero schema churn when adding a photo-owning entity". THAT IS STALE:
--      photo_links_entity_type_chk is a whitelist (derm_manifest, inspection, note, visit), the same
--      trap entity_source_links has. Hence this file. The ADR is corrected in the same commit.
--
-- 🛑 PRIVATE, AND THAT WAS A DECISION (Fred). An approval screenshot can be a whole WhatsApp
--      conversation: names, numbers, pricing. Every other image bucket here is PUBLIC
--      (`GT - Visits Images`, `manifests`, `gdo-permits`), meaning anyone holding the URL reads it
--      with no login. `rpa-evidence` is the only private one and is the model followed here, but
--      DELIBERATELY a separate bucket: that one is the GDO bot's evidence, and mixing human-supplied
--      approval proof into it would confuse the provenance of both.
--
-- 🛑 WRITES ARE service_role ONLY. There is no INSERT policy for `authenticated` on purpose. The app
--      never uploads directly: `save-client-job` receives base64 and PUTs it after Jobber confirms, so
--      no object can exist for a change that did not happen. Same shape as parse-gdo-permit. Adding an
--      INSERT policy here would defeat the reason the bucket is closed.
--
-- ⚠ THE READ POLICY TESTS auth.uid(), NOT THE ROLE, and that asymmetry has already caused a bug
--      elsewhere: a signed-URL call made BEFORE the session hydrates matches zero rows, storage
--      answers not_found, and the UI renders an empty frame instead of an auth error. The app must
--      sign only after auth resolves. (Building Apps rule 7b.)
--
-- AUDIT (ADR 010): public.photo_links already carries audit_photo_links -> audit.log_change and a
--      deleted_by stamper, so proof removal is captured with old_row. public.photos carries NEITHER,
--      which is why removal soft-deletes the LINK and never the photos row. No trigger change here.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. the bucket
-- ---------------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('approval-proof', 'approval-proof', false, 5242880, ARRAY['image/jpeg','image/png'])
ON CONFLICT (id) DO UPDATE
   SET public = false,
       file_size_limit = 5242880,
       allowed_mime_types = ARRAY['image/jpeg','image/png'];

-- ---------------------------------------------------------------------------
-- 2. the new link kind
-- ---------------------------------------------------------------------------
ALTER TABLE public.photo_links DROP CONSTRAINT IF EXISTS photo_links_entity_type_chk;
ALTER TABLE public.photo_links
  ADD CONSTRAINT photo_links_entity_type_chk
  CHECK (entity_type = ANY (ARRAY[
    'derm_manifest'::text,
    'inspection'::text,
    'job_frequency_change'::text,   -- added 2026-08-17
    'note'::text,
    'visit'::text
  ]));

COMMENT ON CONSTRAINT photo_links_entity_type_chk ON public.photo_links IS
  'Whitelist of photo-owning entity kinds. A new kind needs a migration — ADR 009''s "zero schema '
  'churn" claim does not hold because of this constraint. Roles are app-level; '
  'job_frequency_change uses role=''approval_proof''.';

-- ---------------------------------------------------------------------------
-- 3. read-only access for staff, so the app can SIGN a url. No write policy.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS approval_proof_staff_read ON storage.objects;
CREATE POLICY approval_proof_staff_read ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'approval-proof' AND auth.uid() IS NOT NULL);

-- ---------------------------------------------------------------------------
-- 4. assertions. EXERCISE the constraint and the privacy posture.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_change bigint; v_photo bigint; v_link bigint; n int; v_pub boolean;
BEGIN
  -- (A) the bucket is PRIVATE, with a public bucket as the control so "false" is not just a default
  SELECT public INTO v_pub FROM storage.buckets WHERE id = 'approval-proof';
  IF v_pub IS DISTINCT FROM false THEN RAISE EXCEPTION 'approval-proof is not private'; END IF;
  SELECT public INTO v_pub FROM storage.buckets WHERE id = 'GT - Visits Images';
  IF v_pub IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'CONTROL FAILED: GT - Visits Images is not public, so this DB does not distinguish public from private the way this test assumes';
  END IF;

  -- (B) the CHECK accepts the new kind AND still rejects a fabricated one. Two-sided, or a
  --     constraint that had been dropped entirely would pass the first half.
  SELECT id INTO v_change FROM public.job_frequency_changes ORDER BY id DESC LIMIT 1;
  IF v_change IS NULL THEN
    RAISE EXCEPTION 'CONTROL FAILED: no job_frequency_changes row exists, so the link below cannot be exercised';
  END IF;
  INSERT INTO public.photos (storage_path, file_name, content_type, source)
  VALUES ('client-app/job-frequency/probe/'||gen_random_uuid()||'.jpg', 'probe.jpg', 'image/jpeg', 'client_app_upload')
  RETURNING id INTO v_photo;

  INSERT INTO public.photo_links (photo_id, entity_type, entity_id, role)
  VALUES (v_photo, 'job_frequency_change', v_change, 'approval_proof')
  RETURNING id INTO v_link;

  BEGIN
    INSERT INTO public.photo_links (photo_id, entity_type, entity_id, role)
    VALUES (v_photo, 'not_a_real_entity_kind', v_change, 'approval_proof');
    RAISE EXCEPTION 'GUARD FAILED: the CHECK accepted a fabricated entity_type';
  EXCEPTION
    WHEN check_violation THEN NULL;
    WHEN OTHERS THEN IF SQLERRM LIKE 'GUARD FAILED%' THEN RAISE; END IF;
  END;

  -- (C) the link soft-deletes and audit.logs captures it with old_row. That is the whole basis for
  --     removing proof via the LINK rather than the photos row.
  UPDATE public.photo_links SET deleted_at = now(), deleted_reason = 'probe' WHERE id = v_link;
  SELECT count(*) INTO n FROM audit.logs
   WHERE table_name = 'photo_links' AND operation = 'UPDATE'
     AND (record_pk->>'id')::bigint = v_link AND old_row IS NOT NULL;
  IF n < 1 THEN
    RAISE EXCEPTION 'CONTROL FAILED: photo_links soft-delete was not captured in audit.logs with old_row';
  END IF;

  -- (D) `authenticated` may READ the bucket but has NO write policy on it. If a write policy exists,
  --     the app could bypass the verified upload path entirely.
  SELECT count(*) INTO n FROM pg_policy
   WHERE polrelid = 'storage.objects'::regclass
     AND polname = 'approval_proof_staff_read' AND polcmd = 'r';
  IF n <> 1 THEN RAISE EXCEPTION 'the staff read policy is missing'; END IF;

  SELECT count(*) INTO n FROM pg_policy
   WHERE polrelid = 'storage.objects'::regclass
     AND polcmd <> 'r'
     AND (coalesce(pg_get_expr(polqual, polrelid), '') LIKE '%approval-proof%'
       OR coalesce(pg_get_expr(polwithcheck, polrelid), '') LIKE '%approval-proof%');
  IF n <> 0 THEN
    RAISE EXCEPTION 'a NON-read policy references approval-proof (% found); writes must stay service_role-only', n;
  END IF;

  RAISE NOTICE 'OK: bucket private, CHECK two-sided, link soft-delete audited, no write policy';
END $$;

-- the assertions inserted a probe photo + link; discard everything and re-apply the DDL below.
ROLLBACK;

BEGIN;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('approval-proof', 'approval-proof', false, 5242880, ARRAY['image/jpeg','image/png'])
ON CONFLICT (id) DO UPDATE
   SET public = false,
       file_size_limit = 5242880,
       allowed_mime_types = ARRAY['image/jpeg','image/png'];

ALTER TABLE public.photo_links DROP CONSTRAINT IF EXISTS photo_links_entity_type_chk;
ALTER TABLE public.photo_links
  ADD CONSTRAINT photo_links_entity_type_chk
  CHECK (entity_type = ANY (ARRAY[
    'derm_manifest'::text,
    'inspection'::text,
    'job_frequency_change'::text,
    'note'::text,
    'visit'::text
  ]));

COMMENT ON CONSTRAINT photo_links_entity_type_chk ON public.photo_links IS
  'Whitelist of photo-owning entity kinds. A new kind needs a migration — ADR 009''s "zero schema '
  'churn" claim does not hold because of this constraint. Roles are app-level; '
  'job_frequency_change uses role=''approval_proof''.';

DROP POLICY IF EXISTS approval_proof_staff_read ON storage.objects;
CREATE POLICY approval_proof_staff_read ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'approval-proof' AND auth.uid() IS NOT NULL);

DO $$
DECLARE n int; v_pub boolean;
BEGIN
  SELECT public INTO v_pub FROM storage.buckets WHERE id='approval-proof';
  IF v_pub IS DISTINCT FROM false THEN RAISE EXCEPTION 'bucket did not land private'; END IF;
  SELECT count(*) INTO n FROM pg_constraint
   WHERE conname='photo_links_entity_type_chk'
     AND pg_get_constraintdef(oid) LIKE '%job_frequency_change%';
  IF n <> 1 THEN RAISE EXCEPTION 'the CHECK did not land'; END IF;
  SELECT count(*) INTO n FROM public.photo_links WHERE entity_type='job_frequency_change';
  IF n <> 0 THEN RAISE EXCEPTION 'a probe link row survived the rollback (% rows)', n; END IF;
  SELECT count(*) INTO n FROM public.photos WHERE storage_path LIKE 'client-app/job-frequency/probe/%';
  IF n <> 0 THEN RAISE EXCEPTION 'a probe photo row survived the rollback (% rows)', n; END IF;
  RAISE NOTICE 'OK: bucket + CHECK + read policy live, no probe rows left behind';
END $$;

COMMIT;
