# Boca Raton on BSI Online: what exists, what is waiting

*Written 2026-11-04, while the work waits on Yan's video. Keep it current in the same cycle as any change to this work.*

This page is the way in. The reasoning and the full bot design are in
[the plan](../specs/2026-11-03-boca-bsi-leads-and-filing-plan.md); its top section holds the next steps. Trello: #165
`f3Q3Q55i`, #166 `IWJkqTq1`, #169 `0lAWU6Ge`, all In Progress.

**On purpose, nothing here holds a CCN, a BSI contact or a login.** This repo is public.

## In short

- Miami-Dade clients report to DERM, and the GDO report bot files them. Boca Raton clients report to the City of Boca
  Raton's program on **BSI Online** instead, with a **CCN** where Miami-Dade has a GDO number.
- **Nothing files on BSI yet.** Our account had filed 0 reports when it was read on 2026-11-03. Yan files first by hand,
  on video. The bot comes after that, with Fred's go.
- **On hold since 2026-11-04.** Fred: *"first let's wait on the video"*. The CCNs and line 27 wait until it arrives.
- **The routing is already live.** A Boca visit with line 27 stays out of the DERM queue, so the bot cannot file it with
  the wrong agency. No routed client has line 27 yet, so today this changes nothing for anyone.

## Where each piece stands

| Piece | State |
|---|---|
| The BSI scrape (431 properties in the City's program) | Done 2026-11-03, read-only. Raw file in the workspace `backups/`, never in a repo |
| Frozen leads, private schema `leads` | Built and loaded: 420 frozen, 4 linked to clients, 7 waiting for a decision |
| Line-27 routing, and the alerts when it cannot route | Built. First real run clean on 2026-11-04 04:00 ET. No routing alert has fired for real, because no routed client has line 27 |
| Matching our clients to BSI records | 4 of the 10 done (`2026-11-04_1338`), from Yan's answers |
| The 4 CCNs in the Client App | Not done. The office types them, after the video |
| Line 27 on those clients' jobs | Not done, after the CCNs |
| Yan's hand filing, on video | **Waiting.** Fred: they know, and they will make one |
| The filing bot | Not built. It needs the capture from the hand filing, and Fred's go |
| Contact enrichment | Not started. A pilot comes first (plan 8.2) |
| Records request to the City | Not decided (plan decision F4) |
| Viktor reading the leads views | Granted, never tested. Test when Fred says |

## Our clients

`public.fn_client_files_with_bsi(client)` decides who is routed: no live GDO permit, and a live property whose city reads
Boca Raton. It looks at the city name, not at BSI, so being routed does not mean BSI knows the client.

| Client | Status | On BSI? | Open job for line 27 |
|---|---|---|---|
| 022-GRO Grove Kosher | RECURRING | **Yes**, GROVE KOSHER MARKET, 2 interceptors | 1325 |
| 064-TCE Carrot Express Boca | RECURRING | **Yes**, CARROT LOVE PALMETTO PARK LLC, 1 | 1427 |
| 225-PV Pura Vida | RECURRING | **Yes**, PURA VIDA, 1 | 1624 |
| 240-TUR El Turco | ACTIVE | **Yes**, EL TURCO EXPRESS, 1 | No schedule, only Service Call 1714 |
| 135-BB Bagel Boss | RECURRING | Not found. Yan does not know why. The odd one: BSI lists 22161 and 22191 Powerline Rd in its ZIP, nothing at 22107 | Keep off |
| 081-TCE Carrot West Boca | RECURRING | Not found. BSI lists nobody in ZIP 33498, so probably outside the City | Keep off |
| 319-CAP Capas Burger Boca | ACTIVE | Not found, same ZIP | Keep off |
| 361-SFG South Florida Golf Carts | ACTIVE | Not required for compliance (Yan: rain water). Recorded as absent | Never |
| Alta Standard One | ACTIVE | Possibly THE STANDARD. Not asked: every job archived, no visit, no code | None |
| Olympus Academy | ACTIVE | Not found. Not asked, for the same reason | None |
| 112-YA Yan's Restaurant | ACTIVE | Test client, routed by its test CCN | Test only |

ACTIVE alone does not mean we serve a client: on 2026-11-04, 147 of the 323 ACTIVE clients had no code and 185 had no
completed visit. Fred's rule for questions to staff: only clients that are active or recurring, meaning we really serve them.

## What happens to a Boca visit today

1. **Line 27 is the switch**, the "27 - GDO Online Reporting" line, as in Miami-Dade. It is also a billing line: the
   invoice reads "GDO Online Reporting", so the plan puts it on at $0.
2. **A routed client's line-27 visits stay out of the DERM side**: `v_derm_portal_fields` (so the bot's queue and the
   held view), `v_gdo_reporting_derm_mismatch`, `derm.gdo_report_status` and the no-permit part of `log_rpa_derm_health()`.
