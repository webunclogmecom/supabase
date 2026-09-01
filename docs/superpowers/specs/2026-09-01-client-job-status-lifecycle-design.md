# Client App — job actions drive client status (design spec)

**Date:** 2026-09-01
**Author:** Fred (via Claude)
**Status:** approved design → ready for implementation plan
**Apps/repos touched:** Client App (Lovable "Client View Pro" `dbf2133c-539c-48ff-864a-68eb284a569d`) · Supabase Prod `wbasvhvvismukaqdnouk`
**Test client:** 112-YA (the Jobber sandbox test client)

---

## 1. Problem & goals

On the Client App, the job card (see the SA job `#99900756` on 117-BH) lets a user reopen/close/create jobs, but the behavior around **job type**, **confirmations**, and **client status** is wrong or missing:

1. **Legacy (pre-SC/SA) jobs still show a Reopen button.** They should not be reopenable from the app.
2. **Reopen has no confirmation.** Any reopen should confirm first.
3. **Reopening an SA job duplicated its line items** in our DB (price doubled — two `$450.00` + two `$15.89`), while Jobber stayed correct.
4. **No status-transition confirmations exist.** The user wants job actions to move the client between **Active / Recurrent / Inactive**, each with a **dynamic** confirmation that lists the actual jobs/visits affected:
   - Create **or** reopen an SA job on a non-recurrent client → confirm → client becomes **Recurrent**.
   - Close the last open SA job → confirm → client back to **Active**.
   - Close the SC (base) job → confirm → client **Inactive** (all its jobs closed).
5. The three transitions need a **clear, distinct UX** so it's unmistakable which one makes a client Active vs Recurrent vs Inactive.

**Decision (Fred, 2026-09-01):** Client-App **job actions become the human-confirmed authority for `clients.status`.** This *supersedes* the prior rule (Fred, 2026-07-15) that `clients.status` is not authoritative — see §8. Status changes still route through the existing safe RPC (`client.update_client_status`, mandatory reason + audit) and the `archive-client` edge function (Jobber-archive-first for Inactive); no DB trigger silently flips status.

**Non-goals (out of scope):** reactivating an Inactive client by reopening its SC (needs a Jobber un-archive path — deferred); changing PAUSED handling; renaming the ~6 mis-titled live jobs in Jobber (a data-hygiene follow-up, tracked in §5.1).

---

## 2. Current-state findings (verified in code + live data, 2026-09-01)

**Job classification is title-only.** `client.jobs` = `SELECT * FROM public.jobs` (`Supabase/docs/migrations/2026-07-24_client_app_schema.sql:50`); the app classifies client-side:
- **SA:** `title ILIKE 'Service Agreement%'` (edge fn: `isSA = title.toLowerCase().startsWith("service agreement")`, `save-client-job/index.ts:1207`). SA jobs carry job-scoped line items (183/183 live = 100%) and `frequency_days > 0`.
- **SC:** `lower(btrim(title)) = 'service call'`. No frequency, no job-scoped line items (0/278).
- **legacy/other:** anything else (`[OLD]`/`TEST` prefixes, and ~6 odd free-text titles like `'Service'`, `'Emergency call'`, `'Quaterly Hydrojet cleaning'`). No line items.

**Open vs closed** = `public.jobs.job_status`. Closed = `archived` (the only terminal value). Open = everything else (`action_required`, `upcoming`, `requires_invoicing`, `today`, `late`, `active`). ⚠ Do **not** use `archived` to detect legacy — SC/SA jobs archive normally once billed.

