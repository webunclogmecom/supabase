# Client job-status lifecycle — as-built reference

*Shipped 2026-09-01. This is the consolidated, as-built DB-side reference for the Client App feature
where a **job action drives `clients.status`**. Design intent lives in
[`../superpowers/specs/2026-09-01-client-job-status-lifecycle-design.md`](../superpowers/specs/2026-09-01-client-job-status-lifecycle-design.md)
and the task plan in
[`../superpowers/plans/2026-09-01-client-job-status-lifecycle.md`](../superpowers/plans/2026-09-01-client-job-status-lifecycle.md);
this file records what actually shipped and how it was verified. App-facing contract:
`Building Apps/Client App/CLAUDE.md` rule 2n + `Building Apps/Client App/docs/08-changelog.md`.*

---

## 1. What it does

On the Client App a job-card action (create / reopen / close a job), after an explicit confirmation
dialog, now moves `public.clients.status`. Every dialog is built from ONE read-only RPC, and every
write goes through a sanctioned, verified path, so the dialog text and the actual write cannot
disagree.

### The state machine (title-only job kinds)

Job kind is **title-only**, matching the whole estate: SA = `title ILIKE 'Service Agreement%'`,
SC = `lower(btrim(title)) = 'service call'`, else legacy. "Open" job = `job_status <> 'archived'`
(our sync maps Jobber closed/destroyed to `archived`; there is no `closed`/`destroyed` value in
`public.jobs.job_status`).

| Action | Client was | Becomes | How the write happens |
|---|---|---|---|
| create SA / reopen SA | ACTIVE | **RECURRING** | job action, then `client.update_client_status(RECURRING)`, then `client.generate_visits_for_client` |
| close the **last** SA (`other_open_sa_count = 0`) | any | **ACTIVE** | `client.update_client_status(ACTIVE)`; with other SAs open it is a plain close, no status move |
| close the **Service Call** | any | **INACTIVE** | **`archive-client`** edge fn (`close_jobs:true`) — archives in Jobber + closes all open jobs, then INACTIVE |
| reopen the SC of an INACTIVE client | INACTIVE | **ACTIVE** | **`unarchive-client`** edge fn — un-archives in Jobber, reopens the **SC only**, then ACTIVE |
| anything else | — | (no status move) | plain confirm |

🛑 **Reactivation reopens the SC ONLY — old SAs stay closed.** To make an INACTIVE client RECURRING
again the app **creates a NEW SA**; it never reopens an archived one (`unarchive-client` refuses a
non-SC job server-side). This keeps the two systems from resurrecting a stale agreement.

---

## 2. `client.preview_job_action(p_client_id, p_job_id, p_action)` — the describer

Migration [`2026-09-01_1630_preview_job_action.sql`](../migrations/2026-09-01_1630_preview_job_action.sql).
SECURITY DEFINER, `SET search_path = public`, **read-only** (only SELECTs — nothing to audit, no
rollback needed to test). GRANT EXECUTE to `authenticated` (the app, as the signed-in user) +
`service_role` (edge fns); REVOKE from PUBLIC + anon.

Returns `jsonb` with these keys:

