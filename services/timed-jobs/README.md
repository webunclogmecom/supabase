# Timed jobs on Railway (project "UnclogMe Timed Jobs")

The scheduled jobs that GitHub ran unreliably (every 4 to 8 hours, whatever the cron said) move here, one
Railway **cron service per schedule**. Decision log: `docs/audits/2026-10-07_timed_jobs_move.md`.

- **Project:** UnclogMe Timed Jobs, workspace Unclogme (id `0488911d-3f3d-414b-8783-89234f808513`). Kept
  apart from `UnclogMe Backups` on purpose: these jobs hold the service-role key, the backups hold every copy
  of the data, and nobody should get both from one project. Who administers it is recorded in the team's
  private access register, not in this public repo.
- **Every service** deploys from `webunclogmecom/supabase`, branch `main`, repo root. Its settings (start
  command, cron in UTC, watch paths, restart policy NEVER, builder) live in **`services.json`** here and are
  pushed with **`node services/timed-jobs/apply.js`** (shows drift, exit 1) / **`--apply`** (writes it).
  Change the file, then apply; never edit those settings in the dashboard, or the next apply reverts them.
  ⚠ Not `railway.json`: Railway deprecated it (refused for new services, unread after 2026-12-01), and its
  replacement `.railway/railway.ts` cannot express cron, watch paths or restart policy yet (2026-10-07).
- **Every command runs through `scripts/sync/run_logged.js <source>`**, which writes one `public.sync_log` row
  per run (success or error, exit code, duration, stderr tail) and kills a run that passes `RUN_TIMEOUT_MIN`
  (Railway has no timeout, and a run that never exits blocks every later run of its service). Test:
  `node scripts/sync/run_logged.test.js`.
- **Health:** each service's source is added to the watched list in `log_jobber_sync_health` at its own
  cut-over, not before (an empty source would read stale on day one). The two Samsara services also have their own
  watchdog every 10 minutes (`public.log_samsara_feed_health`, `2026-10-15_2230`) that emails Fred at once when one
  stops storing data, and since `2026-10-16_0945` presses Railway "Run now" by itself when one has not run for 15
  minutes (a Railway PROJECT token for this project's production environment, in the Supabase vault secret
  `railway_timed_jobs_token`; a person creates it, the session's Railway login may not). Retry, catch-up, fallback and the guards on the jobs that use the data:
  `docs/reference/samsara-feeds-resilience.md`.
- **"Deploy Crashed" email from Railway** = one cron RUN exited non-zero (the deployment itself stays COMPLETED; the
  run is red in Cron Runs, times in CEST). Read that run's `sync_log` row before touching the deploy.

## Services

| service | config | cron (UTC) | source | variables | status |
|---|---|---|---|---|---|
| samsara-gps | `services.json` | `*/5 * * * *` | `railway_samsara_gps` | SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SAMSARA_API_TOKEN, AUTO_LOOKBACK_H=168 (since 2026-10-16; a week takes ~16 s), RUN_TIMEOUT_MIN=30 | live since 2026-10-07 12:15 ET; sole runner since 2026-10-08 10:48 ET (GitHub schedule removed); health-watched at 30 min; watchdog every 10 min + manual fallback workflow "Samsara GPS (fallback)" (2026-10-16) |
| samsara-readings | `services.json` | `*/5 * * * *` | `railway_samsara_readings` | SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SAMSARA_API_TOKEN, RUN_TIMEOUT_MIN=10 | created 2026-10-12 (tank sensors on Moises + truck RPM/PTO/geofence events, plan `docs/superpowers/specs/2026-10-12-samsara-tank-sensors-db-plan.md`); history from 2026-08-20 backfilled locally the same day (sync_log 77921 = the resume point); live on Railway since 2026-10-12 ~17:10 ET (secrets set by Fred); health-watched at 30 min (`2026-10-12_2120`); watchdog every 10 min + manual fallback workflow "Samsara tank readings (fallback)" (2026-10-16) |

Planned next (plan section 3.3): note-photo, notes-import (temporary), jobber-visit-nightly.

## Secrets

Values are never in this repo. They are copied from `Supabase/.env` into the service's Railway variables by
a person (the Claude sessions do not type secrets), with `node services/timed-jobs/set-secrets.js <service> KEY ...`
run from the `Supabase` folder (works in PowerShell; values go to the Railway CLI on stdin and are never printed).
Give each service only the variables in its row.

🛑 **Since 2026-10-22 (Railway breach rotation) Railway's `SUPABASE_SERVICE_ROLE_KEY` is NOT the legacy service-role
JWT.** It is the Supabase secret key named "railway" (`sb_secret_`), kept in `Supabase/.env` as
`SUPABASE_RAILWAY_SECRET_KEY`, so set it with
`node services/timed-jobs/set-secrets.js <service> SUPABASE_SERVICE_ROLE_KEY=SUPABASE_RAILWAY_SECRET_KEY`.
A plain `SUPABASE_SERVICE_ROLE_KEY` would copy the legacy key back. `SAMSARA_API_TOKEN` was replaced the same day.
Record: `docs/audits/2026-10-22_railway_breach_rotation.md`.

## Rollback and fallback

For 2 weeks after a cut-over the old GitHub workflow keeps its manual button (`workflow_dispatch`) with the
schedule removed. To roll back: put the `schedule:` back in that file and pause the Railway service.
The two Samsara services keep a GitHub workflow for good, as the FALLBACK RUNNER (manual, run through
`run_logged.js` under `github_samsara_gps` / `github_samsara_readings`): `samsara-locations-history.yml` ("Samsara GPS
(fallback)", not deleted on 2026-10-22 as first planned) and `samsara-readings-fallback.yml`.
