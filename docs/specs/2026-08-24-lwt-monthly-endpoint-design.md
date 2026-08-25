# Design: `rpa-derm-monthly`, the LWT monthly report endpoint

*Written 2026-08-24 by @Building Apps, from Jonathan's message after Diego's handover of the blank
form plus six filed pages.* **Status: SHIPPED 2026-08-24.** `derm.v_lwt_monthly_rows` (`2026-08-24_1730`) and the
`rpa-derm-monthly` endpoint are live, docs and Postman updated. 17 of 17 end-to-end assertions pass,
including the scope controls below.

⚠ **The six discrepancies in section 7 are NOT resolved.** They are questions for John, not blockers,
and the endpoint serves the facts either way. The two that change his build: "one quantity per ticket"
does not hold (43 of 127 tickets used more than one truck), and no truck we own is 3,800 gallons.

---

## 1. Read or write? READ ONLY, and not just because he said so

His words: *"the read-only monthly endpoint you scoped."* No POST, PATCH or DELETE anywhere in the
ask. That is also the architecturally correct answer, for a reason worth stating because it will come
up again:

**Every field on this report already originates on our side.** Ticket number, offload date and
facility come from the DERM Tracker upload; pickup date, client and service address come from the
Calendar and Jobber. There is nothing on the form that the bot knows and we do not. So there is
nothing for it to create, correct or delete, and granting write access would create a **second writer
to compliance data with no business reason to exist**. Compare `rpa-derm-result`, which is a genuine
write because only the bot knows what the county portal answered.

⚠ **There is exactly one candidate for a future write, and he did not ask for it:** recording that a
given month's report was filed, the way `derm_portal_submissions` records a GDO filing. That would
turn "did we file August?" from a question somebody answers by looking in a folder into a query.
**Recommend deferring it** until they have run one real cycle: they are hand-filling July, August is
the first machine cycle, and inventing a state machine before the manual process is understood is how
you get a schema nobody uses. Raise it after August.

## 2. What I verified before designing anything

Measured against Prod, all of it, because two of his statements collide with known traps here.

**✅ He is right that pickup date is the VISIT date, and the reason is one he may not know.**
`public.derm_manifests.service_date` is a misnomer: the DERM Tracker writes the entered dump date
into **both** `service_date` and `dump_ticket_date`, so 622 of 659 live manifests have them
identical. Had we served `service_date` as the pickup date, **every pickup would have equalled its
own offload date** and six filed pages would have disagreed with us. The real service date exists
only on the linked visit (`public.visits.visit_date`).

**✅ His "Manifest / Ticket #" single field maps cleanly, and the mapping is self-proving:**

| field | populated | disposal facility | county |
|---|---|---|---|
| `white_manifest_number` | **502** | South District WWTP | Miami-Dade |
| `yellow_ticket_number` | **157** | Water and Wastewater Services | Broward |
| `wwtp_ticket_number`, `wwtp_receipt_number` | **0** | never populated | |

502 and 157 match the facility split **exactly**, so white implies a Miami-Dade offload and yellow a
Broward one. Also measured: **0 collisions** between the two number spaces and **0 manifests carrying
neither**, so `COALESCE(white, yellow)` is a total, unambiguous key. That is the field the form wants.

**✅ Volume is tiny, so his "no lease, no cap" is right.** Per month over 2026: 8 to 18 tickets, 66 to
109 manifests, 65 to 109 visits. A month fits in one response with room to spare.

**✅ The client is unambiguous.** Across 690 links, `manifest.client_id` differs from
`visit.client_id` **zero** times, because `trg_aa_link_same_client` rejects a cross-client link. So
the client can be taken from either side without a tie-break.

## 3. 🛑 The scope rule belongs at ROW grain, not ticket grain. This is the main design decision

The form says *"all transportation activities where liquid waste was picked up **OR** offloaded in
Miami-Dade County."* An "activity" is a pickup, not a ticket.

**First: the OR is load-bearing, not theoretical.** Measured over 2026:

