# Does a Stamp Studio "complete" block other apps' reads? Audit, 2026-09-30

**Fred:** *"when a manifest at the Stamp App, is marked as complete it goes to the blackout process,
but that is a blocking action on the DB that blocks the READ of other apps to the DB meaning they
stay stuck waiting for data ... Take note that this is a guess ... if it's wrong do an audit to see
why sometimes it takes time for the data to be fetched from the apps, like there is something on
the queue at the DB that's blocking the operations."*

The trigger: right after he completed `ticket-836624` in Stamp Studio (15:31:02 ET), the DERM
Tracker `/manifests` page sat on skeletons for about 30 seconds.

Everything here was measured read-only, except ONE rolled-back probe of the complete path (section 2).
Six investigations ran in parallel, then two adversarial verifiers tried to refute the two
conclusions. Claim 1 survived. Claim 2 survived on WHERE the time went and was corrected on three
qualifiers; the corrected wording is what appears below.

---

## Verdict

1. **The guess is wrong about the cause.** Completing a sheet and the blackout sweep it starts take
   only row-level locks, which never block a plain read. The database answered every slow request in
   milliseconds. The slowness began **2 min 13 s BEFORE** the completion, and the worst episode of the
   week (09-28) had no completion and no sweep at all.
2. **The slowness was real, and it was in front of the database.** The network path from Cloudflare's
   **Miami** location (MIA) to the Supabase API gateway slowed down for about five minutes
   (15:28:49 to about 15:34 ET). Over that window **every** request on it got about 200 ms slower,
   and **15% stalled for seconds (up to 56 s)**. The stalls came clustered within bursts, not at
   random. In the same seconds the same instance served our edge functions (Cloudflare IAD,
   Virginia) normally. Supabase has an **open incident** for exactly this: *"Intermittent latency in
   Eastern US"*, API Gateway, since 2026-09-29 16:26 UTC.
3. **Why one stall blanks a whole page:** DERM `/manifests` waits for all 7 of its reads before it
   renders anything, and none of our apps puts a timeout on a read. One read held 29 s in transit
   (29 ms in the DB) meant 29 s of skeletons.
4. **The DB CAN block reads, but the only case this week was one of OUR migrations**, not a
   completion: 2026-09-24 16:01 ET, `CREATE OR REPLACE VIEW derm.visits` followed by a ~27 s VERIFY
   in the same transaction. DERM reads of `derm.visits` waited, and 4 failed with HTTP 500 at the 8 s
   statement timeout. See section 5.

---

## 1. The 09-30 timeline (edge logs, ET)

