# Timed jobs move: GitHub schedules to pg_cron and Railway (decision log, started 2026-10-07)

**Why:** since 2026-08-27 GitHub runs our scheduled workflows only every 4 to 8 hours, whatever their
cron says (measured with `gh run list`). Samsara GPS and the audit Slack alerts are hours stale because
of it. The full plan (every job, merges, cut-over order) is in the workspace-root folder
`system-audit-2026-10-05/TIMED_JOBS_PLAN.md`, which is local only; this file is its versioned record of
what was decided and what shipped.

## Decisions (Fred)

| date | question | answer |
|---|---|---|
| 2026-10-07 | the 14 open questions in the plan, section 6 | "Yes to all defaults" |
| 2026-10-07 | where the Railway jobs live | "put the timed jobs in a separate railway project" |

What the defaults mean, in short: delete the FOG PDF generator and the no-photo alert; webhook log kept
30 days; audit alerts to Slack for hard deletes, the daily health email for the rest; Samsara stats
merged into the GPS job; the duplicate-address list kept as an acknowledgeable health item; GPS may fill
the truck only on dump visits that have none; `cron_jobber.js --full` archived; Postman copy of the API
docs is enough once the repo goes private; bridging jobs on Railway is allowed.

## The Railway home: project "UnclogMe Timed Jobs"

Created 2026-10-07 in the Unclogme workspace (id `0488911d-3f3d-414b-8783-89234f808513`). It is
deliberately NOT inside:

- `UnclogMe Backups` (service `db-backup`): it holds only a read-only database login plus a copy of all
  the data. The timed jobs need the service-role key, which can write anything. One project would give
  anyone with access to either both the write key and every copy.
- `unclogme-gdo-report-bot`: another person is a member.
- `Unclogme - Microservices`: holds the AI keys.

Same cost either way (Railway bills per service). Each job is its own cron service with a
`railway.json` versioned in this repo, run through the logging runner described in the plan (3.6).
Before any secret goes in: 2FA on the Railway login and a second named admin (audit SECURITY-15), which
are Fred's to do.

## What shipped

| step | commit | what |
|---|---|---|
| 0.1, 0.3, 0.4, 0.5 | `00e3adf` | 11 dead or failing workflows deleted with their scripts (2 archived) |
| 0.2 | `655408e` | GitHub token keepalive retired; `sync-jobber-poll` (v32) refreshes the read token 10 minutes before expiry; `log_jobber_sync_health` stops watching it (migration `2026-10-07_1130`) |
| docs | `2fc0942`, Building Apps `f58cde9` | live docs and comments point at the pg_cron jobs that replaced the retired ones |
| 1 | `4ca82b2` | daily cleanup moved into pg_cron `daily-cleanup` (job 125, 03:00 UTC) -> `public.fn_daily_cleanup()` (migration `2026-10-07_1138`); replaces job 2; GitHub schedule removed, manual button kept until 2026-10-21. First run by hand: 2,626 log rows over 30 days deleted, the 2 stuck visit flags cleared |

**0.2 verified live:** the read token was due to expire at 11:38 ET; the 11:36 poll refreshed it (new
expiry 12:36). Check left for 2026-10-14: zero `jobber_job_drift` rows with "HTTP 401" in the week.
The poll had also read `partial` on every run since 01:41 UTC because 2 deleted visits kept failing their replay; step 1's first cleanup cleared them.

## Next, in the plan's order

1. ~~daily-cleanup into pg_cron~~ done 2026-10-07.
2. Railway setup. Done 2026-10-07 except the secrets: 2FA on both logins and a second admin
   (fred@ayache.com), per Fred; runner `scripts/sync/run_logged.js` (`1b22b76`, kill timer tested live);
   settings in `services/timed-jobs/services.json` applied by `apply.js` (`6771a65`; Railway refuses
   railway.json for new services and its new format cannot express cron yet); `set-secrets.sh`
   (`f5d5c4a`). Service `samsara-gps` exists with its settings; its three secrets are Fred's to set.
   Change from the plan: each source joins the health watch list at its own cut-over, not all four now.
3. Then Samsara GPS, driver photos, the 14-day completion check, the nightly Jobber visit check, truck
   from GPS, audit alerts, Samsara stats, notes import, and the last four Supabase moves.
