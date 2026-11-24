# Driver photos from Jobber: move the sync off GitHub (Trello #247)

Written 2026-11-24 about 11:45 AM ET. Fred: *"they should've been in our system 4~6 hours after they were posted"*, then on
the options *"brainstorm it and plan it, what could be the best option with what you know"*.

## What happened (measured)

- Serena (#new-app-issues, 11-24): three visits of the Nov 23 route showed no photos in Admin Review while
  Jobber had them.
- The photo sync (`scripts/sync/sync_jobber_note_photos.js`, GitHub workflow `jobber-note-photo-sync.yml`) asks GitHub for a
  run every hour. GitHub's last run that day started at 1:10 AM ET. The three visits were completed at 1:35, 3:06 and
  4:31 AM ET. No scheduled run came for the next 10 hours.
- Fixed by hand at 11:24 AM ET: two 3-day runs and one 14-day run (`workflow_dispatch`). the three visits went from 0 photos to 17, 19
  and 31, and a Nov 24 visit from 0 to 5. The first run lost 3 photos to the Supabase admin API's rate limit
  (`DB 429 ThrottlerException`); the second picked them up. The 14-day run checked 110 visits and found nothing else missing.
- Not new: `docs/reference/jobber-note-photo-sync-operations.md` section 3 (GitHub delivers about a quarter of the hourly
  runs) and section 4 (every failure is that 429). The timed-jobs plan (`system-audit-2026-10-05/TIMED_JOBS_PLAN.md`,
  step 4) chose Railway for this job on 2026-10-05; the Samsara jobs moved, this one never did.
- The health check (`log_jobber_note_photo_health`) alerts after 12 hours with no run, so on 11-24 it would have spoken
  at its 1:35 PM ET pass, about 12 hours after the first photos.

## The options

| | Where it runs | How it reaches the database | New secret | Verdict |
|---|---|---|---|---|
| A | Railway, hourly | the admin API, as today (account-wide admin token) | the account-wide admin token on Railway | No. That token can change or delete every project in the account, and Railway had a breach in October. The 429s stay. |
| B | Railway, hourly | a direct Postgres connection | a database password on Railway (full power over the project unless a new role is built, and a new role then needs grants and row rules for ~10 tables) | Works, but adds a dependency (`pg`) and either a strong secret or a role to maintain. |
| **C** | **Railway, hourly** | **the normal API with the timed-jobs server key Railway already holds** (the Samsara jobs use it) | **none** | **Recommended.** No new secret, no rate limit (the 429 is the admin API only), writes get a real audit label. |
| D | GitHub, started by our own database every hour (pg_cron calls GitHub's "run workflow") | as today | a GitHub token in the vault | Smallest change and it would work (a started run begins within seconds, measured today), but it keeps the admin token and the 429s, and the repo is meant to leave GitHub to go private. |
| E | a Supabase edge function on pg_cron | built in | none | No. A run that imports 70 photos takes about 5 minutes (4 s per photo) and files reach 50 MB; edge functions stop well before that. |

## Recommended: C, in this order

Each step has its check. Nothing in Admin Review or the other apps changes: they read the same tables.

1. **The script talks to the normal API.** `pg(sql)` is replaced by small calls with `SUPABASE_URL` + the server key and the
   header `x-app-source: note-photo-sync`. Single-table reads and writes (notes, photos, links, the Jobber token row,
   `sync_log`, oversized files) go straight to the tables: service_role holds every grant needed (measured: webhook_tokens
   UPDATE, photos and notes INSERT, photo_links DELETE, entity_source_links / sync_log / jobber_oversized_attachments INSERT).
   The joined reads (the visits to check, the photos a visit already has, its sibling visits, a photo by its Jobber id)
   become read functions for service_role only, copied from the script's current SQL. No function runs SQL it is handed.
   *Check:* a dry run of the new script and of the old one on the same 14 days lists the same visits and 0 photos to add.
2. **`--days=auto`**: 14 days when the run starts in the 05 UTC hour (1 AM ET), else 3, so one service does both jobs and
   two runs never overlap. *Check:* the run's `sync_log` row says `days: 14` once a day.
3. **A real end-to-end test on the test client**: a photo added to a note on a visit of the test client in Jobber shows in Admin Review after the
   next run. *Check:* the photo row, its link, and the audit rows labelled `note-photo-sync`.
4. **Railway service `note-photo`** in `services/timed-jobs/services.json`: `node scripts/sync/run_logged.js
   railway_note_photo scripts/sync/sync_jobber_note_photos.js --execute --enable-remove --days=auto`, cron `5 * * * *`
   (hourly at :05), kill after 45 minutes. **Fred runs one command** to copy the two values Railway needs (the same as the
   Samsara services): `node services/timed-jobs/set-secrets.js note-photo SUPABASE_URL SUPABASE_SERVICE_ROLE_KEY=SUPABASE_RAILWAY_SECRET_KEY`.
   *Check:* 24 runs in the first day, each with a `sync_log` row.
5. **One day side by side**, then the GitHub schedules go (a duplicate is refused by the unique index, so two runners
   cannot double a photo). The workflow stays as a manual button for a bad day, like the Samsara fallback workflows.
   *Check:* no photo added twice; GitHub runs that day add 0.
6. **The alert (card item 5)**: `railway_note_photo` joins the watched list at 2 hours, and `log_jobber_note_photo_health`
   speaks after 2 hours with no run instead of 12. A per-visit alert ("completed 6 hours ago, no photos") was measured and
   rejected: 15 of 209 completed visits in 30 days really have no photos, so it would cry wolf about once every two days.
   *Check:* the health function, run with a fake last-run time 3 hours old, returns the item.
7. **Documents in the same cycle**: the operations doc, `docs/reference/scheduled-jobs.md` (regenerated), the Railway
   README, the timed-jobs plan (step 4 done), Admin Review's changelog (photos arrive within about an hour), and a
   `decisions-to-build.md` row.

About half a day of work. Until it ships, a late visit can be fixed at once with the workflow's "Run workflow" button
(3 days).

## Not in this plan

- The Jobber token refresh stays as it is (the script refreshes the shared token like today); the timed-jobs plan's
  2.5 covers it.
- The daily notes import (`daily-notes-photos-sync.yml`) stays on GitHub; it is daily, and GitHub runs daily jobs.
