-- ============================================================================
-- 2026-07-29a — let the Field Portal sign gdo-permits objects again
--               (the customer-facing GDO permit PDF link is currently DEAD)
-- ============================================================================
-- ── THE DEFECT ─────────────────────────────────────────────────────────────
-- On every Field Portal work-order page the GDO Permit card renders its text
-- fine (that comes from the RPC payload) but the PDF link is dead for every
-- customer. Reported by the Building Apps session 2026-07-28 while verifying
-- the customer-schema RPC migration; independently reproduced here before
-- being acted on.
--
--   POST /storage/v1/object/sign/gdo-permits/gdo/GDO-11308.pdf
--     as anon         -> HTTP 400 {"statusCode":"404","error":"not_found"}
--     as service_role -> HTTP 200 {"signedURL":"/object/sign/gdo-permits/..."}
--   GET  /storage/v1/object/public/gdo-permits/gdo/GDO-11308.pdf
--                     -> HTTP 200 application/pdf
--
-- Same 400 on a second unrelated permit, and the object is demonstrably present
-- and publicly fetchable, so this is authorization and not a missing file.
-- ⚠ Storage answers a policy failure with `not_found` rather than 403, so that
-- it does not leak object existence. That is exactly why this reads like a data
-- gap and why it survived unnoticed — do not chase a missing-file theory here.
--
-- ── ROOT CAUSE ─────────────────────────────────────────────────────────────
-- `storage.objects` carries SELECT policies for the `manifests` and
-- `GT - Visits Images` buckets and NONE AT ALL for `gdo-permits`, which was
-- created 2026-05-25 and never got one:
--     "Public can read manifests"            roles={anon}          bucket_id='manifests'
--     "Authenticated can read manifests"     roles={authenticated} bucket_id='manifests'
--     "Authenticated can read GT visit imgs" roles={authenticated} bucket_id='GT - Visits Images'
--     (nothing for gdo-permits)
-- A PUBLIC bucket serves /object/public/... without consulting RLS, which is why
-- the file is fetchable by URL. But createSignedUrl() takes a different path: it
-- must SELECT the row from storage.objects first, and with no policy that select
-- returns nothing. Hence sign fails while the public URL works. Contrast
-- `manifests`, which IS signable by anon precisely because it has the policy.
--
-- Confirmed not caused by the RPC migration: BA touched src/lib/portal.ts only,
-- the storage call lives in WorkOrderView.tsx and was untouched, and the permits
-- payload is byte-identical before and after. No historical success exists in the
-- edge log to date the break, and FP traffic is sparse enough that log silence
-- proves nothing, so no break date is claimed.
--
-- ── WHY THIS GRANT ADDS NO EXPOSURE ────────────────────────────────────────
-- `gdo-permits` is already a PUBLIC bucket: anyone can fetch any permit today at
-- a predictable /object/public/gdo-permits/gdo/<GDO-NUMBER>.pdf URL with no key
-- at all. Allowing anon to SIGN the same object therefore grants nothing that is
-- not already freely available — it restores parity with `manifests` and fixes
-- the customer-visible break. Net change in what anon can read: zero.
--
-- ⚠⚠ THIS IS A RESTORATION, NOT THE RIGHT LONG-TERM DESIGN. Do not treat it as
-- the storage leg being done. The durable fix is the one already pending in
-- project_pending_derm_storage_private: buckets go PRIVATE, and the Field Portal
-- receives a service_role-signed URL from a SECDEF RPC / edge function that has
-- first validated slug+token — the same shape as the 28v customer RPC migration.
-- ⚠ WHEN THAT LANDS, THIS POLICY MUST BE DROPPED IN THE SAME MIGRATION, or the
-- bucket will go private while anon retains the ability to sign every permit in
-- it, which would silently preserve the exact exposure the storage leg exists to
-- close. Per-client scoping is NOT achievable at the storage-RLS layer today:
-- permit paths are keyed by GDO number (`gdo/GDO-11308.pdf`), not by client, and
-- an anon Field Portal caller carries no client identity in its JWT to filter on.
--
-- ROLLBACK:
--   DROP POLICY "Public can read gdo permits" ON storage.objects;
--
-- AUDIT (ADR 010): policy-only change on a storage table, no business data
-- touched, no table shape changed.
-- ============================================================================

begin;

drop policy if exists "Public can read gdo permits" on storage.objects;

create policy "Public can read gdo permits"
  on storage.objects for select
  to anon, authenticated
  using (bucket_id = 'gdo-permits');

commit;
