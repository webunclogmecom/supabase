# Time on site: the lock and the nightly rule (spec)

**Trello:** [vpF5PLQj](https://trello.com/c/vpF5PLQj) "Visit durations: find the error patterns, then backfill every
affected visit". **Plan:** the approved local plan `samsara-checks/recheck_plan_2026-10-27/PLAN.md` (it names clients, so
it stays outside the repo; this spec is the public-safe part: visit ids, minutes and times only). **Written** 2026-11-03,
before stage S3a, as the plan requires (its section 11). **Updated with each stage.**

| stage | what | status |
|---|---|---|
| S1 | completion stop only inside the visit window; alarm T1 without an upper age | BUILT 2026-11-02 (`2026-11-02_1430`, 1b6d14ca) |
| S2 | band B (visits dated 10-08 to 10-17, plus 8854) closed in the ledger | BUILT 2026-11-03 (`2026-11-03_1300`, e815caa1) |
| **S3a** | **the lock in the five writers, and the reopen rule (sections 3 to 6)** | **BUILT 2026-11-03 12:28 ET (`2026-11-03_1330`), a day early on Fred's "go ahead with S3a now"; every rehearsal and control below passed** |
| S3b | the new nightly rule deployed switched off, the close-out, the site overrides (section 7) | part 1 BUILT 2026-11-03 12:45 ET (`2026-11-03_1500`): the override table with Fred's 5 Q8 rows, the ledger stage CHECK (`nightly`, `person`), Viktor's door (RC6 + RC8). The v15 code, its read and save functions and the close-out are built and checked first, then deployed Thu 11-05 (Fred: "Build today, deploy Thu") |
| S4 | band A: Fred's cards only | Fri 11-06 |
| S5 | the switch on, after Fred reads the comparison | Wed 11-11 |
| S6 / S7 / S10 | band C by the rule; alarms T9 and T10; cleanup | 11-13 / 11-16 / 11-30 |

## 1. What Fred decided

- 2026-10-27: *"Approve the whole plan"*.
- 2026-11-02, Q-E (a) and (i): **"locked" means a reviewed label OR a current `applied` or `proposed` row in
  `public.visit_time_on_site_corrections`, with one test in every writer. The reopen trigger keeps a locked value.**
- 2026-11-02, Q-C (a): the new nightly follows the plan's dates. It is deployed switched off on Thu 11-05, compared
  every day, and switched on Wed 11-11 after Fred reads the comparison.
- 2026-11-02, Q-F (a): there is no decided-bonus guard inside the nightly's 10-day window. One-time stages still turn a
  decided bonus whose value would move into a card.
- 2026-11-02, Q-D (a): shapes the rule cannot settle are held for a person, on the Monday page. Q-M (c): there is no
  monthly sample, so T11 is not built.

## 2. Words used here

- **The time columns:** `visits.duration_minutes`, `actual_arrival_at`, `actual_departure_at`,
  `time_on_site_source`.
- **Labels (`time_on_site_source`) and who writes each:**

  | label | written by | meaning |
  |---|---|---|
  | `review` | a migration only (10-18 fix, S2) | a decided value; every writer skips it |
  | `reviewed_blank` | a migration only | a person found nothing to measure; stays blank |
  | `dump_site_dwell` | `fn_fill_time_on_site_from_stops` | a dump-site visit's single dump stop |
  | `stop_at_completion` | `fn_fill_time_on_site_from_stops` | the truck stop holding the completion (a fallback) |
  | `samsara_stay` | `fn_save_samsara_stay`, `fn_save_samsara_stay_went_once` (the 02:50 nightly) | Samsara's stay |
  | `gps_150m_cluster` | `fn_compute_time_on_site` | the longest 150 m stay of the visit's truck (a fallback) |
  | `gps_150m_any_truck` | `fn_fill_blank_time_on_site` | any truck within 150 m at completion (a fallback) |
  | NULL | legacy values, or a blank | |

