# GDO online reports: the sheet hold reversed, and the mixed-route sweep (2026-10-18)

Fred, 2026-10-18 evening: "go ahead, and yes sweep the mixed routes", and on the bot's open question #4:
"Yes they still owe the DERM GDO report." Then: "document what you have done".

## 1. What went wrong first

On 2026-10-18 (`2026-10-18_0220`) I said 3 GDO reports for visits picked up in Miami-Dade and dumped in Broward
(6218 / 082-TFC, 8089 / 236-LOU, 6721 / 110-CLA) went to the county "without their manifest sheet", and I built a
hold: a report with no sheet on file was not served to the bot (`no_sheet`), and the health email reported it.

That was wrong. Fred asked "did you read the docs of the bot?". I had read only `reporter.py`. Reading the bot's
docs (`webunclogmecom/unclogme-gdo-report-bot`: README, docs/API_CONTRACT, DOMAIN_RULES, OPEN_QUESTIONS, RUNBOOK) and
its code (`reporter.py`, `api_client.py`) settled it:

- The county GDO online report form takes the permit, the hauler (1133 - UNCLOGME LLC), the date pumped and a
  certification checkbox. It has no attachment field.
- The bot never downloads `documents.address` or `documents.receipt`; nothing in its code or docs uploads a file.
- The belief came from OUR side: section 9 of the API contract (written by us in July) says the queue signs the raw
  sheet "because county submission needs the real document", marked "pending confirmation". It was never confirmed.

So the 3 filings were complete and DERM accepted them. The only defect was my hold, which could only delay a filing.

## 2. What changed

| | |
|---|---|
| Migration | `docs/migrations/2026-10-18_2100_gdo_filing_no_sheet_hold_removed.sql` (applied 2026-10-18 ~21:00 ET) |
| Rollback | `docs/migrations/2026-10-18_rollback_gdo_filing_no_sheet_hold_removed.sql` (the `_0220` bodies, dumped live before applying) |
| Objects | `v_derm_portal_queue` (no `has_sheet` gate), `v_derm_portal_queue_held` (no `no_sheet` arm), `v_rpa_derm_health` (`held_no_sheet` NULL), `log_rpa_derm_health` (pre-10-18 body). Bodies copied verbatim from the rehearsed `_0220` rollback. `v_derm_portal_fields` keeps the now-unused `visit_sheet_urls` / `has_sheet` columns |
| Edge fn | `rpa-derm-queue` v31: `documents` is `{address: [], receipt: []}`; the signing code is removed. The key stays so the response shape does not change; the Postman check (`documents` has `address`) still passes |
| Commits | Supabase `fd28840` (migration + function), `3d5a4a6` (CLAUDE.md, decisions register, Postman README + collection) |

Proof:

- Rehearsed in a rolled-back transaction (forward, then rollback back to the live md5) before applying.
- VERIFY in the migration: the bodies equal the pre-10-18 md5s; the queue lost no row and gained only rows that had
  been held `no_sheet` (none existed); every other hold reason unchanged; grants unchanged.
- After applying: held reasons identical (already_filed 37, before_launch_cutoff 51, cooldown_20h 2, data_error 1),
  queue 0.
- Deployed body checked (`scripts/probes/edge_deployed_body.js`): version 31 carries the empty `documents`, no
  `no_sheet`. A live dry-run fetch returned 25 reports, every one with empty documents.
- Side benefit: signed URLs of multi-client address sheets (other clients' rows) no longer leave the database.

## 3. The rule Fred settled

A pickup made in Miami-Dade owes its DERM GDO online report wherever the load was dumped (Broward included). This was
the bot's `docs/OPEN_QUESTIONS.md` #4, asked 2026-08-29.

The queue has never filtered on the dump county (it serves every Line Item 27 visit linked to a manifest), so the rule
was already enforced and needed no change.

## 4. The sweep (read-only, 2026-10-18)

Every GDO-reporting visit (`fn_visit_is_gdo_reporting`) linked to a manifest whose disposal facility is not in
Miami-Dade:

| visit | date | client | permit | ticket | state |
|---|---|---|---|---|---|
| 6616 | 2026-07-08 | 043-MIL | GDO-14117 | 306915 | before launch (2026-07-21), no filing recorded |
| 6616 | 2026-07-08 | 043-MIL | GDO-11024 | 306915 | before launch, no filing recorded |
| 6298 | 2026-07-22 | 111-YC | GDO-13263 | 309944 | filed |
| 6036 | 2026-07-28 | 041-MB | GDO-14965 | 310429 | filed |
| 6568 | 2026-08-24 | 009-CN | GDO-16389 | 312433 | filed |
| 6568 | 2026-08-24 | 009-CN | GDO-10877 | 312433 | filed |
| 6568 | 2026-08-24 | 009-CN | GDO-15062 | 312433 | filed |
| 8095 | 2026-09-23 | 246-LOUI | GDO-12656 | 9-24-26 | NOT filed: county login refused |
| 6218 | 2026-10-06 | 082-TFC | GDO-09853 | 315241 | filed |
| 6721 | 2026-10-13 | 110-CLA | GDO-12517 | 315808 | filed |
| 8089 | 2026-10-14 | 236-LOU | GDO-11696 | 315808 | filed |

Since launch: 9 owed, 8 filed. Open items:

- **8095 / 246-LOUI.** Four attempts (09-25 to 10-01) stopped on `ERROR_EMAIL_MISMATCH` (the county portal had the
  client's own email on permit 12656, not ours), then two (10-06, 10-14) on `ERROR_LOGIN_FAILED` ("Either the
  Password or GDO Permit # is incorrect"). Held as `data_error`. Needs the permit's correct county password; then
  `public.fn_requeue_derm_portal(8095, <gdo_id 217>, reason, by)` re-opens it. Not a Broward problem. Its manifest
  number "9-24-26" is also malformed (the bot's DOMAIN_RULES note it).
- **6616 / 043-MIL (2 permits), 2026-07-08.** Before the bot's launch cutoff. All 51 pre-launch GDO visits have no
  filing in our records, so whether they were filed by hand before the bot cannot be told from our data.

Not owed by us: the four Miami-Dade pickups on Broward manifest 306859 named in the bot's open question
(226-JER Jerusalem Pizza, 034-LG La Granja Calle 8, 056-STM Sarah's Tent Market, 182-PAL The Palm) are not
GDO-reporting clients (no Line Item 27), so no online report is filed for them wherever they dump.

## 5. Not done

- The bot repo's `OPEN_QUESTIONS.md` #4 and `API_CONTRACT.md` section 9 still read as open / "needs the real
  document". That repo is Jonathan's; Fred said not to send corrections ("No need").
- The `_0220` migration header is left as written (it is the record of what was believed then); this file and
  `_2100` correct it.

## 6. Lesson

Before building on what a bot, portal or vendor "needs", read its own docs and code, not our side's description of
it. A note in our own contract marked "pending confirmation" is a question, not a fact.
