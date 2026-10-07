# Scheduled jobs

> **Generated, do not edit by hand.** Written by `node scripts/checks/timed-jobs-inventory.mjs --write`,
> generated on 2026-10-07 15:41 ET. Re-run it after any schedule change and commit the result.

Every timed job in pg_cron (Prod), the Railway project UnclogMe Timed Jobs (read from
`services/timed-jobs/services.json`; `node services/timed-jobs/apply.js` shows any drift from Railway) and
GitHub Actions. Schedules are shown as stored, in UTC (pg_cron runs on `cron.timezone` GMT). The ET column converts
fixed-time schedules: EDT = UTC-4 (second Sunday of March to first Sunday of November), EST = UTC-5.
pg_cron shows the first function a job calls and, when that wrapper posts to one edge function, its name.
The command text itself is never read out of the database.
`cron.job_run_details` proves the SQL ran, not that the edge function behind it worked. GitHub does not
keep to its cron, so check its history before trusting a GitHub time.

Not in this table, because they time themselves: the database backup ([services/db-backup](../../services/db-backup/README.md),
Railway project UnclogMe Backups, a loop that copies every 2 hours at HH:17 UTC, even hours; health in `public.sync_log`
source `db_backup` and pg_cron `db-backup-health`), and the GDO report bot, which runs on its developer's own Railway
deployment, not ours ([its triggers](gdo-rpa-bot-triggers.md)).

Background: [timed jobs on Railway](../../services/timed-jobs/README.md), [the move decision log](../audits/2026-10-07_timed_jobs_move.md).

