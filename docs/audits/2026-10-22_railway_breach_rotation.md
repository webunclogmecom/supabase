# Railway breach: every Railway secret rotated (Trello 8IBiZL5Z), 2026-10-22

Railway disclosed on 2026-10-21 that someone read customer environment variables and decrypted some of them
(<https://blog.railway.com/p/security-disclosure-wednesday-october-21st>, incident
<https://status.railway.com/incident/QH8L8B3E>). Railway then signed everyone out, cancelled every API and project
token, rotated bucket credentials and paused builds (Pro builds were back on 2026-10-22).

Fred, 2026-10-22: *"we need to check what the env vars key are, and rotate them ... you rotate them no need for my
input, you do it, store them correctly afterwards and document everything."*

This file is the record. It names variables only, never a value. New values are kept where their consumers read them
(Railway, Supabase edge secrets, the vault, GitHub Actions, the local `.env` files) and the values only people need
are in the private, git-ignored `.local-secrets/railway-rotation-2026-10-22.json` on Fred's laptop.

## 1. What was in Railway (measured 2026-10-22 ~13:50 ET, before any change)

Workspace "Unclogme", 4 projects, 6 services, all built from GitHub repos (no image source, so no registry
credentials exist).

| project / service | secrets | other settings |
|---|---|---|
| UnclogMe Timed Jobs / samsara-gps, samsara-readings | `SUPABASE_SERVICE_ROLE_KEY` (legacy JWT), `SAMSARA_API_TOKEN` | `SUPABASE_URL`, `AUTO_LOOKBACK_H`, `RUN_TIMEOUT_MIN` |
| UnclogMe Backups / db-backup | `PGPASSWORD` (role `db_backup_reader`) | `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `SUPABASE_URL`, `SUPABASE_PROJECT_ID` |
| unclogme-gdo-report-bot / UnclogMe_Reporter_Bot | `RPA_BOT_KEY`, `RUN_KEY`, `RUN_KEYS`, `SLACK_WEBHOOK_URL`, `GDO_PASSWORD`, `FOG_IMAP_APP_PASSWORD` | `API_BASE_URL`, `SHADOW_MODE`, `HEADLESS`, the `MIGRATE_*` / `*_EVIDENCE*` switches, `RAILWAY_DEPLOYMENT_DRAINING_SECONDS` |
| Unclogme - Microservices / (shared variables) | `ANTHROPIC_API_KEY`, `GOOGLE_PLACES_API_KEY`, `SLACK_APP_TOKEN`, `SLACK_BOT_TOKEN` | |
| Unclogme - Microservices / unclogme-gdo-bot | the four shared ones by reference, `SUPABASE_SERVICE_ROLE_KEY` (a reference to pdf-service's) | `SUPABASE_URL` |
| Unclogme - Microservices / unclogme-pdf-service | `PDF_SERVICE_API_KEY`, `SUPABASE_SERVICE_ROLE_KEY` (legacy JWT) | `SUPABASE_URL`, `SUPABASE_STORAGE_BUCKET`, `LOG_LEVEL` |

Held outside Railway but issued by it: the Supabase vault secret `railway_timed_jobs_token` (a Railway project token
the Samsara watchdog uses to press "Run now"). Railway cancelled it with every other token; the database's own check
had been answering "Project Token not found" since about 08:00 ET.

Where the same value also lived (SHA-256 comparison, no value read out): the legacy service-role key in all four local
`.env` files, every edge function, the vault and GitHub Actions; `SAMSARA_API_TOKEN` in the edge secret, Actions,
`Supabase/.env`, `Slack/.env`; `RPA_BOT_KEY` in edge `RPA_BOT_KEYS` and `Supabase/.env`; `PDF_SERVICE_API_KEY` in the
edge secret. The Railway Anthropic key is NOT the edge one (a separate key, GDO bot only).

## 2. Was anything misused? (logs read 2026-10-22)

- **Supabase API logs, 2026-10-20 00:00 UTC to 2026-10-22 ~18:00 UTC**, every request made with the service-role key,
  grouped by network: Railway (our Samsara jobs and the PDF service), Microsoft (GitHub Actions), Amazon (our own edge
  functions), one Cloudflare caller (a few RPC calls a day, a Lovable app's server function) and Fred's own machine.
  **No unknown network.** The calls from Railway hit only the tables our jobs write. Query shape: section 7.
- **Railway's workspace audit log since 2026-10-19:** 11 events, all deploys. One of them answers an old question:
  the 2026-10-18 21:27 ET deploy of the report bot (`87b24a2`, "who pushed it is not known" in
  `docs/reference/gdo-report-bot.md`) was triggered by **Jonathan's account** (a GitHub push he made).
- **Anthropic:** the GDO bot's key was already **Disabled** when we looked (Railway asked the AI providers to revoke
  keys; the key had cost $0.41 in its whole life). No unauthorised spend.
- Not checked: Samsara, Slack and Google have no per-key access log we can read.

## 3. What changed

Every new value was generated in a script or taken from the vendor's own Copy button, and none was printed, except
the two Slack tokens in item 9 (Fred chose to let the session read those two off the page; they are therefore in this
session's local log).

| # | secret | how | proof |
|---|---|---|---|
| 1 | `RPA_BOT_KEY` (report bot <-> our 5 `rpa-derm-*` functions) | new random key; edge `RPA_BOT_KEYS` held old+new, Railway switched, bot redeployed, old key dropped | queue answers the old key 401 and the new 200; bot `/health` connected after the drop; `Supabase/.env` updated |
| 2 | `RUN_KEY`, `RUN_KEYS` (report bot dashboard + preview-token signing) | new random values; `RUN_KEYS` now `yan` and `diego` only (Jonathan's dropped) | dashboard 200 with each new key, 401 with a wrong one. New keys for Yan and Diego are in the private file: hand them over |
| 3 | `PDF_SERVICE_API_KEY` | new random key on Railway, redeploy, edge secret switched the moment the new container answered (about 20 s with no valid key) | wrong key 403, new key passes auth; a real reprint through `generate-derm-address-preview` returned a PDF and used no sheet number |
| 4 | `db_backup_reader` password (`PGPASSWORD`) | new random password, SCRAM verifier set by the Management API right after the 14:17 ET copy, Railway set and redeployed | direct login with the new password works (read-only on), a wrong one refused (28P01); the 16:17 ET backup reported `success` |
| 5 | Supabase key on Railway | NEW secret key "railway" (`sb_secret_`, revocable on its own) for samsara-gps, samsara-readings and unclogme-gdo-bot (the GDO bot's reference to pdf-service replaced by its own value) | every Railway request since 14:15 ET carries the new key and gets 200/201; stored in `Supabase/.env` as `SUPABASE_RAILWAY_SECRET_KEY` |
| 6 | Vault `railway_timed_jobs_token` | new project token "supabase-samsara-watchdog-2026-10-22" (UnclogMe Timed Jobs / production), made by Fred after his 2FA prompt | it answers the right project and environment; `fn_check_railway_token()` got HTTP 200 |
| 7 | `SAMSARA_API_TOKEN` | new Samsara token "UnclogMe sync (Railway, edge, Actions) 2026-10-22", same scope (whole organization, every read and write scope, as the old one); set on both Railway jobs, edge, GitHub Actions, `Supabase/.env`, `Slack/.env`; old token "FRED CLAUDE" deleted in Samsara | both jobs ran `success` every 5 minutes after the switch |
| 8 | `ANTHROPIC_API_KEY` (GDO Slack bot) | new key "gdo-slack-bot-railway-2026-10-22", workspace "GDO Lookup - Dev", not tied to a person, no expiry (a 30-day key would quietly break the bot); Microservices shared variable + `Slack/GDO Bot/gdo_bot/.env`; the old key stays Disabled | the models list answers 200 |
| 9 | `SLACK_APP_TOKEN`, `SLACK_BOT_TOKEN` (GDO Slack bot, app "GDO") | new app-level token "socket-2026-10-22" (connections:write), old "socket" token revoked; old bot token revoked with `auth.revoke`, app reinstalled with the same scopes | bot logs "Bolt app is running" on the new tokens (down about 4 minutes); the old bot token answers `account_inactive` |
| 10 | `SLACK_WEBHOOK_URL` (report bot digest, app "GDO Online Report", #new-app-issues) | Fred revoked the app's tokens and added a new webhook; Railway set, bot redeployed | new hook answers an empty test body with 400 (live, nothing posted); the revoked hooks answer 404 `no_service` |
| 11 | Jonathan's Railway access | removed from the project `unclogme-gdo-report-bot` (Fred: "Remove Railway, keep GitHub") | the project now has no project-level member; he keeps GitHub write on the repo, so his pushes still deploy |

Redeployed: all six services (the redeploy reuses the built image; no GitHub build was needed). Every latest
deployment reads SUCCESS.

Tooling change: `services/timed-jobs/set-secrets.js` accepts `KEY=ENVNAME`, so a person setting Railway's key runs
`node services/timed-jobs/set-secrets.js samsara-gps SUPABASE_SERVICE_ROLE_KEY=SUPABASE_RAILWAY_SECRET_KEY`. Without
it the script would copy the old legacy key back onto Railway.

## 4. Still open (needs a person or a decision)

| item | why it is not done | what to do |
|---|---|---|
| **Legacy Supabase keys (anon + service_role JWT)** | The only way to kill the leaked service-role JWT is to switch every consumer to publishable/secret keys and then disable the legacy keys, which disables BOTH legacy keys (Supabase docs, read 2026-10-22). Every staff app still uses the legacy anon key (logs: Calendar, Admin Review, DERM, Client App, Planner, HR, Stamp, Field Portal), edge functions use the injected service-role JWT, and `verify_jwt` functions called from the database need a JWT. That is the SECURITY-16 migration (`system-audit-2026-10-05/REPORT.md`), not a rotation. | Fred decides whether to start it now. Until then the logs show no misuse; re-run the section 7 query. |
| PDF service's Supabase key | Still the legacy JWT: its `supabase==2.10.0` refuses any key that is not a JWT ("Invalid API key"). | Part of the item above: bump supabase-py, then give it the "railway" key. |
| `GDO_PASSWORD` (Miami-Dade DERM portal) | Changing it means signing in to the county portal; a session never types a password. | Office (Diego) changes it, then sets the Railway variable; the bot stops after 2 login failures, so change both together. |
| `FOG_IMAP_APP_PASSWORD` (the fog mailbox's Gmail app password) | Needs the mailbox owner's Google sign-in. Owner still unknown (ACCESS.md). | The owner revokes the old app password, makes a new one, and sets the Railway variable. |
| `GOOGLE_PLACES_API_KEY` (GDO Slack bot) | Google Cloud asked for Fred's password. | Make a new key restricted to the Places API, set the shared variable, delete the old key. |
| GitHub link in Railway | fred@ayache.com's Railway account shows GitHub "Connect"; pushes still reach Railway (skipped deploys recorded at 13:57 ET). | Only needed to connect a new repo; reconnect from the account that owns the repo connections when that happens. |
| Old watchdog token row | "supabase-samsara-watchdog" still listed in Railway, already dead. | Delete it in Railway, Settings, Tokens (2FA). |
| Postman `rpaBotKey` | The "UnclogMe - RPA (Prod)" environment holds the old key (now refused). | Paste the new value from `Supabase/.env` into Postman. |
| `SLACK_HEALTH_WEBHOOK_URL` | That #tests hook belonged to the same Slack app and is now dead; nothing read it. | Nothing, or delete the `.env` line and the Actions secret. |
| Jonathan | Card item: "Confirm with Jonathan that his side is done". | Slack draft only (Fred sends). |

## 5. Rules learned

- **A secret goes from a vendor page to our stores only through a person's Copy click.** The in-app browser refuses
  clipboard writes from automated clicks (NotAllowedError), and the safety check refuses moving a token from a vendor
  page to a local receiver. Reading the value off the page puts it in the session log; Fred allowed that for the two
  Slack tokens only. One Samsara token was printed by a page read by mistake and was deleted unused.
- **The Railway CLI's OAuth token expires within the session**; scripts that call the GraphQL API with it get "Not
  Authorized" until any `railway` command refreshes it.
- **A cron service's newest deployments are usually SKIPPED** (pushes outside its watch paths). Redeploy the ACTIVE one
  (`serviceInstance.latestDeployment`), never the newest in the list.
- **The legacy Supabase keys cannot be rotated, only disabled, and anon and service_role go together.** Moving each
  consumer to its own secret key first is what makes a future leak revocable on its own.

## 6. Files changed with this rotation

Supabase: this file, `services/timed-jobs/set-secrets.js` and `README.md`, `services/db-backup/README.md`,
`docs/reference/gdo-report-bot.md`, `docs/reference/samsara-feeds-resilience.md`, `docs/reference/anthropic-api-usage.md`,
`docs/security.md`. Root: `docs/handbook/INCIDENT.md`, `docs/handbook/ACCESS.md`. GDO Slack bot repo: `REFERENCE.md`,
`CHANGELOG.md`. PDF service repo: `docs/DEPLOY.md`. Local `.env` files: `Supabase/.env` (RPA_BOT_KEY,
SAMSARA_API_TOKEN, new SUPABASE_RAILWAY_SECRET_KEY), `Slack/.env` (SAMSARA_API_TOKEN), the PDF service `.env`
(PDF_SERVICE_API_KEY), `Slack/GDO Bot/gdo_bot/.env` (ANTHROPIC_API_KEY, SLACK_APP_TOKEN, SLACK_BOT_TOKEN).

## 7. Re-run the misuse check

Management API, `GET /v1/projects/{ref}/analytics/endpoints/logs` (ClickHouse SQL, about one day per call):

```sql
SELECT log_attributes['request.cf.asOrganization'] AS org,
       log_attributes['request.headers.cf_connecting_ip'] AS ip,
       count() AS n, min(timestamp) AS first, max(timestamp) AS last
FROM logs
WHERE source = 'edge_logs'
  AND (log_attributes['request.sb.jwt.apikey.payload.role'] = 'service_role'
    OR log_attributes['request.sb.jwt.authorization.payload.role'] = 'service_role')
GROUP BY org, ip ORDER BY n DESC
```

Healthy: Railway, Microsoft, Amazon and our own office, plus Cloudflare for a few `/rest/v1/rpc` calls a day (a
Lovable server function; check its paths, an attacker can rent Cloudflare too). Anything else is a leak in use:
disable the legacy keys at once (Settings, API Keys), accepting the app outage.
