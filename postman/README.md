# GDO Online Reporting API

**Audience:** the integrator of the GDO Online Reporting RPA bot (Jonathan / "John").
**Status:** live on Prod, tested end-to-end. Waiting on the bot's `/run` URL + the rollout gates.
**Last updated:** 2026-07-21.

> This is both the **API reference** and the doc for the Postman collection in this folder. It
> documents the **current** contract of the two endpoints your bot talks to, plus the surrounding
> pieces (event push, status surfaces, evidence storage, error codes). Nothing here is a secret: key
> **values** are sent to you privately, never committed. This repo is public.

---

## 1. What this is

The bot files **GDO Online Reporting** on the Miami-Dade DERM portal. For us that is **Line Item 27**
on a client's job, so the **unit of work is a serviced VISIT** for one of the clients that carry that
add-on, not a manifest. When we service such a client and their DERM manifest is filed + linked to the
visit, that visit becomes a "please file the online report" job for the bot.

It is a **small, targeted feed** (only a few clients carry Line Item 27), **server-to-server**, and
**compliance-critical**: the design's first job is to *never double-file a report to the county*. All
the lifecycle rules below exist to guarantee that.

Two endpoints, both live:

| Direction | Method | Endpoint | Purpose |
|---|---|---|---|
| bot → us | `GET`  | `/functions/v1/rpa-derm-queue`  | "What should I report?" |
| bot → us | `POST` | `/functions/v1/rpa-derm-result` | "Here is what happened." |

Base URL: `https://wbasvhvvismukaqdnouk.supabase.co`

---

## 2. Authentication

Every call carries the header **`x-rpa-key`** (value sent to you privately). There is **no Supabase
JWT** and no database connection: the key is the auth, checked inside each function.

- **You get your OWN key.** Every integrator holds a separate key (ours is a comma-separated list of
  labelled entries on our side), so a key can be revoked or rotated on its own without disturbing
  anyone else. You never see the list. Rotation is add-new, you switch, we remove old — zero downtime.
- Every result you POST is recorded against the key that sent it, so the submission log shows which
  consumer filed each report. Nothing is taken from the request body for this — it comes from the
  credential itself, so it cannot be spoofed.
- **Two different keys, never interchange them:**
  - `x-rpa-key` — the key **you send us** on every `GET`/`POST` above.
  - the **run key** — a *different* key **we send you**, used only when our database calls your
    `/run` endpoint (section 5). One is inbound, one is outbound; keep them separate.
- Keys live only in your Railway environment variables, never in code or logs.

Missing/invalid key → `401 {"error":"unauthorized"}`. Key not configured on our side →
`503 {"error":"service_not_configured"}`.

---

## 3. `GET /functions/v1/rpa-derm-queue` — the work queue

Returns up to **25** reports to file, **oldest first**.

**Query params**

| Param | Values | Meaning |
|---|---|---|
| `mode` | `dryrun` | Serve a fixed set of **historical** visits for testing. Omit for the live queue. |

**Response `200`**

```jsonc
{
  "generated_at": "2026-07-21T15:00:00.000Z",
  "mode": "live",              // or "dryrun"
  "count": 3,
  "reports": [ { /* report object, see below */ } ]
}
```

**Report object** — every field the bot needs to file one report:

| Field | Type | Notes |
|---|---|---|
| `visit_id` | integer | **The work key.** Echo it back on your result POST. |
| `manifest_id` | integer | The linked DERM manifest (context; optional to echo). |
| `dry_run` | boolean | `true` when this came from `?mode=dryrun`. |
| `client_code` | string | e.g. `041-MB`. |
| `client_name` | string | |
| `client_email` | string \| null | |
| `address`, `city`, `zip`, `county` | string | Service location. |
| `gdo_number` | string \| null | The GDO permit number. |
| `service_date` | date | When the visit was serviced. |
| `dump_ticket_date` | date | Date on the disposal receipt. |
| `white_manifest_number` | string \| null | Miami-Dade WWTP/dump receipt number. |
| `disposal_facility` | string \| null | |
| `documents.address` | string[] | **Signed URLs** to the DERM Address / Manifest Form sheet(s). |
| `documents.receipt` | string[] | **Signed URLs** to the Transporter Manifest / WWTP receipt(s). |

**Signed URLs are valid ~4 hours** and are minted fresh on every fetch. Download everything at the
start of a run; **never log or persist the URLs**.

### Queue lifecycle (why a visit does or does not appear)

- A visit stays in the live queue **until it is successfully reported** — so nothing is dropped if the
  bot is down for a while.
- It leaves the queue **permanently** once the county confirms it (a `SUCCESS` result with a
  `portal_confirmation`, section 4).
- After any attempt — or the moment we hand it to you — the visit is **held for 20 hours** (a dispense
  *lease*) so a crash between filing and the result POST can never cause a re-dispense and a double-file.
