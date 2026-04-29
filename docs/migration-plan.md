# Migration Plan

The plan for Jobber/Airtable/Fillout sunset and the Odoo.sh cutover in May 2026. Plus active data migrations that must finish before sunset.

---

## Why this document exists

Three source systems are being decommissioned:

| System | Role today | Sunset target | Replaced by |
|---|---|---|---|
| Jobber | CRM, scheduling, invoicing, photo storage | May 2026 | Odoo.sh |
| Airtable | Service configs, DERM data, routes, receivables, leads | May 2026 | Odoo.sh |
| Fillout | Pre/post-shift inspections, forms | Rolling (as forms migrate) | Odoo.sh Forms |

Samsara stays ([ADR 007](decisions/007-samsara-permanent.md)).

Before sunset, three kinds of work must complete:
1. **Data that's in the source system but not yet in Supabase** — must be migrated, or it disappears with the source.
2. **Data that's in Supabase but tied to source-system URLs** (photos, attachments) — must be re-hosted locally.
3. **Downstream consumers** (Odoo.sh CRM) — must point at Supabase, not at the old sources.

---

## Timeline

```
2026-04 ──────────────── 2026-05 ──────────────── 2026-06
  │                        │                        │
  │  photo migration       │                        │
  │◄─── must finish ──────►│  cutover window        │
  │                        │                        │
  │  visit_assignments     │  Odoo.sh live          │
  │  re-pull               │  Jobber/Airtable       │
  │◄─── must finish ──────►│  read-only,            │
  │                        │  then archived         │
  │                        │                        │
  │                        │  Samsara continues     │
  │                        ├──────────────────────► │ (permanent)
```

**Critical path: the Jobber photo migration.** Jobber note attachments are hosted on Jobber's CDN. When Jobber is decommissioned, those URLs die — and with them, DERM evidence, damage documentation, and before/after photos.

---

## Active migration: Jobber notes → photos + text

