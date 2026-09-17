# Images on "Reason for this change" (Client App)

- **Status:** ✅ **SHIPPED 2026-09-16** (Fred: "do not send me the plan and wait for my response, do it").
  DB `2026-09-16_2030_client_reason_photos` (`b4caf66`); `save-client-job` v39 `PROOF_MAX` 5 (`a7f089c`);
  Client App pass 1 live as `index-Do6FE87Y` / `clients._id-DcJtni7o`, pass 2 as `index-e2ocD1IZ` /
  `clients._id-CZd64TLg`; smoke-tested end to end on 112-YA (Building Apps `ccfbe2e`, Client App rule 2q).
- **Asked for by:** Fred, voice note 2026-09-16. Transcript in the session scratchpad; the operative
  sentences are quoted where they bind.
- **Scope owner:** Supabase (bucket, migration, RPCs, view) + Client App (Lovable `dbf2133c-…`, docs).

## 1. Why, in Fred's words

> "when we edit a client … the status or something that usually requires a reason … Besides accepting
> a text of why the reason of that change, we should also accept some images."
>
> "I want a maximum amount of five images per reason … they have to be images. They have to be PNG,
> JPG, and whatever you think it could be … No videos, no files, nothing. Images."
>
> "The image will be like a small box in there where you can add it, and when you click on it, it's
> gonna do a preview. And also I need to be able to replace the image. I also need to be able to delete
> the image and to add more images."
>
> "first to go to the database, read the architecture, know our rules … set up a new architecture …
> for the photos for the reasons … have a really good design … smoke test it."

## 2. Where the app asks for a reason (audited 2026-09-16, six readers, two adversaries)

The live bundle was walked to closure (12 chunks, 1,275,114 bytes). It contains **exactly three**
operator-typed reason fields:

| # | site | write path | ledger | images today |
|---|---|---|---|---|
| 1 | **Edit client** dialog, shown when Status differs (`edit-client-reason`, required, 500) | ACTIVE/RECURRING: `client.update_client_status(id, status, reason)` from the browser. INACTIVE: edge fn `archive-client {action:'archive', reason}` which calls the same RPC as the caller | `public.client_status_changes` | none |
| 2 | **Archive client / Reactivate client** dialog from the client header pill (`archive-client-reason`, required, 500) | edge fn `archive-client {action:'archive'\|'unarchive', reason}` → same RPC | `public.client_status_changes` | none |
| 3 | **Edit job** dialog, Service Agreement frequency change (`job-frequency-reason`, text OR image) | edge fn `save-client-job {patch.frequency_reason, frequency_proof[]}` | `public.job_frequency_changes` + `photo_links(entity_type='job_frequency_change', role='approval_proof')`, bucket `approval-proof` | **3**, base64 through the edge fn, written as service_role after Jobber confirms |

Four job-action dialogs write a fixed machine reason with no field (create/reopen SA, close last SA,
close SC) and `unarchive-client` takes no reason from the app: not capture sites. Everything else
named `reason` in the estate is derived or machine-written (45 columns, 17 functions, all classified
in the audit files).

**And the app has no client-level history surface.** `client_status_changes` is never read by any
chunk (the only Activity modal is job-scoped), so a status reason written today has nowhere to be shown
back. The photos need a home after the dialog closes; that is section 5.

## 3. The rules this design is bound by

- **ADR 009**: "No new per-entity photo tables … An image is a `photos` row plus a polymorphic
  `photo_links` row." The 2026-08-19 architecture audit re-affirmed it ("a dedicated `proof_images`
  table: deliberately NOT recommended"). ⇒ **No new table.** The new architecture is the layer around
  the existing pair: a bucket with the right posture, a link kind, two RPCs, a view, guards.
- **2026-08-19 audit, the core defect**: a `photo_links` row for a proof was forgeable from a browser
  because `authenticated` holds INSERT and the policy only asked `auth.uid()`. ⇒ **The browser never
  writes `photos` or `photo_links` for a reason photo.** A SECURITY DEFINER RPC does, after validating
  the object, the target, the cap and the caller; and the authenticated INSERT policy on `photo_links`
  refuses the new kind exactly as it refuses `approval_proof`.
