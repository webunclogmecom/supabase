# City and client email logic

*Written 2026-09-03. Covers every path that mails a municipality or a customer about a visit.*

Read this before changing anything that sends mail. Two apps send to the city, one cron sends to the
city unattended, and one path sends to the customer. They share one letter template and nothing else.

---

## The four senders

| # | Trigger | Edge function | Goes to | Attachment |
|---|---|---|---|---|
| 1 | **Admin Review**, "send to city" on a reviewed visit | `send-visit-photos-email` | municipality | Job Completion Report (FP Service Report), photos optional |
| 2 | **DERM Tracker**, "Send to City" on a manifest | `send-derm-email` (`target: 'city'`) | municipality | FP Service Report, which EMBEDS the FOG eManifest and the WWTP receipt |
| 3 | **cron `city-email-sweep`**, `7 * * * *` | `send-derm-email` (`target: 'city'`) | municipality | same as 2 |
| 4 | **DERM Tracker**, "Send to client" | `send-derm-email` (`target: 'client'`) | the customer | same report |

🛑 **1 and 2 are DIFFERENT EMAILS ABOUT DIFFERENT MOMENTS, and that is correct.** #1 goes out when
the service is completed, before the waste has been offloaded, so its letter carries a blue note
saying the manifests will follow. #2 goes out after the manifest is filed and blacked out, and IS
that follow-up. Fred, 2026-09-02: *"when we send an Email for the city at the Admin Review App is
different than when we try to send it at the DERM App, which is not of a problem."*

---

## One letter, one file

Both city senders render `supabase/functions/_shared/city-letter.ts`. Before 2026-09-02 they each
built their own, and a municipality received two visibly different letters from the same company for
the same job: the DERM one was plain prose with no service-details panel, no attachment card, no
phone number and no licensed-hauler footer, and it signed off *"Thanks again for your hard work, and
feel free to recommend us to the restaurants in your city ;-)"*.

**Only five things are parameterised. Everything else is fixed copy to a regulator.**

| parameter | what it does |
|---|---|
| `clientName` / `address` / `visitDate` | the SERVICE DETAILS panel |
| `serviceType` | defaults to the fixed `Grease Trap Cleaning` label |
| `card` | the attachment card, or `null` for no card at all |
| `manifestsToFollow` | the blue "a second email is coming" note |
| `isTest` | the internal test strip above the letter |

🛑 **THE BODY IS NOT A REQUEST PARAMETER, ON PURPOSE.** If the caller could pass body text, the
caller would choose what a regulator reads. To change the wording you edit that file and redeploy.

🛑 **DO NOT REINTRODUCE A LOCAL BUILDER.** Two copies of a regulator-facing letter is the trap this
repo already paid for with the base64 encoder (see the OOM section in `CLAUDE.md`): the second copy
is the one nobody re-tests. The markup was extracted mechanically by
`scripts/probes/email/build_city_letter.py`, which asserts every substitution; re-run it rather than
hand-editing if the source template moves.

⚠ **The subjects still differ** and were deliberately not unified: `Grease Trap Service Completed`
for the completion notice, `DERM Manifest for <client>` for the manifest submission. They describe
genuinely different emails. Fred asked for how it LOOKS, and the body is what he was shown.

### Card copy by sender

| sender | card title | card subtitle |
|---|---|---|
| Admin Review | `Job Completion Report` | `Service details only` |
| DERM, report attached | `Service Report` | `Manifest Form & Transporter Manifest` |
| DERM, nothing attached | **no card at all** | |

That last row matters: a letter with no attachment is a real branch (Fred, 2026-08-26, the letter
still goes out) and it must not show a card promising a document that does not exist.

---

## `include_photos`

Added 2026-09-03 because `send-derm-email` called the renderer with `include_photos: true`
**hardcoded**, so every report a municipality has ever received from that path carried the photos.

- Request field on `send-derm-email`. **Absent means true**, so every existing caller is unchanged.
  Only an explicit `false` turns photos off.
- Threaded through `renderVisitReport` and `buildReportAttachment` to both the city and client loops.
- Recorded in `public.derm_email_sends.include_photos`. The rendered PDF is not stored anywhere, so
  without that column there is no way to tell later whether a regulator submission carried the
  photographs. NULL on the 110 rows that predate the flag, deliberately not backfilled.
- The Admin Review side already had this as `visit_photo_email_sends.include_photos`.

