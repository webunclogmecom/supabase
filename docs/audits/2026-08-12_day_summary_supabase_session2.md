# 2026-08-12 — day summary, Supabase session 2

Fred: *"also document all you did today."*

Everything below is this session's work. **The Supabase repo had 19 commits today and only 6 are
mine**; the other 13 are session 1's `create-client` build. Mine: `99e035d`, `ffa227e`, `5426948`,
`b069e85`, `a664402`, `e6c59a9`.

⚠ **"Today" spans two dates.** The session ran past midnight ET. True application times, read off
`audit.logs` rather than from filenames:

| work | applied (ET) | filename says |
|---|---|---|
| property 1017 removed | 2026-08-12 **12:20** | `_1225` |
| GDO frequency backfill | 2026-08-12 **13:12** | `_1330` |
| 3 job statuses re-synced | 2026-08-12 **14:00** | `_1420` |
| 49 job properties linked | 2026-08-12 **15:49** | `_1550` |
| 6 client codes | **2026-08-13 02:24** | `2026-08-12_1615` ← **wrong by a day** |

The first four are within ~20 minutes of their names, which is normal (the name is written before
the migration is applied). The client-code one is off by a day and is corrected in its own header;
the file was not renamed because it is already pushed and referenced elsewhere.

Two of today's actions were **writes to Jobber**, which leave no migration file and which our poll
records as `app_source='jobber'` with a NULL actor. **This document is the only record of who did
them and why.**

---

## 1. The property sweep was re-flagging every row it restaged (`99e035d`)

`upsertRaw` in `sync-jobber-poll` deleted and re-inserted every pulled row with
`needs_populate = TRUE` unconditionally. So all ~470 properties were re-queued every hour while the
replay drained only ~120/hour: a backlog that could never converge, and **43 Jobber properties had
never been populated in 8 days.**

It looked healthy from every angle. The replay reported `ok:10 fail:0` every cycle and pg_cron
reported `succeeded`, because each cycle really did do its 10.

Fixed so a row is left FALSE only when it is byte-identical **and** already populated:

```sql
settled AS (SELECT i.d->>'id' AS gid FROM incoming i
   JOIN raw.<table> r ON r.data->>'id' = i.d->>'id'
    AND r.data = i.d AND r.needs_populate = FALSE)
```

Also added `ORDER BY id` to the replay SELECT, which had no ordering at all.

**Measured drain today:** backlog 350 (13:00) → 107 (15:19) → **53** (15:50); unlinked Jobber
properties 43 → **17**.

## 2. Property 1017 removed, property 200 refused (migration `2026-08-12_1225`)

170-PV held three property rows for a client with one Jobber property. Removed the third (unlinked,
zero references across all nine FKs, audited so recoverable).

**Refused the second removal Fred asked for.** 045-NU / property 200 / *266 Miracle Mile* is absent
from Jobber, so by the letter of the instruction it would go, but it carries a **live job** (1536,
`action_required`), a GDO, a client_location and two `entity_source_links`. `jobs.property_id` is
`ON DELETE NO ACTION`, so the delete would simply raise. It is a location with history that Jobber
no longer returns, which needs a decision rather than a delete.

⚠ **The duplicate test had to be corrected mid-task, by Fred.** My first pass matched on address
alone. Fred: *"242-WYN have multiple ones because it has multiple locations like: Pari Pari, Nino
Gordo, CU4 ... so check that also."* Re-tested on **name AND address**: across all 430 service
properties exactly **one** genuine duplicate group exists fleet-wide, and it was 170-PV's.

## 3. GDO permits: PDF audit and frequency backfill (`ffa227e`, migration `2026-08-12_1330`)

Read **130 of 136** ACTIVE permit PDFs live from Miami-Dade DERM
(`api-ecmrer.miamidade.gov/derm/documents`), parsed with the GDO bot's own parser so the audit and
the bot cannot disagree about what a PDF says.

- **13** permits had no `max_frequency_days` and the PDF stated one → filled.
- **1** correction: 172-NU GDO-07733 stored 30 days, the PDF says **60**. We were over-servicing,
  so no compliance exposure, but the stored number was wrong.
- **0** expiration disagreements: all 130 readable PDFs already matched `permit_expiration`.

Safe because, as Fred confirmed, *"a GDO doesn't change their number when renewal, it's just when the
address of a place changes."* Verified against DERM: one case number accumulates one document per
renewal year (GDO-06762 has 25), and the query sorts `date_desc` and reads document [0].

### 🛑 A correction to that migration's own header, found while writing this summary

The header says *"17 ACTIVE permits are genuinely expired (oldest 2018-12-31)"*. **The real number
is 22.** Re-measured today:

```
ACTIVE + expired, total        22
  of which have a frequency    17   <- what the header counted
  of which have NO frequency    5   <- the 5 unreadable PDFs, silently excluded
expired before 2024            10
```

