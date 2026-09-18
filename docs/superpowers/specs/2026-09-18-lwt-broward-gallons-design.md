# LWT monthly report: gallons on Broward-disposed tickets (design, under review)

**Status:** DRAFT, verified against code, docs, data and the consumer on 2026-09-18 (see section 9). Not built.
**Owner:** @Supabase 2. **Consumer:** Jonathan's LWT generator (`webunclogmecom/unclogme-gdo-report-bot`).
**Deadline named by Jonathan:** the report due 2026-09-20.

## 1. The ask

Slack `#C0B15CHQ1D4`, 2026-09-18. Jonathan is flipping the 2026-08-20 rule ("the county where the load is
disposed decides"), which is why Broward dumps drop off the Dade report today. Answers in the thread:

- Gallons: Yan, *"yes for the miami dade pick up and Broward dump we need the gallons per client to add
  then to the report"*. Jonathan: *"the flattener already reads gallons off each row if you send it.
  Today those rows return null (by design, for Dade tickets that use the decal). For Broward dumps where
  there's no invoice line, can you include the actual gallons per client on those rows in the feed?"*
- Fee: Yan, Broward-disposed gallons pay the $0.00419/gal Dade fee.
- Destination: print the real facility per row. Yan: *"It's correct"*.
- Period ("which period do they belong to, the month of the dump date?"): **nobody answered.**

Fred to Claude: *"help designing a plan on how to put a data on that `gallons`; we can use the Grease Trap
Size from our DB to fill it."*

## 2. What exists today

**Our side.** `derm.v_lwt_monthly_rows` (21 columns, column 18 `gallons integer` = `NULL::integer`)
already serves Dade pickups on Broward tickets as in-scope rows (`in_scope = pickup_in_dade OR
offload_in_dade`, `offload_in_dade = white_manifest_number IS NOT NULL`). The view already LEFT JOINs the
visit's property (`p.id = v.property_id`). `rpa-derm-monthly` reads it with `.select('*')`
(index.ts:189), maps row fields by name and hardcodes `gallons: null` (index.ts:373); the ETag hashes the
whole body minus `generated_at` (index.ts:423-425). Only `derm.v_lwt_ticket_reported` depends on the view
(it reads `ticket_number` only); no function body names the view; `relacl` = postgres + service_role
SELECT; `pgrst_ddl_watch` reloads PostgREST after a `CREATE OR REPLACE`. No column anywhere holds a
measured volume per load (`derm.manifests.gallons` is a `NULL::numeric` placeholder; Jobber pulls carry no
gallons custom field; Moises's LM11 tank sensor is not ingested).

**Jonathan's side, read from his repo (fetched read-only 2026-09-18, `main`, last commit
2026-09-17).** This is what makes the first plan wrong:

| behaviour | where |
|---|---|
| A ticket with `offload_in_dade: false` is dropped whole (`return None`) | `monthly_fetch.py:_flatten_ticket`, ~199-240 |
| Row gallons are collected as a SET of distinct non-null values; exactly one member is used, two or more is a conflict and the ticket's gallons become None; null rows are silently ignored | `monthly_fetch.py:298-307` |
| When gallons is None and the ticket has one decal, gallons = the Miami-Dade decal constant (`C1184 -> 3800`, `C0976 -> 2000`) | `monthly_report.py:611-620`, `reconcile.py:422-433` |
| Any ticket with gallons still None makes `gallons_complete` false and `build_xlsx` refuses the WHOLE report | `monthly_report.py:410-413, 1108-1124` |
| A null row decal (Cloggy) or two trucks on a ticket refuses the ticket's gallons | `monthly_fetch.py:275-297` |
| The bot calls only `month=` or `unreported=1`, never `include=all`; it reads `pickup_in_dade` per row | `api_client.py:158-178` |
| The form is one block per ticket with ONE gallons cell (rowspan over the ticket's facilities) | `monthly_report.py:360-367, 845-857` |
| His tests pin "gallons stay null" | `test_monthly_fetch.py:4, 79, 199-206` |

Consequence: per-client values sent as-is are mishandled by the code as it stands. Simulated over Jun-Sep
2026 in-scope rows: 0 of 12 Broward tickets would be accepted, 10 would conflict (then fall back to a Dade
decal constant of 3,800 or 2,000 gal on a Broward load), 1 would silently use one value while two null
rows vanish (310429), 1 has no value at all. **The contract has to be agreed with Jonathan, not just the
field.**

## 3. What we have, measured 2026-09-18 (dated observation, moves with every Client App edit)

Target = in-scope rows (Dade pickups) on tickets with `offload_in_dade = false`. Source rule = visit's
property `grease_trap_size_gallons`, else the client's Pumping `service_configs.equipment_size_gallons`.

| month | Broward tickets (default GET) | in-scope rows | with a value | still null |
|---|---|---|---|---|
| 2026-06 | 1 | 4 | 2 | 2 |
| 2026-07 | 5 (7 with include=all) | 26 | 20 | 6 |
| 2026-08 | 5 (7) | 31 | 24 (22 property + 2 fallback) | 7 |
| 2026-09 | 0 (2) | 0 | | |

August per ticket: **310607 complete** (4 rows, 1,675 gal). 311780 lacks 4 of 10 (014-JOY, 249-LOU,
293-ALC, 306-16); 312024 lacks 226-JER (3 rows); 312433 lacks 309-KEB (8 rows); 310590 lacks 186-PV
(6 rows) **and** its 189-FRE row is on Cloggy, which holds no decal (Jonathan refuses a ticket on a null
decal; Diego question open since 2026-08-26). The seven properties with no size anywhere: 186-PV (property
113), 306-16 (974), 293-ALC (978), 249-LOU (973), 014-JOY (111), 226-JER (651), 309-KEB (1084). The two
fallback rows: 192-FRK 25 gal, 233-AH 2,000 gal.

Provenance: both arms are trap CAPACITY of the same Airtable origin (117 property values were seeded from
`service_configs` on 2026-08-13; 32 of the 41 in-scope Jun-Aug property values are that untouched
backfill, 9 were edited since by staff or the Jobber sync). The label distinguishes maintained from
frozen, not measured from legacy. `service_configs.equipment_size_gallons` has no live writer.

Jonathan's Dade quantities are NOT plant measurements either: they are the decal constants above, written
"approximately 3800 gallons" on every Moises receipt; July filed as exactly 7 x 3,800 + 8 x 2,000 = 42,600
gal / $178.49. The docs' "MEASURED gallons per manifest" wording is a mischaracterisation carried from
2026-08-25 and gets corrected in section 7.

Oddities to name, not hide: 189-FRE 250 gal on Cloggy (126 gal truck, in scope on 310590); 010-CS 4,000
gal on Moises (3,840, out of scope); 215-G7 = 4 gal (typed in the Client App 2026-09-07, legacy 60, unit
unverified, out of scope but served on 312024 under include=all); 061-TCE = 10 gal in scope on 312433.
Both columns hold zero 0-values today, but `client.update_property_capacity` accepts 0 and the estate
defines 0 as Jobber's empty.

## 4. Design (corrected)

**View** `derm.v_lwt_monthly_rows`, `CREATE OR REPLACE` only, never DROP (a drop cascades to
`derm.v_lwt_ticket_reported` and discards both views' grants: every month, Dade included, would answer 500):

```sql
-- column 18, same name, same type (integer): the ::integer cast is mandatory, an uncast
-- COALESCE(integer, numeric) is numeric and CREATE OR REPLACE refuses it with 42P16 (probed)
CASE WHEN m.white_manifest_number IS NULL
     THEN COALESCE(NULLIF(p.grease_trap_size_gallons, 0), scf.sc_size)
END                                                        AS gallons,
...
-- column 22, appended LAST
CASE WHEN m.white_manifest_number IS NOT NULL THEN NULL
     WHEN NULLIF(p.grease_trap_size_gallons, 0) IS NOT NULL THEN 'grease_trap_size'
     WHEN scf.sc_size IS NOT NULL THEN 'service_config_size'
END                                                        AS gallons_source
-- the fallback is a scalar LATERAL pinned to the Pumping config; a plain LEFT JOIN service_configs
-- ON client_id fans the view out 784 -> 1119 rows today (63 clients hold unsized Cleaning /
-- Warranty rows beside their Pumping row)
LEFT JOIN LATERAL (
  SELECT sc.equipment_size_gallons::integer AS sc_size
  FROM public.service_configs sc
  WHERE sc.client_id = m.client_id AND sc.service_type = 'Pumping'
    AND sc.equipment_size_gallons > 0
  ORDER BY sc.id LIMIT 1) scf ON true
```

Invariants: `gallons IS NULL <=> gallons_source IS NULL`; `gallons > 0` always; `gallons` null on every
row of a Dade-offload ticket; row count unchanged (784 today); the 20 other columns byte-identical.
Rollback is a second `CREATE OR REPLACE` with `NULL::integer AS gallons, NULL::text AS gallons_source`
(the column cannot be removed without a drop); the migration header states this.

**Function** `rpa-derm-monthly`: `gallons: r.gallons ?? null` (integer arrives as a JSON number) and
`gallons_source: r.gallons_source ?? null` on every row; ship the view first so the key is never emitted
before the view serves it. Additionally, on the TICKET head, a ready-made answer to the grain question so
the null rule lives in one place:

```jsonc
"dade_pickup_gallons": {            // present on every ticket; null fields on Dade-offload tickets
  "total": 1675,                    // sum of gallons over rows with pickup_in_dade = true
  "rows": 4, "rows_missing": 0,     // in-scope rows, and how many of them have gallons null
  "complete": true                  // rows_missing = 0; false means DO NOT FILE this ticket
}
```

Nothing else in the payload moves. `include=all` out-of-scope rows on Broward tickets also carry a value
(107 rows today); the bot never requests that mode, and what goes on the form is decided by `in_scope`
and `pickup_in_dade`, never by the presence of gallons.

**Consumer changes Jonathan must make** (his generator, before he flips the rule):
1. `_flatten_ticket`: stop returning None on `offload_in_dade: false`; keep the finding as informational.
2. For those tickets, gallons = the SUM of row gallons over `pickup_in_dade = true` rows (or read
   `dade_pickup_gallons.total`), never the single-distinct-value rule.
3. A null in-scope row (`dade_pickup_gallons.complete = false`) leaves the ticket unresolved. **Never fall
   back to the Miami-Dade decal constant on a Broward-disposed ticket**: 3,800 or 2,000 is a Dade load
   convention and has nothing to do with a Broward dump.
4. Decal handling on Broward tickets is his call: the row decals are Miami-Dade permits; the Broward EPD
   decal (07058 David, 07675 Moises) is not served today.
5. The fee stays in his generator (Yan: Broward gallons pay it).

## 5. Decisions still open (block the build)

1. **Grain, with Jonathan:** option A, per-row values + he sums per ticket (this design, plus the
   ticket-head total as a convenience); option B, we serve the ticket sum repeated on every row so his
   set-of-one rule works. B still needs his flip and the removal of the decal fallback, so A is the
   honest contract. Confirm he will change `_flatten_ticket` before the 20th.
2. **Period:** `month=2026-08` selects by offload date (5 Broward tickets, 4 with a null row); an
   invoice-style 07/26-08/25 window would carry 310429 and drop 312433; his own pending list is 12 Broward
   tickets back to June (`unreported=1`), of which this design resolves 2 today (309944, 310607). Someone
   answers his question.
3. **For Yan:** the number is trap capacity, not a measured volume, and the Dade-side quantity of a
   Broward ticket is the SUM of the Dade-pickup trap sizes (August: 1,675 / 2,355 / 3,540 / 1,150 /
   3,840), which is at or below the 3,800 or 2,000 a Dade manifest carries under the current convention.
   Nobody has told him it is a capacity.
4. **Who types the 7 sizes** (section 3) into the Client App property before the 20th. Without them 4 of
   the 5 August tickets stay unresolved and block his whole August xlsx. No redeploy is needed once the
   view and function have shipped (the view reads the column live; the two-way sync carries it to Jobber).
5. **310590 / Cloggy:** null decal, and 189-FRE at 250 gal on a 126 gal truck. Hold the ticket, fix the
   truck assignment, or decide the decal.
6. Should the Broward FDEP sheet (DERM Tracker, Trap 1 from `properties` only) adopt the same
   `service_configs` fallback so the two regulator artifacts agree on 233-AH?
7. The 2026-08-26_1842 view COMMENT check requires the phrase "MEASURED gallons per manifest"; retire it
   (a dated check in a dated migration) or keep the phrase.
8. A receipt-volume column on `derm_manifests` (the Broward receipt prints "Waste Volume 1700 gals")
   would reverse Fred's 2026-05-22 "don't re-add the Gallons column" decision on the DERM Tracker
   (`Building Apps/DERM Tracker/docs/08-changelog.md:5260-5268`). Not proposed; recorded so nobody
   re-derives it.
9. Jonathan's `docs/OPEN_QUESTIONS.md` #2 (`unreported=1` returns Broward manifests) and #4 (does a Dade
   pickup disposed in Broward still owe its GDO report?) are addressed to Fred and Yan since 2026-08-29
   and unanswered.

## 6. Verification (rewritten)

a. One rolled-back body via the Management API (it returns only the LAST row-returning statement, so
   every check is one final SELECT or a DO that RAISEs): `CREATE TEMP TABLE old AS SELECT * FROM the
   view`; the C-O-R; then assert: EXCEPT ALL both directions over the 20 columns other than `gallons`
   (list generated from `pg_attribute`) = 0, with a positive control that perturbs one column and shows a
   non-zero count; row count unchanged; `count(gallons)` equals the count computed by mirroring the rule in
   the same statement (never a literal; today 153 view-wide, 24 in-scope August); 0 non-null on
   `offload_in_dade = true` with the anchor that 444 such rows carry a property size; `gallons IS NULL <=>
   gallons_source IS NULL`; `min(gallons) > 0`; `count(gallons_source = 'service_config_size') >= 1` (7
   today) so the fallback arm is proven to fire; a listing of rows <= 25 gal for a human look. ROLLBACK,
   then prove the view is byte-identical to before.
b. Apply; deploy; read the deployed body and version (`scripts/probes/edge_deployed_body.js`).
c. Live GETs asserting from the payload: `?month=2026-08` -> 5 Broward tickets, non-null only on their
   rows, `dade_pickup_gallons.complete` true on 310607 only, 0 on the 11 white tickets;
   `&include=all` -> 7 Broward tickets; `?month=2026-09` -> key present, null everywhere;
   `?unreported=1` -> non-null only on Broward rows across June to August. A repeat conditional GET
   returns 304 (every month's ETag flips on deploy because `gallons_source` is a new key; the ETag proves
   the deploy landed, not the data, and it now moves with every trap-size edit).
d. Postman: rewrite the two "gallons is always null" tests as invariants (white ticket => null; null <=>
   source null; Broward non-null => integer > 0 with source in the two labels); put the positive control
   in a request pinned to `?month=2026-08` (`>= 1`, never `== N`; the count moves by design); make the
   `reportMonth` tests skip loudly when a month has no Broward rows; fix `CAP` Moises 9000 -> 3840 (the
   suite is red on that today). Run `node scripts/checks/api-doc-drift.js` (goes red until README 4c names
   `gallons_source` and `dade_pickup_gallons`).

## 7. Documentation (complete list; grep the meaning, this claim escaped a sweep once already)

Living contracts to rewrite with Yan's dated decision: `postman/README.md` 4c (:425, :509-512, :535-537
add "truck" before "capacity", :566-568 "still with Yan"); `Supabase/CLAUDE.md:3456-3467`;
`docs/schema.md:669-675`; the live view COMMENT (the only catalogue copy); `rpa-derm-monthly/index.ts`
:371-373 and :357-358; the Postman collection's START HERE request description (:692), test comment
(:937) and the two tests (:723, :1349-1350); a dated block prepended to
`docs/specs/2026-08-24-lwt-monthly-endpoint-design.md` (never rewrite :191/:274/:379 in place);
`Building Apps/Client App/docs/08-changelog.md` + CLAUDE.md: Grease Trap Size now feeds a regulator
filing; a dated addendum to memory `feedback_a_retraction_does_not_propagate` ("gallons stays null was
right" loads as belief). Leave as dated records: the three migration headers, both 2026-08 audits,
`Building Apps/DERM Tracker/docs/broward-address-audit.md`, `WORKING-NOW.md:14054`.

## 8. Process

Claim in `WORKING-NOW.md` and commit in the same breath; migration `2026-09-18_HHMM_lwt_broward_gallons.sql`
(ET); stage explicit paths; Supabase co-author footer; Client App changelog line with a one-line
no-footer commit; reply to Jonathan drafted by me, posted by Fred.

## 9. How this was verified

Four independent readers (code, docs, data, the ask), eight adversarial refuters (one per plan point plus
the conclusion), one completeness critic; 13 agents, 417 tool calls, every SQL read-only, the C-O-R probed
inside a rolled-back savepoint on the live view. The critic fetched the consumer's repository, which
nobody had read; section 2's second table is from that read and was re-read by the author.
