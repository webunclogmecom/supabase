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
4. Under **Redirect URIs**, make sure this exact URI is listed:
   **`http://localhost:3000/callback`**
5. Copy the app's **Client ID** and **Client Secret** (Settings / OAuth section). Save them for Step 4.

## Step 2 — Point our tool at the app
On the machine doing the auth (Fred's, or Yannick's), in `Supabase/.env` set:
```
JOBBER_CLIENT_ID=<the app's Client ID>
JOBBER_CLIENT_SECRET=<the app's Client Secret>
JOBBER_REDIRECT_URI=http://localhost:3000/callback
```

## Step 3 — Authorize AS AN ADMIN (the critical step)
1. In the **same browser**, log into **Jobber as Yannick (the administrator)** — i.e. the "Allow"
   click must happen on the admin account, not Fred's. *(If Fred is running it, log into Yannick's
   Jobber account in that browser first.)*
2. From `Supabase/`, run:
   ```
   node scripts/jobber_auth.js
   ```
   It opens Jobber's consent page. Confirm it's the **admin** account, review the requested
   permissions (should now include the write scopes), and click **Allow**.
3. On success it captures the **access_token + refresh_token**. The **refresh_token** is the long-lived
   one we need.

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