- **2026-08-19 audit, "Remove removes nothing"**: the storage object survived a remove and was still
  fetchable. ⇒ Remove soft-deletes the link (audited, recoverable metadata) **and the object is
  deleted**, through a DELETE policy that only permits an object nothing live points at.
- **Rule 8**: `photo_links` is audited (old_row on every soft-delete). `photos` is not, and this
  migration does not change that (it is a shared table; opting it in is its own decision). Stated in
  the migration header.
- **CLAUDE.md, `CREATE OR REPLACE`**: the one live function this touches (`client.update_client_status`,
  3-arg) is spliced from `pg_get_functiondef`, md5-pinned, two lines added.
- **Client App CLAUDE.md**: signed-URL helper takes the bucket explicitly; the lightbox portal needs
  `pointerEvents:'auto'`; deploy order for an additive change is server first.

## 4. The architecture

### 4.1 Storage: private bucket `reason-photos`

| setting | value |
|---|---|
| `public` | `false` (a reason image can be a WhatsApp screenshot: names, numbers, pricing) |
| `file_size_limit` | 5,242,880 (the client re-encodes to JPEG ≤ 1600px, ≤ 2 MB; the bucket is the backstop) |
| `allowed_mime_types` | `image/jpeg`, `image/png`, `image/webp` |
| path | `client-app/<entity_type>/<entity_id>/<uuid>.<ext>` — no client name, no email, not guessable |

Policies on `storage.objects`, all `TO authenticated`, all scoped to this bucket:

| policy | rule |
|---|---|
| `reason_photos_staff_read` | SELECT: `auth.uid() IS NOT NULL` (so the app can sign a URL) |
| `reason_photos_staff_insert` | INSERT: `client.fn_reason_photo_path_ok(name)` — the path names an **existing** reason record in the whitelist, in the required shape. **No object can exist for a change that did not happen**, which is the invariant the `approval-proof` bucket gets from being service-role-only, achieved here without an edge function. |
| `reason_photos_staff_delete` | DELETE: `client.fn_reason_photo_object_removable(name)` — no live `reason_photo` link points at the path. An attached image cannot be deleted from under its record; a removed or never-attached (orphan) object can be cleaned up. |

No UPDATE policy: replace is remove + upload + attach, so every object is immutable once written.

Why direct upload and not base64 through an edge function (the frequency path): a status change is a
DB-only write, so nothing has to be confirmed upstream before the object may exist; five images are
up to ~13 MB of JSON when base64'd into one request; per-image upload gives per-tile progress and
retry; and the estate's idiom for a DB-only Client App write is a `client.*` RPC. The frequency path
keeps its edge-fn upload because its object must not exist until Jobber has confirmed the cadence
(section 6).

### 4.2 The link kind

- `photo_links.entity_type = 'client_status_change'` (added to `photo_links_entity_type_chk`),
  `role = 'reason_photo'`, `entity_id → public.client_status_changes.id`.
- `fn_photo_link_target_exists` gains the branch (the dangling-link class the 2026-08-19 audit named).
- The authenticated INSERT policy on `photo_links` additionally refuses
  `entity_type = 'client_status_change'` and `role = 'reason_photo'`.
- `photos.source = 'client_app_upload'` (the value the frequency proofs already use);
  `photo_links.caption` = the uploader's GoTrue email (the estate's documented author convention);
  `photos.uploaded_by_employee_id` resolved from `employees.email` when a row matches, else NULL.

### 4.3 RPCs (schema `client`, SECURITY DEFINER, `search_path = ''`, EXECUTE to `authenticated` only)

`client.attach_reason_photo(p_entity_type text, p_entity_id bigint, p_storage_path text,
p_file_name text DEFAULT NULL, p_width_px int DEFAULT NULL, p_height_px int DEFAULT NULL) → jsonb`

1. staff gate (the same `auth.uid()` + `auth.jwt()->>'email'` domain check every `client.*` RPC uses);
2. `p_entity_type` in the whitelist and the target row exists;
3. `p_storage_path` has the shape `client-app/<entity_type>/<entity_id>/<file>` **for this** entity;
4. `pg_advisory_xact_lock` on the (entity_type, entity_id) so two concurrent attaches cannot both pass
   the cap;