3. **Fred's health email carries the waiting.** The logger runs at 04:00 ET and the email goes at 08:30 ET (winter):
   - `bsi_route_unfiled`: a routed client has line 27, and Yan should file it by hand. It stays open until the work
     changes, because nothing records a BSI filing yet.
   - `bsi_route_gdo_and_boca`: line-27 work at a Boca Raton property of a client with a live GDO. Those visits go to
     Miami-Dade, and the bot may file before the email arrives. 0 such clients today.
   - `bsi_route_other_city`: line-27 work elsewhere, or with no property, for a routed client. 0 today.
4. **Line-27 work** means an open job's own lines, or a GDO-reporting visit since 2026-07-21 that was not skipped or cancelled.

Details and proofs are in Supabase `CLAUDE.md`, section PERMITS.

## Filing by hand

Read from Yan's first video (2026-11-02) and from BSI itself. **Steps 6 to 9 have never been seen working:** that video
stopped before Submit, and nobody has filed through this account.

1. On the BSI dashboard, open **Enter FOG Maintenance Report**.
2. Paste the property's **CCN**, and wait until exactly one card shows. Do not search by FOG Location ID: it finds
   nothing. BSI's search covers every city, and often lists a place under its owner's legal name.
3. **Select.** Check that Organization is "City of Boca Raton Utility Services", that the CCN matches, and that the Filing
   Fee is $0.00.
4. **Enter maintenance** on an interceptor we pumped. Two interceptors need two reports.
5. Fill in the form: the visit date; Hauling Company (already UNCLOGME LLC); Performed By (Aaron Azoulay, the only name
   listed); the plant that took that load; leave depths and gallons empty for now; and the document, which is not settled.
6. **Submit maintenance report.** It reads "Maintenance report added to cart". **The report is not filed yet.**
7. After the last interceptor, open **Cart**: one line per interceptor, $0.00 in total.
8. **Checkout**, pay $0, and keep the receipt (Payments/Receipts).
9. Reopen the property. Its Next Pump Date should have moved, and the cart should be empty.

**The video should settle:** the whole filing through checkout; which of the two "Broward County Wastewater Treatment
Plant" rows to pick; which document to upload; one report or two at Grove (BSI lists 2 interceptors, our record has one
trap). The plan first wants the two oldest Grove visits filed in order: 1384 (Feb 12), then 1721 (Apr 27).

**BSI shows all four matched clients as overdue, with no pump on record** (days on 2026-11-04): Grove 875 and 608 (its
2 interceptors), Carrot Express 1,258, Pura Vida 132, El Turco 167.

When the video is in, correct these steps from what it shows and write the answers to the plan's 11 open questions here
(plan 8.3).

## The leads data

The schema is private. No API role can read a leads table, and signed-in staff never see the BSI links.

| Object | What it is |
|---|---|
| `leads.establishments` | One restaurant. Holds only our decision: `property_id` means it is that property of ours |
| `leads.source_records` | One outside record (431 from BSI) |
| `leads.source_versions` | What the source said, append-only. CCNs and BSI's contacts live here, privately (Fred's choice) |
| `leads.match_decisions` | Who decided what and why, insert-only |
| `public.v_frozen_leads` | Viktor: restaurants that are not ours, no contact values |
| `public.v_lead_interceptors` | Viktor, and later the bot: each interceptor, with the client when matched |
| `public.v_lead_review` | The queue, 11 rows today |

**Recording a decision** is one call to `leads.decide_client`, as postgres, never a hand UPDATE:

