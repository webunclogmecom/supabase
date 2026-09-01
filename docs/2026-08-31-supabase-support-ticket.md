# Supabase support ticket — draft (GoTrue / Auth down, data plane healthy)

*Draft for Fred to submit via the Supabase dashboard support form (or support@supabase.io).
Severity: high / production down. Project is on the Pro plan.*

---

**Subject:** Auth (GoTrue) down ~24h — 503 on all /auth/v1/* while the data plane is healthy; restart did not fix

**Project ref:** `wbasvhvvismukaqdnouk`
**Region:** us-east-1
**Plan:** Pro

**Summary**

Every endpoint under `/auth/v1/*` on our project has been returning **HTTP 503 continuously for
about 23 hours** — first seen the morning of **2026-08-31 ET** and still down now (**2026-09-01,
~09:00 ET**), so this has run into a second business day. No user can sign in, and our apps that
verify sessions via `getClaims()` (which fetches `/auth/v1/.well-known/jwks.json`) are all broken.
**Postgres and PostgREST are completely healthy the entire time** — `/rest/v1/*` responds normally —
so this is isolated to the Auth service.

**Exact response from the gateway** (GET `/auth/v1/health` with a valid apikey):

```
HTTP/2 503
server: cloudflare
body: upstream connect error or disconnect/reset before headers. retried and the latest
      reset reason: remote connection failure, transport failure reason:
      delayed connect error: 111
```

`delayed connect error: 111` (connection refused) with the Envoy retry note indicates the gateway
cannot reach the GoTrue upstream at all — it looks like the Auth container is down / not accepting
connections, not a slow or erroring response.

**Affected (all 503 with a valid apikey):**
- `GET /auth/v1/.well-known/jwks.json`
- `GET /auth/v1/health`
- `GET /auth/v1/settings`
- `POST /auth/v1/token?grant_type=password` (login)

**Healthy (control):** `GET /rest/v1/*` responds normally (401 without a session, 200 with — i.e.
the database and PostgREST are fine).

**What we already tried**
- A full project restart from the dashboard. It completed — the project returned to
  `ACTIVE_HEALTHY` and Postgres restarted — but it **did not revive the Auth service**; `/auth/v1/*`
  continued to 503 immediately afterward and still does.

**Impact**
- Production, now spanning a second business day. Every staff member is locked out of every app that
  uses Supabase Auth. We have had to stand up a temporary workaround to keep operating, and we need
  normal auth back. Please treat this as an active production outage.

**Request**
- Please investigate and restart / recover the GoTrue (Auth) service for
  `wbasvhvvismukaqdnouk`. If there is anything on our side that could cause GoTrue specifically to
  fail to start (a config value, a migration, a JWT signing-keys issue) while Postgres stays healthy,
  please point us at it.

**Reference request IDs** (from earlier probes, in case they help you trace it):
- `01a05872-089d-71e2-b9b4-9ff5a4a54a52`
- `01a05863-9c84-7af1-8f99-1f761e970915`
- A current failing request carries `CF-Ray: a3447e8c7cd7cc68-MAD` (2026-09-01 13:06 UTC).

Thank you — happy to provide anything else that helps.

---

*Note for us: attach a fresh failing `CF-Ray` / timestamp when you actually submit, since the ones
above will be old by then. The `auth_recovery_check.js` probe prints the current status any time.*

---

## ✅ RESOLVED 2026-09-01

**Root cause (Supabase support, Richard Kasprzak):** an invalid duration in the User Sessions config crashed GoTrue on startup - `GOTRUE_SESSIONS_TIMEBOX` could not be parsed (`time: invalid duration`). The Auth > Sessions fields are in **HOURS** (max 8760); they had been set to `sessions_timebox=2592000` and `sessions_inactivity_timeout=1209600`, i.e. **30 days and 2 weeks expressed in SECONDS** dropped into the HOURS fields. As hours, `2592000h` (~296 years) **overflows Go`s `time.Duration`** (int64 ns, ~292y max), so GoTrue failed config load and every `/auth/v1/*` returned 503. It stayed dormant until a restart re-parsed the config on the morning of 2026-08-31.

**Fix:** set Time-box user sessions = **720** h (30 days) and Inactivity timeout = **168** h (1 week) in Auth > Sessions, and Save. GoTrue restarted with valid `720h`/`168h` durations. Verified: `config/auth` shows `sessions_timebox=720`, `sessions_inactivity_timeout=168`; the recovery probe returned `RECOVERED` (jwks/health/settings 200, login processing); a real staff login succeeded. Emergency no-auth mode was then fully reverted.
