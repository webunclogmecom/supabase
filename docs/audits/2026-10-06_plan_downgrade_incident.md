# 2026-10-06: the org went Pro -> Free -> Pro by accident

Fred moved the Supabase organization "Unclogme" (Prod `wbasvhvvismukaqdnouk` and HR Sandbox
`klgtrdwrasrlxbmfyvdh`) from Pro to Free and back to Pro by mistake, then reported the apps as slow.
All times ET. Evidence files: session c0ac1570 scratchpad (logs, db, config, apps lanes).

## What the round trip did

| | before | after the round trip | now |
|---|---|---|---|
| Prod compute add-on | `ci_medium` (4 GB, 120 connections, since 2026-09-03) | **none: Nano**, the Free size (406 MiB, 60 connections, shared_buffers 224 MB) | `ci_medium` again |
| HR Sandbox compute | probably Micro | none: Nano | left on Nano (Fred; no app uses it) |
| Auth sessions_timebox / inactivity | 720 h / 168 h (since 2026-08-31) | **0 / 0** (sessions never expire) | 720 / 168 again |
| password_hibp_enabled | unknown | false | false (Fred: leave it off) |
| default_transaction_read_only | off | off (the DB is ~1 GB, over the Free 500 MB limit, and still never went read-only) | off |
| max_worker_processes, PostgREST config, SMTP, storage, backups, log retention | | unchanged | unchanged |

Going back to Pro restores the plan, **not the add-ons or the Pro-only settings.** The spend cap is
dashboard-only (the API cannot read it), so it has to be checked by a person.

## Timeline

- 13:54:07 Realtime tenant terminated (first effect). 13:54:44 Postgres restarted on Nano; Auth reloaded
  with sessions 0/0.
- 13:54:53 to 14:02:35 PostgREST could not load its schema cache (503, PGRST002); its pool fell from 40 to 10.
- 13:55 to 14:43 statement timeouts (483+); worst 14:10 to 14:20, /rest p50 22 to 30 s, p95 105 to 125 s.
  CPU 75-78% waiting on disk: the database no longer fit in memory.
- 13:58 the Jobber poll's cursor read failed and came back as "no cursor", so it pulled all 2,890 visits
  and flagged 2,631 for replay (see the fix below).
- 13:59 to 14:50 70 pg_cron runs skipped ("job startup timeout").
- 14:00:07 Realtime terminated again (probably the return to Pro; it did not restart Postgres or restore
  the add-on).
- 14:33 to 14:37 token refresh failed (504/500/409); staff on Calendar, Stamp Studio and Client App were
  signed out.
- 14:49:55 `PATCH /v1/projects/{ref}/billing/addons` `ci_medium` (Fred's OK). Down 14:50:30 to 14:53:51.
- 14:53:51 healthy: 1,146 app calls with 0 x 5xx, Calendar p50 63 ms, DERM p50 218 ms (morning baseline).
- 15:32 Auth sessions restored to 720/168 (Fred's OK); /auth/v1/health and /settings 200.
- 15:35 `sync-jobber-poll` v31 deployed (the cursor fix).

## Impact per app (13:54 to 14:54)

| app or job | what happened | lost work |
|---|---|---|
| Visit Calendar | 102 x 503 at the restart, then about 13% 5xx, p50 5 to 14 s | 2 reschedule RPC calls timed out at 14:29 to 14:31 (maybe dry runs) |
| DERM Tracker | 111 of 358 calls 5xx, p50 23 to 26 s | none (reads only) |
| Client App | p50 3 to 4.6 s; one user signed out at 14:34 | one `client_contacts` INSERT timed out at 14:35:14, never saved |
| Stamp Studio | signed out at 14:33 to 14:37; redact-manifest-sheet failed 5 of 7 | none (the sweep re-runs) |
| Admin Review, Field Portal | slow; one customer error page | none |
| HR App, Picture Planner, Apps Hub, DUMP | no traffic in the window | none |
| webhook-jobber | 10 real events failed; 9 repaired by a later event within 2 minutes | invoice #3313 (id 2901) line items to re-check |
| pg_cron | 70 runs skipped | none; all sweeps clean since 14:53 (sa-visit-promote missed 14:20) |

## The Jobber poll fix (`sync-jobber-poll` v31)

1. `getCursor()` read only `data`. supabase-js does not throw on an HTTP error, it returns
   `{ data: null, error }`, and a null cursor means "pull everything". It now throws on `error`, and the
   read sits inside the per-entity try, so a failed read skips that entity for one cycle (logged partial).
   A missing cursor row (no error) is still a legitimate null.
2. The error path called `.insert(...).catch(() => {})`. A query builder has `then` but no `catch`, so it
   threw a TypeError before the insert was sent and an errored run wrote no `sync_log` row. It is now
   awaited and its error logged.

Check: `node scripts/checks/jobber_poll_cursor_guard.mjs` runs `getCursor` from the working tree and from
`df02aba` (before the fix) against the same stubs; the old body must fail, the new one must pass.

The 2,631-visit replay was left to drain: after the restore it replayed 119 visits and wrote **0** visit
audit rows (Jobber and our data already matched). Visits have no `replayLimit`, so while the backlog lasts
each 5-minute run is killed before it writes its `sync_log` row; expect no `jobber_poll_pgcron` rows until
it is drained (about 8 per minute from 2,537 at 15:12).

## After any plan or billing change

`GET /v1/projects/{ref}/billing/addons` (Prod must read `ci_medium`), `GET /v1/projects/{ref}/config/auth`
(sessions_timebox 720, sessions_inactivity_timeout 168, in HOURS), and
`select current_setting('max_connections')` (120). Check the spend cap in the dashboard.