**The 5 excluded are precisely the 5 oldest**: GDO-05104 (2007-01-14), GDO-01861 (2009), GDO-01179
(2011), GDO-11308 (2018), PSO-00025 (2019). So the subset that dropped out of the count was not a
random 5, it was **the worst cases**, and the headline number under-reported the compliance gap by
23%. Same shape as the other instrument failures below: the exclusion was invisible because the
number it produced looked plausible.

⚠ **Status was deliberately NOT touched.** Flipping 22 permits to INACTIVE would hide a compliance
gap behind a tidy table. That is a business decision and it is **still open**.

## 4. Three job statuses re-synced from Jobber (`5426948`, migration `2026-08-12_1420`)

Fred: *"I found a client recently which showed closed job in our db but it was opened in jobber."*
Compared all 1,797 Jobber jobs against our 1,804: **3 drifted, all one direction** (ours archived,
Jobber open), 0 the other way. Jobber owns job lifecycle, so Jobber won on all three.

**Why they drifted, which the row fix does not address:** `sync-jobber-job-drift` excludes
`archived/closed/destroyed` on our side and adds a 14-day arm for recently-terminal jobs. A job
archived here more than 14 days ago and reopened in Jobber falls outside **both** arms and can never
reconcile. Not widened: Fred settled on 2026-08-03 that the reconciler ignores archived jobs on
purpose, and 3 rows a quarter is cheaper to fix by hand than to reopen that cost trade.

## 5. The "duplicate Service Call jobs", which were mostly not duplicates (`b069e85`)

Full write-up: [`2026-08-12_sc_job_duplicate_review_and_close.md`](2026-08-12_sc_job_duplicate_review_and_close.md).

Seven open SC jobs across three clients looked like duplicates. I refused the DB-side delete, Fred
then said *"close the duplicate SC jobs in jobber"*, and I put the conclusion through an adversarial
review before writing. **Only one was a real duplicate.**

**Closed in Jobber: `#99901049`** (112-YA), same client/property/title as the live `#99900535`, 0
visits so `DESTROY_ALL` was inert, `jobReopen` available. Control re-read after the mutation:
`#99900535` unchanged at `upcoming` with 7 visits. Our DB picked it up 12 minutes later.

**✅ Fred then settled the rest:** *"a job goes per property."* The other six sit at six different
service addresses and are correct. Nothing else closed.

Two details raised, not acted on: **job 1280 carries two paid invoices for the same amount**
(#2602 and #2680, $361.32 each) against one completed visit; and 1791 ($413.08) and 1836 ($549.13,
**past due**) still have money outstanding.

## 6. 49 open jobs linked to their Jobber property (`a664402`, migration `2026-08-12_1550`)

**This is the finding of the day, because it is what manufactured item 5.** Read from our database,
275-MLP's three open SC jobs all showed property = *(none)*, the exact signature of a duplicate.

```
open jobs missing property_id ....  50 / 451  (11%)
  open Service Call ..............  41 / 271  (15%)
  open Service Agreement .........   6 / 176  (3%)   <- control
by month created:  Apr 0/25 (0%)  Jun 20/382 (5%)  Jul 27/38 (71%)  Aug 3/5 (60%)
```

⚠ **My first diagnosis was wrong and the data refuted it.** I blamed item 1's sweep bug. All 50
carry a property in Jobber and **49 already had it linked here**. The mechanism is ordering:
`webhook-jobber:1105` is `if (propertyId) jobRow.property_id = propertyId`, so a job populated
before its property exists is **silently skipped** and nothing re-populates it.

Repaired with a targeted one-column UPDATE, deliberately **not** a `needs_populate` replay, which
would rewrite every field from stale raw and could have reverted item 4's three statuses. Verified
0 cross-client and 0 billing-row attachments, and asserted no job with an existing `property_id`
changed. **The silent skip itself is NOT fixed** and belongs in `handleJob`.

## 7. Client codes for the 6 live coded-less clients (`e6c59a9`, migration `2026-08-12_1615`)

160 ACTIVE clients had a NULL `client_code`, which badly overstates it: only **6** have an open job,
only 5 have ever had a visit. The other 154 are one-off Jobber customers (120 invoiced, 40 with
nothing) plus non-clients (`Doug Test`, `Truck Maintenance`, `Parking`, two `NOT USE` rows, four
competing plumbers). Control: 123 coded ACTIVE clients, 92 with visits. **The 154 were left alone.**

| id | client | code | last visit |
|---|---|---|---|
| 83 | PineTree Holding Corp | `301-PT` | 2026-08-07 |
| 100 | Allison Sarbin | `302-SAR` | 2026-08-05 |
| 263 | Federico Hinojosa | `303-HIN` | 2026-08-05 |
| 351 | Laura odette | `304-ODE` | none |
| 518 | Habib Elghrissi | `305-HE` | 2026-07-29 |
| 525 | 16 Handles | `306-16` | 2026-08-04 |

