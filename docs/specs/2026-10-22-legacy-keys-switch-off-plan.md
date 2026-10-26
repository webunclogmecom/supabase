# Switch off the legacy Supabase keys (Trello 8IBiZL5Z, last step)

Fred, 2026-10-22, after the Railway breach rotation: *"let's change it as the last step we have to do."* The leaked
legacy service-role JWT gives full access to the whole database, stays valid until 2036, and cannot be rotated, only
switched off. This is also SECURITY-16 of the 2026-10-05 audit (Supabase retires the legacy keys by the end of 2026).

Names only, never a value. Record of the breach: `docs/audits/2026-10-22_railway_breach_rotation.md`.

## 1. What is true today (measured 2026-10-22, 19:00 to 19:40 ET)

**API keys** (Management API `api-keys`): legacy `anon` (prefix `sPJGF`) and legacy `service_role` (`TFkQy`), both
still accepted; `default` publishable key and `default` secret key (both since 2026-04-02); secret key `railway`
(2026-10-22).

**Signing keys** (`config/auth/signing-keys`): ES256 `in_use` (every staff session token is ES256 since April),
legacy HS256 `previously_used`, which means it STILL VERIFIES. The leaked service-role JWT is signed with it.

⚠ **Two switches, both needed.** "Disable the legacy API keys" makes the gateway refuse the old keys as `apikey`. It does
NOT stop the leaked JWT sent as `Authorization: Bearer` next to a valid publishable key, because the HS256 key still
verifies it as role `service_role`. Only revoking the HS256 signing key closes that. Revoking is not reversible, so it
is the very last step.