⚠ **A visit whose photos are all unclassified renders the SAME pdf either way.** Photo roles in
`public.photo_links` are only `other` and `attachment`; the before/after split lives in
`public.photo_classifications.service_phase`. Visit 6347 has 42 photos and zero classified, so both
renders came back byte-identical at 271 KB. **That is a test that cannot discriminate, not a passing
test** - pick a visit with classified photos (6568 has 39, 6617 has 18) when verifying this flag.

---

## The gates, and what "test mode" means

Everything lives in `public.app_config`, which is audited.

| key | today | effect |
|---|---|---|
| `city_email_live_sends` | **`false`** | every city send is forced to the test recipient and logged `is_test=true` |
| `city_email_test_recipient` | `fred@ayache.com` | where gated sends land |
| `client_email_live_sends` | **`true`** | the CUSTOMER-facing send is LIVE and reaching real addresses |
| `city_email_start_from` | **`infinity`** | the automatic sweep's on/off switch AND backlog cutoff in one value |
| `city_email_delay` | `24 hours` | how long after the blackout the automatic email goes |
| `city_email_retry_after` | `20 hours` | stops a re-send loop |
| `city_email_batch_limit` | `5` | per sweep run |

**What is test-mode scaffolding, and must go at cutover:**

1. The **INTERNAL TEST strip** above the letter. It is keyed on `isTest`, which is keyed on
   `test_recipient`, so it disappears by itself the moment the gate opens. Nothing to remove.
2. **`city_email_test_recipient`** must be cleared, or every automatic email keeps going to Fred and
   is logged `is_test=true`, which also means the `already_sent` guard never matches and the sweep
   retries the same manifests forever.
3. The DERM Tracker's **test-recipient modal**, which is test scaffolding
   (`project_city_email_test_modal_must_be_removed_at_prod` in memory).

### 🛑 Cutover order, and it is not one statement

```sql
-- 0. FIRST: no test address may be sitting in properties.city_emails, or the sweep mails it as a
--    real municipality. Known: 009-CN property 42 has held fred@ayache.com.
select c.client_code, p.id, p.city_emails
  from public.properties p join public.clients c on c.id = p.client_id
 where p.deleted_at is null and p.city_emails && array['fred@ayache.com','test@example.com'];

-- 1. open the gate BEFORE clearing the recipient
update public.app_config set value = 'true' where key = 'city_email_live_sends';

-- 2. now clear it. Doing this FIRST returns 503 city_gate_misconfigured on every DERM email,
--    city and client, because the recipient regex rejects an empty string while the gate is shut.
update public.app_config set value = ''     where key = 'city_email_test_recipient';

-- 3. LAST. This is the switch that admits manifests, so nothing moves until it lands, and it also
--    sets the backlog cutoff: anything blacked out before this instant is never swept.
update public.app_config set value = now()::text where key = 'city_email_start_from';
```

Verify on the first sweep, which runs at `:07`. A real send writes `is_test = false` with a
municipal address:

```sql
select recipient_type, is_test, recipient_email, include_photos,
       sent_at at time zone 'America/New_York'
  from public.derm_email_sends where sent_at > now() - interval '2 hours' order by id desc;
```

⚠ **`city-email-sweep` is already running hourly and sending nothing.** That is the intended state,
not a broken job: `city_email_start_from = infinity` admits nothing. A cron that has been running
harmlessly for days is a far better thing to switch on than one whose first execution is also its
first real send.

⚠ Read `derm.v_city_email_candidates.status`, never the queue view, to see why a manifest is not
going out. `no_city_email` dominating is the normal shape of this system, not a gap.

---

## Safety properties worth not breaking

- **`test_recipient` is what makes a smoke test safe**, decisively: `toList = testRecipient ? [testRecipient] : cityEmails`,
  and `CITY_BCC` is dropped when it is set. `scripts/probes/derm_email_smoke.js` always sends it.
- It must run **server-side**: `send-derm-email` is origin-restricted to `derm.unclogme.app`, so a
  browser call from anywhere else dies at the preflight with a bare `TypeError: Failed to fetch`,
  which looks like a broken function and is not one.
- **An unrecognised `test_recipient` is REFUSED (400), never ignored** - ignoring it would fall
  through to the real municipal recipients.
- The **base64 encoder is duplicated** in `send-derm-email` and `send-visit-photos-email` and must
  stay byte-identical; `scripts/probes/b64_chunked_test.js` reads both and fails on drift.
- `MAX_REPORT_BYTES` is **8 MiB** here, deliberately not the sibling's 25 MiB: this function loops
  over recipients in one invocation and the sibling sends one email per invocation.
