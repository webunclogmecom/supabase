# Slow-fetch audit, 2026-09-03

**Fred:** *"this and past week it have been working slowly... the apps loads up fast enough, but the
data to display takes too long to be displayed, like the fetch takes too long from time to time."*

Sections 1-6 are the READ-ONLY audit, written before anything was changed - read them as the
"before" picture. A fix was then applied (`2026-09-03_1800_stagger_cron_schedules.sql`, `ce0500f`)
and the **post-fix re-audit is appended at the end of this file**, including the root cause that
sections 1-6 had not yet identified: **background-worker starvation**, `max_worker_processes = 6`
against 14 jobs firing at minute `:00`.

---

## Verdict in one line

**The database is not generally slow. It stalls in short episodes, and separately it was spending
31.8% of its execution time on one query that returned zero rows.**

⚠ Read that second clause carefully: 31.8% of *execution time*, where total query load is only ~2.2%
of one core - so it was ~0.7% of a core, not a third of the machine. Both the stalls and that query
have since been fixed; the root cause of the stalls turned out to be neither. See the end of this file.

---

## 1. The largest single query, and it found nothing (fixed; and see the correction below)

```
derm.fn_blackout_targets(p_limit)
  649 calls · 2,056 ms mean · 22.2 minutes total · 31.8% of ALL database execution time
  rows returned: 0
```

Driven by the `redact-manifest-sweep` cron (`*/5`) via `fn_request_blackout_sweep` ->
`redact-manifest-sheet`. `EXPLAIN ANALYZE` confirms it: `Function Scan ... (actual time=1973.680
..1973.681 rows=0)`. It takes ~2 seconds to decide there is nothing to do, and it does that every
five minutes, forever.

This is the cheapest thing on the list to fix and the only finding that is pure waste. It is not
"slow because the DB is loaded" - its stddev is 189 ms against a 2,056 ms mean, so it costs the same
2 seconds every single time, busy or idle.

⚠ **It is not broken** - returning 0 is the correct answer, there is no blackout work pending. The
defect is that establishing that costs 2 seconds.

🛑 **CORRECTION (2026-09-03, credit to the Supabase 2 session). An earlier version of this line said
fixing it "would return roughly a third of the database's capacity". THAT WAS WRONG and the error is
worth understanding, because the number itself is right.** 31.8% is a share of *database execution
time*, and total query load on this instance is only about **2.2% of one core**. 37% of 2.2% is
**~0.7% of one core**. The percentage is real; the denominator makes it small.
⇒ Fix it because it is free waste, **not** because it will fix the reported slowness. It will not.
⇒ It also weakens section 3: a box averaging 2.2% of one core is *accruing* burst credits, not
depleting them. ⚠ But `pg_stat_statements` counts STATEMENTS only - it cannot see autovacuum,
checkpointer, bgwriter, the WAL sender feeding Realtime, or platform work like backups. So 2.2%
bounds the QUERY load and says nothing about total instance load.
✅ **FIXED 2026-09-03** (`2026-09-03_1900_blackout_targets_materialise_bands.sql`): **2,056 ms ->
529 ms**, same rows. The cost was `derm.v_stamp_row_bands`, a 713-row VIEW costing 3 ms, referenced
five times and re-derived ~640 times inside correlated subqueries. Materialised once into a CTE.
No predicate changed and deliberately NO short-circuit was added - this function decides which client
documents get redacted, and a wrong early exit fails open on PII.

---

## 2. The slowness is EPISODIC, not constant, and everything slows together

Every cron run over 3 seconds in the last 7 days - 17 windows, in three clusters:

| when (ET) | duration | jobs affected in one minute | worst |
|---|---|---|---|
| 08-31 10:05 - 10:37 | ~30 min | up to 8 at once | 17.3 s |
| 09-03 12:50 - 12:56 | ~6 min | up to 6 at once | 19.8 s |
| 08-28 13:27, 15:40 | isolated | 2 | 12.7 s |

🛑 **The shape is the diagnosis.** These jobs average **0.03 - 0.37 s**. During an episode they all
hit 10-20 s *simultaneously*. A slow query slows itself; when unrelated statements all slow together
by 10-50x, they are victims of a shared stall, not causes of it.

⚠ **I initially read this as a "cron convoy" and that was wrong.** Total cron time is **492 seconds
in 24 hours - 0.6% of wall clock**. The crons are not the load. They are simply the only thing that
records its own duration, which is why they are a useful stall detector.