- The live queue only contains visits with a `dump_ticket_date` on/after a **launch cutoff** (currently
  `2026-07-21`). This exists so the bot's first live run cannot re-submit the entire historical backlog
  to the county. We widen the cutoff deliberately if a backfill is ever wanted.
- `?mode=dryrun` serves already-serviced **historical** visits and does **not** place a lease; use it
  freely for testing.

---

## 4. `POST /functions/v1/rpa-derm-result` — record an outcome

Same `x-rpa-key`. **Idempotent on `(visit_id, run_id)`**: a retried POST returns `200 {deduped:true}`
and changes nothing (first write wins).

**Request body**

| Field | Type | Req | Notes |
|---|---|---|---|
| `visit_id` | integer | ✅ | From the queue. |
| `manifest_id` | integer | | Optional; echo it back if you have it. |
| `run_id` | string | ✅ | Charset `[A-Za-z0-9_.-]`, ≤100 chars. **Generate ONCE per report attempt, before you hit the portal, and reuse it verbatim on every retry.** It becomes part of the screenshot storage key. |
| `status` | string | ✅ | Short uppercase code, `^[A-Z0-9_]{1,64}$`. Use the literal **`SUCCESS`** for a confirmed report (see below). |
| `retryable` | boolean | ✅ | `true` for transient problems (portal timeout); `false` for data problems (missing field). |
| `failure_reason` | string | | ≤1000 chars. |
| `attempted_at` | string | ✅ | ISO 8601 UTC. **Log/audit only** — our queue timing uses our own server clock, so a skewed bot clock can never cause a double-file. |
| `portal_confirmation` | string | | ≤200 chars. Whatever number/text the portal returns. **Required for a real `SUCCESS`.** |
| `screenshot` | string | | base64 JPEG, ≤5 MB decoded. |
| `screenshot_missing_reason` | string | | ≤300 chars. **Provide this OR `screenshot`** — every result needs one. |
| `dry_run` | boolean | | Ignored / derived server-side; harmless to send. |

Unknown fields → `400 {"error":"unknown_field_<name>"}`.

**Two hard rules enforced on our side:**

1. **No optimistic success.** A visit only counts as reported (permanent queue exit) when
   `status = 'SUCCESS'` **and** a `portal_confirmation` is present. Any other confirmed status is fine
   too as long as you send `portal_confirmation`, but `SUCCESS` is the clean permanent-done signal.
2. **Evidence or a reason.** Every result carries a `screenshot` **or** an explicit
   `screenshot_missing_reason`. If a screenshot is oversized/undecodable we still **record the result**
   and just flag the missing evidence — we never drop a genuine attempt over a screenshot problem.

**Responses**

| Code | Body | Meaning |
|---|---|---|
| `201` | `{"recorded":true,"deduped":false,"id":<n>}` | New result stored. |
| `200` | `{"recorded":true,"deduped":true,"id":<n>}` | Duplicate `(visit_id, run_id)`; no-op ack. |

**If you do not get a 2xx, keep the result locally and retry the same POST** (same `run_id`) until you
do. Never treat a report as done before we acknowledge it.

**Screenshots:** send the bytes in the POST; we store them in a **private** bucket (`rpa-evidence`,
client data) and record only the path. You never need storage credentials. If images ever exceed the
5 MB cap routinely we will switch you to a signed upload URL.

---

## 5. Triggers — event push + poll backup

**Event push (primary).** The moment we link a serviced Line-Item-27 visit to its DERM manifest, our
database calls **your** service to run it. Expose:

```
POST /run        (on your service, gated by the RUN key we send you)
```

- Returns **`202` immediately** and does the work in the background.
- Returns **`409`** if a run is already in progress (single-flight).
- We call it with a small body naming the visit.

Send us your `/run` URL and we flip the push on. Until then the push is dormant and the poll backup
alone already works.

**Poll backup (safety net).** Independently, poll `GET /rpa-derm-queue` on a **slow schedule**
(every 15–30 min) and file anything sitting there. A missed push is then never a missed report.

---

## 6. What the result feeds (status surfaces)

Your `POST` results drive per-visit "GDO report filed / pending / failed" chips in our apps:

- `derm.gdo_report_status` — per visit, shown in the internal DERM Tracker.
- `customer.gdo_reports` — per visit, shown on the customer's Field Portal.

Every write from the bot is attributed in our audit trail as `app_source = 'gdo-report-bot'`, and every
result is logged in `public.derm_portal_submissions` (visit_id / run_id / status / confirmation /
screenshot path / dry_run).

---

## 7. Error reference

All errors are `{"error":"<code>"}` with the HTTP status shown.

**Both endpoints**

