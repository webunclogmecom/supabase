# App Auth Gate — Design Spec

**Date:** 2026-06-15
**Status:** Design v2 (plan-mode) — **audited 2026-06-15** (adversarial multi-lens review); one open decision in §13 before this becomes an implementation plan.
**Author:** Fred + Claude (brainstorm)
**Scope:** Visit Calendar, DERM Tracker, Admin Review (the three internal Lovable apps). **FP + HR excluded** (see §12).

---

## 1. Goal & threat model

**Goal:** stop the internal apps from being usable by anyone who simply has the URL. Today `calendar.unclogme.app`, `derm.unclogme.app`, and `grease-buddy-dash.lovable.app` are public with **anon-permissive RLS and no login**.

**What "anon-permissive" actually means today (VERIFIED live 2026-06-15)** — the anon role (key ships in every app's JS bundle, public by design) has, via `/rest/v1`, not just read but **write** access to:
- `visit_reviews`, `shift_reviews` — INSERT/UPDATE/DELETE → **driver bonus / payroll decisions**
- `derm_manifests`, `manifest_visits` — INSERT/UPDATE/DELETE → **DERM compliance records**
- `visits`, `visit_assignments`, `photo_classifications` — INSERT/UPDATE/DELETE → visits, crew assignments, photo tags

So a mildly technical visitor can today **approve/deny bonuses, alter compliance records, delete assignments, and inject visits** — none of which a client-side login screen touches. This reframes the security assessment (§10) and drives the open decision (§13).

**Threat model (Fred, 2026-06-15):** keep the *public / random URL visitor* out. Not a tight per-user/RBAC exercise. **But** see §13 — "not tight" was originally stated against a *read*-exposure understanding; the verified *write* exposure to payroll/compliance warrants an explicit re-confirm.

**Users in scope:** office staff only (Yannick, Fred, Aaron) on `ayache.com` / `unclogme.com` Google accounts, plus a shared fallback login. Drivers/field/customers are NOT in scope for these three apps.

## 2. Non-goals

- **FP (Field Portal) + HR app** — out of scope (see §12).
- **Per-user identity / roles / RBAC** — deferred to Phase 2 (real users arrive with the CRM).
- **MFA** — out of scope for Phase 1's keep-the-public-out goal (adds friction; wouldn't meaningfully protect a shared account). Reconsider with per-user accounts in Phase 2.
- **Full anon-READ lockdown** — deferred to Phase 1.5 (§9); reads share base tables/views with FP and need a per-table audit.

## 3. Constraints discovered (why the design is what it is)

- **Apps are Lovable-hosted behind Lovable's own Cloudflare.** `unclogme.app` NS is GoDaddy; `calendar.unclogme.app` resolves to Lovable ingress `185.158.133.1`. The Cloudflare we see is **Lovable's CDN, not our zone**.
  - ⇒ **An edge gate (Cloudflare Access / Zero Trust) is NOT available** — we don't control that layer. Re-platforming just to gate it isn't justified.
  - ⇒ **The gate must live inside the apps** = Supabase Auth.
- **All three apps run on the same Prod Supabase project** (`wbasvhvvismukaqdnouk`) ⇒ they share one `auth.users` pool — one account set works across all three; provisioning is one place. (NB: this is a shared *credential store*, NOT a shared session — see §4.2.)
- **Only the apps write the high-value tables as anon.** Crons/webhooks write via the `service_role` key (bypasses RLS); the Jobber-push trigger is SECURITY DEFINER. So once the apps authenticate (Phase 1 login), revoking anon *write* breaks nothing app-side — this is what makes the §13 write-lockdown low-risk.
- **Resend is wired** (used by `send-derm-email`) ⇒ a delivery path exists, but the **auth mailer is NOT pointed at Resend** today; Supabase's default SMTP is heavily throttled (see §8).
- **The CRM (ops-portal) is not deployed yet** ⇒ apps are used **standalone today**. Per-app login is the correct Phase-1 move and the foundation Phase-2 SSO builds on — not throwaway.
- **Apps currently send no `X-Frame-Options`/CSP** ⇒ anyone can iframe them (clickjacking surface). Addressed in Phase 2 (§9).

## 4. Phase 1 — the gate (now)

Add **Supabase Auth** to Calendar, DERM Tracker, and Admin Review.

### 4.1 Providers (both enabled, same `auth.users` pool)

