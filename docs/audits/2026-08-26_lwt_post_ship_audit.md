# LWT monthly filing: the ship, and the audit that followed it, 2026-08-26

*Fred: "do an audit to see if we're missing something, and if not, send me the dm to copy."*

**The work described here happened on 2026-08-26 ET; this file was written at 2026-08-27 04:12 ET.**
Every timestamp came from the DB (`now() at time zone 'America/New_York'`), never the session clock,
per `feedback_get_todays_date_from_the_db_not_memory`, and that rule earned itself again here. An
earlier draft of this paragraph said the ET day had *not* yet rolled and that the machine clock
running CEST was the only reason today's artefacts read 08-26. True when written at 18:50 ET, stale
by the time the file was committed. The migrations (`_1815`, `_1842`) are stamped with the ET time
they were actually applied, so the filename date is right for the ship.

**Audience:** whoever next touches `rpa-derm-monthly`, `rpa-derm-monthly-filed`, or the tables
behind them. **This is not a summary of what shipped** (the API reference in `postman/README.md`
§4c and §4d is that). It is the record of what the audit found wrong afterwards, because most of it
was wrong in a way that reads as correct.

**No Lovable app consumes any of this.** Measured: `v_lwt_monthly_rows|rpa-derm-monthly|lwt_filing|
truck_decal` returns **0** occurrences across the `Building Apps` repos, against a positive control
(`derm_manifests|visit_locations`) returning 328 across 60 files. So there is deliberately no
`Building Apps/<App>/docs/` entry for this work; root CLAUDE.md §4b does not apply.

---

## 1. What shipped, in one table

| | |
|---|---|
| `derm.v_lwt_monthly_rows.truck_decal` | the vehicle's ACTIVE Miami-Dade decal, per row. 649 of 700 resolve. |
| `rpa-derm-monthly` | `truck_decal`, `truck_decals`, `reported` + `filing` per ticket, `?unreported=1`, `mode` |
| `rpa-derm-monthly-filed` | **new POST**, ticket-grained, append-only, idempotent on `run_id` |
| `public.lwt_filings`, `public.lwt_filing_tickets`, `derm.v_lwt_ticket_reported` | the store |
| Postman | filing set 17 → 21 tests, folder 5 → 6 requests, **new folder 6** (8 requests) |

Migrations: `2026-08-26_1600`, `_1615`, `_1815`, `_1842`.

---

## 2. The audit: six auditors, 54 raw findings, 14 survived refutation

Scope was tests, README accuracy against live behaviour, both edge functions, the DB objects, every
quantitative claim re-measured, and the outgoing Slack message. Each finding then went to a verifier
briefed to **refute** it, defaulting to `real=false`.

**The code and the data were sound.** No live data defect. The decal mapping, every constraint, the
idempotency index, the LATERAL's fan-out safety and every number re-measured exactly. **What was
wrong was almost entirely what we had WRITTEN about it**, which is why none of it showed up as a
failing test.

⚠ **40 lower-severity findings were not verified**, by an explicit cap in the workflow. That is a
stated limit, not a clean bill.

---

## 3. 🛑 The one that matters: a security property claimed four times and never implemented

`2026-08-26_1615` created both tables with:

```sql
revoke all on public.lwt_filings from public;
grant select, insert on public.lwt_filings to service_role;
```

That reads like hardening. It is not. **`CREATE TABLE` had already handed out full privileges
through Supabase's `ALTER DEFAULT PRIVILEGES`, and a REVOKE aimed at the `PUBLIC` pseudo-role does
not touch a grant held by a NAMED role.** So the GRANTs added nothing and the REVOKE removed
nothing.

Measured on both tables before the fix:

```
authenticated  SELECT+ INSERT+ UPDATE+ DELETE+ TRUNCATE+   rls=false   0 audit triggers
service_role   SELECT+ INSERT+ UPDATE+ DELETE+ TRUNCATE+
anon           nothing                                     <- this half was always correct
```

Against the sibling this design copied, `public.derm_portal_submissions`: `authenticated` holds
**nothing**, RLS **on**, **2** audit triggers.