| Key | Meaning |
|---|---|
| `job` | the acted job `{job_number, title, kind, frequency_days, job_status}`; NULL on `create` (pass `p_job_id = NULL`) |
| `status_change` | `{from, to}`, or **null when there is no status move** |
| `jobs_to_close[]` | jobs that will close. **`upcoming_visits` is a per-job key ONLY on the close-SC branch** (which lists EVERY open job). On close-SA, `jobs_to_close` is just the acted job object with no per-job count. |
| `upcoming_visits_removed` | top-level total of upcoming visits the action removes (this is where the SA count rides) |
| `other_open_sa_count` | how many OTHER non-archived SAs remain — the gate for "close last SA → ACTIVE" |
| `will_archive_client` | true on close-SC |
| `will_unarchive_client` | true on reopen-SC of an INACTIVE client |
| `action` | echoes `p_action` (harmless superset of the design's key list) |

🛑 **Never compute the transition or the jobs-to-close list in the browser.** The RPC is the single
source. For `create`, pass `p_job_id = NULL`.

---

## 3. The line-item duplication fix (prerequisite, Phase A)

`public.line_items` has **no unique key by design** — a job legitimately carries 2–3 same-name rows
at split prices. Three inbound writers each rewrote job-scope lines as a **non-atomic
delete-then-insert**: `webhook-jobber.handleJob` (the `*/5` poll), `sync-jobber-job-drift` (the
30-min reconciler), and `public.fn_record_client_job` (create/edit via `save-client-job`). A reopen
bumps Jobber's `updatedAt` (forcing a poll pass) **and** flips the job out of the terminal states the
drift reconciler excludes, so two cycles overlap and interleave (delete-A, delete-B, insert-A,
insert-B) → the set is written twice. It self-heals but is visible.

- **`public.rewrite_job_line_items(p_job_id bigint, p_lines jsonb)`**
  ([`2026-09-01_1620`](../migrations/2026-09-01_1620_atomic_job_line_items_rewrite.sql)) takes a
  **per-job advisory XACT lock** (serializes concurrent rewrites of the SAME job, auto-released at
  txn end), then does the delete and the insert as one statement each in one transaction — no writer
  can observe the deleted-but-not-reinserted window. Lives in **`public`** (not `ops`) because both
  edge-function clients use the default PostgREST schema. Delete predicate is the widest-safe form:
  `job_id = X AND visit_id IS NULL AND invoice_id IS NULL AND quote_id IS NULL`.
  ⚠ The INSERT is guarded by `jsonb_array_length(p_lines) > 0`, so an **empty array deletes then
  inserts NOTHING** (i.e. clears the job's job-scope lines) — a non-empty array is what inserts.
- **`public.fn_record_client_job`** was rerouted through it
  ([`2026-09-01_1625`](../migrations/2026-09-01_1625_fn_record_client_job_uses_rewrite.sql)) with the
  exact live body, only the line-item block changed. The `webhook-jobber` and `sync-jobber-job-drift`
  writers were routed through it in the same cycle (edge-fn side).

---

## 4. `archive-client` — deactivation (close SC → INACTIVE)

Source `supabase/functions/archive-client/index.ts`. `config.toml`: `verify_jwt = false`, staff gate
IN the handler (`db.auth.getUser(token)` + `@ayache.com`/`@unclogme.com`). App calls it
`{client_id, close_jobs:true, reason}`.

🛑 **The order is the feature — JOBBER FIRST, VERIFY, THEN US, and closes are EXPLICIT:**

1. Read the client + its open jobs from Jobber.
2. If there are open jobs and **`close_jobs` is not true**, return `code:'open_jobs'` with the job
   list and **write nothing** (the app takes a second explicit confirmation — Fred: "ask me in the
   moment").
3. With `close_jobs:true`, **close every open job explicitly** via
   `jobClose(input:{modifyIncompleteVisitsBy: DESTROY_ALL})` in a loop. **It does NOT rely on
   `clientArchive` cascading the closes** — the closes happen first, one per job. `DESTROY_ALL` (not
   `COMPLETE_PAST_DESTROY_FUTURE`) is deliberate: an incomplete visit did not happen, so destroying it
   is honest and marking it completed would assert work never performed.
4. `clientArchive(clientId)`, then **re-read** and require `isArchived === true`. A clean mutation
   response is not evidence.
5. Only then `client.update_client_status(client_id, 'INACTIVE', reason)` via the **caller's JWT** —
   pins `status_source='manual'` and `audit.logs` names the human.

If any `jobClose` or the archive fails, it returns fail-safe (writes no status). ⚠ **Jobber-side
partial-close is possible** (some jobs closed, then a later step fails) — our DB status stays
unchanged, but the Jobber side may hold a partial teardown to reconcile.

### The structured refusal — `archive_blocked_preconditions`

Jobber refuses `clientArchive` while the client has open **quotes / work requests / unpaid
invoices** (not just open jobs). archive-client parses that one opaque userError into:

```
{ code: "archive_blocked_preconditions",
  blockers: [{ category, source, count }],   // category ∈ work_requests | quotes | invoices
  jobber_error: "<the raw Jobber message>",
  message: "<what to clear in Jobber, then retry>" }
```

- Blocker categories come from substring-matching Jobber's message; counts for quotes/invoices are
  enriched from OUR DB (`countArchiveBlockers`), and a count is **omitted, never zeroed**, on a read
  error (so `null` means "not counted", never "zero").
- 🛑 **None of these are clearable from the Client App** — the `jobber_write` OAuth scope cannot touch
  quotes/requests/invoices, and billing is Jobber-mastered. A human must act in Jobber. (Quotes ARE
  resolvable *there* by archive/convert/delete — `countArchiveBlockers` treats
  `quote_status IN (archived,converted)` as resolved; the point is our app can't do it, **not** that
  quotes have no archive path.)
- The app surfaces `message` on the red confirm dialog. See
  [`reference_jobber_client_archive_needs_quotes_invoices_cleared`] in memory.

---

## 5. `unarchive-client` — reactivation (reopen SC → ACTIVE)

Source `supabase/functions/unarchive-client/index.ts`. The mirror of archive-client, reversed.
`config.toml`: `verify_jwt = false`, same in-function staff gate. App calls it `{client_id, job_id}`
where `job_id` is our `public.jobs.id` of the Service Call.

1. Validate the job belongs to the client and **IS an SC** (`title = 'service call'`, trimmed) —
   **refuses SA/legacy** (`not_service_call`), so it can never resurrect a Service Agreement.
2. `clientUnarchive(clientId)`, then re-read and require `isArchived === false` (Jobber-first +
   verify, same as archive).
3. `jobReopen(jobId)` on the SC if it is terminal in Jobber; record its status via
   `fn_record_client_job`.
4. `client.update_client_status(client_id, 'ACTIVE', reason)` via the caller's JWT (pins `manual`).

Idempotent (rule 5): a client already `isArchived=false` converges our side and returns; an SC
already open is left as-is.

---

## 6. The `status_source='manual'` pin

Both edge fns write status through the **3-arg** `client.update_client_status` (reason mandatory; the
2-arg overload's whole body is `raise 'a reason is now required'`, so a 2-arg call fails loudly). The
3-arg RPC pins `clients.status_source = 'manual'`, and `webhook-jobber`'s `handleClient` skips its
INACTIVE→ACTIVE reactivation branch for `manual` rows — so a deliberate deactivation is NOT reverted
by the `*/5` poll. (Only the reactivation branch is gated; an explicit archive in Jobber still forces
INACTIVE.) Mechanism: `Supabase/CLAUDE.md` "clients.status_source" + migration `2026-08-13_0130`.

---

## 7. Verification (as-built)

### 561 "ZZ Mode Separate" (311-ZMS) — synthetic, already-archived — 2026-09-01

Full reactivate→deactivate round-trip driven through the Client App and verified at the Client App,
Jobber (API + web UI) and the DB, then restored to its INACTIVE/archived baseline. Reactivation held
ACTIVE across **two `*/5` poll runs** (the manual pin held). This was the safe, synthetic proof.

### 112-YA "Yan's Restaurant" (client 381) — REAL recurring client — 2026-09-01

Fred cleared its Jobber blockers by hand first (7 quotes, 2 work requests, the $1 test invoice
#2894 — the archive precondition), then the FULL archive→reactivate→restore ran through the actual
edge fns on a client with a live SA + three SCs + a legacy job:

- **archive-client** (`close_jobs`): `ok:true`, `archived:true`, `status_write.result.visits_removed:0`
  (0 incomplete visits, verified in Jobber first), 5 jobs `jobClose`'d, `ACTIVE→INACTIVE/manual`.
  Verified: Jobber `isArchived:true`; DB INACTIVE; Client App pill **"Inactive"** + "Reactivate client".
- **unarchive-client** (SC #99900535, our job id 766): `ok:true`, un-archived + verified, SC reopened
  to `action_required`, `INACTIVE→ACTIVE/manual`. Verified: Jobber `isArchived:false`; DB ACTIVE;
  Client App pill **"Active"** + "Archive client".
- **Restored** to baseline by `jobReopen` on the SA + the other two SCs → **5 open jobs, 9 live / 0
  scheduled visits (exactly baseline)**. Audit trail attributed to `fred@ayache.com`.

### 🛑 Restore-fidelity finding: `jobs.job_status` is a pure Jobber mirror and does NOT self-revert

After the round-trip the SA (#11100534) came back **`requires_invoicing`**, not its baseline
`active`. This is **not** a broken restore:

- **`jobs.job_status` is a pure MIRROR of Jobber** — the `*/5` poll copies Jobber's `jobStatus`, it
  never derives one. So the status can only change if Jobber changes it.
- Jobber holds it at `requires_invoicing` because the job carries **completed, unbilled work**
  ($207.06 on that SA). That is a stable state; it clears to `active` only when the work is **invoiced
  in Jobber**, not on a timer. **Measured over ~10 poll cycles / ~53 min it did NOT self-revert** —
  Jobber stayed put and the DB row's `updated_at` never moved, because the poll never had a changed
  value to sync.
- It is **functionally inert**: `public.fn_generate_sa_visits` keys on `job_status <> 'archived'`
  (not `= 'active'`), and `frequency_days = 45` + `jobType = RECURRING` both survive the round-trip,
  so the SA still generates visits exactly as before.
- ⇒ Do not expect a poll to fix it, and do NOT invoice to tidy it (billing = Jobber-mastered). Left
  as-is pending Fred.

Also durable and documented: `status_source` `jobber→manual` after any archive/reactivate round-trip
(the pin above; harmless).

---

## 8. Cross-references

- **Migrations:** `2026-09-01_1620` (rewrite_job_line_items), `2026-09-01_1625` (fn_record_client_job
  rewire), `2026-09-01_1630` (preview_job_action).
- **Edge fns:** `supabase/functions/archive-client/index.ts`,
  `supabase/functions/unarchive-client/index.ts`; both `verify_jwt = false` + in-function staff gate
  (`supabase/config.toml`).
- **Pre-existing RPCs used:** `client.update_client_status` (3-arg, pins `manual`),
  `client.generate_visits_for_client`, `public.fn_generate_sa_visits`.
- **Authority / rules:** `Supabase/CLAUDE.md` "clients.status" section (the 4 transitions, the
  `status_source` pin, the archive precondition, and the `job_status`-is-a-Jobber-mirror principle).
- **App-facing:** `Building Apps/Client App/CLAUDE.md` rule 2n; `Building Apps/Client App/docs/08-changelog.md`.
- **Memory:** `reference_jobber_client_archive_needs_quotes_invoices_cleared`,
  `project_recurring_client_authoritative_source`.
