# One-time data migrations

Scripts in this folder are **one-time** migrations (as distinct from `scripts/populate/`, which is the bulk orchestrator, and `scripts/migrations/*.sql`, which are schema-only).

Each migration here has a specific deadline or blocker it resolves. Running one is a deliberate act — these scripts write to prod.

## Active migrations

### `jobber_notes_photos.js`

**Status:** Scaffold — graph query shape and upload pipeline stubbed with `TODO` markers.

**Deadline:** May 2026 Jobber sunset. Without this, Jobber-hosted photo URLs expire and all historical field photos are lost.

**What it does:** Pulls every Jobber note (from clients, jobs, visits) with its text body and attachments. Classifies each note (visit-scoped vs. non-visit). Routes the text to the `notes` table and each attachment to `photos` + `photo_links` with the correct `entity_type`/`role`. Uses `entity_source_links` for idempotency.

**Implementation roadmap:**

| Step | Function | Status |
|---|---|---|
| 1. Auth + GraphQL client | `jobberGraphQL` | ✓ Working (with cost budget logging + throttle retry) |
| 2. Enumerate clients | `iterateClients` | ✓ Working (reads from `entity_source_links`) |
| 3. Pull notes per client | `fetchJobberClientNotes` | **TODO** — needs the real Jobber GraphQL query |
| 4. Classify note | `classifyNote` | ✓ Working (visit triangulation by ±1 day) |
| 5. Download + upload attachment | `fetchAndStoreAttachment` | **TODO** — needs Supabase Storage REST upload |
| 6. Persist (note + photos + links) | `persistNote` | **TODO** — DRY_RUN printout works; real INSERT pending |
| 7. Checkpoint in `sync_cursors` | inline in main | ✓ Working |
| 8. Rate-limit handling | `respectBudget` | ✓ Working (sleeps when budget < 20% of max) |

**Next steps** (in order, so each step can be tested before moving on):

1. Fill in `fetchJobberClientNotes` with the real Jobber GraphQL query (reference: `supabase/functions/webhook-jobber/index.ts` for the query shape conventions; Jobber docs for the specific `notes { attachments { … } }` schema).
2. Run against one test client with `--dry-run --limit 1`. Verify classification output.
3. Implement `fetchAndStoreAttachment` using Supabase Storage REST (`POST /storage/v1/object/jobber-notes-photos/<path>`). Stream from Jobber CDN → buffer → upload.
4. Run against one test client with `--dry-run --limit 1` — should print upload paths, still no DB writes.
5. Implement `persistNote` as a single transaction (note + photos + photo_links + entity_source_links). Use the same 'ON CONFLICT' pattern as `populate.js` for idempotency.
6. Run against one test client with `--execute --limit 1` — verify rows exist in `notes`, `photos`, `photo_links`, `entity_source_links`.
7. Run against 10 clients. Verify rate limits stay healthy (check `[budget]` logs).
8. Full run: `node scripts/migrate/jobber_notes_photos.js --execute` (overnight, ~1–2 hours for ~400 clients).
9. Spot-verify 10 random notes against Jobber's UI.
10. Move to the `properties.location_photo_url` backfill + column drop.

## Follow-up migration (planned, not yet scripted)

### Property location photos backfill

`properties.location_photo_url` (single TEXT column, legacy) → `photos` + `photo_links(entity_type='property', role='overview')`. One-shot SQL migration. Should run after the Jobber notes migration is complete (so it's not competing for the same Storage bucket).
