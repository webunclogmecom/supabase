# Runbook

Operational procedures for the Unclogme Supabase database. "It's broken, what do I do?" lives here.

---

## Table of contents

1. [Webhook is failing](#1-webhook-is-failing)
2. [Data inconsistency detected](#2-data-inconsistency-detected)
3. [Schema migration procedure](#3-schema-migration-procedure)
4. [Edge Function deployment & rollback](#4-edge-function-deployment--rollback)
5. [Samsara webhook registration](#5-samsara-webhook-registration)
6. [Outstanding population gaps](#6-outstanding-population-gaps)
7. [Daily / weekly ops checks](#7-daily--weekly-ops-checks)
8. [Incident log](#8-incident-log)

---

## 1. Webhook is failing

**Symptom:** Clients/visits/invoices stopped updating. Dashboards show stale data. Office team reports "I updated X in Jobber but it's not in Supabase."

**Diagnose:**

```sql
-- Which source is failing, and how recently?
SELECT source_system, status, COUNT(*), MAX(created_at) AS last_seen
FROM webhook_events_log
WHERE created_at > NOW() - INTERVAL '24 hours'
GROUP BY source_system, status
ORDER BY source_system, status;
```

Expected: `status='processed'` majority, `status='failed'` near zero.

**If `status='failed'` is spiking:**

```sql
-- What's the error?
SELECT source_system, event_type, error_message, COUNT(*)
FROM webhook_events_log
WHERE status = 'failed'
  AND created_at > NOW() - INTERVAL '24 hours'
GROUP BY source_system, event_type, error_message
ORDER BY COUNT(*) DESC
LIMIT 20;
```

Common `error_message` values and their fixes:

| Error | Cause | Fix |
|---|---|---|
| `signature_invalid` | Webhook secret mismatch between source and Edge Function | Re-set the secret: `supabase secrets set JOBBER_WEBHOOK_SECRET=<value>` |
| `token_expired` | OAuth access token expired, refresh failed | Run `node scripts/jobber_auth.js`, update `webhook_tokens` |
| `entity_not_found` | `entity_source_links` lookup returned nothing — new entity not yet synced | Acceptable during bulk backfills; if persistent, check source's webhook delivery |
| `duplicate key` | `ON CONFLICT` clause misconfigured | Fix the upsert statement in the Edge Function, redeploy |
| `FK violation` | Parent entity hasn't been ingested yet (race) | Retry delivery via source's dashboard; if persistent, fix ordering |

**If no recent webhook events at all** (count = 0):
1. Source system may have disabled our webhook. Check the source's webhook dashboard (Jobber Developer Center, Samsara, Airtable automations).
2. Edge Function may be down. Check Supabase Dashboard → Edge Functions → `webhook-<source>` → Logs.
3. Check `webhook_tokens` for expired credentials (see [security.md](security.md#jobber-token-refresh-automatic-but-double-check)).

---

## 2. Data inconsistency detected

**Symptom:** A report shows numbers that don't add up. Manifest count vs. visit count mismatch. Client shows paid but invoice shows outstanding.

**Diagnose:**

```sql
-- Example: visits that reference a manifest that doesn't exist
SELECT mv.visit_id, mv.manifest_id
FROM manifest_visits mv
LEFT JOIN derm_manifests m ON m.id = mv.manifest_id
WHERE m.id IS NULL;
```

**Common inconsistency patterns:**

| Symptom | Likely cause | Fix |
|---|---|---|
| A client's `visits` count doesn't match Jobber | Missed webhook during an outage | Trigger manual resync: edit the client in Jobber (any touch) → webhook fires |
| Manifest count > visit count for a client | Multi-stop manifest (one manifest, many visits) | Not a bug — `manifest_visits` is M:N |
| `invoices.outstanding_amount` doesn't match `SUM(line_items.total_price)` | Manual adjustment in Jobber | Jobber is source of truth; `outstanding_amount` wins |
| `service_configs.next_visit` is in the past but `status='On Time'` | Trigger didn't fire on last visit completion | Manually recompute with a refresh query (see below) |

**Recompute `service_configs.next_visit` for a client:**

```sql
UPDATE service_configs sc
SET next_visit = last_visit + frequency_days,
    status = CASE
      WHEN (last_visit + frequency_days) < CURRENT_DATE - INTERVAL '14 days' THEN 'Critical'
      WHEN (last_visit + frequency_days) < CURRENT_DATE THEN 'Late'
      ELSE 'On Time'
    END,
    updated_at = NOW()
WHERE sc.client_id = <id>;
```

**If inconsistency is systemic** (not one client but many): stop. Don't mass-update. Investigate root cause first:
1. Identify affected rows (write a detection query).
2. Determine the mechanism (bad upsert? race condition? migration bug?).
3. Fix the mechanism (Edge Function change + redeploy).
4. Backfill the affected rows with a one-shot migration.

Never bulk-update without a detection query you can re-run to verify zero affected rows after the fix.

---

## 3. Schema migration procedure

**Every migration is a file in `scripts/migrations/` with a 3NF-audit header.**

### Standard flow

1. **Write the migration file.** Filename: `YYYYMMDD_brief_description.sql` (ordering by date), or `NN_description.sql` (ordered by number) — pick one convention and stay consistent. Current repo uses descriptive names.
2. **3NF audit header.** Every column added must have a stated 3NF justification. See `scripts/migrations/3nf_telemetry_readings.sql` for the template.
3. **BEGIN / COMMIT block.** All migrations are transactional. If a step fails, nothing applies.
4. **Idempotency.** Use `IF NOT EXISTS`, `IF EXISTS`, `CREATE OR REPLACE` — the script must be re-runnable without error.
5. **Viktor review for structural changes.** Per the collaboration protocol, structural changes (new tables, new FKs, column renames) get Viktor's sign-off before apply. Tests/probes don't need consent.
6. **Apply via Supabase SQL editor** (Dashboard → SQL Editor → paste → Run). Or via `psql` with the service-role connection string.
7. **Verify.** Run the detection query from the header comment (if any) — should return expected row count.
8. **Commit the file** to the repo. Never apply a migration that doesn't exist in git.

### Example header template

```sql
-- ============================================================================
-- Migration: <short name>
-- ============================================================================
-- Purpose:
--   <one-line what + why>
--
-- Changes:
--   1. <change> — 3NF check: <justification>
--   2. <change> — 3NF check: <justification>
--
-- Safety:
--   <row counts affected, whether any destructive ops, rollback plan>
-- ============================================================================

BEGIN;
-- ... statements ...
COMMIT;
```

### Rollback

There is no automatic rollback after `COMMIT`. Options:

- **Point-in-time recovery.** Supabase Pro plan has 7-day PITR. Dashboard → Database → Backups. Restores entire DB — use only if data loss, not for schema mistakes.
- **Inverse migration.** Write a new migration that reverses the change. `DROP COLUMN`, `DROP TABLE`, etc. Commit separately.
- **Pre-check queries.** Before applying, always run `SELECT COUNT(*) FROM <affected_table>` and save the number so you can verify after.

Never use `ALTER TABLE ... DROP COLUMN` on a column with data without a documented plan. Always `DROP COLUMN IF EXISTS` with a backup of the data captured first.

---

## 4. Edge Function deployment & rollback

### Deploy

```bash
# From project root
supabase functions deploy webhook-jobber --project-ref wbasvhvvismukaqdnouk
supabase functions deploy webhook-samsara --project-ref wbasvhvvismukaqdnouk
supabase functions deploy webhook-airtable --project-ref wbasvhvvismukaqdnouk
```

Deploy is atomic — either the new version goes live or the old stays. No partial state.

### Secrets

Edge Function environment variables are **not** read from `.env` at deploy time. They come from the Supabase secrets store:

```bash
supabase secrets list --project-ref wbasvhvvismukaqdnouk
supabase secrets set JOBBER_WEBHOOK_SECRET=<value> --project-ref wbasvhvvismukaqdnouk
```

Secrets update live — no redeploy needed.

### Rollback

If a deploy breaks something:

1. **Immediate mitigation:** disable the function. Dashboard → Edge Functions → select function → Disable. The source system will queue webhooks (up to their retry window) and redeliver when re-enabled.
2. **Revert the code** in git: `git revert <bad-commit>`.
3. **Redeploy:** `supabase functions deploy <name>`.
4. **Re-enable** in the dashboard.
5. **Backfill missed events:** in most cases not needed — Jobber / Samsara / Airtable retry failed deliveries for 24 h. If longer gap, trigger manual resync by editing the entity in the source.

### Logs

```bash
supabase functions logs webhook-jobber --project-ref wbasvhvvismukaqdnouk --tail
```

Or: Dashboard → Edge Functions → select function → Logs tab.

---

## 5. Samsara webhook registration

**Current status: BLOCKED.** Samsara webhook registration returns an auth error because the `SAMSARA_API_TOKEN` lacks the "Webhooks write" scope.

**Consequence:** `vehicle_telemetry_readings` is at 0 rows. `v_vehicle_telemetry_latest` returns empty. GPS enrichment on visits stops working for new visits.

### Fix

1. Log into Samsara dashboard: https://cloud.samsara.com/ → Admin Settings → API Tokens.
2. Locate the token currently in `SAMSARA_API_TOKEN` (or create a new one).
3. Edit permissions → enable **"Webhooks write"** scope.
4. If the token value changed, update:
   - `.env` (local)
   - `supabase secrets set SAMSARA_API_TOKEN=<new-value> --project-ref wbasvhvvismukaqdnouk`
5. Run `node scripts/webhooks/register-samsara.js` — should return 201 with the registered webhook ID.
6. Verify: trigger a vehicle event (e.g. drive Moises briefly) and check:

```sql
SELECT COUNT(*) FROM webhook_events_log
WHERE source_system = 'samsara' AND created_at > NOW() - INTERVAL '1 hour';
```

---

## 6. Outstanding population gaps

Tables with 0 rows that should eventually have data. Tracked here because each has a specific blocker.

| Table | Rows | Blocker | Path to fix |
|---|---|---|---|
| `vehicle_telemetry_readings` | 0 | Webhooks registered + Edge Function deployed 2026-04-20 — awaiting first telemetry events | Watch `webhook_events_log` for `source_system='samsara'` inflow |
| `visit_assignments` | 0 | Needs Jobber visits re-pull with `assignedUsers` field; hits rate limits | Add backfill endpoint to `webhook-jobber`; paced re-query over weekend |
| `notes` / `photos` / `photo_links` | 1,853 / 8,019 / 8,019 | Jobber migration complete 2026-04-21. 9.3 GB in Storage. 221 of 373 Jobber clients had notes. | — |
| `jobber_oversized_attachments` | 35 | Files > 50 MB skipped by the migration (Supabase Pro bucket cap). Tracked for recovery pass. | Plan upgrade or external storage |

### `visit_assignments` re-pull plan

1. Write a new endpoint in `webhook-jobber` that accepts `{action: 'backfill', visitIds: [...]}`.
2. For each visit ID, query Jobber GraphQL with the `assignedUsers` subfield.
3. Upsert to `visit_assignments`.
4. Rate-limit: batch of 50 visits per call, 2-second delay, max 1,500 req per 5-min window (stays well under Jobber's 2,500 / 5-min).
5. Trigger via `curl` or a one-shot script; run overnight.

---

## 7. Daily / weekly ops checks

### Daily (automatable, 5 min)

```sql
-- 1. Webhook pulse — all three sources should be live
SELECT source_system, COUNT(*) FILTER (WHERE status='processed') AS ok,
       COUNT(*) FILTER (WHERE status='failed') AS failed,
       MAX(created_at) AS last_seen
FROM webhook_events_log
WHERE created_at > NOW() - INTERVAL '24 hours'
GROUP BY source_system;

-- 2. Token health
SELECT source_system, expires_at, now() > expires_at AS expired
FROM webhook_tokens;

-- 3. Late clients (operationally critical)
SELECT COUNT(*) FROM clients_due_service WHERE status IN ('Late','Critical');
```

### Weekly (5 min)

```sql
-- 1. FK integrity sweep — should all return 0
SELECT 'orphan visits' AS check, COUNT(*)
FROM visits v LEFT JOIN clients c ON c.id = v.client_id
WHERE c.id IS NULL
UNION ALL
SELECT 'orphan visit_assignments', COUNT(*)
FROM visit_assignments va LEFT JOIN visits v ON v.id = va.visit_id
WHERE v.id IS NULL
UNION ALL
SELECT 'orphan manifest_visits', COUNT(*)
FROM manifest_visits mv LEFT JOIN derm_manifests m ON m.id = mv.manifest_id
WHERE m.id IS NULL;

-- 2. entity_source_links coverage (entities missing their source ID)
SELECT 'clients without jobber link' AS check, COUNT(*)
FROM clients c
WHERE NOT EXISTS (
  SELECT 1 FROM entity_source_links esl
  WHERE esl.entity_type = 'client' AND esl.entity_id = c.id AND esl.source_system = 'jobber'
);
```

### Monthly (~15 min)

- Rotate any quarterly-due secrets (see [security.md](security.md#routine-quarterly)).
- Review `webhook_events_log` retention — trim rows older than 90 days if table is bloated.
- Review row counts vs. source systems (spot-check 10 clients, 10 visits, 10 invoices).
- Review open items in this runbook — anything still blocked after 30 days gets escalated to Fred + Viktor.

---

## 8. Incident log

Documented incidents for future learning. Add a row when something breaks and gets fixed.

| Date | Incident | Root cause | Fix | Prevention |
|---|---|---|---|---|
| 2026-04-14 | `vehicle_fuel_readings.fuel_gallons` was a stored 3NF violation | Pre-standing-check design | Dropped column, renamed table to `vehicle_telemetry_readings`, added view | [ADR 005](decisions/005-3nf-standing-check.md) |
| 2026-04-15..19 | Daily-sync GitHub workflow red for 5 consecutive days | `JOBBER_ACCESS_TOKEN` GH Secret drift — workflow refreshes token in-memory but can't self-update secrets | Deleted workflow (`5253c2b`); webhooks cover the real-time path | [ADR 001](decisions/001-webhooks-over-cron.md) |
| 2026-04-20 | GitHub PAT `ghp_cPxzQL...` embedded in `.git/config`, exposed via `git remote -v` | Initial `git init` used token-in-URL auth | Stripped PAT from remote URL; moved to `gh auth login` keyring | [security.md](security.md#rules-non-negotiable) rule 2 |
| 2026-04-20 | `visits.is_complete`, `service_configs.{next_visit, status}` were stored derived columns | Pre-standing-check design; columns created before 3NF enforcement was explicit | Dropped columns, rebuilt 5 dependent views with inline derivations | [ADR 010](decisions/010-drop-stored-derived-columns.md) |
| 2026-04-20 | 132 clients had `status = 'Recuring'` (typo, missing 'r') | Airtable-sourced typo, propagated via populate.js | Normalized to `RECURRING`; views updated to canonical spelling | Add a CHECK constraint or status enum in future |
| 2026-04-20 | Photo architecture fragmented across `visit_photos`, `inspection_photos`, and inline `properties.location_photo_url` | Before/after treated as intrinsic to the photo (it isn't — it's a link attribute) | Unified to `photos` + `photo_links` polymorphic pair, superseding [ADR 008](decisions/008-photos-normalized-out.md) | [ADR 009](decisions/009-unified-photos-architecture.md) |
| 2026-04-20 | Jobber notes GraphQL query with `first: 50` + `fileAttachments { url }` rejected by Jobber with THROTTLED (requested cost ~25k > 10k budget ceiling) — never executed | Jobber's cost calculator multiplies page_size × nested-field-count and rejects queries with requested_cost > max_budget | Lowered `NOTES_PAGE_SIZE` to 10 (requested ~5k, actual ~50). Documented in extractor header comment. | Any future deep query: estimate requested cost before production use (fetch small page first, check `extensions.cost.requestedQueryCost`) |
| 2026-04-20 | Jobber `JobNoteUnion.nodes` returned the same ClientNote surfaced via both `client.notes` and `job.notes` connections | Jobber's JobNoteUnion `possibleTypes` includes ClientNote — inherited client notes show up on each job | Dedup by `note.id` in `fetchJobberClientNotes` using a Set | Always dedupe when a GraphQL Union type could surface the same node via multiple paths |
| 2026-04-20 | Supabase Storage bucket rejected >50 MB videos with HTTP 413 (bucket set at 500 MB but Pro plan caps it at 50 MB) | Supabase Pro hard-caps bucket `file_size_limit` at 50 MB — the PUT on /storage/v1/bucket/{name} silently rejects larger values without updating | Track oversized files in `jobber_oversized_attachments` with signed Jobber URL + metadata. Deferred recovery. | Before assuming a config limit is honored, verify via GET after PUT |
| 2026-04-20/21 | Jobber migration script crashed twice on `getaddrinfo ENOTFOUND api.supabase.com` | Transient DNS resolution spikes on Cloudflare-served Supabase Management API hostname | Idempotency via `entity_source_links` made both crashes zero-data-loss; resumed from `sync_cursors` checkpoint each time | Long-running scripts that write frequently need DNS-retry logic or a resumable cursor (this one had the cursor, so recovery was ~1 line of code: reset + `--resume`) |
| 2026-04-21 | Jobber migration hung silently for 3+ hours mid-client after ECONNRESET errors | The `https.request` calls had no `setTimeout` — a half-closed TCP connection kept the promise pending forever | Added 120 s timeout to `httpRequest` helper via `req.setTimeout(ms, () => req.destroy(...))`. Caught by per-note try/catch. | Any production script making outbound HTTPS must set an explicit socket timeout. Node's default is infinite. |
| 2026-04-21 | Jobber notes+photos migration complete | — | 1,853 notes + 8,019 files (9.3 GB) migrated from 221/373 Jobber clients. 35 oversized (>50 MB) logged for recovery. Zero integrity failures. | See [`docs/jobber-migration-techlead-summary.md`](jobber-migration-techlead-summary.md) |

*Add new rows in chronological order. Keep the "Prevention" column actionable — what procedural change prevents a repeat?*