**Cost.** Any signed-in staff browser could `PATCH` or `DELETE` a county filing record straight
through PostgREST. `lwt_filing_tickets.filing_id` is `ON DELETE CASCADE`, so deleting one header row
silently re-queues every ticket on it for a **second filing with Miami-Dade**. Exposure was
prospective, not realised: 2 rows existed, both `dry_run`.

**Meanwhile the claim "the endpoint's role holds only SELECT and INSERT, so the inability is a
grant, not a branch" had been written into the README twice, a code comment, and a message to an
external developer.**

🛑 **This is `public.job_frequency_changes` (fixed 2026-08-07) recurring verbatim on a compliance
table, three weeks later, in a repo whose CLAUDE.md documents that exact defect** under "Grants,
views and functions". Reading the rule is not running the check.

### What fixed it, and what made the fix trustworthy

`2026-08-26_1815`: `authenticated` loses everything, `service_role` keeps SELECT + INSERT only, RLS
on, and both tables get the audit trigger **rule 8 requires and neither earlier migration mentioned
either way**.

Checked *before* revoking rather than assumed:

- `derm.v_lwt_ticket_reported` is **not** `security_invoker` and is owned by `postgres`, so it reads
  as its owner. `authenticated` keeps SELECT on the view and loses nothing it uses.
- The `Building Apps` repos reference these tables **0** times, against a control finding a real
  table **328** times. ⚠ **Audit silence could not have told us this**: neither table had ever had
  an audit trigger, so an empty `audit.logs` is a false all-clear here **by construction**. That is
  the §5.5(b) trap in root CLAUDE.md, and it applied exactly.
- `rpa-derm-monthly-filed` contains no `.update(`, `.delete(` or `.upsert(`.
- `service_role` has `rolbypassrls = true`, so enabling RLS cannot break the endpoint.

✅ **The migration's verification block was run ALONE first, against the pre-fix state, and
correctly refused**, naming all 14 defects. A verification block that has never failed is not a
verification block.

✅ **Then probed as the real roles**, in a `DO` block terminated by a `RAISE` so nothing could
commit:

```
service_role SELECT=allowed | INSERT=allowed | UPDATE=denied | DELETE=denied
authenticated TABLE=denied  | VIEW=allowed (apps keep working)
audit trigger FIRED on the insert
```

🛑 **A permission probe over the Management API measures nothing**: that transport runs as
`postgres`, which OWNS the table and bypasses the grant system. `SET LOCAL ROLE`, or
`has_table_privilege(<role>, ...)`.

---

## 4. Two assertions that could never fail, and the harness that hid both

### 4a. `pm.test` dispatches on ARITY

```js
pm.test("a dry run does NOT mark the ticket reported", () => {   // <- no `done`
    pm.sendRequest({...}, (err, res) => { pm.expect(...) });      // runs AFTER the report
});
```

postman-sandbox: `if (assert.length) { wait for done } else { call it and report immediately }`.
With no `done` parameter it takes the **synchronous** path, so it fires the request and records
**PASS** before the callback asserts anything. Under newman the stray failure is swallowed
entirely: no output, no failure row, **exit 0**.

**The one assertion protecting real tickets from a rehearsal was permanently green.** Fixed to
`function (done)` with `try { ... done(); } catch (e) { done(e); }`, and mutation-tested both ways.

### 4b. The wrong-key test was sending the VALID key

It declared the bad key as a plain request header. postman-runtime's apikey signer runs **after**
and does `request.headers.remove(h => lowerCase(h.key) === lkey)` then adds the collection's own.
So the only auth test on a **write** endpoint exercised the authorised path, and in documented run
order its body is a valid dry-run filing, so it would have written a third permanent row. Fixed to
a request-level `auth` block, matching folder 3.

### 🛑 4c. The generalisation, which is the reusable part

**A harness that models a runtime is a SECOND implementation, and it is the one nobody tests.** My
Node runner was wrong about **both** rules above: it always called the test function with no
arguments, and it applied collection auth *before* letting request headers override. Each error
concealed a real defect **in the direction of looking healthy**, and my mutation tests "passed"
because they exercised my model rather than Postman's.

