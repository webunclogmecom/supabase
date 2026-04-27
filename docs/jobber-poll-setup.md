# Jobber polling cron — first-run setup

**Why this exists:** Jobber's webhook delivery for our In-Development app is unreliable (verified empirically: edits in Jobber → zero webhook events at our endpoint). This cron polls Jobber every 2 minutes via GitHub Actions and replays results through the same `webhook-jobber` Edge Function — DB stays at most 2 min stale, regardless of webhook reliability. Detailed rationale in [ADR 009](decisions/009-oversized-storage-and-jobber-webhooks.md).

**Removable:** if Jobber support resolves the webhook issue, just disable or delete `.github/workflows/jobber-poll.yml`. Nothing else changes — webhook-jobber stays the same code path.

---

## Required GitHub Actions secrets

Set in `Settings → Secrets and variables → Actions → New repository secret`:

| Secret | Value source | Notes |
|---|---|---|
| `SUPABASE_URL` | `.env` line | `https://wbasvhvvismukaqdnouk.supabase.co` |
| `SUPABASE_SERVICE_ROLE_KEY` | `.env` line | service-role JWT (long string starting `eyJ...`) |
| `SUPABASE_PAT` | `.env` line | Personal Access Token (`sbp_...`) — used by Management API to run SQL |
| `JOBBER_CLIENT_ID` | `.env` line | OAuth app's client_id (UUID) |
| `JOBBER_CLIENT_SECRET` | `.env` line | OAuth app's client_secret (also serves as webhook HMAC key) |

The cron does **not** need `JOBBER_ACCESS_TOKEN` or `JOBBER_REFRESH_TOKEN` in GitHub — it reads them from `public.webhook_tokens` at runtime and writes back any refreshes there. The DB is the single source of truth for tokens.

### Quick add via gh CLI

If you have `gh` authenticated and the Supabase repo is the working directory:

```bash
# Source the local .env to populate shell vars
set -a && . ./.env && set +a

# Set each secret in GitHub
gh secret set SUPABASE_URL --body "$SUPABASE_URL"
gh secret set SUPABASE_SERVICE_ROLE_KEY --body "$SUPABASE_SERVICE_ROLE_KEY"
gh secret set SUPABASE_PAT --body "$SUPABASE_PAT"
gh secret set JOBBER_CLIENT_ID --body "$JOBBER_CLIENT_ID"
gh secret set JOBBER_CLIENT_SECRET --body "$JOBBER_CLIENT_SECRET"
```

Verify:
```bash
gh secret list
```
You should see the 5 names + their last-updated timestamps.

---

## Verifying the workflow

After secrets are set + the workflow file is in `main` branch:

1. **Manual trigger** to confirm it runs cleanly:
   ```bash
   gh workflow run jobber-poll.yml
   gh run watch
   ```
   Wait for "completed", then check the run log. Expect ~60–120s runtime, output like:
   ```
   [cron] start <ts>
   [cron] clients: pulled N, cursor → <ts>
   [cron] properties: pulled N, cursor → ...
   ...
   [cron] done in Ns — N rows pulled
   ```

2. **Confirm the DB updated:**
   ```sql
   SELECT entity, last_synced_at, rows_pulled, last_run_status
   FROM sync_cursors ORDER BY entity;
   ```
   `last_run_status` should be `success` and `last_synced_at` should be within the last few minutes.

3. **Watch ongoing runs** — the schedule fires every 2 minutes. View them in `Actions` tab; each run takes ~60–120s.

---

## Cost / quota

GitHub Actions on private repos: **2,000 min/mo free** for typical accounts.
Our cron: **~720 runs/day × ~90s avg = ~18 hours/day = ~540 min/day**.

That's over the free tier. **Two options:**

1. **Make the repo public** (free unlimited Actions) — but our repo contains config, not secrets, so this is safe.
2. **Reduce frequency to 5 min** — 288 runs/day × 90s = 432 min/day, still over free.
3. **Set frequency to 10 min** — 144 runs/day × 90s = 216 min/day = ~6,500 min/month — covered by paid tier ($0.008/min for Linux ≈ $52/month).
4. **Run on Cloudflare Workers Cron Triggers** — free, more performant.

**Recommendation:** **Make the repo public** if you're comfortable with that. Otherwise reduce schedule to `*/5 * * * *` (5 min) — still effectively-live for an ops business — and accept that you may exceed free tier. Can be tuned in `.github/workflows/jobber-poll.yml`.

The default cron in this repo is `*/2 * * * *`. **Change it before enabling if you want to control cost.**

---

## Operational concerns

| Concern | Mitigation |
|---|---|
| Token expiry mid-run | `cron_jobber.js` refreshes if expiring within 60s, writes new tokens back to DB before any GraphQL call |
| Concurrent runs | Workflow uses `concurrency: jobber-poll` group + `cancel-in-progress: false` → newer queued runs wait for active to finish |
| Cursor drift on failure | Cursors are only advanced on successful entity pulls; failed pulls don't touch the cursor |
| Rate limits | Jobber allows 10k cost points / 10s. One full cycle uses ~50 points → ~0.5% of quota |
| GitHub Actions outage | Stops syncing during outage; recovers automatically — at most we lose 5–10 min of "freshness" |

---

## When you can delete this

Once Jobber's API support team resolves the webhook delivery issue and you've confirmed real webhooks arrive reliably (e.g. 24 hours of consistent delivery in `webhook_events_log`):

```bash
rm .github/workflows/jobber-poll.yml
git commit -am "Remove Jobber polling cron — webhooks now reliable"
git push
```

The Edge Function (`webhook-jobber/index.ts`) and the DB schema stay unchanged. The `cron_jobber.js` script can also stay in the repo as documentation / disaster-recovery tooling.
