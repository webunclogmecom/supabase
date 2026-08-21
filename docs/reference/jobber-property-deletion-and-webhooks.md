# Deleting a Jobber property, and the webhook gap behind it

*Researched 2026-08-20 after Fred asked "we need to be able to delete (maybe soft delete) those
properties". Every claim here has a named source; where sources disagree that is called out.*

---

## 1. Can a property be deleted?

**Three independent sources agree.**

| Source | Finding |
|---|---|
| **Schema introspection** (authoritative) | Only `propertyCreate(clientId, input)` and `propertyEdit(propertyId, input)` exist. **No delete, no archive.** |
| **Jobber UI** (observed) | A red **Delete** button exists on Edit property. Used it: 112-YA went 5 properties → 4, confirmed via `clientProperties`. |
| **Jobber AI** (asked directly) | *"the schema I checked exposes propertyEdit only… property deletion appears to be a web UI action, not an exposed GraphQL operation"* and *"Deleting a property in Jobber is not reversible… the property cannot be recovered."* |

✅ **POSITIVE CONTROL for the API claim:** the API has **18** delete/archive mutations for other
objects (`clientArchive`, `expenseDelete`, `requestArchive`, `assessmentDelete`…). So the absence for
properties is a deliberate gap, not a missing feature or a bad query.

🛑 **DELETING A PROPERTY CASCADE-DELETES ITS JOBS.** Jobber's own confirmation dialog: *"Deleting this
property also deletes related quotes and jobs, including associated estimates and prices. This data
also won't be included in your reports."*

⇒ **This is the route around "there is no `jobDelete`".** That constraint has been treated as absolute
all through the SC-job work, and it is true of the API — but a permanent job CAN be removed by
deleting its property in the UI. Irreversibly, and taking the quotes with it.

⚠ **Jobber AI's advice to "archive the property instead" is wrong on the specifics** — there is no
property archive, in the API or the UI. Its general point (prefer editing to deleting) still stands.
⚠ It could not confirm whether invoices are deleted too, and said so rather than guessing. Treat
invoices as unverified.

---

## 2. 🛑 The real gap: we are not subscribed to any DESTROY webhook

`webhook-jobber` already contains `handlePropertyDestroy` (hard-deletes the row on `PROPERTY_DESTROY`).
**It has never fired.**

```
PROPERTY_DESTROY received, ever :  0
PROPERTY_CREATE received, ever  : 15   <- POSITIVE CONTROL: property webhooks DO reach us
```

`WebHookTopicEnum` exposes **46 topics**, including **12 DESTROY topics**
(`PROPERTY_DESTROY`, `JOB_DESTROY`, `CLIENT_DESTROY`, `VISIT_DESTROY`, `INVOICE_DESTROY`, …).
We receive **7**: `CLIENT_UPDATE`, `INVOICE_UPDATE`, `JOB_UPDATE`, `PROPERTY_CREATE`,
`PROPERTY_UPDATE`, `QUOTE_UPDATE`, `VISIT_UPDATE`. **Zero DESTROY topics.**

**Consequence, observed today:** deleting property 1092 in the Jobber UI left our row behind. Its
stored GID now resolves to `null` in Jobber. **Deleting in Jobber silently orphans our row**, and
nothing anywhere reports it.

⚠ **The orphan check is `data.property === null`, NOT an `errors` array.** A deleted GID returns
`{"data":{"property":null}}` with no error. A checker that tests for `errors` reports "it still
exists" — I made exactly that mistake before catching it.

### How subscribing works (from the docs, quoted)

> *"Webhooks are managed from the app settings page in the Developer Center. Each webhook requires a
> topic and a URL… To receive webhook data for a given topic, your app must have the appropriate read
> scope for that object."*

⇒ It is a **Developer Center UI change, not code and not a GraphQL call.** We already receive
`PROPERTY_CREATE`/`PROPERTY_UPDATE`, so we already hold the property read scope: **adding
`PROPERTY_DESTROY` needs no new scope and no re-authorization.**

---

## 3. 🛑 URGENT AND UNRELATED: we are breaching Jobber's 1-second webhook limit

> *"Webhook requests must be responded to within 1 second of receipt… If response times consistently
> exceed the 1-second limit… **Jobber may disable the app's webhooks** to protect other apps and
> systems."*

Measured over the last 7 days (`webhook_events_log.processing_ms`):

| topic | n | avg ms | max ms | over 1s | % |
|---|---|---|---|---|---|
| VISIT_UPDATE | 16,782 | 551 | **33,735** | 614 | 3.7% |
| CLIENT_UPDATE | 578 | 854 | **32,001** | 66 | 11.4% |
| PROPERTY_CREATE | 7 | **1,048** | 1,967 | 3 | **42.9%** |
| INVOICE_UPDATE | 77 | 666 | 3,349 | 5 | 6.5% |
| PROPERTY_UPDATE | 495 | 366 | 2,258 | 8 | 1.6% |
| **TOTAL** | **17,984** | | | **696** | **3.9%** |

