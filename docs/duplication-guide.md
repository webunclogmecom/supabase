# Duplication Guide — clone this project to a new Supabase

**For:** when you need to spin up a parallel environment (staging, demo, fresh customer, disaster recovery test).
**Audience:** a competent engineer with no prior context on this codebase.
**Time:** 2–4 hours end-to-end depending on Jobber/Airtable/Samsara availability.

This guide is the **counterpart to [`onboarding.md`](onboarding.md)**: onboarding is "join the existing project," this is "stand up a fresh one."

---

## What you'll have at the end

- A new Supabase project running the same 28-table 2NF/3NF schema, all 7 public views + 8 ops views, RLS enabled, security_invoker on all views, all FK indexes in place.
- 3 Edge Functions deployed (`webhook-jobber`, `webhook-airtable`, `webhook-samsara`).
- Webhook subscriptions registered with Jobber, Samsara, and Airtable.
- Initial data populated from Jobber + Airtable + Samsara + Fillout.
- Cross-session token sync helper working.
- All 4 source systems live-syncing.

---

## Prerequisites

| Item | Why | How to get |
|---|---|---|
| Node ≥ 20 | every script is Node | nodejs.org |
| `gh` CLI authed | repo clone, releases | `gh auth login` |
| Supabase CLI | Edge Function deploy + secret mgmt | `npm i -g supabase` |
| Supabase account + new project | the destination | Pro plan ($25/mo) — Free is too small |
| Jobber Developer account | OAuth app | developer.getjobber.com |
| Samsara API token (Webhooks-write scope) | webhook registration | Samsara dashboard → Admin → API Tokens |
| Airtable PAT with read access to the Unclogme base | data pulls | airtable.com/create/tokens |
| Fillout API key | inspection forms (optional — can be skipped) | fillout.com → Account → API |

---

## Phase 1 — Repo + secrets (15 min)

```
gh repo clone webunclogmecom/supabase unclogme-supabase
cd unclogme-supabase
npm install
cp .env.example .env
```

Open `.env` and fill in:

| Var | Where it comes from |
|---|---|
| `SUPABASE_URL`, `SUPABASE_PROJECT_ID` | New project's dashboard URL |
| `SUPABASE_SERVICE_ROLE_KEY` | Project Settings → API → service_role (reveal) |
| `SUPABASE_PAT` | https://supabase.com/dashboard/account/tokens |
| `JOBBER_CLIENT_ID`, `JOBBER_CLIENT_SECRET` | Jobber Developer Center → your new app |
| `JOBBER_REDIRECT_URI` | `http://localhost:3000/callback` for dev |
| `SAMSARA_API_TOKEN` | Samsara → API Tokens (must have Webhooks write scope) |
| `AIRTABLE_API_KEY`, `AIRTABLE_BASE_ID` | airtable.com/create/tokens (PAT with `data.records:read`); base ID from any Airtable URL |
| `AIRTABLE_WEBHOOK_TOKEN` | A long random string you generate. Set to same value in Supabase secrets later. |
| `FILLOUT_API_KEY`, `FILLOUT_PRESHIFT_FORM_ID`, `FILLOUT_POSTSHIFT_FORM_ID` | Fillout dashboard → API + form IDs |

Verify:
```
npm run probe   # or: node scripts/probe.js
```
If green, you can talk to the destination Supabase + Jobber API.

---

## Phase 2 — Schema (10 min)

The schema lives in two places that need to be applied **in this order** to a fresh DB:

### 2.1 — Apply the canonical schema

```
psql "postgres://postgres.<project_id>:<service_role_key>@aws-0-<region>.pooler.supabase.com:5432/postgres" \
  -f schema/v2_schema.sql
```

Or use the Supabase Dashboard → SQL Editor → paste the file contents → Run.

This creates: 28 business tables + `entity_source_links` + `webhook_events_log` + `webhook_tokens` + `sync_cursors` + the 7 `public.*` views and the 8 `ops.*` views.

### 2.2 — Apply post-schema migrations in this order

