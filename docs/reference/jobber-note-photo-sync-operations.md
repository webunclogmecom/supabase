# Jobber note-photo sync: how it runs, how long it takes, and how it fails

*The attribution rule (which photo belongs to which visit) lives in
[`jobber-note-photo-attribution.md`](./jobber-note-photo-attribution.md). This file is the
operational half: cadence, duration, failure modes, and the health check.*

Measured 2026-09-07/08 over the workflow's complete 511-run history.

---

## 1. It is NOT a pg_cron job. Do not look for it in `cron.job`.

```
.github/workflows/jobber-note-photo-sync.yml  ->  scripts/sync/sync_jobber_note_photos.js
```

**One workflow, TWO cron triggers, one script, different look-back:**

| trigger | arg | visits/run | purpose |
|---|---|---|---|
| `0 */6 * * *` | `--days=14` | ~95 | **the guarantee.** Re-reads two weeks every time, because photos get added to OLD notes days later |
| `30 * * * *` | `--days=3` | ~26 | **freshness only.** Added 2026-08-18 so a photo taken right after a visit is not invisible for 6h |

The `:30` offset exists so the two never fire in the same minute at 00/06/12/18 UTC (20:00, 02:00,
08:00, 14:00 ET).

⚠ **A missed hourly run loses NO DATA.** The 3-day window means the next run picks it up, and the
14-day sweep is a second net. It costs latency, not photos.

---

## 2. How long it takes

| | hourly `--days=3` | 6-hourly `--days=14` |
|---|---|---|
| whole GitHub job | p50 **0m33s** | p50 **1m52s** |
| the sync script alone | p50 0m18s | p50 1m38s |
| when it finds nothing | ~0m15s | ~0m55s |
| when it imports photos | ~0m51s | ~2m31s |
| p90 | 1m29s | 5m19s |
| worst ever | 10m03s | **21m34s** |

**Cost model:** `1.6s fixed + 0.74s per visit checked + 4.0s per photo downloaded`. The script is
fully sequential: one Jobber GraphQL call and an 80ms sleep per visit, then a download-plus-upload
per new photo. About 11s of every run is GitHub overhead (checkout, setup-node, npm install).

The 45-minute timeout has never been close: the worst run used 48% of it.

---

## 3. 🛑 GitHub throttles sub-hourly crons in this repo. The hourly trigger delivers ~25%.

Measured across every scheduled workflow here, all of them converge on roughly the same low number
of delivered runs per day regardless of what their cron asks for:

| workflow | asks | delivered/day |
|---|---|---|
| `audit-critical-poll` | 288/day | ~7 |
| `samsara-poll` | 144/day | ~7 |
| `mirror-derm-pdfs-to-storage` | 96/day | ~7 |
| `jobber-note-photo-sync` (both triggers) | 28/day | ~10 |

The repo asks for ~800 scheduled runs/day and is delivered ~70. Daily and weekly crons deliver 100%.
A GitHub Actions incident on **2026-08-26 15:11 UTC** ("we've throttled inbound traffic",
"per-customer concurrency limits") coincides with a sharp step down, and delivery has been slowly
recovering since.