- **The ledger:** `public.visit_time_on_site_corrections`. One **current** row per visit at most
  (`superseded_at IS NULL`, a unique index). Rows are superseded, never edited in place. `applied` rows are watched by
  T7 (the time columns must equal `new_*`) and T8 (truck, date, completion). A `proposed` row waits for a person. A
  `proposed` row whose action is `keep_verified` means "the proposal is to keep". It does not mean verified.
- **Locked** (Q-E): `time_on_site_source IN ('review', 'reviewed_blank', 'dump_site_dwell')` OR a current ledger row with
  status `applied` or `proposed`. A `rolled_back` or `skipped_guard` row does not lock.
- **Visit window:** from 4 h before the visit date (00:00 ET) to 10:00 ET the next day. The candidates function, the stop
  reference view (since S1) and the judges all use it.

## 3. Facts the lock rests on (measured 2026-11-03, read-only)

- **The five writers** are all SECURITY DEFINER, owner `postgres`, EXECUTE `postgres` and `service_role` only:

  | writer (md5 on 11-03) | writes | skips today | callers |
  |---|---|---|---|
  | `fn_fill_time_on_site_from_stops(boolean)` `acaaf879` | `stop_at_completion` / `dump_site_dwell` | anything but a NULL blank, or a `gps_150m_cluster` value of the last 10 days; **no date window for blanks** | cron 26 (02:20 ET), the 11 AM reminder, Viktor's truck door |
  | `fn_compute_time_on_site(date,date,boolean,int,int,int)` `9ed2ff46` | `gps_150m_cluster` | any label but NULL or `gps_150m_cluster` | the same three |
  | `fn_fill_blank_time_on_site(date,date,boolean)` `b1d8cea3` | `gps_150m_any_truck` | anything but a NULL blank | the same three |
  | `fn_save_samsara_stay(...)` `4f220a19` | `samsara_stay` | `review`, `reviewed_blank`, `dump_site_dwell`; a row that changed since read | edge fn `time-on-site-samsara-recheck` (02:50 ET) |
  | `fn_save_samsara_stay_went_once(...)` `2395825e` | `samsara_stay` | the same | the same edge fn |

  Viktor's door is `viktor_set_visit_truck`. It runs the three fillers for the visit's date only, with no 10-day window,
  so it can reach any visit of any date.
- **The two saves return `false` when they do not write.** The edge function counts any answer other than `true` as
  `refused` (`if (ok !== true) { counts.refused++ }`). So a lock test added to their `WHERE` fails safe and needs no
  edge deploy.
- **What the lock newly protects.** 505 completed visits are locked by label today. **899 more are protected only by a
  ledger row**, and none of those is inside the nightly's 10-day window. Of those 899, these are writable by some writer
  today:
  - 35 NULL blanks (the 34 decided blanks plus 8752): the stop fill and the any-truck fill would fill them;
  - 6270 (101 min, no label, an open card): the 150 m measure could rewrite it;
  - 767 `samsara_stay` and 96 `stop_at_completion` values: only the saves can rewrite these, and only inside their
    window.

  Until S3a, date windows alone keep those values safe.
- **The reopen trigger** `trg_zz_clear_time_on_site_on_reopen` (BEFORE UPDATE OF `visit_status`, when a completed visit
  leaves `completed`) runs `fn_clear_time_on_site_on_reopen()` (`8cb07e25`, SECURITY INVOKER). It clears the time
  columns unless the label is `review` or `reviewed_blank`.
  - **Who reopens:** in the last 60 days, `jobber` 7 times (the completion reconcilers) and `visit-calendar` 3 times
    (through its SECURITY DEFINER status RPC).
  - `anon` and `authenticated` cannot UPDATE `visit_status` (column privilege false), so the trigger runs as
    `service_role` or `postgres`.

## 4. S3a, part 1: one lock predicate in every writer

**The function** (G-15 of the plan):

