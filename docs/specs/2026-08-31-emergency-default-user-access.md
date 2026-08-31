# Emergency access mode: the `Default` user

*Spec written 2026-08-31 during a live Supabase Auth outage, at Fred's direction: "We need to keep
working, and no app with an Auth is working, so we gotta do a temporary fix ... make it so we work
with a user called `Default` ... and just make all the apps skip the auth."*

**Status: SPEC ONLY. Nothing here is built. It needs Fred's go-ahead on scope (which apps) and one
secret only he can retrieve.**

---

## 1. The measurement this whole design rests on

Taken live at 12:5x ET while `/auth/v1/*` was returning 503:

| probe | result | meaning |
|---|---|---|
| `service_role` -> `/rest/v1/clients?limit=1` | **HTTP 200** | **the data plane is completely healthy** |
| `anon` -> same | 401 | anon holds nothing |
| service_role / anon JWT header | **`{"alg":"HS256"}`** | legacy symmetric keys |
| `has_table_privilege('anon', ...)` on 9 core objects + all 9 `customer.*` views | **false / 0 of 9** | anon cannot read anything |

🛑 **THE LOAD-BEARING FACT: PostgREST validates an HS256 JWT LOCALLY against the project's JWT
secret. It never calls GoTrue.** That is why `service_role` returns 200 right now while every login
is dead. So a token we mint ourselves is accepted by the database **during the outage**, and the
entire fix can avoid touching `anon` grants.

⇒ **This is what makes a safe version possible.** Without it the only "quick" option would be
granting `anon` SELECT across the business tables, and the anon key ships in every public bundle in
two public repos.

---

## 2. What we are NOT doing, and why

**We are not granting anything to `anon`.** The anon key is public by design. Granting it read on
`clients` / `visits` / `properties` / `derm_manifests` / `customer.*` publishes the entire client
book, contact emails, addresses and compliance manifests to anyone who opens a bundle.

🛑 **And a GRANT cannot be time-boxed.** Grants do not expire; a person has to remember to revoke
them. This estate has direct evidence of how that goes: `client_email_live_sends` was set to
`false` "for testing" and was still false three days later, found only by a sweep, because nothing
expires it. A "3-hour" grant is one distraction from being permanent.

**The design below expires by construction.** Its access is a JWT with a short `exp`. If every
human forgets it exists, it stops working anyway. That property is the entire reason to prefer it.

---

## 3. Design

### 3a. The `Default` identity

A fixed sentinel UUID plus the claim `email: default@unclogme.com`.

🛑 **Do NOT reuse a real person's UUID** (the tempting shortcut, since creating a new auth user
needs GoTrue, which is down). Minting everyone's actions under Fred's identity would put false
per-person attribution into a compliance trail, which is worse than no attribution.

⚠ **`auth.uid()` will resolve to a UUID with no row in `auth.users`.** Before shipping, check that
no RLS policy on a table the chosen apps write JOINS `auth.users`; policies that only compare
`auth.uid()` or test the role are fine. This is a five-minute check and it is a hard gate.

**Audit trails keep working, and stay honest.** `audit.logs.changed_by` has never been populated
(it reads the singular `request.jwt.claim.sub`, PostgREST sets the plural); real attribution rides
on `jwt_claims->>'email'`, which will read `default@unclogme.com`. So the trail will say plainly
"this was done in emergency mode", which is the correct and auditable outcome.

### 3b. `emergency-session` edge function

```
POST /functions/v1/emergency-session   { "passphrase": "..." }
  -> 200 { token, expires_at }   |   401 on mismatch
```

- Validates against edge secret `EMERGENCY_PASSPHRASE`.
- Mints HS256 signed with edge secret `EMERGENCY_JWT_SECRET`:
  `{ role:"authenticated", aud:"authenticated", sub:"<sentinel-uuid>",
     email:"default@unclogme.com", app_mode:"emergency", iat, exp: now + 4h }`
- `verify_jwt = false` in `config.toml` (it must be callable without a session - that is the point),
  so the passphrase is the only gate. Rate-limit by IP.
- Logs every issuance (time, IP, user agent) to `public.emergency_session_grants`.

🛑 **`exp` MUST be <= 4 hours and the function MUST refuse to mint a longer one.** This is the
mechanism that makes the whole thing self-limiting.

### 3c. App change, behind a build flag

- `VITE_EMERGENCY_AUTH=true` swaps the session gate for a passphrase screen.
- On success the token goes in **`sessionStorage`**, never the shared cookie.
  🛑 **It must NOT be written to `sb-wbasvhvvismukaqdnouk-auth-token`.** That cookie is shared across
  all six apps on `.unclogme.app`; writing a hand-minted token into it would corrupt the real
  session store for every app and survive the outage.
- The Supabase client is constructed with
  `global: { headers: { Authorization: "Bearer <token>" } }` - PostgREST honours it and GoTrue is
  never contacted.
- A **persistent banner** on every screen: `Emergency access - signed in as Default. Your actions are
  recorded as Default, not as you.` Non-dismissible.

### 3d. Scope: which apps

⚠ **Do not do all six.** Each app is a separate Lovable project: prompt, build, publish, verify,
roughly 20-25 minutes each, so six is 2 to 2.5 hours and may outlast the outage itself. Pick the
apps where work is actually blocked right now (dispatch and manifest filing are the usual answer)
and leave the rest showing the honest self-retrying screen, which now recovers on its own.

---

## 4. Rollback, and it is not optional

1. `VITE_EMERGENCY_AUTH=false`, republish every app that received it.
2. Delete the `emergency-session` function.
3. Rotate `EMERGENCY_PASSPHRASE`.
4. Confirm `public.emergency_session_grants` shows no issuance after the window.

✅ **Even if all four are forgotten, every minted token is dead within 4 hours.** Contrast a GRANT,
which lives until a human removes it.

---

## 5. Honest risk statement

| risk | severity | mitigation |
|---|---|---|
| passphrase leaks -> holder gets full `authenticated` access | **high while live** | 4h token cap, rotate on close, issuance log |
| per-person accountability lost for the window | medium | trail explicitly reads `default@unclogme.com`; window is bounded |
| flag left on after recovery | medium | rollback checklist; tokens expire regardless |
| `auth.uid()` has no `auth.users` row | **blocks writes if a policy joins it** | pre-flight check, section 3a |
| GoTrue returns mid-window, two auth paths coexist | low | flag off + republish |

**This is deliberately a smaller, temporary auth system that we control, not the absence of auth.**
"Skip the auth" in a public SPA means either staff-level data access exposed publicly, or a secret
the user supplies. This spec chooses the second.

---

## 6. What Fred must supply

1. **Which apps.** (Recommendation: the one or two that are actually blocking work.)
2. **The JWT secret** - Supabase Dashboard, Settings -> API -> JWT Settings. Paste it into the edge
   function's secrets in the dashboard yourself; it must never enter a repo, a bundle, or a chat.
3. **The passphrase**, set the same way.