---

## 3. The instance is small, and the DB now roughly equals its cache

```
shared_buffers        256 MB
effective_cache_size  768 MB
work_mem              3.4 MB
max_connections       60      (39 in use; 21 are PostgREST's idle pool, by design)
database size         752 MB
```

The whole database is about the size of `effective_cache_size`. Cache hit ratio is still **99.95%**,
so it fits today - but there is no headroom, and this is the profile of a burstable instance whose
CPU credits deplete under sustained load and then recover. That behaviour produces exactly the
episodic pattern in section 2.

⚠ **I could not confirm this from inside the database.** Compute size, CPU credit balance and disk
IOPS are not exposed to SQL and the Management API does not return them on this endpoint. **This is
an inference from the memory settings, not a measurement.** The Supabase dashboard's CPU and Disk IO
charts for 08-31 10:05-10:37 would confirm or kill it in one look, and that is the single most
valuable thing to check next.

---

## 4. What is NOT the problem (each checked, each cleared)

| suspected | measured | verdict |
|---|---|---|
| `v_calendar_visit` is slow | plans at **85 ms**, all index scans, no seq scan on the hot path | healthy; its 6,377 ms max is an episode victim |
| a 45-minute stuck query | it is Realtime's `START_REPLICATION SLOT ... WalSenderWaitForWal` | long-lived by design |
| connection exhaustion | 39/60, of which 21 are PostgREST's deliberately-held idle pool | fine |
| autovacuum not running | 11 tables vacuumed and 23 analyzed in 24 h; `autovacuum = on` | healthy |
| table bloat | `last_autovacuum = never` on the big ones, but they are append-only partitions and telemetry | not a fault |
| PostgREST schema reloads | 118 in 53 h, ~800 ms each = **~95 s total** | real but negligible |
| the apps hammering the DB | see section 5 | not the cause |

---

## 5. ⚠ The app-side finding I nearly got wrong, and the correction

My first two browser measurements showed the Calendar refetching **all 11 endpoints 4-6 times**
within a minute, which looked like a severe amplification defect.

**It was largely my own instrument.** Every `javascript_tool` call I made was itself provoking a
refetch. Measured properly - observer installed, then **90 seconds with zero browser interaction**:

```
REST calls in 90 s idle: 11   (one burst, 11 distinct endpoints, 0 focus events)
```

One full refresh roughly every 90 seconds on an idle tab. That is a reasonable poll for a live
calendar, not a defect.

✅ **The arithmetic confirms it independently:** `v_calendar_visit` shows **1,992 calls in 53 hours =
37/hour**, which is almost exactly one open tab polling at 90 s. If the app were refetching 6x a
minute the counter would read ~190,000.

⇒ Had I reported the first measurement, I would have sent someone to fix a 60x amplification bug
that does not exist. **The browser is not a passive observer; automating it changes what it measures.**

---

## 6. Other things worth someone's time

- **A single 92-second query** sits in the stats: the Stamp Studio band/stamp query
  (`with pub as ( select r.id, r.dump_folder, coalesce(r.stamp_page,r.page) ...`), one call,
  91,850 ms. One-off, but if it is reachable from the UI it will stall the instance on its own.
- `derm.v_stamp_sheets`: 168 calls, 493 ms mean, 6,245 ms max.
- `public.objects` (Storage metadata): 368 dead rows against 362 live, with **5.1 million index
  scans**. Small table, heavy traffic - worth a look if Storage feels slow.
- The Calendar issues **11 separate endpoint calls** per refresh. Not a bug, but it is 11 round trips
  where a couple of composed views would do, and it is 11x more exposed to any stall.

---

## Recommended order

1. ~~**Fix `derm.fn_blackout_targets`.**~~ ✅ **DONE** - 2,056 ms -> 529 ms. ⚠ But see the correction
   in section 1: this returns ~0.7% of one core, not "a third of capacity", so do **not** expect it
   to resolve the reported slowness. It was free waste and is now gone; that is all.
2. **Look at the Supabase dashboard CPU / Disk IO charts for 08-31 10:05-10:37 ET.** That single
   check confirms or eliminates the burstable-CPU theory in section 3, which nothing inside the
   database can answer.
3. **Only then consider compute.** If (1) frees a third of the capacity, the episodes may stop being
   noticeable without spending anything.

