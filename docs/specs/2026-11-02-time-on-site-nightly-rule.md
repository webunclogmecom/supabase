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
| S3b | the new nightly rule deployed switched off, the close-out, the site overrides (section 7) | part 1 BUILT 2026-11-03 12:45 ET (`2026-11-03_1500`): the override table with Fred's 5 Q8 rows, the ledger stage CHECK (`nightly`, `person`), Viktor's door (RC6 + RC8). **Part 2 BUILT 2026-11-05 11:20 ET (`2026-11-05_1125`, f891f36b): v15 and its four functions, switched off, parity passed. The runbook is section 10 and the day's numbers are 10.7** |
| S4 | band A: Fred's cards only | BUILT 2026-11-06 11:22:59 ET (`2026-11-06_1121`, 186623bb), on Fred's list of 2026-11-05 ("yes, keep 25 on 6599"). See 10.8 |
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
- 2026-11-09, the S6 card: *"50, go with your recommendation."* Visit 6243 (10-18, bonus approved 10-20) takes the
  rule's 50 min (`went_once`) over the saved 57 (`gps_150m_cluster`) in S6; the approved bonus is not re-priced. It was
  the only decided bonus the 10-18 to 10-26 dry range of 11-06 would move. S6 re-runs that range first and stops if
  6243's rule value is no longer 50.
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

## 10. Thursday 11-05: the S3b part 2 runbook (v15 deploy)

Fred, 2026-11-03: *"Build today, deploy Thu"*, then *"document this, so we know what we need to do on thursday"*.

- **What gets deployed:** edge function `time-on-site-samsara-recheck` v15, plus its four database functions.
- **Where it is built:** locally, outside the repo, under `samsara-checks/duration_recheck_run_2026-10-28/` (abbreviated
  RR below):
  - `RR/v15/`: the edge function code and its checks;
  - `RR/S3b/part2_functions.sql`: the four functions.
- **Everything below was proven on 11-03 except the steps marked NEW.** Thursday repeats the proofs on the day, then
  deploys.

**Rules for the day:**
- **One moving part.** No other session deploys `time-on-site-samsara-recheck` or `time-on-site-reminder`, rolls out
  `_shared/service-caller.ts` or `_shared/slack-notify.ts`, or runs legacy-keys steps 9 and 10 (plan G-9).
- **Write window:** 11:15 to 17:30 ET, clear of :05 to :10, :15 to :20, :30 to :45, and :00 to :05 before 14:05.
- **Times** come from the DB clock.
- **Never** a real (non-dry) call of the function by hand.
- **The switch stays off.** Thursday changes the code. It does not change `fn_request_time_on_site_samsara_recheck`'s
  body (still `'{}'`, so rules 1). The flip is S5, Wed 11-11, on Fred's word after the shadow comparison.

### 10.1 Before the deploy (morning)

