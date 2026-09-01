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

**Non-goals (out of scope):** changing PAUSED handling. *(Reactivation of an Inactive client is now IN scope — see §5.5. The ~6 mis-titled live jobs keep their titles for historic value and are treated as legacy / no-reopen — see §5.1.)*

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
                 create / reopen SA (confirm 🟢)
        ┌───────────────────────────────────────────┐
        ▼                                            │
   ┌──────────┐  close last SA, no other SA (⚪)  ┌──────────┐
   │  ACTIVE  │ ◀────────────────────────────────  │ RECURRING│
   │ (SC only)│                                    │(SC + SA) │
   └──────────┘                                    └──────────┘
      ▲   │                                            │
      │   │ close SC (confirm 🔴): archive client in   │ close SC (confirm 🔴)
      │   ▼ Jobber → auto-closes ALL jobs              ▼
      │                   ┌──────────┐
      └───────────────────│ INACTIVE │  reopen SC = reactivate (un-archive in Jobber → Active)
      reopen SC (confirm) └──────────┘  Inactive → Recurring = reactivate + create a NEW SA
```

Rules:
- **Active** = has an open SC job, no open SA.
- **Recurring** = has ≥1 open SA job (on top of the SC).
- **Inactive** = SC job closed → the whole client is shut down (all jobs closed + archived in Jobber).
- Creating/reopening an SA (on an **Active** client) moves Active → Recurring. Closing the **last** open SA moves Recurring → Active (if another SA stays open, no status change). Closing the SC moves either state → Inactive (**archiving the client in Jobber auto-closes every job**).
- **Reactivation (Inactive → Active):** reopening the **SC** un-archives the client in Jobber and reopens the SC. Old SA jobs are **not** reopened. To become Recurring again you **create a new SA** (never reopen an archived one) — see §5.5.
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
Everything else (legacy, `[OLD]`, odd free-text) → **no Reopen button** (the archived row still shows "Open in Jobber"). Never gate on `job_status`. **One status-aware refinement:** on an **INACTIVE** client, only the **SC** shows Reopen (it's the reactivation entry); archived **SA** rows are hidden (§5.4 / §5.5).

⚠ **~6 live jobs act like SCs but fail the title test** (`'Service'` on 293-ALC/296-KAT, `'service'` on 297-MAR, two `'Emergency call'`, `'Quaterly Hydrojet cleaning'` on 110-CLA). Per Fred (2026-09-01): **keep their titles as-is** (they carry historic value) and treat them as legacy → **no Reopen**, which is the intended behavior — "no need to reopen old jobs." Do **not** rename them and do **not** special-case them in the app. (Consequence: for the rare client whose only base job is one of these, the SC-close→Inactive job-card flow won't recognize it; deactivation for those falls back to the Edit-client status dialog. Accepted.)

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
  "will_archive_client": false,
  "will_unarchive_client": false
}
```

- Reads `client.jobs` (open = `job_status <> 'archived'`) and `client.v_visits_live` (upcoming = `visit_status='scheduled' AND deleted_at IS NULL AND start_at >= now()`).
- **create:** `jobs_to_close=[]`; `status_change = {ACTIVE→RECURRING}` iff current status **= ACTIVE** (else null — PAUSED/INACTIVE go through Edit-client per §5.4).
- **reopen SA, client = ACTIVE:** `status_change={ACTIVE→RECURRING}`.
- **reopen SC, client = INACTIVE (reactivation, §5.5):** `status_change={INACTIVE→ACTIVE}`; `will_unarchive_client=true`; `jobs_to_close=[]`.
- **reopen** otherwise (SC on a non-Inactive client, or SA on a RECURRING/PAUSED client): `status_change=null`.
- **close SA:** `jobs_to_close=[that SA]`; `other_open_sa_count` = open SA jobs excluding this one; `status_change={→ACTIVE}` iff `other_open_sa_count=0`, else null.
- **close SC:** `jobs_to_close` = **every** open job on the client (SC + all SAs + any other), each with its `upcoming_visits`; `upcoming_visits_removed` = total; `will_archive_client=true`; `status_change={<current>→INACTIVE}`.

Every dialog renders its rows/counts straight from this payload — nothing is hardcoded.