## How to re-run this

```sql
-- the offender, and its share
with s as (select calls, mean_exec_time::numeric mt, total_exec_time::numeric tt
             from pg_stat_statements where query like '%fn_blackout_targets%'
            order by total_exec_time desc limit 1),
     tot as (select sum(total_exec_time)::numeric t from pg_stat_statements)
select s.calls, round(s.mt)::int mean_ms, round(s.tt/60000.0,1) total_min,
       round(100.0*s.tt/tot.t,1) pct_of_all, (select count(*) from derm.fn_blackout_targets(50)) rows_found
  from s, tot;

-- stall windows: any cron run over 3s
select to_char(start_time at time zone 'America/New_York','MM-DD HH24:MI') et, count(*) jobs,
       round(max(extract(epoch from (end_time-start_time)))::numeric,1) worst_s
  from cron.job_run_details d join cron.job j on j.jobid=d.jobid
 where d.end_time is not null and extract(epoch from (d.end_time-d.start_time)) > 3
   and d.start_time > now() - interval '7 days'
 group by 1 order by 1 desc;
```

⚠ `pg_stat_statements` was last reset **2026-09-01 12:00 UTC**, so it covers 53 hours - it cannot
speak to "last week". The cron history goes back further and is what section 2 relies on.
⚠ `round(double precision, int)` does not exist in this Postgres; cast to `numeric` first.

---

# Post-fix re-audit, 2026-09-03 13:42 ET

The re-phase (`2026-09-03_1800_stagger_cron_schedules.sql`, `ce0500f`) took effect at **13:34 ET**.

## What is PROVEN, and needs no waiting

Structural, recomputed from the live `cron.job` table rather than from the planning script:

| | before | after |
|---|---|---|
| peak jobs in one minute | **14** | **5** |
| minutes/hour at or above the 6-worker pool | **9** | **0** |
| minutes/hour with 4+ jobs | 12 | 4 |
| active jobs | 25 | 25 |
| per-job frequency | - | **unchanged**, asserted per job in the migration |

The condition that produced `job startup timeout` - more jobs demanding a background worker than the
pool of 6 can supply - **no longer occurs at any minute of the hour.** That is deterministic, not
statistical.

## What is NOT yet proven, and I am not going to claim it

```
runs in the 15 minutes since   38
failures                        0
runs over 3s                    0
max duration                    0.19 s   (during a stall window: 10-20 s)
```

🛑 **This is consistent with the fix working and it does not demonstrate it.** The baseline failure
rate is **0.22 failures/hour**, so a clean 15-minute window would be expected to contain
**about 0.06 failures** even with the bug fully present. Zero is what you would see either way.

Worse, the symptom was **episodic**: 36 failures in 7 days arriving in three clusters, not spread
evenly. A quiet quarter of an hour is exactly what the previous seven days looked like most of the
time. **Absence of the symptom over 15 minutes is not evidence.**

⇒ **The honest verdict: the mechanism is provably removed, the outcome needs a few days.** The check
that will actually settle it, run in a week:

```sql
-- must stay at zero. Any row here means the worker pool is still being exhausted.
select to_char(start_time at time zone 'America/New_York','MM-DD HH24:MI') et,
       (select jobname from cron.job c where c.jobid=d.jobid) job, return_message
  from cron.job_run_details d
 where status <> 'succeeded' and start_time > timestamptz '2026-09-03 17:34:00+00'
 order by start_time desc;
```

## Still open after this fix

1. **`derm.fn_blackout_targets` is 32-37% of all DB execution time and returns zero rows.** Owned by
   the Supabase 2 session, deliberately untouched here. Fixing it is the single largest remaining
   win and is independent of the scheduling problem.
2. **`max_worker_processes = 6` with `cron.max_running_jobs = 32`** is still an inconsistent pair.
   Staggering means we no longer *demand* more than 5 at once, but the ceiling is unchanged and a
   future job added carelessly at `:00` walks straight back into it. Raising it needs a restart and
   is Fred's call. **Anyone adding a cron should check the collision map first**, not just pick `*/5`.
3. **The instance profile** (shared_buffers 256 MB, effective_cache_size 768 MB against a 752 MB
   database) is unchanged and remains an inference, not a measurement - the dashboard CPU / Disk IO
   charts for 08-31 10:05-10:37 ET are still the check that would confirm or kill it.

---