**1. Google OAuth**, one-click, **restricted to `ayache.com` and `unclogme.com`** — restriction is mandatory and enforced server-side (Supabase's Google provider otherwise admits any gmail).

- **Mechanism — a fail-CLOSED Before-User-Created Auth Hook implemented as a Postgres function** (NOT an Edge/HTTP hook, NOT an `auth.users` trigger):
  - A Postgres-function hook runs *in the signup transaction*; returning an error reliably aborts user creation and **cannot fail-open**. An HTTP/Edge hook can time out or 5xx and (depending on config) fail-open — unacceptable for the one control the whole gate rests on. A raw `BEFORE INSERT` trigger on `auth.users` is rejected as the fallback: it risks interfering with GoTrue's own flows. Grant `EXECUTE` to `supabase_auth_admin`.
  - Verified 2026-06-15: `/config/auth` exposes `hook_before_user_created_enabled`/`_uri` (off today); `auth.users` is empty with no triggers → clean slate. We deploy + enable via the Management API, no dashboard.
- **⚠ Known limitation — the hook sees `user.email` but NOT Google's `hd` (hosted-domain) claim or `email_verified`.** Domain string-matching alone could in principle be passed by an *unverified* Google account whose profile email is set to an `@unclogme.com` address. **Required mitigation + test:** confirm whether Supabase's Google provider rejects `email_verified=false` (it generally trusts Google-verified emails); if `email_verified` is surfaced to the hook, also require it true; and the §6 acceptance test MUST include creating a throwaway off-domain Google account with a spoofed domain email and confirming it is rejected (no `auth.users` row). Treat "the hook is strong" as UNPROVEN until that negative test passes.
- **Prerequisite (Fred — the one hard dependency):** create a Google Cloud OAuth client (ID + secret), consent screen "External" (to span both domains), redirect URI `https://wbasvhvvismukaqdnouk.supabase.co/auth/v1/callback`; hand Claude the ID + secret.

**2. Shared email+password fallback** — account `unclogme@unclogme.com`, password **stored in the team password manager** (placeholder `<SHARED_PW>` in this doc — the repo is public; the literal value is NOT committed). On `unclogme.com`, so the hook admits it.
- **Must be created via the Admin API with `email_confirm: true`** — `mailer_autoconfirm=false` (verified), so a normally-created account would sit unconfirmed and be unable to log in.
- Accepted weakness (Fred): a shared credential, no per-person identity; replaced with real per-user accounts in Phase 2.

**3. Account creation gated by the hook, not globally disabled.** The hook restricts *all* creation (Google + email/password) to the two domains. Leave Supabase's global "Disable signups" toggle OFF (it would also block new Google-domain users). Office Google users self-onboard on first sign-in; randoms are rejected by every path.

### 4.2 Session behaviour — persistent, but NOT single sign-on

- Supabase JS defaults (`persistSession` + `autoRefreshToken`) ⇒ **log in once per app, stay logged in for months** (silent refresh).
- **This is three separate logins, not SSO.** Sessions live in per-origin `localStorage`; there is no cross-origin session sharing. A user logs in separately at `calendar.unclogme.app`, `derm.unclogme.app`, and `grease-buddy-dash.lovable.app` — and the last is a *different registrable domain*, so it can never share a session with the `unclogme.app` subdomains even via a cookie-domain trick. SSO arrives only in Phase 2 (CRM handoff). The shared `auth.users` pool means the same *credentials* work everywhere, not the same *session*.

### 4.3 Per-app work (Lovable — Claude drafts prompts, Fred runs)

Each app gets a **login screen / auth guard** (unauth → "Sign in with Google" + email/password; authed → app as today), wired to the Prod URL + existing anon key. Login-guard prompt MUST specify **accessibility** (labeled fields, keyboard-navigable, visible focus, announced errors) and handle the **logged-out / expired-session** state explicitly.

| App | URL | Phase-1 change |
|---|---|---|
| Visit Calendar | calendar.unclogme.app | login guard (+ write-RLS swap per §13) |
| DERM Tracker | derm.unclogme.app | login guard (+ write-RLS swap per §13) |
| Admin Review | grease-buddy-dash.lovable.app | login guard (+ write-RLS swap per §13) |

### 4.4 OAuth redirect config (REQUIRED, or sign-in dead-ends)

Verified: `site_url` is still the default `http://localhost:3000`. Before Google works we must, via the Management API:
- set `site_url` to a real app URL;
- populate the redirect allow-list with the **exact** per-app callback URLs for all three apps — **no wildcards** (an over-broad allow-list is an open-redirect risk);
- (NB: resolve any Lovable project-id/domain discrepancy for Calendar before finalizing the redirect list.)

## 5. Rollout order & break-glass (REQUIRED — avoids public-gap AND self-lockout)

Strict order; verify each step before the next:
1. **Create + verify the shared account FIRST** (Admin API, `email_confirm:true`) and confirm it can log in — *before* enabling the hook, so a hook bug can't block the one guaranteed fallback.
2. Configure backend: Google provider creds, `site_url` + redirect allow-list, deploy + enable the Postgres-function hook.
3. **Run the §6 acceptance tests** (esp. the negative off-domain Google test) — gate must prove it works before app changes.
4. Apply the login guard per app, one at a time; confirm each shows the wall logged-out and lets a domain user in before moving to the next.
5. (If §13 = yes) apply the write-RLS swap per app *after* that app's login is live (so the app writes as `authenticated`).
- **Break-glass / rollback:** the gate is reversible in one step each — disable the hook (`hook_before_user_created_enabled=false` via API), and the write-RLS swap is revert-by-migration. Keep the shared account + service-role access as the break-glass path. Note: existing open anon tabs are NOT force-logged-out in Phase 1 (only the RLS work ends anon sessions).

## 6. Acceptance tests (the gate must prove itself)

- **Positive:** an `ayache.com` and an `unclogme.com` Google account each sign in to each app; the shared account signs in.
- **Negative — the critical one:** a random `@gmail.com` Google sign-in is rejected and creates **no** `auth.users` row; an off-domain email/password signup is rejected; (see §4.1 ⚠) a Google account with a *spoofed/unverified* `@unclogme.com` profile email is rejected.
- **Redirect:** OAuth round-trips correctly after the `site_url`/allow-list fix (no localhost dead-end).
- **Wall:** each app, logged out, shows the login wall, not the app.
- **(If §13=yes) Write-lockdown:** an anon `/rest/v1` write to `visit_reviews`/`shift_reviews`/`derm_manifests`/`visits` is rejected; the logged-in app can still perform the same write.

## 7. Monitoring & drift detection (NEW)

The gate fails silently (a Lovable re-deploy can drop the guard; a hook could be disabled) — this team has been burned by silent green before. Add:
- a **pg_cron watchdog** asserting `hook_before_user_created_enabled=true` and `external_google_enabled=true` (via `/config/auth`), alerting to Slack on drift;
- a scheduled query flagging any `auth.users` email whose domain ∉ {ayache.com, unclogme.com};
- a checklist item (or synthetic check) to re-confirm each app shows the login wall **after every Lovable re-deploy**.

## 8. Recovery & email deliverability (NEW)

- Create the shared account with `email_confirm:true` (no confirmation email needed).
- **Point Supabase's auth SMTP at Resend** (recommended) — default SMTP is throttled to a few mails/hour, so OTP/confirmation/reset mail will otherwise be flaky.
- Document who owns the `unclogme@unclogme.com` inbox and the recovery path if the shared password is lost; note service-role/Management access is the ultimate break-glass.

## 9. Phase 1.5 & Phase 2 (later)

- **Phase 1.5 — anon-READ lockdown (NOT "cheap" — a per-table audit, give it a date + owner).** Flip remaining anon *reads* to `authenticated`. For each table/view, first **enumerate every reader/writer** (the three apps, **FP — which shares base tables/views**, crons, Edge functions, SECURITY-DEFINER triggers) and verify in the **anon context**, not just the logged-in app — a blanket flip can break FP, crons, the Jobber-push chain, or repeat the past SECURITY-DEFINER 401. **Trigger:** schedule within a defined window of Phase-1 go-live (don't let "whenever" leave the documented hole open indefinitely over PII/DERM/bonus data).
- **Phase 2 — CRM SSO + clickjacking lock (when ops-portal ships):**
  - CRM owns login; passes the Supabase session into each iframe via `postMessage` (pin the exact origin) → `supabase.auth.setSession(...)`. **Open risk to validate before relying on it:** browser **storage partitioning** (Chrome) / **ITP** (Safari) may block or partition the embedded app's session storage, and popup-based Google OAuth is often blocked inside iframes — so the passthrough (parent logs in, hands the session down) is the intended path precisely because the iframe may not be able to log in itself. Confirm empirically per browser.
  - Replace the shared account with real per-user accounts.
  - Add `Content-Security-Policy: frame-ancestors https://ops.unclogme.app` (confirm Lovable can set response headers). Blocks embedding by other sites; direct visits stay gated by the Phase-1 login.
  - **Explicitly avoided:** any "trust a token the portal injects without a real session" path (token-replay risk).

## 10. Honest security assessment (rewritten post-audit)

- **What Phase 1 (login only) protects:** a random URL visitor hits a login wall instead of the app UI.
- **What login alone does NOT protect:** the login is **client-side state**, not a network control. With RLS left anon, anyone who copies the anon key from the bundle and calls `/rest/v1` directly **reads AND writes** everything in §1 — including approving/denying **driver bonuses** and altering **DERM compliance**. The login wall does nothing for this path. ⇒ This is why §13 proposes pulling the **write**-lockdown into Phase 1.
- **Genuinely strong (once §4.1 hook + its negative test pass):** the Google-domain restriction. The shared `unclogme@…` account is the deliberate soft spot.
- **Compliance note:** the exposed data includes Miami-Dade DERM regulatory records and employee bonus/comp figures. Fred/Yan should confirm that the accepted Phase-1 trade (and any deferral of the read lockdown) is acceptable with that in mind, or pull Phase 1.5 forward.

## 11. Work split (verified 2026-06-15)

- **Fred — the only hard dependency:** create the Google Cloud OAuth client (ID + secret, "External" consent, redirect URI above); hand Claude the creds. Run the per-app Lovable login-guard prompts Claude drafts. Confirm the Workspace facts in §13.
- **Claude — everything else, no dashboard:** deploy + enable the fail-closed Postgres-function hook; configure Google provider + `site_url`/redirect allow-list; create the shared account (`email_confirm:true`); point auth SMTP at Resend; (if §13=yes) author the write-RLS swap migrations; build the pg_cron watchdog; draft the per-app guard prompts.

## 12. Out of scope — FP & HR

- **FP (Field Portal)** — client-facing (`customer.*`). No auth now. Future options: per-client magic-link, signed/expiring work-order URLs, or a light client login — designed separately to avoid customer friction.
- **HR app** — separate **dev** project (`klgtrdwrasrlxbmfyvdh`, legacy anon schema, employee/PII data). Carries the same public-URL exposure as these apps but is pre-production; **address when it goes to prod** (it'll want the same gate, arguably with stricter RLS given HR data).

## 13. OPEN DECISION for Fred — does the WRITE-lockdown move into Phase 1?

The audit verified the data API is **world-writable** to payroll (`visit_reviews`/`shift_reviews`), DERM compliance (`derm_manifests`/`manifest_visits`), and visits — bypassing any login screen. Two ways forward:

- **(A) Recommended — pull the write-lockdown into Phase 1.** For each high-value table: add an `authenticated` write policy mirroring the existing anon one, then drop the anon write policy + revoke the anon write grant. Because **only the apps write these as anon** (crons = service-role, Jobber-push = SECURITY DEFINER) and the apps will be logged in after the Phase-1 guard, this is low-risk and makes "we added auth" *real* for the dangerous paths. Anon *reads* still deferred to Phase 1.5. Modest extra work (a handful of mirror-policy migrations + the §6 write test).
  - **VERIFIED 2026-06-15 (audit.logs writer enumeration, 60d):** the only browser-app writers of these tables are `admin-review`, `derm-tracker`, `visit-calendar` (the three getting logins). **`field-portal` writes NONE of them.** All other writers (`sql`, `fog-backfill`, `service-agreement-cron`, `jobber-reconcile`, etc.) run as service-role/scripts that bypass RLS. ⇒ revoking anon write breaks nothing once the three apps authenticate. Sequencing (per §5): each app's login goes live BEFORE its anon-write is revoked.
- **(B) Login-wall only, eyes open.** Accept that bonuses/DERM/visits stay **world-writable via the anon API** until a later RLS pass — i.e. "anyone can rewrite payroll," not merely "anyone can read." Re-label the project outcome accordingly so no one assumes the data is protected.

**This is the one decision blocking the implementation plan.** Everything else above is settled.
