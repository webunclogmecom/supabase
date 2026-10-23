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

## 4. Then

Mark SECURITY-16 done in `system-audit-2026-10-05/REPORT.md`, update `docs/security.md`, the root handbook
(`ACCESS.md`, `INCIDENT.md`), every app's `CLAUDE.md` line that names the anon key, and close Trello 8IBiZL5Z.