| offloaded in Dade | any Dade pickup | tickets | |
|---|---|---|---|
| no | **yes** | **11** (83 visits) | **invisible to an offload-only filter** |
| yes | no | 1 (5 visits) | qualifies through the offload leg |
| yes | yes | 105 (531 visits) | qualifies either way |
| no | no | 9 (71 visits) | correctly excluded |

Those 11 tickets are Broward offloads carrying Miami-Dade pickups. A naive "offloaded in Dade" build
would silently drop 83 real activities from a regulator-facing report.

**Second, and this is the subtle half: a ticket can mix counties. 20 tickets do** (Broward+Dade,
Broward+Palm Beach). So applying the rule at ticket grain **over-reports**: a Broward pickup that was
also offloaded in Broward does not belong on the Miami-Dade form merely because a different pickup on
the same truckload happened to be in Dade.

⇒ **The correct predicate is per row:**

```
include a pickup row  ⇔  pickup_county = 'Dade'  OR  ticket offloaded in Miami-Dade
```

Note the asymmetry that makes it work: if the ticket offloaded in Dade then **every** pickup on it was
offloaded in Dade, so all its rows qualify. Only the Broward-offload tickets need row-level filtering.

**How the endpoint should handle it.** He said his *"broader-read-and-filter-down build was right"*, so
serve the superset and let his generator decide: return every qualifying ticket **with all of its
rows**, each row carrying its own `county` and a boolean, plus a ticket-level offload flag. **Do not
bake the regulatory judgement into the API.** If DERM reinterprets the rule, he changes a filter
rather than waiting on us to redeploy.

⚠ `public.properties.county` stores **`'Dade'`**, while `public.disposal_facilities.county` stores
**`'Miami-Dade'`**. Two vocabularies for one county. Comparing them naively matches nothing. The view
normalises; the response should emit one spelling and say which.

## 4. The contract

```
GET /functions/v1/rpa-derm-monthly?month=YYYY-MM
Header: x-rpa-key   (same key as the other three, same auth model)
```

**Response 200**

```jsonc
{
  "month": "2026-06",
  "generated_at": "2026-08-25T11:00:00.000Z",   // excluded from the ETag, or every call would differ
  "county": "Miami-Dade",
  "scope": "picked up in Miami-Dade OR offloaded in Miami-Dade, evaluated per activity",
  "include": "in_scope",                        // or "all" with ?include=all
  "ticket_count": 11,
  "row_count": 75,
  "excluded_rows": 10,                          // rows on these tickets that fell OUT of scope
  "data_quality": {
    "checked": true,                            // ⚠ false = the overlay query FAILED and an
                                                //   empty conflicts list proves NOTHING
    "conflict_count": 0,
    "conflicts": []
  },
  "tickets": [
    {
      "ticket_number": "826114",
      "ticket_kind": "white",          // white = Dade offload, yellow = Broward offload
      "offload_in_dade": true,
      "offload_date": "2026-06-01",
      "disposal_facility": "South District WWTP",
      "trucks": ["Moises"],            // distinct trucks across the rows; see the open question
      "excluded_rows": 0,              // per-ticket, and the reason a ticket can appear with
                                       // fewer rows than it really has: 20 tickets mix counties
      "rows": [
        {
          "pickup_date": "2026-05-28",     // visits.visit_date, NEVER derm_manifests.service_date
          "client_code": "017-FIA",
          "client_name": "Florida Food Eats LLC Fialkoff's (Surfside)",  // punctuation folded to
                                           // ASCII; accented LETTERS deliberately preserved
          "address": "9463 Harding Avenue",
          "city": "Surfside",
          "state": "FL",                   // USPS 2-letter. ⚠ anything NOT two letters is an
                                           // unrecognised value passed through VERBATIM on
                                           // purpose -- treat it as an error, do not print it
          "zip": "33154",
          "county": "Dade",
          "pickup_in_dade": true,
          "in_scope": true,                // county='Dade' OR ticket offloaded in Dade
          "truck": "Moises",
          "truck_capacity_gallons": 9000,
          "gallons": null,                 // ALWAYS null, by design. See section 6.
          "visit_id": 4636,
          "anomaly": null                  // non-null = this row's dates are impossible; see 2026-08-24_1510
        }
      ]
    }
  ]
}
```