```sql
CREATE FUNCTION public.fn_time_on_site_is_locked(p_visit_id bigint) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (SELECT 1 FROM public.visits v WHERE v.id = p_visit_id
                   AND v.time_on_site_source IN ('review', 'reviewed_blank', 'dump_site_dwell'))
      OR EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections c
                  WHERE c.visit_id = p_visit_id AND c.superseded_at IS NULL AND c.status IN ('applied', 'proposed'))
$$;
REVOKE ALL ON FUNCTION public.fn_time_on_site_is_locked(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_time_on_site_is_locked(bigint) TO service_role;
```

- **SECURITY DEFINER** because the ledger has RLS on and no grant to anyone but the owner. Every caller is a postgres-owned
  definer writer or the reopen trigger running as `service_role` / `postgres` (section 3).
- **One definition.** The labels inside it are the same three the saves already skip, so the saves' own label test
  becomes redundant. It stays in place: the edit only adds a clause.

**Where it goes.** One anchored clause per writer: `AND NOT public.fn_time_on_site_is_locked(v.id)`.

| writer | where it picks its rows (so a dry run counts what a real run writes) | in the UPDATE's WHERE |
|---|---|---|
| `fn_fill_time_on_site_from_stops` | yes (`_fill_stops`; the morning check's "stop fill would fill" count reads it) | yes |
| `fn_compute_time_on_site` | yes (the `target` CTE) | yes |
| `fn_fill_blank_time_on_site` | yes (the `blank` CTE, whose rows the dry run counts as "filled") | yes |
| `fn_save_samsara_stay` | (no candidate set) | yes: returns `false`, counted `refused` |
| `fn_save_samsara_stay_went_once` | (no candidate set) | yes: the same |

The three fillers' counts are discarded by every caller: cron 26 selects them, and the reminder and Viktor's door call
them with `perform`. So the clause in the candidate set changes no reader of those counts.

**How each edit is made** (the S1 way):
- the live body is read with `pg_get_functiondef` and its md5 is pinned;
- the anchor must occur exactly once;
- the edited text is EXECUTEd, then read back, and must equal the expected text;
- the new md5 goes into the migration's VERIFY and into the morning check's re-baseline.

The migration is `2026-11-03_1330_time_on_site_s3a_lock_in_writers.sql`. Its rollback beside it restores each old body
by md5 and drops the function last. Both files were generated from the live bodies by a script, so no body was retyped.

**As built (2026-11-03):**
- R2: the three fillers, run as cron 26 and the reminder call them, wrote the same visits old and new (only 9054,
  unlocked). Their dry candidate sets were identical.
- R3: on 6512, the old stop fill, 150 m measure and any-truck fill each wrote the locked visit, and the new ones did not.
  The save on 8588 and the went-once save on 8773 went from `true` to `false`.
- R4: as `service_role`, a reopened locked visit (8854) was cleared before and is kept now. An unlocked one (9045) is
  cleared both times, and a `review` one (8851) is kept both times.
- R5: `authenticated` is refused with 42501.
- R5b: `viktor_set_visit_truck` on 6512 runs with no error, changes the truck, keeps the time, and T8 names the visit.
- After the apply: the six md5s are as predicted, no visit time changed anywhere, and T1 to T8 are 0. The morning check
  re-baselined and passes.

**What does not change.**
- No visit is written, no edge function is deployed, and no view or check function changes.
- Viktor's door gets the lock through the fillers. Its reply text is fixed in S3b (RC8): until then, on a locked visit,
  it reports the kept value as if just measured, or "still empty" for a locked blank.
- A truck change on a visit with an `applied` row still fires T8, by design.

## 5. S3a, part 2: the reopen rule (Q-E part 2)

`fn_clear_time_on_site_on_reopen` gains one condition: it clears only when the visit is NOT locked.

```sql
  if coalesce(OLD.time_on_site_source, '') not in ('review', 'reviewed_blank')
     and not public.fn_time_on_site_is_locked(OLD.id)                     -- S3a, Q-E part 2
     and (OLD.duration_minutes is not null or ...) then
```

In the BEFORE trigger the table still holds the OLD row, so the predicate sees the visit as it was.

- **What a person sees:**
  - a reopened locked visit keeps its value;
  - T6 (a time on a visit that is not completed) and T8 (status) are red while it stays reopened, as they already are
    for a reopened `review` visit;
  - a re-completion with the same date, completion time and truck clears both by itself;
  - any other outcome stays red and goes to the Monday page, where a dry range run re-measures it and a superseding row
    settles it.
- **One behaviour change to know:** `dump_site_dwell` is part of "locked", so a reopened dump-site visit (9 completed
  ones today) now keeps its dwell. Before, it was cleared, and the stop fill refilled the same value after
  re-completion.

## 6. S3a: checks, rehearsals, smoke tests

**Before the migration (read-only, on the day):**
1. Claim in `WORKING-NOW.md`, then read the other sessions' claims and transcripts. The shared `_shared` roll-outs and
   legacy-keys steps are not on the same day (G-9).
2. Pre-flight:
   - the six md5s of section 3 equal the live bodies;
   - the morning check passed after a clean night;
   - T1 to T8 are 0;
   - today's 11 AM reminder run is logged before any write between 11:15 and 14:00.
3. Prediction register:
   - **no visit changes** today: no ledger visit is in the 10-day window (measured 0 on 11-03; re-measure);
   - the stop-fill and any-truck dry runs drop exactly the locked visits from their candidates;
   - the T checks are unchanged.

**Rehearsals** (`apply_sql_file.mjs <file> rehearse`, and a runner with fixtures, every run rolled back):
- **R1, as written:** pass.
- **R2, parity:** each of the five writers runs on today's window, dry and executed, once with the old body (a `pg_temp`
  copy) and once with the new one. The written sets must be identical, because no ledger visit is in the window.
