# Hand-off → Supabase 2: `visit_date` oscillates ±1 day daily (UTC-vs-ET operating-date bug)

*Prepared by the Supabase (1) session for the Supabase 2 drift/reconcile lane, 2026-07-09.
Fred routed this. Read-only investigation; no changes made.*

## Symptom (what Fred + Diego saw)

Visit times/dates on the Calendar "changed" and the activity feed attributes it to **"System"**.
Diego flagged 070-TCE + 243-FE; the real scope is larger. Two distinct things are happening:

1. **All-day fills (correct):** visits that Jobber holds with no specific hour (e.g. 070-TCE, 243-FE
   Service Calls) get `start_at`=00:00 ET / `end_at`=23:59 ET. This **matches Jobber exactly** (verified
   live via the Jobber API) — not a bug, just a full-day span mirrored from Jobber.
2. **`visit_date` OSCILLATION (the bug):** a set of visits have their `visit_date` flipped **+1 day one
   morning, −1 day the next, +1 again the day after** — indefinitely. Every flip is an `app_source='sql'`
   write ⇒ shows as "System" in the activity feed.

## Root cause (confirmed — the UTC↔ET angle Fred called out)

**A daily reconcile computes `visit_date` from the RAW UTC date, not the ET operating date.** Every
oscillating visit is an **evening-ET** visit whose `start_at` in UTC lands **just past midnight (next
calendar day)**:

| Visit | Client | `start_at` ET | `start_at` UTC | UTC date vs ET date |
|---|---|---|---|---|
| 5810 | 035-LG La Granja Downtown | Fri **20:00** | **00:00Z** | UTC = +1 day |
| 5811 | 052-PV Pura Vida DD | Fri **21:00** | **01:00Z** | UTC = +1 day |
| 5812 | 032-LG La Granja 36th | Fri **22:00** | **02:00Z** | UTC = +1 day |
| 5799 | 007-CC Cafe Club | Wed **20:30** | **00:30Z** | UTC = +1 day |
| 5013 | 197-BGT Bagatelle | Thu **20:30** | **00:30Z** | UTC = +1 day |

So one writer sets `visit_date` = the **UTC** date (+1), and the ET operating-date rule
(BEFORE trigger `trg_aa_reconcile_operating_date`, per `docs/reference/operating-date-rule.md`) sets it
back to the **ET operating date** (−1). They disagree by exactly one day and fight once per day → a
perfect daily flip-flop. This is precisely the "raw-UTC date compare, no source guard" latent lane that
Supabase 2 already flagged as a follow-up in the 2026-07-08 drift note (WORKING-NOW line for `18b031b`).

## The operation doing the writes

- Workflow **`daily-jobber-completion-reconcile.yml`** (`cron: 30 8 * * *`) →
  `scripts/sync/cron_jobber_reconcile_completion.js` — ran at **11:27 UTC on 2026-07-09** (GH Actions
  fired the 08:30-UTC cron ~3h late) and did today's writes to 070-TCE/243-FE + the chain.
- Sibling **`daily-jobber-anomaly-reconcile.yml`** (`cron: 15 9 * * *`) →
  `scripts/sync/cron_jobber_reconcile_anomalies.js` — the one flagged for raw-UTC date compares.
- Both write via Node/service-role with **no `X-App-Source`**, so every write lands as `app_source='sql'`
  ⇒ the Calendar shows the opaque **"System."**

Please confirm which of the two owns the explicit `visit_date` write; the fix applies to whichever
computes the date. (The other daily reconcile and/or the operating-date trigger is the −1 counter-writer.)

## Full impact — 18 visits with ≥2 `visit_date` flips (by System/sql) in 10 days

Worst offenders flip **every day** (8 flips each, 07-02→07-09), all evening-ET / just-past-midnight-UTC:

| Visit | Client | ET start | UTC start | flips |
|---|---|---|---|---|
| 5013 | 197-BGT Bagatelle | Thu 20:30 | 00:30Z | **8** (06-04↔06-03 daily) |
| 5799 | 007-CC Cafe Club | Wed 20:30 | 00:30Z | **8** (06-17↔06-16) |
| 5810 | 035-LG La Granja Downtown | Fri 20:00 | 00:00Z | **8** (06-19↔06-18) |
| 5811 | 052-PV Pura Vida DD | Fri 21:00 | 01:00Z | **8** (06-19↔06-18) |
| 5812 | 032-LG La Granja 36th | Fri 22:00 | 02:00Z | **8** (06-19↔06-18) |
| 6005 | 034-LG La Granja Calle 8 | Sun 16:30 | 20:30Z | 4 (07-01↔07-02) |
| 5654 | 170-PV Pura Vida Bakery | Sat 20:00 | 00:00Z | 3 |
| 5990 | 031-KRU Krudo Fish Market | Wed 06:30 | 10:30Z | 3 |
| 6497 | 214-MYK Myka Brickell | Fri 14:30 | 18:30Z | 3 |
| 6592 | 027-HER Herzka Residence | Thu 04:15 | 08:15Z | 3 |
| 6835 | 168-AVA AVA | Wed 05:30 | 09:30Z | 3 |
| 6860 | 239-COM Courtyard Marriott SOBE | Tue 14:45 | 18:45Z | 3 |
| 6981 | 093-KC KC Market | Thu 00:00 | 04:00Z | 3 |
| 6982 | 245-MAYU MAYU | Thu 03:00 | 07:00Z | 3 |
| 6983 | 242-WYN Wynd 28 | Thu 01:30 | 05:30Z | 3 |
| 5846 | 081-TCE Carrot Express W Boca | Sun 08:15 | 12:15Z | 2 |
| 6817 | 127-PC Puya Cantina | Mon 09:15 | 13:15Z | 2 |
| 6955 | 168-AVA AVA | Thu 00:45 | 04:45Z | 2 |

