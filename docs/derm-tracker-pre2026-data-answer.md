# Answer — DERM Tracker pre-2026 manifests (Supabase session, 2026-06-01)

Reply to `Building Apps/DERM Tracker/docs/pending-supabase-question-pre2026-data.md`.
Diagnostics: `Supabase/reports/_derm_pre2026.json` + `_derm_health_split.json`
(probe `scripts/probes/_derm_pre2026_diagnostics.js`).

> ## ✅ RESOLVED 2026-06-01 — by deletion, NOT by filtering
> Fred chose to **remove** the historical data rather than scope the app to it. The **598 pre-2026
> DERM manifests were backed up** (`Supabase/docs/backups/derm_manifests_2025_backup_2026-06-01.json`,
> 1.04 MB — manifests + dependent rows) and then **hard-deleted** from Prod. `public.derm_manifests`
> is now **2026-only (977 → 379)**; visits were already 2026-only. **DERM Tracker therefore shows only
> 2026 automatically — NO app change is needed** (do not add a year filter or "Historical backlog"
> tab; there is no pre-2026 data left). The analysis below is kept for the record.

## TL;DR

**The pre-2026 data is legitimate historical DERM compliance — do NOT hard-filter or purge it.**
It's a one-time Airtable backfill from the 2026-04-29 DB do-over (AT is canonical for
`derm_manifests`). The right scoping is an **app default-view** (default to current year, older
reachable), **not** a `derm.*` view filter or a sync change. That routing matches the brief: data
scoping stays here (answered: keep it), the default-view is the Building Apps session's to set.

## The 5 questions, answered

**1. How far back / count by year** — 977 manifests total. **2025: 598 (61%)**, **2026: 379**.
Service dates span **2025-03-20 → 2026-05-27**. (Neither `derm.manifests` nor `derm.manifest_health`
filters — both return all 977; anon has a permissive read policy and sees all 977, so the app's
"227" is its own already-built default filter, not RLS.)

**2. Pre-2026: real open gaps vs just old/complete** — of the 598 pre-2026:
- **525 are `fully_complete`** (88%) — old, documented, done. Pure list clutter.
- **73 are "unhealthy"** (12%): 50 `has_number_no_pdfs`, 21 `partial_other`, 2 `has_pdfs_no_number`,
  **0 `empty_placeholder`**.
- **The work queue is 91% pre-2026:** the app's Health queue (`health_state <> 'fully_complete'`) is
  **80 total — 73 pre-2026 + only 7 from 2026.** Current-year operations are 98% clean.
- **These 73 are NOT active "never filed" gaps.** 50/73 already have a DERM manifest NUMBER (so they
  were filed with the city) but no PDF scan in our system. **72 of 73 cluster in March–April 2025**
  (36 + 36; the 73rd is Oct 2025) — the very start of the dataset. **0 of 73 are linked to a visit;**
  69/73 belong to active clients. Read: **document-scan backfill gaps from the earliest period**, not
  live operational misses.

**3. Where the pre-2026 data comes from** — a **one-time Airtable backfill** during the **2026-04-29
DB do-over**. Every one of the 977 rows has `created_at` in 2026; `entity_source_links` first_seen =
2026-04-29; 971/977 carry an `airtable` source link. **Not stale/test rows; not an ongoing sync of
old data** (the AT pipeline is sunsetting). AT is the canonical DERM source, so this is real history.

**4. Intended scope** — Fred has stated current-year (2026) operations. (If the intent were
"manage all historical DERM compliance," the answer flips to *keep showing everything* — please
confirm, but the recommendation below assumes current-year.)

**5. Where scoping should live** — **app default-view only.** Specifically NOT:
- ❌ **`derm.*` view year filter** — would permanently hide the 73 older gaps from the Health queue =
  masking real (if old) incompleteness. The exact anti-pattern the brief flagged. Keep views exposing all.
- ❌ **Sync filter** — it's a one-time backfill; no new old rows arrive; AT is sunsetting anyway.
- ❌ **Purge / archive flag** — it's canonical historical compliance data; keep it.
- ✅ **App default-view** — default DERM Tracker to current-year, older reachable via the date filter
  that's already built.

## Recommendation (boundary routing)

**Supabase session owns (DONE — no change needed):** the data is legit; `derm_manifests` keeps all
977 rows; the `derm.*` views correctly expose everything; no sync/purge/flag. Nothing to mutate.

**Building Apps session owns (the actual change):** default both surfaces to current year, keep older
reachable —
- **`/manifests` list:** default to 2026; the 598 pre-2026 rows (mostly complete) are just clutter at
  the bottom. Cosmetic.
- **`/manifests/health` queue (the important one):** default to current year so the **7 real 2026
  gaps** are visible instead of buried under 73 backfill-era items — but keep a **"Historical backlog
  (73)"** toggle/tab so they're **not hidden**, just not masquerading as the live queue.

Since `service_date` is exposed (ISO `YYYY-MM-DD` text, sorts correctly), the app can filter
`service_date >= '2026-01-01'` directly — no DB change required.

## ⚠️ Time-sensitive, separate from the scope question

The 50 `has_number_no_pdfs` manifests (have a DERM number, missing the PDF scan) likely have those
scans as **Airtable attachments** — and **AT sunsets this week.** If we ever want to close those gaps,
we must pull the PDFs from AT into Supabase Storage **before sunset**, or they may be unrecoverable
(same risk class as the Jobber-notes→photos migration). This is a data-completeness task, independent
of the app-scope decision. The Supabase session can verify whether those AT records have attachments
and migrate them if so — flag if you want this run now.

---

## Paste-ready block to relay to the Building Apps session

> **From the Supabase session, 2026-06-01 — two things.**
>
> **(1) Pre-2026 data — resolved by deletion, no app change needed.** Fred chose to delete the
> historical data rather than filter it. The 598 pre-2026 DERM manifests were backed up + hard-deleted;
> `public.derm_manifests` is now **2026-only**. DERM Tracker shows only 2026 automatically — **do NOT
> add a year filter or a "Historical backlog" tab; there's no pre-2026 data left to scope.** (Restore
> source if ever needed: `Supabase/docs/backups/derm_manifests_2025_backup_2026-06-01.json`.)
>
> **(2) Found an app data-quality gap — small Bulk Upload fix, please.** While cleaning DERM data I
> found the form let bad manifests through: **7 manifests with no client** (incl. `#825560` saved
> **5×** and a test `#44444444`, all 5/27, app-sourced — no Airtable link), and one row that linked
> **5 different clients' visits to a single manifest**. I cleaned them DB-side (relinked the 1 real
> one, removed the test/dups). To stop recurrence the form should **(a) require a client before a
> manifest can be saved**, and **(b) keep one manifest = one client** — a shared dump ticket gets one
> row PER client (same number), never one row spanning clients. I can add a `NOT NULL` constraint on
> `derm_manifests.client_id` as a hard backstop once you confirm the form always sets a client.
