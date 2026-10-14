# Delivered / Opened chips: audit and recommended plan

*2026-10-14 · audits `2026-10-14-email-delivery-status-chips-plan.md` after step 0 · plan only, nothing built*

Fred: *"Do an audit about this, and only plan for now, what's the best decision, you can even do a research online
about the best practices for it."*

How it was done: one multi-agent run. Five readers worked in parallel: Resend's docs, open-tracking reliability,
archive-copy practice, a code audit of both senders, and a data audit with mail-server (MX) lookups. Then an options
paper, three judges (truthfulness, engineering risk, business), a synthesis, and a completeness critic, whose
corrections are folded in below. All of it was read-only: no send, no write, no deploy. The query results are in
the session scratchpad.

## 1. The best decision, in short

1. **Build the chips on "Delivered", and do not change the senders now.**
   - A city email shows **"Delivered to both city inboxes"** in Fred's D2 colour, with the tooltip *"We can't tell if
     they opened it."*
   - A client email can show **Opened** as a soft hint.
   - Delivered is the evidence standard everywhere. Opened is not proof in either direction.
2. **Do not build D5 yet. Decide it in 4 weeks, with numbers.**
   - D5 means sending our archive copy as a separate email.
   - Both cities run Microsoft 365. There, an "Opened" may come from a security scanner, and classic Outlook blocks
     the image, so real reads are missed.
   - So first measure what city opens look like (kept hidden, see 5.6). Change the two senders that write to
     regulators only if the data says the opens are real people.
3. **Build the back end this week, before the mockups.**
   - Every city send before the webhook is live loses its per-inbox record for good.
   - The backfill window closes on **2026-10-22 at 14:37 ET**, so the backfill must run by 2026-10-21.
4. **Diego should ask Surfside and Hallandale Beach three short questions** (section 7, decision 2). The A La Carte
   problem was the city's FOG BMP portal, and no chip fixes that.

## 2. What the audit found

1. **Opens cannot be credited to one recipient.** One email carries one tracking image, so an open counts for every
   recipient. Delivery is recorded per recipient.
   - Source: step 0 (plan file).
   - Resend's tracking docs: one image per email.
   - Standard industry fix: one message per recipient (AWS SES).
2. **Every real city email carries the archive Bcc `derm@ayache.com`.** That is 40 of 40 real city sends.
   - `send-derm-email/index.ts:1121-1126` adds `CITY_BCC` whenever there is no test recipient.
   - `send-visit-photos-email/index.ts:975`, sent at `:983`, always adds it.
3. **The logs do not show the archive copy reliably.**
   - Admin Review's `logSend` stores only the Bcc a person typed (`send-visit-photos-email/index.ts:623`).
   - The June and July `derm_email_sends` city rows show an empty Bcc.
   - So no rule may read "who else got it" from `bcc_emails` on city rows.
4. **Client emails have no archive copy, and their logs are accurate.**
   - One row per To address, all sharing one Resend id (`send-derm-email/index.ts:1367-1397`).
   - The Bcc is logged as actually sent (`:1396`).
   - 391 of 393 active clients have exactly one report recipient.
   - ⚠ **Zero client emails have been sent in the last 30 days.** The last real one was 2026-08-19.
5. **The visible Cc to outside addresses on city emails is unused.** `cityReportCc` (`send-derm-email/index.ts:1142-1181`)
   is configured on 0 clients, and 0 real sends ever had a Cc.
6. **Only two cities have an inbox on file, and both are Microsoft 365.** Surfside and Hallandale Beach have MX
   records that point to `mail.protection.outlook.com`.
   - Microsoft documents link scanning (Safe Links). Image pre-fetch by scanners is field-reported, not documented.
   - Classic Outlook blocks pictures by default.
   - So a city "Opened" may be a machine, and a real read may never register.
7. **What Resend can and cannot do** (Resend docs):
   - Open tracking is set for the whole domain, never for one email.
   - Resend suggests tracking opens only on broadcasts.
   - Batch sends cannot carry attachments.
   - Idempotency keys last 24 hours.
   - The rate limit is 10 requests per second.
   - Every To, Cc and Bcc address counts toward the quota, so D5 would add no quota.
   - Email data is kept for **30 days**.
   - "Retrieve email" gives one `last_event` for the whole email, not one per recipient.
   - Webhooks are signed with Svix, retried for about 27 hours, and not ordered.
