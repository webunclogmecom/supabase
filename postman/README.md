# GDO Online Reporting API

**Audience:** the integrator of the GDO Online Reporting RPA bot (Jonathan / "John").
**Status:** LIVE, filing real reports to Miami-Dade. 7 confirmed filings since 2026-07-24.
**Last updated:** 2026-08-24 (added the evidence endpoint, §4b).

> This is both the **API reference** and the doc for the Postman collection in this folder. It
> documents the **current** contract of the two endpoints your bot talks to, plus the surrounding
> pieces (event push, status surfaces, evidence storage, error codes). Nothing here is a secret: key
> **values** are sent to you privately, never committed. This repo is public.

---

## 1. What this is

The bot files **GDO Online Reporting** on the Miami-Dade DERM portal. For us that is **Line Item 27**
on a client's job, so the **unit of work is a serviced VISIT** for one of the clients that carry that
add-on, not a manifest — but the queue is **deduped per dump**, so you never receive the same manifest
twice (see §3). When we service such a client and their DERM manifest is filed + linked to the
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

- There is **one key** — the `x-rpa-key` you send us on every `GET`/`POST` above. It is matched
  against a **comma-separated** secret on our side, so we can rotate with zero downtime (add new,
  you switch, we remove old). You never see the list.
- The key lives only in your Railway environment variables, never in code or logs.

Missing/invalid key → `401 {"error":"unauthorized"}`. Key not configured on our side →
`503 {"error":"service_not_configured"}`.

---

## 3. `GET /functions/v1/rpa-derm-queue` — the work queue

Returns up to **25** reports to file, **oldest first**.

### 🛑 One report per ACTIVE PERMIT, not per ticket (changed 2026-08-11)

We pump **both** grease traps on a visit, so a client holding N active GDO permits owes Miami-Dade
**N reports per qualifying dump ticket**. Until 2026-08-11 this queue offered one, which was
under-reporting.

| | |
|---|---|
| `gdo_number` | now means **the permit this row is for**, not "the client's permit" |
| `gdo_id` | **new column**, our stable integer id for that permit |

**You still receive at most one permit per ticket at a time.** The 20-hour dispense lease is held
against the whole ticket, so the remaining permits stay back until the served one is filed. A
multi-permit ticket therefore reappears on a later poll carrying its next permit, and a three-permit
client (009-CN Casa Neos) files over roughly two days. The DERM deadline is the 15th of the following
month, so that is immaterial.

**Nothing about your contract changes.** Batch cap is still 25 rows, `visit_id` is still unique within
a batch, and you do **not** send the permit back: we resolve it ourselves from the pair we served.

⚠ Permit numbers render three different ways. The county email prints the bare integer (`12517`), our
`gdo_number` is a zero-padded string (`GDO-09853`), and the permit PDF prints `GDO-012517-2026/2026`.
**Compare as integers everywhere.** Four integer collisions exist across 135 active permits, all of
them the same number held by two different client records, and **none within a single client**, so
integer matching can never merge one client's own permits.

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

- **One row per dump (DERM manifest).** A county report is filed per **dump ticket / manifest**, so the
  queue returns **one report per manifest** even when more than one visit fed that dump (represented by
  the visit whose service date is closest to the dump). `visit_id` is still your work key — you just
  never see the same dump twice in a batch.
- A dump stays in the live queue **until it is successfully reported** — so nothing is dropped if the
  bot is down for a while.
- It leaves the queue **permanently** once the county confirms it (a `SUCCESS` result with a
  `portal_confirmation`, section 4). This is **manifest-scoped**: reporting *any* visit of a dump clears
  the whole dump, so a sibling visit can never re-surface an already-filed report.
- After any attempt — or the moment we hand it to you — the dump is **held for 20 hours** (a dispense
  *lease*, also manifest-scoped) so a crash between filing and the result POST can never cause a
  re-dispense and a double-file.
- The live queue only contains visits with a `dump_ticket_date` on/after a **launch cutoff** (currently
  `2026-07-21`). This exists so the bot's first live run cannot re-submit the entire historical backlog
  to the county. We widen the cutoff deliberately if a backfill is ever wanted.
- `?mode=dryrun` serves already-serviced **historical** visits and does **not** place a lease; use it
  freely for testing.

### 🛑 `held` — why the queue is empty (added 2026-08-25)