| Status | Code | Cause |
|---|---|---|
| 401 | `unauthorized` | Missing/wrong `x-rpa-key`. |
| 405 | `method_not_allowed` | Wrong HTTP method. |
| 503 | `service_not_configured` | Key secret not set on our side (tell us). |

**`rpa-derm-queue`**

| Status | Code |
|---|---|
| 500 | `queue_query_failed` |

**`rpa-derm-result`**

| Status | Code | Cause |
|---|---|---|
| 400 | `invalid_json` | Body was not JSON. |
| 400 | `unknown_field_<name>` | A field we do not accept. |
| 400 | `visit_id_required_integer` | Missing/invalid `visit_id`. |
| 400 | `manifest_id_must_be_integer_or_omitted` | Bad `manifest_id`. |
| 400 | `run_id_must_be_alnum_dot_dash_underscore_max100` | Bad `run_id` charset/length. |
| 400 | `status_must_be_short_uppercase_code` | `status` failed `^[A-Z0-9_]{1,64}$`. |
| 400 | `retryable_boolean_required` | `retryable` not a boolean. |
| 400 | `failure_reason_max_1000_chars` | Too long. |
| 400 | `portal_confirmation_max_200_chars` | Too long. |
| 400 | `attempted_at_must_be_iso8601` | Not a valid ISO timestamp. |
| 400 | `screenshot_missing_reason_max_300_chars` | Too long. |
| 400 | `screenshot_or_screenshot_missing_reason_required` | Neither provided. |
| 400 | `success_requires_portal_confirmation` | `SUCCESS` without a `portal_confirmation`. |
| 422 | `visit_not_found_or_deleted` | `visit_id` unknown or soft-deleted. |
| 500 | `visit_lookup_failed` / `result_store_failed_retry` | Transient; retry the same POST. |

---

## 8. Rollout gates

Nothing hits the county for real until, in order:

1. A **dry-run pass** over the historical visits (`?mode=dryrun`) — ~29 are available now.
2. The **first live report on a single visit** Fred picks, verified on the county side.
3. Then it **opens for all** the eligible clients.

---

## 9. Operating notes (our side)

- **Watchdog:** a daily health check surfaces a stuck queue / repeated data errors / storage failures.
- **Launch cutoff:** currently `2026-07-21` bounds the live queue.
- **Evidence retention:** screenshots live in the private `rpa-evidence` bucket keyed `visit_id/run_id.jpg`.
- **PII note (under review):** the queue currently signs the **raw multi-client** address sheet. This is
  intended because county submission needs the real document, but if the portal only needs the client's
  own row we will serve the redacted copy instead — pending confirmation of what the portal requires.

---

## 10. Integration checklist (what we still need from you)

1. **The CSV column list** you read today, so we can flag any field name you expect that we do not
   already return.
2. Your **repo link** (we set up a private repo under the `webunclogmecom` org; Railway auto-deploys
   from `main`).
3. Your **`/run` URL**, so we can flip the event push on.

We send the keys and the county portal login privately.

---

## 11. Using this Postman collection

The collection in this folder (`gdo-reporting-bot.postman_collection.json`) is a ready-to-run test
harness for the two endpoints above.

**Setup (once):** right-click the collection **UnclogMe - GDO Online Reporting Bot API** → **Edit** →
**Variables** tab → paste your key into `rpaBotKey`'s **Current value** column → **Save**. The value is
`RPA_BOT_KEY` in `Supabase/.env` (never commit it). Auth is one collection-level header
`x-rpa-key: {{rpaBotKey}}`, so every request uses it automatically. (An optional
`UnclogMe - RPA (Prod)` environment is also included; if selected it overrides the collection value.)

**Run:** top to bottom. Start with **1. Queue → Queue - dry-run** — it returns real historical code-27
visits and captures the first `visit_id` into a collection variable the Result requests reuse. Then run
**2. Result** (all `dry_run:true`, so they record separately and never affect the live queue or what
customers/apps see), and **3. Validation** (shows the endpoint rejecting bad input).

**Variables:** you only ever set `rpaBotKey`. `baseUrl` is preset. `dryRunVisitId` / `dryRunManifestId`
are auto-captured into **collection** scope by the dry-run request — leave them empty and do **not** add
them to a selected environment (an empty environment copy shadows the captured value and blanks the
Result requests).

**Gotcha:** a `401 unauthorized` means `rpaBotKey` is still blank (or an empty environment is selected
and overriding it). Dry-run result writes create harmless `dry_run` rows in our log table; clear anytime
with `DELETE FROM public.derm_portal_submissions WHERE dry_run;`. There is deliberately no
"SUCCESS needs confirmation" test here: that rule (and the double-file guards) apply only to LIVE
reports, so a dry-run `SUCCESS` is exempt and cannot be exercised against dry-run data.