8. **The backfill (D3) can only partly happen.**
   - Of the 77 real sends, 23 are still inside Resend's 30 days. 2 of those are 112-YA, so 21 are real customer
     sends. Each gets one summary (delivered or not), never "2 of 2".
   - The other 54 can only read "No delivery record".
   - The first real one drops out on **2026-10-22 14:37 ET**.
9. **The senders are fragile right after the Resend call.**
   - There is no timeout and no idempotency key.
   - A failed log insert is only printed (`send-derm-email:754-756`, `send-visit-photos-email:626-628`).
   - Both outer catch blocks log the send as an error (`send-derm-email:1204-1208`, `send-visit-photos-email:1005-1007`).
   - So any new code placed after a successful send (D5's second email) could make a delivered email look failed.
     This is the main reason not to rush D5.
10. **"Delivered" means the city's mail server accepted the email.** It can still land in junk or quarantine.
    Fla. Stat. 403.0741(3) asks for a copy to the municipality and the county. The chip covers only the city copy.
11. **Found on the side:** 112-YA property 162 has `fred@ayache.com` in `city_emails`.
    - So 112-YA "real" city sends exist (`derm_email_sends` 189, Oct 7).
    - `Supabase/CLAUDE.md` go-live step 0 says no internal address may sit in `city_emails`.
    - Harmless while 112-YA is excluded from counts and health checks, but every new view must exclude it.

## 3. Best practice (research, with sources)

- **Delivered is the proof.** It means the receiving server accepted the email, and Resend and Amazon SES define it the
  same way. Store it yourself, per address.
  ([Resend events](https://resend.com/docs/webhooks/event-types),
  [AWS SES](https://docs.aws.amazon.com/ses/latest/dg/monitor-using-event-publishing.html))
- **Opens are unreliable both ways.**
  - Apple Mail Privacy Protection and security scanners make opens nobody made.
  - Blocked images hide real reads.
  - So never show "Not opened" or "Unread", and never use a warning colour for a missing open.
  - Sources: [Apple](https://support.apple.com/guide/mail/mlhlp1205/mac),
    [Mailgun bot detection](https://documentation.mailgun.com/docs/mailgun/user-manual/tracking-messages/open-click-bot-detect),
    [Microsoft: Outlook blocks pictures](https://support.microsoft.com/en-us/office/block-or-unblock-automatic-picture-downloads-in-email-messages-15e08854-6808-49b1-9a0a-50b81f2d617a),
    [Postmark](https://postmarkapp.com/support/article/782-how-does-open-tracking-work).
- **An open belongs to one person only if the email had one recipient.**
  ([AWS SES blog](https://aws.amazon.com/blogs/messaging-and-targeting/how-to-send-messages-to-multiple-recipients-with-amazon-simple-email-service-ses/))
- **Resend suggests open tracking for broadcasts only,** because of inbox placement.
  ([Resend tracking](https://resend.com/docs/dashboard/domains/tracking))
- **Webhooks:**
  - Verify the signature over the raw body.
  - Deduplicate on the delivery id.
  - Compute the status from all events, never from the last one.
  - Keep your own copy, because the provider forgets after 30 days.
  - Sources: [Svix verification](https://docs.svix.com/receiving/verifying-payloads/how-manual),
    [Resend retries](https://resend.com/docs/webhooks/retries-and-replays),
    [Resend limits](https://resend.com/docs/knowledge-base/account-quotas-and-limits).
- **Read receipts are not proof and annoy recipients.** Don't add them. ([RFC 8098](https://www.rfc-editor.org/rfc/rfc8098.html))
- **Keep click tracking off.** Safe Links already rewrites and pre-clicks links.
  ([Microsoft Safe Links](https://learn.microsoft.com/en-us/defender-office-365/safe-links-about))

## 4. Options compared

| Option | City chip can say | Effort | Risk | Judges (truth / eng / business) |
|---|---|---|---|---|
| A. Keep the Bcc; city emails always use the D2 colour; senders unchanged | Delivered to both inboxes, open unknown | S | Low | 8 / 8 / 7 |
| B. D5: archive copy and internal Bcc sent as a second email | Opened (hint) or Delivered | M | Medium: both regulator senders change, the two sends can half-fail, the archive is no longer the exact email | 7 / 6 / 5 (about 7 if hardened) |
| C. One email per city inbox | Opened per inbox | L | High: breaks one-row-per-send; a scanner open names a person | 5 / 2 / 2 |
| D. Drop the archive email; keep the PDF + log + events instead | Opened or Delivered | L | High: loses the Gmail archive | 8 / 3 / 3 |
| E. Delivered / Bounced only, open tracking off | Delivered | S | Lowest, but loses client opens (D1) | 10 / 9 / 8 |
| F6. Keep the Bcc and trust nobody opens the archive | Opened | XS | Fails in the dangerous direction | 2 |

**Picked: A now, B only if the 4-week data passes the gate (5.6), plus the cities' answers.** E stays as the off
switch.

**Why A and not E, which scored highest:** for city emails A and E show exactly the same thing. A keeps client opens
(Fred's D1) and lets us measure city open timing for the D5 decision. If the watch shows deliverability trouble, or no
use for opens, switching to E takes a minute.

## 5. Recommended design

### 5.1 Senders
No change in phase 1: not to `send-derm-email`, `send-visit-photos-email`, the hourly sweep, or when emails go out.

### 5.2 Resend
- **Webhook endpoint:** `https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/webhook-resend`.
  - Events: `delivered`, `opened`, `bounced`, `delivery_delayed`, `complained`, `failed`, `suppressed`.
  - Not `sent`, not `clicked`.
  - Fred adds it in the dashboard. Its signing secret becomes the edge secret `RESEND_WEBHOOK_SECRET`, never printed.
- **Click tracking stays off.**
- **Open tracking stays on** for the 4-week watch (decision 3).

### 5.3 Edge function `webhook-resend` (about 150 lines, Web Crypto only)
- `verify_jwt = false` pinned in `config.toml`. The signature is the gate:
  - Svix HMAC-SHA256 over `id.timestamp.raw body`.
  - Any `v1,` signature may match.
  - A timestamp more than 5 minutes off is refused.
  - Anything that fails gets 401 and writes nothing.
- **Our emails only.** It parses the address out of `from` ("Name <addr>") and keeps the event only when the domain is
  exactly `unclogme.com`. Anything else gets 200 and is dropped.
- **One row per address in `data.to`.** Every row in the insert array has the same keys, because an array upsert NULLs
  any key some rows leave out. Insert with `ignoreDuplicates` on `(svix_id, recipient)`, then answer 2xx fast.
- **Backfill mode** (`{backfill: true}`):
  - Accepted only when the caller's key exactly matches the service key.
  - Runs `GET /emails/{id}` for every logged real send that has no events, at no more than 5 per second.
  - Reads one expired id first, so we know what an expired id returns.

### 5.4 Database (one migration plus a rollback file; the DDL transaction stays short)
- **`public.email_events`**
  - Columns: `svix_id`, `resend_email_id`, `event_type` (the 7 types plus `backfill_summary`), `recipient` (text NOT
    NULL DEFAULT '', lower-cased; '' for a summary row), `occurred_at`, `received_at`, `detail` jsonb (the
    bounce/failure reason only, never the body).
  - **Plain `UNIQUE (svix_id, recipient)`.** An expression key would break the upsert (42P10).
  - A trigger that refuses UPDATE and DELETE. (Built as a rule 8 OPT-OUT of audit.logs, the sync-only append default:
    rows are written once and can never change, so an audit row would only duplicate them.)
    Never purged.
  - service_role only: revoke by name from `public`, `anon` and `authenticated`, then assert `relacl`.
- **`app_config` keys:**
  - `email_open_tracking_since` = `2026-10-14 17:54:00+00`.
  - `email_open_tracking_until` = empty. Set it in the same minute tracking is ever switched off, or later emails
    would read "tracked, not opened".
- **`public.v_email_delivery`** (service_role only): one row per `resend_email_id` across the three send sources.
  - **To-line counting:**
    - City rows split the comma-joined `recipient_email`, then trim and lower-case it.
    - Client rows group their per-address rows by Resend id.
    - Only events on the To list count. 112-YA and other non-customer clients are excluded by joining
      `public.v_non_customer_clients`.
  - **Columns:** `delivery_status`, `to_count`, `delivered_count`, `bounced_count`, `delivered_at`, `opened_at`,
    `open_gap_seconds` (NULL when the open came before the delivery), `open_creditable`, `open_unknown_reason`,
    `bounce_reason` (addresses masked to "an inbox"), `summary_only`.
  - **An open is creditable only for a client send that meets all of these:**
    - `cc_emails` and `bcc_emails` are empty;
    - every recipient in its events is on its To list;
    - it was sent inside the tracking period.
  - **City sends are never creditable in phase 1.** `open_unknown_reason` is one of `archive_copy`, `other_recipients`,
    `before_tracking`, `tracking_off` or `summary_only`.
- **`public.v_visit_city_email_sends`:** append `delivery_status`, `delivery_at` and `delivery_detail` (jsonb: counts,
  `opened_at`, `open_unknown_reason`, masked bounce reason) at the END of the column list, so the grants survive. Both
  apps already read this view.
- **`public.v_client_email_sends` (new):** one row per real client send (`manifest_id`, `client_id`, `sent_at`,
  `sent_by`, `to_count`, plus the same 3 columns).
  - Grants: SELECT for `authenticated` and `service_role`, revoked from `anon` by name.
  - For the DERM Tracker client line and the Manifests "Emailed" chip.
- **Fixture checks run outside the DDL transaction,** as their own rolled-back transaction. They cover:
  - a 2-of-2 split of a comma list;
  - one bounced out of two;
  - a client open;
  - a city open that stays unknown;
  - a send from before tracking;
  - a negative gap;
  - a mutation control proving the old single-To counting fails the 2-of-2 case.

  Inside the migration: only grants, `relacl`, byte-identical old columns, and an unchanged row count.

### 5.5 Chips (same rules in both apps; colours picked at the mockup step)

Order: Not delivered, Bounced 1 of 2, Marked as spam, Delayed, then Opened / Delivered / Delivered with open unknown,
then Delivered 1 of 2, Sending, No status received, No delivery record.

| Chip | When | Tooltip |
|---|---|---|
| **Not delivered** (red) | No To address delivered, at least one refused | "Not delivered. The city's email system refused it on Oct 9, 3:12 PM. Check the city email on the property." (client: "...Check the client's email in the Client App.") |
| **Bounced 1 of 2** (red) | Some delivered, at least one refused | "Delivered to 1 of 2 city inboxes. The other refused it. Check the city emails on the property." |
| **Marked as spam** (amber) | A spam report on a To address | "Delivered, then reported as spam by the receiving email system on Oct 9, 3:40 PM." |
| **Delayed** (amber) | Delay, nothing final yet | "Not delivered yet. Their email system is holding it and we keep retrying." |
| **Opened** (soft green, same weight as Delivered; clients only in phase 1) | Every To address delivered, open creditable, open recorded | "Delivered Oct 9, 3:12 PM, opened 3:20 PM. A hint, not proof: phones and mail filters can open emails by themselves." |
| **Delivered** (blue) | Every To address delivered, creditable, tracked, no open yet | "Delivered Oct 9, 3:12 PM. No open recorded yet; many email programs block the image we use, so this does not mean unread." |
| **Delivered, open unknown** (Fred's D2 colour) | Every To address delivered, open not creditable (every city email, and anything sent before Oct 14) | City: "Delivered to both city inboxes Oct 9, 3:12 PM. We can't tell if they opened it." Before tracking: "Delivered Sep 22. Sent before we tracked opens, so we can't tell if it was opened." |
| **Delivered 1 of 2** (blue) | Some delivered, the others not answered yet | "Delivered to 1 of 2 city inboxes so far; waiting for the other." |
| **Sending** (grey) | No event yet, under 2 hours | "Handed to our email service at 3:10 PM; waiting for their email system to answer." |
| **No status received** (grey, with a warning icon) | No event after 2 hours, for a send after the webhook went live | "No delivery report came back. It is listed in the daily health email." |
| **No delivery record** (grey) | The 54 sends older than Resend's 30 days | "Sent Jul 9, before we kept delivery reports." (Fred confirms the wording at the mockup step) |

**Where the chips go:**

| App | Screen | Source |
|---|---|---|
| Admin Review | City email card, newest send line | `v_visit_city_email_sends` |
| Admin Review | City email dialog, "Show all N" | `v_visit_city_email_sends` |
| DERM Tracker | Visit page, City row and its "Show all" | `v_visit_city_email_sends` |
| DERM Tracker | Visit page, client line | `v_client_email_sends` |
| DERM Tracker | Manifests page, the client's city line | `v_visit_city_email_sends` |
| DERM Tracker | Manifests page, the "Emailed" chip | `v_client_email_sends` |

The send dialogs themselves show no chip, because the email does not exist yet. After a send, the history line shows
Sending, then the result.

### 5.6 The 4-week watch and the D5 gate
- **Store city open timing, never show it.** `opened_at` and the gap are kept on city sends in phase 1.
  - The archive mailbox `derm@ayache.com` is not opened in normal work, so these opens are mostly the city or its
    scanner. Mostly is not good enough to show, but it is good enough to measure.
- **Gate, read around 2026-11-18** (about 20 city sends):
  - **Fewer than 8 city sends with an open:** images are blocked. A city "Opened" would almost never appear, so D5
    is not worth it. Stop.
  - **Median gap under 60 seconds, or 90% or more of sends opened within 2 minutes:** a scanner. Keep city opens
    hidden for good. Consider E.
  - **Otherwise:** the opens look human. Build D5 (phase 2) and show city opens from its deploy, with no second watch.
- **Turn tracking off (E) at once, setting `email_open_tracking_until` in the same minute, on any of these:** a city
  bounce or delay, or a city telling us our email lands in junk or quarantine.

### 5.7 Daily health email (D4)
New kinds in `public.log_notification_health()`, which is already in both health views. Test clients and `is_test`
rows are excluded.
- `email_not_delivered`: a real send in the last 7 days with a bounce, failure, suppression or spam report on its To
  line. It names the property or client code, never an address.
- `email_status_missing`: a real send after the webhook went live, over 2 hours old, with no event at all. This means
  the webhook stopped.
- `email_delivery_incomplete`: a real send over 24 hours old where some To address still has no final event.

### 5.8 Phase 2 (D5), only if the gate passes and Fred says yes
- **One helper, `_shared/archive-copy.ts`.**
  - Same subject, html, text and attachments, with no second render.
  - A visible first line on the archive copy only: "Archive copy of the email sent to the city on <time ET>." Plus
    `X-Unclogme-Archive-Of` headers.
  - `Idempotency-Key: archive:<city resend id>`, a 30-second timeout, and one retry on 429 or 5xx. It never throws.
  - It builds the request body only after the city send's body is released, so two base64 PDFs are never held at once.
- **Senders:**
  - Remove the Bcc from the city payload (`send-derm-email:1126`, `send-visit-photos-email:983`).
  - Call the helper after the sent row is inserted, in its own try/catch.
  - Store `archive_resend_email_id` and `archive_error` on the SAME row. Never a second row, never `status='error'`.
  - Admin Review's `logSend` starts recording the real Bcc (fixes `:623`).
- **Migration first:** nullable `hidden_copies_separate`, `archive_resend_email_id` and `archive_error` on both logs;
  a city credit rule keyed on `hidden_copies_separate IS TRUE`; and a health kind `city_email_archive_missing`.

## 6. Build order (each step has its check)

1. **Fred's decisions (section 7); Diego writes to the 2 cities.**
   - Check: the answers are written into this file.
2. **Back end this week (no UI, so no mockups needed first):**
   - Migration (claimed in `WORKING-NOW.md`, `lock_timeout`, outside office hours), then `webhook-resend` deployed,
     then Fred adds the endpoint in Resend.
   - Check: forged signature gets 401 and 0 rows; stale timestamp gets 401; a replayed `svix-id` adds 0 rows; a
     non-unclogme `from` gets 200 and 0 rows; the deployed body is confirmed by `scripts/probes/edge_deployed_body.js`
     with a control needle.
3. **Smoke tests on 112-YA with @ayache.com addresses only.**
   - First add a `bcc` argument to `scripts/probes/derm_email_smoke.js`. Step 0 used a scratch copy.
   - City send with a Bcc. Check:
     - one `delivered` row per address, each with its own `data.to`;
     - after a Gmail open, `opened` rows, with the city status staying "open unknown";
     - a second open, to see whether a second event fires.
   - Client send. Check: it reads Opened, with the gap.
   - Bounce, spam, missing and incomplete cases: a rolled-back SQL fixture. Check: each health kind fires.
4. **Backfill by 2026-10-21.** Read one expired id first, then run it.
   - Check: the A La Carte Oct 9 send (`derm_email_sends` 190) reads Delivered, open unknown (summary); 21 summaries
     exist; the 54 read No delivery record.
5. **Mockups of the real screens** (every surface in 5.5, every chip state). Fred picks the D2 colour and the "No
   delivery record" wording.
6. **Apps, one Lovable project at a time, each claimed and published:** Admin Review first, then the DERM Tracker.
   - Check on the live site with real rows (A La Carte Oct 9).
   - Check the published bundle never renders an address.
   - The client line is checked against a 112-YA test send by reading the view, because no real client send has
     happened in 30 days.
7. **Docs, same cycle:**
   - `Supabase/CLAUDE.md` (city email section) and `docs/reference/city-and-client-email-logic.md`.
   - Admin Review `docs/11-city-email.md` (also fix lines 83-84, which say rows carry `derm@ayache.com`) and
     `08-changelog.md`.
   - DERM Tracker `CLAUDE.md` rule 13 (and the stale lines 642-646, 695-701), `06-features-and-routes.md` (lines 135
     and 165) and `08-changelog.md`.
8. **Watch until about 2026-11-18, then read the gate (5.6).** Write a dated note with the numbers here, and Fred
   decides phase 2.

## 7a. Fred's answers (2026-10-14)

1. **D5 later, behind the gate: yes.**
2. **Diego writes to the cities: no.** Fred: *"we checked on derm@ayache.com and the email was sent, but it might've
   arrived in the spam folder, that's why we did the uncheck the click on Sender"* (click tracking was left off for
   inbox placement). Step 1's "Diego writes to the 2 cities" is dropped.
3. **Open tracking stays on during the watch: yes.**
4. **Backfill: "Mark them all as Delivered".** All 77 past real sends read Delivered. For the 54 that Resend no
   longer holds, the row is written as `backfill_summary` with `detail.basis = 'assumed_before_reports'` (not a
   Resend answer), so the data stays honest. The chip is the D2 "Delivered, open unknown" look, and the tooltip says
   "Delivered Jul 9. Sent before we tracked opens, so we can't tell if it was opened." A send Resend reports as
   bounced or failed still reads Not delivered.
5. **Keeping data longer than Resend's 30 days:** `public.email_events` IS the long-term store. It is never purged,
   and from the day the webhook is live every event is ours forever, whatever Resend keeps. Longer retention at
   Resend itself is not a documented plan option; it can only be asked of Resend support.

## 7. Decisions for Fred

1. **D5 later, behind the 4-week gate?** Recommended: **yes, later.**
   - The earliest city "Opened" would be about the end of November, after phase 2 ships.
   - Saying yes now would change two regulator senders to show a signal that may be a scanner.
2. **Diego writes to Surfside and Hallandale Beach** (4 inboxes) with three questions. Recommended: **yes, this week.**
   - Are these the right addresses for our reports?
   - Can they add contact@unclogme.com to their safe senders?
   - Hallandale: who records our cleanings in FOG BMP, and does our email clear that reminder?
3. **Keep open tracking on during the watch,** knowing Resend suggests it for broadcasts only. Recommended: **yes.**
   - It is what makes the D5 gate measurable.
   - Client opens (D1) also need it, though no client email has been sent in 30 days.
   - The off switch (E) and its triggers are in 5.6.
4. **D3 as it can actually be done:** 21 sends get a one-line "delivered" summary and 54 read "No delivery record".
   OK? Recommended: **yes.** The 30-day limit is Resend's; nothing can recover the older ones.

Also found, no decision needed: 112-YA property 162 holds an internal address in `city_emails` (2.11). Every new view
excludes 112-YA through `v_non_customer_clients`.

## 8. Build status

- **2026-10-14, back end SHIPPED** (Fred: "yes, build the back end now"). Migration `2026-10-14_1505_email_delivery_events`
  (rollback beside it, rehearsed both ways), edge fn `webhook-resend`, fixtures `scripts/probes/email_delivery_fixtures.sql`
  (16 fixture emails, every state, health items, address masking: all pass), `scripts/checks/svix_verify_check.mjs`
  (8 of 8 against Svix's published vector).
- **Backfill done:** all 77 real sends read Delivered (22 confirmed by Resend, 55 assumed, Resend answered 404).
- **Webhook LIVE 2026-10-14 15:31 ET** (`2026-10-14_1531`): Fred added it in Resend (also ticked sent + clicked, which
  the function ignores) and the secret (first paste held the secret's name, caught by `secret_shape`). Smoke on
  112-YA: city test delivered for both addresses, a real open credited to both, status stays open unknown; forged,
  unsigned and stale calls get 401 and write nothing.
- **New finding for the mockups:** the client test read Opened 8 seconds after delivery while still UNREAD in Gmail
  (an automatic open). Proposal for Fred at the mockup step: an open within about a minute of delivery shows as
  "Delivered" with the tooltip "Opened seconds after it arrived, most likely automatically by their email app, so we
  can't tell if a person read it", in the D2 colour, instead of "Opened".
- **Not started:** mockups, then the chips in Admin Review and the DERM Tracker.

