# DERM paperwork storage: final plan (reviewed 2026-09-27)

> ## ✅ Stage 0 DONE, 2026-09-27 (Fred: "Start with Stage 0")
>
> Every step was tested with a baseline first (the hole proven open), then the change, then the same test
> (closed), plus a control. No file was moved or deleted.
>
> | step | result |
> |---|---|
> | 0.1 generators | `generate-derm-address-preview` v27, `generate-fog-manifest` v21 and (added, the plan missed it) `generate-derm-address-pdf` v29: gateway check on (pinned in `config.toml`) plus an in-code check, service_role or a signed-in staff email. Before: anyone (even with no token) reached the preview and fog generators, and the public anon key reached the PDF one. After: anon key, no token and a forged token all get 401; staff and the service key pass. The DERM Tracker's Visits page "Generate" now sends the user's session (it sent the hard-coded anon key), published first (`index-OiSKwQFZ.js`). |
> | 0.2 get-derm-doc | v26. kind `fog` is staff-only; an unknown client and an unknown manifest now get the same 403. **Found on the way and closed: a forged token bypass.** The address/fog gate read the token's role claim without checking its signature, and this function runs with the gateway check off, so a hand-made `{"role":"service_role"}` token with a garbage signature got the raw sheet (measured HTTP 200). service_role is now recognised only by an exact match with the function's own key; users still go through `auth.getUser`. Every other function that trusts a role claim was checked LIVE: all run with the gateway check on. kind `manifest` (the Field Portal receipt card) stays open until Stage 4d, as planned. |
> | 0.3 storage rules | `2026-09-27_1215_derm_storage_stage0_policies.sql`. Anonymous uploads under derm/ closed (baseline: an anonymous upload returned 200 in both buckets; after: refused by RLS). Signed-in deletes under derm/ blocked by one RESTRICTIVE policy (signed-in upload still 200; signed-in delete removes nothing; control: a signed-in delete outside derm/ still works). Probe files removed. |
> | 0.4 mirror job | "Mirror DERM PDFs to Supabase Storage" disabled (`disabled_manually`); no run since. |
> | 0.5 fog.pdf | Fred: pause it. Storage logs for the last 7 days: 0 real downloads of any fog.pdf (1, from our own test script), 26 uploads by the generator. "Generate FOG Manifests" disabled; re-enabling back-fills. |
>
> Commits: Supabase `1b3a4cb` `061b18c` `7bf5537` `1db808f` `cafd642`. Rollback per step is in each step below.

## 1. Summary

About 3,022 DERM paperwork files (1.39 GB, growing by about 42 a week) sit in two public buckets at numbered paths anyone can walk. Every name pattern downloads with no login: one file of each of the 24 patterns returned HTTP 200. Each file on its own is a Florida public record. Together they are a free, pre-joined map of which businesses share a dump ticket, and the per-client fog.pdf alone is enough to rebuild that map (127 of 127 multi-client tickets).

The plan has two parts:
1. **First, close three side doors that bypass storage entirely.** An unauthenticated sheet generator returns rendered client sheets. The signing service hands out documents to anyone who has a guessable client code. And the upload and delete rules on the derm/ folder are open.
2. **Then move the files into a new private bucket, in small checked batches.** For each batch we rewrite every stored link in one self-checking transaction, and we move each public original into a private quarantine bucket instead of deleting it.

Why this beats the alternatives:
- A folder inside a public bucket cannot be made private, because the public download route never reads a policy.
- Making the whole buckets private would break 28,049 visit photos, 775 customer FOG sheets, and the logo in every email already sent.
- Random file names would leave permanent public links that nobody can revoke.
- Moving only the address sheets leaves fog.pdf, which rebuilds the same map.

Compared with the July plan:
- Nothing is deleted until the last step, and that step is optional.
- Every reader and every writer is fixed before a referenced file moves.
- Each mechanism is tried first on files nothing reads (1,097 orphans), then on the test client 112-YA, then on one real ticket, and only then in waves.

## 2. The stages in one screen

| # | Stage | What it does | Can it be undone? |
|---|---|---|---|
| 0 | Week-1 hardening | Close the three side doors, disable the dead mirror job, and (if Fred agrees) pause the fog.pdf generator. | Yes |
| 1 | Baseline and tools | Measure everything, build and prove the tools. Changes nothing. | Nothing to undo |
| 2 | Private buckets | Create derm-docs and derm-quarantine, and prove copy, move and signing on a few files. | Yes |
| 3 | Archive, then orphans | Take an encrypted archive, then move the 1,097 files that belong to deleted manifests (36% of the exposure). | Yes |
| 4 | Readers | Make every reader work with any bucket, one small deploy at a time, while files are still public. | Yes |
| 5 | Pilot on 112-YA | Full cycle on the test client, including a real rollback. | Yes |
| 6 | Writers | New files go only to derm-docs, and the public derm/ folders are locked. | Yes |
| 7 | Files no live manifest uses | Move about 685 more. | Yes |
| 8 | Real canary | One real multi-client ticket, one Broward FDEP sheet and one Broward per-visit sheet. | Yes |
| 9 | Waves | About 1,240 referenced files, ordered by harm. | Yes, per batch |
| 10 | Final audit and 30-day soak | Prove the public folders are empty and nothing broke. | Yes |
| 11 | Optional: delete the quarantine | The only irreversible step. | No |

After Stage 7, about 58% of the files are private. The rest become private wave by wave in Stage 9.

## 3. Stages in detail

Each stage below lists its goal, what it does, the small test, the audit gate that must pass before the next stage, the rollback, and whether it is reversible. The tool rules, the rewrite transaction and the rollback generator are in Appendix B. The counts that the gates check are in Appendix A.

### Stage 0. Week-1 hardening (no file moves)

**Goal.** Shut the paths that leak documents or let strangers write, whichever bucket the files sit in. Five independent steps, each one small, tested and reversible on its own.

**0.1 Caller check on the two generator endpoints.**
- **Why.** generate-derm-address-preview streams back the rendered sheet with no caller check (index.ts:150 `new Response(upstream.body`; no getUser in the file; config.toml:418-419 verify_jwt=false). Anyone can post sequential visit_ids and get a Miami-Dade DERM form listing client facilities and addresses. Each such call also burns a real sheet number and writes provenance rows, and on Broward it writes storage. generate-fog-manifest lets anyone overwrite fog.pdf. Probe (Investigation 2): a no-header POST returned 400 invalid_json from the function body, not 401.
- **Order (so no user sees an outage):**
  1. Publish the DERM Tracker change that sends the user's session instead of the anon key. Today's function still accepts that.
  2. Deploy both functions with a check that accepts service_role or a staff JWT, using the pattern already in derm-visit-report (index.ts:73-79). The fog cron uses the service key (cron_generate_fog_manifests.js:28, 41-42), so it keeps working.
