<!-- ==========================================================================
PROVENANCE — everything below this block is JOHN'S DOCUMENT, VERBATIM.
Received from John via Fred, 2026-07-29. Do not edit the body: it describes a
system we do NOT own (the RPA bot runs on John's Railway deployment). If it
drifts from reality, replace it with a newer copy from John rather than patching
it, and note the date here.

⚠ OUR SIDE OF THIS INTEGRATION, for orientation — the bot pulls work from and
reports back to OUR Supabase edge functions:
    supabase/functions/rpa-derm-queue    (bot fetches pending permits)
    supabase/functions/rpa-derm-result   (bot posts the outcome back)
  backend migration : docs/migrations/2026-07-21e_rpa_derm_portal_backend.sql
  briefings         : docs/handoffs/2026-07-23_gdo_bot_railway_briefing.md
                      docs/handoffs/2026-07-21_rpa_bot_reply_to_john.md
  audit attribution : writes land as app_source='gdo-report-bot' (machine actor,
                      not a person) — see CLAUDE.md ADR 016 section.
  evidence bucket   : storage `rpa-evidence` (PRIVATE — the only private bucket).

⚠ `RPA_BOT_KEY` below is the key John's bot uses against OUR Supabase functions,
so it is a shared secret between the two systems. `RUN_KEY`, `SHADOW_MODE`,
`SLACK_WEBHOOK_URL` etc. are John's side only.
========================================================================== -->

# UnclogMe GDO RPA Bot — Triggers & Run Conditions

> **Environment:** Railway (production) · `https://unclogmerpabot-production.up.railway.app`

---

## When does the bot run?

The bot has **3 trigger mechanisms**:

| # | Trigger | How | Frequency |
|---|---|---|---|
| 1 | **Manual / external webhook** | `POST /run` with `x-run-key` header | On-demand |
| 2 | **Automatic poll scheduler** | Internal background thread | Every 60 min |
| 3 | **Daily Slack digest** | Internal background thread | Daily at 8:00 AM EST |

---

## 1. Webhook `POST /run` (primary trigger)

The bot is triggered by an HTTP request:

```
POST https://unclogmerpabot-production.up.railway.app/run
Header: x-run-key: <RUN_KEY>
```

**Behavior:**
- Responds `202 Accepted` immediately (async).
- Runs in the background — non-blocking.
- If a run is already in progress, responds `409 Conflict`.

**Modes:**
| URL | Mode | Queue used |
|---|---|---|
| `POST /run` | **Live** — submits real permits to the DERM portal | Production queue (Supabase) |
| `POST /run?dry_run=true` | **Test/Shadow** — navigates to Preview screen, **does NOT click final Submit** | QA queue (25 test items) |

**Example (from terminal):**
```bash
# Live run
curl -X POST https://unclogmerpabot-production.up.railway.app/run \
     -H "x-run-key: YOUR_RUN_KEY"

# Dry run (test without submitting to the government portal)
curl -X POST "https://unclogmerpabot-production.up.railway.app/run?dry_run=true" \
     -H "x-run-key: YOUR_RUN_KEY"
```

---

## 2. Automatic Poll Scheduler (safety net)

- **Fires:** automatically every **60 minutes** while the container is running.
- **Purpose:** ensures no pending permit is missed if the webhook trigger fails.
- **Condition:** if a run is already active when its turn comes, it **skips** (no double runs).
- **Queue:** uses the **production queue** (live) — same as the webhook without `dry_run=true`.
- **Configurable:** via `POLL_INTERVAL_SECONDS` env var (default: `3600`).

---

## 3. Daily Slack Digest

- **Fires:** every day at **8:00 AM EST**.
- **Content:** summary of the **previous day's** activity (permits filed, errors, pending items).
- **Channel:** Slack (via Incoming Webhook configured in `SLACK_WEBHOOK_URL`).
- **Configurable:** via `DIGEST_HOUR` env var (default: `8`).

---

## Key Environment Variables

| Variable | Description |
|---|---|
| `SHADOW_MODE` | `true` → all runs are dry-run (no final Submit). `false` → live mode. |
| `RUN_KEY` | Secret key to authenticate the `POST /run` webhook. |
| `RPA_BOT_KEY` | Key to authenticate calls to the Supabase API. |
| `POLL_INTERVAL_SECONDS` | Poll scheduler interval (default: `3600` = 60 min). |
| `DIGEST_HOUR` | Hour of the Slack digest in EST (default: `8` = 8 AM). |
| `SLACK_WEBHOOK_URL` | Slack Incoming Webhook URL. |

---

## Conditions for the bot to process an item

The bot only processes a permit if **all** of the following conditions are met:

1. ✅ **Queue is not empty** — Supabase returns at least 1 pending item.
2. ✅ **Not a duplicate** — the `(gdo_permit, manifest_number)` pair does not already exist as `SUCCESS` or `TEST_SUCCESS` in the local audit log.
3. ✅ **Pre-flight validation passes** — the item has valid `gdo_number`, `service_date`, and `ticket_number`.
4. ✅ **Valid email on the portal** — the email field in DERM contains `contact@unclogme.com` or `fog@unclogme.com` (or is empty and the bot fills it in automatically).
5. ✅ **No active lock** — no other run is currently in progress (internal mutex).

---

## Health Check

```
GET https://unclogmerpabot-production.up.railway.app/health
```
Returns:
```json
{
  "status": "ok",
  "busy": false,
  "supabase": "connected"
}
```
