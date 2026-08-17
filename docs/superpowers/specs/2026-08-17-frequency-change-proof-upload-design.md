# Approval-proof image upload for job frequency changes

- **Status:** Design approved 2026-08-17 (Fred). Not implemented.
- **Asked for by:** Yannick, [Slack](https://unclogme.slack.com/archives/C0BD3VDPB9S/p1786979623871639)
- **Scope owner:** Client App (UI) + Supabase (bucket, migration, edge fn)

## 1. Why

Yannick, on the Client App's frequency-change reason field:

> *"in red its not about putting a few words its about proof that it was approved, so we need the slack
> link OR a screenshot of whatsapp (so you need to be able to upload the pic)"*

Fred's clarification, which defines the actual requirement:

> *"Whatsapp is just an example, he meant any kind of image as proof. The idea is to have a
> reason/proof of the change of freq, and we can support that claim using a photo or the whole claim
> could be the photo … but something must be required, either they put a photo, or a text (message or
> link or anything)"*

**The rule is: at least one of {text, image}.** Text may be a message, a link, or anything. A link is
never mandatory.

⚠ **A link-mandatory version shipped on 2026-08-17 and was relaxed the same day.** Requiring an
`http(s)` URL blocked every approval that lives somewhere unlinkable, which is precisely the case this
image path exists to cover. Do not reintroduce it. Current live rule: `reason.trim().length >= 10`,
client and server.

**On shipping:** the rule becomes `(text >= 10) || (>= 1 image)`, and **the image arm must be enforced
server-side too**. If only the client checks it, the requirement is a suggestion.

## 2. Storage

New **private** bucket `approval-proof`:

| setting | value | why |
|---|---|---|
| `public` | `false` | An image may be a whole WhatsApp conversation: names, numbers, pricing |
| `file_size_limit` | `5242880` (5 MB) | Matches `rpa-evidence`, the only existing private bucket |
| `allowed_mime_types` | `image/jpeg`, `image/png` | The client normalises to JPEG before upload |

🛑 **Separate from `rpa-evidence`** (Fred's call). That bucket is the GDO bot's evidence; mixing
human-supplied approval proof into it would confuse the provenance of both.

Path, following the newest convention (`admin-review/<id>/<uuid>.png`):

```
client-app/job-frequency/<job_id>/<uuid>.jpg
```

Job-scoped folders browse well. *Which change* an image proves lives in `photo_links`, never in the
path — a path is not a relationship.

**Viewing:** `createSignedUrl` from the app. Staff run as `authenticated` with a real `uid`, so
client-side signing works and no proxy is needed. ⚠ Per Building Apps rule 7b the storage policy tests
`auth.uid() IS NOT NULL`, **not** the role, so signing must happen *after* the session hydrates or it
returns zero rows and the UI renders an empty frame rather than an error.

## 3. Data model — no new tables

Per [ADR 009](../../decisions/009-unified-photos-architecture.md) this is a new `entity_type`, not a
new table. The ADR is explicit: *"No new per-entity photo tables"* and *"No inline photo URL columns"*.

| table | row |
|---|---|
| `photos` | `storage_path`, `file_name`, `content_type`, `size_bytes`, `width_px`, `height_px`, `uploaded_by_employee_id`, `source='client_app_upload'` |
| `photo_links` | `entity_type='job_frequency_change'`, `entity_id=job_frequency_changes.id`, `role='approval_proof'` |

**One migration:** add `'job_frequency_change'` to `photo_links_entity_type_chk`.

🛑 **The ADR's "zero schema churn when adding a photo-owning entity" claim is STALE.**
`photo_links_entity_type_chk` is a CHECK whitelist holding only `derm_manifest`, `inspection`, `note`,
`visit`. A new kind needs a migration — the same trap `entity_source_links` has. Correct the ADR in the
same cycle.

⚠ **`uploaded_by_employee_id` is an FK to `employees`, but the actor is an auth user identified by
email.** Map email → `employees.id`; leave NULL when there is no match. Attribution must not fail the
upload. (`audit.logs` records the real actor via `jwt_claims->>'email'` regardless — note that
`changed_by` is always NULL and is not the column to read.)

⚠ **Soft-delete asymmetry, and it decides where deletion happens.** `photo_links` has
`deleted_at`/`deleted_by`/`deleted_reason` **and** an audit trigger; `photos` has **neither**. So
removing a proof soft-deletes the **link** and leaves `photos` and the file intact. Deleting the
`photos` row would be an untraceable hard delete that CASCADEs the links.

## 4. Flow (approach A: base64 through `save-client-job`)

1. An **Attach proof** control appears beside the reason field, under the same condition that already
   gates the reason: an existing job whose frequency actually changed.
2. **Client-side normalise:** downscale to ~1600px long edge, re-encode JPEG ~0.8, reject if still
   > 2 MB. **Max 3 images.**
   🛑 The canvas re-encode is what **strips EXIF**, and that is the point, not a side effect. "Any
   image" now includes a phone photo of a paper approval, which can carry GPS. House rule: normalise
   the **input**, not the consumer — and a mime allow-list does not cover EXIF.
3. Save enabled when `reason.trim().length >= 10` **OR** `attachments.length >= 1`.
4. Payload gains `frequency_proof: [{ file_name, content_type, data_base64 }]`.
5. `save-client-job` keeps its existing order — push to Jobber → **re-read and verify** → write the job
   → insert `job_frequency_changes` — and **only then** uploads each image (service_role) and inserts
   `photos` + `photo_links`.
6. Response gains `frequency_proof_saved: <n>`.

**Why not a direct browser upload:** it would need an INSERT policy on a bucket chosen specifically to
stay closed, and every abandoned save would leave an orphan needing a sweeper. Routing through the edge
function means **no object ever exists for a change that did not happen**. Precedent:
`parse-gdo-permit` already does base64 → service_role upload, because the app has no INSERT policy on
private buckets.

**Cost accepted:** base64 inflates ~33% and edge functions cap request size. That is what the 2 MB /
3 image caps are for.

## 5. Failure handling

| failure | outcome |
|---|---|
| Jobber refuses | Nothing uploaded, nothing written. The existing guard returns first. |
| Jobber succeeds, `job_frequency_changes` insert fails | Existing behaviour, unchanged (`frequency_reason_recorded: false`). No upload attempted. |
| Jobber succeeds, change row written, **upload fails** | The cadence change **stands**. Jobber is committed and cannot be rolled back. Return success with `frequency_proof_saved: 0` and a warning. |

🛑 **The last row needs a remedy or it is a dead end**, so **attach-proof-to-an-existing-change is in
scope** (Fred approved). Same code path minus Jobber, keyed on `job_frequency_changes.id`. Without it a
failed upload leaves a change that can never be proven.

⚠ Never report the whole save as failed because an image did not upload. Jobber and the DB already hold
the cadence change; claiming failure would send someone to re-apply a change that already happened.

## 6. Testing

Every check below pairs with a control, because a green suite with no control is an untested
instrument.

| # | test | control that makes it mean something |
|---|---|---|
| 1 | CHECK accepts `job_frequency_change` | and **rejects** a fabricated value (two-sided) |
| 2 | A link row soft-deletes and `audit.logs` captures it | `public.clients` as the known-audited comparison |
| 3 | Bucket is private: `anon` and `authenticated` cannot read an object directly | a **signed URL can** — else "denied" might just mean "broken" |
| 4 | **EXIF stripped:** stored object carries no GPS | assert the **source file DID** carry GPS, or the test proves nothing |
| 5 | Validation matrix: text only / image only / both / **neither** | neither refused on **client and server** |
| 6 | Partial failure: force the storage step to fail after Jobber succeeds | change is recorded, response warns, `frequency_proof_saved: 0` |
| 7 | Caps: 4th image refused, >2 MB refused | a 1.9 MB image is **accepted** |

**Visual check required** (Fred's standing rule): the control renders in the dialog, a thumbnail
appears after attaching, and the proof is viewable via a signed URL on a saved change.

## 7. Deploy order

🛑 **Direction decides the order, and this field has already proven both.**

- **This change ADDS an alternative** (image satisfies the requirement), so it **loosens** the client
  gate while **adding** a server capability. Ship the **server first**: a server that accepts more than
  the UI sends is always safe.
- If a future change ever **requires** the image, that is a tightening: **UI first, verify the published
  bundle, then the server**, or every save from the current bundle fails. That is known-issue 0g and
  the `DEPLOY-B-FREQ-REASON` note in `save-client-job`.

## 8. Out of scope

- Images on the **client status** reason. Fred: link/proof optional there, any text accepted.
- Backfilling proof onto the frequency changes already recorded.
- Any client-facing surface. This is internal approval evidence; the Field Portal must never show it.