🛑 **This is why three other syncs already moved to pg_cron**, each with the reason written into the
workflow file: `jobber-poll` (*"GitHub throttled this */2 to ~2-3h gaps"*), `jobber-upcoming-visits`
(*"immune to GitHub's scheduler throttling"*), `reconcile-jobs` (*"GitHub throttles sub-hourly crons
unreliably"*). **The note-photo sync is the last sub-hourly Jobber sync still on GitHub's scheduler.**
Moving its hot window to an edge function on pg_cron is the known fix and would also remove every
failure below. Not done.

---

## 4. 🛑 Every failure is the same failure, and it is invisible in the database

**39 of 511 runs (7.6%) failed. All 39: `FATAL DB 429: ThrottlerException` from the Supabase
Management API.** Not Postgres, not Jobber. Concentrated where the work is: **12.8%** of full sweeps
versus **2.0%** of hourly runs.

The Management API only exists in this script because a GitHub runner has no database connection. A
days=14 run makes ~97 Management API calls, dominated by one per-visit query inside the loop.

🛑 **A failed run never reaches its `sync_log` INSERT, and the INSERT's own error is swallowed by
`.catch(() => {})`.** So `sync_log` is ~36 rows short of reality and **a failed run is
indistinguishable from a run GitHub never fired.** Same class as
`reference_pg_cron_success_is_structurally_blind`.

⚠ **Nothing is lost.** Every fatal lands on a read, writes sit in per-attachment try/catch, and the
next run re-diffs. Verified: 519 photos committed inside the 39 failure windows, **0 still unlinked**.
The cost is a median 5h26m healing lag.

---

## 5. 🛑 `sync_log` cannot tell you how long a run took

`duration_seconds` is **NULL on all 475 rows** and `finished_at` always equals `started_at`, because
the script writes `VALUES (now(), now())` in one statement at the end. Twelve of the other fifteen
`sync_source` values DO record real durations, so the column works; this job just never fills it.
**Duration has to come from GitHub Actions.**

---

## 6. Photos ARE being captured. One narrow hole.

Measured against Jobber directly: **0 of 209 rule-owned attachments missing** across a 17-visit
sample, 0 wrong-visit links, 0 stale links. The ±2 day window is correct and its leak since shipping
is **3 photos on 1 note**. The remove path has never fired because no attachment has ever been
deleted from a note, not because it is broken (proven with synthetic pairs).

**The hole was oversized video. FIXED 2026-09-08** (`2026-09-08_0300`, commit `46ed1fd`).

It used to be one branch that skipped any attachment over the 50MB bucket limit while incrementing
**neither `added` nor `errors`**, reaching no counter in `sync_log.details`. **A permanent failure was
byte-identical to a quiet day**: six field videos, 915MB, five clients, over 8 days. The one message
conflated two unrelated causes, and `att.fileSize && ...` was silently permissive, so a null or zero
size fell *through* the guard into a download attempt.

Now:

| before | after |
|---|---|
| `skip <file> (no url / oversized)` | `skip <file> OVERSIZED 410159322 bytes > 52428800 limit` **or** `NO_URL` |
| no counters | `oversizedSkipped` / `noUrlSkipped` in the DONE line **and** in `sync_log.details` |
| nothing recorded | a row in `public.jobber_oversized_attachments` with the new `skip_reason` |
| invisible | the health check reports `oversized_attachments` in `ops.v_health_items` |

🛑 **The basin write uses `ON CONFLICT DO UPDATE`, not `DO NOTHING`, and that is the point.**
`jobber_url_signed` is a presigned S3 url and it **expires**. The 58 rows the migrate script wrote
were never refreshed, every url is dead, and **the basin had never recovered a single file**. The sync
re-encounters the same attachment ~10x/day, so refreshing on conflict is what makes the row able to
hand someone the file. `logged_at` is deliberately not refreshed, so it still means **first seen** and
the health check's 7-day window flags NEW losses rather than the permanent backlog.

Verified against visit 6105 (062-TCE), whose 410,159,322-byte video had been skipped silently for
weeks: basin 58 -> 59 rows, `skip_reason='OVERSIZED'`, size and visit recorded, a live url stored,
`oversizedSkipped: 1` in `sync_log`, health check moved to **warning**.

⚠ **The 50MB limit itself is unchanged and correct** (largest successfully stored photo: 49.4MB).
This makes the loss visible and the file recoverable; it does not ingest the video. Whether large
video should be stored at all is a product decision.

⚠ **Still true:** the note's `entity_source_links` row is created *before* the skip, so the migrate
script's idempotency check still skips that note. That no longer matters, because the sync now writes
the basin itself rather than depending on the migrate script to do it.

---

## 7. The health check

`public.log_jobber_note_photo_health()` on pg_cron **`note-photo-sync-health`, every 6h at :35**,
reading `public.v_jobber_note_photo_health` and writing a `sync_log` row that surfaces in
`ops.v_health_items`.

| condition | threshold | why that number |
|---|---|---|
| `full_sweep_stale` -> **attention** | no `days=14` run in **24h** | measured gap: avg 6.9h, p90 11.2h, **max 17.5h** over 103 intervals. 24h means four cycles missed. |
| `all_runs_stale` -> **attention** | nothing at all in **12h** | both triggers together deliver ~10/day |
| `hot_window_collapsed` -> **warning** | fewer than **2** hourly runs in 24h | ~6 of 24 is NORMAL here (section 3), so only a collapse is worth flagging |
| `oversized_backlog` -> **warning** | any attachment skipped for size in the last **7 days** | added 2026-09-08. Keyed on `logged_at` (first seen), so it flags NEW losses and clears on its own rather than warning forever about the standing backlog |

⚠ **It measures DELIVERED RUNS, not attempts** — see section 4. It can tell you photos stopped
flowing; it cannot tell you why.

⚠ **`ops.v_health_items` and `ops.v_health_status` each carry their OWN hardcoded copy of the source
list and the items CASE.** A new check is invisible until BOTH are edited.

*Migration: `2026-09-08_0230_note_photo_sync_health_check.sql`.*