### 5.3 The dialogs (core four mocked in the design session; the 🔵 reactivate variant mirrors them)
| Trigger | Dialog | Style | On confirm |
|---|---|---|---|
| Create SA (client = ACTIVE) | 🟢 "Make {client} a recurrent client?" — lists the new SA, status Active→Recurring | success | `save-client-job create` → `update_client_status(RECURRING, reason)` → `generate_visits_for_client` |
| Reopen SA (client = ACTIVE) | 🟢 same, wording "Opening this agreement…" | success | `save-client-job reopen` → `update_client_status(RECURRING, reason)` → `generate_visits_for_client` |
| Close last SA (`other_open_sa_count=0`) | ⚪ "Close this service agreement?" — lists the SA + N upcoming visits, status Recurring→Active | neutral | `save-client-job close` → `update_client_status(ACTIVE, reason)` |
| Close SC | 🔴 "Close service call and deactivate {client}?" — lists **all** open jobs that will close with per-job upcoming counts, status →Inactive, "archived in Jobber" | danger | `archive-client` — archives the client in Jobber, which **auto-closes every job**, then sets INACTIVE |
| Reopen SC on an **Inactive** client (reactivation, §5.5) | 🔵 "Reactivate {client}?" — notes it un-archives in Jobber and reopens the Service Call; old agreements stay closed; status Inactive→Active | info | `unarchive-client` — un-archives in Jobber, reopens the SC, sets ACTIVE |
| Reopen with no status change (SC on a non-Inactive client, or SA on a RECURRING/PAUSED client) | plain "Reopen this job?" — lists the one job | neutral | `save-client-job reopen` |
| Create/reopen SA on a **non-ACTIVE** client (RECURRING already, or PAUSED) | *(no status dialog)* | — | the job action only |

**Reason strings** (auto-filled, satisfy the mandatory-reason RPC and land in `client_status_changes`): e.g. `"Client App: reopened SA job #99900756"`, `"Client App: closed last SA job #99900756"`, `"Client App: closed SC job #99900755 → deactivated"`, `"Client App: reactivated (reopened SC job #99900755)"`. The confirmation click is the human proof.

**Sequencing & failure handling.** For the create/reopen-SA and close-last-SA cases, the status RPC runs **after** the job action succeeds (branch on `data.ok`); if the job action succeeds but the status RPC fails, surface the error and leave status unchanged (the job state is already correct) — the user can retry from Edit-client. For **close SC → Inactive** and **reactivation**, the whole thing is a **single edge-function call** (`archive-client` / `unarchive-client`) that mutates Jobber, verifies the re-read, and sets the status — so it either fully succeeds or leaves the client unchanged; no partial-close state to reconcile app-side.

### 5.4 Edge cases (explicit)
- **Already RECURRING + create/reopen another SA:** no status dialog; just do the job action (`fn_is_current_sa_job` already satisfied).
- **Close SA when another SA stays open:** plain close confirm (`other_open_sa_count>0`), no status change.
- **Reopen the SC of an INACTIVE client:** this **is** reactivation (§5.5) — the 🔵 "Reactivate {client}?" dialog → `unarchive-client` → Active. Old SA jobs stay closed.
- **Archived SA rows on an INACTIVE client show NO Reopen button.** Old agreements are historic; to make an inactive client recurring again you reactivate (reopen SC → Active) then **create a new SA** — never reopen an archived one (§5.5).
- **PAUSED clients:** job actions do not auto-change status; direct the user to Edit-client. (PAUSED is a deliberate human hold.)
- **The `status_source='manual'` pin** is correct here — a human confirmed each change, and it must survive the Jobber poll. INACTIVE ordering is handled by `archive-client`.
- **`generate_visits_for_client`** runs only on the → RECURRING transitions (matching the existing Edit-client flow).

### 5.5 Reactivation (Inactive → Active / Recurring)
Reactivating a client is the mirror of the close-SC deactivation, and it only brings back the **base SC job** — never the old agreements.

- **Trigger:** the **Reopen** control on the archived **SC** job of an Inactive client (labeled "Reactivate" in its confirm). Archived **SA** rows on an Inactive client show no Reopen (§5.4).
- **New backend: `unarchive-client` edge function** (the reverse of `archive-client`, same verified-saga shape):
  1. Un-archive the client in Jobber; re-read until `isArchived === false`.
  2. `jobReopen` the client's **SC** job (the one being reopened); record its `job_status`.
  3. `client.update_client_status(id, 'ACTIVE', reason)` (`status_source='manual'`).
  4. Leave every **SA** job archived — reactivation does **not** reopen agreements.
- **Inactive → Recurring** is a **two-step** path, by design: reactivate (SC → Active), then **create a new SA** (the 🟢 create-SA → Recurring flow, §5.3). The app never reopens an old archived SA to reach Recurring. If reactivation is initiated from the Edit-client "set Recurring" dropdown on an Inactive client, it must likewise route to **create a new SA** (SA tab, reopen-old hidden), consistent with this rule.
- ⚠ Depends on Jobber supporting client un-archive + reopening a job on a just-un-archived client — verify in the implementation plan (a `jobReopen` on the SC must succeed only after the client is un-archived).

---

## 6. Testing — multi-visual-check on 112-YA

Run end-to-end on **112-YA** (Jobber sandbox client). At each step: (a) screenshot the UI, (b) verify the live DB (`public.jobs.job_status`, `public.clients.status`/`status_source`, `public.line_items` count for the job, `client_status_changes`, upcoming visits). Roll back / restore 112-YA to its baseline at the end.

