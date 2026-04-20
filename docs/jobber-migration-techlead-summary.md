# Jobber Notes + Photos Migration — Tech Lead Summary

*Author: Claude (as Tech Lead) · 2026-04-20 · To be reviewed by Fred*

This document is the "how and why" of the Jobber notes + photos migration. Read this first if you need to understand, rerun, or extend the migration.

---

## TL;DR

- **What:** Extracted every note (text + photos + videos + PDFs) from Jobber's Client and Job records, routed them to our schema under the new unified `photos` / `photo_links` / `notes` architecture (ADR 009).
- **Why:** Jobber sunsets May 2026. Its S3 presigned URLs die with it. All DERM evidence, before/after photos, and client context would be permanently lost without this migration.
- **Outcome:** See §7 "Run results" below (filled after migration completes).
- **Idempotent, resumable:** `node scripts/migrate/jobber_notes_photos.js --execute --resume`. Safe to re-run.

---

## 1. The problem

Jobber's note system is rich but tied to their infrastructure:

- Notes on Client, Job, Quote, Request (4 entity types)
- Each note has: text body, timestamp, author (User or App), and 0-N file attachments
- Attachments are hosted on Jobber's S3 with signed URLs (3-day expiry) — **they die when Jobber sunsets**
- No bulk export, no automatic migration

Fred's requirements:
1. Don't lose anything
2. Respect the new schema (ADR 009: unified `photos` + polymorphic `photo_links`)
3. Classify photos by likely intent: close to a visit → it's about that visit; far from any visit → historical context on the client
4. Be idempotent; be resumable; be flawlessly documented

## 2. The architecture

```
Jobber GraphQL                                      Our database
┌────────────────┐                                  ┌──────────────────┐
│ client         │                                  │ clients          │
│  notes         │──▶ classify by ±1-day  ──▶       │ notes            │
│   fileAttach.  │    to matching visit             │ photos           │
│ jobs           │                                  │ photo_links      │
│  notes         │──▶ dedupe (JobNoteUnion          │ entity_source_   │
│   fileAttach.  │    shows inherited               │   links          │
└────────────────┘    ClientNotes)                  └──────────────────┘
                                     ▲
                                     │
                              ┌──────┴──────────┐
                              │ Supabase        │
                              │ Storage:        │
                              │ "GT - Visits    │
                              │  Images" bucket │
                              └─────────────────┘
```

**Single-pass, single-script:** fetch + classify + upload + persist all in one Node.js script. No intermediate queues, no separate upload step. Keeps failure modes obvious.

**Transactional at the note level:** for each note we write a single SQL batch that inserts the note row, creates its `entity_source_links`, and — for each already-uploaded attachment — the photo row, the photo_link, and the photo's entity_source_links row. If any step fails, nothing persists for that note; the already-uploaded files in Storage become orphans but the next `--resume` run picks them up via ON CONFLICT on `photos.storage_path`.

**Idempotency by construction:** `entity_source_links (entity_type, source_system, source_id)` is UNIQUE. Before inserting a note or photo, we check this table. If the Jobber ID is already in there, we skip. Running the script twice in a row → second run is a no-op.

## 3. The three "gotchas" found during the build

### 3.1 Jobber's GraphQL cost budget rejects large nested queries

**Symptom:** Every run threw `"Throttled"` on the very first notes query, even though the account's 10k-point budget was full.

**Cause:** Jobber's query cost calculator inspects the query shape *before* execution. A `notes(first: 50) { … fileAttachments { … url } }` query gets a *requested cost* of ~25,000 points because the calculator assumes worst-case attachments per note. That exceeds the 10,000 max, and Jobber rejects without running. The *actual* cost of an executed query is much lower (~50), but the pre-check is pessimistic.

**Fix:** Lowered `NOTES_PAGE_SIZE` from 50 to 10. At `first: 10` the requested cost is ~5,000 — fits inside the ceiling. More pages per client, but page overhead is trivial. Documented in the script header.

### 3.2 JobNoteUnion surfaces inherited ClientNotes

**Symptom:** Same note id appeared twice in the extractor output — once via `client.notes` and once via `job.notes`.

**Cause:** Jobber's `JobNoteUnion.possibleTypes` includes ClientNote. Fetching a job's notes returns JobNotes *and* the inherited ClientNotes the client-level UI would show. Same note id, two surface paths.

**Fix:** Dedupe by `note.id` in `fetchJobberClientNotes` using a Set. Clean.

### 3.3 Supabase Pro bucket file-size cap is 50 MB

**Symptom:** 4K phone videos (50-400 MB) rejected with HTTP 413. Attempting to raise `file_size_limit` to 500 MB on the bucket: the API accepts the PUT with 400 "Payload too large" — the bucket silently keeps the prior 50 MB limit.