**Asked for by Jonathan:** *"the queue read empty on the 21st–23rd while 11024 sat excluded, so
'empty' and 'stuck' looked identical."* He was right. `count: 0` used to mean **both** "nothing to
file" and "a filing is stuck and nobody can see it". Every response now carries a `held` block:

```jsonc
"held": {
  "available": true,
  "total": 8,                       // REAL holds
  "by_reason": { "already_filed": 8 },
  "not_held": {                     // NOT problems, listed so they are not mistaken for holds
    "sibling_won_this_pass": 0,
    "before_launch_cutoff": 51
  }
}
```

**The reasons, and what each means for you**

| reason | what it means | needs you? |
|---|---|---|
| `already_filed` | the county confirmed it. The healthy steady state | no |
| `cooldown_20h` | an attempt landed in the last 20h | no, it serves after |
| `data_error` | a **non-retryable** failure holds it until something about the row **changes** | **maybe — see below** |
| `leased` | we handed the manifest out and are holding it 20h | no |

⚠ **`data_error` is the one to watch, and it is the one that bit us.** Its freshness anchor is a
timestamp **in our database**. If you fix the cause on the **county side** — a portal credential, a
permit registration — that fix is structurally invisible to the gate and the row will never come
back on its own, no matter how long you poll. **Tell us and we re-open it in one call.**

⚠ **`not_held` entries are not problems.** `sibling_won_this_pass` means the queue serves one permit
per manifest per pass and another permit won this one; it comes up next pass.
`before_launch_cutoff` is the historical backlog we deliberately do not file.

⚠ **`available: false` means the summary itself could not be computed** — the queue is still valid,
but do not read a missing `held` as "nothing held". An absent summary and an empty one are different
answers, which is the whole point of this block.

**`count` and `reports` are unchanged.** This is purely additive.

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
| `screenshot` | string | | base64 **JPEG or PNG**, ≤5 MB decoded. We detect the real format from the bytes and store the matching extension and content-type, so send whatever you have and do not re-encode. |
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
| `201` | `{"recorded":true,"deduped":false,"id":<n>,"screenshot_stored":<bool>,"screenshot_missing_reason":<str\|null>}` | New result stored. |
| `200` | `{"recorded":true,"deduped":true,"id":<n>,"screenshot_stored":<bool>,"screenshot_missing_reason":<str\|null>}` | Duplicate `(visit_id, run_id)`; no-op ack. |

**`screenshot_stored` (added 2026-08-11)** tells you whether the image is actually in the bucket.

An oversize, undecodable or unstorable image is **still recorded as a filing and still answers 201**,
with the image dropped. That is deliberate: a real county filing must never be lost over a screenshot
problem. Before this field existed you could not tell "filed with evidence" from "filed without it"
by reading the response. Now you can.

- `screenshot_missing_reason` carries **our** drop reason when we dropped it: `SCREENSHOT_TOO_LARGE`,
  `SCREENSHOT_DECODE_FAILED`, `STORE_FAILED`. It overrides whatever you sent in that field.
- On a **deduped 200** both fields describe the **stored row**, not what you just posted, because a
  dedupe uploads nothing. That is the number that tells you whether the stored filing has evidence.

**`gdo_id` and `gdo_number` are accepted and ignored.** You do not need to send them. We resolve which
permit a filing covered server-side, from the pair the queue served. They are accepted only so a bot
built against the earlier draft contract cannot get a `400` on a filing that already happened.

**If you do not get a 2xx, keep the result locally and retry the same POST** (same `run_id`) until you
do. Never treat a report as done before we acknowledge it.

**Screenshots:** send the bytes in the POST; we store them in a **private** bucket (`rpa-evidence`,
client data) and record only the path. You never need storage credentials. If images ever exceed the
5 MB cap routinely we will switch you to a signed upload URL.

---

## 4b. `POST /functions/v1/rpa-derm-evidence`: attach the image LATER

**Added 2026-08-24, for the case where the filing succeeds but its evidence is not ready yet.**
The county confirmation email usually arrives the same minute as the submit, but not always. Rather
than hold the run open or post a result you cannot evidence, **post the result first and attach the
image when it arrives.**

Same `x-rpa-key`. Body:

```jsonc
{
  "visit_id": 6216,                    // required
  "run_id": "5133d0d7-...",            // required, the SAME run_id you used on the result
  "screenshot": "<base64 JPEG or PNG>" // required
}
```

`manifest_id` and `dry_run` are accepted and ignored, so you can reuse your result body verbatim.
Any other field is a `400`.