| # | step | command (from RR unless noted) | pass |
|---|---|---|---|
| 1 | The morning check, after the nights of 11-03 and 11-04 (the S2 + S3a + S3b part 1 smoke) | `node --env-file=../../Supabase/.env morning.mjs` | PASS. In `sync_log`, cron 26 (02:20) and the nightly (02:50) have their usual counts (43 to 65 candidates), and no time-column write on a locked visit since 11-03 12:28 ET (`audit.logs` joined to `fn_time_on_site_is_locked`). T1 to T8 are 0 |
| 2 | Claim in `WORKING-NOW.md` (commit with an explicit path): the edge function, the four new functions, cron 151. Read the other sessions' claims and transcripts | file tool + `cat >>` | no open claim on these objects |
| 3 | v14 has not moved since the build | `sha256sum ../../Supabase/supabase/functions/time-on-site-samsara-recheck/index.ts` | `315e20a4e08310841eb54d6f2fbe12bb8fc5128a39ee6c7d9346ac1fba4b8d4a`. If it differs: rebuild (step 4) and re-run steps 5 to 7 |
| 4 | Build `v15/index.ts` from today's v14 and the modules | `node v15/build_index.mjs` | it prints the sizes |
| 5 | The offline proofs, all again | `node v15/equiv_test.mjs`, `node v15/closeout_test.mjs`, `node v15/check_index.mjs`, `node v15/stub_rules2.mjs` | each ends "ALL PASS" or "all checks passed" (0 of 1,452 mismatches; 26 close-out cases; 187 v14 lines kept; rules 2 stub plus its mutation) |
| 6 | The v14 stub test on v15 (rules 1 = v14) | from `Supabase/scripts/checks`: `node time_on_site_samsara_recheck.mjs <RR>/v15/index.ts` | "all checks passed (five mutations caught)" |
| 7 | The live-read proofs, rolled back | `node --env-file=../../Supabase/.env v15/site_test.mjs`, `v15/fixes_test.mjs`, `S3b/test_part2.mjs`, `S3b/test_stops500.mjs` | 25 of 25 sites identical; 40 of 40 fixes; every refusal reason right; 8752 lists its 471 m stop |
| 8 | **NEW: the migration.** `RR/S3b/part2_functions.sql` becomes `Supabase/docs/migrations/2026-11-05_<hhmm>_time_on_site_s3b_v15_functions.sql`, plus `2026-11-05_rollback_time_on_site_s3b_v15_functions.sql`. Contents: the header (the ask, the four functions, G-15); a PIN (none of the four exists yet; `fn_time_on_site_is_locked`, the overrides table and the `nightly` / `person` stage CHECK do exist); VERIFY: SECURITY DEFINER with an empty search_path, `has_function_privilege` false for anon and authenticated and true for service_role, and the read answers for today's window. The rollback drops the four, after a PIN that they exist | write the file, then from `Supabase`: `node scripts/probes/apply_sql_file.mjs <file> rehearse` | (a) as written: HTTP 201; (c) a PIN altered: raises; the rollback on top: the four are gone; the rollback alone: refuses |
| 9 | **NEW: the live positive cases** (rolled back, a runner like `S3b/test_part2.mjs`) | `fn_save_time_on_site_stay` on a real UNLOCKED completed visit of the window, passing its own saved interval, its own minutes and source, and its site point (r 250, point). Then `fn_close_time_on_site` twice for one visit of the run date | the save returns `{ok: true}` (our GPS at both ends inside the site); the first close-out inserts 1, the second returns `already_closed: 1` |
| 10 | Apply the migration, in the write window | from `Supabase`: `node scripts/probes/apply_sql_file.mjs <file>` | HTTP 201; then a read-only check that the four exist with the right privileges |

### 10.2 The deploy, with parity (plan 5.2 check a)

| # | step | command | pass |
|---|---|---|---|
| 11 | A v14 dry run, the "before" (a dry run writes nothing and logs nothing) | `node --env-file=../../Supabase/.env v15/dryrun.mjs v14_before_1105 '{}'` | HTTP 200 (on 11-03: 9 s, 53 candidates, 0 changes) |
| 12 | Copy v15 into the repo and deploy, within minutes of step 11. `verify_jwt = true` is pinned in `config.toml`; never pass `--no-verify-jwt` | `cp <RR>/v15/index.ts supabase/functions/time-on-site-samsara-recheck/index.ts`, then from `Supabase`: `SUPABASE_ACCESS_TOKEN=<PAT from .env, never printed> supabase functions deploy time-on-site-samsara-recheck --project-ref wbasvhvvismukaqdnouk` | "Deployed" (not proof on its own, see step 13) |
| 13 | Read the deployed body back | from `Supabase`: `node scripts/probes/edge_deployed_body.js time-on-site-samsara-recheck "rules must be 1 or 2" "BEGIN rule.mjs" "fn_time_on_site_recheck_visits" "api.samsara.com/v1/fleet/trips"` (the last one is the control: v14 has it too) | every needle present; `updated_at` is new. A new `version` alone proves nothing |
| 14 | The v15 dry run with the default body (rules 1), right after | `v15/dryrun.mjs v15_rules1_1105 '{}'` | HTTP 200 |
| 15 | Parity | `node v15/parity.mjs v14_before_1105 v15_rules1_1105` | "PASS parity": the same window, counts and changes. On a FAIL, run steps 11 and 14 once more back to back (a value can move between two runs); a second FAIL goes to rollback 10.4 |
| 16 | Commit in one breath (Supabase: an explicit pathspec and the Co-Authored-By footer; pull-rebase first): the function's `index.ts`, the migration and its rollback, this spec and `CLAUDE.md` | `git add <paths> && git commit -F <msg> -- <paths> && git push` | pushed. The commit before it is the rollback point: record its hash in the claim |
| 17 | Re-baseline the morning check's edge pins (the body and `updated_at` moved on purpose) | `node --env-file=../../Supabase/.env edge_pins.mjs` (it must show ONLY time-on-site-samsara-recheck moved), then `edge_pins.mjs --save` | the second run reports nothing moved; `morning.mjs` PASSES |