| runtime | name | schedule (UTC) | ET | what it runs | health source |
|---|---|---|---|---|---|
| pg_cron | admin-review-reminder | `0 15,16 * * *` | 11:00, 12:00 EDT / 10:00, 11:00 EST | `public.fn_request_admin_review_reminder`, edge fn `admin-review-reminder` | `cron.job_run_details` jobid 126 |
| pg_cron | audit-partman-maintenance | `0 */6 * * *` | 20:00, 02:00, 08:00, 14:00 EDT / 19:00, 01:00, 07:00, 13:00 EST | `partman.run_maintenance` | `cron.job_run_details` jobid 1 |
| pg_cron | blackout-health-check | `0 12 * * *` | 08:00 EDT / 07:00 EST | `public.log_blackout_health` | `cron.job_run_details` jobid 28 |
| pg_cron | calendar-push-auto-retry | `2-59/5 * * * *` | interval, same in ET | `public.fn_calendar_push_auto_retry` | `cron.job_run_details` jobid 17 |
| pg_cron | calendar-push-health-check | `30 7 * * *` | 03:30 EDT / 02:30 EST | `public.log_calendar_push_health` | `cron.job_run_details` jobid 7 |
| pg_cron | calendar-task-poll | `1-59/5 * * * *` | interval, same in ET | `public.fn_request_calendar_task_poll`, edge fn `poll-calendar-tasks` | `cron.job_run_details` jobid 31 |
| pg_cron | city-email-sweep | `7 * * * *` | hourly at :07, same in ET | `public.fn_request_city_email_sweep`, edge fn `send-derm-email` | `cron.job_run_details` jobid 33 |
| pg_cron | daily-cleanup | `0 3 * * *` | 23:00 EDT / 22:00 EST | `public.fn_daily_cleanup` | `cron.job_run_details` jobid 125 |
| pg_cron | db-backup-health | `25 13 * * *` | 09:25 EDT / 08:25 EST | `public.log_db_backup_health` | `cron.job_run_details` jobid 124 |
| pg_cron | derm-required-rederive | `20 7 * * *` | 03:20 EDT / 02:20 EST | `public.rederive_visits_derm_required` | `cron.job_run_details` jobid 6 |
| pg_cron | dump-driver-truck-refresh | `4-59/5 * * * *` | interval, same in ET | `public.refresh_dump_driver_truck` | `cron.job_run_details` jobid 12 |
| pg_cron | gdo-permit-label-sweep | `11 9 * * *` | 05:11 EDT / 04:11 EST | `public.fn_request_gdo_permit_label_sweep`, edge fn `gdo-permit-label` | `cron.job_run_details` jobid 114 |
| pg_cron | generated-sheet-finisher | `6-59/10 * * * *` | interval, same in ET | `public.fn_request_generated_measure`, edge fn `measure-generated-page` | `cron.job_run_details` jobid 43 |
| pg_cron | health-escalation | `30 13 * * *` | 09:30 EDT / 08:30 EST | `public.fn_request_health_escalation`, edge fn `health-escalate` | `cron.job_run_details` jobid 30 |
| pg_cron | inbound-file-drain | `*/5 * * * *` | interval, same in ET | `public.fn_request_inbound_file_drain`, edge fn `inbound-file-drain` | `cron.job_run_details` jobid 48 |
| pg_cron | invoice-drift-reconcile | `25 */6 * * *` | 20:25, 02:25, 08:25, 14:25 EDT / 19:25, 01:25, 07:25, 13:25 EST | `public.fn_request_jobber_sync('invoice-drift')` | `cron.job_run_details` jobid 40 |
| pg_cron | jobber-billing-observe | `0 6 * * *` | 02:00 EDT / 01:00 EST | `public.fn_request_billing_observe`, edge fn `sync-jobber-billing-observe` | `cron.job_run_details` jobid 38 |
| pg_cron | jobber-client-state-sweep | `15 7 * * 0` | Sun 03:15 EDT / Sun 02:15 EST | `public.fn_request_jobber_sync('client-state-sweep')` | `cron.job_run_details` jobid 47 |
| pg_cron | jobber-job-drift-reconcile | `15,45 * * * *` | hourly at :15, :45, same in ET | `public.fn_request_jobber_sync('jobs-drift')` | `cron.job_run_details` jobid 21 |
| pg_cron | jobber-poll-sync | `1-59/5 * * * *` | interval, same in ET | `public.fn_request_jobber_sync('poll')` | `cron.job_run_details` jobid 5 |
| pg_cron | jobber-sync-health | `13 13 * * *` | 09:13 EDT / 08:13 EST | `public.log_jobber_sync_health` | `cron.job_run_details` jobid 37 |
| pg_cron | jobber-upcoming-visits-sync | `3-59/15 * * * *` | interval, same in ET | `public.fn_request_jobber_sync('upcoming')` | `cron.job_run_details` jobid 4 |
| pg_cron | jobber-visit-drift-reconcile | `8-59/30 * * * *` | interval, same in ET | `public.fn_request_jobber_sync('drift')` | `cron.job_run_details` jobid 8 |
| pg_cron | note-photo-sync-health | `35 */6 * * *` | 20:35, 02:35, 08:35, 14:35 EDT / 19:35, 01:35, 07:35, 13:35 EST | `public.log_jobber_note_photo_health` | `cron.job_run_details` jobid 39 |
| pg_cron | outbound-custom-field-push | `1-59/2 * * * *` | interval, same in ET | `public.fn_request_outbound_custom_field_push`, edge fn `jobber-push-custom-field` | `cron.job_run_details` jobid 35 |
| pg_cron | page-reference-measure | `8-58/10 * * * *` | interval, same in ET | `public.fn_request_page_reference_measure`, edge fn `measure-page-reference` | `cron.job_run_details` jobid 119 |
| pg_cron | plan-drive-warm | `15 9 * * *` | 05:15 EDT / 04:15 EST | `public.fn_request_plan_drive_fill`, edge fn `plan-drive-fill` | `cron.job_run_details` jobid 44 |
| pg_cron | redact-manifest-sweep | `3-59/5 * * * *` | interval, same in ET | `public.fn_request_blackout_sweep`, edge fn `redact-manifest-sheet` | `cron.job_run_details` jobid 10 |
| pg_cron | resolve-stale-visit-sync-pending | `1-59/3 * * * *` | interval, same in ET | `public.fn_request_jobber_push`, edge fn `jobber-push-visit` | `cron.job_run_details` jobid 9 |
| pg_cron | rpa-derm-health-check | `0 9 * * *` | 05:00 EDT / 04:00 EST | `public.log_rpa_derm_health` | `cron.job_run_details` jobid 14 |
| pg_cron | sa-schedule-gap-check | `15 10 * * *` | 06:15 EDT / 05:15 EST | `public.log_sa_schedule_gaps` | `cron.job_run_details` jobid 16 |
| pg_cron | sa-visit-generation | `0 10 * * *` | 06:00 EDT / 05:00 EST | `public.fn_generate_sa_visits` | `cron.job_run_details` jobid 22 |
| pg_cron | sa-visit-promote | `20 * * * *` | hourly at :20, same in ET | `public.fn_promote_sa_visits_to_jobber` | `cron.job_run_details` jobid 23 |
| pg_cron | sheet-number-ocr-sweep | `2-59/10 * * * *` | interval, same in ET | `public.fn_request_sheet_number_ocr`, edge fn `ocr-address-sheet-number` | `cron.job_run_details` jobid 24 |
| pg_cron | sheet-row-ocr-sweep | `4-59/10 * * * *` | interval, same in ET | `public.fn_request_sheet_row_ocr`, edge fn `ocr-address-sheet-rows` | `cron.job_run_details` jobid 29 |
| pg_cron | stamp-sheets-reminder | `0 15,16 * * *` | 11:00, 12:00 EDT / 10:00, 11:00 EST | `public.fn_request_stamp_sheets_reminder`, edge fn `stamp-sheets-reminder` | `cron.job_run_details` jobid 115 |
| pg_cron | start-flags-drain | `*/2 * * * *` | interval, same in ET | `ops.refresh_start_flags` | `cron.job_run_details` jobid 61 |
| pg_cron | start-flags-health | `20 13 * * *` | 09:20 EDT / 08:20 EST | `public.log_start_flags_health` | `cron.job_run_details` jobid 112 |
| pg_cron | start-flags-sweep | `0 8 * * *` | 04:00 EDT / 03:00 EST | `ops.fn_judge_starts` | `cron.job_run_details` jobid 62 |
| pg_cron | start-push-retry | `1-59/5 * * * *` | interval, same in ET | `ops.retry_marker_pushes` | `cron.job_run_details` jobid 111 |
| pg_cron | time-on-site-nightly | `20 7 * * *` | 03:20 EDT / 02:20 EST | `public.fn_compute_time_on_site` | `cron.job_run_details` jobid 26 |
| pg_cron | vehicle-gps-reconcile-nightly | `5 7 * * *` | 03:05 EDT / 02:05 EST | `public.fn_infer_visit_vehicle` | `cron.job_run_details` jobid 27 |
| Railway | samsara-gps | `*/5 * * * *` | interval, same in ET | `scripts/sync/cron_samsara_locations_history.js` | `public.sync_log` source `railway_samsara_gps` |
| GitHub | `audit-critical-poll.yml` | `*/5 * * * *` | interval, same in ET | `scripts/alerts/audit_critical_poll.js` | Actions history (`gh run list -w audit-critical-poll.yml`) |
| GitHub | `daily-jobber-anomaly-reconcile.yml` | `15 9 * * *` | 05:15 EDT / 04:15 EST | `scripts/sync/cron_jobber_reconcile_anomalies.js` | Actions history (`gh run list -w daily-jobber-anomaly-reconcile.yml`) |
| GitHub | `daily-jobber-completion-reconcile.yml` | `30 8 * * *` | 04:30 EDT / 03:30 EST | `scripts/sync/cron_jobber_reconcile_completion.js` | Actions history (`gh run list -w daily-jobber-completion-reconcile.yml`) |
| GitHub | `daily-notes-photos-sync.yml` | `12 12 * * *` | 08:12 EDT / 07:12 EST | `scripts/sync/jobber_token.js`, `scripts/migrate/jobber_notes_photos.js` | Actions history (`gh run list -w daily-notes-photos-sync.yml`) |
| GitHub | `derive-visit-vehicle-id.yml` | `17 * * * *` | hourly at :17, same in ET | `scripts/sync/derive_visit_vehicle_id.js` | Actions history (`gh run list -w derive-visit-vehicle-id.yml`) |
| GitHub | `frequent-jobber-completion-reconcile.yml` | `*/30 * * * *` | interval, same in ET | `scripts/sync/cron_jobber_reconcile_completion.js` | Actions history (`gh run list -w frequent-jobber-completion-reconcile.yml`) |
| GitHub | `jobber-note-photo-sync.yml` | `0 */6 * * *` | 20:00, 02:00, 08:00, 14:00 EDT / 19:00, 01:00, 07:00, 13:00 EST | `scripts/sync/sync_jobber_note_photos.js` | Actions history (`gh run list -w jobber-note-photo-sync.yml`) |
| GitHub | `jobber-note-photo-sync.yml` | `30 * * * *` | hourly at :30, same in ET | `scripts/sync/sync_jobber_note_photos.js` | Actions history (`gh run list -w jobber-note-photo-sync.yml`) |
| GitHub | `samsara-locations-history.yml` | `*/15 * * * *` | interval, same in ET | `scripts/sync/cron_samsara_locations_history.js` | Actions history (`gh run list -w samsara-locations-history.yml`) |
| GitHub | `samsara-poll.yml` | `*/10 * * * *` | interval, same in ET | `scripts/sync/cron_samsara_telemetry.js` | Actions history (`gh run list -w samsara-poll.yml`) |
| GitHub | `weekly-dedup-audit.yml` | `0 14 * * 0` | Sun 10:00 EDT / Sun 09:00 EST | `scripts/sync/weekly_dedup_audit.js` | Actions history (`gh run list -w weekly-dedup-audit.yml`) |

Totals: pg_cron 42 (0 paused), Railway 1, GitHub 11 schedules in 10 workflows.
