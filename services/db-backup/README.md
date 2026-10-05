# db-backup: our own copy of the Prod database every 2 hours (Railway)

Fred, 2026-10-05: "Go with the 2-hour copy on Railway." PITR is off on Prod and Supabase keeps one daily
backup (about a week), so a bad day could lose up to 24 hours. This service keeps our own copies instead of
paying for PITR (about $100 a month): at most about 2 hours of business data can be lost.

## What it does

| Copy | When | What is in it | Kept |
|---|---|---|---|
| 2-hourly | every 2 hours at HH:17 UTC (even hours) | schemas `public derm ops client sync raw customer hr`, without the data of `vehicle_telemetry_readings` (Samsara can resend it), `webhook_events_log` and `sync_log` (logs) | last 24 (2 days) |
| daily | the first run after the newest daily is 23 hours old | the same schemas with all their data, plus `audit` (the change history) | last 14 |

Never in any copy: `vault` (secrets), `public.webhook_tokens` (Jobber and Samsara OAuth tokens and the
client secret), `auth` and `storage` (Supabase-managed), `cron`, `net`, `realtime` (logs).
⚠ **Photos and PDFs are files in Supabase Storage, not database rows. No database copy (ours or
Supabase's) contains them.**

Each copy is a `pg_dump -Fc` file written as `.partial`, checked (`pg_restore --list` must show at least
50 tables of data), then renamed, with a `.sha256` next to it. Every run writes one heartbeat row to
`public.sync_log` (`sync_source = 'db_backup'`, status `success` or `error`, details: kind, bytes,
sha256, file).

Measured 2026-10-05: business data without the bulk tables is about 35 to 40 MB (12 copies a day), the
daily copy about 430 MB before compression. Download from Supabase is roughly 30 GB a month, inside the
250 GB the Pro plan includes. Volume use stays well under 5 GB (Railway Hobby limit).

## Monitoring

`public.log_db_backup_health()` (pg_cron `db-backup-health`, 13:25 UTC daily, just before the health
email) raises an item when the last good 2-hourly copy is older than 5 hours, the last good daily older
than 30 hours, or the last run failed. Items reach Fred through the existing health email
(`ops.v_health_items`, `health-escalate`). It stays silent until the first heartbeat ever arrives.
Migration: `docs/migrations/2026-10-05_1820_db_backup_reader_and_health.sql`.

## The login: `db_backup_reader`

Read-only by construction (SELECT on the business schemas only, plus INSERT on `public.sync_log` for its
heartbeat), BYPASSRLS because `pg_dump` refuses row-level-security tables otherwise, and **NOLOGIN until
Fred sets its password**. Deliberately NOT `pg_read_all_data`, which can read `vault.decrypted_secrets`.
Its password lives only in Fred's password manager and the Railway variable, never in a file. A new
table that holds a secret must be revoked from this role and added to `EXCLUDE_TABLE` in `backup.sh`.

## Setup on Railway (Fred; a session cannot sign in or handle passwords)

1. Railway account `web@unclogme.com`: turn on two-step login, and add your own account as a second admin.
   The volume will hold every client record, so Railway access is data access.
2. New project (for example "UnclogMe Backups"), separate from "Unclogme - Microservices".
3. New service from GitHub repo `webunclogmecom/supabase`, root directory `services/db-backup` (Railway
   builds the `Dockerfile` there). When the repo goes private, give Railway's GitHub app access to it.
4. Add a volume to the service: mount path `/data`.
5. Variables: `PGHOST=aws-1-us-east-1.pooler.supabase.com`, `PGPORT=5432`, `PGDATABASE=postgres`,
   `PGUSER=db_backup_reader.wbasvhvvismukaqdnouk`, and `PGPASSWORD` = a new strong password from your
   password manager.
6. In the Supabase SQL editor, the same password: `alter role db_backup_reader login password '...';`
7. Deploy. The first run starts at once (a daily copy). Tell the session; it checks the heartbeat row and
   runs a restore drill.

## Restoring

Never restore over Prod. A restore goes into a NEW Supabase project, then rows are copied back (or, in a
disaster, the apps are pointed at the new project; that is its own decision).

1. Create a new Supabase project (same region, Postgres 17).
2. Open a shell in the Railway service (`railway ssh`), pick a file under `/data/two_hourly/` or
   `/data/daily/`, and check it: `sha256sum -c <file>.sha256`.
3. Restore into the new project, from that shell:
   `pg_restore --no-owner --no-privileges -d "postgresql://postgres.<new-ref>:<password>@aws-1-us-east-1.pooler.supabase.com:5432/postgres" <file>`
   Expect errors only for objects Supabase already has.
4. Take what you need from it (a table, some rows) and copy it back to Prod with a reviewed migration.
5. A 2-hourly copy has no Samsara telemetry, no webhook or sync logs and no audit history: take those
   from the newest daily copy. Jobber and Samsara tokens are in no copy: reconnect them after a full
   switch.

## Testing done (2026-10-05)

- Script logic with stand-in tools: first run daily, then 2-hourly, retention, a failed dump (no partial
  file left, error heartbeat), a dump with too few tables refused, next-slot timing.
- As `db_backup_reader` on Prod, in a rolled-back transaction: sees all rows of an RLS table (3,028 of
  3,028 visits), reads the audit history, writes its heartbeat, is refused `webhook_tokens` and any update.
- `log_db_backup_health()` with simulated stale, fresh and failed heartbeats (rolled back): 2, 0 and 1
  items, and the failed one shows in `ops.v_health_items`.
- **Not yet run: a real `pg_dump` and a restore drill.** This machine has no Postgres tools without a
  download. The first Railway run is the real dump; the restore drill follows it.