- **Small test:**
  - One staff preview on 112-YA returns 200.
  - One service-role call of generate-fog-manifest for 112-YA manifest 1941 returns 200.
  - The no-header probe returns 401 on both.
- **Gate:** the deployed bodies, read back with edge_deployed_body.js, contain the check (plus a control needle), and the DERM Tracker bundle, walked from real routes, sends a session.
- **Rollback:** redeploy v25 and v19 and restore the previous Tracker version.

**0.2 Close the anonymous signing path for kind 'fog'.**
- **Why.** get-derm-doc gates only kind 'address' (index.ts:116). For 'fog' and 'manifest' it signs for any caller who supplies a manifest_id and a client_code. The file's own comment says the client code "is therefore not a secret" (index.ts:100). It also leaks whether a code exists: an unknown client returns 403 (line 152) before an unknown manifest returns 404 (line 159). Once files are private, this function would hand them back out.
- **What changes now:**
  - Gate kind 'fog' exactly like 'address'. No live bundle calls it (kind:"fog" appears in 0 chunks of all five apps).
  - Return one identical 403 body for unknown client, unknown manifest and not entitled.
  - Kind 'manifest' stays open until Stage 4d moves the Field Portal WWTP card off it, because gating it now would break that customer card.
- **Small test:**
  - An anonymous kind 'fog' call returns 401.
  - DERM Tracker galleries on 112-YA return 200.
  - The FP WWTP card on one real visit returns 200.
  - The unknown-client and unknown-manifest responses are byte-identical.
- **Rollback:** redeploy v23.

**0.3 Storage rules on the public derm/ folders.**
- **What changes.** Save the definitions of the two anon INSERT policies ("Anon can upload to derm path in GT visit images" and "... in manifests"), then drop them. Add RESTRICTIVE policies that deny authenticated DELETE where `storage.foldername(name)[1] = 'derm'` on both public buckets.
- **Evidence:**
  - There have been no anon writes to manifests/derm since 2026-08-10, and 0 of 2,813 GT/derm objects have an owner (Investigation 2).
  - There are 0 RESTRICTIVE storage policies today, and authenticated INSERT, UPDATE and DELETE are bucket-wide on both buckets (pg_policies, 2026-09-27).
  - The only storage delete call in any live bundle is the Client App's `storage.from(r.bucket).remove(` (reason photos). The DERM Tracker has none (bundle grep).
- **Small test:**
  - An anon upload under derm/ returns 4xx.
  - One staff upload on the DERM Tracker upload page for 112-YA creates an object with owner_id set.
  - The migration VERIFY block reads the policies back and evaluates the predicate on sample names. derm/1941/fog.pdf must be denied for DELETE, and visits/x must still be allowed.
- **Rollback:** recreate the saved anon policies and drop the restrictive ones.

**0.4 Disable the "Mirror DERM PDFs to Supabase Storage" GitHub workflow.**
- **Why.** Its source, Airtable DERM, is retired, and the last run logged "0 rows to process". If a non-Supabase URL ever appears, it would recreate a public copy.
- **Test:** the next 15-minute slot does not run.
- **Rollback:** re-enable it.

**0.5 (Fred decides) Pause the hourly fog.pdf generator if nothing uses fog.pdf.**
- **Evidence that nothing reads it:**
  - fog_manifest_url is referenced by client.derm_manifests, by customer.work_orders(_all) only inside an inner lateral (it is not an output column), and by one function, derm.audit_pack (information_schema and pg_proc, 2026-09-27).
  - It appears in 0 live app bundles, and kind 'fog' has 0 callers.
- **Effect:** fog.pdf is 115 of the 198 new public files in the last 30 days (58%).
- **Small test:** after disabling generate-fog-manifests.yml, one new manifest appears with fog_manifest_url NULL, and no health view or email-readiness view changes.
- **Rollback:** re-enable it. The cron picks every row with fog_manifest_url IS NULL, so it back-fills on its first run.

**Reversible:** yes, every step.

### Stage 1. Baseline, census and tools (read-only in production)

**Goal.** A measured picture of today and tools that have been proven to fail when they should.