### 10.3 After the deploy: the new rule, dry (plan 5.2 checks b and f)

| # | step | command | pass |
|---|---|---|---|
| 18 | Check (b): the new rule over band B and band C with the ledger lock lifted (dry only), against judge D | `v15/dryrun.mjs v15_rules2_bandBC_1105 '{"rules":2,"from":"2026-10-08","to":"<yesterday>","include_ledger":true}'`, then `node v15/compare_b.mjs v15_rules2_bandBC_1105` | HTTP 200, and no "UNEXPLAINED" line. A difference is expected only where the saved value changed since Phase 1 (S2's 10 visits, band C's nightly writes since 10-28); each one is listed and read. `only_d` is empty |
| 19 | The new rule, dry, on tonight's window (the first shadow) | `v15/dryrun.mjs v15_rules2_shadow_1105 '{"rules":2}'` | HTTP 200; `places_ok: true`, `trip_reads_failed: 0`; every candidate listed with its decision |
| 20 | Check (f): no close-out row before the flip | read-only: `select count(*) from public.visit_time_on_site_corrections where stage = 'nightly'` | 0 (and 0 every morning until S5) |
| 21 | Docs, same cycle | this spec (S3b BUILT and its numbers); `Supabase/CLAUDE.md` time-on-site section (v15, the `rules` switch, `include_ledger` / `place_shapes` dry only, the close-out); `decisions-to-build.md`; the run README; memory; the Trello progress comment; release the claim | committed and pushed |

### 10.4 Rollback (if a check fails after step 12)

1. Redeploy v14 from the commit recorded in step 16:
   `git show <commit>:supabase/functions/time-on-site-samsara-recheck/index.ts > supabase/functions/time-on-site-samsara-recheck/index.ts`.
   Deploy it, read the body back (needle "rules must be 1 or 2" absent, "api.samsara.com/v1/fleet/trips" present), and
   commit. Do not use `aab4ac0`: it would undo later `_shared` work.
2. Then apply the migration's rollback, which drops the four functions. Nothing calls them under rules 1.
3. Part 1 (the overrides table, the stage CHECK, Viktor) stays. Its own rollback is
   `2026-11-03_rollback_time_on_site_s3b_overrides_stages_viktor.sql`, and it refuses while `nightly` or `person` rows
   exist.

### 10.5 What comes after Thursday

