# Security

Secrets handling, token lifecycle, access control, and incident response for the Unclogme Supabase database.

---

## Threat model (what we're protecting against)

| Asset | Threat | Mitigation |
|---|---|---|
| Client PII (name, address, phone, email) | Unauthorized read → privacy breach, DERM audit exposure | Service-role key never in frontend; RLS policies; office/field role split |
| Invoice / A/R data | Unauthorized read or manipulation → financial fraud | Only `dev` group has direct write; payments flow via Jobber, audited |
| DERM manifest numbers | Forgery or destruction → compliance violation, $500–$3,000 fines × N | Append-only write path; `webhook_events_log` for audit |
| API tokens (Jobber, Airtable, Samsara) | Token exfil → source-system access | `webhook_tokens` table, service-role-only; never in frontend code |
| GitHub PATs | Accidental commit → repo push access | gh keyring auth (not embedded in `.git/config`); PAT scope review |
| Supabase service-role JWT | Leak → full DB admin | Never in browser; Edge Function secrets only; rotate on any suspicion |

---

## Secrets inventory

Every secret the project uses, where it lives, and how to rotate.

| Secret | Purpose | Stored in | Rotation |
|---|---|---|---|
| `SUPABASE_SERVICE_ROLE_KEY` | Full DB access for scripts + Edge Functions | `.env` (local) + Edge Function secrets (deploy) | Dashboard → Settings → API → Rotate service_role |
| `SUPABASE_PAT` | Management plane (CLI, Edge Function deploy) | `.env` (local only) | https://supabase.com/dashboard/account/tokens — regenerate |
| `JOBBER_CLIENT_ID` + `JOBBER_CLIENT_SECRET` | OAuth app identity | `.env` | Jobber Developer Center — regenerate OAuth app |
| `JOBBER_ACCESS_TOKEN` + `JOBBER_REFRESH_TOKEN` | Jobber API auth (refreshed ~every 60 min) | `webhook_tokens` row `source_system='jobber'` | Run `node scripts/jobber_auth.js` → paste new tokens → UPDATE `webhook_tokens` |
| `SAMSARA_API_TOKEN` | Samsara REST + webhook registration | `.env` + Edge Function secrets | Samsara dashboard → API tokens → Regenerate |
| `AIRTABLE_PAT` | Airtable Personal Access Token | `.env` + Edge Function secrets | https://airtable.com/create/tokens |
| `FILLOUT_API_KEY` | Fillout REST (sunset path) | `.env` | Fillout dashboard → API keys |
| `SLACK_WEBHOOK_URL` | Slack incident alerts | `.env` + Edge Function secrets | Slack admin → Incoming Webhooks |
| GitHub PAT (user-level) | `gh` CLI + git push | Windows Credential Manager / macOS Keychain (via `gh auth login`) | https://github.com/settings/tokens |

### Rules, non-negotiable

1. **Never commit `.env`.** `.env` is in `.gitignore`. Use `.env.example` as the template.
2. **Never embed a token in a git remote URL.** `git remote -v` should never show a token. Use `gh auth login` (keyring) instead.
3. **Never paste secrets into Slack, email, or docs.** If a secret is exposed in any logged channel, treat as compromised.
4. **Never reuse a dev/local token in production Edge Functions.** Function secrets are set via `supabase secrets set`, not via repo file.
5. **The `anon` key is public by design** and can be shipped in frontend code — its safety depends on RLS, not on secrecy. The `service_role` key is never public.

---

## Token rotation runbook

### Routine (quarterly)

