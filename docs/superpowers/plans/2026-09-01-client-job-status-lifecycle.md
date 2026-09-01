# Client job actions drive client status — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Client-App job actions the confirmed driver of client status (Active/Recurrent/Inactive) with dynamic confirmations, hide Reopen on legacy jobs, and fix the concurrent line-item duplication — per the approved spec `2026-09-01-client-job-status-lifecycle-design.md`.

**Architecture:** Two layers. **Backend (Supabase Prod `wbasvhvvismukaqdnouk`):** a new atomic per-job line-item rewrite RPC that all three inbound sync writers route through (kills the duplication race); a `client.preview_job_action` RPC that returns the objects each dialog lists; and a new `unarchive-client` edge function (reverse of `archive-client`). Status changes reuse the existing `client.update_client_status` / `archive-client`. **App (Lovable "Client View Pro" `dbf2133c-539c-48ff-864a-68eb284a569d`):** title-based Reopen gating, context-aware reopen confirm, and the four/five dynamic dialogs, wired to the preview RPC and the status edge functions.

**Tech Stack:** PostgreSQL (SECURITY DEFINER RPCs, advisory locks, `CREATE OR REPLACE`), Supabase Edge Functions (Deno/TS, verified Jobber GraphQL saga), Supabase Management API for DB writes/probes, React/TS via Lovable prompts.

**How backend tasks are applied & tested:** write the migration/edge-fn, apply via the Management API (`POST https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query` with `SUPABASE_PAT` from `Supabase/.env`; deploy edge fns with `SUPABASE_ACCESS_TOKEN=<PAT> supabase functions deploy <fn> --project-ref wbasvhvvismukaqdnouk`), and prove each with a **rolled-back** SQL probe or a real edge-fn call. Never print the PAT. Every migration carries a dated header (ADR 010) and ends `NOTIFY pgrst, 'reload schema';`. Commit convention: Supabase repo commits carry the `Co-Authored-By: Claude Opus 4.8 (1M context)` footer; Building Apps commits are one-line, no footer.

---

## File / object map

**Backend — new objects**
- `docs/migrations/2026-09-01_<t>_atomic_job_line_items_rewrite.sql` — `ops.rewrite_job_line_items(bigint, jsonb)` (Phase A).
- `docs/migrations/2026-09-01_<t>_preview_job_action.sql` — `client.preview_job_action(bigint, bigint, text)` (Phase B).
- `supabase/functions/unarchive-client/index.ts` — reverse of `archive-client` (Phase B).

**Backend — modified**
- `supabase/functions/webhook-jobber/index.ts` (`handleJob`, ~1262-1271) — route its DELETE+INSERT through `ops.rewrite_job_line_items`.
- `supabase/functions/sync-jobber-job-drift/index.ts` (~216-241) — same.
- `docs/migrations/2026-07-30_1552_fn_record_client_job.sql` → new migration that `CREATE OR REPLACE`s `fn_record_client_job` to call the RPC for its line-item block.

**App — Lovable "Client View Pro"** (no repo source; changes via prompts, verified on `clients.unclogme.app`)
- Job card Reopen control (title gate + status-aware visibility).
- Reopen confirm dialog (context-aware).
- Create-SA / close-SA / close-SC / reactivate confirmations, wired to `client.preview_job_action` + `client.update_client_status` / `archive-client` / `unarchive-client`.

**Docs**
- `Building Apps/Client App/docs/08-changelog.md`, `09-known-issues.md`, Client App `CLAUDE.md`.
- Memory `project_recurring_client_authoritative_source.md` + `Supabase/CLAUDE.md` (the authority re-ruling).

---

## Phase A — Backend: stop the line-item duplication (independent, ship first)

### Task A1: Capture the exact line-item write shape

**Files:** read-only.

- [ ] **Step 1: Record the three writers' INSERT column lists**

Read and copy the exact `line_items` insert column set + value mapping from each:
- `supabase/functions/webhook-jobber/index.ts` — `handleJob`, the `delete().eq('job_id',…)` then `insert(...)` (~1262-1271).
- `supabase/functions/sync-jobber-job-drift/index.ts` (~216-241).
- `docs/migrations/2026-07-30_1552_fn_record_client_job.sql` — the `DELETE … WHERE job_id=X AND visit_id IS NULL AND invoice_id IS NULL` then re-insert loop (~92-103).

Write the union of columns they insert (e.g. `job_id, name, quantity, unit_price, total_price, jobber_line_item_id, …`) into a scratch note. This is the column contract Task A2 must match exactly.

