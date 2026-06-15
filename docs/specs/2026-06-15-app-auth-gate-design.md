# App Auth Gate — Design Spec

**Date:** 2026-06-15
**Status:** Design (plan-mode) — approved direction, pending spec review → implementation plan
**Author:** Fred + Claude (brainstorm)
**Scope:** Visit Calendar, DERM Tracker, Admin Review (the three internal Lovable apps). **FP excluded** (client-facing — separate future effort).

---

## 1. Goal & threat model

**Goal:** stop the internal apps from being usable by anyone who simply has the URL. Today `calendar.unclogme.app`, `derm.unclogme.app`, and `grease-buddy-dash.lovable.app` are public with **anon-permissive RLS and no login** — anyone with the link can read PII (clients, visits), financial data (driver bonuses), and DERM compliance, and in places write (classify photos, save reviews, edit visits).

**Threat model (Fred, 2026-06-15):** keep the *public / random URL visitor* out. **Not** a tight data-security exercise — explicitly accepted. No per-user roles, no RBAC, no audit-attribution requirement (the DB already attributes writes via the `app_source` header).

**Users in scope:** office staff only (Yannick, Fred, Aaron) on `ayache.com` / `unclogme.com` Google accounts, plus a shared fallback login. Drivers/field/customers are NOT in scope for these three apps.

## 2. Non-goals

- **FP (Field Portal)** — client-facing; no auth added now; revisit separately later.
- **Tight data-layer security in Phase 1** — see §6; the Phase-1 gate is a UI/login wall, not a vault. RLS hardening is deferred to Phase 1.5.
- **Per-user identity / roles / RBAC** — deferred to Phase 2 (real users arrive with the CRM).

## 3. Constraints discovered (why the design is what it is)

- **Apps are Lovable-hosted behind Lovable's own Cloudflare.** `unclogme.app` nameservers are GoDaddy (`domaincontrol.com`); `calendar.unclogme.app` resolves to Lovable's ingress (`185.158.133.1`). The `Server: cloudflare` / `CF-RAY` we see is **Lovable's CDN, not our zone**.
  - ⇒ **An edge gate (Cloudflare Access / Zero Trust) is NOT available** — we don't control that Cloudflare layer, and double-proxying a Lovable app through our own Cloudflare isn't clean. Re-platforming hosting just to gate it isn't justified for "keep the public out."
  - ⇒ **The gate must live inside the apps** = Supabase Auth (native to the whole stack, first-class in Lovable).
