# Jobber write-OAuth setup (Phase 2 — Calendar → Jobber write-back)

**Goal:** give our Jobber integration **write** access (create/update jobs + visits) so visits
created in our Calendar push into Jobber. The read-sync already works; this only **adds write**.

**Why Yannick:** a Jobber OAuth token inherits the **permissions of the user who clicks "Allow."**
Fred's Jobber login isn't an administrator, so his token can't write. **Yannick's is an admin** — so
an admin must do the authorization step (#3). That's the only blocker (task #80).

What we need back at the end: **Client ID + Client Secret + Refresh Token** (send securely — these are
secrets). Fred/Claude stores them in `public.webhook_tokens` and the write-back sync uses them.

---

## Step 1 — App + write scopes (Jobber Developer Center)
1. Go to **developer.getjobber.com** and sign in (the Jobber Dev account that owns our app — Yannick's).
2. Open the existing **Unclogme** app (or **+ New App** if there isn't one).
3. In the app's **Scopes / Permissions**, enable **READ + WRITE** for at least:
   - **Clients** (read)
   - **Jobs** (read + **write**)
   - **Scheduling / Visits** (read + **write**)
   *(Keep every read scope the integration already uses; just add the write ones. Exact scope names
   are shown in Jobber's UI — pick the write equivalents of jobs + scheduling/visits.)*
4. Under **Redirect URIs**, add this exact URI — **it MUST be `https://`** (Jobber rejects `http://`):
   **`https://localhost:3000/callback`**
   *(If Jobber also refuses `localhost`, use a domain we own instead, e.g.
   `https://fp.unclogme.app/jobber-callback` — nothing has to actually serve it; see Step 3.)*
5. Copy the app's **Client ID** and **Client Secret** (Settings / OAuth section). Save them for Step 4.

## Step 2 — Point our tool at the app
On the machine doing the exchange (Fred's), in `Supabase/.env` set:
```
JOBBER_CLIENT_ID=<the app's Client ID>
JOBBER_CLIENT_SECRET=<the app's Client Secret>
JOBBER_REDIRECT_URI=https://localhost:3000/callback   # must match Jobber EXACTLY
```

## Step 3 — Authorize AS AN ADMIN (the critical step), then exchange the code
Because the redirect must be `https://`, we can't auto-capture on a plain local server. We do a
no-server manual exchange instead. **The token inherits the permissions of whoever clicks "Allow"**,
so an **admin (Yannick)** must do the Allow click — but anyone can run the exchange.

1. Print the consent URL:
   ```
   node scripts/jobber_auth_https.js
   ```
2. Open that URL in a browser **logged into Jobber as Yannick (the admin)**, review the permissions
   (should now include the write scopes), and click **Allow**. *(If Fred drives it, log into Yannick's
   Jobber account in that browser first; or send Yannick the URL and have him send back the result.)*
3. The browser lands on `https://localhost:3000/callback?code=XXXX`. **That page won't load — that's
   expected.** Copy the full URL (or just the `code=...` value) from the address bar.
4. Exchange it for tokens:
   ```
   node scripts/jobber_auth_https.js --code "<paste-the-code-or-full-url>"
   ```
   It saves the **access_token + refresh_token** to `.env`. The **refresh_token** is the long-lived one.
   *(The code is single-use and expires fast — if it errors with `invalid_grant`, just re-run step 1
   for a fresh one.)*

## Step 4 — Hand the credentials to Fred / Claude
Send (securely): **Client ID**, **Client Secret**, and the **Refresh Token** from Step 3.
Claude stores them in `public.webhook_tokens` (the row the syncs read), replacing the read-only token
with the write-capable one. From then on, the write-back sync can create jobs/visits in Jobber.

---

## Notes
- Re-authorizing with the admin **replaces** the token in `webhook_tokens`; the read-syncs keep working
  (write scope is a superset). No downtime.
- If you'd rather keep a separate write app, that's fine too — just send all three values for it; we can
  store a second token row.
- The refresh token rotates on use but stays valid; our syncs refresh the short-lived access token
  automatically.