**Gateway behaviour, probed with a dry run** (`stamp-sheets-reminder`, `verify_jwt = true`, `{dry_run:true}`):
a real `sb_secret_` key passes the gateway (the function's own check then answered 403); a fake `sb_secret_...`
answers 401 "Invalid API key" from the gateway; no key answers 401. So `verify_jwt = true` functions need NO gateway
change: only each function's own caller check, which today decodes the JWT's `role` claim and cannot read a secret key.

## 2. Who uses the old keys (logs over the 24 hours to 23:20 UTC, plus code and stores)

| # | user | old key | moves to | what changes |
|---|---|---|---|---|
| 1 | The database calling edge functions: 30 `fn_request_*` / trigger functions through `net.http_post` | legacy service-role JWT in vault `edge_invoke_service_key` and `jobber_push_service_key` (both fingerprint `5dbfb3f552`) | the `default` secret key (never leaves Supabase; it is what the edge functions already hold) | 2 vault values |
| 2 | The edge functions' own "is this a service caller" check | decodes the JWT `role` claim (32 files, no shared helper; 46 functions `verify_jwt = true`, 34 `false`) | one shared helper: accepts the old JWT role claim AND a secret key | edit + deploy each, read each body back |
| 3 | GitHub Actions, 10 workflows | Actions secret `SUPABASE_SERVICE_ROLE_KEY` | new secret key "github-actions" | 1 Actions secret, then run each workflow once |
| 4 | PDF service (Railway) | legacy JWT; `supabase==2.10.0` refuses a non-JWT key | the `railway` key | bump supabase-py, test, deploy, set the variable |
| 5 | Field Portal `/login` server function (Lovable server env) | legacy JWT, only `rpc/get_client_by_code` | new secret key "field-portal", or none (SECURITY-34 says it is no longer needed) | Lovable server env, republish |
| 6 | Every staff app, the Field Portal and DUMP in the browser | legacy anon key (`supabase-js-web`, every office network) | the `default` publishable key | each app's env var, republish, one app at a time |
| 7 | Local scripts (`Supabase/.env`, `Slack/.env`, pdf-service and GDO bot `.env`) | legacy JWT and legacy anon | new secret key "office", publishable key | the `.env` lines |
| 8 | To check before the switch | Viktor (SECURITY-30: may hold a service-role key), Postman, Lovable server functions of other apps, Realtime private channels | as found | inventory first |

Already on new keys: every edge function's injected key (the `default` secret key), the edge functions' injected
anon key (the publishable key), the Samsara jobs and the GDO Slack bot (`railway`).

## 3. Order, each step with its check

Steps 1 to 3 and 7 are invisible to staff. Step 6 touches each app. Steps 9 and 10 are the switch.

1. **Shared caller check.** `_shared/service-caller.ts`: a caller is the service when its bearer is the function's own
   `SUPABASE_SERVICE_ROLE_KEY` (exact match), or any `sb_secret_` key on a `verify_jwt = true` function (the gateway has
   already refused a fake one), or, until step 10, a JWT whose role is `service_role` on a `verify_jwt = true` function.
   Roll it into the 32 files. Check: each deployed body read back (`scripts/probes/edge_deployed_body.js`); a dry-run
   call with the new key answers 200 and with the old JWT still 200; a fake key 401; no key 401.
2. **Vault.** Put the `default` secret key in both vault entries. Check: the next run of every cron that posts (the 30
   functions) writes its normal `sync_log` row; `ops.v_health_status` shows nothing new.
3. **GitHub Actions.** New secret key "github-actions", set the Actions secret. Check: dispatch each of the 10 workflows
   once, each `success`, and the logs show the new key's hash from Microsoft.
4. **PDF service.** Bump supabase-py to a version that takes `sb_secret_` keys, run its tests, deploy, set `railway`.
   Check: the `/images/rotate` probe; a reprint on test client 112-YA (never a real visit, it spends a sheet number).
5. **Field Portal login.** Remove the server key if login works without it (SECURITY-34), else a "field-portal" key.
   Check: log in to a real client portal, open a visit report.
6. **Apps, one at a time** (Apps Hub, Admin Review, Client App, Stamp Studio, DERM Tracker, Visit Calendar, HR App,
   Picture Planner, Field Portal, DUMP): set the publishable key, republish. Check, on the live site at 1440 and 375:
   sign in, the main list loads, one save, a realtime refresh where the app has one, the bundle carries
   `sb_publishable_` and no legacy anon JWT for Prod. Claim each Lovable project in `WORKING-NOW.md` first.
7. **Local `.env` files.** New secret key "office" and the publishable key. Check: a read-only script and `q.cjs`.
8. **Watch for 24 hours.** Rerun the key query of the breach record, section 7: zero legacy anon and zero legacy
   service-role calls. Anything left is a user this plan missed: move it, watch again.
9. **Disable the legacy API keys** (dashboard, Settings, API Keys). Reversible. Check: every app (step 6 checks), every
   cron, the leaked JWT as `apikey` answers 401.
10. **Revoke the legacy HS256 signing key**, after a quiet day following step 9, with Fred's OK at that moment. Not
    reversible. Check: the leaked JWT as `Authorization: Bearer` with the publishable key answers 401 on REST and on an
    edge function; staff sessions keep working (they are ES256).

Rollback: steps 1 to 8 keep the old path working; step 9 is undone by re-enabling the legacy keys; step 10 has none,
which is why it waits.

## 3b. Progress

| step | state | evidence |
|---|---|---|
| 1. shared caller check | ✅ 2026-10-23 13:20 ET | `aab4ac0`. `isSecretKeyCaller` in `_shared/service-caller.ts`, rolled into 31 functions (all `verify_jwt = true`), each deployed body read back. Before deploying, each function's live body was compared with git (dates and distinctive lines): only comment changes were undeployed. Canary `stamp-sheets-reminder` dry run: new secret key 200, old JWT 200, fake key 401, no key 401. The database's calls after the deploys all 200/202. Standing check `scripts/checks/service_caller_gateway.mjs` (31 importers pinned and live, 4 gateway cases), with a mutation control that makes it fail. The helper trusts the `sb_secret_` prefix only behind the gateway: measured, the gateway refuses a made-up secret key ("Invalid API key") and a bearer that differs from the apikey header ("Conflicting API keys"). |
| 2. vault | ✅ 2026-10-23 13:28 ET | `edge_invoke_service_key` and `jobber_push_service_key` now hold the `default` secret key (fingerprint `46cfa6ab8b`, the edge functions' own key), were `5dbfb3f552` (the legacy JWT). Script `scratchpad/rw/vault_step2.cjs` (fingerprints only). Rollback: the same update with the legacy JWT from `Supabase/.env`. |
| 3. GitHub Actions | ✅ 2026-10-23 14:05 ET | New secret key "github_actions" (fingerprint `d2e3361a2c`, no local copy; Supabase can reveal it) set as the Actions secret `SUPABASE_SERVICE_ROLE_KEY` of `webunclogmecom/supabase`, the only repo that held the key. Checked first: the job scripts use the key only as `apikey` / `Bearer` for REST and Storage (their JWT decodes are of Jobber tokens), and Storage accepts a secret key (admin bucket list 200). Proven by four runs started by hand: Samsara telemetry, truck-on-visit, completion reconcile, note photos (the last failed once on the Management API's rate limit, `429` on the account token, which this session's own queries share, and passed on re-run). The other six run on their schedules or by hand only (the two Samsara fallbacks run the scripts Railway already runs with a secret key). Script `scratchpad/rw/step3_github.cjs`. Found: `OLD_SUPABASE_*` Actions secrets from April, unused here, left alone (SECURITY-18). |
| 4. PDF service | ✅ 2026-10-23 14:15 ET | supabase-py 2.10.0 -> 2.18.1 and pydantic 2.10.3 -> 2.14.1 (pdf-service `97e4216`, 0.8.2; 342 tests pass; the service's read helpers run against Prod with a secret key in a local venv; 2.10 refuses the key, the control). Deployed with the old key first, then the Railway variable switched to the "railway" key (`42ba972c38`) and redeployed (`419be2e3`, SUCCESS). Probe: a preview for a visit id that does not exist answers 404 "No matching visits found", which needs a successful read. Supabase's logs: supabase-py 2.18.1 on the railway key at 18:15 UTC, nothing on the old key since. Rollback: set the legacy JWT back (0.8.2 accepts both). |
| 5. Field Portal login | ✅ 2026-10-25 19:14 ET | **Done:** after a Publish, a live login on fp.unclogme.app (23:14:53 UTC) sent `sb_secret_6hIXz` / hash `bTrhT-cfoQ`, HTTP 200, and a visit report opened. The value Fred saved was the right key both times (his screenshot); my "most likely not the `sb_secret_` key" below was WRONG. The real cause: **a changed Lovable server secret reaches neither preview until the app is published**, despite Lovable's note. The publish carried no code (History: the 10-19 version was the latest and already published). ⚠ The editor preview may keep sending the legacy JWT until its dev server restarts; step 8's 24-hour watch will show it if it does. History of the step: The key sits in the Lovable project's server secrets (`PERSONAL_SUPABASE_SERVICE_ROLE_KEY`, read by `src/lib/auth.functions.ts`); a session never types a key into a web form. New secret key "field_portal" created 2026-10-23 (log hash prefix `bTrhT-cfoQ`, tested 200 on `get_client_by_code`). 2026-10-24: Fred deleted and re-created the Lovable secret (created date Oct 24 in the Secrets list), but test logins on BOTH the preview (20:41 UTC) and fp.unclogme.app (20:34, 20:35) still sent the legacy service-role JWT (`TFkQyI`). Lovable says a secret change applies to the preview at once, so the saved value is most likely not the `sb_secret_` key. 2026-10-25: saved again (created date Oct 25), and the editor's LIVE preview login (21:48:41 UTC) and the build preview (21:42:44) still sent `TFkQyI`. The code reads `PERSONAL_SUPABASE_SERVICE_ROLE_KEY` first (`src/lib/auth.functions.ts`, `src/integrations/personal-supabase/client.server.ts`), and `TFkQyI` is the legacy SERVICE-ROLE signature (not the anon one), so that variable holds the legacy JWT. The "field_portal" value has no local copy; it is copied from the dashboard's Secret keys list (not the Legacy tab). Next: Fred re-pastes the "field_portal" value (starts `sb_secret_`), the session re-tests the preview, then a publish (the editor already shows unpublished changes) and a live login, each checked in the edge logs. |
| 6. the apps | **needs Fred** for the same reason (the publishable key is public by design, but it is still pasted into each project's settings); the session prepares each app's change and checks it live. ⚠ Learned on step 5: a pasted value is live only after a Publish, and the preview is no evidence. Each app: Fred pastes, the session publishes (only when History shows no unpublished code from someone else), then checks the live bundle and the edge log. **Admin Review ✅ 2026-10-26 ~15:09 ET** (`.env` only; live `index-DZU1FDt7.js` carries `sb_publishable_-QrT6` and no JWT; edge log: 143 requests from the app with the publishable key, all 200, 0 legacy; save `review_set_visit_manholes` on test visit 8113 set and cleared; 1440 and 375; Admin Review changelog 2026-10-26). **Apps Hub ✅ 2026-10-26 ~16:32 ET** (`.env` only; live `index-iaZRhq7-.js`, 6 chunks, no JWT; edge log since the publish all publishable, all 200; 1440 and 375; Hub changelog 2026-10-26 (b)). **Client App ✅ 2026-10-26 ~16:50 ET** (the key was a literal in `src/lib/db.ts`, not `.env`; live `index-D8wKyj3R.js`, no JWT; edge log since the publish all publishable, all 200; a saved view created and deleted; Client App changelog 2026-10-26). **Stamp Studio ✅ 2026-10-26 ~17:02 ET** (literal in `src/lib/supabase-derm.ts`, no `.env`; all 7 chunks identical to the old build with keys masked; realtime subscribed and received a probe; edge log all publishable, all 200; no save on purpose, every write changes a DERM sheet). **DERM Tracker ✅ 2026-10-26 ~17:35 ET** (literals in `src/integrations/personal-supabase/client.ts` and `src/routes/index.tsx`; 25 of 27 chunks identical with keys masked, the other 2 identifier renames only; edge log 84 publishable, all 200, 0 legacy; realtime websocket 101; no save on purpose). **Visit Calendar ✅ 2026-10-26 ~17:44 ET** (`.env` + the fallback in `src/lib/supabase-prod.ts`; chunks identical bar minifier renames; edge log 85 publishable, all 200, 0 legacy; a realtime probe refetched, a quiet control did not; no save on purpose, writes push to Jobber). **HR App ✅ 2026-10-26 ~17:49 ET** (literal in `src/lib/supabase.ts`; all 14 chunks identical with keys masked; edge log all publishable, all 200, 0 legacy; no save on purpose). Next: Stamp Studio, DERM Tracker, Visit Calendar, HR App (key hardcoded in `src/lib/supabase.ts`), Picture Planner, Field Portal. DUMP ships no key |
| 7 to 10 | not started | 7 needs a choice: local scripts that call `verify_jwt = false` functions compare the EXACT default key, so a separate "office" key would break them. |

Found on the way, not part of this plan: `inbound-file-drain` has no caller check of its own, so any valid project key or staff sign-in reaches it (the gateway is its only gate).

## 4. Then

Mark SECURITY-16 done in `system-audit-2026-10-05/REPORT.md`, update `docs/security.md`, the root handbook
(`ACCESS.md`, `INCIDENT.md`), every app's `CLAUDE.md` line that names the anon key, and close Trello 8IBiZL5Z.