- **R3, the predicate bites (positive controls):** for each writer, one fixture where the OLD body writes a locked visit
  and the NEW body does not:
  - **stop fill:** a decided blank with a ledger row that has a completion stop;
  - **150 m measure:** a ledger visit with its label set to NULL inside the transaction;
  - **any-truck fill:** a ledger blank with a truck within 150 m at completion;
  - **each save:** a ledger visit whose own interval is passed back, which the old body accepts (`true`) and the new
    body refuses (`false`).

  The fixture ids are chosen on the day from the section 3 lists. A control the old body does not write is replaced,
  never dropped.
- **R4, reopen:** run as `service_role`, and once through the Calendar's status RPC. A locked fixture keeps its four
  columns, an unlocked fixture clears them, and the old body as control clears both.
- **R5, privileges:** `has_function_privilege` is false for `anon` and `authenticated` and true for `service_role`. This
  is checked in the migration and again after the rollback rehearsal.
- **R5b, every caller's path runs:**
  - cron 26's command, the reminder's refresh block and `viktor_set_visit_truck` each run inside a rolled-back
    transaction as their real role;
  - the transaction must end with no warning;
  - 🛑 why: the reminder wraps the three fillers in `exception when others then raise warning`, so a predicate that
    errors there (a missing grant, a typo) would turn into a silent warning and leave the 11 AM path unfilled with
    nothing red. Cron 26 has no such wrapper and would fail loudly in `cron.job_run_details`.
- **R6, one PIN altered:** the file raises.
- **R7, the rollback on top:** the six bodies are back to their old md5s, the function is gone, and the privilege lines
  hold.

**After the apply:**
- the new md5s are recorded;
- `out/rebaseline.json` gains the five writers and the trigger function, so the morning check reads them as expected;
- the stop-fill count, read in a rolled-back run, drops to the visits with no ledger row.

**Visual checks:** none, because no value changes (plan 8.1).

**Smoke test, the night after:**
- the 02:20 cron 26 and the 02:50 nightly logged with counts in their usual range (43 to 65 candidates);
- `audit.logs` shows no time-column write on a locked visit;
- T7 and T8 are 0;
- the morning check passes.

## 7. S3b and after: the nightly rule (deployed switched off Thu 11-05)

The full design, with its fixtures and numbers, is in plan section 5.2. In short, and public-safe:

- **Candidates:** every completed client visit of today - 10 to tomorrow that has a truck and is **not locked**. Inside
  the window a held change is retried every night. At day 10 the visit is closed into the ledger (the close-out below).