It then bit for real: after the collection was fixed, the still-wrong runner sent the valid key and
**wrote a spurious row to Prod**, the exact outcome the finding predicted. (`bot-postman-badkey`,
deleted with Fred's approval; see §7.)

---

## 5. 🛑 A guard set exactly at the cap can never trip

`rpa-derm-monthly` requested `.limit(MAX_ROWS + 1)` with `MAX_ROWS = 1000`, then raised
`month_too_large` on `rows.length > MAX_ROWS`. Its comment read *"Loud, never a silent
truncation."*

**PostgREST is configured `max_rows: 1000` and enforces it regardless of a larger explicit limit.**
Measured on a 2,524-row table:

| requested | returned |
|---|---|
| `limit=999` | 999 |
| `limit=1000` | 1000 |
| `limit=1001` | **1000** |
| `limit=5000` | **1000** |

So the comparison was structurally false. Now compares against `count: 'exact'`, which keeps
reporting the true total through the cap (`content-range 0-999/2524`), so it fires whenever the
server returned fewer rows than exist, whichever limit bit first.

⚠ **The sibling read had no limit and no check at all**, and it is the one that SELECTS the filing
set: `derm.v_lwt_ticket_reported` at 127 rows of a 1000 cap. Past that it would have served the
first 1000 with HTTP 200 and the bot would have filed a short month. Both now guarded.

---

## 6. The retracted claim that would not die

"The filed quantity is the truck capacity resolved from the decal" was retracted the same morning
against Jonathan's invoice (ticket 828837: Moises / C1184 / 9,000 on our side, **3,800** billed).
The retraction was applied to the README, two comment blocks and the assertion messages.

**It survived in six more places**, found across three separate sweeps:

| where | note |
|---|---|
| the Postman request labelled **START HERE** | the first thing a reader opens |
| `docs/schema.md:669` | |
| `COMMENT ON VIEW derm.v_lwt_monthly_rows` | **where the claim originally propagated from** |
| `Supabase/CLAUDE.md` | the file every session reads first |
| `docs/specs/2026-08-24-...` §6 | stated as positive design rationale |
| the `truck_decal` code comment | **written hours AFTER the correction** |

🛑 **A PHRASE grep only finds the wordings you already thought of.** `resolve.*from the decal` found
three. The code comment read *"the caller resolves quantity from a decal-keyed table"* and the spec
read *"the quantity on the filed form is the truck capacity"*. Same claim, neither matches. What
found them was a relational pattern over the two **concepts**:

```
(decal|capacity)[^.]{0,80}(quantity|filed)|(quantity|filed)[^.]{0,80}(decal|capacity)
```

⚠ **A correct DECISION can rest on the retracted premise and nothing about the outcome flags it.**
The spec's "`gallons` stays null" was right, and is *more* obviously right under the true rationale,
so a false premise sat under a good call for two days invisibly. **Check conclusions you still agree
with.**

⚠ The migration headers that still carry it (`2026-08-24_1730`, `2026-08-25_0400`) are **dated
records and were deliberately left alone.** Correcting a historical migration to match the present
is how the evidence disappears.

---

## 7. 🛑 `truck_decals` is MANIFEST-grained; `rows` is FILING-grained

`index.ts:275-280` builds `trucks` and `truck_decals` from **`all`** rows on the ticket, while
`rows` uses **`kept`** (`all.filter(r => r.in_scope)`) unless `include=all`. So `truck_decals` can
name a decal appearing on **no row the caller was served**.

Live: **ticket 312024** (August). David ran two Broward pickups on that manifest, both out of scope,
so every served row is Moises / C1184 while `truck_decals` reads `["C0976","C1184"]`.
**1 of 118 tickets**, which is the density that survives a spot-check and then puts a wrong permit number on
a county form.

**This predates the decal work** (`trucks` disagrees the same way on 2 tickets) and the endpoint is
correct. **My first assertion compared the two as if they were one set and failed on that ticket.**
I nearly filed it as a product bug; what stopped it was reading the source before reaching a
verdict.

⇒ Asserts what actually holds: `truck_decals` reconciles with `trucks` (same grain), and the served
rows' decals are a **SUBSET** of it. Both verified over 245 ticket-payloads.

⇒ Also removed an assertion that was **provably implied** by another: if `truck_decals` equals the
deduped decals of `trucks`, it can never be longer. An assertion that cannot fail is not one.

---

## 8. The grain mix that reached the outgoing message

Found by re-measuring every number in the Slack draft rather than trusting it:

> *"51 of 700 rows come back null ... Cloggy holds no decal in any jurisdiction: that is **43 rows**
> across 27 in-scope tickets. Six more rows have no truck at all."*

**51 counts every row. 43 counts only the in-scope ones.** So it read as `51 = 43 + 6`, which is 49,
and a careful reader goes looking for two rows that were never missing. It is **45 rows, 43 of them
in scope**, and `45 + 6` closes. Corrected in the message, the README and the code comment.

Same class as §7: two grains in one sentence, both numbers individually correct.

---

## 9. The dry-run default that would have filed a real report

The example body in **both** the API reference and the outgoing message omitted `dry_run`. The check
is `body.dry_run === true`, so **omitting it, sending `null`, or spelling it `dryRun` all record a
permanent REAL filing.** The tickets in the example are real ticket numbers; a copied body would
mark them filed with a `filed_at` nobody chose, and they would drop out of `?unreported=1` for good
and never reach the county.

Both examples now send `true`, with the default named in prose. The example's ticket list is also
now flagged as illustrative: SP00013840's window (06/28 to 07/25) holds **19** in-scope tickets, not
the 2 shown.

---

## 10. Also fixed

- **`?unreported=1` had no content coverage.** It serves 599 rows across 8 months where `month=`
  tests 90 rows of one, so a data defect outside the last completed month passed the whole suite.
  Ported the content assertions; added the three row keys the shape check omitted (`in_scope`,
  `anomaly`, `pickup_in_dade`).
- **The no-property case was undocumented.** `address`, `city`, `state`, `zip` and `county` are
  **null together** on 14 of 700 rows (13 in scope, 10 clients), an exact diagonal with no
  half-populated row either way. Asserted in the tests, stated in no document. The null-decal rule
  already forces 11 of the 13 to be refused; **ticket 825560 is the one a compliant bot would
  otherwise file with a blank service address**, and nothing in `data_quality`, `anomaly` or
  `excluded_rows` flags it.
- **The `unknown_tickets` echo assertion goes inert after the first run ever** (stable `run_id` means
  every later run takes the replay path, which returns no `unknown_tickets`). It now logs a `NOTE`
  instead of skipping silently, and the README says how to re-arm it.

---

## 11. The sanctioned delete

`bot-postman-badkey` (`lwt_filings` id 34) was written by the harness bug in §4b. Fred approved
removing it. Done the way a sanctioned delete has to be done here:

1. **Rule-8 check first.** Both tables carry audit triggers as of `2026-08-26_1815`, so
   `audit.logs.old_row` is a real recovery path. Confirmed present afterwards for the filing **and**
   its cascaded child.
2. **JSON backup** to `backups/2026-08-26_lwt_filings_badkey_row.json` with a restore hint, before
   touching anything.
3. **Pinned to the PK while re-asserting the predicate that made it deletable**
   (`id = 34 AND run_id = 'bot-postman-badkey' AND dry_run = true`), so it could not fire if the
   world had changed between the read and the write.
4. **Verification inside the transaction**, raising rather than committing on any mismatch: target
   gone, cascade clean, ids 15 and 16 **surviving**, exactly 2 filings left, 0 tickets reported, an
   audit row present.

⚠ **`service_role` could not have performed it.** The lock-down left the endpoint's role at SELECT +
INSERT. It took the table **owner** over the Management API. That is the correct reading of
append-only: the application cannot rewrite the record, not that nobody can.

---

## 12. Verification state at close

| | |
|---|---|
| monthly suite | **35/35**, including 26 mutations that each turn the intended assertion red |
| folder 6 against live | **24/24** after the error-code requests were added (was 9/9) |
| error-code mutations | **7/7**, including "a different gate fired" |
| atomic RPC | migration verify passed with its non-atomic control firing; re-proven independently; fresh-insert path **27/27** over HTTP |
| `api-doc-drift.js` | clean: 25 error codes, 3 params, 19 row fields all documented |
| `?unreported=1` | 118 before and after a full folder-6 run |
| `derm.v_lwt_ticket_reported` | 127 tickets, **all `reported = false`** |
| `public.lwt_filings` | 2 rows, both `dry_run = true` |
| em dashes added | 0 |

---

## 13. The message that actually went, and why it was rewritten

*Added 2026-08-27 10:19 ET.*

The first draft was **8,451 characters over two Slack messages**. Fred: *"make it look like a person
answered them ... natural, short, and simple, not too technical, but using the important keys."*
The version sent is **2,630 characters in one message**, about a third of the length.

What was cut: the append-only grant reasoning, the `unknown_tickets` echo, `confirmation_ref`
nullability, option 2 versus option 3, the scope question with Yan, the Broward decal reasoning, the
index-alignment trap, ticket 825560 by name, and my own account of the five missed copies of the
retracted claim. All of it is in the API reference, which the message points at.

What was kept even though it is technical, because each one bites:

| kept | if he does not know it |
|---|---|
| `dry_run` defaults to false | he files a real county report by accident |
| `filed_by_email` required when `run_id` starts `manual-` | a `400` he has to debug |
| nulls mean refuse the ticket | a guessed permit number on a filing |
| `truck_decals` is not his filing set | a wrong permit number on a filing |
| don't copy the example ticket list | 2 of 19 tickets filed as if they were the package |

⚠ **Before sending, every number in it was re-measured rather than trusted, and one was wrong.**
See §8: the Cloggy sentence mixed two grains. That check is the only reason it did not go out.

---

## 14. 🛑 `ticket_insert_failed` cannot be recovered by the caller

*Found 2026-08-27 while documenting the error codes. Not a finding from the six-auditor pass.*

Writing a filing is **two statements with no transaction around them**: the header into
`lwt_filings`, then the rows into `lwt_filing_tickets`. The header insert is what claims the
`run_id` (that is the idempotency mechanism, a unique index plus a `23505` branch).

So if the *second* statement fails:

- the header exists and the `run_id` is **already claimed**;
- retrying with the same `run_id` hits `23505`, takes the **replay** path, and returns
  `already_recorded: true` with `tickets_recorded: 0` **without inserting anything**;
- the filing stays permanently empty and those tickets stay unreported.

⚠ **I first documented the opposite from a guess** ("retry with the same `run_id`, the replay path
will not re-insert the header"), which is true about the header and wrong about the outcome. Reading
the insert path showed it. **The doc-drift check would have passed either way** because it compares
documented against emitted, never documented against true. Read the code before writing the
sentence.

**Documented for the caller with the tell**: `tickets_recorded: 0` on a replay means that filing is
empty. He is told to report it rather than paper over it with a fresh `run_id`, which would leave an
orphan filing behind.

**It never fired.** ✅ **FIXED 2026-08-27** in `2026-08-27_1024_lwt_record_filing_atomic.sql`.

Both inserts moved into `public.fn_record_lwt_filing`. PostgREST runs a function call in one
transaction, so a ticket failure now rolls the header back with it, the `run_id` is never claimed,
and a retry is a clean first attempt rather than a replay of an empty filing. The edge function
lost 41 lines and holds **zero** direct writes to either table.

🛑 **SECURITY INVOKER, deliberately.** A `SECURITY DEFINER` wrapper owned by `postgres` would
bypass the very grant that makes the append-only claim true, which is the widening CLAUDE.md warns
about. Measured first: `service_role` already holds SELECT on `derm_manifests` and SELECT + INSERT
on both targets and **no DELETE**, so invoker rights are sufficient and the grant stays the control.
Verified after: `prosecdef = false`, `anon` and `authenticated` cannot execute, `service_role` can,
and the table lock-down is untouched.

**How atomicity was proven**, rather than argued from "a function is one transaction": a temporary
trigger forces the ticket insert to fail, the function is called, and the filing row must NOT exist
afterwards. 🛑 **With a control that fires** - the same probe is run against a deliberately
non-atomic implementation (one that swallows the ticket failure in an inner block), and that one
must leave a header behind. Without it, step 4 passing could just mean the probe is blind. Re-run
independently outside the migration: `returned_anyway=f header_survived=f control_detected=t`.

⚠ **Folder 6 could not have caught a regression here**, and that is worth knowing. Both of its
`run_id`s already exist, so every write request it makes takes the **replay** path: the fresh-insert
path, and with it all parameter marshalling (JS array to `text[]`, date strings, nulls), was
untested over HTTP after the rewrite. Covered by a separate 27-assertion run that also proved
de-duplication (3 tickets in, 2 rows out) and manifest resolution. It left one `dry_run` row,
`atomic-verify-20260827`.

**Contract change:** `insert_failed` and `ticket_insert_failed` no longer exist. One
`record_failed` replaces both, and it always means nothing was recorded.

---

## 15. Documentation drift, and making it mechanical

Fred: *"remember that you must have the postman documentation of this api rest up to date."*
It was not. Diffing what the endpoints **emit** against what the reference **documents** found
**five error codes documented nowhere**, including `reported_lookup_truncated`, which I had added
hours earlier, and the changed `month_too_large` payload.

`scripts/checks/api-doc-drift.js` now makes this re-runnable: it compares emitted error codes, query
params and row fields against `postman/README.md`. Mutation-tested, and it exits **2** rather than 0
when its own extraction looks implausible.

🛑 **That exit-2 rule exists because the first version was wrong in the most dangerous way.** It
located the row object with a pattern that matched a **comment**, extracted **zero** fields, and
printed *"all documented"*. Two of its other three findings were also its own pattern bugs
(`unreported` reported missing because the check demanded backticks the README does not use;
`invalid_` reported as a code when it is a dynamic prefix). **Two thirds of its first run was the
instrument, not the target.**

### Error-code test coverage

| endpoint | before | after |
|---|---|---|
| `rpa-derm-monthly` | 5 of 10 | **6 of 10** |
| `rpa-derm-monthly-filed` | 6 of 15 | **12 of 15** |

Seven requests added. **Every one asserts the error CODE, never just the status**, because
validation runs in a fixed order and a request tripping an earlier gate still returns `400`. A
status-only assertion would pass while testing something else entirely, so each body is built valid
right up to the gate it targets, and each also asserts nothing was recorded.

Mutation-tested seven ways, including the case that matters: feeding a test the response from a
**different** gate must turn it red. Also covered a silently raised ticket cap and a valid ticket
being wrongly rejected.

⚠ The 2,001-ticket body is generated in a pre-request script, and is **one over** the cap on
purpose, so the test fails if the cap is ever RAISED rather than passing on a wider one.

### 🛑 The seven that stay untested, named rather than quietly absent

| why | codes |
|---|---|
| database failure | `monthly_query_failed`, `reported_lookup_failed`, `insert_failed`, `ticket_insert_failed` |
| needs volume an order of magnitude past real data | `month_too_large` (largest real month 109 rows against a 1,000 cap), `reported_lookup_truncated` (127 tickets) |
| needs the key secret unset | `server_misconfigured` |

**Four of those are the truncation and write-failure paths**, which are precisely the ones deciding
whether a short or empty filing reaches the county. Testing them means fault injection, a bigger
change than a Postman collection. They are listed in the README so the gap is visible, and the drift
check enforces that every code is either exercised or on that list. **There is no third category.**

---

## 16. Still open

- **Diego**: is Cloggy a permitted LWT vehicle? 45 rows / 43 in scope / 27 in-scope tickets carry
  `truck_decal: null`, offloads 2026-01-15 to 2026-08-20.
- **Yan**: the scope rule (`pickup_in_dade OR offload_in_dade`). Untouched; nothing here pre-empts it.
- **Jonathan**: the July diff against Diego's filed county pages. Everything verified so far only
  proves the endpoint agrees with **our own database**.
- ✅ **`ticket_insert_failed` is FIXED** (§14), 2026-08-27. The write is atomic, the error no
  longer exists, and `record_failed` replaces it meaning nothing was recorded.
- **Three error paths have no test and are the three that matter most** (§15): the truncation and
  write-failure paths. They need fault injection. The worst of them is gone rather than untested.
- **Optional**: `unknown_tickets` could be returned on the replay path too, which would make that
  assertion live on every run instead of only the first. Small endpoint change, not taken.
- **`vehicle_decals` has no temporal validity.** If a decal is ever replaced, historical months will
  report the CURRENT one. Inert today (4 rows, all ACTIVE, none ever replaced).