**Actions:**
- **Claim the work** in WORKING-NOW.md and commit it in the same step. List every resource this plan touches (Appendix A), and give each Lovable project one owner per step.
- **Census by catalogue sweep, never by a fixed column list.** Sweep every text, text[] and jsonb column in the public, derm, client, customer, ops, raw and sync schemas, plus every *_bucket/*_path pair. It must reproduce Appendix A2 and find these known controls, or it is blind:
  - the 3 dangling generated_visit_sheets rows;
  - the 25 soft-deleted manifests that carry derm URLs;
  - the ops.pgss_snapshot query texts (excluded as not links).
- **Classify every object** using a numeric folder test, `split_part(name,'/',2) ~ '^[0-9]+$'`, so that derm/sheets and derm/broward-sheets are not called orphans. Classes: orphan, unreferenced, referenced only by soft-deleted manifests, referenced only by non-manifest columns, referenced live.
- **Group map.** Build connected groups from paths, rows, the ticket key COALESCE(white, yellow), and same-eTag-within-ticket edges. Every batch is a union of whole groups.
- **Outcome baseline.** Record outcomes, not cron status:
  - blackout_sweep_log error_count and redacted_manifest_errors (0 today);
  - the rate of new address_sheet_scan_reads, sheet_number_ocr_attempts and generated_measure_attempts rows;
  - v_stamp_placement_health, v_blackout_blocked_sheets, v_blackout_completed_unpublished, v_band_edges_off_rule, v_sheet_number_ocr_backlog (109 rows), v_generated_measure_backlog;
  - v_derm_portal_queue, and the v_city_email_candidates status histogram;
  - ticket_page_images for every ticket, and fn_blackout_targets(1000);
  - non-null wwtp_receipt_url in customer.work_orders (794) and work_orders_all (815).
- **Reference renders.** Render (not send) reports on both the FP and the DERM targets, for cases chosen by query: one GT receipt, one manifests receipt, one Broward per-visit sheet, one redacted doc, and one work_orders_all-only visit. Record each render's embedded image count.
- **Build the tools** in Appendix B and prove each one once against a deliberately wrong input.

**Small test:** the reconciliation query flags a planted wrong ledger row, and the status probe voids its own run when either control is missing.

**Gate:** census totals match Appendix A within known growth, every control is found, and every tool's negative test fires.

**Rollback:** nothing to roll back.

**Reversible:** yes.

### Stage 2. Private buckets and a few-object proof

**Goal.** Prove on real objects, with nothing public changing, that copy and move behave the way the rest of the plan assumes.

**Actions:**
- **Create derm-docs:**
  - private;
  - 52,428,800-byte limit;
  - MIME types image/jpeg, image/png, image/webp and application/pdf (the measured union of the move set: pdf 836, jpeg 2,158, png 26, webp 2).
- **Policies on derm-docs.** All are for authenticated users with `bucket_id='derm-docs' AND auth.uid() IS NOT NULL`:
  - SELECT;
  - UPDATE;
  - INSERT, with `storage.foldername(name)[1]='derm'`.
  There is no anon policy and no DELETE policy. The DERM Tracker's upsert:true needs INSERT, UPDATE and SELECT.
- **Create derm-quarantine:** private, no policies.
- **VERIFY block in the migration:**
  - The policies read back correctly.
  - authenticated without a uid sees 0 rows (the blank-frame trap).
  - With a uid, it sees rows.
  - anon sees none.
- **Proof steps:**
  1. REST copy (`POST /storage/v1/object/copy`, destinationBucket) of 112-YA's fog.pdf (GT) and manifest_1.jpg (manifests), plus the one pdf and one webp file under manifests/derm.
  2. Move the fog.pdf copy into quarantine and back.
  3. Move a webp into 'manifests' under a scratch name, to learn whether a rollback of the 3 non-jpeg/png objects would be refused. That bucket allows only jpeg and png.
  4. Call the CDN purge endpoint once on a _brand asset, to learn which key it accepts.

**Gate:**
- Each copy row is in the destination bucket, not the source (the July supabase-js failure), with the same name, eTag, size and mimetype.
- The moved copy keeps its row id and eTag across both hops.
- /object/public/derm-docs/... returns 400.
- A service-role signed URL returns 200 with content-length equal to size.
- Anon signing returns 4xx.
- The public originals still return 200, on both /object/public/ and /render/image/public/.
- Every probe run includes a known 200 (a visit photo) and a known 400 (an rpa-evidence object), or the run is void.

**End of stage:** delete the test copies through the Storage API. They are duplicates, and the originals are untouched. This stops a later stage from finding a same-name copy and wrongly recording the original as done.

**Rollback:** delete the test copies and drop both buckets and their policies.

**Reversible:** yes.

### Stage 3. Encrypted archive, then move the 1,097 orphan files

**Goal.** Close about 36% of the exposure using files that have no database reference and no reader, and prove move, reconciliation, CDN invalidation and rollback at scale.

**Actions:**
- **Archive.** Download every derm/ object with the service key to the encrypted offline location Fred chooses, outside every repo and synced folder. As the download's integrity check, compare each file's MD5 with its eTag (all 3,022 are single-part MD5-shaped). Where they differ, compare size and download again. Before every later move batch, refresh the archive with new and changed objects.
- **Re-census.** An object qualifies only if its numeric folder has no derm_manifests row, live or deleted, and nothing references it. Expected: GT 1,091 plus manifests 6. Manifest ids come from a sequence (last_value 1988 = max id), so no orphan folder can be reused.
- **Move.** Canary of 25 objects spread over the name patterns. Rehearse the rollback on 5 of them (back, then forward again). Then batches of 100, with at most 5 requests in flight.

**Gate, per object:**
- The same row id now has bucket derm-docs, and the same name, eTag, size and mimetype as the ledger.
- No row remains at the old (bucket, name).

**Gate, per batch:**
- The public derm/ count fell by exactly the batch size, and the derm-docs count rose by the same amount.
- The visits/*, redacted/* and _brand counts are unchanged.
- The census shows 0 references to the moved paths.
- A sample of old /object/public/ and /render/image/public/ URLs returns 4xx within 2 minutes, with the probe's controls. If anything still serves, run a purge.
- One signed sample returns 200.
- The outcome ledgers stay at baseline.

**After any move error:** check the source bytes with the service key before retrying. A row that is present but whose bytes are missing is restored from the archive. The platform queues the source-byte delete before COMMIT (object.ts:541-571).

**Rollback:** move the files back using the ledger. If Stage 2 showed that 'manifests' refuses webp or pdf, widen its MIME list first for those files.

**Reversible:** yes.

### Stage 4. Make every reader work with any bucket (files still public, users see no change)

Six separate deploys, each with its own test and rollback. Claim each Lovable project in WORKING-NOW.md for its own step.

**4a. Server readers.**
- Add one helper in supabase/functions/_shared. It parses `/object/public|sign/<bucket>/<path>`, decodes the bucket, and GETs `/storage/v1/object/authenticated/<bucket>/<path>` with the service key. It reads exactly the named bucket, with no cross-bucket fallback, because a fallback would hide a missed rewrite. It raises a clear error.
- Use the helper in:
  - redact-manifest-sheet (index.ts:146);
  - ocr-address-sheet-number (:167);
  - ocr-address-sheet-rows (:179);
  - measure-generated-page (:74), whose allow-list at :66-67 also accepts derm-docs.
- rpa-derm-queue drops and logs an item it cannot sign, instead of returning the raw URL (index.ts:166).
- Deploy one function at a time.
- **Gate:**
  - The deployed bodies contain the helper, and do not contain the bare-fetch needles `fetch(t.source_url)`, `fetch(r.image_url)`, `fetch(urls[i])` and `fetch(imageUrl)`. Each read-back has a control needle.
  - The helper returns 200 on a known rpa-evidence object and on a known 'GT - Visits Images' object (a name with spaces).
  - **Forced single calls, not cron status**, each writing its outcome row with 0 errors:
    - one redaction target;
    - both OCR functions in explicit mode, on one ticket with a GT page and one with a manifests page;
    - measure on one generated page.
  - Cron status proves nothing here. Jobs 10, 24, 29 and 43 each show 100% success over 7 days, because they only queue an HTTP call.

**4b. Page order stops depending on the bucket name.**
- derm.ticket_page_images orders its second loop by the full URL (`ORDER BY u`) and breaks ties in its first loop with `mode() WITHIN GROUP (ORDER BY image_url)` (pg_get_functiondef, 2026-09-27). 'derm-docs' sorts ahead of both old buckets. After Stage 6, a new page on an existing ticket would therefore jump ahead of older pages and move existing stamp pages.
- Change both keys to `regexp_replace(u,'^.*/object/public/[^/]+/','')`.
- **Gate:** ticket_page_images is identical for all 144 live tickets. Prove it first in a rolled-back transaction, then after the deploy.

