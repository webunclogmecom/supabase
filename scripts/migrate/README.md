# One-time data migrations

Scripts in this folder are **one-time** migrations (as distinct from `scripts/populate/`, which is the bulk orchestrator, and `scripts/migrations/*.sql`, which are schema-only).

Each migration here has a specific deadline or blocker it resolves. Running one is a deliberate act — these scripts write to prod.

## Active migrations

### `jobber_notes_photos.js`

**Status:** ✅ Functional. First production run 2026-04-20.

**Deadline:** May 2026 Jobber sunset. Without this, Jobber-hosted photo URLs expire and all historical field photos are lost.

**What it does:** Pulls every Jobber note (from clients, jobs, visits) with its text body and attachments. Classifies each note (visit-scoped vs. non-visit). Routes the text to the `notes` table and each attachment to `photos` + `photo_links` with the correct `entity_type`/`role`. Uses `entity_source_links` for idempotency.

## How it works

```
                ┌─────────────────────────────────────────────────┐
                │  1. Enumerate clients via entity_source_links    │
                │  (entity_type='client', source_system='jobber')  │
                └────────────────────┬────────────────────────────┘
                                     ▼
             ┌──────────────────────────────────────────────┐
             │  2. Per client, two GraphQL fetches:          │
             │     - client.notes(first: 10) paginated       │
             │     - client.jobs { id } → for each: job.notes│
             │     Dedupe by note.id (JobNoteUnion surfaces  │
             │     inherited client notes)                   │
             └────────────────────┬─────────────────────────┘
                                  ▼
             ┌──────────────────────────────────────────────┐
             │  3. For each note: classify                   │
             │     - visit match (±1 day on same client)     │
             │     - else: non_visit (client-scoped)         │
             └────────────────────┬─────────────────────────┘
                                  ▼
             ┌──────────────────────────────────────────────┐
             │  4. For each attachment:                      │
             │     - check mime-type whitelist               │
             │     - check size ≤ 50 MB (Supabase Pro cap)   │
             │       > 50 MB → log to                        │
             │         jobber_oversized_attachments          │
             │     - skip if already migrated (ESL check)    │
             │     - download from Jobber S3 presigned URL   │
             │     - upload to bucket 'GT - Visits Images'   │
             │       at visits/<visit_id>/… or notes/<c>/…   │
             └────────────────────┬─────────────────────────┘
                                  ▼
             ┌──────────────────────────────────────────────┐
             │  5. Transactional persist (CTE batch):        │
             │     INSERT notes + entity_source_links('note')│
             │     INSERT photos + photo_links               │
             │       + entity_source_links('photo')          │
             │     ON CONFLICT → skip (idempotency)          │
             └──────────────────────────────────────────────┘
```

## Usage

```bash
# Sanity-check what WOULD happen on N clients (no writes, no uploads)
node scripts/migrate/jobber_notes_photos.js --dry-run --limit 5

# Real run
node scripts/migrate/jobber_notes_photos.js --execute

# Resume from last checkpoint (sync_cursors.jobber_notes_migration)
node scripts/migrate/jobber_notes_photos.js --execute --resume

# Emergency: skip attachments (write notes text only)
node scripts/migrate/jobber_notes_photos.js --execute --skip-attachments
```

## Rate-limit profile

- Jobber: 2,500 req/5min (DDoS) + 10k-point query-cost bucket @ 500pt/s restore
- Notes-with-attachments query is capped at `first: 10` — each page requests ~5,000 cost-budget points (actual burn ~50 points). At first: 50 Jobber rejects the query outright (requested 25k > 10k ceiling).
- Script's `respectBudget()` sleeps when budget < 20% of max.

## Idempotency

Every note and photo gets an `entity_source_links` row keyed by `(entity_type, 'jobber', source_id)`. Before insert, the script checks this table and skips any already-migrated note/photo. Safe to Ctrl-C and re-run with `--resume`.

## Files > 50 MB

Supabase Pro caps bucket `file_size_limit` at 50 MB. Larger attachments (mostly 4K video from Samsung phones) are skipped and logged to `jobber_oversized_attachments` with the Jobber signed URL (valid ~3 days). Recovery requires a Supabase plan upgrade or external storage (S3 / GCS bucket pointer).

## Classifier output shape

- **visit-scoped**: note.visit_id set to closest visit within ±1 day; photos link to `entity_type='visit'`, `role='other'` (historical attachments can't be disambiguated before/after without manual review).
- **non-visit**: note has only client_id; photos link to `entity_type='note'`, `role='other'`. Future manual review can reclassify.

## Follow-ups (scheduled, not yet executed)

### Property location photos backfill

`properties.location_photo_url` (legacy TEXT column) → `photos` + `photo_links(entity_type='property', role='overview')`. One-shot SQL migration. Should run after the Jobber notes migration is complete.

## Follow-up migration (planned, not yet scripted)

### Property location photos backfill

`properties.location_photo_url` (single TEXT column, legacy) → `photos` + `photo_links(entity_type='property', role='overview')`. One-shot SQL migration. Should run after the Jobber notes migration is complete (so it's not competing for the same Storage bucket).
