-- ============================================================================
-- 2026-07-29f — STAGED, NOT APPLIED — close the DERM storage leak by MOVING the
--               raw sheets to a private bucket (NOT by flipping buckets)
-- ============================================================================
-- ⚠ CORRECTION TO AN EARLIER DRAFT OF THIS FILE. The first version proposed
-- `update storage.buckets set public=false` on all three buckets. THAT WAS WRONG
-- and contradicted a decision Fred already made on 2026-07-02, which I had not
-- re-read: a whole-bucket flip is NOT safe, because `GT - Visits Images` holds
-- ~22,789 NON-DERM visit photos that the apps load publicly on purpose. Flipping
-- it 404s all of them to fix 2,572. The agreed shape is a MOVE of the derm/*
-- objects into a new private bucket, leaving both public buckets public.
-- Re-scoping to the move shrinks the blast radius from "all seven consumers" to
-- exactly TWO. Recording the error because the instinct that caused it — plan
-- from the current state, forget the state was already reasoned about — is the
-- same one that produces the "verify one consumer and generalise" mistake.
--
-- ── THE LEAK (measured 2026-07-29, not asserted) ───────────────────────────
-- Raw DERM address sheets are fetchable with NO key and NO headers, at guessable
-- paths: `manifests/derm/<manifest_id>/address_N.jpg` and
-- `GT - Visits Images/derm/<id>/…`, where manifest ids are sequential integers.
-- Each address sheet lists EVERY co-client on that dump ticket — business name
-- and street address. That is precisely what the FP blackout pipeline exists to
-- stop a customer seeing; the redaction is enforced in the app while the raw
-- sheet stays public by URL.
--
-- ── SCOPE: WHAT MOVES, WHAT STAYS (counted 2026-07-29) ─────────────────────
--   MOVE -> new PRIVATE bucket `derm-docs`
--     GT - Visits Images/derm/*     2,572 objects
--     manifests/derm/*                 97 objects
--   STAY PUBLIC (untouched, and this is the whole point of the move)
--     GT - Visits Images  22,789 visit photos  (FP grids, Admin Review classifier)
--     manifests/redacted/*   544 FP customer-facing FOG sheets — HASH-NAMED
--                                (`m<id>-<10hex>.jpg`), so NOT enumerable
--     manifests (other)        1 brand asset
--     gdo-permits            164 — separate 2026-06-24 decision, stays public
--
-- ── WHY THE MOVE BREAKS ONLY TWO THINGS ────────────────────────────────────
-- Consumers of the MOVE SET only (verified against live bundles + column counts):
--   derm_manifests.derm_address_url / derm_manifest_url / fog_manifest_url  ~587
--     -> DERM Tracker: already signs via get-derm-doc. SURVIVES.
--     -> send-derm-email: ⛔ BREAKS (see below).
--   customer.work_orders.wwtp_receipt_url  544
--     -> FP WWTP card passes `kind` -> get-derm-doc. SURVIVES.
--   derm.v_stamp_rows.image_url  559
--     -> Stamp Studio: ⛔ BREAKS. Renders DB public URLs straight into <img> and
--        into new Image()+canvas.toBlob() for the ZIP export, with ZERO
--        storage-client calls, so the export breaks as well as the display.
--
-- NOT affected, because they never touch derm/*:
--   FP FOG card       -> customer.work_orders.derm_manifest_url is 562/562
--                        `manifests/redacted/…`, and 0 rows point at derm/*.
--   FP photo grids    -> customer.wo_photos.url is `visits/…`. Stays public.
--   Admin Review      -> visit photos, `visits/…`. Stays public.
--   Visit Calendar    -> gdo-permits. Untouched.
--   Client App        -> gdo-permits permit link untouched; DERM links sign.
--
-- ⚠ This is why the move beats the flip: the two buckets that CANNOT be signed
-- by an anon browser (GT - Visits Images has no anon SELECT policy — verified,
-- anon-sign 400 vs service_role-sign 200 on the same path) keep serving their
-- public objects exactly as today. Only service-side consumers touch the private
-- bucket, and service_role can always sign.
--
-- ── THE TWO BLOCKERS, BOTH MUST BE FIXED FIRST ─────────────────────────────
-- 1. ⛔ `send-derm-email/index.ts:162 fetchAttachment()` does a bare
--    `await fetch(url)` with NO auth against the stored public URLs. After the
--    move those URLs point at a private bucket and the fetch 400s, so DERM
--    submissions TO THE CITY silently lose their attachment. This is a
--    COMPLIANCE path. Fix (my lane): resolve via service_role
--    `createSignedUrl` — which works on public buckets too, so it can ship and
--    be verified BEFORE the move, independently.
--    ⚠ Do NOT verify it by sending a real submission. Test attachment RESOLUTION
--    only; a real send needs Fred's explicit in-the-moment OK.
-- 2. ⛔ Stamp Studio must stop rendering `derm.v_stamp_rows.image_url` directly
--    (display + ZIP export). It is authenticated, and `derm-docs` will carry an
--    `{authenticated}` SELECT policy, so a client-side `createSignedUrl` IS a
--    sufficient fix there — unlike the anon cases. Building Apps' lane.
--
-- ── URL REWRITE FORMAT (decided 2026-07-24, keep it) ───────────────────────
-- Keep the `/storage/v1/object/public/<bucket>/<path>` SHAPE and swap only the
-- bucket segment to `derm-docs`. Both get-derm-doc's `toBucketPath()` and the
-- Client App helper derive the bucket FROM the stored string and then re-sign, so
-- this repoints every signing consumer with ZERO frontend parser change.
-- ⚠ `derm-docs` must be added to get-derm-doc's bucket fallback list in the same
-- change, or it will fail to resolve the new paths.
--
-- ── EXECUTION ORDER (each step verifiable on its own) ──────────────────────
--   1. Create `derm-docs` PRIVATE + an {authenticated} SELECT policy.
--   2. Fix send-derm-email to sign via service_role. Verify resolution. (mine)
--   3. Stamp Studio -> createSignedUrl. Verify live. (Building Apps)
--   4. Copy the 2,669 objects into `derm-docs`; verify byte counts match.
--   5. Rewrite the URL columns (bucket segment only).
--   6. Re-verify: DERM Tracker, FP WWTP, Stamp Studio, send-derm-email resolution.
--   7. DELETE the public originals under derm/*.
--   8. Drop the now-unnecessary `Public can read manifests` anon policy.
-- ⚠ VERIFY WITH STATUS CODES, NOT PAGES. FP computes its "Documented" chip from
-- `state==='ready' && !!url` — the URL STRING being truthy, never the fetch
-- succeeding — so a broken document still renders a green DOCUMENTED chip over a
-- dead preview. A page-load smoke test PASSES on a broken state.
--
-- ROLLBACK at any point before step 7: repoint the URL columns back to the public
-- bucket. The originals are still there until step 7, so it is fully reversible.
--
-- AUDIT (ADR 010): storage + URL-column change; no business row semantics change.
-- ============================================================================

-- ⚠ COMMENTED OUT DELIBERATELY. Uncomment step by step, in order, verifying each.
-- The object copy itself is NOT SQL — it runs through the storage API with
-- service_role (a script under scripts/migrations/), because storage.objects
-- rows cannot simply be UPDATEd to a different bucket_id without moving bytes.

/*
-- STEP 1 — create the private bucket + let staff apps sign
insert into storage.buckets (id, name, public)
values ('derm-docs', 'derm-docs', false)
on conflict (id) do nothing;

create policy "Authenticated can read derm docs"
  on storage.objects for select
  to authenticated
  using (bucket_id = 'derm-docs');

-- STEP 5 — rewrite the URL columns (bucket segment ONLY; shape preserved)
-- run AFTER the objects exist in derm-docs and BEFORE deleting the originals
update public.derm_manifests set
  derm_address_url  = replace(replace(derm_address_url,  '/object/public/GT%20-%20Visits%20Images/', '/object/public/derm-docs/'), '/object/public/manifests/', '/object/public/derm-docs/'),
  derm_manifest_url = replace(replace(derm_manifest_url, '/object/public/GT%20-%20Visits%20Images/', '/object/public/derm-docs/'), '/object/public/manifests/', '/object/public/derm-docs/'),
  fog_manifest_url  = replace(replace(fog_manifest_url,  '/object/public/GT%20-%20Visits%20Images/', '/object/public/derm-docs/'), '/object/public/manifests/', '/object/public/derm-docs/')
 where derm_address_url like '%/derm/%' or derm_manifest_url like '%/derm/%' or fog_manifest_url like '%/derm/%';
-- ⚠ the *_extra_urls[] array columns need the same treatment — handle explicitly,
--   a scalar replace() will not touch array elements.

-- STEP 8 — after everything verifies, close the last anon door on manifests
-- drop policy "Public can read manifests" on storage.objects;
-- ⚠ only once nothing anon needs to sign `manifests`; the FP redacted/* sheets
--   are served as PUBLIC urls, not signed, so check that first.
*/