**Cause:** Supabase Pro plan has a hard 50 MB ceiling on bucket `file_size_limit`. You can't configure a bucket to accept larger files without plan changes.

**Fix:** Pre-check attachment size in the script. Files > 50 MB are skipped and logged to a new `jobber_oversized_attachments` table with the Jobber signed URL preserved (3-day validity). Recovery requires either a plan upgrade or external storage (S3/GCS pointer in the photo row).

## 4. The classifier

For each Jobber note with timestamp `note_date`:

```
SELECT id, property_id
FROM visits
WHERE client_id = <our_client_id>
  AND visit_date BETWEEN (note_date::date - 1) AND (note_date::date + 1)
ORDER BY ABS(visit_date - note_date::date), end_at DESC NULLS LAST
LIMIT 1
```

- Match found → **visit-scoped**: note.visit_id set; photos link to `entity_type='visit', role='other'`
- No match → **non-visit**: note only has client_id; photos link to `entity_type='note', role='other'`

Why `role='other'` and not `before`/`after`? Historical attachments have no intent markers. A future app (Odoo.sh forms) will tag them explicitly. Forcing a guess now would bake bad data in forever.

Observed from live run so far: **~78% of notes triangulate cleanly to a visit.** That matches Fred's intuition: techs write notes right after a job, close in time to the visit.

## 5. Schema landed (all applied to prod before migration)

| Migration file | Effect |
|---|---|
| `add_notes_table.sql` | Created `notes` table — text content, optional scoping to visit/property/job/client |
| `unified_photos_architecture.sql` (earlier commit) | Created `photos` + `photo_links`, dropped the obsolete `visit_photos` / `inspection_photos` |
| `add_jobber_oversized_attachments.sql` | Tracking table for files > 50 MB |

## 6. How to use it

```bash
# Sanity-check — what would the script do, for 5 clients?
node scripts/migrate/jobber_notes_photos.js --dry-run --limit 5

# Real run
node scripts/migrate/jobber_notes_photos.js --execute

# Resume after interruption
node scripts/migrate/jobber_notes_photos.js --execute --resume

# Text-only (for debugging; no uploads)
node scripts/migrate/jobber_notes_photos.js --execute --skip-attachments

# Verification report after a run
node scripts/migrate/verify_jobber_migration.js
```

All flags documented in `scripts/migrate/README.md`.

## 7. Run results (2026-04-20)

*This section is filled in after the background migration completes. Until then, see `scripts/migrate/verify_jobber_migration.js` for a live report.*

Placeholder — current-state snapshot at checkpoint time:

- Notes migrated: *(live: run verify_jobber_migration.js)*
- Photos uploaded: *(same)*
- Storage used: *(same)*
- Oversized attachments logged: *(same)*
- Classifier split: ~78% visit-scoped, ~22% non-visit
- Clients processed: *(live)*
- Errors: *(live)*

## 8. Follow-ups scheduled

### Property location photos backfill (not yet scripted)
`properties.location_photo_url` → `photos` + `photo_links(entity_type='property', role='overview')`. One-shot SQL. Should run after this migration.

### Oversized attachment recovery (conditional)
If Fred decides to handle files > 50 MB, options:
1. **Upgrade Supabase plan** — raises the cap, re-run the script with just the oversized list
2. **External S3 bucket** — upload to a separate bucket, store URL in `photos.storage_path`
3. **Compress before upload** — transcode videos to fit under 50 MB; lossy
4. **Accept loss** — only ~1 oversized per 100 notes observed; might not be worth the effort

## 9. What future work inherits

The patterns established here are reusable for:
- **Fillout photo migration** — Fillout stores shift inspection photos. Same pattern: fetch, classify, upload to Storage, link via `photo_links(entity_type='inspection')`.
- **Odoo.sh photo ingest** — same idempotency + polymorphic link design, but photos come in via webhooks rather than bulk extraction.

## 10. Key files

```
scripts/migrate/
  jobber_notes_photos.js    — the extractor
  verify_jobber_migration.js — read-only health report
  README.md                 — operator-oriented usage doc

scripts/migrations/
  add_notes_table.sql
  add_jobber_oversized_attachments.sql

docs/decisions/
  009-unified-photos-architecture.md  — the architectural ADR

docs/
  migration-plan.md         — broader May-2026 sunset context
  runbook.md                — operational playbook + incident log
  schema.md                 — schema reference (notes, photos, photo_links)
```

---

*If you're extending or rerunning this: read §3 "gotchas" first. Each one burned an hour of debug time and each one has a permanent fix documented in the extractor source.*
