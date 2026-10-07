# Timed jobs on Railway (project "UnclogMe Timed Jobs")

The scheduled jobs that GitHub ran unreliably (every 4 to 8 hours, whatever the cron said) move here, one
Railway **cron service per schedule**. Decision log: `docs/audits/2026-10-07_timed_jobs_move.md`.

- **Project:** UnclogMe Timed Jobs, workspace Unclogme (id `0488911d-3f3d-414b-8783-89234f808513`). Kept
  apart from `UnclogMe Backups` on purpose: these jobs hold the service-role key, the backups hold every copy
  of the data, and nobody should get both from one project. 2FA on and two admins (web@unclogme.com,
  fred@ayache.com) since 2026-10-07.
- **Every service** deploys from `webunclogmecom/supabase`, branch `main`, repo root, and reads its settings
  from its own file here (Railway setting "Config file path"): start command, cron (UTC only), watch paths,
  restart policy NEVER. Change the file, not the dashboard.
- **Every command runs through `scripts/sync/run_logged.js <source>`**, which writes one `public.sync_log` row
  per run (success or error, exit code, duration, stderr tail) and kills a run that passes `RUN_TIMEOUT_MIN`
  (Railway has no timeout, and a run that never exits blocks every later run of its service). Test:
  `node scripts/sync/run_logged.test.js`.
- **Health:** each service's source is added to the watched list in `log_jobber_sync_health` at its own
  cut-over, not before (an empty source would read stale on day one).

## Services

| service | config | cron (UTC) | source | variables | status |
|---|---|---|---|---|---|
| samsara-gps | `samsara-gps.railway.json` | `*/5 * * * *` | `railway_samsara_gps` | SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SAMSARA_API_TOKEN, AUTO_LOOKBACK_H=48, RUN_TIMEOUT_MIN=30 | being set up 2026-10-07 |

Planned next (plan section 3.3): note-photo, notes-import (temporary), jobber-visit-nightly.

## Secrets

Values are never in this repo. They are copied from `Supabase/.env` into the service's Railway variables by
a person (the Claude sessions do not type secrets). Give each service only the variables in its row.

## Rollback

For 2 weeks after a cut-over the old GitHub workflow keeps its manual button (`workflow_dispatch`) with the
schedule removed. To roll back: put the `schedule:` back in that file and pause the Railway service.