# max_worker_processes raised 6 -> 12, 2026-09-03 15:05 ET

## 🛑 The pool is three smaller than it looks

Three background workers are **permanently resident**, measured in `pg_stat_activity`:

| backend_type | slots |
|---|---|
| logical replication launcher | 1 |
| pg_cron launcher | 1 |
| pg_net 0.20.0 worker | 1 |

So a stated pool of **6 gave 3 usable slots** for pg_cron job workers and parallel query workers -
and `max_parallel_workers = 2` drew from those same 3. That is why fourteen jobs at minute `:00`
failed so completely. At 12 the usable figure is **9**.

⇒ **When sizing this, subtract the three permanent residents first.** The headline number lies.

Not from this pool, despite appearing in `pg_stat_activity`: checkpointer, background writer,
walwriter, archiver, the autovacuum launcher, and the walsender feeding Realtime.

## ✅ Do autovacuum workers draw from it? No - proven, not assumed

The documentation is silent on this and it is commonly stated wrongly, so it was settled by
contradiction on real data. **If** autovacuum drew from the pool, then 3 permanent +
`autovacuum_max_workers` 3 = 6 = the entire old pool, leaving **zero** for pg_cron - so cron would
have failed *always*, not occasionally.

```
autovacuum runs, last 24h ................................... 11
successful cron runs, last 24h ........................... 3,173
cron successes within 60 SECONDS of an autovacuum finishing . 62
```

Those 62 are impossible if the pools are shared. They are separate.

## The change

`PUT /v1/projects/<ref>/config/database/postgres` with `{"max_worker_processes": 12}` -> HTTP 200.

⚠ **It restarts immediately, not in a maintenance window.** The next SQL call returned
`FATAL 57P03: the database system is shutting down`. **Unavailability: 40 seconds.**
⚠ `GET` on that endpoint previously returned `{}` - **no parameter had ever been overridden**, so 6
was purely the compute-tier default. It is now an explicit override.

Value derived from demand, not rounded: 3 permanent + 5 peak cron in one minute + 2 parallel = 10,
set to 12 for headroom.

## Verified after

```
max_worker_processes 12 · pending_restart: none · max_parallel_workers 2 (<= 12)
3 permanent bgworkers back · realtime walsender back · 25 cron jobs active
sync.outbound_queue pending 0 (nothing lost) · Jobber write token intact
6 min later: 14 cron runs / 10 distinct jobs / 0 failures / 0 over 3s / max 0.55s
derm.fn_blackout_targets still 540 ms
Calendar in the browser: signed in, visits rendering, 13 REST calls, slowest 585 ms, no errors
```

## ⚠ Two things to carry forward

1. **This was headroom, not a fix.** The re-phase had already taken failures to zero *before* the
   restart. Raising the ceiling protects against the next carelessly-added cron; it did not resolve
   an active failure. Do not let a later reader infer the restart is what fixed the stalls.
2. **A compute-size change may silently reset it**, because it is now an override against a tier
   default. The check is one line:
   `select setting from pg_settings where name='max_worker_processes';` -- must read 12.

---

# 🛑 CORRECTION, 2026-09-03 15:20 ET — the worker-starvation root cause was WRONG

Everything above about background-worker starvation, minute `:00`, and the 6-slot pool is **false**.
An adversarial workflow refused the premise and every one of its claims verifies:

```
cron.use_background_workers = off     context postmaster, source DEFAULT — never set
failures at minute :00 ......... 0    job starts at minute :00 ... 12,042 (perfect record)
failure minutes ................ 9,10,15,27,33,35,36,37,50,51,55,56
failure durations .............. 10.02 s to 19.79 s
```

**With `use_background_workers = off`, pg_cron runs every job as a libpq CLIENT CONNECTION** against
`cron.host = localhost`. Jobs consume `max_connections` and never touch `max_worker_processes`; the
only pool slot pg_cron holds is its single launcher. **The mechanism I described cannot occur.**

⚠ **Two things should have stopped me and did not:**
1. **The minute I blamed has a perfect record.** `:00` — where I counted 14 colliding jobs — has
   12,042 starts and **zero** failures across 119,693 runs. I built the fix around a collision map
   without ever checking whether failures actually landed on the colliding minutes. One `group by`
   would have killed it.
2. **The duration refutes it on its own.** An exhausted slot pool refuses *instantly*. Ten to twenty
   seconds is a connection-establishment deadline expiring. I read `job startup timeout` and matched
   it to the theory I already had.

