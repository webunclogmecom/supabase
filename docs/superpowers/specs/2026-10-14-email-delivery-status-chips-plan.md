# Show "Delivered" / "Opened" on every email the apps send (plan)

*2026-10-14 · after Diego's A La Carte report ("they never received it")*

## The ask

Fred, 2026-10-14: *"design a plan about how to use that information + our db, about how to display that in the
Admin Review App and DERM App, where they can send the email to attach a chip like `open` or `delivered` (when is
not opened)"*.

## What is true today (measured 2026-10-14)

- **Resend knows, we don't.** Resend records Sent, Delivered, Bounced and, since today, Opened for every email
  (tracking subdomain `links.unclogme.com`, open tracking on, click tracking off). Our logs stop at "Resend accepted
  it": `status = 'sent'` plus `resend_email_id`.
- **Proven today:** the A La Carte city email of Oct 9 reads Delivered for both city inboxes and the archive BCC. A
  112-YA test email read Sent, Delivered, then Opened 2 minutes after Gmail showed it, and it carried the open pixel
  with its links untouched.
- **Both send logs already keep Resend's id, on every real row:**

  | log | written by | real sends | with a Resend id |
  |---|---|---|---|
  | `public.derm_email_sends`, `recipient_type = 'city'` | DERM Tracker "Send to city", the automatic sweep | 29 (12 since go-live) | 29 |
  | `public.derm_email_sends`, `recipient_type = 'client'` | DERM Tracker "Send to client" | 37 (last 2026-08-19) | 37 |
  | `public.visit_photo_email_sends` | Admin Review "Send email to City" | 11 | 11 |

  So nothing in the senders has to change.
- **Both apps already read ONE history view for city emails:** `public.v_visit_city_email_sends` (one row per real
  city send per visit, `source_table` + `send_id` point back to the log row). Admin Review's card and dialog
  (`CityEmailHistory.tsx`), the DERM Tracker visit page City row and the Manifests client line render it: the newest
  send as one line, then "Show all N city emails". A column appended to that view reaches both apps through the
  queries they already run.
- DERM Tracker rule 13: never select or show the view's `recipients`. A chip must say "2 of 2 inboxes", never
  the addresses.
- Client sends are shown differently: the DERM Tracker visit page reads `derm.visits.client_last_*`, and the
  Manifests page has the "Emailed / Not emailed" chip.

## Design

```
Resend ──webhook──> edge fn webhook-resend ──> public.email_events (one row per event per recipient)
                                                      │
                          public.v_email_delivery  <──┘  (one row per resend_email_id: status + times)
                                   │
        v_visit_city_email_sends + 3 appended columns ──> Admin Review card/dialog, DERM Tracker City row
        (client send line, if D1 = yes)               ──> DERM Tracker client line
```

### 1. Store the events: `public.email_events`

- Columns: `id`, `svix_id` (UNIQUE, so a retried webhook is stored once), `resend_email_id`, `event_type`
  (`delivered`, `opened`, `bounced`, `delivery_delayed`, `complained`, `failed`, `suppressed`), `recipient`
  (one row per address in the event's `to`), `occurred_at` (the event's `created_at`), `received_at`, `detail`
  (jsonb: only the bounce or failure reason, never the body).
- Service_role only (revoke from `public`, `anon` and `authenticated` by name, and assert it). No audit trigger:
  it is an append-only log.
- **Only our own emails are kept:** an event whose `from` is not `@unclogme.com` is answered 200 and dropped. The
  Resend account ("ayache") may send for other businesses, and their recipients do not belong in this DB.

### 2. Receive them: edge fn `webhook-resend`

- `verify_jwt = false` in `config.toml` (Resend cannot send a Supabase token), like `webhook-jobber`. The real
  gate is the **Svix signature**: HMAC-SHA256 over `svix-id.svix-timestamp.raw body` with the endpoint secret
  (edge secret `RESEND_WEBHOOK_SECRET`), any `v1,` signature must match, and a timestamp more than 5 minutes off
  is refused. Web Crypto only, no new dependency. Anything unsigned gets a 401 and writes nothing.
- Insert with `ON CONFLICT (svix_id) DO NOTHING`, answer 200. Retries and out-of-order arrival are harmless
  because nothing is overwritten: the status is computed from all events (next step), never from "the last one".
- Fred creates the webhook in the Resend dashboard (Webhooks, Add endpoint,
  `https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/webhook-resend`, the 7 event types above; not `sent`, not
  `clicked`) and pastes the signing secret, which I set as the edge secret without printing it.

### 3. One status per email: `public.v_email_delivery`

