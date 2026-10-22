# Samsara feeds: retry, catch-up, watchdog, fallback, guards

Fred, 2026-10-16, after Railway mailed "Deploy Crashed" for samsara-readings (three runs had failed on one Samsara
HTTP 504): *"add the same retry to the GPS job too. And we need to have like a fallback or restart system for this
cases, because we also use this data."* Shipped the same night: Supabase migration
`docs/migrations/2026-10-15_2230_samsara_feed_watchdog_and_guards.sql` plus the collector code.

Two Railway cron services (project UnclogMe Timed Jobs, every 5 minutes, each through `scripts/sync/run_logged.js`,
one `public.sync_log` row per run) store the Samsara data everything else is built from:

| service | script | writes | sync_log source |
|---|---|---|---|
| samsara-gps | `scripts/sync/cron_samsara_locations_history.js` | `vehicle_telemetry_readings` (GPS points) | `railway_samsara_gps` |
| samsara-readings | `scripts/sync/cron_samsara_tank_readings.js` | tank sensor distance and percent, engine RPM, PTO, dump/yard site events | `railway_samsara_readings` |

## The five layers

1. **Retry inside a run.** Both scripts call Samsara through `scripts/lib/samsara_client.js`: 60 s timeout per request,
   429 / any 5xx / network error or timeout retried, 3 attempts (5 s then 10 s). A 4xx other than 429 is not retried.
   The GPS job's PostgREST calls have the same 60 s timeout (a hung socket used to block the service until
   run_logged's 30-minute kill, and Railway skips every run due while one is still running).
