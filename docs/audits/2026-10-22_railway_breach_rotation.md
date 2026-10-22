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
had been answering "Project Token not found" since 2026-10-21 (between 01:03 and 07:13 ET), at least 34 hours, without
raising its item (section 5).

Where the same value also lived (SHA-256 comparison, no value read out): the legacy service-role key in all four local
`.env` files, the vault and GitHub Actions; `SAMSARA_API_TOKEN` in the edge secret, Actions,
`Supabase/.env`, `Slack/.env`; `RPA_BOT_KEY` in edge `RPA_BOT_KEYS` and `Supabase/.env`; `PDF_SERVICE_API_KEY` in the
edge secret. The Railway Anthropic key is NOT the edge one (a separate key, GDO bot only).

⚠ **Corrected 2026-10-22 evening: the edge functions do NOT hold the legacy service-role JWT.** The key Supabase injects
into them as `SUPABASE_SERVICE_ROLE_KEY` is the project's **default secret key** (`sb_secret_`, edge secret digest
`46cfa6ab8b`), and the API logs agree: every edge-runtime request (Deno, Amazon) carries that key, none the legacy JWT.
An earlier version of this paragraph said "every edge function".

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
- **Found by the verification (edge function logs, 2026-10-18 and 2026-10-20): the OLD `RPA_BOT_KEY` was used from
  outside Railway BEFORE the breach.** 14 calls on 2026-10-18 (23:16 to 23:47 UTC) and 8 on 2026-10-20 (18:37 to
  18:48 UTC), all `rpa-derm-queue?mode=dryrun`, all 200, from a residential ISP abroad (two address ranges), with the
  bot's own HTTP client (`python-httpx/0.28.1`). That fits someone running the report bot's code on their own machine,
  most likely Jonathan's local copy (inferred, not verified). A dry run never leases, but it does return the 25-row
  sample with client names and addresses, and a working local copy also needs `GDO_PASSWORD` and the fog app password.
  The old key now answers 401. Nothing has used it since 2026-10-21 22:15 UTC except Railway and Fred's machine.
- **The legacy service-role JWT, by caller, over the 24 hours to 2026-10-22 23:05 UTC** (section 7 query): Railway's
  two Samsara jobs until 18:10 UTC (then the "railway" key), the PDF service (Railway, `python-httpx/0.27.2`), GitHub
  Actions (Microsoft), the Field Portal's `/login` server function (Cloudflare, `supabase-js-node`, only
  `rpc/get_client_by_code`) and Fred's machine. No other caller.

## 3. What changed