These migrations were applied to the live DB after `v2_schema.sql` and have not been folded back. **Run them sequentially** — order matters because some depend on others:

| # | File | Why |
|---|---|---|
| 1 | `scripts/migrations/3nf_drop_derived_columns.sql` | Removes columns that violated 3NF; replaces with views |
| 2 | `scripts/migrations/3nf_telemetry_readings.sql` | Splits Samsara telemetry into normalized table |
| 3 | `scripts/migrations/normalize_client_status_recuring.sql` | Cleans `status` enum |
| 4 | `scripts/migrations/split_grease_and_fuel_tanks.sql` | Vehicles get separate tank capacity columns |
| 5 | `scripts/migrations/add_vehicle_fuel_readings.sql` | Telemetry helper table |
| 6 | `scripts/migrations/add_notes_table.sql` | Jobber notes container |
| 7 | `scripts/migrations/add_jobber_oversized_attachments.sql` | Tracking for >50 MB files |
| 8 | `scripts/migrations/unified_photos_architecture.sql` | photos + photo_links polymorphic (replaces v1 visit_photos / inspection_photos) |
| 9 | `scripts/migrations/drop_properties_location_photo_url.sql` | Removes the 2NF violation we found post-migration |
| 10 | `scripts/migrations/fix_v2_view_status_strings.sql` | View definitions match new status enum |
| 11 | `scripts/migrations/enable_rls_security_fix.sql` | RLS on all 7 public tables that lacked it |
| 12 | `scripts/migrations/fix_security_definer_views.sql` | Public views: `security_invoker = true` |
| 13 | `scripts/migrations/fix_function_search_path.sql` | Pin `trg_set_updated_at` search_path |
| 14 | `scripts/migrations/audit_fixes_2026_04_27.sql` | ops.* views security_invoker + missing FK indexes |

Skip these (DB-state-specific, not migration-applicable):
- `create_viktor_readonly_role.sql` / `drop_viktor_readonly_role.sql` — historical exploration, no longer used
- `dedup_jobber_links.js` — script that fixes a one-time data-format mismatch from a buggy webhook deploy. A fresh DB never has the bug.

You can apply them in one shot:

```bash
for f in 3nf_drop_derived_columns 3nf_telemetry_readings normalize_client_status_recuring \
         split_grease_and_fuel_tanks add_vehicle_fuel_readings add_notes_table \
         add_jobber_oversized_attachments unified_photos_architecture \
         drop_properties_location_photo_url fix_v2_view_status_strings \
         enable_rls_security_fix fix_security_definer_views \
         fix_function_search_path audit_fixes_2026_04_27; do
  psql "$PG_URL" -f "scripts/migrations/$f.sql" || break
done
```

Verify:
```bash
node -e "
const {newQuery} = require('./scripts/populate/lib/db');
(async () => {
  const r = await newQuery(\`SELECT 'tables' AS m, count(*)::text AS v FROM pg_tables WHERE schemaname='public'
    UNION ALL SELECT 'views', count(*)::text FROM pg_views WHERE schemaname='public'
    UNION ALL SELECT 'ops_views', count(*)::text FROM pg_views WHERE schemaname='ops'
    UNION ALL SELECT 'rls_disabled', count(*)::text FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r' AND c.relrowsecurity=false;\`);
  console.table(r);
})();
"
```

Expected: `tables=30, views=7, ops_views=8, rls_disabled=0`.

---

## Phase 3 — Edge Functions (10 min)

```bash
npx supabase login                                                # interactive
npx supabase link --project-ref $SUPABASE_PROJECT_ID

# Deploy all 3 functions
for f in webhook-jobber webhook-samsara webhook-airtable; do
  npx supabase functions deploy "$f" --project-ref "$SUPABASE_PROJECT_ID" --no-verify-jwt
done
```

Set Edge Function secrets (read by the deployed functions at runtime):

```bash
npx supabase secrets set --project-ref "$SUPABASE_PROJECT_ID" \
  JOBBER_WEBHOOK_SECRET="$JOBBER_CLIENT_SECRET" \
  AIRTABLE_WEBHOOK_TOKEN="$AIRTABLE_WEBHOOK_TOKEN" \
  SAMSARA_WEBHOOK_SECRETS=""  # empty for now; populated by reset_samsara.js
```