*(Note: the top 5 are pure evening→+1-UTC-day cases — the clean TZ bug. A few others (034-LG 16:30,
239-COM 14:45, 214-MYK 14:30) are afternoon-ET where UTC=same day, so those flips have a SECOND cause —
likely dispatch re-timing in Jobber or the reconcile's date-window math. Worth a second look, but the
evening TZ bug is the dominant, reproducible pattern.)*

Raw data: scratchpad `osc2.json` / `full_recon.json` (this session).

## Divergence proof (2026-07-09) — it's NOT cosmetic; `start_at` drifts off Jobber by a day

Fleet check of all **18 visits System (`sql`) wrote in the last 3 days**, DB `start_at`/`end_at` vs the
live Jobber API: **13 match Jobber exactly; 5 DIVERGE — currently a full day AHEAD of Jobber.** The 5 are
exactly the evening oscillators:

| Visit | Client | DB start_at (wrong) | Jobber start_at (truth) |
|---|---|---|---|
| 5810 | 035-LG | 2026-06-20 00:00Z | 2026-06-19 00:00Z |
| 5811 | 052-PV | 2026-06-20 01:00Z | 2026-06-19 01:00Z |
| 5812 | 032-LG | 2026-06-20 02:00Z | 2026-06-19 02:00Z |
| 5799 | 007-CC | 2026-06-18 00:30Z | 2026-06-17 00:30Z |
| 5013 | 197-BGT | 2026-06-05 00:30Z | 2026-06-04 00:30Z |

So the oscillation actively **corrupts the real `start_at` instant** (not just the `visit_date` label):
on "+1" days these visits sit a full day ahead of Jobber; on "−1" days they match. The counter-writer is
the ET operating-date trigger (`trg_aa_reconcile_operating_date`: "pure date-drag → move start_at's day,
keep the ET wall-clock") dragging `start_at` with the flipped `visit_date`. Meanwhile the 13 non-evening
visits (incl. 235-LOU/070-TCE/243-FE) mirror Jobber correctly — the bug is specific to the evening/
just-past-midnight-UTC cohort. Raw data: scratchpad `diverge.json`.

## Requested fix (Supabase 2's lane)

1. **Derive `visit_date` via the shared ET operating-date helper, never a raw UTC date slice.** Both
   reconcile scripts must use the same `operatingDateET(start_at)` derivation as
   `webhook-jobber.operatingDateET` / `sync-jobber-visit-drift.adoptTarget` / the DB trigger
   `trg_aa_reconcile_operating_date` (spec: `docs/reference/operating-date-rule.md`,
   `OVERNIGHT_CUTOFF = 06:00 ET`). Evening ET visits → the ET calendar day, not the UTC +1.
2. **Add the source-guard you already flagged** so a reconcile doesn't clobber a `visit_date` the ET
   operating-date rule just set (stop the two-writer fight).
3. **Backfill the 18 oscillators** to their correct ET operating date once (they'll stop flipping after
   #1+#2). The top 5 evening visits should sit on the ET date (e.g. 035-LG → 06-18, not 06-19).

## Secondary finding — the reconcile makes 2 passes (placeholder → real), doubling "System" noise

Example 235-LOU (visit 7052, a completed Service Call that came back from Jobber with NO start/end):
- **07-08 pass**: set an all-day **placeholder** (00:00 → 23:59 ET) — did NOT read Jobber's real time.
- **07-09 pass**: overwrote it with Jobber's actual `endAt` (12:59 AM ET) → now matches Jobber.

Result: **two "System" activity entries** and a confusing intermediate (11:59 PM) that was never real. The
reconcile should read Jobber's real `startAt`/`endAt` on the **first** pass and skip the all-day
placeholder entirely — one correct edit, one activity line. (Note: 235-LOU's Jobber time itself is a
midnight 12:00–12:59 AM slot even though it was completed 1:25 PM — a **Jobber data-entry** issue on that
Service Call, not ours; flag to Diego separately.)

## Attribution improvement (small, helps everyone)

Have the reconcile scripts set an explicit **`X-App-Source`** header/GUC (mechanism exists — ADR 016),
e.g. `jobber-daily-completion-reconcile` / `jobber-daily-anomaly-reconcile`, so the Calendar activity
feed shows the actual cron name instead of the opaque **"System."** This alone would have made this
whole investigation a 10-second read for Fred.
