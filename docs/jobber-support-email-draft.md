# Email draft to api-support@getjobber.com

Copy/paste-ready. Update `[your email]` and `[your name]` before sending.

---

**To:** api-support@getjobber.com
**Subject:** Webhooks not delivering for In-Development app — Account 1444605, App fbd14714

---

Hi Jobber API team,

We have an **In-Development** app ("Unclogme Supabase Sync") that is OAuth-authorized against our production Jobber account, but it is **not receiving webhook deliveries** despite all 22 subscribed topics being correctly configured. I'd like your help confirming whether Jobber's infrastructure is even attempting delivery — and if there's a server-side block we should know about.

### App details

- **App name:** Unclogme Supabase Sync
- **App status:** In Development (not published)
- **Client ID (App ID):** `fbd14714-b6e9-46c5-97cb-9856ed6a41e9`
- **Authorized account ID:** `1444605` (Unclogme — verified via `account { name }` GraphQL query)
- **Webhook URL:** `https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/webhook-jobber`
- **Refresh-token rotation:** disabled (per Dev Center toggle)

### Verifications we've done on our side

- **OAuth flow completes successfully** with all 14 scopes we require (read_clients, read_jobs, read_scheduled_items, read_invoices, read_quotes, read_users, read_requests, read_expenses, read_custom_field_configurations, read_time_sheets, read_equipment, read_jobber_payments, write_tax_rates, write_custom_field_configurations).
- **GraphQL queries against the authorized account succeed** — we can read clients, visits, invoices, etc. normally and `account { name }` returns "Unclogme".
- **Our endpoint is reachable.** We have a script that synthesizes webhook payloads, HMAC-signs them with our OAuth `client_secret`, POSTs to our webhook URL, and is processed correctly within ~300–500ms. The Edge Function processes these synthetic webhooks end-to-end without issue.
- **22 subscribed topics**, configured in Dev Center: CLIENT_CREATE/UPDATE/DESTROY, JOB_CREATE/UPDATE/CLOSED/DESTROY, VISIT_CREATE/UPDATE/COMPLETE/DESTROY, INVOICE_CREATE/UPDATE/DESTROY, QUOTE_CREATE/UPDATE/SENT/APPROVED/DESTROY, PROPERTY_CREATE/UPDATE/DESTROY.
- **HMAC verification uses the OAuth `client_secret` per docs.** When real webhook events DID arrive a few times historically (April 21–25), they verified successfully once we fixed our signing implementation. So signing is correct.

### What we observe today

We performed a controlled test:
- **At 20:50:51 UTC**, an admin user updated a client's first_name and last_name in the production Jobber UI.
- We immediately verified via `clients(filter: {updatedAt: {after: ...}})` GraphQL that **Jobber registered the edit** — the client appears with the new `firstName`/`lastName` and the new `updatedAt`.
- **Our webhook endpoint received zero events** in the 5+ minutes that followed.

We have records of only **6 real webhook deliveries** from Jobber to our endpoint since 2026-04-21, despite hundreds of edits in the Jobber UI in that window. Last real delivery: 2026-04-25 06:43 UTC.

### What I'd like to know

1. Can you confirm from Jobber's side whether webhook deliveries have been **attempted** for app `fbd14714-b6e9-46c5-97cb-9856ed6a41e9` against account `1444605` in the last 24 hours? If so, what response codes did Jobber's infrastructure see?
2. Do **In-Development** apps deliver webhooks to their authorized accounts on the same delivery semantics as published apps? Or is there a different posture for in-dev apps that isn't documented?
3. Is there a delivery-log / "recent attempts" view in the Developer Center that we have overlooked? Each webhook subscription row in our app's Dev Center page doesn't appear to expose a delivery history.
4. If there is a "send test webhook" tool we could use to trigger a known delivery and trace it, please point us to it.

We're happy to provide additional logs, raw request captures (we don't see real Jobber requests reaching us, so there's nothing to share from our side), or an endpoint timestamp window for correlation.

Thank you for any insight — this is the last unresolved piece of our integration.

Best,
[your name]
[your email]
Unclogme LLC

---

## Tips when sending

- Send from a real user mailbox (not a no-reply alias) so they can reply.
- Don't include the actual `client_secret` in the email — only the `client_id`. If they ask to verify, share over a secure channel.
- Mention you're a paying Jobber customer (the production Unclogme account is on a paid plan) — moves it from "developer query" to "customer support."
- If they don't respond within ~3 business days, the polling cron is still running, so there's no operational urgency to chase them.