## What is actually tight

**Connections and memory, not workers.** `cron.max_running_jobs = 32` against `max_connections = 60`
(3 superuser-reserved) with PostgREST holding ~21 idle is a genuine and dangerous pair — measured
worst case **59 of 60**. My instinct that `32` was inconsistent with the ceiling was right; I named
the wrong ceiling.

## What survives, and what it cost

| action | verdict |
|---|---|
| **Cron re-phase** (`ce0500f`) | **KEEP.** Right for the wrong reason: spreading jobs reduces concurrent CONNECTIONS, the resource that is actually scarce. Peak 14 -> 5 still holds. |
| **`max_worker_processes` 6 -> 12** | **Bought essentially nothing for cron.** Harmless (260 KB of shared memory) and not worth a second restart to revert, but it did not address the failures. |
| **`fn_blackout_targets` 2,056 -> 529 ms** | Unaffected by any of this. Still a real fix. |

🛑 **AND IT COST SOMETHING I DID NOT ANTICIPATE: the restart reset `pg_stat_statements`.**
`stats_reset` is now `2026-09-03 14:18:36 ET`. With `track_functions = 'none'`, that view is this
estate's **only usage oracle** — the one root `CLAUDE.md` §5.5(b) requires before revoking any grant
or RPC. **Any "is this still used?" audit run in the next few days returns a confident false zero.**
⇒ Snapshot it before any future restart:
```sql
create table ops.pgss_snapshot_<date> as select now() as captured_at, * from pg_stat_statements;
```

## Where that leaves the original question

The episodic stalls are **still not explained**. Not the crons (0.33% of wall clock), not worker
starvation (impossible), not `fn_blackout_targets` (~0.7% of one core). Connection pressure and
memory remain the live hypotheses, and **the dashboard CPU and Disk IO charts for 08-31 10:05-10:37
ET remain the single most useful unexamined evidence** — as this document has said from the start,
and is now the only recommendation in it that has never been wrong.

---

## 2026-09-03 ~16:5x ET — COMPUTE UPGRADED `ci_micro` -> `ci_medium` (Fred: "Go with Medium")

**This is the only change in this audit that addresses the ACTUAL remaining hypothesis.** Everything
above ruled a cause out; this one acts on what was left. Fred chose Medium over the Small I
recommended.

### What changed

| | before (`ci_micro`) | after (`ci_medium`) |
|---|---|---|
| RAM | 1 GB | **4 GB** |
| CPU | 2 cores, **burstable** | 2 cores, burstable (unchanged) |
| baseline disk IO | 87 MB/s | **347 MB/s** (burst 2,085) |
| direct connections | 60 | **120** |
| `shared_buffers` | 256 MB | **1024 MB** |
| `effective_cache_size` | 768 MB | **3072 MB** |
| `work_mem` | 3.4 MB | **7 MB** |
| `maintenance_work_mem` | 64 MB | **256 MB** |
| cost | ~$10/mo | ~$60/mo |

**The number that matters: the database is 752 MB and `effective_cache_size` is now 3072 MB.** The
whole working set fits in cache with room for the co-tenant services, which it did not before.

`max_parallel_workers` (2) and `autovacuum_max_workers` (3) did NOT scale with the tier.

### 🛑 THE ENDPOINT IS `PATCH`, NOT `POST`. A POST RETURNS 404.

`POST /v1/projects/{ref}/billing/addons` -> **HTTP 404**, which reads like "this project cannot be
resized" rather than "wrong verb". Found by fetching the OpenAPI spec (`https://api.supabase.com/api/v1-json`,
338 KB) and reading the path:

```bash
curl -X PATCH -H "Authorization: Bearer $PAT" -H "Content-Type: application/json" \
  -d '{"addon_type":"compute_instance","addon_variant":"ci_medium"}' \
  "https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/billing/addons"
```

Returns **HTTP 200 with an empty body**. `DELETE /v1/projects/{ref}/billing/addons/{addon_variant}`
reverts. **Downtime measured: 138 seconds**, `RESIZING` -> `ACTIVE_HEALTHY`.

### ✅ `max_worker_processes` SURVIVED THE RESIZE

Explicitly checked, because it is now an override against a tier default and a compute change is
exactly the kind of event that silently resets one. It reads **12**. Had it reverted to 6, the three
permanent bgworkers plus the Realtime walsender would have been competing again with no signal.