Note: `JOBBER_WEBHOOK_SECRET` is the OAuth `client_secret` itself — Jobber signs webhooks with HMAC-SHA256(body, client_secret). There is no separate "webhook signing secret."

---

## Phase 4 — External system setup (60–90 min)

### 4.1 — Jobber OAuth app + webhooks (~30 min)

1. **In Jobber Developer Center**, create a new app:
   - Name: e.g. "Unclogme Sync (staging)"
   - Callback URL: `http://localhost:3000/callback`
   - Scopes: read_clients, read_requests, read_quotes, read_jobs, read_scheduled_items, read_invoices, read_jobber_payments, read_users, read_expenses, read_custom_field_configurations, read_time_sheets, read_equipment, write_tax_rates, write_custom_field_configurations
   - **Refresh token rotation: OFF** — rotation causes cross-session breakage we don't want.
   - Webhooks: subscribe to all 22 topics listed in [`docs/integration.md`](integration.md).
2. Copy the new Client ID + Client secret to `.env`.
3. **Run OAuth bootstrap** with the Jobber account owner present:
   ```
   node scripts/jobber_auth.js
   ```
   This opens a browser, owner clicks Allow, tokens land in `.env`.
4. **Sync tokens to DB:**
   ```
   node scripts/sync/jobber_token.js
   ```
   This populates `webhook_tokens` so the Edge Function can read the access token.

### 4.2 — Samsara webhook registration (~10 min)

```bash
node scripts/webhooks/reset_samsara.js --execute
```

