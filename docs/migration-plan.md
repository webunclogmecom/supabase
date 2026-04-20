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

**Status:** Planned, not started (as of 2026-04-20). Must finish before May 2026 Jobber sunset.

### Scope

Jobber stores notes on Clients, Jobs, and Visits. Each note has:
- `body` (text) — historical field notes, damage reports, "customer requested X"
- `createdAt`, `updatedAt`, `createdBy` (Jobber user)
- `attachments[]` — photos, each with a URL + metadata

**We need to migrate both the text and the attachments.** Earlier scoping assumed photos only; Fred clarified on 2026-04-20 that note text is equally important (contains DERM documentation, client instructions, repeat-issue tracking).

### Target schema (proposed)

```
notes
  id PK
  client_id FK → clients   (always set — every note lives under a client)
  visit_id  FK → visits NULL   (resolved when we can triangulate to a visit)
  job_id    FK → jobs   NULL   (set if the note was on a Job, not a Visit)
  body TEXT
  author_employee_id FK → employees NULL   (Jobber user → our employees via entity_source_links)
  note_created_at TIMESTAMPTZ   (load-bearing: used for visit triangulation)
  created_at, updated_at TIMESTAMPTZ

note_attachments
  id PK
  note_id FK → notes
  storage_path TEXT   (path inside Supabase Storage bucket)
  content_type, file_name TEXT
  size_bytes BIGINT
  jobber_original_url TEXT   (audit-only; not the live source after sunset)
  created_at TIMESTAMPTZ
```

Jobber note IDs → `entity_source_links` with `entity_type='note'`, `source_system='jobber'`. No `jobber_note_id` column, per [ADR 002](decisions/002-entity-source-links.md).

### Visit triangulation

A note is attached to a Client or a Job in Jobber. Matching it to one of our `visits` rows requires:

- `client_id` — always available.
- `note_created_at` — when the note was written (usually right after the visit).
- `visits.visit_date` — the operating date of each visit.

Match rule: the visit whose `visit_date` is closest to `note_created_at` for the same client, within a ±1 day window. If no visit is within the window, `visit_id` stays NULL.

Edge cases:
- Multi-stop visits on the same day for one client → note links to the most recent by `end_at`.
- Notes written days after the visit → `visit_id` stays NULL, note still preserved with client + timestamp.
- Notes on client-level (not tied to a specific job) → `visit_id` always NULL.

### Storage bucket

- **Bucket name:** `jobber-notes-photos` (Fred created on 2026-04-20)
- **Visibility:** private; signed URLs issued on read
- **Path pattern:** `<visit_id>/<original-filename>` when `visit_id` resolves, else `unassigned/<client_id>/<jobber_note_id>/<filename>`

### Execution plan

1. **Build extractor.** New Node.js script or a one-shot Edge Function that:
   - Enumerates Jobber clients (paginated)
   - For each client, fetches notes via GraphQL with attachments subfield
   - For each note, downloads attachments to a temp dir
   - Uploads attachments to Supabase Storage
   - Writes `notes` + `note_attachments` rows
   - Writes `entity_source_links` for each note
2. **Rate limiting.** Stay under 2,500 req / 5 min (Jobber DDoS). Batch by 50 clients per cycle, 2-second delay.
3. **Idempotency.** Use `ON CONFLICT` on `entity_source_links(entity_type='note', source_system='jobber', source_id)`. Re-runnable.
4. **Checkpoint.** Track progress in `sync_cursors` under entity `jobber_notes_migration`.
5. **Verify.** After completion, spot-check 10 random notes across 3 clients — confirm body text matches, photos load, `visit_id` resolution looks right.

### Open design questions (for Viktor review)

- [ ] Worth the effort to map Jobber `createdBy` user → our `employees.id`? Or leave as a denormalized `author_name TEXT` field for historical notes where the person may be long gone?
- [ ] One bucket for all note attachments, or split by photo_type (before/after/damage/derm)? Current plan: one bucket, reorganize later if needed.

---

## Active migration: `visit_assignments` backfill

**Status:** Blocked on Jobber API rate limits. Tracked in [runbook.md §6](runbook.md#outstanding-population-gaps).

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