**Responses**

| Code | Body | Meaning |
|---|---|---|
| `200` | `{"attached":true,"id":<n>,"screenshot_path":"...","screenshot_stored":true,"cleared_missing_reason":"<what it said before>"}` | Stored. Any `screenshot_missing_reason` on the row was cleared in the same write. |
| `200` | `{"attached":false,"already_had_evidence":true,"id":<n>,"screenshot_path":"..."}` | That result already has an image. **Not an error**. This is the expected answer to a retry. |
| `404` | `{"error":"result_not_found_for_visit_run"}` | No result stored for that `(visit_id, run_id)`. |

🛑 **FILL-ONCE. This endpoint can only ever turn "no image" into "an image".** It will never replace
an image we already hold, not even with a different one. That means **you can retry it as often as
you like, in any order, and concurrently with yourself, and it cannot do damage.** If you genuinely
need an image corrected, that is a human decision and staff do it in the DERM Tracker.

🛑 **POST THE RESULT FIRST.** Evidence for a `(visit_id, run_id)` we have never seen is a `404`, not
a stored orphan. The intended sequence is always:

1. `POST /rpa-derm-result` with your `screenshot_missing_reason` (say why it is not there yet), then
2. `POST /rpa-derm-evidence` with the same `run_id` once you have the image.

**Errors**

| Status | Code | Cause |
|---|---|---|
| 400 | `invalid_json` | Body was not JSON. |
| 400 | `unknown_field_<name>` | A field we do not accept. |
| 400 | `visit_id_required_integer` | Missing/invalid `visit_id`. |
| 400 | `run_id_must_be_alnum_dot_dash_underscore_max100` | Bad `run_id` charset/length. |
| 400 | `screenshot_required` | No image in the body. |
| 400 | `screenshot_too_large` | Over 5 MB decoded. |
| 400 | `screenshot_decode_failed` | Not valid base64. |
| 400 | `screenshot_must_be_jpeg_or_png` | The bytes are not a JPEG or a PNG. |
| 404 | `result_not_found_for_visit_run` | Post the result first. |
| 409 | `multiple_results_for_visit_run` | Should be impossible; tell us if you see it. |
| 500 | `submission_lookup_failed` / `evidence_store_failed_retry` / `evidence_fill_failed_retry` | Transient; retry the same POST. |

⚠ **Unlike `rpa-derm-result`, a bad image here IS a 4xx.** There we accept the result and flag the
evidence, because rejecting would lose a real county filing. Here the filing is already safely
recorded, so refusing a broken attach costs nothing and telling you plainly is more useful.

---

## 4c. `GET /functions/v1/rpa-derm-monthly`: the LWT monthly report

**Added 2026-08-24**, read-only, for the Miami-Dade Liquid Waste Transporter monthly filing.

```
GET /functions/v1/rpa-derm-monthly?month=YYYY-MM
```

Same `x-rpa-key`. **No lease, no dispense, no side effects.** Safely re-callable: two calls a second
apart return the same body unless a manifest changed underneath. This is deliberately the opposite of
the queue, whose job is to never hand the same work out twice.

**Query params**

| Param | Values | Meaning |
|---|---|---|
| `month` | `YYYY-MM` | **required.** Selected on the OFFLOAD date, so a ticket is never split across two reports. |
| `include` | `all` | Optional. Return every row of every ticket in the month, in-scope or not. Omit for the filing set. |

**Response `200`** (abridged)

```jsonc
{
  "month": "2026-08",
  "county": "Miami-Dade",
  "scope": "picked up in Miami-Dade OR offloaded in Miami-Dade, evaluated per activity",
  "include": "in_scope",
  "ticket_count": 12, "row_count": 70, "excluded_rows": 10,
  "tickets": [{
    "ticket_number": "312024",
    "ticket_kind": "yellow",              // white = Dade offload, yellow = Broward offload
    "offload_in_dade": false,
    "offload_date": "2026-08-21",
    "disposal_facility": "Water and Wastewater Services",
    "trucks": ["David", "Moises"],
    "excluded_rows": 6,
    "rows": [{
      "pickup_date": "2026-08-16",        // the VISIT date. see the warning below
      "client_code": "026-HAP", "client_name": "Happea's",
      "address": "1250 South Miami Avenue", "city": "Miami",
      "state": "FL", "zip": "33130", "county": "Dade",
      "pickup_in_dade": true, "in_scope": true,
      "truck": "Moises", "truck_capacity_gallons": 9000,
      "gallons": null,
      "visit_id": 6587
    }]
  }]
}
```