**Job lifecycle backend** — the `save-client-job` edge function (`Supabase/supabase/functions/save-client-job/index.ts`), a synchronous verified Jobber saga (mutate Jobber → re-read/verify → write DB); branch on `data.ok`, not HTTP status:
- **reopen** (`index.ts:1191`): `jobReopen(jobId)` (`M_REOPEN`) → `fn_record_client_job({gid, job_status, actor_email})`. **Writes NO line items.**
- **close** (`index.ts:1176`): `jobClose(input:{modifyIncompleteVisitsBy: DESTROY_ALL})` (`M_CLOSE`) → `fn_record_client_job` → `fn_close_job_visits(jobId)` (soft-deletes still-scheduled visits under `app.suppress_jobber_push`). No `jobDelete` exists in Jobber. **Touches no line items.**
- **create** (`index.ts:919`, `patch:{kind:"SA"|"SC"}`): validates, `jobCreate`, verifies, then `fn_record_client_job` with `line_items` from the verified read-back. SC forbids any line item/fee (`index.ts:949`).
- `save-client-job` **never writes `clients.status`** in any path.

**Client status model.** `public.clients.status ∈ {ACTIVE, RECURRING, PAUSED, INACTIVE}`; companion `status_source ∈ {jobber, manual}` (`manual` pins against the `*/5` Jobber poll's revive). App writes go through `client.update_client_status(id, status, reason)` (SECURITY DEFINER, **reason mandatory**, audits `public.client_status_changes`, pins `status_source='manual'`). `RECURRING` is gated by `client.fn_is_current_sa_job()` (a non-`[OLD]` `Service Agreement%` job with `frequency_days>0` and ≥1 line item coded 01–07). Setting `INACTIVE` routes through the **`archive-client`** edge function (archives in Jobber, re-reads `isArchived`, then the RPC). Leaving RECURRING / entering INACTIVE|PAUSED fires `trg_clients_cleanup_sa_visits_on_status`, which soft-deletes upcoming **SA** visits. The Edit-client dialog already has the reason textarea + a "remove upcoming SA visits?" confirm driven by `client.preview_client_status_change`.

**The "becomes Recurrent" confirmation was never built.** Today the flow is the inverse: set status in Edit-client → that *forces* an SA job to exist. Job actions do nothing to status.

**The line-item duplication is a concurrency race, not the reopen code.** `public.line_items` has no unique key; three inbound writers rewrite job-scoped lines as a **non-atomic DELETE-then-INSERT**: the `*/5` poll `handleJob` (`webhook-jobber/index.ts:1262-1271`), the 30-min drift reconciler (`sync-jobber-job-drift/index.ts:216-241`), and `fn_record_client_job` (create/edit only). A reopen bumps Jobber's `updatedAt` (forcing a poll pass) *and* flips the job back into the drift reconciler's candidate set (it excludes `archived`/`closed`/`destroyed`), so two delete+insert cycles overlap → `delete-A, delete-B, insert-A, insert-B` → the set is written twice. It **self-heals** (the next single writer re-collapses it) and Jobber stays correct. Confirmed live: job `99900756` was close/reopen-cycled 12:35–12:52 ET with `app_source='jobber'` and `'sql'` line-item rewrites landing in the same sub-second windows.

---

## 3. The client-status state machine

A property/client always has one **SC (base) job**; recurring clients also have one or more **SA jobs** on top.

```
                 create/reopen SA (confirm 🟢)
        ┌───────────────────────────────────────────┐
        ▼                                            │
   ┌─────────┐   close last SA, no other SA (⚪)  ┌──────────┐
   │ ACTIVE  │ ◀─────────────────────────────────  │ RECURRING│
   │ (SC only)│                                     │(SC + SA) │
   └─────────┘                                      └──────────┘
        │                                            │
        │ close SC (confirm 🔴): close ALL jobs,     │ close SC (confirm 🔴)
        ▼ archive in Jobber                          ▼
                        ┌──────────┐
                        │ INACTIVE │  (client archived in Jobber; all jobs closed)
                        └──────────┘
```

Rules:
- **Active** = has an open SC job, no open SA.
- **Recurring** = has ≥1 open SA job (on top of the SC).
- **Inactive** = SC job closed → the whole client is shut down (all jobs closed + archived in Jobber).
- Creating/reopening an SA moves Active → Recurring. Closing the **last** open SA moves Recurring → Active (if another SA stays open, no status change). Closing the SC moves either state → Inactive.
- Only **transitions that actually change status** show a status dialog; a no-op reopen/close shows the plain variant.

---

## 4. Part 1 — Backend fix: stop line-item duplication (independent, ship first)

This is the real data-integrity bug and is decoupled from the UX; it can and should land first.

**Root cause:** non-atomic DELETE-then-INSERT of job-scoped line items by ≥2 concurrent inbound writers, on a table with no unique key.

**Approach (chosen):** make each job's job-scoped line-item rewrite **atomic and serialized per job**.
- New SECURITY DEFINER RPC, e.g. `ops.rewrite_job_line_items(p_job_id bigint, p_lines jsonb)`:
  - `PERFORM pg_advisory_xact_lock(hashtextextended('job_line_items', p_job_id))` (or `SELECT id FROM public.jobs WHERE id=p_job_id FOR UPDATE`) to serialize concurrent rewrites of the same job.
  - `DELETE FROM public.line_items WHERE job_id=p_job_id AND visit_id IS NULL AND invoice_id IS NULL AND quote_id IS NULL;`
  - Insert the provided lines — **in one transaction**, so no other writer can observe the deleted-but-not-yet-reinserted window.
- Route all three writers through it: the poll `handleJob`, the drift reconciler, and `fn_record_client_job`'s line-item block. (They currently each do their own delete+insert.)

**Rejected alternative:** a partial unique index on `(job_id, name, unit_price, quantity) WHERE visit_id IS NULL …` — jobs legitimately carry same-name split-price rows, so a unique constraint would reject valid data.

**Verification:** a rolled-back concurrency probe (two overlapping rewrites of the same test job must leave exactly one set), plus re-check `99900756` / 117-BH shows a single set after a reopen. Migration lives in `Supabase/docs/migrations/` with the standard dated header.

---

## 5. Part 2 — Client App job UX

### 5.1 Legacy jobs get no Reopen button
Gate the per-row Reopen control on the **title test**:
```
canReopen(job) = /^service agreement/i.test(job.title.trim()) || job.title.trim().toLowerCase() === 'service call'
```
Everything else (legacy, `[OLD]`, odd free-text) → **no Reopen button** (the archived row still shows "Open in Jobber"). Never gate on `job_status`.

⚠ **Known false-legacy risk:** ~6 live jobs act like SCs but fail the title test (`'Service'` on 293-ALC/296-KAT, `'service'` on 297-MAR, two `'Emergency call'`, `'Quaterly Hydrojet cleaning'` on 110-CLA). They will show no Reopen. **Durable fix = rename them to `Service Call` in Jobber** (data-hygiene follow-up, listed here so it isn't lost). Do not special-case them in the app.

### 5.2 One preview drives every dialog
Before showing any confirmation, the app calls **`client.preview_job_action(p_client_id, p_job_id, p_action)`** (new SECURITY DEFINER RPC in the `client` schema; `p_job_id` null for `create`). It returns:

```jsonc
{
  "job":            { "job_number": 99900756, "title": "...", "kind": "SA|SC|legacy", "frequency_days": 30, "job_status": "archived" },
  "action":         "create|reopen|close",
  "status_change":  { "from": "ACTIVE", "to": "RECURRING" } | null,
  "jobs_to_close":  [ { "job_number": 99900755, "title": "Service Call", "kind": "SC", "upcoming_visits": 2 }, ... ],
  "upcoming_visits_removed": 6,
  "other_open_sa_count": 0,
  "will_archive_client": false
}
```

- Reads `client.jobs` (open = `job_status <> 'archived'`) and `client.v_visits_live` (upcoming = `visit_status='scheduled' AND deleted_at IS NULL AND start_at >= now()`).
- **create:** `jobs_to_close=[]`; `status_change = {ACTIVE→RECURRING}` iff current status **= ACTIVE** (else null — PAUSED/INACTIVE go through Edit-client per §5.4).
- **reopen SA, client = ACTIVE:** `status_change={ACTIVE→RECURRING}`.
- **reopen** otherwise (SC, or SA on a RECURRING/PAUSED client): `status_change=null`.
- **close SA:** `jobs_to_close=[that SA]`; `other_open_sa_count` = open SA jobs excluding this one; `status_change={→ACTIVE}` iff `other_open_sa_count=0`, else null.
- **close SC:** `jobs_to_close` = **every** open job on the client (SC + all SAs + any other), each with its `upcoming_visits`; `upcoming_visits_removed` = total; `will_archive_client=true`; `status_change={<current>→INACTIVE}`.

Every dialog renders its rows/counts straight from this payload — nothing is hardcoded.

### 5.3 The four dialogs (see mockup in the design session)
| Trigger | Dialog | Style | On confirm |
|---|---|---|---|
| Create SA (client = ACTIVE) | 🟢 "Make {client} a recurrent client?" — lists the new SA, status Active→Recurring | success | `save-client-job create` → `update_client_status(RECURRING, reason)` → `generate_visits_for_client` |
| Reopen SA (client = ACTIVE) | 🟢 same, wording "Opening this agreement…" | success | `save-client-job reopen` → `update_client_status(RECURRING, reason)` → `generate_visits_for_client` |
| Close last SA (`other_open_sa_count=0`) | ⚪ "Close this service agreement?" — lists the SA + N upcoming visits, status Recurring→Active | neutral | `save-client-job close` → `update_client_status(ACTIVE, reason)` |
| Close SC | 🔴 "Close service call and deactivate {client}?" — lists **all** open jobs to be closed with per-job upcoming counts, status →Inactive, "archived in Jobber" | danger | for each open job `save-client-job close` → `archive-client` (archives in Jobber, sets INACTIVE) |
| Reopen with no status change (SC, or SA on a RECURRING/PAUSED client) | plain "Reopen this job?" — lists the one job | neutral | `save-client-job reopen` |
| Create/reopen SA on a **non-ACTIVE** client (RECURRING already, or PAUSED) | *(no status dialog)* | — | the job action only |

**Reason strings** (auto-filled, satisfy the mandatory-reason RPC and land in `client_status_changes`): e.g. `"Client App: reopened SA job #99900756"`, `"Client App: closed last SA job #99900756"`, `"Client App: closed SC job #99900755 → deactivated"`. The confirmation click is the human proof.

**Sequencing & failure handling.** Status changes run **after** the job action succeeds (branch on `data.ok`). If the job action succeeds but the status RPC fails, surface the error and leave the client status unchanged (the job state is already correct in Jobber+DB); the user can retry from Edit-client. For **close SC**, close the jobs first, then `archive-client`; if archiving fails after jobs are closed, surface it — the client is not yet Inactive but its jobs are closed (a recoverable, visible state).

### 5.4 Edge cases (explicit)
- **Already RECURRING + create/reopen another SA:** no status dialog; just do the job action (`fn_is_current_sa_job` already satisfied).
- **Close SA when another SA stays open:** plain close confirm (`other_open_sa_count>0`), no status change.
- **Reopen the SC of an INACTIVE client:** **blocked** with a message "Reactivate this client from Edit-client first" — reactivation needs a Jobber un-archive path, deferred (§1 non-goals). The client is archived in Jobber, so `jobReopen` would fail anyway.
- **PAUSED clients:** job actions do not auto-change status; direct the user to Edit-client. (PAUSED is a deliberate human hold.)
- **The `status_source='manual'` pin** is correct here — a human confirmed each change, and it must survive the Jobber poll. INACTIVE ordering is handled by `archive-client`.
- **`generate_visits_for_client`** runs only on the → RECURRING transitions (matching the existing Edit-client flow).

---

## 6. Testing — multi-visual-check on 112-YA

Run end-to-end on **112-YA** (Jobber sandbox client). At each step: (a) screenshot the UI, (b) verify the live DB (`public.jobs.job_status`, `public.clients.status`/`status_source`, `public.line_items` count for the job, `client_status_changes`, upcoming visits). Roll back / restore 112-YA to its baseline at the end.

0. **Baseline capture** — record 112-YA's current jobs (numbers, titles, statuses), status, and line-item counts.
1. **Legacy no-reopen** — on a legacy-titled (or `[OLD]`) job row, confirm **no Reopen button**; an SC/SA archived row **does** show it. *(screenshot)*
2. **Reopen confirm (no status)** — reopen an SC (or an SA on an already-recurring client): plain "Reopen this job?" dialog listing the one job; confirm; job → open; **client status unchanged**; **line items NOT doubled** (Part 1). *(screenshot + line_items count)*
3. **Create SA → Recurrent** — with 112-YA Active, create an SA job: 🟢 dialog naming the new SA + Active→Recurring; confirm; `clients.status=RECURRING`, `status_source=manual`, a `client_status_changes` row, visits generated. *(screenshot + DB)*
4. **Reopen SA → Recurrent** — close then reopen that SA (client back to Active first via step 5, or on a second SA): 🟢 dialog; confirm; status → Recurring. *(screenshot + DB)*
5. **Close last SA → Active** — close the only open SA: ⚪ dialog listing the SA + its upcoming visit count; confirm; status → Active; SA visits soft-deleted. *(screenshot + DB)*
6. **Close SC → Inactive** — close the SC: 🔴 dialog listing **every** open job with per-job upcoming counts + "archived in Jobber"; confirm; all jobs `archived`, client `INACTIVE`, `isArchived=true` in Jobber, visits removed. *(screenshot + DB + Jobber check)*
7. **Duplication regression** — after the step-2/4 reopens, confirm each affected job has exactly one set of line items (no `2×$450`). *(DB)*
8. **Restore** — return 112-YA to baseline (reopen/recreate as needed, reset status).

---

## 7. Rollout order
1. **Part 1** (backend dup fix) — migration + reroute the three writers → deploy → concurrency probe.
2. **`client.preview_job_action`** RPC (+ any `client` grants / `NOTIFY pgrst`).
3. **Part 2** Client App (Lovable) — legacy gate, reopen confirm, the four dialogs, the status-transition calls.
4. Test on 112-YA (§6).
5. Documentation (§8) + the Jobber rename follow-up (§5.1).

---

## 8. Documentation to update (at ship)
- **`project_recurring_client_authoritative_source.md`** (memory) + **`Supabase/CLAUDE.md`** "`clients.status`" section — record the re-ruling: *Client-App job actions are now the human-confirmed driver of `clients.status` (Active/Recurrent/Inactive); the 2026-07-15 "status is not authoritative" rule is superseded for app-driven changes.* Keep the note that the Jobber poll still owns archive-driven INACTIVE.
- **`Building Apps/Client App/docs/08-changelog.md`** (dated entry) + **`09-known-issues.md`** (close the reopen-duplication item; note the ~6 mis-titled jobs) + the app's **`CLAUDE.md`** (the new status-driving rule + `preview_job_action` contract).
- **`Supabase/docs/`** — migration headers for the dup fix + `preview_job_action`; cross-reference this spec.

## 9. Risks / open items
- **Jobber archive vs. jobClose ordering** for close-SC: verify whether archiving the client in Jobber auto-closes its jobs, or whether we must `jobClose` each first (spec assumes close-each-then-archive). Confirm in the implementation plan against a Jobber sandbox job.
- **Emergency-only clients** (`feedback_emergency_only_clients.md`) keep jobs but rarely visit — closing an SC to deactivate them is a deliberate human action here, so it's fine, but the UX copy should not imply "inactive = abandoned".
- **The ~6 mis-titled live jobs** are the only classification ambiguity; the durable fix is renaming in Jobber, tracked in §5.1.
- **`generate_visits_for_client` horizon** — the recurring dialog could optionally show "~N visits will be generated"; left out of v1 to avoid coupling to the generator's horizon math.