- [ ] **Step 2: Confirm the delete predicate**

Confirm all three scope job-level lines as `job_id = X AND visit_id IS NULL AND invoice_id IS NULL` (and `quote_id IS NULL` where present). Note any writer that differs — the RPC must use the widest-safe predicate: `visit_id IS NULL AND invoice_id IS NULL AND quote_id IS NULL`.

### Task A2: Atomic per-job line-item rewrite RPC

**Files:**
- Create: `docs/migrations/2026-09-01_<t>_atomic_job_line_items_rewrite.sql`

- [ ] **Step 1: Write the failing probe (duplication reproduces without the RPC)**

In a rolled-back transaction against a disposable test job, prove the *current* behaviour can double a set. Apply this probe via the Management API and confirm it reports a doubled count (documents the bug the RPC removes):

```sql
-- pick a job with job-scope lines; DO block simulates two non-atomic delete+insert cycles interleaving
-- (delete-A, delete-B, insert-A, insert-B). Expected BEFORE the RPC: 2x the line set.
-- Roll back afterward. This is the red state.
```

Expected: the probe shows `2 * n` job-scope rows.

- [ ] **Step 2: Write the RPC**

```sql
-- 2026-09-01_<t>_atomic_job_line_items_rewrite.sql
-- WHAT: one atomic, per-job-serialized rewrite of job-scope line items, to end the concurrent
--   DELETE-then-INSERT duplication race (public.line_items has no unique key by design).
BEGIN;
CREATE OR REPLACE FUNCTION ops.rewrite_job_line_items(p_job_id bigint, p_lines jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  -- serialize concurrent rewrites of the SAME job; released at txn end
  PERFORM pg_advisory_xact_lock(hashtextextended('ops.rewrite_job_line_items', p_job_id));
  DELETE FROM public.line_items
   WHERE job_id = p_job_id AND visit_id IS NULL AND invoice_id IS NULL AND quote_id IS NULL;
  INSERT INTO public.line_items (job_id /*, <exact columns from Task A1> */)
  SELECT p_job_id /*, (l->>'name'), (l->>'quantity')::numeric, … per Task A1 mapping */
    FROM jsonb_array_elements(p_lines) AS l;
END $fn$;
REVOKE ALL ON FUNCTION ops.rewrite_job_line_items(bigint, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION ops.rewrite_job_line_items(bigint, jsonb) TO service_role;
NOTIFY pgrst, 'reload schema';
COMMIT;
```

Fill the INSERT column list + `jsonb_array_elements` mapping from Task A1 exactly. `service_role` only — the three callers all run as service_role.

- [ ] **Step 3: Apply the migration**

Apply via Management API. Expected: `[]` / HTTP 2xx.

- [ ] **Step 4: Write the passing probe (two concurrent rewrites via the RPC leave one set)**

Rolled-back probe: call `ops.rewrite_job_line_items(job, lines)` twice against the same test job inside overlapping subtransactions (or back-to-back) and assert the final job-scope count equals `n`, not `2n`. Include a positive control: a single call must still produce exactly `n`.

Expected: exactly `n` rows; control passes. Roll back.

- [ ] **Step 5: Commit**

