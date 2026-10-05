# db-backup: our own copy of the Prod database every 2 hours (Railway)

Fred, 2026-10-05: "Go with the 2-hour copy on Railway." PITR is off on Prod and Supabase keeps one daily
backup (about a week), so a bad day could lose up to 24 hours. This service keeps our own copies instead of
paying for PITR (about $100 a month): at most about 2 hours of business rows can be lost, recovered the way
"Restoring" below describes.

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
120 tables of data for a 2-hourly copy, 140 for a daily; measured 2026-10-05: 131 and 150), then renamed,
with a `.sha256` next to it. `--strict-names` makes a renamed schema fail instead of being skipped, and
`--lock-wait-timeout=60s` makes it give up rather than wait behind a migration. Every run reports through
`public.fn_db_backup_heartbeat` (one `public.sync_log` row, `sync_source = 'db_backup'`).

Behaviour worth knowing:
- At start (every deploy) it copies only if no copy is younger than 2 hours, so redeploys do not flood
  retention. Leftover `.partial` files from a killed run are deleted at the next run, and the oldest copy is
  pruned BEFORE each dump, so a full volume recovers by itself.
- A due daily copy that fails is followed at once by a 2-hourly one, so a daily problem never costs the
  2-hour point.
- Without a Railway volume at `/data` it copies nothing and reports a setup error (copies on the container's
  own disk would vanish on the next deploy).

Measured 2026-10-05: business data without the bulk tables is about 35 to 40 MB, the daily copy about
430 MB before compression. Download from Supabase is roughly 30 GB a month, inside the 250 GB the Pro plan
includes. Volume use stays well under 5 GB (Railway Hobby limit).

## Monitoring, and how fast a problem is noticed

`public.log_db_backup_health()` (pg_cron `db-backup-health`, 13:25 UTC daily, just before the health email
at 13:30) raises an item when: the last good 2-hourly copy is older than 5 hours; the last good daily is
older than 30 hours; the last run failed; 2 or more runs failed in 24 hours; or the login is switched on
but no copy has ever reported in (a broken setup). Items reach Fred through the existing health email
(`ops.v_health_items`, `health-escalate`).
⚠ **The check runs once a day, so a stopped backup can go unnoticed for up to about 24 hours.** Running the
health checks every 2 hours is possible; it would change when every other check emails too, so it is
Fred's call.
Migrations: `docs/migrations/2026-10-05_1820_db_backup_reader_and_health.sql` and
`docs/migrations/2026-10-05_1852_db_backup_review_fixes.sql`.

## The login: `db_backup_reader`

SELECT on the business schemas only, BYPASSRLS (pg_dump refuses tables with row-level security
otherwise), EXECUTE on its heartbeat function, and `default_transaction_read_only = on`. **NOLOGIN until
Fred sets its password.** Deliberately NOT `pg_read_all_data`, which can read `vault.decrypted_secrets`.
Honest limits: like every login on Supabase it inherits PUBLIC's grants on the `pg_net` schema (it could
send HTTP requests from the database); postgres cannot revoke that. And anyone who can open the Railway
project can read the password and every copy, so the Railway account (two-step login, two admins) is the
real protection. Encrypting the copies was considered and not done: the live password sits next to them.
A new table that holds a secret must be revoked from this role and added to `EXCLUDE_TABLE` in `backup.sh`.

## Setup on Railway (Fred; a session cannot sign in or handle passwords)

1. Railway account `web@unclogme.com`: turn on two-step login, and add your own account as a second admin.
2. New project (for example "UnclogMe Backups"), separate from "Unclogme - Microservices", in the region
   **US East (Virginia)**, next to the database, so each dump is short.
3. New service from GitHub repo `webunclogmecom/supabase`, root directory `services/db-backup`. In the
   service settings set **Watch Paths** to `/services/db-backup/**`, so pushes to the rest of the repo do not
   redeploy it. When the repo goes private, give Railway's GitHub app access to it.
4. Add a volume to the service, mount path `/data`.
5. Variables: `PGHOST=aws-1-us-east-1.pooler.supabase.com`, `PGPORT=5432`, `PGDATABASE=postgres`,
   `PGUSER=db_backup_reader.wbasvhvvismukaqdnouk`, and `PGPASSWORD` = a new password of 20+ characters from
   your password manager (plain ASCII, no spaces).