- **All three apps run on the same Prod Supabase project** (`wbasvhvvismukaqdnouk`) ⇒ they already **share one `auth.users` pool**. One small set of accounts works across all three; provisioning/revoking happens in one place.
- **Resend is already wired** (used by `send-derm-email`) ⇒ a delivery path for any auth emails already exists; no new dependency.
- **The CRM (ops-portal) is not deployed yet** ⇒ apps are used **standalone today**. The CRM iframe + SSO is a future phase. This makes per-app login the correct Phase-1 move (it's used standalone anyway) **and** the foundation the SSO phase builds on — not throwaway.
- **Apps currently send no `X-Frame-Options`/CSP** ⇒ anyone can iframe them today (clickjacking surface). Addressed in Phase 2 (§5).

## 4. Phase 1 — the gate (now)

Add **Supabase Auth** to Calendar, DERM Tracker, and Admin Review.

### 4.1 Providers (both enabled, same `auth.users` pool)

1. **Google OAuth**, one-click "Sign in with Google", **restricted to `ayache.com` and `unclogme.com`**.
   - **The domain restriction is mandatory and must be enforced server-side.** Supabase's Google provider by default admits *any* Google account (any gmail) — without enforcement the "Sign in with Google" button opens the gate to the entire internet, defeating the goal.
   - **Mechanism:** a Supabase **Before-User-Created Auth Hook** (preferred) — or a `BEFORE INSERT` trigger on `auth.users` — that rejects any email whose domain is not in `{ayache.com, unclogme.com}`. The hook fires on first sign-in (when the user row is created). Enforcing at the Supabase layer (not the Google consent screen) is required because the consent-screen "internal" restriction only covers a single Workspace org, and we have two domains.
   - **VERIFIED 2026-06-15 (Management API probe):** the project exposes `hook_before_user_created_enabled` / `hook_before_user_created_uri` in `/config/auth` (currently off) — so we can deploy the hook (Postgres function or Edge Function) and enable it via the API, no dashboard. `auth.users` is empty (0 rows) with no existing triggers → clean slate, zero migration risk.
   - **Prerequisite (Fred action — the one genuine hard dependency):** create a Google Cloud OAuth client (client ID + secret) with authorized redirect URI `https://wbasvhvvismukaqdnouk.supabase.co/auth/v1/callback`, and hand the client ID + secret to Claude. Everything else (enabling the provider, the hook, redirect URLs) is then done via the Management API — no dashboard clicks needed from Fred.

2. **Shared email+password fallback** — `unclogme@unclogme.com` / `unclogme` (Supabase identifies accounts by email, so it's an email, not a bare username).
   - **Accepted weakness (Fred, 2026-06-15):** the password equals the company name and is guessable; it is the weak link in the Phase-1 gate. Accepted deliberately for low friction; **replaced with real per-user accounts in Phase 2** when the CRM ships.

3. **Account creation gated by the domain hook, not globally disabled.** The same Before-User-Created hook (§4.1.1) restricts *all* account creation — Google OAuth *and* email/password — to `{ayache.com, unclogme.com}`. So:
   - Office Google-domain users self-onboard on first "Sign in with Google" (no pre-provisioning needed) — the hook lets their domain through.
   - A random person cannot self-register an email/password account (wrong domain → hook rejects), and cannot Google-in (wrong domain → hook rejects).
   - The shared `unclogme@unclogme.com` account is on `unclogme.com`, so it passes the hook; we create it once.
   - **Do NOT use Supabase's global "Disable signups" toggle** — it would also block new Google-domain users from onboarding. Domain gating is the hook's job.

### 4.2 Session behaviour

- Supabase JS defaults: `persistSession: true` + `autoRefreshToken: true` ⇒ **log in once per app, stay logged in for months** (token silently refreshes; re-auth only on storage-clear or explicit sign-out). This is the "long-lived session/cookie" requirement.
- JWT access-token expiry can be left at default (1h) since refresh is automatic.

### 4.3 Per-app work (Lovable — Claude drafts prompts, Fred runs)

Each of the three apps gets:
- A **login screen / auth guard**: unauthenticated → show "Sign in with Google" + email/password; authenticated → render the app as today.
- Supabase Auth client wired with the Prod URL + anon key already in use (no new project).

| App | URL | Phase-1 change |
|---|---|---|
| Visit Calendar | calendar.unclogme.app | add login guard |
| DERM Tracker | derm.unclogme.app | add login guard |
| Admin Review | grease-buddy-dash.lovable.app | add login guard |

### 4.4 RLS in Phase 1

**Left `anon`-permissive as-is** (no RLS flip). The Phase-1 gate is a **UI/login wall** — it stops casual URL visitors (the actual goal) but does not lock the data API (see §6). This keeps Phase 1 low-risk (no chance of breaking existing queries) per the accepted not-tight trade.

## 5. Phase 1.5 & Phase 2 (later)

- **Phase 1.5 — RLS hardening (cheap, when wanted):** flip the apps' tables/views from `anon` to `authenticated` so the data API itself requires a logged-in session, not just the UI. Closes the §6 gap. Do per-app, verifying queries still pass.
- **Phase 2 — CRM SSO + clickjacking lock (when ops-portal ships to `ops.unclogme.app`):**
  - The CRM owns login; it passes the Supabase session into each embedded iframe via `postMessage` → `supabase.auth.setSession(...)`. **No second login** — same session mechanism, just a different *supplier*. Because Phase 1 already makes each app "require a real Supabase session," this is additive, not a rebuild.
  - Replace the shared `unclogme@unclogme.com` account with **real per-user accounts** (Google-domain users already work; add/remove people).
  - **Add `Content-Security-Policy: frame-ancestors`** locking embedding to `https://ops.unclogme.app` only (kills the open-iframe / clickjacking surface that exists today). Note: `frame-ancestors` blocks *embedding by other sites* but not direct top-level visits — direct visits are already gated by the login from Phase 1.
  - **Explicitly avoided:** a "trust a token the portal injects without a real session" path. That invents a weaker trust route (token replay if leaked via URL/history/referer). The app always requires a real Supabase session regardless of who supplies it.

## 6. Honest security assessment

**What Phase 1 protects:** a random person who finds/guesses an app URL hits a login wall instead of the app. That is the stated goal and Phase 1 meets it.

**What Phase 1 does NOT protect (accepted):** with RLS left `anon`, the data API (`/rest/v1/...`) remains technically reachable by anyone who extracts the anon key from the app's JS bundle and crafts requests directly. The login is a UI deterrent, not a data vault. This is an accepted Phase-1 trade; Phase 1.5 (RLS flip) closes it.

**Genuinely strong even in Phase 1:** the Google-domain restriction (if the §4.1 hook is in place) — only `ayache.com`/`unclogme.com` Google accounts can authenticate. The shared `unclogme:unclogme` account is the deliberate soft spot.

## 7. Work split (refined after the 2026-06-15 Management-API verification)

Almost the entire backend is doable by Claude programmatically (Management API for `/config/auth`, `service_role` Admin API for users, SQL/Edge for the hook) — same access level we use for crons + Edge Functions. The split:

- **Fred — the only hard dependency:** create the Google Cloud OAuth client (client ID + secret) with redirect URI `https://wbasvhvvismukaqdnouk.supabase.co/auth/v1/callback`; hand Claude the ID + secret. (Consent screen "External" so it can span both domains.) Then run the per-app Lovable login-guard prompts Claude drafts (the login UI lives in the Lovable apps).
- **Claude — everything else, no dashboard:**
  - Deploy the domain-restriction hook (Postgres function or Edge Function) gating ALL account creation to `{ayache.com, unclogme.com}`; enable it via `/config/auth`.
  - Enable + configure the Google provider via the Management API (once Fred supplies creds); email provider already on.
  - Set `site_url` + redirect allow-list to the real app URLs (currently the default `http://localhost:3000` — must be fixed or OAuth redirects fail).
  - Create the shared `unclogme@unclogme.com` account via the Admin API.
  - Leave the global "Disable signups" toggle OFF (domain gating is the hook's job).
  - Draft the per-app Lovable login-guard prompts.
- **Confirm:** the two Google Workspaces (`ayache.com`, `unclogme.com`) exist and all office users have an account on one of them.

## 8. FP (Field Portal) — deferred note

FP is client-facing (`customer.*` reads). No auth in this effort. Future options to consider when securing it: per-client magic-link access, signed/expiring work-order URLs, or a lightweight client login — to be designed separately so as not to add friction for customers.