⚠ **This example is a real payload**, fetched from the live endpoint on 2026-08-25 and abridged to a
single row. An earlier version of it was hand-written, claimed `"month": "2026-08"` while its only
ticket is a JUNE ticket, and omitted `scope`, `include`, `excluded_rows`, `data_quality`, `visit_id`
and `anomaly` — six fields the endpoint has always served. Rows are returned in a **total, stable
order** (offload_date, ticket_number, pickup_date, visit_id, manifest_id), so two identical calls
are byte-identical; that only became reliable on 2026-08-25, when the last two keys were added.

**Errors**, reusing the existing vocabulary exactly:

| Status | Code | Cause |
|---|---|---|
| 400 | `month_required_yyyy_mm` | missing or malformed `month` |
| 400 | `month_out_of_range` | year before **2024**, or the month END more than **62 days** ahead of now |
| 400 | `month_too_large` | over 1,000 rows. Raises rather than truncating — a short compliance report is the worst failure available |
| 401 | `unauthorized` | missing/wrong `x-rpa-key` |
| 405 | `method_not_allowed` | anything but GET |
| 500 | `monthly_query_failed` | transient, retry |
| 503 | `service_not_configured` | key secret not set our side |

**Semantics.** Pure function of the data: no lease, no side effects, safely re-callable. Two
calls a second apart return the same body unless a manifest changed underneath.

⚠ Two corrections to earlier wording in this section, both measured against `index.ts` on
2026-08-25. **"no cap" is wrong** — there is a 1,000-row cap that raises `month_too_large`
rather than truncating (the largest real month is 109 rows, so it has ~9x headroom and has
never fired). And the range guard is `year >= 2024` and month-end within **62 days**, not
"one month in the future".

⚠ **"the same body" only became true on 2026-08-25.** The sort had three keys and left 571 of
690 rows in tie groups, so two identical calls could return the same rows in a different
order and hash to different ETags. `visit_id` and `manifest_id` now make the order total.

⚠ **Add `ETag` and honour `If-None-Match`.** His preview UI is a "pick a month, review, download" loop
that will re-poll the same month repeatedly. A hash of the result set turns every repeat into a `304`.
Cheap now, awkward to retrofit once a client depends on always getting a body.

⚠ **A cap is still needed even though he asked for none.** Not for his volume, which is trivial, but
because an unbounded endpoint is a latent outage. Set a documented ceiling far above real volume
(1,000 rows) and return a **loud 400 `month_too_large`** if it is ever hit. **Never truncate
silently:** a short report on a compliance filing is the worst possible failure, and this repo has
been bitten by silent caps before.

## 5. Architecture: a view does the work, the function is transport

Put the logic in **`derm.v_lwt_monthly_rows`**, one row per (ticket, linked visit), carrying the
normalised county, both dates, client, address, truck and the two flags. The edge function then does
only what an edge function is good at: check the key, validate `month`, select the range, group rows
into tickets, emit JSON.

Three reasons this split is not ceremony:

1. **It is testable without HTTP.** The scope predicate is the part that can be wrong in a way a
   regulator notices, and in a view it can be exercised in a rolled-back probe against real months and
   diffed against Diego's six filed pages.
2. **Our own apps can read it.** The DERM Tracker could show "this month's LWT rows" from the same
   view, with zero risk of a second, divergent implementation of the scope rule. Two assemblies of one
   rule is how most of the defects in this repo's CLAUDE.md were born.
3. **It matches the house pattern.** `rpa-derm-queue` already reads `v_derm_portal_queue` rather than
   assembling its own SQL.