**PROPERTY_CREATE's mean is already over the limit.** Max times of 32-33 seconds are 33x the budget.

The docs also warn: *"The Developer Center does not currently send automated notifications for
unexpected webhook responses"* — so if Jobber disables our webhooks, **we find out by noticing data
stopped arriving.** There is no alert.

🛑 **This matters MORE than the property question, and it makes the property fix riskier:** adding
`PROPERTY_DESTROY` adds load to an endpoint already breaching its SLA, and its nearest sibling
(`PROPERTY_CREATE`) is the worst offender by rate.

**The documented fix is architectural:** *"process webhook payloads asynchronously. Your app should
acknowledge receipt immediately and handle the event in a background job or queue."* Our handler does
the Jobber GraphQL round-trip and the DB write inline, before responding. That is the cause.

---

## 4. Other facts worth keeping

- **At-least-once delivery.** *"the same webhook may be delivered more than once… Apps should detect
  duplicate deliveries… and handle them idempotently."*
- **One action can fire the same topic several times** — adding a payment fires `INVOICE_UPDATE`
  twice. Observed here: three `PROPERTY_UPDATE` events one second apart. **Not** retries or bugs.
- **Real payload shape** is `{ data: { webHookEvent: { topic, appId, accountId, itemId, occurredAt } } }`.
  ⚠ Our synthetic replay in `save-client-property` / `create-client` sends
  `{ topic, webHookEvent: { itemId, occurredAt } }` — a **different shape**, no `data` wrapper, topic
  at the top level. It works because our own handler accepts it, but do not use it as a reference for
  what Jobber actually sends.
- **Timestamp spelling trap:** apps created before 2023-12-08 receive `occuredAt` (missing an r).
  Check which our app is before parsing that field.
- **HMAC:** base64 `X-Jobber-Hmac-SHA256`, HMAC-SHA256 of the raw body with the OAuth client secret,
  compared in constant time. That is what our replay already does.

---

## 4b. ⚠ Subscribing needs FRED — the Developer Center is a SEPARATE login

Attempted 2026-08-20 and stopped deliberately. `developer.getjobber.com` is **not** the same session as
`secure.getjobber.com`: the work Chrome is signed into the Jobber app but NOT the Developer Center,
and its login is a plain **email + password form** with no SSO and no "continue as the signed-in
user". Typing credentials is out of bounds, so this step cannot be automated.

**What Fred needs to do (about 30 seconds):**
1. Log in at `developer.getjobber.com`, open the UnclogMe app, go to its webhooks.
2. Add a webhook: topic **`PROPERTY_DESTROY`**, URL
   `https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/webhook-jobber`
3. Optionally add `JOB_DESTROY`, `CLIENT_DESTROY`, `VISIT_DESTROY` at the same time — all are equally
   blind today, and the handler dispatch already ignores unknown topics safely.

**No new scope and no re-authorization**: the docs require only the matching read scope, and we
already receive `PROPERTY_CREATE`/`PROPERTY_UPDATE`, so the property scope is already granted.

**How to prove it worked afterwards** (do not trust the settings screen):
delete a spare 112-YA property in the Jobber UI, then check that our row disappears and that a
`PROPERTY_DESTROY` row appears in `webhook_events_log`. Orphan 1092 is still sitting in
`public.properties` as a ready-made before/after case.

---

## 5. Recommended plan, in order

1. **Fix the 1-second breach first.** Acknowledge immediately, do the work in the background. Nothing
   else should be added to that endpoint until this is done — the penalty is Jobber disabling our
   webhooks with no notification.
2. **Subscribe `PROPERTY_DESTROY`** in the Developer Center. No code, no scope change, no
   re-auth — `handlePropertyDestroy` already exists and starts working the moment it is subscribed.
   Consider `JOB_DESTROY`, `CLIENT_DESTROY`, `VISIT_DESTROY` at the same time; all are equally blind today.
3. **Change `handlePropertyDestroy` to SOFT-delete.** It currently does
   `.from('properties').delete()`, a hard delete, against the standing never-hard-delete rule.
   ⚠ `public.properties` has **no** `deleted_at`/`status`/`archived_at` column today (4 other tables
   do), and **30 views read it** — so this is a real migration with a real blast radius, not a column add.
4. **Add an orphan reconciler** for what webhooks miss: properties whose Jobber GID resolves to
   `null`. Keyed on the null payload, not on an errors array.

**Do NOT** build a delete button in our apps that only writes our DB. A property deleted only here
still exists in Jobber, the poll re-imports it, and the two systems diverge silently. Deletion has to
start in Jobber.