- **The site:**
  - the visit's site point within 250 m, where an override spot replaces the map point;
  - or the client's linked Samsara Place plus 40 m. A Place whose latest observation says `moved` is not used unless an
    override names it;
  - **both** trip ends of a stay must be at the site;
  - Place shapes come from one live Samsara read per run, failing closed: if it fails, no Place-only stay and no decided
    blank that night.
  - Overrides are data in `public.time_on_site_site_overrides`: a stored-fix id or a Place id, never coordinates.
- **The rule:**
  1. the tap claims the stay of its own truck that holds it, else the nearest within -5 / +15 min;
  2. a tap made while the truck stands at another client is not evidence;
  3. a joined or went-once stay counts only when no other client's visit that night is within 30 m of it;
  4. seed: the claimed stay, else the single clear went-once cluster, else keep the value and record why;
  5. a re-park counts whole: neighbouring clear at-site stays at most 15 min apart, with no stored fix beyond 250 m
     between them;
  6. never fail open: no stay means keep, never blank, never change a truck; no data is not "no stay";
  7. **a big change** (more than 15 min or 50%) of a Samsara value needs a Jobber visit timer starting within 5 min of the
     new arrival. The completion tap never confirms the stay it chose. A fallback value (`stop_at_completion`,
     `gps_150m_cluster`, `gps_150m_any_truck`) is not protected: it is replaced at 2 min or more;
  8. complex shapes (loads, shared stays, another truck, another day) are held for a person;
  9. wait for data: never decide on a stay that has not ended or not been stored yet.
- **The save** `fn_save_time_on_site_stay` re-checks on the server:
  - the row is unchanged since it was read, and the visit is not locked (section 4);
  - the arrival is inside the window and the span is 0 to 12 h;
  - our own stored GPS fixes at both ends are inside the same site.
- **The close-out** at day 10, only when `rules = 2` and not a dry run, writes one ledger row per visit:
  - `keep_verified`, method `nightly_self`, when the rule agrees. This is never counted as independent verification;
  - a decided `blank` (`no_samsara_presence`) only when six data tests pass: the truck has trips, no other-day stay, no
    other truck at the site, no stop of ours within 500 m, the Place read succeeded, and no stay at the client's other
    property;
  - otherwise `proposed` for a person.

  The ledger's stage CHECK gains `nightly` and `person` (one widening, after listing every reader).
- **The switch:** `rules` 1 (today) or 2 (the new rule), flipped in one line of
  `fn_request_time_on_site_samsara_recheck` on Wed 11-11. The old path is removed after 14 clean nights (S10).
- **Checks** (plan 5.2 N-G):
  - the stub tests are repaired first;
  - parity of v14 and v15 with `rules: 1`;
  - a `rules: 2` dry run with `include_ledger` equals the re-run simulation visit by visit;
  - the golden fixtures, each guard's negative control, a daily shadow, and the first night equal to the last shadow.

## 8. Alarms (`fn_time_on_site_checks`, hourly, read by the daily health email once per code)

| alarm | meaning | since |
|---|---|---|
| T1 | a completed visit 3 or more days old, not settled in the ledger, blank or much shorter than its stop | changed in S1 |
| T6 | a time on a visit that is not completed (a reopened locked visit shows here until it is re-completed) | before |
| T7 | an `applied` ledger row whose visit no longer holds its `new_*` | 10-18 |
| T8 | an `applied` ledger row whose visit changed truck, date or completion, or was deleted or reopened | 10-18 |
| T9 | a visit 11 or more days old with no `applied` or `proposed` row (a close-out gap) | S7, after band C |
| T10 | a `proposed` row older than 8 days (waiting on a person) | S7 |

T11 (a monthly sample) is not built (Fred, Q-M).

## 9. Not in this spec

These are out of scope, each for a reason given in plan 5.1:
- the stop builder;
- the vehicle linker;
- a rebuild of history;
- counting a shared stop once in Hours worked;
- errands;
- a re-measure after a truck change outside the window.