**Auth**: identical `x-rpa-key` check, copied from the existing functions, `verify_jwt = false` in
`config.toml`, service-role client. No new secret, no new key to distribute.

**No new tables. No migration to any existing table.** The endpoint is pure read.

## 6. What we deliberately do NOT compute, and why that is the right call

- **`gallons` stays `null`.** He resolves quantity from the decal client-side. Correct: the quantity
  on the filed form is the **truck capacity**, which is a property of the vehicle and the decal, not of
  the manifest. We do not store a measured volume per load, so anything we put here would be a guess
  dressed as data. Serving `truck` and `truck_capacity_gallons` gives him the input without us
  asserting the answer.
- **The fee and its truncation.** `total_gal × $0.00419`, **truncated** to cents. That belongs in his
  generator, which is validated against six filed pages, and it must live in exactly one place. If we
  also computed it, the two would drift and the filed artifact would depend on which one was believed.
  ⚠ Worth recording because it is genuinely surprising and will look like a bug to whoever meets it
  next: **truncation, not rounding.** Two filed pages only reproduce that way.
- **Form layout and pagination of the printed artifact.** His.

## 7. Discrepancies to put to John before he builds against this

These are all measured, and each one changes something on his side.

1. 🛑 **"One quantity per ticket" does not hold in our data. 43 of 127 tickets used more than one
   truck** (33 used two, 10 used three). If the quantity is resolved from the decal, a three-truck
   ticket has three capacities and one line cannot represent it. Either the form wants one row per
   truck load (which is what "per truck load" suggests), or those tickets need splitting. **This is the
   most important question of the six.**
2. 🛑 **No truck we own has a 3,800 gallon capacity.** Ours are Moises 9,000, Goliath 4,800 (INACTIVE),
   David 1,800, Cloggy 126. The receipt he quotes prints "approximately 3800 gallons". So either the
   capacity figures we hold are wrong, or the receipt quantity is not our truck capacity, and his
   client-side resolution will not reproduce that page.
3. **4 links have a pickup date AFTER the offload date.** Legal in our data: the guard allows
   `visit_date <= dump_ticket_date + 1` as a grace for overnight operating-date timing. On a form they
   would read as waste offloaded before it was collected. He should decide whether to clamp or flag.
4. **14 linked visits in 2026 carry no property**, so no address and no county. They cannot be scoped
   by the pickup leg and will arrive with nulls. **6 carry no truck**, so no capacity.
5. **One ticket has zero linked visits.** It offloaded but has no pickups to list. Include it as an
   empty ticket, or omit it? Omitting hides a real offload; including prints a row with no activity.
6. ~~**`state` reads "Florida", not "FL"**, and client names carry typographic apostrophes
   (`Fialkoff's`). Cosmetic, but it lands on a printed county form.~~
   ✅ **RESOLVED 2026-08-25 - Fred: "yes normalise both"** (`2026-08-25_0400`). The endpoint now
   serves `state` as a USPS two-letter code and client names with ASCII punctuation. **John needs no
   change and should be told it is done, not asked.**
   🛑 Both obvious implementations are wrong, so if this is ever revisited:
   - `state` is an **explicit CASE, never the constant `'FL'`**. `properties.state` holds California,
     Quebec and New York rows today, so a constant would relabel a non-Florida property on a
     compliance form the first time one took a Miami-Dade pickup. Unrecognised values pass through
     **verbatim**. Proven by outcome: a rolled-back probe drove 14 values through the live view and
     `Ontario` / `Puerto Rico` / `XYZZY` each came back unchanged.
   - The punctuation fold is a **fixed seven-character list, not `unaccent()`**. "Fendi Chateau
     Residences" (a-circumflex) and "409/448 Espanola Way" (n-tilde) are CORRECT spellings - a real
     business name and a real Miami Beach street - and stripping them would misspell the county form.
     The migration's VERIFY therefore requires those accents to **survive**; asserting "0 non-ASCII"
     would be asserting the regression.
   - Re-validated end to end: all 8 months still match the database (690 rows / 589 in scope / 126
     tickets, unchanged), and the served payload carries 0 curly apostrophes with both accents intact.