```bash
git add docs/migrations/2026-09-01_<t>_atomic_job_line_items_rewrite.sql
git commit -m "Atomic per-job line-item rewrite RPC (ops.rewrite_job_line_items) to end the duplication race" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task A3: Route the three inbound writers through the RPC

**Files:**
- Modify: `supabase/functions/webhook-jobber/index.ts` (~1262-1271)
- Modify: `supabase/functions/sync-jobber-job-drift/index.ts` (~216-241)
- Create: `docs/migrations/2026-09-01_<t>_fn_record_client_job_uses_rewrite.sql` (CREATE OR REPLACE of `fn_record_client_job`'s line-item block)

- [ ] **Step 1: webhook-jobber — replace delete+insert with one RPC call**

In `handleJob`, where it does `db.from('line_items').delete().eq('job_id', entityId)` then `.insert(rows)`, replace both with:

```ts
await db.rpc('rewrite_job_line_items', { p_job_id: entityId, p_lines: rows });
```
where `rows` is the same array previously inserted, reshaped to the jsonb the RPC expects (keys per Task A1). Keep the `isSA` gate unchanged (SC/legacy still get an empty set → the RPC deletes and inserts nothing).

- [ ] **Step 2: sync-jobber-job-drift — same replacement** (~216-241), passing `row.id` and the diffed line array.

- [ ] **Step 3: fn_record_client_job — CREATE OR REPLACE to call the RPC**

Copy the live `fn_record_client_job` body from `pg_get_viewdef`-equivalent (`\sf` / `pg_get_functiondef`), and replace only its inline DELETE+INSERT line-item block with `PERFORM ops.rewrite_job_line_items(<gid's job id>, <lines jsonb>);`. Everything else byte-identical. Wrap in `BEGIN; CREATE OR REPLACE FUNCTION …; NOTIFY pgrst,'reload schema'; COMMIT;`.

- [ ] **Step 4: Deploy + apply**

```bash
cd Supabase && SUPABASE_ACCESS_TOKEN=<PAT> supabase functions deploy webhook-jobber --project-ref wbasvhvvismukaqdnouk
SUPABASE_ACCESS_TOKEN=<PAT> supabase functions deploy sync-jobber-job-drift --project-ref wbasvhvvismukaqdnouk
```
Apply the `fn_record_client_job` migration via Management API.

- [ ] **Step 5: Verify on a real reopen (117-BH / job 99900756)**

Reopen an SA job through the app (or call the edge fn) and, after the poll + drift windows, assert the job has exactly one line-item set:

```sql
SELECT count(*) FROM public.line_items
 WHERE job_id = (SELECT id FROM public.jobs WHERE job_number = 99900756)
   AND visit_id IS NULL AND invoice_id IS NULL;  -- expect the true count, never 2x
```

- [ ] **Step 6: Commit**

```bash
git add supabase/functions/webhook-jobber/index.ts supabase/functions/sync-jobber-job-drift/index.ts docs/migrations/2026-09-01_<t>_fn_record_client_job_uses_rewrite.sql
git commit -m "Route all three inbound line-item writers through ops.rewrite_job_line_items" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Phase B — Backend: preview RPC + reactivation edge function

### Task B1: `client.preview_job_action`

**Files:**
- Create: `docs/migrations/2026-09-01_<t>_preview_job_action.sql`

- [ ] **Step 1: Write the failing probe**

Rolled-back probe on 112-YA data: `SELECT client.preview_job_action(<112-YA client id>, <an SC job id>, 'close')` — expect an error (function does not exist).

- [ ] **Step 2: Write the RPC**

```sql
-- 2026-09-01_<t>_preview_job_action.sql
BEGIN;
CREATE OR REPLACE FUNCTION client.preview_job_action(p_client_id bigint, p_job_id bigint, p_action text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_status text; v_job jsonb; v_kind text; v_jobs_to_close jsonb := '[]'::jsonb;
  v_upcoming int := 0; v_other_sa int := 0; v_from text; v_to text := null;
  v_arch bool := false; v_unarch bool := false;
BEGIN
  SELECT status INTO v_status FROM public.clients WHERE id = p_client_id;
  v_from := v_status;
  -- classify the acted job (title-only)
  SELECT jsonb_build_object('job_number', j.job_number, 'title', j.title,
           'kind', CASE WHEN j.title ILIKE 'Service Agreement%' THEN 'SA'
                        WHEN lower(btrim(j.title)) = 'service call' THEN 'SC' ELSE 'legacy' END,
           'frequency_days', j.frequency_days, 'job_status', j.job_status),
         (CASE WHEN j.title ILIKE 'Service Agreement%' THEN 'SA'
               WHEN lower(btrim(j.title)) = 'service call' THEN 'SC' ELSE 'legacy' END)
    INTO v_job, v_kind
    FROM public.jobs j WHERE j.id = p_job_id;

  IF p_action = 'create' THEN
    IF v_status = 'ACTIVE' THEN v_to := 'RECURRING'; END IF;
  ELSIF p_action = 'reopen' AND v_kind = 'SA' AND v_status = 'ACTIVE' THEN
    v_to := 'RECURRING';
  ELSIF p_action = 'reopen' AND v_kind = 'SC' AND v_status = 'INACTIVE' THEN
    v_to := 'ACTIVE'; v_unarch := true;
  ELSIF p_action = 'close' AND v_kind = 'SA' THEN
    SELECT count(*) INTO v_other_sa FROM public.jobs
      WHERE client_id = p_client_id AND id <> p_job_id
        AND title ILIKE 'Service Agreement%' AND job_status <> 'archived';
    IF v_other_sa = 0 THEN v_to := 'ACTIVE'; END IF;
    v_jobs_to_close := (SELECT jsonb_agg(x) FROM (SELECT v_job AS x) t);
    SELECT count(*) INTO v_upcoming FROM client.v_visits_live
      WHERE job_id = p_job_id AND visit_status='scheduled' AND deleted_at IS NULL AND start_at >= now();
  ELSIF p_action = 'close' AND v_kind = 'SC' THEN
    v_to := 'INACTIVE'; v_arch := true;
    SELECT jsonb_agg(jsonb_build_object('job_number', j.job_number, 'title', j.title,
             'kind', CASE WHEN j.title ILIKE 'Service Agreement%' THEN 'SA'
                          WHEN lower(btrim(j.title))='service call' THEN 'SC' ELSE 'legacy' END,
             'upcoming_visits', (SELECT count(*) FROM client.v_visits_live vv
                                   WHERE vv.job_id = j.id AND vv.visit_status='scheduled'
                                     AND vv.deleted_at IS NULL AND vv.start_at >= now())))
      INTO v_jobs_to_close
      FROM public.jobs j WHERE j.client_id = p_client_id AND j.job_status <> 'archived';
    SELECT count(*) INTO v_upcoming FROM client.v_visits_live vv
      JOIN public.jobs j ON j.id = vv.job_id
      WHERE j.client_id = p_client_id AND j.job_status <> 'archived'
        AND vv.visit_status='scheduled' AND vv.deleted_at IS NULL AND vv.start_at >= now();
  END IF;

  RETURN jsonb_build_object(
    'job', v_job, 'action', p_action,
    'status_change', CASE WHEN v_to IS NULL THEN null ELSE jsonb_build_object('from', v_from, 'to', v_to) END,
    'jobs_to_close', COALESCE(v_jobs_to_close, '[]'::jsonb),
    'upcoming_visits_removed', v_upcoming, 'other_open_sa_count', v_other_sa,
    'will_archive_client', v_arch, 'will_unarchive_client', v_unarch);
END $fn$;
REVOKE ALL ON FUNCTION client.preview_job_action(bigint,bigint,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION client.preview_job_action(bigint,bigint,text) TO authenticated, service_role;
NOTIFY pgrst, 'reload schema';
COMMIT;
```

⚠ Confirm `client.v_visits_live` exists and carries `job_id, visit_status, deleted_at, start_at`; if the app's upcoming-visit source differs, use that. For `create`, callers pass `p_job_id = NULL` and `v_job`/`v_kind` come back null — the `create` branch only reads `v_status`, so that is fine.

- [ ] **Step 3: Apply + assert on 112-YA**

Apply. Then assert each branch against 112-YA's real jobs (rolled-back where a status is needed): e.g. `preview_job_action(112-YA, <SC job>, 'close')` returns `will_archive_client=true`, `status_change.to='INACTIVE'`, and `jobs_to_close` lists every open job with per-job `upcoming_visits`. Positive control: `preview_job_action(112-YA, <SA job>, 'reopen')` on an ACTIVE client returns `status_change={ACTIVE→RECURRING}`.

- [ ] **Step 4: Commit** (Supabase footer).

### Task B2: `unarchive-client` edge function

**Files:**
- Create: `supabase/functions/unarchive-client/index.ts`
- Reference: `supabase/functions/archive-client/index.ts` (mirror its structure/CORS/auth/verify-saga)

- [ ] **Step 1: Confirm Jobber supports the un-archive + reopen path**

Against a Jobber sandbox client (112-YA), confirm the GraphQL to un-archive a client and that `jobReopen` on its SC succeeds only after un-archive. Capture the exact mutation names. If Jobber cannot un-archive a client, STOP and escalate to Fred (spec §9 risk) before building.

- [ ] **Step 2: Write the edge function**

Mirror `archive-client` but reversed: (1) un-archive the client in Jobber; re-read until `isArchived === false`; (2) `jobReopen` the passed SC job GID; record its `job_status` via `fn_record_client_job`; (3) `client.update_client_status(client_id, 'ACTIVE', 'Client App: reactivated (reopened SC job #<n>)')`. Do NOT reopen any SA job. Branch on `data.ok`. Reuse `archive-client`'s CORS echo + staff-auth gate verbatim.

- [ ] **Step 3: Deploy** (`supabase functions deploy unarchive-client …`, respecting `config.toml verify_jwt`).

- [ ] **Step 4: Verify on 112-YA** — take it Inactive (via the app's close-SC once Phase C ships, or `archive-client` directly), call `unarchive-client`, assert Jobber `isArchived=false`, SC job open, `clients.status='ACTIVE'`, SA jobs still `archived`. Restore state.

- [ ] **Step 5: Commit** (Supabase footer).

---

## Phase C — Client App (Lovable). Each task = one Lovable prompt + a live check.

> No local source/tests. "Verify" = re-measure the live `clients.unclogme.app` DOM/network, or the DB after an action. Follow the Lovable workflow rules in `Building Apps/CLAUDE.md` (send one-line prompts; confirm the build; publish; reload-then-publish if the panel desyncs; verify against the LIVE bundle, not the chat).

### Task C1: Legacy jobs get no Reopen; status-aware SC/SA visibility

- [ ] **Step 1: Prompt** — one line:
> On the client detail page, gate the per-row "Reopen" control on the job TITLE: show it only when the job title starts with "Service Agreement" (case-insensitive) OR equals "Service Call" (case-insensitive, trimmed); for every other job (legacy, [OLD], odd free-text) show NO Reopen button (keep "Open in Jobber"). Additionally, when the client's status is INACTIVE, show Reopen ONLY on the Service Call job (it is the reactivation entry) and hide it on archived Service Agreement rows. Do not change any query, RPC, or the Supabase client.

- [ ] **Step 2: Publish** (reload-then-publish guard).
- [ ] **Step 3: Verify live** — on an Active client: an archived SC/SA row shows Reopen; a legacy/[OLD] row does not. On an Inactive client: only the SC shows Reopen. Screenshot each.

### Task C2: Context-aware reopen confirmation

- [ ] **Step 1: Prompt** — one line:
> Before reopening any job, first call the RPC `client.preview_job_action(client_id, job_id, 'reopen')` and show a confirmation dialog built from its result. If `status_change` is null, show a plain "Reopen this job?" dialog listing the one job (#number + title) with a Cancel / "Reopen job" pair that calls the existing reopen (save-client-job action:"reopen"). If `status_change.to` is "RECURRING", show the green "Make {client} a recurrent client?" dialog (see Task C3). If `will_unarchive_client` is true, show the reactivate dialog (Task C3). Do not change the emergency-access or auth logic.

- [ ] **Step 2: Publish + verify** — reopen an SC on an Active client shows the plain dialog; confirm reopens the job and leaves status unchanged; **line items are not doubled** (Phase A). Screenshot + `line_items` count.

### Task C3: The status dialogs

- [ ] **Step 1: Prompt (create SA → Recurrent)** — one line:
> When creating a new Service Agreement job and the client status is ACTIVE, after the New-SA form is submitted show a green confirmation "Make {client} a recurrent client?" that lists the new SA (from `client.preview_job_action(client_id, null, 'create')`) and the Active→Recurring transition; on confirm, run save-client-job action:"create", then call `client.update_client_status(client_id,'RECURRING', 'Client App: created SA job → recurrent')`, then `client.generate_visits_for_client(client_id)`. If the client is not ACTIVE, create the SA with no status dialog.

- [ ] **Step 2: Prompt (reopen SA → Recurrent)** — one line:
> Reuse the green "Make {client} a recurrent client?" dialog for reopening an SA when `preview_job_action` returns status_change.to = 'RECURRING'; on confirm, save-client-job action:"reopen", then `client.update_client_status(client_id,'RECURRING', 'Client App: reopened SA job #<n> → recurrent')`, then `client.generate_visits_for_client(client_id)`.

- [ ] **Step 3: Prompt (close last SA → Active)** — one line:
> When closing a Service Agreement, use `client.preview_job_action(client_id, job_id, 'close')`. If `other_open_sa_count` is 0, show a neutral "Close this service agreement?" dialog listing the SA and its `upcoming_visits_removed`, and the Recurring→Active transition; on confirm, save-client-job action:"close", then `client.update_client_status(client_id,'ACTIVE','Client App: closed last SA job #<n>')`. If `other_open_sa_count` > 0, show the plain close confirm and change no status.

- [ ] **Step 4: Prompt (close SC → Inactive)** — one line:
> When closing the Service Call job, use `client.preview_job_action(client_id, job_id, 'close')` and show a RED destructive dialog "Close service call and deactivate {client}?" that lists EVERY job in `jobs_to_close` (#number + title + per-job upcoming count), the total `upcoming_visits_removed`, an "archived in Jobber" note, and the →Inactive transition; on confirm, call the `archive-client` edge function (which archives the client in Jobber, auto-closing all jobs, and sets INACTIVE). Do not close jobs individually first.

- [ ] **Step 5: Prompt (reactivate)** — one line:
> When Reopen is used on the Service Call of an INACTIVE client, show an info dialog "Reactivate {client}?" (from `preview_job_action` with `will_unarchive_client`=true) noting it un-archives in Jobber and reopens the Service Call, old agreements stay closed, and the Inactive→Active transition; on confirm, call the new `unarchive-client` edge function. To make an inactive client recurring again, the app must offer CREATE a new SA (never reopen an archived one).

- [ ] **Step 6: Publish after each; verify live per Phase D.**

---

## Phase D — End-to-end test on 112-YA (spec §6, the multi-visual-check)

For each step: screenshot the UI + verify the DB (`jobs.job_status`, `clients.status`/`status_source`, `line_items` count, `client_status_changes`, upcoming visits). Restore 112-YA to baseline at the end.

- [ ] **D0 Baseline** — record 112-YA's jobs (numbers/titles/statuses), status, line-item counts.
- [ ] **D1 Legacy no-reopen** — legacy row has no Reopen; SC/SA archived rows do.
- [ ] **D2 Reopen confirm (no status)** — reopen an SC: plain dialog; job opens; status unchanged; line items NOT doubled.
- [ ] **D3 Create SA → Recurrent** — 🟢 dialog; confirm; `clients.status=RECURRING`, `status_source=manual`, a `client_status_changes` row, visits generated.
- [ ] **D4 Reopen SA → Recurrent** — 🟢 dialog; confirm; status→Recurring.
- [ ] **D5 Close last SA → Active** — ⚪ dialog lists the SA + upcoming count; confirm; status→Active; SA visits soft-deleted.
- [ ] **D6 Close SC → Inactive** — 🔴 dialog lists every open job + per-job counts + "archived in Jobber"; confirm; `archive-client` archives client (`isArchived=true`), all jobs `archived`, `clients.status=INACTIVE`, visits removed.
- [ ] **D7 Reactivate** — Reopen the archived SC: 🔵 dialog; confirm; `unarchive-client` → `isArchived=false`, SC open, `status=ACTIVE`; old SA stays `archived`; archived SA rows show no Reopen while Inactive.
- [ ] **D8 Inactive → Recurring uses a NEW SA** — going Recurring prompts create-new-SA, never reopen the archived SA.
- [ ] **D9 Duplication regression** — after the D2/D4/D7 reopens, each affected job has exactly one line-item set.
- [ ] **D10 Restore** — return 112-YA to baseline.

---

## Phase E — Documentation

- [ ] **E1** Memory `project_recurring_client_authoritative_source.md` + `Supabase/CLAUDE.md` "`clients.status`" section: record that **Client-App job actions are now the confirmed driver of `clients.status`**, superseding the 2026-07-15 "not authoritative" rule for app-driven changes (Jobber poll still owns archive-driven INACTIVE).
- [ ] **E2** `Building Apps/Client App/docs/08-changelog.md` (dated entry) + `09-known-issues.md` (close the reopen-duplication item; note the ~6 mis-titled jobs get no Reopen by design) + Client App `CLAUDE.md` (the status-driving rule + the `preview_job_action` contract + `unarchive-client`).
- [ ] **E3** `Supabase/docs/` migration headers cross-reference this plan and the spec.

---

## Self-review notes (author)

- **Spec coverage:** legacy gate (C1), reopen confirm (C2), dup fix (A), preview RPC (B1), the four/five dialogs + status calls (C3), reactivation + `unarchive-client` (B2/C3-5), close-SC = single `archive-client` (C3-4), 112-YA test (D), docs incl. authority re-ruling (E). All spec §4–§8 items map to a task.
- **Known non-TDD reality:** Phase C has no local tests; its gate is the live 112-YA verification in Phase D — stated up front, not hidden.
- **Placeholders that are deliberate, not failures:** `<t>` = the HHMM timestamp at apply time; the Task A1 column list + the live `fn_record_client_job` body are captured from the running system in their own steps (A1, A3-3) precisely because retyping them is the "copy don't retype" hazard — the plan routes around it rather than inventing a column list.
- **Type consistency:** the preview JSON keys (`status_change`, `jobs_to_close`, `upcoming_visits_removed`, `other_open_sa_count`, `will_archive_client`, `will_unarchive_client`) are identical in B1 and every C3 prompt.