- **Fri 11-06 to Wed 11-11:**
  - every morning, a `{"rules":2}` dry run (the shadow), compared with what v14 wrote that night. Step 7 is judged on the
    value standing before 02:50 (plan 5.2 check d);
  - `stage = 'nightly'` rows stay 0;
  - Fri 11-06 also: S4, band A cards (Fred's answers are due Wed 11-04), and the dry range over 10-18 to 10-26 for the
    S6 cards.
- **Wed 11-11, S5:** Fred reads the comparison and says go. The flip is one line in
  `fn_request_time_on_site_samsara_recheck` (body `'{}'` to `'{"rules":2}'`), and the rollback is the same line back.
  The next morning's checks are plan 5.2 check e and the 8.1 row S5.

### 10.6 Known going in

- **Deno has never run v15.** The machine that built it has no Deno, so step 14 is its first Deno run. The file starts
  with `// @ts-nocheck`, because the inlined rule is untyped JS.
- **A knife-edge carried over from D.** Visit 8232 flips when the 30 m margin becomes 31 m. That is in D, and kept.
- **`shared_stay` is D's narrower reading.** The close-out adds the wider test (another visit's tap inside the stay)
  before it marks anything `nightly_self`.
- **The close-out's "a truck stayed at the site" tests use a wider site than the rule.** The point counts to 300 m, and
  a Place to its enclosing circle plus 80 m. So a doubtful blank goes to a person.

### 10.7 What happened on Thursday 11-05 (measured)

Applied at 11:20 ET, deployed at 11:20:39 ET (edge version 27). Commit f891f36b. **The rollback point is e0b9b7ff**, and its
function file is v14 (sha starts 315e20a4).