**4c. get-derm-doc gains two safe paths.**
- A 'work_order' kind keyed only on the Field Portal public_id, never on client_code (public_id is 10 mixed-case characters on 2,864 of 2,864 visits). It reads customer.get_work_order server-side, so the receipt_doc_class gating is unchanged. It returns wwtp_receipt_url and fog_documents, signing items that are in a private bucket and passing public ones through.
- A staff path keyed on visit_id that reads derm.get_visit_report. This matters because get_work_order reads customer.work_orders while get_work_order_internal reads work_orders_all (verified). 21 visits have a receipt only in the internal view.
- Add derm-docs to the raw-path bucket list.
- **Gate:** for 3 visits chosen by query, the kind returns the same items as get_work_order. The staff path returns them for a work_orders_all-only visit.

**4d. Field Portal (Lovable).**
- The FOG card and the report page call the new kind only for URLs outside the buckets that stay public. manifests/redacted/* renders directly, as today.
- The WWTP card switches from kind 'manifest' to the new kind.
- The report page publishes expected and loaded evidence counts as a data attribute.
- Write it up in Building Apps/Field Portal docs/08-changelog.md.
- Then gate kind 'manifest' to a staff JWT or service_role, the same way as in 0.2.
- **Gate:**
  - On 3 visits chosen by query (a GT receipt, a manifests receipt, a Broward per-visit sheet), every evidence image returns 200.
  - An anonymous kind 'manifest' call returns 401.

**4e. DERM Tracker report and printed DERM report.**
- The interactive page uses the staff path. It must never call createSignedUrl: the pdf-service DERM router refuses any Supabase request other than a POST to get-derm-doc or a GET on /object/public/ or /object/sign/ (visit_report.py DERM router), so a client-side sign would fail the render.
- derm-visit-report replaces wwtp_receipt_url and the fog_documents URLs with signed URLs in the payload before it calls the pdf-service.
- Write it up in the DERM Tracker docs.

**4f. pdf-service.**
- Assert that the expected evidence count equals the number of img elements with naturalWidth > 0. Today it waits only on `i.complete`, which is true for failed loads (visit_report.py:963).
- Fail or flag the render, per Fred.
- W3 (upload_address_pdf) returns a signed URL, or the button is retired.
- Bump __version__.
- Prove the check fires once by rendering a 112-YA report (no send) with the kind forced to return an error.

**Gate for Stage 4 as a whole:**
- The Stage 1 reference renders reproduce their image counts on both targets.
- The outcome ledgers stay at baseline for 24 hours.
- Bundle walks from real routes (fp report route, derm /visits/8088) show the new kind, and no report chunk puts wwtp_receipt_url straight into an img src.

**Rollback:** per piece: the previous edge version, the saved function body, or the previous pdf-service tag. Use a Lovable restore only after checking that no other session's change is pending in that project.

**Reversible:** yes.

### Stage 5. Pilot on the test client 112-YA, including a real rollback

**Goal.** Prove copy, rewrite, every reader, the quarantine and a real rollback end to end on a sanctioned test client.

**Scope.** Computed by the group query, not by hand. Manifest 1941 is live and has 3 objects: fog.pdf in GT, and address_1.jpg and manifest_1.jpg in manifests. Of the 3 receipt_doc_class rows and 3 redacted docs, some belong to soft-deleted manifests 1939 and 1940. Card 2979 on ticket-111112 carries a witness that points at manifests/derm/1940/address_1.jpg (Attack 1 measurement). The group query decides whether that object joins the pilot. It is the one real example of the "referenced only by non-manifest columns" class. The soft-deleted manifest rows themselves are not rewritten (decision 5).

**Steps:**
1. Copy the objects and reconcile them.
2. Rehearse the rewrite in a transaction that ends in ROLLBACK, with `SET CONSTRAINTS ALL IMMEDIATE` before the checks so the deferred page-image guard fires.
3. Run the real rewrite (Appendix B3).
4. Exercise every reader:
   - get-derm-doc: address, manifest, the new kind, and the staff path;
   - FP visit and report pages;
   - DERM Tracker gallery, visit page and report page;
   - the Client App DERM link;
   - Stamp Studio display and ZIP export (toBlob returns a non-empty PNG);
   - pdf-service renders on both targets, with no send;
   - both OCR functions in explicit mode;
   - rpa-derm-queue, if a 112-YA item is queued;
   - one forced redaction regeneration (withdraw one 112-YA redacted row and let the sweep rebuild it from derm-docs), with Fred's in-the-moment OK.
5. Wait one sweep cycle (10 minutes), then rescan every census column for the old prefix.
6. Move the public originals into derm-quarantine and re-check the readers.
7. **Real rollback:** run the reverse generator (B4), move the originals back, and re-check the readers on public data.
8. Redo the forward steps.

**Gate:**
- Every reader returns 200 or writes its expected outcome row.
- After the quarantine, the old /object/public/ and /render/image/public/ URLs return 4xx within 2 minutes.
- The regenerated redacted doc exists and loads with 200.
- The OCR reads are stored under the derm-docs URL.
- The render image counts equal the pre-pilot renders.
- Rollback leaves 0 census values with the derm-docs prefix for these paths, and the originals are back with the same row id and eTag.
- The redo passes the same gate.
- Negative controls: /object/public/derm-docs returns 400, anon signing returns 4xx, and authenticated without a uid sees 0 rows.

**Soak.** 72 hours. Stage 6 may start once the reader checks pass, and the soak keeps running alongside it.

**Rollback:** B4 plus moving the originals back. The derm-docs copies are deleted only when no census value names them.

**Reversible:** yes.

### Stage 6. Point every writer at derm-docs and lock the public derm/ folders

**Goal.** New DERM files land only in derm-docs, so the pile stops growing before the bulk work.

**Actions:**
- **pdf-service.** Add a DERM_STORAGE_BUCKET setting, read only by upload_pdf, upload_address_pdf and upload_fdep_sheet_pdf (supabase_client.py:128-151, 200-224, 451-479). SUPABASE_STORAGE_BUCKET stays as it is, because it also serves download_object and upload_rotated_photo (:500-529); flipping it would break Admin Review photo rotation. Deploy with the default equal to today's bucket, verify that nothing changed, then set derm-docs on Railway.
- **DERM Tracker.** Change the 8 'manifests' literals to 'derm-docs': 4 upload sites, 2 getPublicUrl calls and 2 p_photo_bucket arguments. Publish, then walk the live bundle.
- **webhook-airtable.** Delete the dead DERM mirror (index.ts:452-505).
- **Restrictive policies.** After the Tracker publish, add RESTRICTIVE policies that deny authenticated INSERT and UPDATE where `foldername(name)[1]='derm'` on both public buckets. A browser tab loaded before the publish then fails loudly instead of writing publicly.
- **Watchdog.** Add one reason to an existing log_*_health function. Copy the whole body; never retype it. It flags:
  - any object in the public buckets named derm/% with created_at OR updated_at after cutover (an upsert keeps created_at);
  - any audit.logs write of a public derm/ prefix into a URL column after cutover;
  - any generated_visit_sheets row after cutover whose object does not exist (the silent best-effort FDEP store, app.py:701-709);
  - any live derm_manifests URL that resolves to no object or to a quarantine path (catches an SQL un-delete; audit.logs holds 5 such un-deletes);
  - the count of live derm_address and derm_manifest photo_links in public buckets (tracks the Fillout follow-on).
- **Positive-control writes on 112-YA:**
  - W5 upload page;
  - W6 edit modal;
  - W7 per-visit sheet;
  - W1 fog.pdf, if the generator is kept;
  - W2 FDEP, if 112-YA can produce one; otherwise the first natural one.

**Gate:**
- /health shows the new pdf-service version.
- Each control write created an object in derm-docs (with owner_id for app uploads) and stored the /object/public/derm-docs/ shape, or 'derm-docs' in the bucket column.
- Each control write is readable by its reader, and receipt_doc_class picked up the new URL through autoclassify.
- The Tracker bundle has 0 `storage.from("manifests")` upload sites and 8 'derm-docs' literals.
- Anon and staff INSERT under derm/ in the public buckets are refused.
- Over 7 days: 0 new or updated public derm/ objects, and derm-docs gains files at roughly the normal rate. Zero new files there is itself a failure.

**Rollback:** set the pdf-service setting back, restore the Tracker version, and drop the restrictive policies. Files already in derm-docs stay valid, because every reader now handles any bucket.

**Reversible:** yes.

### Stage 7. Move the files that no live manifest uses (about 685)

**Goal.** Close the rest of the population that needs no link rewrite.

**Rule.** An object qualifies if no live derm_manifests row references it and no other column does. That is about 657 unreferenced files plus 28 referenced only by soft-deleted manifests (25 of them are fog.pdf). The soft-deleted rows keep dead links. They are recorded as a known set, and the Stage 6 watchdog catches any un-delete.

**Mechanics.** Same as Stage 3 (move). If the destination name is already taken by a newer file with a different eTag, move the original into quarantine and record it as superseded.

**Gate:**
- The Stage 3 gates.
- ticket_page_images for the affected folders is unchanged, which proves the files were truly unused.
- No moved path gained a reference between the census and the move.

**Rollback:** move the files back using the ledger.

**Reversible:** yes.

### Stage 8. Real canary: three groups that cover every mechanism

**Goal.** Exercise the paths the test client cannot: 112-YA has no multi-client ticket, no Broward sheet, no FDEP sheet, no OCR ledger and no generated sheet.

**Choose by query:**
- one completed multi-client ticket with a generated sheet that fills the most link columns (stamps with witness, address extras, scan reads, OCR and measure rows, page_rule_scans, redacted docs, receipts);
- one Broward FDEP sheet;
- one Broward per-visit sheet.

**Mechanics.** The full Stage 5 cycle, including the bucket columns and the ledgers, then a 48-hour soak.

**Gate:**
- The Stage 5 gate, for every client on the ticket.
- measure-generated-page returns 200, not the allow-list 400.
- The DERM Tracker FDEP and per-visit viewers sign with 200.
- rpa-derm-queue output, if queued, carries signed URLs that return 200.
- The email-readiness statuses and both OCR and measure backlogs are unchanged.
- Stamp Studio shows every stamp on the right page.

**Rollback:** B4 for this group, then move its originals back.

**Reversible:** yes.

### Stage 9. Referenced waves, ordered by harm (about 1,240 files)

**Order of waves:**
1. **fog.pdf** (about 785 live). One column, and no reader compares it by string. If Fred confirms fog.pdf is dead output, each batch is a move plus a fog_manifest_url rewrite in the same batch.
2. **Address-sheet groups**, per ticket: derm_address_url and its extras, address_row_map, scan reads, the OCR and measure ledgers, page_rule_scans, and redacted source_url.
3. **The Broward bucket columns**, plus the 4 objects referenced only by non-manifest rows.
4. **WWTP receipts last:** derm_manifest_url and receipt_doc_class in the same transaction, with receipt_doc_class first.

A path referenced from two waves moves with the earlier one, and both sets of columns are rewritten in that transaction.

**Batching rules:**
- About 100 objects per batch, closed under whole groups, one batch at a time.
- Off-hours ET, and only when fn_blackout_targets(1000) is empty.
- Writers quiet during each copy: the fog cron paused. After the copy, check audit.logs for any write to the batch's manifests during the window. Copy is not no-clobber against a concurrent writer (object.ts:407-431).
- Skip any group that the GDO bot leased in the last 4 hours. Its signed URLs last 4 hours (rpa-derm-queue/index.ts:36).
- 48 hours between waves.

**Quarantine step, per batch:**
1. Wait one sweep cycle after the commit.
2. Rescan every census column for the old prefix, before and after the move.
3. Move a source only if its current eTag still equals the copy's eTag.
4. Probe the old /object/public/ and /render/image/public/ URLs, and purge any path that still serves.

**Gate per batch:**
- 100% per-object reconciliation.
- The in-transaction checks (B3).
- Each column's counts moved by exactly the batch's values.
- 0 values in the batch still carry the old prefix.
- A reader sample (3 tickets, the full reader list) returns 200.
- A sample of old URLs returns 4xx.
- The outcome ledgers are at baseline.

**Gate per wave:** a full-fleet ticket_page_images comparison against the baseline, ignoring only the bucket name.

**Rollback:** per batch, B4 for that batch, then move its originals back. Earlier batches stay valid on their own.

**Reversible:** yes.

### Stage 10. Final audit and long soak (leak closed, still reversible)

**Final checks:**
- A name-level set comparison, not a count: inventory plus post-cutover writes equals derm-docs plus quarantine.
- 0 derm/ objects in either public bucket.
- Every live link resolves to an object.
- The soft-deleted dead links match the recorded set.
- A status-only enumeration sample over all 24 old patterns returns 4xx, on both routes.
- Anonymous kind 'fog', 'manifest' and 'address' calls return 401.
- The watchdog is quiet.

**Soak.** Let a full month boundary pass: the LWT monthly report, the GDO filings and the city emails. There must be no storage-caused failure in the edge logs, sync_log, derm_email_sends reasons or rpa results.

**Close-out.** Update Supabase CLAUDE.md, the memory note and the app docs. Retire docs/migrations/2026-07-29f_storage_privatise_STAGED.sql with a pointer to the new migrations.

**Rollback:** any object can still move back from quarantine, and any link can be restored with B4.

**Reversible:** yes.

### Stage 11. Optional deletion of the quarantine (irreversible)

**Goal.** Only if Fred wants it. Keeping about 1.4 GB costs a few cents a month.

**Actions:**
- Confirm that every quarantined object has a derm-docs twin with the same eTag, or is a recorded superseded file.
- Confirm that the archive matches for 100% of files.
- Delete through the Storage API only, in batches of 100, with a ledger. Never use DELETE FROM storage.objects; the platform refuses it anyway (trigger protect_objects_delete).

**Gate:** the quarantine is empty (or holds the set Fred chose to keep), derm-docs is untouched, and every reader still returns 200.

**Rollback:** none in storage. Restore from the archive by upload.

**Reversible:** no.

## 4. What staff and customers notice

| Stage | Staff | Customers (Field Portal) and outsiders |
|---|---|---|
| 0 | Nothing, except that a DERM Tracker tab loaded before the publish must be reloaded before its next Generate. If fog.pdf is paused, new manifests have no fog.pdf, which nothing displays. | Outsiders can no longer render sheets, sign fog.pdf, or upload under derm/. Customers see no change. |
| 1 to 3 | Nothing. | Nothing. Old links to files of deleted manifests stop working. |
| 4 | Report pages look the same. A report whose evidence image fails now fails or is flagged instead of printing with a hole. | Receipts and Broward sheets load through a signing call (slightly slower). Nothing else changes. |
| 5 | Only the 112-YA test client. | Nothing. |
| 6 | Uploads and generated PDFs go to the private bucket. Tell staff to reload open DERM Tracker tabs once. A stale tab gets an upload error instead of writing publicly. | Nothing. |
| 7 | Nothing. | Nothing. |
| 8 and 9 | Nothing visible. Rewrites run off-hours. | Raw receipt links a customer saved from an old page stop working. The pages themselves keep working. |
| 10 and 11 | Nothing. | Nothing. |

## 5. Decisions only Fred can make

1. **fog.pdf.** Is fog.pdf still used for anything? If not, may we pause its hourly generator in week 1? It makes 58% of new public files, and nothing in the apps reads it.
2. **Scope.** Move all of derm/ (recommended), or only the address sheets? Address-only does not remove the harm, because fog.pdf rebuilds the map.
3. **Receipts and Broward per-visit sheets.** Move them and have the pages sign them (recommended), or leave them public?
4. **Follow-on scope.** Handle these as a separate follow-on (recommended), or leave them public?
   - the 1,123 raw DERM photos under airtable/derm/;
   - the 432 inspection DERM photos under airtable/inspection/;
   - new Fillout inspection DERM photos, which have their own writer since 2026-09-23, with 0 files so far.
5. **Soft-deleted manifests.** Should their rows keep dead links (recommended)? Row 284 cannot be updated at all.
6. **Held GDO filings.** The link rewrite bumps updated_at, which would re-release 3 held GDO filings to the bot. Pause the updated_at triggers inside each rewrite transaction (recommended), or accept the re-attempts and tell Jonathan?
7. **Failed evidence image.** When a Service Report evidence image fails to load, should the render fail (the send waits) or be flagged?
8. **Generate DERM address button.** Keep it with a signed link, or retire it? One file has ever been made with it.
9. **Archive.** Where does the encrypted archive of about 1.4 GB of client paperwork live, and for how long?
10. **Soak lengths.** Are these right: 72 hours for the pilot, 7 days after the writer switch, 48 hours between waves, and 30 days at the end?
11. **Stage 11.** Should the quarantine ever be deleted?
12. **Old links.** Is it acceptable that old links stop working: saved receipt links, DERM "Open PDF" tabs, derm.audit_pack output, FP sandbox rows, and links pasted into Jobber notes?
13. **In-the-moment approvals.** Will you approve, when asked, one forced 112-YA redaction regeneration and any test send to a staff address?
14. **Orphans.** Keep the 1,097 orphan files in derm-docs (default), or archive and delete them later?

## 6. Known limits (what this does NOT fix)

**What stays exposed, or was exposed already:**
- Anyone who already downloaded the numbered paths keeps what they took.
- Referenced files stay public until their wave's quarantine step, which could be about 3 weeks away. The orphans and the files no live manifest uses (58%) close within days of starting.
- manifests/redacted/*, gdo-permits and visits/* stay public, by earlier decisions. The redacted names end in a 10-hex fingerprint (775 of 775), so they cannot be enumerated.
- The follow-on files in decision 4 stay public until a separate design exists. public.photos has no bucket column (storage_path, thumbnail_path and original_storage_path only), so moving them needs its own reader work.
- Storage versioning cannot serve as a safety net. The capability is off and the platform code is not merged. The archive and the quarantine are the only undo.

**What the checks cannot see:**
- The census cannot see links outside the database: links pasted into Jobber notes or emails, bookmarks, or signed URLs the GDO bot has cached (4 hours). The quarantine keeps those files recoverable.
- A reader missed by both the census and the bundle scans would first fail at a quarantine step. The reversible quarantine and the per-wave soak are the net, not proof that no such reader exists.
- The CDN's 60-second invalidation after a move is Supabase's documented behaviour, not something measured here. The status probe after each move is the real check.
- A signed URL issued before a move stays valid until the file moves. Nothing else revokes it.

**Side effects the rewrite leaves:**
- derm-docs copies of referenced files get a new owner_id and created_at. The originals in quarantine and the archive keep the old values.
- The rewrite writes audit rows on derm_manifests and address_row_map. The unaudited tables (receipt_doc_class, the OCR and measure ledgers, redacted_manifest_docs, page_rule_scans) can be restored only from each batch's backup file.
- The row-OCR ledger keys on an md5 of the page URL list (derm.row_ocr_attempts.image_fingerprint, 15 rows), so the rewrite re-arms row OCR for the tickets it touches. That costs a few vision calls. It is accepted, not prevented.

## Appendix A. The inventory the gates check (measured 2026-09-27)

### A1. Objects

- **By bucket:** 'GT - Visits Images'/derm has 2,813 objects (1,309,348,083 B). 'manifests'/derm has 209 (78,759,489 B).
- **Paths:** there are 0 path collisions between the two buckets. The largest object is 3,526,912 B. All eTags are single-part MD5-shaped, and 499 eTags are shared by 2 or more paths, so reconciliation keys on (bucket, name) and never on eTag alone.
- **By class:** address sheets 1,187; receipt / manifest images 1,005; fog.pdf 811; Broward FDEP 19.
- **By reference:**

| Class | Count | Handled in |
|---|---|---|
| Orphans (numeric folder, no manifest row) | 1,097 | Stage 3 |
| Other unreferenced | 657 | Stage 7 |
| Referenced only by soft-deleted manifests | 28 | Stage 7 |
| Referenced only by non-manifest columns | 4 | Stage 9 (wave 3) |
| Referenced by live rows | about 1,236 | Stages 5, 8, 9 |

- **Growth:** 198 new objects in 30 days (fog.pdf 115, DERM Tracker uploads 44, per-visit 20, FDEP 19). 457 of the 811 fog.pdf files were overwritten in place.

### A2. Link values into the move set (all rows)

| Column | Values | Compared by | Audited |
|---|---|---|---|
| public.derm_manifests.derm_address_url | 785 | triggers, ticket_page_images | yes |
| public.derm_manifests.derm_address_extra_urls[] | 500 | same (rebuild WITH ORDINALITY) | yes |
| public.derm_manifests.derm_manifest_url | 804 | = receipt_doc_class.url (work_orders join) | yes |
| public.derm_manifests.fog_manifest_url | 810 | nothing (passthrough only) | yes |
| derm.address_row_map.image_url | 751 (+72 'pending') | injective guard, mode() in ticket_page_images | yes |
| derm.address_row_map.stamp_image_url | 770 | array_position in fn_reconcile_stamp_pages | yes |
| derm.redacted_manifest_docs.source_url | 745 | _img_etag fingerprint | no |
| derm.receipt_doc_class.url | 150 | join key | no |
| derm.page_rule_scans.source_url | 219 | source_etag = _img_etag (219/219) | no |
| derm.address_sheet_scan_reads.image_url | 92 | OCR backlog equality | no |
| derm.sheet_number_ocr_attempts.image_url | 12 | ledger key | no |
| derm.generated_measure_attempts.image_url | 5 | IS DISTINCT FROM resets budget | no |
| derm.manifest_visit_sheets.photo_bucket/photo_path | 20 | fn_fog_documents builds a public URL | yes |
| derm.generated_visit_sheets.pdf_bucket/pdf_path | 21 (3 dangling) | Tracker signs by bucket + path | yes |

**Total:** 5,643 URL strings plus 41 bucket/path rows, which is 5,684. The July plan counted about 3,331 values, and its staged UPDATE covered 3 columns.

**Latent columns (0 values today, but writers exist, so they are rewritten and counted):**
- derm_manifests.derm_manifest_extra_urls (upload-*.js; public.edit_manifest);
- derm.address_sheets.pdf_bucket/pdf_path (63 rows, all 'preview');
- derm.manifest_visit_sheets.pdf_bucket/pdf_path (0).

**Hash dependent:** derm.row_ocr_attempts.image_fingerprint, which is md5 of the joined ticket_page_images (15 rows).

**Not links, excluded:** ops.pgss_snapshot_20260903_medium.query (7 texts), webhook_events_log.payload (0 under derm/), audit.logs, app-assets/derm/no-image-available.jpg.

### A3. Writers

| Id | Writer | Bucket / path | Volume | Repoint |
|---|---|---|---|---|
| W1 | pdf-service /generate/fog-manifest, hourly GitHub cron | GT derm/<id>/fog.pdf, upsert | 115 in 30 d | DERM_STORAGE_BUCKET, or pause (0.5) |
| W2 | pdf-service Broward branch of generate-derm-address-preview | GT derm/broward-sheets/<n>/fdep_<ts>.pdf | 19 | DERM_STORAGE_BUCKET, backfill pdf_bucket |
| W3 | pdf-service /generate/derm-address (Tracker button) | GT derm/sheets/<n>/address_<ts>.pdf | 1 ever | setting plus signed URL, or retire |
| W4a | GitHub "Mirror DERM PDFs to Supabase Storage" | GT derm/<id>/{manifest,address}.<ext> | 0 since 2026-06-30 | disable (0.4) |
| W4b | webhook-airtable mirrorAttachmentToStorage | GT derm/... | unreachable since 2026-07-21 | delete (Stage 6) |
| W5 | DERM Tracker upload page | manifests derm/<id>/{manifest,address}_<n>.<ext> | 44 in 30 d | 8 literals (Stage 6) |
| W6 | DERM Tracker edit-manifest modal | manifests derm/<id>/..._<ts>-<rand>.<ext> | 0 since 2026-07-03, code live | same |
| W7 | DERM Tracker per-visit sheet | manifests derm/<id>/address_visit_<visit>.<ext> | 20 | same, backfill photo_bucket |
| W8 | fillout-inspection plus inbound-file-drain (derm_address, derm_manifest roles) | GT fillout/inspection/<id>/derm_*_<n>.jpg | 0 so far, live since 2026-09-23 | follow-on (decision 4), watchdog counts it |

- **Evidence for W8:** fillout-inspection/index.ts:31 and :102-103; sync.inbound_file_queue has 0 derm roles so far.
- **Confirmed non-writers:** Stamp Studio, Admin Review, Client App, Field Portal, Calendar, Dump, Planner, Reviews and Hub (bundle crawl with positive control). No pg_cron job and no DB function writes under derm/.

### A4. Readers and how each breaks today

| Reader | How it reads | Breaks at | Fixed in |
|---|---|---|---|
| redact-manifest-sheet v22 | bare fetch (index.ts:146) | rewrite | 4a |
| ocr-address-sheet-number v11 | bare fetch (:167), plus statement trigger | rewrite | 4a |
| ocr-address-sheet-rows v11 | bare fetch (:179) | rewrite | 4a |
| measure-generated-page v3 | allow-list /object/public/manifests/ (:66-67), bare fetch (:74) | rewrite | 4a |
| FP visit page FOG card | raw fog_documents url (20 Broward work orders) | rewrite | 4d |
| FP visit page WWTP card | get-derm-doc kind manifest (client_code) | survives, but open to anyone | 4d, then gate |
| FP report page, printed by pdf-service, attached by send-derm-email v61 and send-visit-photos-email v38 | raw img src for wwtp_receipt_url and fog_documents | rewrite, silently | 4d, 4f |
| DERM Tracker report page and derm-visit-report v7 | raw img src; reads get_work_order_internal | rewrite | 4e |
| DERM Tracker galleries, lightbox, edit modal | get-derm-doc address and manifest | survives if copies are complete | none needed |
| DERM Tracker FDEP and per-visit viewers | createSignedUrl(bucket, path) with session | survives if the bucket columns are rewritten | B3 |
| DERM Tracker "Open PDF" (W3) | window.open of a public URL | writer switch | 4f |
| Stamp Studio | parses the URL, signs with session; writes page_rule_scans.source_url unsigned | survives; can write old URLs back | quarantine rescan |
| Client App | parses the URL, signs with session | survives; failure shows as endless loading | none |
| get-derm-doc v23 | signs the bucket named in the URL; raw list lacks derm-docs | survives; fog/manifest open to anon | 0.2, 4c |
| rpa-derm-queue v25 | signs 4 h; returns the raw URL on failure (:166) | fails open | 4a |
| derm._img_etag and ticket_page_images | parse '/public/', eTag by (bucket, name); order by full URL | missing copy shifts pages; bucket changes order | B3 checks, 4b |
| derm.fn_fog_documents arm (b) | builds a public URL from photo_bucket | rewrite | 4c, 4d |
| customer.work_orders / get_work_order (anon) | wwtp_receipt_url via string join | if the join key is split | B3 order |

### A5. Triggers the rewrite fires (public.derm_manifests, pg_trigger 2026-09-27)

- **BEFORE, on any UPDATE:**
  - trg_aa_normalize_ticket_numbers;
  - trg_derm_inherit_ticket_fields (this is what would abort the staged July UPDATE with 23514 on soft-deleted row 284);
  - trg_zz_ticket_matches_facility;
  - trg_derm_manifests_updated_at (set_updated_at). This feeds v_derm_portal_fields.updated_at = GREATEST(v.updated_at, linked_at), and v_derm_portal_queue gate 3 tests `s.created_at > GREATEST(f.updated_at, requeue)`.
- **AFTER:**
  - trg_zc_autoclassify_receipt (OF derm_manifest_url);
  - trg_zv_reconcile_stamp_pages (OF derm_address_url, derm_address_extra_urls, deleted_at);
  - trg_zx_generated_sheet_return_review (OF derm_address_url);
  - zzz_request_sheet_number_ocr (statement);
  - audit_derm_manifests;
  - zzz_broadcast_inval.
- **On derm.address_row_map:**
  - trg_zz_page_image_injective (DEFERRABLE INITIALLY DEFERRED);
  - its updated_at trigger (re-arms the measure budget via cards_updated_at);
  - the witness trigger (fn_stamp_witness).

## Appendix B. Tool rules

**B1. Copy and move tool.**
- Uses the REST endpoints only. Keeps a resumable ledger (bucket, name, id, size, eTag, mimetype, owner, created_at, before and after). At most 5 requests in flight.
- An object is **done** only when its source row is absent AND the destination eTag equals the ledger eTag. If the destination has the same eTag but the source still exists, the source goes to quarantine.
- A 409 means "check it", not "done".
- After any error, check the source bytes before retrying.

**B2. Status probe.** Status and size only, never content. It includes a known-200 control and a known-400 control in every run, and it probes both /object/public/ and /render/image/public/.

**B3. Rewrite transaction.** Generated per batch.

Before the transaction: write a JSON backup of every (table, pk, column, old, new).

Inside one transaction:
1. With Fred's OK (decision 6), `ALTER TABLE ... DISABLE TRIGGER` the two updated_at triggers. Re-enable them before COMMIT, and assert that they are re-enabled.
2. Rewrite, in this order:
   1. derm.receipt_doc_class.url;
   2. derm.address_row_map image_url and stamp_image_url, in one statement;
   3. redacted_manifest_docs.source_url and page_rule_scans.source_url;
   4. the three OCR and measure ledgers;
   5. the bucket columns;
   6. ONE UPDATE on public.derm_manifests (live rows only) that sets all five URL columns, with the arrays rebuilt WITH ORDINALITY. The generator asserts that the SET list holds only URL columns.
3. Swap the prefix by exact string comparison (`left(url,n) = old_prefix`), keeping the bucket encoded ('GT%20-%20Visits%20Images').
4. `SET CONSTRAINTS ALL IMMEDIATE`.
5. Checks. Any failure RAISEs and aborts the transaction:
   - derm._img_etag(new URL) equals the CURRENT source eTag for every URL;
   - ticket_page_images is identical apart from the bucket, for every ticket in the batch;
   - stamp_sheet_status (completed, reopened_at) is unchanged;
   - 0 address_row_map rows have a changed stamp_page;
   - these are unchanged: v_stamp_placement_health, fn_blackout_targets(1000), v_sheet_number_ocr_backlog, v_generated_measure_backlog, v_derm_portal_queue, and the v_city_email_candidates histogram;
   - the receipt_doc_class count is unchanged, with 0 new 'auto' notes;
   - wwtp_receipt_url counts in both views are unchanged;
   - an md5 of each row's non-URL columns (excluding updated_at) is unchanged;
   - each column's counts moved by exactly the batch's values.

**B4. Rollback generator.**
- It is the same prefix swap in reverse, applied by value across every census column for the batch's paths. This also catches rows written after the forward step.
- It is compare-and-swap: a value changes only where it still equals the forward value, and anything else is reported.
- It runs the same checks as B3.
- Never delete a derm-docs copy while any census value names it.
- **Gate:** 0 census values with the derm-docs prefix for the batch.

## Appendix C. Review findings rejected or changed

- **Attack 3, archive finding: partly rejected.** The archive is kept, but only just before the first move (Stage 3), not deferred to Stage 11. A MOVE deletes the source bytes, and that delete is queued before COMMIT (object.ts:571), so the archive is the net against a platform defect. The MD5-vs-eTag comparison is kept only as the download's own integrity check, not as a plan gate. Accepted from the same finding: eTag = MD5 is not what the fingerprints depend on, and the second-pass re-hash is dropped.
- **Attack 3, Fillout finding: partly rejected.** The scope gap and the watchdog are accepted. Repointing the Fillout DERM roles inside the writer stage is rejected, because public.photos has no bucket column, so every photo reader assumes GT. That needs its own design.
- **Attack 2, measure re-arm: not adopted as a standing re-arm.** The updated_at trigger pause (decision 6) removes the cause, and the in-transaction check makes any residue visible.
- **Plan bullet "pdf-service must allow get-derm-doc and /object/sign/ during print": removed.** The DERM router already allows both (visit_report.py DERM router), and the FP target has no router.
- **Investigation 4's cross-bucket fallback helper, and its MOVE for referenced files: rejected.** A fallback hides a missed rewrite. A move leaves live links dangling between the move and the rewrite, and it cannot be rehearsed.
- **July note, "keep the anon INSERT policies (app upload paths)": rejected by measurement.** There have been no anon writes since 2026-08-10, and the Tracker uploads as a signed-in user.
- **July note, "gating kind manifest would break the FP WWTP card": superseded.** The card moves to the public_id kind first (4d), and the kind is gated after that.