6. Turn the login on WITHOUT the password reaching the database logs (they record role changes): in your
   own terminal run `node Supabase/services/db-backup/scram-verifier.mjs`, paste the same password when it
   asks (it is hidden), and paste the `ALTER ROLE ...` line it prints into the Supabase SQL editor. Never
   type `ALTER ROLE ... PASSWORD 'the plain password'`.
7. Deploy. The first run starts at once (a daily copy). Tell the session; it checks the heartbeat and runs a
   restore drill. If you forget, the health email reports "never ran" after the next 13:30 UTC run.
8. Optional, stronger: in Supabase Database settings download the CA certificate, add it to the image, and
   set `PGSSLROOTCERT` to its path; the script then verifies the server certificate (`verify-full`).

## Restoring

**Never point the apps at a project built with `pg_restore` from these files.** It has no staff logins, no
cron jobs, no vault secrets, no Storage triggers, and `--no-privileges` drops every REVOKE, so anon could
call every public function and read or write every public table.

### A. Rows lost or damaged, Prod still alive (the usual case)

1. First look in Prod's `audit.logs` (`old_row`): for an audited table the old row is there, no restore needed.
2. Otherwise create a new Supabase project (organisation "Dev - Unclogme", same region, Postgres 17) and
   enable `pg_trgm` in it (Database, Extensions).
3. Get a shell in the backup service: install the Railway CLI, `railway login`, add your SSH key in the Railway
   account settings, `railway link` to the backup project, then `railway ssh`.
4. `ls -lt /data/*/*.dump | head -3`, `cd` into the folder of the copy you want, `sha256sum -c <file>.sha256`.
5. Copy the Session pooler host from the NEW project's Connect button, then (the shell already holds the
   Prod reader's PG variables, so set every value explicitly):
   `PGPASSWORD='<new project password>' pg_restore --no-owner --no-privileges -d "host=<that host> port=5432 dbname=postgres user=postgres.<new-ref> sslmode=require" <file> 2>/tmp/restore.err; tail -3 /tmp/restore.err`
   Expected errors: "schema public already exists"; for a 2-hourly copy also about 70 triggers that call
   `audit.log_change` and four views over `audit.logs` (the audit schema is only in the daily copy). Then
   check the table you need loaded: `pg_restore -l <file> | grep "TABLE DATA <schema> <table>"` against
   `select count(*) from <schema>.<table>;` in the new project.
6. Read the rows you need from the new project (the Management API query endpoint works without Postgres
   tools) and write them back to Prod in a reviewed migration that keeps the original ids. For
   `public.visits`, start with `set local app.suppress_jobber_push = 'on';` and write `sync_state` in a second
   statement; filter `manifest_visits` pairs the DERM link guards reject; re-read the rows and check the app
   afterwards. Never use `session_replication_role` on Prod. (Supabase/CLAUDE.md has the details of each.)
7. Delete the scratch project when done.

### B. The Prod project is lost or unusable

1. First restore Supabase's own newest daily backup (Dashboard, Database, Backups). It brings back logins,
   cron jobs, vault secrets, grants and Storage triggers.
2. Then fill the gap since that backup from the newest 2-hourly copy, with procedure A.
3. A 2-hourly copy has no Samsara telemetry, webhook or sync logs and no audit history: take those from the
   newest daily copy if needed. Jobber and Samsara tokens are in no copy: reconnect them.

## Testing done (2026-10-05)

- Script logic with stand-in tools: daily first, then 2-hourly, retention, no volume (setup error, nothing
  written), a failing daily followed by a 2-hourly, too few tables refused, leftovers cleaned, the start-up
  copy skipped when a recent copy exists, a bad setting refused, next-slot timing.
- As `db_backup_reader` on Prod, in rolled-back transactions: sees all rows of an RLS table (3,028 of 3,028
  visits), reads the audit history, writes its heartbeat through the function only, is refused
  `webhook_tokens` and any update.
- `log_db_backup_health()` with simulated heartbeats (rolled back): stale, fresh, failed, never ran, failing.
- `scram-verifier.mjs` reproduces RFC 7677's SCRAM-SHA-256 example before printing anything.
- **Not yet run: a real `pg_dump` and a restore drill.** This machine has no Postgres tools without a
  download. The first Railway run is the real dump; the restore drill follows it.
- An independent three-lens review (script, security, restore) found the issues fixed in
  `2026-10-05_1852` and in this version of `backup.sh`.