**`state` is a USPS two-letter code** (normalised 2026-08-25). It used to be served as whatever we
held, which was inconsistently `"Florida"` and `"FL"`. It is now mapped from an explicit list.

🛑 **If you ever receive a `state` that is NOT two letters, that is us handing you a value we did not
recognise, passed through verbatim on purpose so it is visible rather than silently relabelled.
Treat it as an error and do not print it on the form.** We deliberately do not coerce an unknown
state to `FL`, because doing so would put a false state on a county filing for a property that is
genuinely somewhere else. Every value we currently hold maps cleanly, so this should never fire.

**`client_name` has typographic punctuation folded to ASCII** (curly apostrophes become `'`). Accented
LETTERS are deliberately preserved, because they are the correct spelling of a real name -- you will
see `Fendi Château Residences` and addresses on `Española Way`, and those are not encoding errors.

**Rows come back in a total, stable order** (added 2026-08-25): `offload_date`, `ticket_number`,
`pickup_date`, `visit_id`, `manifest_id`. Two identical calls are byte-identical, so the `ETag` is
meaningful and successive pulls can be diffed.

⚠ **This is new.** Until 2026-08-25 the sort had only the first three keys, which left **571 of 690
rows in a tie group** — the same rows could come back in a different sequence on two identical
calls. If you built anything before that date on "the body is stable", it was true most of the time
and not guaranteed. It is guaranteed now.

### 🛑 Scope is evaluated PER ACTIVITY, not per ticket

The form covers *"all transportation activities where liquid waste was picked up OR offloaded in
Miami-Dade County"*, and an activity is a pickup. Both obvious shortcuts are wrong, and both were
measured over 2026 before this was built:

- filtering on **"offloaded in Dade" alone drops 11 tickets and 53 activities**, Broward offloads that
  carried Miami-Dade pickups;
- applying the OR at **ticket** grain **over-reports**, because 20 tickets mix counties. Measured on
  August: ticket `311045` has 0 in-scope rows of 2, `312024` has 3 of 9, `310590` has 6 of 8.

So the rule is `pickup county = Dade OR the ticket offloaded in Miami-Dade`, applied to each row. If a
ticket offloaded in Dade then every pickup on it qualifies, so only Broward-offload tickets get
trimmed.

**By default you receive only in-scope rows**, and a ticket with no in-scope activity is omitted
entirely. Nothing is dropped silently: `excluded_rows` is reported per ticket and for the month, and
`?include=all` returns the superset so you can see exactly what was filtered and apply your own rule.

### 🛑 `pickup_date` is the VISIT date, never our `service_date`

Our `derm_manifests.service_date` is a misnomer that holds the **dump** date: the DERM Tracker writes
the entered dump date into both columns, so 622 of 659 live manifests have them identical. This endpoint
reads the linked visit instead. If you ever see `pickup_date` equal to `offload_date` on every row,
that is the bug, not the data.

⚠ **A pickup can fall in the previous month.** Ticket `831710` offloaded 2026-08-02 carrying a
2026-07-30 pickup. The month selects on the offload date so a ticket is never split in two.

### ⚠ `gallons` is always `null`, and that is the contract

The filed quantity is the **truck capacity**, which is a property of the vehicle and its decal, not of
the manifest. We store no measured volume per load, so any number here would be a guess dressed as
data. `truck` and `truck_capacity_gallons` are served so you have the input. The fee arithmetic
(`total gal × $0.00419`, **truncated** to cents, not rounded) stays in your generator, which is
validated against filed pages.

### 🛑 `data_quality` — read this before you file

**Added 2026-08-24.** Every response carries a `data_quality` block:

```jsonc
"data_quality": {
  "checked": true,          // did the check actually run? see the warning below
  "conflict_count": 1,
  "conflicts": [{
    "visit_id": 6756, "ticket_number": "830673",
    "conflict_kind": "pickup_after_offload",   // or "visit_not_completed", or "both"
    "days_after_offload": 7, "violates_guard": true,
    "client_code": "175-PV",
    "offload_date": "2026-07-22", "pickup_date": "2026-07-29",
    "visit_status": "completed"
  }]
}
```

and the affected row also carries an inline `anomaly` object (it is `null` on every healthy row).