0. **Baseline capture** — record 112-YA's current jobs (numbers, titles, statuses), status, and line-item counts.
1. **Legacy no-reopen** — on a legacy-titled (or `[OLD]`) job row, confirm **no Reopen button**; an SC/SA archived row **does** show it. *(screenshot)*
2. **Reopen confirm (no status)** — reopen an SC (or an SA on an already-recurring client): plain "Reopen this job?" dialog listing the one job; confirm; job → open; **client status unchanged**; **line items NOT doubled** (Part 1). *(screenshot + line_items count)*
3. **Create SA → Recurrent** — with 112-YA Active, create an SA job: 🟢 dialog naming the new SA + Active→Recurring; confirm; `clients.status=RECURRING`, `status_source=manual`, a `client_status_changes` row, visits generated. *(screenshot + DB)*
4. **Reopen SA → Recurrent** — close then reopen that SA (client back to Active first via step 5, or on a second SA): 🟢 dialog; confirm; status → Recurring. *(screenshot + DB)*
5. **Close last SA → Active** — close the only open SA: ⚪ dialog listing the SA + its upcoming visit count; confirm; status → Active; SA visits soft-deleted. *(screenshot + DB)*
6. **Close SC → Inactive** — close the SC: 🔴 dialog listing **every** open job that will close + "archived in Jobber"; confirm. Verify `archive-client` archived the client in Jobber (`isArchived=true`), which **auto-closed all jobs** (`job_status='archived'`), `clients.status=INACTIVE`/`status_source=manual`, a `client_status_changes` row, and upcoming visits removed. *(screenshot + DB + Jobber)*
7. **Reactivate (Inactive → Active)** — on the archived **SC** row, click Reopen: 🔵 "Reactivate 112-YA?" dialog; confirm; `unarchive-client` un-archives in Jobber (`isArchived=false`), reopens the SC (open `job_status`), `clients.status=ACTIVE`; the old **SA stays `archived`** (not reopened). Confirm archived **SA** rows show **no** Reopen while Inactive. *(screenshot + DB + Jobber)*
8. **Inactive → Recurring uses a NEW SA** — from the reactivated (or Inactive) client, going Recurring prompts **create a new SA** and never offers to reopen the archived SA. *(screenshot)*
9. **Duplication regression** — after the reopens in steps 2/4/7, confirm each affected job has exactly one set of line items (no `2×$450`). *(DB)*
10. **Restore** — return 112-YA to baseline (reopen/recreate as needed, reset status).

---

## 7. Rollout order
1. **Part 1** (backend dup fix) — migration + reroute the three writers → deploy → concurrency probe.
2. **`client.preview_job_action`** RPC + the **`unarchive-client`** edge function (reverse of `archive-client`, §5.5) (+ any `client` grants / `NOTIFY pgrst`).
3. **Part 2** Client App (Lovable) — legacy gate, the reopen confirm (incl. the 🔵 reactivate variant), the dynamic dialogs, the status-transition calls.
4. Test on 112-YA (§6).
5. Documentation (§8).

---

## 8. Documentation to update (at ship)
- **`project_recurring_client_authoritative_source.md`** (memory) + **`Supabase/CLAUDE.md`** "`clients.status`" section — record the re-ruling: *Client-App job actions are now the human-confirmed driver of `clients.status` (Active/Recurrent/Inactive); the 2026-07-15 "status is not authoritative" rule is superseded for app-driven changes.* Keep the note that the Jobber poll still owns archive-driven INACTIVE.
- **`Building Apps/Client App/docs/08-changelog.md`** (dated entry) + **`09-known-issues.md`** (close the reopen-duplication item; note the ~6 mis-titled jobs) + the app's **`CLAUDE.md`** (the new status-driving rule + `preview_job_action` contract).
- **`Supabase/docs/`** — migration headers for the dup fix + `preview_job_action`; cross-reference this spec.

## 9. Risks / open items
- **Jobber close-on-archive** (resolved per Fred, 2026-09-01): archiving the client in Jobber auto-closes its jobs, so close-SC is a single `archive-client` call. The plan should still confirm on a Jobber sandbox job that archiving handles incomplete visits the way we expect, so the upcoming-visit cleanup matches the dialog's count.
- **Reactivation depends on Jobber** supporting client un-archive and then `jobReopen` on the just-un-archived SC — verify on a sandbox job before building `unarchive-client` (§5.5).
- **Emergency-only clients** (`feedback_emergency_only_clients.md`) keep jobs but rarely visit — closing an SC to deactivate them is a deliberate human action here, so it's fine, but the UX copy should not imply "inactive = abandoned".
- **`generate_visits_for_client` horizon** — the recurring dialog could optionally show "~N visits will be generated"; left out of v1 to avoid coupling to the generator's horizon math.