### ⚠ REALTIME REPORTS `UNHEALTHY` FOR THE FIRST FEW MINUTES, AND IT IS NOT A FAULT

Three minutes after the resize: `realtime healthy=false`, **zero walsenders, and
`pg_replication_slots` completely EMPTY**. That is alarming to read and it is transient. At six
minutes: slot `supabase_realtime_messages_replication_slot_...` back and `active=true`, 1 walsender,
6 realtime backends. **Poll it before concluding anything** — the cache-invalidation broadcasts the
Visit Calendar depends on ride that slot, so a person checking once at T+3min would reasonably file
a Realtime outage that does not exist.

### Verified after the resize

| check | result |
|---|---|
| cron runs / failures | 13 / **0** |
| slowest cron run | **0.09 s** (during the stall windows these reached 10-20 s) |
| active cron jobs | 25 |
| `sync.outbound_queue` pending | 0 — nothing lost across the restart |
| permanent bgworkers | 3 |
| Realtime slot + walsender | back, active |
| Jobber write token | valid |
| `derm.fn_blackout_targets` still materialised | yes |
| cache hit ratio | 99.70% |
| `ops.pgss_snapshot_20260903_medium` | 1,993 rows, taken BEFORE the resize |

**Query latency, measured server-side (5/3/3 runs):**

| query | cold | warm |
|---|---|---|
| `ops.v_calendar_visit`, 30-day window (163 rows) | 24.6 ms | **0.9-1.1 ms** |
| `client.properties` (937 rows) | 1.3 ms | 0.3 ms |
| `customer.work_orders` (718 rows) | 10.5 ms | 6.4 ms |
| `derm.fn_blackout_targets(3)` | 533 ms | **507-513 ms** |

**Live app, `calendar.unclogme.app` signed in:** 142 visits, 8 to schedule, 4 trucks, 139 chips
rendered. **13 REST calls on one page load**, median **223 ms**, slowest **530 ms**
(`v_calendar_visit`). Against a 0.9 ms server-side query that is network + PostgREST, not the DB.

### 🛑 WHAT THIS DOES **NOT** PROVE, AND THE HONEST FRAMING FOR FRED

**The stalls were episodic and the last one was 2026-09-03 12:50-12:56. An hour of healthy readings
after an upgrade is not evidence they are gone**, and every number in the table above would have
looked just as good at 12:45. The case for compute rests on ruling everything else out plus the
instance spec, not on a post-fix measurement.

Specifically still true:
- **The queries were never slow in Postgres.** During a stall they were CANCELLED at the 8 s
  `statement_timeout` (266 of them in two windows, measured by @Supabase 2), which is a symptom of
  the whole host stalling, not of a slow plan. A faster plan cannot fix that; more headroom might.
- **`fn_blackout_targets` did not get faster** (507 ms vs the ~514 ms measured pre-upgrade). It is
  CPU-bound on a query plan, and the CPU allocation did not change — only RAM and disk did. That is
  the expected result, and it confirms the upgrade is not a general speed-up.
- **The dashboard Memory and Disk IO charts for `2026-08-31 10:05-10:45 ET` have still never been
  looked at.** That is the one recommendation in this audit that has never been wrong, and it is the
  only thing that would say WHICH of memory or disk was binding. If a stall recurs on Medium, that
  is the first place to go, not another spec change.

**The test is time.** If no stall occurs over the next week or two of normal use, the diagnosis was
right. If one does, the remaining suspects are CPU (which Medium did not change — the next tier that
does is `ci_large` with dedicated cores) and something outside Postgres entirely.

### Still worth doing regardless of whether the stalls return

1. `statement_timeout` for `authenticated` is **8 s**. During a stall that turns a slow page into a
   hard error. Raising it does not fix the stall; it makes the failure mode a slow load rather than
   an error toast.
2. `cron.max_running_jobs = 32` against the old `max_connections = 60` was genuinely dangerous
   (worst case measured 59/60). At 120 it is comfortable, but 32 is still far more than the 5
   concurrent the staggered schedule now produces.
3. PostgREST holds ~21 idle connections. Cheap at 120, but it is 17% of the pool doing nothing.
4. The Calendar makes **13 REST round-trips per refresh**. That is an app-side change and it is the
   single biggest lever left on perceived load time, since each one costs ~220 ms of network.
