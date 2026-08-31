# Supabase support ticket — draft (GoTrue / Auth down, data plane healthy)

*Draft for Fred to submit via the Supabase dashboard support form (or support@supabase.io).
Severity: high / production down. Project is on the Pro plan.*

---

**Subject:** Auth (GoTrue) returning 503 on all /auth/v1/* for hours — data plane healthy, restart did not fix

**Project ref:** `wbasvhvvismukaqdnouk`
**Region:** us-east-1
**Plan:** Pro

**Summary**

Every endpoint under `/auth/v1/*` on our project has been returning **HTTP 503** for several hours
(first seen the morning of 2026-08-31 ET, still down as I write this). No user can sign in, and our
apps that verify sessions via `getClaims()` (which fetches `/auth/v1/.well-known/jwks.json`) are all
broken. **Postgres and PostgREST are completely healthy the entire time** — `/rest/v1/*` responds
normally — so this is isolated to the Auth service.

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
- Production. Every staff member is locked out of every app that uses Supabase Auth. We have had to
  stand up a temporary workaround to keep operating, and we need normal auth back.

**Request**
- Please investigate and restart / recover the GoTrue (Auth) service for
  `wbasvhvvismukaqdnouk`. If there is anything on our side that could cause GoTrue specifically to
  fail to start (a config value, a migration, a JWT signing-keys issue) while Postgres stays healthy,
  please point us at it.

**Reference request IDs** (from earlier probes, in case they help you trace it):
- `01a05872-089d-71e2-b9b4-9ff5a4a54a52`
- `01a05863-9c84-7af1-8f99-1f761e970915`
- A current failing request also carries `CF-Ray: a33fe701debe028a-MAD` (2026-08-31 23:44 UTC).

Thank you — happy to provide anything else that helps.

---

*Note for us: attach a fresh failing `CF-Ray` / timestamp when you actually submit, since the ones
above will be old by then. The `auth_recovery_check.js` probe prints the current status any time.*