"DB" = `x_envoy_upstream_service_time` (PostgREST + Postgres + the gateway's pool wait and connect).
"total" = Cloudflare's `origin_time`. The difference is time spent between Cloudflare and the gateway's
router: network, TLS, gateway filters. It is NOT database time.

| time | request | total | DB |
|---|---|---|---|
| 15:28:49 | Picture Planner `/auth/v1/user` (first stall) | 4,072 ms | 12 ms |
| 15:28:54 | Stamp `/auth/v1/.well-known/jwks.json` | 6,523 ms | 0 ms |
| 15:29:45, 15:30:02, 15:30:27 | `set_sheet_completed` on **ticket-836361**, refused 400 (`needs_snap_then_extent`) before any write | | |
| **15:31:02.547** | **`set_sheet_completed` ticket-836624** (the completion) | **237 ms** | **18 ms** |
| 15:31:34 to :37 | the blackout sweep it kicked: `fn_blackout_targets`, one redacted page written | | 659 ms |
| 15:31:39.923 | Stamp `v_stamp_rows` (5 siblings sent in the same 7 ms: 250-860 ms) | **56,505 ms** | 22 ms |
| 15:31:58.626 | DERM `derm_manifests` (the other 6 page reads were done by 15:32:01) | **28,957 ms** | 29 ms |
| 15:33:01.8 | DERM page reload: 4 of 7 reads | 2.8 to 14.7 s | 7 to 601 ms |
| 15:33:10.6 | Calendar refocus: 11 of 13 parallel reads | 1.5 to 6.2 s | 2 to 149 ms |
| after ~15:34 | clean again | | |

The stall durations climb in a doubling series (about 1.2, 3, 6 to 7, 14, 29, 56 s). That fits
retransmission backoff on a lossy link. It is suggestive only; we cannot see which layer retried.

## 2. The complete path takes no lock that blocks a reader (proven)

- **Rolled-back probe** (15:54:31 ET, `ticket-111111`, completed=false, no blocker): the real
  `derm.set_sheet_completed` ran inside a DO block that listed its own `pg_locks` and then raised, so
  nothing committed. Duration 21.3 ms. The strongest lock was **RowExclusiveLock** (on
  `derm.stamp_sheet_status`, `audit.logs` + partition, `net.http_request_queue`). There was no Share,
  Exclusive or AccessExclusive lock and no advisory lock. Checked afterwards: row unchanged, queue
  empty, no audit row. A plain SELECT waits only for AccessExclusiveLock.
- **Code read:** `set_sheet_completed`, all 5 triggers on `derm.stamp_sheet_status`,
  `fn_request_blackout_sweep` (a pg_net POST), `fn_blackout_targets` (STABLE, SELECT only) and the
  `redact-manifest-sheet` edge function (PostgREST row writes + Storage). None of them contains DDL,
  LOCK, REFRESH, TRUNCATE, VACUUM FULL, advisory locks or long transactions.
- **Live sampling:** 118 samples of `pg_stat_activity`/`pg_locks` across 3 sweep ticks that each
  redacted a page (15:53, 15:58, 16:03): 0 waiters. A **positive control** (two sessions contending
  on a private advisory lock) was caught by both the sampler and `postgres_logs`, so the zeros are real.
- **Logs:** `log_lock_waits = on`, `deadlock_timeout = 1 s`. In 7 days of `postgres_logs`: 6 lock
  waits over 1 s, **all** on 09-24 16:01 (section 5), **0 on 09-30**. 0 deadlocks ever.
- **Live probe:** the DERM `/manifests` reads were replayed every 10 s for 16 minutes across 4 real
  sweeps (1,010 GETs). Median 230 ms, max 1,658 ms. Reads in the 90 s after a sweep were no slower
  than at other times (visits DB time 660 vs 638 ms). The 16 concurrent server requests during the
  15:31:34 sweep had 2-9 ms DB time.
- `pg_stat_statements` since 09-03: across 2.02M PostgREST calls the slowest statement took 3.8 s.
  None exceeded 8 s. `set_sheet_completed`: 18 calls, mean 16.6 ms.

## 3. Where the time actually went

- On 09-30, during the episode, **Cloudflare MIA** traffic had 46 of 303 requests over 1 s, with a
  median gap of 201-257 ms (normally about 35 ms). **IAD** in the same minutes had 2 of 384, with a
  median of 16-25 ms. MIA had 0 stalls from 13:33 to 15:21 and from 15:36 to 16:06.
- Of the 26,280 requests since the gateway header appeared today, 15 had DB time over 1 s (max
  1.5 s), and **193 had a gap over 1 s**.
- GoTrue served all 977 jwks responses in under 5 ms and all 5,257 `/user` responses in under 250 ms
  (its own metrics), yet the edge recorded 4 to 6.5 s for some of them.
- The instance was idle: ~3% CPU over 27 days, no swap-ins, no OOM kills, NIC drops 0,
  `pgrst_db_pool_timeouts_total` 0.
- **09-28 15:50-15:59 ET** was the week's biggest episode: 268 browser requests over 1 s, max 57 s.
  It had no completion and no sweep with work, and Postgres logged nothing. It matches Cloudflare
  incident `32sg73xwyq89` ("Network Performance Issues in Eastern North America", 19:50-20:20 UTC)
  to the minute. (The gateway header did not exist yet on 09-28, so DB time cannot be separated for
  that day. Postgres being silent while requests returned 200 after 30-57 s points outside it.)
- **Supabase incident `w91bvbjhqf0f`**, still open: *"increased latency for clients in the eastern US
  during spikes caused by bursty traffic"*, *"most noticeable during EDT working hours around the :00
  and :30 hour marks"*, and *"We have tied the issue to a particular PoP"* (the PoP is not named).
  Fred's episode straddles 15:30.
- **The statistic behind Fred's guess:** counting each event once, 1 of 5 completions and 6 of 35
  page-writing sweeps since 09-22 had a stall in the next 5 minutes. A random 5-minute window with
  browser traffic has one 10% of the time. That is chance level (P = 0.41 and 0.13). Sweeps outside
  Fred's episode: 0.34% slow requests near them vs 0.41% elsewhere.
- **Frequency:** from 09-23 to 09-30, 71 of 109,251 browser requests took over 5 s. All 71 fell inside
  three episodes (two gateway, one migration).
- **Server callers (edge functions, IAD)** have a separate, smaller tail of 1-4 s gaps. It bunches in
  the first seconds of a minute (5.7% at second 0 vs about 0.5% elsewhere) and after idle periods.
  It is a different shape from the MIA episodes.

## 4. Our own amplifiers (things we control)

1. **All-or-nothing page:** DERM `/manifests` is one react-query `Promise.all` over 6 read chains
   (7 GETs) behind one `isLoading`. One stalled read = the whole page on skeletons.
2. **No timeout, no retry:** no app passes `global.fetch` to `createClient`, and none calls
   `.abortSignal()`. react-query only retries a request that throws, and a stalled request never
   throws. Replaying 15:28-15:34 with "abort a GET after 5 s and retry it once" cuts the 29.1 s
   skeleton to about 5.6 s. ⚠ That figure is modelled, not measured, because stalls come in bursts
   and a retry inside an episode can stall too. It does NOT cover read RPCs sent as POST
   (`calendar_drive_days` stalled 2.6 and 3.9 s) or server-side callers.
3. **Refetch fan-out:** DERM and the Calendar call `invalidateQueries()` with NO filter on every
   realtime broadcast. At 15:33:09-18 an edge function sent 25 single-row `PATCH visits` that
   rewrote identical values (audit.logs skips them as no-change, but the FOR EACH STATEMENT broadcast
   trigger fires anyway), so DERM made 72 requests and the Calendar 78 in a few seconds, right inside
   the episode. On 09-28 one Calendar client reached about 1,000 requests a minute.
4. **Stamp Studio:** it calls `/auth/v1/user` twice on every studio remount, and it refetches
   `v_stamp_sheets` (select=*, limit 500, ~500 ms DB) on every remount and on every
   `derm_manifests`/`address_row_map` broadcast. That is 84% of Stamp's DB time. `v_stamp_sheets`
   calls `derm.ticket_page_images` **twice per row** (two output columns), so 381 ms of the ~500 ms
   goes to `_img_etag`.
5. **supabase-js 2.105.4 (DERM, Calendar)** holds the navigator auth lock across `getUser()`, so a
   stalled `/auth/v1/user` would hold every read in that tab. Stamp (2.110.0) has no lock.

## 5. The one real DB block this week: a migration pattern

2026-09-24 16:01:20 ET, migration `2026-09-24_1615_derm_visits_grey_water_pumping_own_lines_first`:
`CREATE OR REPLACE VIEW derm.visits` (AccessExclusiveLock on the view, held until COMMIT), then a
`DO $verify$` of about 27 s in the same transaction. DERM's reads of `derm.visits` queued behind it:
6 "still waiting for AccessShareLock on relation 43008" lines, 4 cancelled at the 8 s statement
timeout (HTTP 500 in the app), 2 acquired after 3.4 and 4.0 s. `pg_stat_statements` holds other
VERIFY blocks of 25.6-27.2 s. A dry run that rolls back holds the lock just as long.
**Rule added to `Supabase/CLAUDE.md`:** keep DDL on an app-read view in a short transaction.

## 6. Separate live bug found on the way: Stamp Studio's printed-rule guides are blank

Every Stamp read of `derm.v_page_printed_rules` returns 403 (41 of 41 today, `42501 permission denied
for function _is_rule_source`). `2026-09-14_0610_template_rules_precedence.sql` pointed the view at
`derm._is_rule_source(text)`, whose ACL is `{postgres=X/postgres}` (revoked from PUBLIC on 09-02). Postgres
checks EXECUTE on a function inside a view against the CALLER, even for an owner-rights view. The
migration's VERIFY ran as postgres, which is why it passed. Both Stamp call sites swallow the error,
so the guides have silently shown nothing since 09-14. Re-verified 2026-09-30 with
`set local role authenticated`: denied. **Not fixed here** (read-only audit).

## 7. pgaudit FUNCTION logging (a real cost, not the cause)

`authenticator` and `service_role` log the `function` class. That is **94% of all Postgres log
lines** (9.4M in 34 days, 5.2 of 5.7 GB), and 88% of it is `derm._img_etag`: about 228k lines a
day, with a cron-driven floor of about 180-220k even on weekends. It adds a measured **+54 ms median
(+10%)** to the Stamp list query (29 interleaved runs each, `SET LOCAL pgaudit.log`, identical result
hashes). It does NOT explain the stalls: that cost is inside the DB time, which was small, and
per-minute log volume vs other apps' latency gives r = 0.007 to 0.13. No script or alert reads the
FUNCTION lines. Dropping `function` (keeping `ddl, role, write`) is an ADR 010 decision for Fred.

---

## Options (none applied; Fred decides)

| # | change | effect | size |
|---|---|---|---|
| A | GRANT EXECUTE on `derm._is_rule_source(text)` to `authenticated` (or put the literal patterns back in the view, as the 09-02 comment prescribes) | Stamp printed-rule guides work again | one migration |
| B | Fetch wrapper in the shared-session `createClient`: abort an idempotent GET after ~5 s, retry once; never retry POST/PATCH/DELETE, `/auth/v1/token`, functions, storage | turns 30-60 s skeletons into ~5 s in an episode (modelled) | shared module + 8 publishes |
| C | Filtered `invalidateQueries` in DERM/Calendar; skip identical-value `PATCH visits` in the edge function that sends them | fewer requests exposed to a stall | app + edge fn |
| D | Compute `ticket_page_images` once per row in `v_stamp_sheets`; stop Stamp refetching the list on every remount | ~halves the Stamp list query | view + app |
| E | Drop `function` from pgaudit on authenticator/service_role | -94% log volume, -10% on heavy queries | ADR 010 decision |
| F | Supabase support ticket citing incident `w91bvbjhqf0f`, colo MIA, the request ids below | only Supabase can fix the path | outward message, needs Fred's OK |

Request ids for a ticket (09-30, UTC = ET + 4): `01a0f3cd-1913-751f-a9d9-d30619112603` (56.5 s),
`01a0f3cd-6222-72ad-8371-3d5f5b41b9d0` (29.0 s), `01a0f3ce-5908-717f-9531-053922e8ac77` (14.7 s),
`01a0f3cd-49f8-794d-b6ce-d1c2e1b8dcc4` (8.6 s).

## How to re-run (logs API)

⚠ `GET /v1/projects/{ref}/analytics/endpoints/logs.all` now returns **410 Gone**. Use
`/analytics/endpoints/logs?sql=...&iso_timestamp_start=...&iso_timestamp_end=...` (24 h max, about
1,000 rows max, so aggregate). The SQL is ClickHouse over ONE table `logs`, filtered on `source`:

```sql
-- the gap: time between Cloudflare and the gateway's router, per request
select timestamp, log_attributes['request.path'] p, log_attributes['request.headers.referer'] ref,
       toFloat64OrNull(log_attributes['response.origin_time']) total_ms,
       toFloat64OrNull(log_attributes['response.headers.x_envoy_upstream_service_time']) db_ms,
       log_attributes['request_id'] rid
from logs where source = 'edge_logs'
  and toFloat64OrNull(log_attributes['response.origin_time'])
    - toFloat64OrNull(log_attributes['response.headers.x_envoy_upstream_service_time']) > 1000
order by timestamp
```
Run it with `node scripts/probes/edge_logs.js "<sql>" <outfile> <isoStart> <isoEnd>` (bounds required,
exit 3 when the server's 1,000-row cap was hit; a smaller `limit` of your own truncates without that
signal, so leave it off or count first). ⚠ Use `toFloat64OrNull`, not `toInt32OrZero`: a missing map
key returns `''` silently, and OrZero turns "no DB timing recorded" into "0 ms in the DB", which
inflates the gap. Re-checked null-safely on 2026-09-30, over non-OPTIONS rest/auth requests
(preflights never carry the header): in 15:28-15:35 ET all 687 carried it, 48 had a gap over 1 s,
12 over 5 s, and **0 spent over 1 s in the DB**. Over 08:40-16:40 ET, 1,595 of 28,166 lacked it
(1,594 of them before 10:00 ET, the rollout morning), 195 had a measured gap over 1 s, 10 had DB
time over 1 s.

⚠ `x_envoy_upstream_service_time` only exists from **2026-09-30 08:41 ET**. Before that, only
`origin_time` exists, and it cannot separate DB time from path time. OPTIONS preflights never reach
the origin (origin_time 0), so they are not a control for the gateway leg. The endpoint's other traps
(no default window, a >24 h span silently clipped, the silent 1,000-row cap, errors inside an HTTP 200,
10 calls per 60 s per token) are handled and documented in `scripts/probes/edge_logs.js`.

```sql
-- lock waits: with log_lock_waits on, zero lines = no wait over deadlock_timeout (1 s)
select timestamp, event_message from logs where source = 'postgres_logs'
  and (event_message like '%still waiting for%' or event_message like '%canceling statement%')
order by timestamp limit 200
```

Instance metrics: `https://<ref>.supabase.co/customer/v1/privileged/metrics`, basic auth
`service_role:<service key>`. Snapshots refresh every 60-90 s. No TCP, conntrack or ENA allowance
counters are exposed.