Every new value was generated in a script or taken from the vendor's own Copy button, and none was printed, except
the two Slack tokens in item 9 (Fred chose to let the session read those two off the page; they are therefore in this
session's local log).

| # | secret | how | proof |
|---|---|---|---|
| 1 | `RPA_BOT_KEY` (report bot <-> our 5 `rpa-derm-*` functions) | new random key; edge `RPA_BOT_KEYS` held old+new, Railway switched, bot redeployed, old key dropped | queue answers the old key 401 and the new 200; bot `/health` connected after the drop; `Supabase/.env` updated |
| 2 | `RUN_KEY`, `RUN_KEYS` (report bot dashboard + preview-token signing) | new random values; `RUN_KEYS` now `yan` and `diego` only (Jonathan's dropped) | dashboard 200 with each new key, 401 with a wrong one. New keys for Yan and Diego are in the private file: hand them over |
| 3 | `PDF_SERVICE_API_KEY` | new random key on Railway, redeploy, edge secret switched the moment the new container answered (about 20 s with no valid key) | wrong key 403, new key passes auth; a real call through `generate-derm-address-preview` (visit 8860, 089-COW) returned a PDF. ⚠ Corrected: that call DID use a sheet number (Miami-Dade 1149, `derm.address_sheets` id 187; the first version of this row said "no sheet number", checking the Broward table). Nobody printed it; voided by `2026-10-22_1915`. Smoke-test that path with a visit id that does not exist (404 before any number is taken) |
| 4 | `db_backup_reader` password (`PGPASSWORD`) | new random password, SCRAM verifier set by the Management API right after the 14:17 ET copy, Railway set and redeployed | direct login with the new password works (read-only on), a wrong one refused (28P01); the 16:17 ET backup reported `success` |
| 5 | Supabase key on Railway | NEW secret key "railway" (`sb_secret_`, revocable on its own) for samsara-gps, samsara-readings and unclogme-gdo-bot (the GDO bot's reference to pdf-service replaced by its own value) | every Railway request since 14:15 ET carries the new key and gets 200/201; stored in `Supabase/.env` as `SUPABASE_RAILWAY_SECRET_KEY` |
| 6 | Vault `railway_timed_jobs_token` | new project token "supabase-samsara-watchdog-2026-10-22" (UnclogMe Timed Jobs / production), made by Fred after his 2FA prompt | it answers the right project and environment; `fn_check_railway_token()` got HTTP 200 |
| 7 | `SAMSARA_API_TOKEN` | new Samsara token "UnclogMe sync (Railway, edge, Actions) 2026-10-22", same scope (whole organization, every read and write scope, as the old one); set on both Railway jobs, edge, GitHub Actions, `Supabase/.env`, `Slack/.env`; old token "FRED CLAUDE" deleted in Samsara | both jobs ran `success` every 5 minutes after the switch |
| 8 | `ANTHROPIC_API_KEY` (GDO Slack bot) | new key "gdo-slack-bot-railway-2026-10-22", workspace "GDO Lookup - Dev", not tied to a person, no expiry (a 30-day key would quietly break the bot); Microservices shared variable + `Slack/GDO Bot/gdo_bot/.env`; the old key stays Disabled | the models list answers 200 |
| 9 | `SLACK_APP_TOKEN`, `SLACK_BOT_TOKEN` (GDO Slack bot, app "GDO") | new app-level token "socket-2026-10-22" (connections:write), old "socket" token revoked; old bot token revoked with `auth.revoke`, app reinstalled with the same scopes | bot logs "Bolt app is running" on the new tokens (down about 4 minutes); the old bot token answers `account_inactive` |
| 10 | `SLACK_WEBHOOK_URL` (report bot digest, app "GDO Online Report", #new-app-issues) | Fred revoked the app's tokens and added a new webhook; Railway set, bot redeployed | new hook answers an empty test body with 400 (live, nothing posted); the revoked hooks answer 404 `no_service` |
| 11 | Jonathan's Railway access | removed from the project `unclogme-gdo-report-bot` (Fred: "Remove Railway, keep GitHub") | the project now has no project-level member; he keeps GitHub write on the repo, so his pushes still deploy. ⚠ Railway's audit row for the removal (`Member.removed`, 2026-10-22 20:41:31 UTC) shows `by: jon.v@ayache.com`. The session made the removal with Fred's login 17 s earlier, so Railway most likely records the REMOVED member in that field; read it that way, not as Jonathan acting |

Redeployed: all six services (the redeploy reuses the built image; no GitHub build was needed). Every latest
deployment reads SUCCESS.

Tooling change: `services/timed-jobs/set-secrets.js` accepts `KEY=ENVNAME`, so a person setting Railway's key runs
`node services/timed-jobs/set-secrets.js samsara-gps SUPABASE_SERVICE_ROLE_KEY=SUPABASE_RAILWAY_SECRET_KEY`. Without
it the script would copy the old legacy key back onto Railway. Since the verification it also REFUSES a plain
`SUPABASE_SERVICE_ROLE_KEY` (the `.env` line of that name is the leaked legacy JWT), so the mistake cannot be made by
leaving the mapping off.

## 4. Still open (needs a person or a decision)

Fred, 2026-10-22: *"do we really need this? is this affected by railway leak/hack? ... if they're not needed to be
rotated we can just leave them be. If that is so, then move the card in trello."* Each item answered below. Three of
them sat on Railway as literals and were exposed with everything else, so they DO need rotating, and the card stays
open until they are.

| item | exposed by the breach? | verdict | why it is not done | what to do |
|---|---|---|---|---|
| **Legacy Supabase keys (anon + service_role JWT)** | **Yes** (the service-role JWT was on the PDF service and, until 14:10 ET, the two Samsara jobs) | **Rotate: Fred's decision** | It cannot be rotated, only disabled, and disabling disables BOTH legacy keys (Supabase docs, read 2026-10-22). Every staff app still ships the legacy anon key, and the service-role JWT is still used by the PDF service, GitHub Actions, the Field Portal's login server and local scripts (section 2). That is the SECURITY-16 migration (`system-audit-2026-10-05/REPORT.md`), not a rotation. The edge functions are NOT on the list: they already use the default secret key. | Fred decides whether to start it now. Until then re-run the section 7 query; a caller outside the known list is a leak in use. |
| PDF service's Supabase key | Yes (same key as above) | Part of the item above | Its `supabase==2.10.0` refuses any key that is not a JWT ("Invalid API key"). | Bump supabase-py, then give it its own secret key. Moving it alone does not end the exposure; only disabling the legacy keys does. |
| `GDO_PASSWORD` (Miami-Dade DERM portal) | **Yes** (literal on the report bot service) | **Rotate** | Changing it means signing in to the county portal; a session never types a password. A local copy of the bot ran outside Railway on 10-18 and 10-20 (section 2), so a second copy of this password probably exists too. | Office (Diego) changes it, then sets the Railway variable at the same time; the bot stops after 2 login failures. |
| `FOG_IMAP_APP_PASSWORD` (the fog mailbox's Gmail app password) | **Yes** (literal on the report bot service) | **Rotate** | Needs the mailbox owner's Google sign-in. Owner still unknown (ACCESS.md). | The owner revokes the old app password, makes a new one, and sets the Railway variable. |
| `GOOGLE_PLACES_API_KEY` (GDO Slack bot) | Yes (Microservices shared variable) | Optional | It reads public map data; the worst use is spend on our Google bill. Google Cloud asked for Fred's password. | Either rotate (new key restricted to the Places API, set the shared variable, delete the old key) or keep it and set an API restriction plus a daily quota. |
| Yan's and Diego's report-bot dashboard keys | No: these ARE the new keys | Hand over | Already rotated (item 2 above); they only need to reach their owners. | Give Diego his key (password manager, never Slack), Yan only if he uses it, then delete the private file. |
| GDO Slack bot out of #gdo-permit | No (a side effect of item 9) | **Fix** | The reinstall that replaced the bot token took the app out of its channels; it answered there on 2026-10-14 and is not a member now. The bot runs and its tokens are valid, but @GDO mentions get no answer. | A person runs `/invite @GDO` in #gdo-permit, then @mentions it with a known address and checks for a threaded reply. |
| Jonathan | His local copy (section 2) | Recommended | Card item: "Confirm with Jonathan that his side is done". He probably still holds the portal and fog passwords. | Slack draft only (Fred sends): ask him to delete his local copies and say what else he runs. |
| GitHub link in Railway | No (not a secret) | Not needed | fred@ayache.com's Railway account shows GitHub "Connect"; pushes still reach Railway. | Only when connecting a new repo. |
| Old watchdog token row | No: already dead (Railway cancelled it) | Not needed | Still listed in Railway. | Optional tidy: delete it in Railway, Settings, Tokens (2FA). |
| Postman `rpaBotKey` | No: holds the old key, now refused | Not needed for security | Postman calls fail until updated. | Paste the new value from `Supabase/.env` when Postman is next used. |
| `SLACK_HEALTH_WEBHOOK_URL` | No: dead with its Slack app, nothing reads it | Not needed | | Optional: delete the `.env` line and the Actions secret. |

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
- **A watchdog that checks a token must treat an ANSWER that is not a clean match as a refusal.** Railway answers a
  dead project token with HTTP 200 and `data: null`; `status = 200 AND projectId = ...` is then NULL, not false, and
  the dead-token item never fired. The token was dead for about 34 hours unseen. Fixed by `2026-10-22_1855`.
- **A "smoke test" of a document generator can spend a real number.** The preview path takes the next Miami-Dade
  sheet number for any real visit. Use a visit id that does not exist.
- **Reinstalling a Slack app (to replace its bot token) takes it out of every channel.** Re-invite it, then check it
  answers.
- **A log query that matches a key hash must match the PREFIX.** The logs store more characters of the hash than a
  fingerprint shows, so `= '<10 chars>'` matches nothing and reads as "the key is not used".

## 6. Files changed with this rotation

Supabase: this file, the migrations `2026-10-22_1855_samsara_watchdog_dead_token_item.sql` (+ its rollback) and
`2026-10-22_1915_void_test_preview_sheet_1149.sql`, `services/timed-jobs/set-secrets.js` and `README.md`, `services/db-backup/README.md`,
`docs/reference/gdo-report-bot.md`, `docs/reference/samsara-feeds-resilience.md`, `docs/reference/anthropic-api-usage.md`,
`docs/security.md`. Root: `docs/handbook/INCIDENT.md`, `docs/handbook/ACCESS.md`. GDO Slack bot repo: `REFERENCE.md`,
`CHANGELOG.md`. PDF service repo: `docs/DEPLOY.md`. Local `.env` files: `Supabase/.env` (RPA_BOT_KEY,
SAMSARA_API_TOKEN, new SUPABASE_RAILWAY_SECRET_KEY), `Slack/.env` (SAMSARA_API_TOKEN), the PDF service `.env`
(PDF_SERVICE_API_KEY), `Slack/GDO Bot/gdo_bot/.env` (ANTHROPIC_API_KEY, SLACK_APP_TOKEN, SLACK_BOT_TOKEN).

## 7. Re-run the misuse check

Management API, `GET /v1/projects/{ref}/analytics/endpoints/logs` with `sql`, `iso_timestamp_start` and
`iso_timestamp_end` (ClickHouse SQL, about one day per call). It groups by KEY as well as by network, so a key used
from the wrong place stands out:

```sql
SELECT
  multiIf(log_attributes['request.sb.jwt.apikey.payload.signature_prefix'] = 'TFkQyI', 'legacy service_role JWT',
          startsWith(log_attributes['request.sb.apikey.apikey.hash'], 'QrqXLDgh4I'), 'secret key railway',
          startsWith(log_attributes['request.sb.apikey.apikey.hash'], 'Rs-mq4tY0O'), 'secret key default',
          'other secret key') AS key,
  log_attributes['request.cf.asOrganization'] AS org,
  substring(log_attributes['request.headers.user_agent'], 1, 30) AS ua,
  count() AS n, uniqExact(log_attributes['request.headers.cf_connecting_ip']) AS ips,
  min(timestamp) AS first, max(timestamp) AS last
FROM logs
WHERE source = 'edge_logs'
  AND (log_attributes['request.sb.jwt.apikey.payload.signature_prefix'] = 'TFkQyI'
    OR startsWith(log_attributes['request.sb.apikey.apikey.prefix'], 'sb_secret_'))
GROUP BY key, org, ua ORDER BY key, n DESC
```

The three markers are not secrets: `TFkQyI` is the first characters of the legacy service-role JWT's signature, and
the two hash prefixes are what the logs record for the two secret keys. ⚠ Match the hash with `startsWith`: the logs
store more characters than shown here, and `=` matches nothing.

Healthy (measured over the 24 hours to 2026-10-22 23:05 UTC):

| key | expected callers |
|---|---|
| secret key default | the edge functions only (`Deno ... SupabaseEdgeRuntime`, Amazon networks, a few A100 ROW) |
| secret key railway | the two Samsara jobs and the GDO Slack bot (`node`, `python-httpx`; network "Railway" until 2026-10-22 16:57 ET, "Google LLC" since the 16:57 ET redeploy), and Fred's machine |
| legacy service_role JWT | the PDF service (Railway, `python-httpx`), GitHub Actions (Microsoft), the Field Portal's `/login` server function (Cloudflare, `supabase-js-node`, only `rpc/get_client_by_code`), Fred's machine |

For the RPA key, read `function_edge_logs` for `rpa-derm-*`: only Railway and Fred's machine since 2026-10-21 22:15 UTC.

A caller outside these lists is a leak in use: for the legacy JWT, disable the legacy keys at once (Settings, API
Keys), accepting the app outage; for a secret key, delete that key and give its services a new one. A Cloudflare
caller is NOT automatically ours (anyone can rent Cloudflare): check its paths.

## 8. Verification (2026-10-22, 17:00 to 19:00 ET)

Fred: *"check the ones we just did a rotation to make sure they work correctly."* Every rotated secret was checked
where it is stored and where it is used, each check challenged by a second agent.

**Stored and working:** every new value carries the same fingerprint in every store that holds it (Railway, edge
secrets, vault, GitHub Actions, the local `.env` files). The report bot's queue refuses the old RPA key (401) and
accepts the new one; the dashboard keys work; the PDF service refuses a wrong key (403); the backup ran `success` with
the new password; both Samsara jobs ran `success` every 5 minutes on the new token and the "railway" key; the vault
token answers the right project; the GDO Slack bot connected on the new Slack tokens and the new Anthropic key answers.

**Found and fixed the same evening:**
- The Samsara watchdog could not see a dead Railway token (section 5). Migration `2026-10-22_1855`, from the live
  body, old body kept as a control that must stay silent; rollback beside it.
- The PDF test spent Miami-Dade sheet 1149 on 089-COW. Soft-deleted by `2026-10-22_1915` (the number stays used).
- `set-secrets.js` now refuses to copy the legacy key to Railway.
- This record's two wrong statements (section 1, section 3 item 3) and the section 7 query, which used the old field
  names and could not tell the keys apart.

**Found, needs a person:** the GDO Slack bot is out of #gdo-permit (section 4).

**Not yet proven, only stored correctly** (each first real use is after this record):
- The report bot's new Slack webhook: the first daily digest, 2026-10-23 08:00 ET (bot log "Daily Slack digest sent",
  or the post in #new-app-issues).
- ✅ Proven after this list was written: the new Samsara token in GitHub Actions. The Actions secret changed at
  2026-10-22 20:58 UTC, after the last scheduled "Samsara telemetry polling" run (20:46 UTC, still the old token), so
  the session started that workflow by hand at 23:06 UTC: success, 3 vehicle records pulled from Samsara.
- The new Samsara token in the edge secret: the nightly `time-on-site-samsara-recheck`, 2026-10-23 03:50 ET.
- The GDO Slack bot end to end (the "railway" key, Anthropic, Places): the first @GDO answer after the re-invite.