Every 90 days, rotate:
- `SUPABASE_SERVICE_ROLE_KEY` (Dashboard → Settings → API → Rotate)
- `SUPABASE_PAT` (https://supabase.com/dashboard/account/tokens)
- `SAMSARA_API_TOKEN` (Samsara dashboard → API tokens)
- `AIRTABLE_PAT` (https://airtable.com/create/tokens)
- GitHub PATs used by humans (review scopes — `repo`, `workflow`, `read:org` is the default minimal set)

After rotating a secret used by an Edge Function:
```bash
supabase secrets set SUPABASE_SERVICE_ROLE_KEY=<new-value> --project-ref wbasvhvvismukaqdnouk
supabase secrets set SAMSARA_API_TOKEN=<new-value> --project-ref wbasvhvvismukaqdnouk
# Redeploy is NOT required — secrets update live.
```

### Jobber token refresh (automatic, but double-check)

The `webhook-jobber` Edge Function calls Jobber's OAuth refresh endpoint when the access token has <10 min of life. It writes the new access + refresh token to `webhook_tokens`. Verify health:

```sql
SELECT source_system, expires_at, updated_at
FROM webhook_tokens
WHERE source_system = 'jobber';
-- expires_at should always be within the next ~60 min
-- updated_at should be within the last ~60 min during business hours
```

If `expires_at` is in the past and hasn't moved in >2 hours, run `node scripts/jobber_auth.js` locally to mint a fresh pair and overwrite the row.

### Emergency rotation (compromise suspected)

If any secret appears in a commit, Slack message, log file, or screenshot:
1. **Revoke immediately** at the source (GitHub / Jobber / Supabase dashboard). Don't wait for rotation to complete.
2. **Rotate** — generate a new value.
3. **Update `.env` + Edge Function secrets + `webhook_tokens`** depending on what the secret was used for.
4. **Audit access** — check `webhook_events_log` for any anomalous activity with the compromised credential.
5. **Document** in `docs/runbook.md#incident-log`.

---

## Row-level security (RLS)

**Current posture (since 2026-04-25, commit `7cc73bb`):** RLS is **enabled on all 30 public tables**. The pattern in use is "RLS on with no policies" — service-role bypasses RLS by design, so Edge Functions and our Node scripts continue to work unchanged. anon and authenticated roles are denied because no policies grant them anything. This is the safe default for an operational warehouse with no end-user clients yet.

Triggered by a Supabase security alert (`rls_disabled_in_public` + `sensitive_columns_exposed` on `webhook_tokens`) — the alert is now resolved.

Verification: `SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r' AND c.relrowsecurity=false;` returns 0.

Related: all 7 `public.*` views and all 8 `ops.*` views have `security_invoker = true` (commits `9388819` and the audit-fix migration). They run as the querying role, so RLS on underlying tables is honored. No `SECURITY DEFINER` views exist anywhere in either schema.

**When end-user clients land** (Odoo.sh, Lovable-style apps), add explicit `CREATE POLICY` clauses on the tables they need to read. The pattern:

```sql
ALTER TABLE clients ENABLE ROW LEVEL SECURITY;

-- Read-only role (e.g. Odoo, Lovable)
CREATE POLICY "read_all" ON clients FOR SELECT TO authenticated USING (true);

-- No INSERT/UPDATE/DELETE policies → operations fail by default
```

Separate Postgres roles per integration:

```sql
CREATE ROLE odoo_readonly NOLOGIN;
GRANT USAGE ON SCHEMA public TO odoo_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO odoo_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON TABLES TO odoo_readonly;
```

Mint a JWT signed with the project's JWT secret (Dashboard → Settings → API → JWT Secret) with `role: "odoo_readonly"` in the claims. Hand that JWT to the integration.

**Never** give an external system the `service_role` key.

---

## Webhook signature validation

Each Edge Function validates the incoming request's authenticity before touching the DB. Without this, anyone who knows the public Edge Function URL could forge events.

| Source | Validation method | Secret source |
|---|---|---|
| Jobber | HMAC-SHA256 of request body with shared secret, compared to `X-Jobber-Hmac-Sha256` header | Jobber app settings + Edge Function secret |
| Airtable | Static bearer token in request header, compared to expected value | Airtable automation + Edge Function secret |
| Samsara | HMAC-SHA256 of request body with shared secret, compared to `X-Samsara-Signature` header | Samsara webhook config + Edge Function secret |

Details in [docs/integration.md](integration.md#webhook-signature-validation).

**Failure mode:** any request that fails signature validation is rejected with HTTP 401 and logged to `webhook_events_log` with `status='failed'` and `error_message='signature_invalid'`. Never process an unverified payload.

---

## Access control (people)

Defined in `docs/company.md` — repeated here with enforcement details.

| Group | Members | Can do | Cannot do |
|---|---|---|---|
| **dev** | Fred, Yan | Everything | — |
| **office** | Aaron, Diego | Read all; create clients, visits, invoices; edit scheduling | Delete core data; rotate secrets; deploy Edge Functions |
| **field** | Technicians | Submit visit updates, incident reports, photos via apps | Read financial, payment, or client account data |

Enforcement today: access is managed at the *tool* level (Airtable permissions, Jobber roles, Fillout form scopes). Once Odoo.sh replaces Jobber + Airtable, access is managed in Odoo + RLS on this database.

Any request to "give a tech access to the client list" is a security event. Log in `#viktor-security-setup` and confirm with Fred or Yan directly.

---

## Incident response checklist

**Suspected credential leak:**
1. Revoke at source (don't wait).
2. Check `webhook_events_log` for anomalous requests in the last 24 h.
3. Rotate the secret.
4. Document in `docs/runbook.md`.

**Unauthorized data change suspected:**
1. Pull recent changes from `updated_at` descending on the affected table.
2. Cross-reference with `webhook_events_log` by `entity_type` + `entity_id`.
3. If `webhook_events_log` does not show the change, a direct DB actor made it — review `audit_log` in the Supabase dashboard (Settings → Audit Logs).
4. Determine scope (which rows, which fields, when).
5. Restore from Supabase point-in-time recovery (Pro plan, 7-day PITR) if needed.

**Webhook flood (possible DDoS or source-system misconfiguration):**
1. Check `webhook_events_log` count per minute.
2. If spike is from one `source_system`, contact the source's support (Jobber / Airtable / Samsara).
3. Temporarily disable the Edge Function via the dashboard if needed — source systems will buffer webhooks and retry.

---

## What's missing (roadmap for "big tech company" posture)

- [x] RLS enabled on every public table (2026-04-25 / commit `7cc73bb`).
- [ ] Explicit RLS policies on tables that end-user clients (Odoo.sh / Lovable) need to read — add when those integrations land in May 2026.
- [ ] Automated secret rotation (currently manual, quarterly).
- [ ] SOC 2 audit posture (not needed at current scale, re-evaluate at $2M revenue).
- [ ] Per-Edge-Function service accounts (currently all share `service_role`).
- [ ] PII redaction in logs (`webhook_events_log.payload` contains full client data — acceptable at dev team of 2, revisit when office/field groups get query access).

See `docs/runbook.md` for operational procedures, `docs/decisions/` for architectural decisions.