One row per `resend_email_id`, counting **only the To line** (the addresses in the send log's `recipient_email`),
so the archive BCC `derm@ayache.com` and internal Cc copies never make an email look delivered or opened:

| `delivery_status` | when | chip |
|---|---|---|
| `bounced` | any To address bounced, failed or was suppressed | red **Bounced** ("1 of 2 inboxes bounced", reason in the tooltip) |
| `opened` | an open event exists | green **Opened** + first open time |
| `delivered` | every To address delivered, no open | blue **Delivered** ("not opened yet" only when sent after tracking started) |
| `partial` | some To addresses delivered, none bounced yet | blue **Delivered 1 of 2** |
| `delayed` | a `delivery_delayed`, nothing final yet | amber **Delayed** |
| `sent` | no event yet (normal for the first seconds) | grey **Sent** |

Plus `delivered_at`, `opened_at` (first), `to_count`, `delivered_count`, `bounce_reason`, and
`open_tracked` = sent on or after `app_config.email_open_tracking_since` (`2026-10-14 17:54 UTC`, the first
tracked send). **An email sent before that can never read "not opened"**; its chip says Delivered, full stop.

Bounced outranks Opened on purpose: a bounce means a wrong city address on the property, which is the one thing
someone must act on.

### 4. Show it: append to the view both apps already read

`v_visit_city_email_sends` gets three appended columns (`delivery_status`, `delivery_at`, `delivery_detail`),
joined from `v_email_delivery` through `source_table` + `send_id`. Appending keeps the grants
(`CREATE OR REPLACE`, asserted), so both apps can read it right away. Each app then adds one small chip next to the
existing "who sent it / which app" chips, on the newest-send line and in "Show all N".

### 5. Fill in the past: one backfill run

77 real sends have a Resend id. A one-off run of the same edge fn (service_role, `{backfill: true}`) calls Resend's
"retrieve email" for each one (`last_event`) and stores it as one event with `svix_id = 'backfill:<id>'`. So the
Oct 9 A La Carte email shows **Delivered** on day one. Opens cannot be backfilled (none were tracked).

### 6. Know when it breaks

`public.log_notification_health()` (the daily health email) gets one new item, `email_status_missing`: a real
send more than 2 hours old with no event at all, which means the webhook stopped arriving. Also
`city_email_bounced`: a city send in the last 7 days whose status is `bounced`, with the property, so the wrong
address gets fixed. No new Slack post.

## Steps

0. **Measure before building (no Prod change):** one test send with two To addresses (`fred@ayache.com` plus an
   internal `test_cc`), open only one of them, and read the per-recipient rows in Resend. This answers the one
   unknown that changes the design: **does Resend tell WHICH recipient opened?** If yes, the view counts opens per
   To address and ignores the archive. If no (one pixel per email), then an open by `derm@ayache.com` would show
   as "Opened" on a city email, and the fix is to stop the archive copy being opened from the inbox (or to drop
   the BCC in favour of the log). Decision D2.
1. **Mockups of the real screens first** (Fred's rule): the Admin Review card and dialog, the DERM Tracker visit
   City row, the Manifests client line, each with Opened / Delivered / Bounced / Sent. Fred picks.
2. **Migration** (`YYYY-MM-DD_HHMM_email_delivery_events`, rehearsed, VERIFY inside, rollback beside it): table,
   grants, `app_config` key, `v_email_delivery`, the three appended columns, the two health items, `NOTIFY`.
3. **Edge fn `webhook-resend`** + `config.toml`, deployed. Fred adds the webhook in Resend and gives me the secret.
4. **Smoke test on 112-YA** (`scripts/probes/derm_email_smoke.js 2017 381 city nophotos`, test address only):
   rows land for delivered, then opened after Gmail shows it. A forged request (bad signature) gets 401 and writes
   nothing. A replayed `svix-id` writes nothing.
5. **Backfill** the 77 sends; check A La Carte's Oct 9 row reads `delivered` with 2 of 2.
6. **Apps (Lovable, one project at a time, claimed in `WORKING-NOW.md`, published):** Admin Review chip, then
   DERM Tracker chip, each verified on the live site with a real row, not a mock.
7. **Docs, same cycle:** `Supabase/CLAUDE.md` city email section, `Supabase/docs/reference/city-and-client-email-logic.md`,
   Admin Review `docs/11-city-email.md` + `08-changelog.md`, DERM Tracker `CLAUDE.md` rule 13 +
   `06-features-and-routes.md` + `08-changelog.md`.

Size: one migration, one ~150 line edge fn, one backfill run, two small app changes.

## Rules that must not regress

- "Opened" is a hint, never proof. City mail systems (often Microsoft 365) can open the pixel when scanning, and
  some readers block images. The tooltip says so; nobody should treat "not opened" as "not received". Delivered is
  the proof.
- Only To-line addresses count. The archive BCC and internal Cc copies never change a city email's status.
- Never show addresses in the DERM Tracker (rule 13). Counts only.
- Status is computed from all events, never from the newest one (webhooks retry and arrive out of order).
- An unsigned or badly signed request writes nothing.
- No change to the senders, the sweep, or when emails go out.

## Decisions for Fred

- **D1. Client emails too?** The DERM Tracker "Send to client" emails (37, the restaurant) can get the same chip
  on the visit page client line and the Manifests "Emailed" chip. Recommended: **yes, in the same build**; the
  events table already has them, it is one more join. Or city only for now.
- **D2. If step 0 shows Resend cannot tell which recipient opened:** keep the archive BCC and accept that an open
  of the archive copy reads as "Opened"? Recommended: **keep the BCC and set a Gmail filter on derm@ayache.com
  that archives these unread**, so nobody opens them by accident. Decide only if step 0 says it matters.
- **D3. Backfill the 77 past sends from Resend?** Recommended: **yes**; it is what makes the Oct 9 A La Carte email
  show Delivered.
- **D4. Bounce alerts:** daily health email only (recommended), or also a Slack post to the office when a city
  email bounces?