**Status:** ✅ **COMPLETE 2026-04-21.** 1,853 notes + 8,019 files (9.3 GB) migrated from 221/373 Jobber clients. 35 oversized files (>50 MB) tracked in `jobber_oversized_attachments`. See [`docs/jobber-migration-techlead-summary.md §7`](jobber-migration-techlead-summary.md#7-run-results-2026-04-20--2026-04-21) for final numbers.

### Scope

Jobber stores notes on Clients, Jobs, and Visits. Each note has:
- `body` (text) — historical field notes, damage reports, "customer requested X"
- `createdAt`, `updatedAt`, `createdBy` (Jobber user)
- `attachments[]` — photos, each with a URL + metadata

**We need to migrate both the text and the attachments.** Earlier scoping assumed photos only; Fred clarified on 2026-04-20 that note text is equally important (contains DERM documentation, client instructions, repeat-issue tracking).

### Target schema

Photos now live in the unified `photos` + `photo_links` pair ([ADR 009](decisions/009-unified-photos-architecture.md)) that landed on 2026-04-20. The Jobber migration routes attachments to the right `entity_type` based on classification (see below).

`notes` table shipped 2026-04-20 (migration `add_notes_table.sql`).

```
notes
  id PK
  client_id FK → clients        (always set)
  visit_id  FK → visits    NULL (set when triangulated to a specific visit)
  property_id FK → properties NULL (set when scoped to a specific location)
  job_id    FK → jobs      NULL (set when attached to a Job instead of a Visit)
  body TEXT
  author_employee_id FK → employees NULL
  author_name TEXT                 (denorm fallback for unresolvable historical Jobber users)
  note_date TIMESTAMPTZ             (original Jobber timestamp — load-bearing for triangulation)
  source TEXT                       ('jobber_migration' | 'user' | 'ai' | 'system')
  tags TEXT[]                       (optional: 'warning','payment','derm','access')
  created_at, updated_at TIMESTAMPTZ
```

Jobber note IDs → `entity_source_links` with `entity_type='note'`, `source_system='jobber'`. Per [ADR 002](decisions/002-entity-source-links.md) — no `jobber_note_id` column on notes.

**Photos** — already have a home. Each Jobber attachment becomes:
- One row in `photos` (the file + EXIF metadata, `source='jobber_migration'`)
- One row in `photo_links` (polymorphic link to the right entity, see classification rules below)

### Classification (the core logic)

Every Jobber note goes through this classifier:

```
For each Jobber note (has: client_id, note_date, body, attachments[]):

  1. Try to match to a visit:
     - Find visits for this client where |note_date − visit_date| ≤ 1 day
     - If exactly one → VISIT-SCOPED
     - Multiple → pick closest by timestamp
     - Zero → NON-VISIT

  2. VISIT-SCOPED:
     - Insert into `notes` with visit_id, client_id, property_id, source='jobber_migration'
     - For each attachment:
         photos row (file + EXIF, source='jobber_migration')
         photo_links row with entity_type='visit', entity_id=<visit_id>, role='other'
         (historical attachments can't be cleanly before/after — leave role='other';
          the future app will tag explicit before/after)
     - The note's body becomes the caption for each linked photo

  3. NON-VISIT (Fred's "historical, warning, or something else"):
     - Insert into `notes` with only client_id (+ maybe property_id), source='jobber_migration'
     - Infer tags from body: 'payment','warning','derm','access','contact'
     - For each attachment:
         - If body mentions address/access/gate AND client has 1 property → link to property (role='access')
         - Otherwise → link to the note itself (entity_type='note', role='attachment')
           These can be reclassified later via a manual review pass
```

Edge cases:
- Multi-stop visits on the same day for one client → note links to the most recent by `end_at`.
- Notes written days after the visit → `visit_id` stays NULL on the note; any photos attach to `entity_type='note'`.
- Notes on client-level (not tied to a specific job) → `visit_id` always NULL.

### Storage bucket

- **Bucket name:** `GT - Visits Images` (Fred created 2026-04-20; previously documented as `jobber-notes-photos` in earlier drafts of this doc — actual bucket name in Supabase is the spaced version).
- **Visibility:** private; signed URLs issued on read.
- **Path pattern in `photos.storage_path`:** `visits/<visit_id>/<YYYYMMDD>_<jobber_id_b64>_<filename>` when the photo links to a visit; `notes/<note_id>/...` for client-level notes that didn't resolve to a visit.
- **Generating a signed URL** (Odoo connector pattern):
  ```bash
  curl -X POST \
    "$SUPABASE_URL/storage/v1/object/sign/GT%20-%20Visits%20Images/<storage_path>" \
    -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
    -H "Content-Type: application/json" \
    -d '{"expiresIn": 3600}'
  ```
  Response: `{"signedURL": "/object/sign/GT - Visits Images/...?token=..."}`. Prepend `$SUPABASE_URL/storage/v1` to construct the final URL.

### Execution plan

Full details: [scripts/migrate/README.md](../scripts/migrate/README.md).

**Architecture constraints found during build:**

1. **Jobber GraphQL cost budget:** the notes-with-attachments query at `first: 50` has a *requested* cost of ~25k points, exceeding the 10k ceiling — Jobber rejects without executing. Script uses `first: 10` which requests ~5k, actually burns ~50. More paginated calls, but they fit.

2. **JobNoteUnion dedup:** Jobber's `job.notes` connection returns inherited client-level notes too (ClientNote is a possibleType of the union). Same note id can surface twice — once via `client.notes`, once via `job.notes`. Script dedupes by note.id.

3. **Bucket file-size cap:** Supabase Pro hard-caps bucket `file_size_limit` at 50 MB. Videos > 50 MB (observed: 4K phone footage) can't be stored on this plan. Script logs these to `jobber_oversized_attachments` with the signed Jobber URL preserved for later recovery (URL expires ~3 days, so recovery window is tight).

**Run log:**

```bash
# Dry-run first
node scripts/migrate/jobber_notes_photos.js --dry-run --limit 5

# Real run, resumable
node scripts/migrate/jobber_notes_photos.js --execute
node scripts/migrate/jobber_notes_photos.js --execute --resume  # if interrupted
```

**Verification after completion:**

- `SELECT COUNT(*) FROM notes WHERE source='jobber_migration'` — expected: several hundred
- `SELECT COUNT(*) FROM photos WHERE source='jobber_migration'` — expected: low thousands
- `SELECT COUNT(*) FROM jobber_oversized_attachments` — track for follow-up recovery
- Spot-check 10 random notes: pull their `body` from our DB, compare against Jobber UI view

### Open design questions (for Viktor review)

- [ ] Worth the effort to map Jobber `createdBy` user → our `employees.id`? Or leave as a denormalized `author_name TEXT` field for historical notes where the person may be long gone?
- [ ] One bucket for all note attachments, or split by entity type? Current plan: one bucket (`GT - Visits Images`), reorganize later if needed.
- [ ] `notes` table creation — ship with the extractor or ahead of it? No DB dependency either way.

---

## ~~Active migration: `visit_assignments` backfill~~ — not needed

**Status:** ✅ Resolved. Doc audit on 2026-04-21 found `visit_assignments` already has **1,677 rows** (1,398 unique visits × 14 employees), populated via `populate.js` fixup pass 5 (text match on `visits.completed_by` against `employees.full_name`). The "blocked on Jobber rate limits" status was stale — it dated from mid-build before the fixup had run.

A more thorough backfill via Jobber's GraphQL `visit.assignedUsers` field could still enrich the ~287 unmatched visits, but this is now a nice-to-have, not a blocker.

`visit_assignments` is at 0 rows because the initial Jobber visits pull didn't include the `assignedUsers` subfield. Current webhook deliveries DO include it — so all visits post-webhook-deploy have correct assignments; only the 1,685 pre-webhook Jobber visits are missing.

### Execution plan

1. Write a new `webhook-jobber` endpoint: `POST /functions/v1/webhook-jobber` with body `{action: 'backfill', visitIds: [...]}`.
2. For each visit ID, query Jobber GraphQL with `assignedUsers { id name }`.
3. Resolve each `assignedUsers.id` to our `employees.id` via `entity_source_links`.
4. Upsert to `visit_assignments`.
5. Rate-limit: 50 visit IDs per call, 2-sec delay between calls, max 1,500 queries per 5-min window.
6. Drive from a one-shot script that pulls all 1,685 visit IDs, chunks them, fires the endpoint.

Estimated runtime: ~90 minutes over a weekend window.

---

## Cutover: Jobber + Airtable → Odoo.sh

**Target date:** May 2026 (TBC by Yan).

### Prerequisites (all must be done before the cutover weekend)

- [ ] All photo and note migrations complete.
- [ ] `visit_assignments` backfill complete.
- [ ] Odoo.sh reading from Supabase via its own Edge Function (`webhook-odoo`) or scheduled pulls.
- [ ] Full RLS policies on every public-read table (Odoo will read via a restricted role, not service_role).
- [ ] Parallel-run period: at least 2 weeks where Odoo is live but Jobber is still the authoritative input. Any discrepancy → fix before cutover.
- [ ] A documented rollback plan if Odoo's data model diverges from what we expected.

### Cutover weekend checklist

1. Disable Jobber webhook subscriptions (stop new events flowing into Supabase from Jobber).
2. Take a Supabase PITR snapshot as "pre-cutover-<date>" reference.
3. Update Odoo.sh to write-through to Supabase (Odoo becomes source of truth for CRM/billing writes).
4. Redirect DNS / iframes / links from Jobber-backed pages to Odoo.
5. Keep Jobber in read-only mode for 60 days as an emergency reference.
6. After 60 days, archive `entity_source_links` rows with `source_system = 'jobber'` to a `legacy_entity_source_links` table. Business tables are untouched.

### Same flow for Airtable

Identical playbook: photo migration, parallel run, cutover, 60-day read-only, archive `source_system='airtable'` rows.

---

## Data export before archival

Even after archival, we may want a raw Jobber/Airtable backup in cold storage. Plan:

- Before sunset, export each source's raw data to a JSON/Parquet dump on S3 or Google Cloud Storage.
- Label with date + source version.
- Retention: 7 years (matches tax/audit retention on financial data).
- This is separate from `webhook_events_log`, which is operational, not archival.

No active plan yet — TBD before April 2026.

---

## What's NOT being migrated

Intentionally left out:

- **QuickBooks data.** Not in scope ([ADR 006](decisions/006-no-quickbooks.md)).
- **Ramp expense data.** Emily the bookkeeper reads Ramp directly. No Supabase integration.
- **Gmail / Google Drive contents.** Files, SOPs, client emails live in Google. Supabase is structured data only.
- **Trello boards.** Project management lives in Trello; not sync'd here.

If the list above grows to "and also X", that's a scope-creep conversation — not an emergency migration.

---

## Success criteria

The cutover is done when, after 60 days of Odoo.sh operations:
- Zero inbound Jobber or Airtable webhook events.
- Zero dashboards or reports still reading from Jobber/Airtable URLs.
- Zero URL references to `jobber.com` or `airtable.com` in active Edge Functions, scripts, or docs.
- Every photo or attachment that was in Jobber has a `note_attachments.storage_path` pointing at Supabase Storage.
- `entity_source_links` with `source_system IN ('jobber','airtable')` is ≤ 60 days old (stale rows archived).

At that point, update [ADR 001](decisions/001-webhooks-over-cron.md) and ADR 007 with a supersession note, and close out this document.