Numbers 301-306 per [`client_code_scheme.md`](../reference/client_code_scheme.md): max normal was
300, no gap backfilling, computed across all statuses because the uniqueness index is partial, and
**verified free in both systems** (0 Jobber names carry a 3xx prefix, control 465 rows scanned).

**Two tag collisions avoided:** `AS` is already 251-AS Andrew Saka; and Habib Elghrissi shares a
surname with 119-ME Mosche Elghrissi but is a different person, so neither tag was reused.

### Written to Jobber as well (Fred: *"add the new clients codes on jobber suffix and in the custom field client code"*)

Both halves, matching the convention sampled from five existing coded clients:

| code | field written | result |
|---|---|---|
| 301-PT | `companyName` | `PineTree Holding Corp - 301-PT` |
| 302-SAR | `lastName` | `Allison  Sarbin - 302-SAR` |
| 303-HIN | `firstName` | `Federico Hinojosa - 303-HIN` |
| 304-ODE | `firstName` | `Laura odette - 304-ODE` |
| 305-HE | `companyName` | `Habib Elghrissi - 305-HE` |
| 306-16 | `companyName` | `16 Handles - 306-16` |

plus the **Client Code** text custom field (`ALL_CLIENTS`, config id ending `Mzgy NTky Nw==`) set to
the bare code on all six. Every one re-read after the mutation and verified on both name and field.

**Where the suffix goes depends on the client shape**, and this was read off live examples rather
than invented: companies take it on `companyName` (294-TCE, 298-PAR), a client with a real surname
takes it on `lastName` (251-AS `Saka - 251-AS`), and a first-name-only client takes it on
`firstName` (300-EC). Mutation is `clientEdit(clientId, input)`.

✅ **This does not double up in our DB.** `webhook-jobber` reads the **custom field first** and
strips a ` - CODE` suffix from the display name (the 2026-07-31 block), so `clients.name` stays the
clean business name. Confirmed by reading that code and watched across poll cycles.

### 🛑 `000` is a reserved band and the scheme did not say so

The code migration's duplicate-number assertion **refused on its first run and rolled everything
back**, on a pre-existing pair rather than my six: `000-DP` (DUMP Pompano) and `000-DH` (Homestead
Dump) both hold number **0**. They are disposal facilities carried as clients, deliberately parked
outside the customer sequence. That is a sentinel band like 700+, **not** a 247-style collision, and
they must not be renumbered. Added to the scheme doc; uniqueness checks must bound to `1..699`.

---

## The thread running through today

**Five "duplicate" findings were reversed in one day, every one by checking the upstream system.**
242-WYN properties (six real units sharing an address), 262-JM address spellings (Jobber holds both,
the duplicate is upstream), the SC jobs (six different sites), 128-MF, and the `000` pair. In no
case was a measurement wrong. **The claim built on the measurement was wrong every time.**

The instrument failures found today all share a shape too: **selective silence reads as a finding,
uniform silence reads as broken.**

| the silence | what it looked like | what it was |
|---|---|---|
| `property_id` NULL on 50 jobs | duplicate jobs | a mirror gap |
| `line_items` 0 job-scoped on 271 SC jobs | rule compliant | never mirrored at all |
| 5 unreadable PDFs dropped from the expired count | 17 expired | 22, and those 5 were the oldest |
| replay `ok:10 fail:0` every cycle | healthy sync | a backlog that never converged |

## Still open, none of it actioned

1. **22 ACTIVE-but-expired GDO permits**, 10 expired before 2024, oldest 2007. Business decision.
2. **5 ACTIVE permits with an unreadable PDF** and therefore no frequency.
3. **`public.line_items` mirrors 0 job-scoped rows for all 271 open SC jobs** (control: 323 on SA
   jobs). Fred's rule *"the SC only have line items on their visits not on the settings"* **cannot be
   audited from our database at all**.
4. **Jobber holds an upcoming 2026-08-16 visit on job 766 that `public.visits` does not have.**
   Not the test-client exclusion; both exclusion sets are empty.
5. **The `handleJob` silent property skip** (item 6) is unfixed.
6. **Job 1280's two paid invoices** for the same amount against one visit.
7. **154 ACTIVE clients with no code**, believed intentional but never confirmed by Fred.
8. **Property 200 (045-NU)**, absent from Jobber but carrying a live job.
9. **262-JM's duplicate address spellings** need merging in Jobber, not here.
10. **SC jobs recur on multi-site clients**: 4 of the last 40 landed on a client that already had one
    open, and a new 275-MLP job (1838) appeared at 15:45 ET while this work was in progress.
