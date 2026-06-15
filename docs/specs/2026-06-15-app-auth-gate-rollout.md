# App Auth Gate — Rollout guide (Fred's steps + Lovable prompts)

Companion to `2026-06-15-app-auth-gate-design.md`. The **backend is already done** (see "Done by Claude" below). What remains needs you: the Google OAuth client, then running the Lovable login-guard prompts, after which Claude applies the per-app anon-write revoke (A2).

---

## ✅ Already done by Claude (Supabase backend, 2026-06-15)

- Shared fallback account `unclogme@unclogme.com` created (email-confirmed, login verified). Password is the agreed Phase-1 value (kept in the team password manager — not written here; this repo is public).
- Fail-closed domain hook live + tested: only `@ayache.com` / `@unclogme.com` can create accounts; a real gmail signup was rejected (403, no user created).
- `site_url` + redirect allow-list set to the 3 app URLs (was `localhost:3000`).
- A1 applied: `authenticated` is a verified peer of `anon` (identical read counts; authenticated write confirmed) → **adding login will NOT break the apps**.
- A2 (anon-write revoke) written + staged, NOT applied: `docs/migrations/STAGED_2026-06-15c_auth_revoke_anon_write_DO-NOT-APPLY-YET.sql`.
- **Google provider ENABLED 2026-06-15** (client `…0928881…`; secret stored in Supabase encrypted config, never committed). Verified: `/auth/v1/authorize?provider=google` → 302 to accounts.google.com.
  - ⚠ **Check the Google consent-screen publishing status** when you first sign in: if it's in **"Testing"**, only added test users can get in (add Yannick/Fred/Aaron as test users, or click **Publish app** → "In production"). Our domain hook still does the real restriction; "Production" here just means the Google app isn't limited to a test-user list. Symptom if it's Testing: "Access blocked / app is being tested."
  - You can now delete the downloaded `client_secret_….json` from Downloads — the secret lives in Supabase config.

## Step 1 — ✅ DONE: Google OAuth client (Fred created, Claude enabled)
Original instructions kept below for reference. Client + secret received and enabled via the Management API on 2026-06-15.

1. Google Cloud Console → APIs & Services → **Credentials** → Create Credentials → **OAuth client ID**.
2. App type: **Web application**.
3. **Authorized redirect URI:** `https://wbasvhvvismukaqdnouk.supabase.co/auth/v1/callback`
4. OAuth consent screen: **External** (so it can serve both `ayache.com` and `unclogme.com`; the Supabase hook does the domain restriction, not the consent screen).
5. Copy the **Client ID** and **Client secret** and hand them to Claude. Claude enables the Google provider via the Management API (no dashboard) — that's the last backend bit.

## Step 2 — Fred: run the login-guard prompt in each Lovable app

Paste this into the Lovable chat of **each** app (Visit Calendar, DERM Tracker, Admin Review). It's the same pattern; nothing app-specific to change.

> Add a Supabase Auth login gate to this app using our EXISTING Supabase client (do not create a new Supabase project or change the Supabase URL/anon key — keep the current Prod connection).
>
> Behavior:
> - On load, if there is no Supabase session, show a clean login screen (UnclogMe brand: #f14714 orange, Manrope) with two options: a "Sign in with Google" button (`supabase.auth.signInWithOAuth({ provider: 'google' })`) and an email + password form (`supabase.auth.signInWithPassword`). No public sign-up link.
> - If there IS a session, render the app exactly as it does today.
> - Use the default persistent session (persistSession + autoRefreshToken) so users stay logged in.
> - Add a small "Sign out" action somewhere unobtrusive (`supabase.auth.signOut()`).
> - Subscribe to `supabase.auth.onAuthStateChange` so the UI flips between the login screen and the app without a manual refresh.
> - Accessibility: labeled email/password inputs, keyboard-navigable, visible focus ring, and login errors announced (role="alert").
> - Do not change any data queries — they already work; they'll simply run as the logged-in user now.
>
> After building, keep the app published at its current custom domain.

**Testing note:** the OAuth redirect allow-list is set to the 3 published URLs. If you test the Google flow inside the **Lovable preview** (a `*.lovable.app`/`*.lovableproject.com` URL), the redirect will fail until that preview URL is added — easiest is to test on the **published** URL, or tell Claude the preview URL to add it temporarily. The **email/password** login works in preview regardless.

## Step 3 — Claude: enable Google provider + apply A2 per app

Once you hand over the Google creds and confirm an app's login works in production:
1. Claude enables the Google provider via the Management API.
2. For that app, Claude applies its section of the staged A2 migration (revokes anon write on that app's tables), then verifies the logged-in app can still save and that an anon `/rest/v1` write is now rejected.
3. `visits` (Section D) is revoked only after BOTH Calendar and DERM logins are live (both write it).

## Order / safety

- Login (Step 2) goes live BEFORE the A2 revoke (Step 3) for each app — the live apps write as anon until they have a login, so revoking first would break them.
- Everything is reversible: the hook disables via one API flag; A2 re-grants anon via the documented rollback.
- Phase 1.5 (revoke anon READ) and Phase 2 (CRM SSO, real per-user accounts, frame-ancestors) come later per the design spec.