## 8. Can this extend the existing API? Yes as a surface, no as a resource

Fred's question. My answer is that it should join the **same API** and must not be folded into the
**same endpoints**.

**Share, because it is free and it is what an integrator experiences as "one API":** the base URL, the
`x-rpa-key` auth, the `{"error":"code"}` error vocabulary, the accept-and-ignore-unknown-fields
discipline, one `postman/README.md`, and one Postman collection with a new folder. John should not
have to learn a second set of conventions.

**Do not merge it into `rpa-derm-queue`.** They are different resource types wearing similar clothes:

| | `rpa-derm-queue` | `rpa-derm-monthly` |
|---|---|---|
| question | "what work is outstanding?" | "what happened in August?" |
| state | **stateful**: 20h dispense lease, one-per-permit, exits on SUCCESS | **stateless**, pure read |
| repeat call | deliberately gives you something different | must give you the same thing |
| cache | never | should be cached, ETag |
| cap | 25, deliberate | none, by nature |

Putting a lease on a report, or removing the lease from the queue, would break the property that makes
each one correct. **The queue's whole job is to not hand the same work out twice; the report's whole
job is to be repeatable.** They are opposites, and that is the real reason to keep them apart.

### What I would change about the existing API, honestly

Since you asked what I think about building REST APIs, the useful version is what I would and would
**not** do here:

**Would not.** Rename anything. `rpa-derm-queue` / `-result` / `-evidence` / `-monthly` are
RPC-flavoured names rather than resources; a textbook design would be `GET /reports/queue`,
`POST /visits/{id}/results`, `PUT /results/{run_id}/evidence`, `GET /reports/monthly/2026-08`. **It is
not worth it.** There is one consumer, it is live and filing to a county, and the only benefit is
aesthetic. A breaking rename that risks a compliance integration to satisfy a naming convention is a
bad trade. Naming purity is the cheapest thing to want and the most expensive thing to retrofit.

**Would not.** Add path versioning or a version header. One consumer, additive changes only so far,
and the existing accept-and-ignore-unknown-fields rule already does the practical work of a version
scheme. Add versioning the day a second consumer appears, not before.

**Would, and these are cheap:**
- **`ETag` on the read endpoints.** Both the queue and the monthly report are re-polled by a bot.
- **Explicit null semantics, documented.** `gallons: null` is a contract here ("we do not know, resolve
  it yourself"), not an accident. An undocumented null is the thing every integrator guesses wrong.
- **A documented ceiling with a loud error instead of a silent truncation**, on any endpoint that
  returns a list.
- **Keep the two-error-channel discipline.** The existing functions already separate transport failure
  from business refusal; the new one should not invent a third shape.
- **One doc, one collection, always updated in the same commit as the code.** That has been the
  weakest link in this API's history rather than anything about the code.

The general principle behind all of it: **an API's real interface is its contract plus its
documentation, and the expensive mistakes are semantic rather than structural.** Serving the dump date
under a field named `service_date` would have been a perfectly RESTful, perfectly named, completely
wrong API.

## 9. Verification plan

- Build the view first and **diff it against Diego's six filed pages** (Feb/Mar/Jun). Those pages are
  the only ground truth that exists, and they are the reason the truncation rule was found. A month
  that reproduces a filed page is the acceptance test.
- **Assert the scope predicate with a control that must fire**: the 11 Broward-offload tickets with
  Dade pickups must be present, and the 9 Broward/Broward tickets must be absent. A build that returns
  everything passes a naive test and is wrong.
- Exercise the row-grain rule on a **mixed-county ticket** specifically, since ticket-grain and
  row-grain agree everywhere else.
- Confirm `pickup_date` never equals `offload_date` fleet-wide by construction, which is the tell that
  `service_date` crept back in.
- Postman: a fifth folder, dry-run safe by nature since the endpoint has no side effects.