| steps | result |
|---|---|
| 1 | **morning.mjs FAILED, on history, and the day went ahead on live values** (below) |
| 3 to 9 | v14 had not moved. Every proof passed again: equivalence, close-out, index, stub rules 2, v14 stub on v15 (five mutations caught), 25 of 25 sites, 40 of 40 fixes, every refusal reason, 8752's 471 m stop. Rehearsal of both migrations: as written, an altered PIN raises, the rollback on top, the rollback alone refuses. Live positive cases rolled back on visit 9075 |
| 10 | HTTP 201 for both. The four functions: SECURITY DEFINER, empty search_path, only postgres and service_role can run them. All T and Z checks 0 |
| 11, 14, 15 | v14 and v15 under rules 1: the same window (10-26 to 11-06), 65 candidates, 0 changes, identical. **PASS parity** |
| 13 | every needle present, `updated_at` new |
| 17 | only `time-on-site-samsara-recheck` moved, then saved. Rebaselined in `out/rebaseline.json`: `fn_stop_facts_checks` (`2026-11-05_1120`) and the shared `audit.log_change` (`2026-11-04_2141`) |
| 18 | rules 2, 10-08 to 11-04, ledger lock lifted: 177 visits, 169 candidates, 5 write, 125 keep, 28 hold, 11 locked, `places_ok`, 0 trip reads failed. Against D: 119 compared, 107 the same, 12 where the saved value moved since D (S2's 10 visits, and 5944 and 8893 by the nightly), **0 unexplained**, `only_d` empty |
| 19 | the first shadow, 10-26 to 11-06: 71 visits, 67 candidates, 3 write, 48 keep, 16 hold, `places_ok`, 0 trip reads failed |
| 20 | 0 `nightly` rows; the cron's body is still `'{}'` |

**Why step 1 failed, and why that did not stop the day.** Its check fails if any hourly stop facts run in the last 26 hours
was not clean, and 11 were:
- **T5 on 9074, cleared at 02:20 ET, and on 9076, cleared at 11:00 ET.** T5 is a blank from yesterday whose gap has no stop
  while `v_visit_stop_reference` has one. 9076 closed at 04:33 ET, after the night's fill, so it waited for the 11:00 fill.
  The T5s are transient, as this one proved.
- **Z8 from 02:35 ET.** The Monthly Report page's `derm.lwt_board` (`2026-11-05_0245`) reads `public.v_vehicle_dumps` for one
  on-screen hint. Fred: "Allow this one function". `2026-11-05_1120` allows that view in that function only, and three probes
  in its VERIFY prove any other stop or tank object, in any `derm` function, still fires.

At 11:06 ET, before anything was applied, the live values were T1 to T8 all 0. The 11:35 ET hourly run, the first after the
deploy, was `success` with every T and Z at 0. The check was not changed: it keeps failing on this history until about 12:35
ET on 11-06, so judge those mornings on the live values too. The daily shadow of 10.5 is `RR/v15/shadow.mjs` (`--self-test`
proves its first-night reading); it writes `RR/shadow/<date>.md`, and a trial run today passed.

**A false alarm in the comparison tool, fixed.** `compare_b.mjs` first reported 47 "UNEXPLAINED". It compared v15 with D's
answer on the value BEFORE the first nightly overwrite (`d.decision`), while v15 reads the live value, so identical keeps read as
differences (5889: D "write" from 164 to 159, the live value already 159). It now compares with D's answer on live (`on_live`)
and leaves a label lock locked. A copy of the run with a keep turned to a write, a different number of minutes, or a label
lock lifted is caught each time.

**What the first shadow would write, for the 11-11 comparison:** 6056 from 93 to 101 (two parts), 8868 from blank to 23, and
9076 from 4 to 94. On 9076 the saved 4 is the fallback's stop at 02:52, and the truck then parked from 02:59 to 04:33, the
minute it closed. A fallback's value is not held as a big change (`FALLBACK` in the rule), by design.

**Q-L closed with no Samsara edit** (Fred: "no need to send a message"). Yan's three questions were answered from the truck
data, and the two doubtful Places are ones the rule already drops. Visits at properties with no Place, last 60 days: 110, of
which 107 have a linked stop within 250 m of our point, 0 beyond, 3 no linked stop. Caveat: linked stops sit near the property
by construction, so the shadow runs from 11-06 are the real test. Client detail is local (the run's README).

### 10.8 What happened on Friday 11-06 (S4, measured)

Applied at 11:22:59 ET, commit 186623bb, rollback `2026-11-06_rollback_time_on_site_s4_band_a_cards.sql`. 33 ledger rows of run `tos-recheck-2026-r4`, stage `person`, all applied, none skipped. 8 visits written (7 values, 6270's label), 6 audit flags closed, nothing sent to Jobber. Rehearsed first: as written, the consumer diff, a proposed row moved (skipped), an applied row moved (T7 stops the file), four moved (stops), an altered PIN, the rollback on top, the rollback alone (refuses).

| check | predicted | measured |
|---|---|---|
| durations | 3903 205 -> 55, 3890 107 -> 178, 1462 29 -> 67, 5802 28 -> 51, 8139 29 -> 50, 1311 99 -> 117, 3927 93 -> 117 | equal, net +45 |
| Calendar past days, next 45 days | the seven only; the average of 6239 95 -> 70 | equal |
| `v_visit_tank_service`, F7 | disagreement true -> false on 8139; F7 down by 1 | equal, 106 -> 105 |
| shared time | 3903 loses 3901, nothing new | equal |
| tank hash, frozen grease, every other completed visit time, stop reference, control 6509 | unchanged | unchanged |
| T1 to T8, open flags | 0; 7 -> 1 (7828's truck question stays) | equal |
| live apps | Admin Review 3903 55m, 3890 2h 58m, 8139 50m, 6270 1h 41m, control 6509 32m; Calendar Sep 16 Grecia 6.2h -> 6.5h | equal |

**The wording that was wrong:** the approved page said the 22 reopened locks "lose the lock". T9 (S7, 11-16) fires on any completed visit over 10 days old with no current applied or proposed row, and a current row IS the lock, so they cannot end with no row. On the page Fred approved, 5 change and 17 keep their minutes; each of the 22 got a new settled row. Fred was told this correction twice before the apply (11-05 and the morning of 11-06) and did not object.

**Left out on purpose:** every other visit on the page, the 5 blanks (each has a current row), 7828's truck question, band C (S6). **A row moved on an applied visit stops the whole file rather than skipping**, because T7 then stands: the safer answer when a settled value has changed.