This deletes any existing Unclogme webhooks (matches our Edge Function URL only — won't touch unrelated webhooks), creates 6 fresh ones, and prints the comma-joined `secretKey` values. Copy those secrets into Supabase:

```bash
npx supabase secrets set --project-ref "$SUPABASE_PROJECT_ID" \
  SAMSARA_WEBHOOK_SECRETS="<paste comma-joined secrets here>"
```

### 4.3 — Airtable automations (~30 min)

Follow [`docs/airtable-automation-setup.md`](airtable-automation-setup.md) — create 10 automations (5 tables × 2 trigger types each). Verify each by clicking the Test button; a `POST 200` response means it's live.

### 4.4 — Fillout (optional, ~5 min)

If you need pre/post inspection sync, set the form IDs in `.env`. The current setup pulls inspections from **Airtable** instead (the `PRE-POST insptection` table) — Fillout is a fallback path that's currently inactive.

---

## Phase 5 — Initial data load (30–60 min depending on volume)

### 5.1 — Fetch Jobber → raw cache

```
node scripts/sync/incremental_sync.js --execute --since=2020-01-01
```

This populates `raw.jobber_pull_*` from the Jobber GraphQL API. Expect ~5,000 rows total across clients/jobs/visits/invoices/quotes/users/properties.

### 5.2 — Run populate

```
node scripts/populate/populate.js --execute --confirm
```

This is the **one-shot** orchestrator: pulls live Airtable + Samsara + Fillout in memory, joins with Jobber raw cache via name + entity_source_links, and inserts into all 28 business tables in dependency order.

It's **non-idempotent** and refuses to run on a non-empty `clients` table — use `--truncate` to wipe first if you need to re-run.

### 5.3 — Backfill via webhook handlers (optional)

For maximum FK accuracy on visits/jobs/invoices/quotes, replay raw rows through the live Edge Function:

```
node scripts/sync/replay_to_webhook.js --execute
```

This re-fetches each entity from Jobber GraphQL and re-upserts via the same code path live webhooks use. Catches any FK gaps `populate.js` couldn't resolve via name match.

### 5.4 — Migrate Jobber notes + photos (15–60 min depending on volume)

```
node scripts/migrate/jobber_notes_photos.js --execute
```

Iterates all 373 Jobber clients, pulls every note attachment + visit note, downloads to Supabase Storage. Files >50 MB are logged to `jobber_oversized_attachments` (handle separately per ADR 009 — Cloudflare R2 is the recommended landing pad).

---

## Phase 6 — Verify (10 min)

```bash
node scripts/migrate/verify_jobber_migration.js                # photo/note integrity
node -e "
const {newQuery} = require('./scripts/populate/lib/db');
(async () => {
  const r = await newQuery(\`SELECT 'clients' tbl, count(*)::int n FROM clients
    UNION ALL SELECT 'visits', count(*)::int FROM visits
    UNION ALL SELECT 'invoices', count(*)::int FROM invoices
    UNION ALL SELECT 'photos', count(*)::int FROM photos
    UNION ALL SELECT 'notes', count(*)::int FROM notes
    UNION ALL SELECT 'webhook_events', count(*)::int FROM webhook_events_log;\`);
  console.table(r);
})();
"
```

Expected (will vary based on source-system state): clients ~400, visits ~5000, invoices ~1600, photos ~8000, notes ~1900.

Trigger a real edit in each source system → verify a row lands in `webhook_events_log` with `status='processed'` within 30s. If yes, you're fully live.

---

## Phase 7 — GitHub Actions automation (10 min)

Two workflows live in `.github/workflows/`. Both need the same 5 GitHub Actions secrets.

### 7.1 `jobber-poll.yml` — Jobber polling fallback (every 2 min)
Pulls Jobber deltas + replays through `webhook-jobber`. Required because Jobber's webhook delivery is unreliable for In-Development apps. See ADR 009.

### 7.2 `daily-cleanup.yml` — DB hygiene (09:00 UTC daily)
Two jobs in one script (`scripts/sync/daily_cleanup.js`):
- DELETE `webhook_events_log` rows older than 30 days (~700 MB/year savings).
- Clear `needs_populate=TRUE` on `raw.jobber_pull_*` rows that have failed for 7+ days due to deleted-in-Jobber records (stops cron from retrying dead rows).

### Setup — add 5 GH secrets

```bash
gh secret set -f .env  # uploads all .env vars; or set the 5 below individually:
# SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_PAT,
# JOBBER_CLIENT_ID, JOBBER_CLIENT_SECRET
```

Trigger first run manually:
```bash
gh workflow run jobber-poll.yml
gh workflow run daily-cleanup.yml
```

Expected: both complete in ~60–90s. Then they fire on schedule.

---

## What's documented elsewhere

| Topic | See |
|---|---|
| Why decisions were made | [`docs/decisions/`](decisions/) — 9 ADRs |
| Operational gotchas (column names, overnight shifts, truck-vs-person names) | [`docs/operations.md`](operations.md) |
| Day-to-day runbook (how to fix a stuck sync, etc.) | [`docs/runbook.md`](runbook.md) |
| Schema details + 3NF rationale | [`docs/schema.md`](schema.md) |
| Webhook flow + signature verification | [`docs/integration.md`](integration.md) |
| Security posture (RLS, secrets, rotation) | [`docs/security.md`](security.md) |
| Jobber/Airtable May-2026 sunset plan | [`docs/migration-plan.md`](migration-plan.md) |

---

## Known papercuts (would-improve-but-not-blocking)

1. **No automatic migration tracking.** We don't have a `_migrations` table that records which `.sql` files have run. If you re-apply, you may get "already exists" errors. Most migrations are written `IF NOT EXISTS`-style for idempotency, but not all. Always test on a throwaway DB first.
2. **`populate.js` is a one-shot tool**, not a sync engine. After initial load, ongoing changes flow through Edge Functions + webhooks, not populate.
3. **Some scripts assume Windows paths** (Fred's machine). Cross-platform-compat is good but not exhaustively tested.
4. **The 3 source systems each have different live-sync mechanisms** — Jobber webhooks (intermittent — see ADR 009), Airtable automations, Samsara webhooks. A consolidating wrapper would be nice but doesn't exist.

---

*If you find a gap while following this guide, **update this file in the same PR**. The guide is only useful if it stays accurate.*