A conflict means the activity **contradicts itself**: the pickup is dated after its own offload, or
the visit backing it is not marked completed. Grease is pumped before it is dumped, so one of the two
records is wrong. **Check it against the paper manifest before filing.**

**These rows are still returned, never filtered or corrected.** Silently clamping a compliance date is
worse than printing an odd one, and it is your call, not ours. As of 2026-08-24 there are 4 such rows
in all of 2026 — one each in January, March, May and July.

⚠ **`checked: false` means the check itself failed**, so an empty `conflicts` list proves nothing.
`conflict_count` is `null` in that case. Do not read zero as an all-clear without `checked: true`.

**Caching:** every response carries a weak `ETag`. Send it back as `If-None-Match` and a repeated poll
for the same month costs a `304`.

**Errors**

| Status | Code | Cause |
|---|---|---|
| 400 | `month_required_yyyy_mm` | missing or malformed `month` |
| 400 | `month_out_of_range` | before 2024, or more than ~2 months ahead |
| 400 | `month_too_large` | over 1,000 rows. Raises rather than truncating: a short compliance report is the worst failure available |
| 401 | `unauthorized` | missing/wrong `x-rpa-key` |
| 405 | `method_not_allowed` | anything but GET |
| 500 | `monthly_query_failed` | transient, retry |

---

## 5. How you run it — you poll, on your own schedule

**You own the timing. There is no push from us** — you don't expose any endpoint, and there is no
second "run" key. Just poll the queue and file whatever it returns:

- Poll `GET /rpa-derm-queue` on a **slow schedule** (every 15–30 min is plenty), file each report,
  and POST the result. That's the whole loop.
- Reporting is safe to run as often as you like: the queue only hands you visits that still need
  filing (a `SUCCESS` permanently removes one), each dispensed visit is **leased for 20h** so a crash
  can't get it re-handed-out, and `rpa-derm-result` is **idempotent on `(visit_id, run_id)`** — so a
  duplicate or retried run never double-files.
- Nothing on our side calls you, so you never need an inbound endpoint or a public URL.

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

✅ **Gates 1 and 2 are PASSED.** The dry-run pass ran, and real reports have been filed and confirmed
on the county side: **7 confirmed filings between 2026-07-24 and 2026-08-17**.

3. Gate 3, **opening it for all** the eligible clients, is the remaining one and is Fred's call.

---

## 9. Operating notes (our side)

- **Watchdog:** a daily health check surfaces a stuck queue / repeated data errors / storage failures /
  a code-27 visit whose service is not DERM-manifest-requiring (a mis-applied add-on to flag).
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

We send the key and the county portal login privately. You expose nothing to us — you poll (section 5).

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

**Variables:** you only ever set `rpaBotKey`. `baseUrl` and `wrongRpaKey` are preset. `dryRunVisitId` /
`dryRunManifestId` / `evidenceRunId` are auto-captured into **collection** scope by the requests that
create them.

🛑 **`wrongRpaKey` exists so the "Wrong key -> 401" test does NOT hold a literal in its auth field, and
it must stay that way.** Postman's secret scanner flags **any** hardcoded value in an auth field as an
"Auth secret", whatever the string is: it flagged `deliberately-wrong-key` and then flagged the
harmless rename `WRONG-ON-PURPOSE` identically. That prompt **blocks the whole collection import**
behind Vault / Secure / Remove, none of which suit a value that is deliberately invalid. A `{{variable}}`
is never flagged, which is why the collection's own auth (`{{rpaBotKey}}`) always imported cleanly.
⚠ Put a literal back in that field and every future import, including John's, hits the prompt again.

**⚠ Importing by URL silently does nothing.** Pasting the raw GitHub URL into Import produced
"Import Failed" (and once, "Import Complete" and "Import Failed" at the same time) while changing
nothing. **Paste the JSON contents instead**, which works first time. Verify by looking at the folder
tree, never at the notification — leave them empty and do **not** add
them to a selected environment (an empty environment copy shadows the captured value and blanks the
Result requests).

**Gotcha:** a `401 unauthorized` means `rpaBotKey` is still blank (or an empty environment is selected
and overriding it). Dry-run result writes create harmless `dry_run` rows in our log table; clear anytime
with `DELETE FROM public.derm_portal_submissions WHERE dry_run;`. There is deliberately no
"SUCCESS needs confirmation" test here: that rule (and the double-file guards) apply only to LIVE
reports, so a dry-run `SUCCESS` is exempt and cannot be exercised against dry-run data.