```sql
select leads.decide_client(<property>, 'same', '<why, quoting the person>', <staff email>, <source record>);
select leads.decide_client(<property>, 'different', '<why>', <staff email>, <source record>);   -- also undoes a same
select leads.decide_client(<property>, 'absent', '<why>', <staff email>, null, 'bsi');
```

**The 11 rows in the queue:** 135-BB, 319-CAP and 081-TCE (Yan unsure); Alta and Olympus (not asked); and 5 other
restaurants in Grove's plaza plus BENTO BOCA on Pura Vida's street, which nobody has decided. Those last 6 and THE STANDARD
do not count as frozen leads until someone records them as different.

Rules for the data, including why the loader must use `leads.ingest_quiet`: Supabase `CLAUDE.md`, section FROZEN LEADS, and
[ADR 020](../decisions/020-frozen-leads-in-prod-private-schema.md).

## Rules not to break

- **The CCN is treated as an access code:** never in a repo, Slack, memory, or a view an API role can read. Yan's video
  shows it, and shows the password if he records the login, so it does not belong in a channel.
- **No line 27 on a routed client before its match is recorded.** `bsi_routing.sql` fails if it happens.
- **Submit does not file.** Filing is Submit, then a $0 checkout.
- **Never contact a frozen lead.** The plan contacts nobody, and calling and emailing rules need a lawyer first.
- **Before any bot login,** check that a new login does not sign Yan out of BSI.
- **Only a person's answer goes in `decide_client`,** with their words in the reason. An unsure answer is not a decision.
- **A new DERM reader** that does not go through `v_derm_portal_fields` must apply the routing rule itself.

## Open decisions

**For Fred:**
- Should "Record a manual filing" (with Miami-Dade) in the DERM Tracker refuse a Boca visit? It would have to key on
  `fn_client_files_with_bsi`, because that view serves about 95% of visit pages.
- Should a GDO client's line-27 visit at a Boca Raton property be held in the bot's queue until a person clears it?
- Should the 6 neighbours in the queue be recorded as different, under his name?
- Do Yan and Diego know where the video should go, and to start it after the login?
- A message to Diego for the 4 CCNs: drafted when the video is in.

**For Yan,** if the video does not settle them (plan section 10): Pura Vida's ZIP (BSI 33432, ours 33496); which traps
the drivers pump at Grove, Carrot Express and Pura Vida; line 27 at $0 on jobs 1325, 1427 and 1624; what the bot files
first; which plant took 5943 and 5944, with Diego (Samsara and the manifest disagree); that no card is stored in BSI.

## How to check it

From `Supabase/`:

| Check | What it proves | Expect |
|---|---|---|
| `scripts/checks/bsi_routing.sql` | The routing rule, the DERM side and the logger | 18 rows, all ok |
| `scripts/checks/leads_integrity.sql` | Privacy by value in every cell, and the data's shape | 18 rows, all ok |
| `node --env-file=.env scripts/checks/bsi_routing_mutations.mjs` | Every row of the routing check can fail (each case undone) | `pass: true`, 37 cases |
| `scripts/checks/permits_gdo_only.sql` | DERM readers see GDO permits only, for when the CCNs go in | `status: ok` |

⚠ `bsi_routing.sql` pins the md5 of the logger's routing block. Changing that block on purpose means proving it and
updating the pin.

## Where everything is

| What | Where |
|---|---|
| Next steps, the design, BSI's API, the build order | [the plan](../specs/2026-11-03-boca-bsi-leads-and-filing-plan.md) |
| Why leads live in Prod, in a private schema | [ADR 020](../decisions/020-frozen-leads-in-prod-private-schema.md) |
| Columns | [`docs/schema.md`](../schema.md) |
| Scraper and loader | `scripts/leads/bsi_boca_scrape.mjs`, `scripts/leads/load_bsi.mjs` |
| Raw scrape | `backups/2026-11-03_bsi_boca_raw.json`, at the workspace root, never in a repo |
| Migrations and rollbacks | `docs/migrations/2026-11-03_*leads*`, `*route_line27*`, `2026-11-04_0042`, `2026-11-04_1338` |
| The thread with Yan's answers | [#office-team, 2026-11-04](https://unclogme.slack.com/archives/C0AMQ5M7BL6/p1793809609144129) |