2. **Every run is a restart.** Railway starts a new run every 5 minutes, and each one begins where the last good one
   stopped, so a failed run or an outage is refilled by the next good run with nothing lost:
   - GPS: from the newest stored GPS-only point minus 30 min (late points are picked up), plus a 48 h deep pass once a
     day (a truck that uploads late after losing signal), up to 7 days back (`AUTO_LOOKBACK_H`, default 168). A week
     took 16 s on 2026-10-16. Beyond 7 days the run stores the last 7, reports `dropped_span` and exits 1. That span
     stays OPEN (`public.fn_samsara_gps_open_holes`) until a manual run whose window contains it succeeds (the GPS
     fallback workflow with `start_time` at or before the span's start, end blank): meanwhile the watchdog reports
     `gps_dropped_span` and, for 14 days, every job that waits for GPS waits at its start, so nothing is built across
     it. After 14 days the jobs stop waiting (a stuck stop builder costs more) and the item, still listed for 60 days,
     adds the stop rebuild to its what_to_do.
     Rows are inserted in time order and the run stops at the first failed batch, so within a run the cursor (derived
     from the data) never moves past rows that did not land. A cursor lookup that fails is fatal (it used to fall back
     to the last 90 minutes and lose the rest). `END_TIME` without `START_TIME` is refused.
   - Readings: from the last run that stored every stream (`resume_point`) minus 30 min, no limit; 48 h deep pass once
     a day. Any failed call or insert makes the run an error, so the cursor never moves past it.
   Both print `RUN_SUMMARY` (stored in `sync_log.details.summary`; `rows_inserted` = rows the DB actually took).
   Restart policy stays NEVER on purpose: Railway documents nothing about restarts for cron services, a restarting run
   would make the scheduled one skip, and a permanent error (a revoked token) would only loop.
3. **Watchdog every 10 minutes.** `public.log_samsara_feed_health()` (pg_cron `samsara-feed-health`, `3-59/10`), check
   `samsara-feed-health` in the health email chain (`ops.v_health_items`, `ops.v_health_status`). Items, each with a
   `reason` and the `what_to_do` line the email prints:
   - `feed_stale:<railway source>`: that Railway service has no good run in 20 min (it names a newer GitHub fallback
     run, and a skipped readings stream, for which Run now cannot help);
   - `gps_dropped_span:<from>`: an open GPS hole (layer 2);
   - `gps_silent:vehicle-<id>`: only while GPS is otherwise live, a truck's engine ran in the last 6 h more than 30 min
     after its last stored GPS point (a GPS job that runs green but stores nothing for that truck).
   When an item appears that was never emailed, or an open one has been gone for 2 runs, it calls the health
   escalation at once (not at 13:30 UTC): one email when an outage starts (about 20 to 30 minutes in), plus one per new
   hole or silent truck; resolutions ride along. (A scan run for another reason during a single quiet run still
   resolves an item, so a feed that flaps can send an extra email.) The daily `log_jobber_sync_health` watches the watchdog itself (30
   min). It sees failed or missing runs; a readings run that is green but stores no sensor data raises nothing here
   (see Known gaps).
4. **Fallback runners, independent of Railway.** GitHub Actions, manual "Run workflow" (GitHub schedules here fire every
   4 to 8 hours, so they are not scheduled):
   - **Samsara GPS (fallback)**: `.github/workflows/samsara-locations-history.yml`, source `github_samsara_gps`;
     `start_time` / `end_time` for an exact backfill.
   - **Samsara tank readings (fallback)**: `.github/workflows/samsara-readings-fallback.yml`, source
     `github_samsara_readings`.
   Running one while Railway also runs is safe (every target table ignores duplicates). Their own sync_log sources mean
   the watchdog keeps reporting a dead Railway service, while the guards below accept their data.
   **Automatic restart (2026-10-16, Fred: "yes set up the auto restart"; migration `2026-10-16_0945`).** When a Railway
   service has not RUN at all for 15 minutes, the watchdog presses Railway's "Run now" for it
   (`public.fn_request_samsara_job_run`, GraphQL `deploymentInstanceExecutionCreate`), at most once every 30 minutes and
   6 times in 24 hours per service, and the email says what happened (pressed, Railway accepted or refused it). It does
   not press when the job runs but fails (another run would not help) or skips a reading. The token is a Railway
   PROJECT token (UnclogMe Timed Jobs, production only) in the Supabase vault secret `railway_timed_jobs_token`;
   `public.fn_check_railway_token` checks it once a day (hourly after a failure) and a refused token raises
   `restart_token_invalid`. Each press is a sync_log row `samsara-job-restart`, each check `samsara-job-restart-check`;
   Railway's answer is in `net._http_response` under the row's `request_id` (kept about 6 hours).
   To press it by hand: `select public.fn_request_samsara_job_run('samsara-gps', 'by hand');`.
   Without the secret nothing is sent and the email says "not set up". The session's Railway login may not create
   project tokens ("Not Authorized"), so a person creates it in Railway (Settings, Tokens) and puts it in the vault.
   ✅ Set up and proven 2026-10-16: Fred created the token (`supabase-samsara-watchdog`) and saved it in the vault; the
   check answered project UnclogMe Timed Jobs / production (HTTP 200), and a press at 10:12:16 ET was accepted
   (`deploymentInstanceExecutionCreate: true`) and started an extra samsara-readings run at 10:12:17 (success).
   🛑 2026-10-22: Railway cancelled every project token after its breach, so the check read "Project Token not found"
   from about 08:00 ET and no restart could be pressed. Replaced by `supabase-samsara-watchdog-2026-10-22` (Fred made
   it after his 2FA prompt; the value went from his Copy click into the vault); the check answered HTTP 200 again.
   The old row still shows in Railway and is dead. Record: `docs/audits/2026-10-22_railway_breach_rotation.md`.
   The GitHub fallback stays manual (dispatching it needs a GitHub token in the database).
5. **The jobs that write once wait for complete data.** One answer, `public.fn_samsara_data_complete_through('gps' |
   'readings')`: 'infinity' while the feed is live (a good run in the last 20 min), else the start of the newest good
   run (Railway or fallback), NULL if it never ran; for GPS never later than an open hole's start. The guards act only
   while a feed is stale or a hole is open: on a healthy day every job behaves exactly as before, including the
   nightly runs that read a window still in progress (they re-derive within 10 days).
   | job | guard |
   |---|---|
   | `fn_refresh_stop_facts` (hourly stop builder; stops are append-only) | builds only up to both feeds minus 15 min |
   | `ops.fn_freeze_grease_estimates` (Calendar grease tile, past days frozen) | day X only after a truck-from-GPS run on X+1 or later ran with GPS live (none in 7 days: the day before yesterday), and never a day the feeds do not cover past its midnight |
   | `fn_request_time_on_site_reminder` (11 AM Slack post) | `fn_time_on_site_reminder_hold`: cron hourly 15:00-19:00 UTC, posts once (a `time_on_site_reminder_request` marker row) at the first run 11 AM to 2 PM ET when both feeds reach 10 AM; at 2 PM it posts anyway |
   | `fn_fill_blank_time_on_site` (fills once) | skips a visit whose GPS window (to 10 AM next day) is not stored |
   | `fn_infer_visit_vehicle` (nightly truck from GPS) | same, for both its longest-stay test (window to 04:00 next day) and the completion-stay test that can replace a truck (window to 10 AM after the completion) |
   | `scripts/sync/derive_visit_vehicle_id.js` (GitHub, fills empty trucks) | skips a visit whose widest window (+30 min) is not stored |

## When the alert comes

1. Railway, UnclogMe Timed Jobs, the service named in the alert, Cron Runs: open the latest run's log.
   `sync_log` has the same run (`select * from sync_log where sync_source = 'railway_samsara_gps' order by id desc limit 5`).
2. A Samsara error that repeats (401 = token, 5xx for long = Samsara down): nothing to do for 5xx, the runs catch up when
   it is back. A code or config error: fix and push (both services redeploy on `scripts/sync/**`, `scripts/lib/**`).
3. Railway itself down or stuck: run the GitHub fallback workflow (step 4 above); repeat every hour or so until Railway
   is back, or just once when it is back (both catch up).
4. A `gps_dropped_span` item: run the GPS fallback with `start_time` = the span's start (in the item) and end blank.
   The span closes by itself when that run succeeds, and the waiting jobs carry on.
5. After a GPS hole the stop builder passed anyway (a hole older than this design, or one let go after 14 days):
   rebuild that truck's stops
   with `select public.fn_refresh_stop_facts(<vehicle_id>, '<hole start>');` (supersedes and rebuilds stops, links and
   tank levels from there), then re-run the nightly time on site sequence for those dates
   (`fn_fill_time_on_site_from_stops(true)`, `fn_compute_time_on_site(from, to, true)`,
   `fn_fill_blank_time_on_site(from, to, true)`, `fn_infer_visit_vehicle(from, to, true)`) and call the edge function
   `time-on-site-samsara-recheck` with `{from, to}`. Check any visit set to `reviewed_blank` during the outage.
6. GPS is not in the 2-hourly database backup: Samsara is the only other copy, so re-pull rather than restore.

## Known gaps (not built)

- A readings row Samsara publishes more than 48 h late is never fetched (deep pass is 48 h, once a day). Observed max
  lateness 28 h.
- ~~A tank level measured before a late reading arrived inside its window is not re-measured~~ WRONG, corrected
  2026-10-22 (water audit 2): it never matched the code. `fn_measure_vehicle_stop_tank_levels` re-decides every stop
  that arrived in the last 35 days on every hourly run (condition (a)) and replaces a level when any field differs, so
  a late reading recovered by the daily deep pass (17:15 to 17:35 ET) corrects a figure already shown. A water or grease
  figure is therefore provisional for 35 days. Nothing has moved since 2026-10-16 15:09 ET.
- ~~`tank_feed_freshness` (hourly) stays red on check T5 ... a dead tank sensor ... is not emailed.~~ FIXED
  `2026-10-22_1349`: the health items of `tank_feed_freshness` and `stop_facts_integrity` are keyed per check code
  (`check_failed:tank_feed_freshness:T1` is its own item), so T5 staying open no longer mutes T1/T2/T4. T5 itself stays
  open until the collector is switched to feed=true.
- A 30-day acknowledgement (`fn_health_ack`) of a `feed_stale` item also silences the next outage of the same feed in
  those 30 days (the shared scan keeps the acknowledgement when an item comes back). Do not acknowledge these items.
- If the nightly truck run has not seen live GPS for 7 days, the freeze falls back to freezing the day before
  yesterday with whatever truck the visit has then.
- The Calendar's frozen grease rows never take a later correction (a design question for Fred).