5. cap: live `reason_photo` links for the target `< 5`, else a plain-language refusal;
6. the object exists in `storage.objects` for bucket `reason-photos`, uploaded by the caller
   (`owner_id = auth.uid()`), `metadata->>'mimetype'` is `image/*`, size is read from the object's
   metadata (server truth, never the client's claim);
7. inserts `photos` + `photo_links`; returns the link as the view below renders it.

`client.remove_reason_photo(p_link_id bigint, p_reason text DEFAULT NULL) → jsonb`

1. staff gate; 2. the link is a live `reason_photo`; 3. soft-delete (`deleted_at`, `deleted_reason`,
`deleted_by` via the existing stamper; `audit.logs` captures `old_row`); returns `{link_id, bucket,
storage_path, remaining}` so the app can then delete the object through the storage API (a DB-side
`DELETE FROM storage.objects` does not remove the file from the store; the API does).

Messages follow the 2026-09-14 rule: the MESSAGE is a sentence for the operator, codes go to DETAIL.

### 4.4 Read: `client.reason_photos` (view, SELECT to `authenticated`)

One row per live reason photo: `link_id, entity_type, entity_id, bucket, storage_path, file_name,
content_type, size_bytes, width_px, height_px, uploaded_by, uploaded_at`. **`bucket` is a column** so
no consumer can sign against the wrong bucket (the trap the Client App CLAUDE.md records).
`client.status_changes` gains an appended `photo_count`.

### 4.5 `client.update_client_status` returns `status_change_id`

Two lines: `insert … returning id into v_change_id` and `'status_change_id', v_change_id` in the
return object (`null` on the no-op branch). `archive-client` already returns the RPC result verbatim
as `status_write.result`, so the app reads the id on both paths with no edge-function change.

## 5. The app (Lovable, three passes, each verified in the published bundle)

- **One component, `ReasonImages`**, used by all three reason sites and the history surface: a row of
  64px tiles; a dashed "Add image" tile while under 5 (click or drop; `accept="image/*"`, multiple);
  click a tile → the existing portal lightbox (prev/next, Escape) with **Replace** and **Remove**
  actions; a small × on the tile; "n of 5"; images are canvas re-encoded to JPEG ≤ 1600px (strips
  EXIF; a phone screenshot carries GPS), refused over 2 MB after re-encode, refused if not decodable
  as an image ("… is not an image").
- **Edit client + Archive/Reactivate dialogs**: staged tiles under the reason; on Save, after the RPC
  or edge fn returns `status_change_id`, each image is uploaded then attached, with progress; a failed
  image is reported by name ("2 of 3 images attached; retry from Status history") and the change stands.
- **Status history** (new): a "Status history" action on the client header opening a modal listing
  `client.status_changes` newest first (old → new, when, who, reason, tiles) where images can be
  previewed, replaced, removed and added up to 5, through the same RPCs.
- **Frequency change**: same component, cap 5 (server `PROOF_MAX` 3 → 5 first).

## 6. Deliberately not done here

- **Unifying the frequency proofs onto the new bucket/RPCs.** Their objects live in `approval-proof`,
  `photos.storage_path` does not carry the bucket, and the read tiles pick the bucket by entity kind.
  Moving them means moving 13 objects and rewriting a Fred-verified path. Recorded as the next step.
- **Auditing `public.photos`** (rule 8, shared table): its own decision.
- **Server-side EXIF stripping**: the browser re-encode remains the control, as on the frequency path.

## 7. Verification plan

Migration VERIFY inside the transaction: bucket private (with a public bucket as the control); CHECK
two-sided; policy set exact (read/insert/delete, no update); `SET LOCAL ROLE authenticated` with a
simulated JWT: the path function accepts a good path and refuses a bad kind / missing record / wrong
shape; the attach RPC refuses a foreign path, a missing object, a sixth image; a browser-shaped
`INSERT INTO photo_links` for the new kind is refused by policy; remove soft-deletes and `audit.logs`
holds `old_row`; the spliced RPC's md5 matches the live one before splicing and the noop branch returns
`status_change_id: null`. Then a live smoke on the sanctioned test client 112-YA through the published
app, with the delivered tiles opened by eye.
