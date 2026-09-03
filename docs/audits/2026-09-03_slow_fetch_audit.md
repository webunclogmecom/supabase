# Slow-fetch audit, 2026-09-03

**Fred:** *"this and past week it have been working slowly... the apps loads up fast enough, but the
data to display takes too long to be displayed, like the fetch takes too long from time to time."*

Read-only audit. Nothing was changed.

---

## Verdict in one line

**The database is not generally slow. It stalls in short episodes, and separately it is spending
31.8% of all its execution time on one query that returns zero rows.**

---

## 1. 🛑 The single biggest finding: a third of the DB's work finds nothing

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
defect is that establishing that costs 2 seconds. Worth pointing at whoever owns
`derm.fn_blackout_targets`: an early-exit or an index that lets it answer "nothing pending" cheaply
would return roughly a third of the database's capacity.

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

1. **Fix `derm.fn_blackout_targets`.** It is 31.8% of all database time for zero work, it costs
   nothing to fix relative to the return, and it needs no infrastructure decision.
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
