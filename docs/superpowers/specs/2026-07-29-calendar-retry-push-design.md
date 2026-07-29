# Calendar "retry push to Jobber" — auto-retry + manual escape hatch

**Date:** 2026-07-29 · **Author:** @Supabase 2 · **Status:** approved by Fred, not yet built
**Split:** backend + data contract = @Supabase 2. Button + dialog = @Building Apps (sole owner of Lovable `6533c3ee`).

---

## 1. Why

A visit created in the Visit Calendar is pushed to Jobber by `fn_push_visit_to_jobber` →
`jobber-push-visit`. When that push fails, the visit sits in the Calendar showing
`Sync issue: not_in_jobber` and nothing retries it. On 2026-07-28 a ~25-minute Jobber failure
window stranded visits **7409** (283-PIK) and **7410** (021-GRA) exactly this way.

**The measured shape of the problem decided the design.** From `audit.logs`, 30 days to 2026-07-29:

| Metric | Value |
|---|---|
| Transitions into `sync_state='failed'` | ~19 (≈0.6/day) |
| Distinct visits that ever failed | 17 |
| Of those, later reached `confirmed` | **16** |
| Still failed today | **0** |

So failures are **rare and almost always transient**. They are not permanent breakage; they are
*latency and visibility* problems — a visit looks broken until something incidental re-pushes it.
A purely manual button would therefore make a human do work that the system can do itself in the
overwhelming majority of cases.

**Fred's decisions (2026-07-29):**
1. **Auto-retry is the primary mechanism; the button is an escape hatch** that only matters once
   auto-retry gives up.
2. **Duplicate handling is asymmetric:** auto-retry *refuses outright* and never pushes a probable
   duplicate; the manual button *warns via a confirmation dialog* and lets a human proceed. And —
   Fred's addition — **the drawer must say that auto-retry stopped because of a probable duplicate**,
   rather than stopping silently.

That last point is the whole lesson of 2026-07-28/29 restated: a stop nobody can see is
indistinguishable from a system that is working.

---

## 2. The duplicate problem, precisely

Retrying a push for a visit with no Jobber link **creates** a Jobber visit. If the same work already
reached Jobber under a different visit row, the retry puts a phantom stop on a real crew's schedule.

This is not hypothetical — it is the 7409/7417 shape:

| Visit | Service | In Jobber? |
|---|---|---|
| 7409 | `22 - Service Call - Labor` | no (push failed) |
| 7417 | `18 - Service Call - Unclogging - Commercial - Hydrojet` | yes, and completed |

Same client (283-PIK), same date, same job (1721), created 2 hours apart. Almost certainly a
mis-picked service code that was recreated correctly — Fred soft-deleted 7409 on 2026-07-29 10:03 ET,
confirming that reading.

⚠ **But "same client + same day" is NOT proof of duplication.** Measured live: **45 client/day pairs
carry more than one visit**. Some are genuinely two distinct services in one day. Therefore the guard
must be **advisory, never absolute** — which is precisely why the human path warns and the machine
path refuses.

---

## 3. Architecture

```
push fails ──> jobber-push-visit catch ──> visit_sync_flags (reason, detail)   [SHIPPED c865608]
                                                │
                     ┌──────────────────────────┴───────────────────────────┐
                     │                                                      │
        pg_cron calendar-push-auto-retry (*/5)              ops.v_calendar_push_health
        backoff 1/5/15/60, max 4 attempts                   (+ duplicate_of_visit_id,
                     │                                        attempts, auto_retry_state)
        duplicate risk? ──yes──> auto_retry_state='blocked_duplicate', STOP     │
                     │            (attempts NOT consumed)                       │
                     no                                                         v
                     │                                              Calendar drawer (Building Apps)
                     v                                              amber box + Retry button
        fn_request_jobber_push(visit_id,'upsert')  <───────── retry_visit_push(visit_id, force)
```

Nothing here re-implements pushing. `fn_request_jobber_push(p_visit_id bigint, p_op text)` already
exists (SECURITY DEFINER, used by `sync-jobber-visit-drift`'s HEAL path) and is the single primitive
both the auto-retry and the manual RPC call.

---

## 4. Backend components (@Supabase 2)

### 4.1 `public.fn_visit_push_duplicate_of(p_visit_id bigint) → bigint`

Returns the id of a sibling visit that is **already linked to Jobber** for the same
`client_id` + `visit_date` + `job_id`, when `p_visit_id` itself has **no** Jobber link.
`NULL` = no duplicate risk.

- `STABLE`, `SECURITY INVOKER`, `SET search_path TO 'public','pg_temp'`.
- Ignores `deleted_at IS NOT NULL` rows on both sides.
- Prefers the *most recently created* linked sibling when several match (deterministic, and the most
  likely intended replacement).
- ⚠ **Grants:** Supabase default privileges auto-grant new functions to `anon`/`authenticated`/
  `service_role`, and `REVOKE ... FROM PUBLIC` alone does not undo that
  (`reference_supabase_function_default_privileges`). Revoke explicitly, then
  `GRANT EXECUTE TO authenticated, service_role`. **anon stays out.**
- ⚠ It is SECURITY INVOKER *and* it is called from `ops.v_calendar_push_health`. Function EXECUTE is
  **not** laundered through an owner-rights view (three incidents: 2026-07-28h, 2026-07-28t). Any role
  that can read that view — today `authenticated`, and `yannick_readonly` holds SELECT on `ops.*` —
  must hold EXECUTE, or it gets `42501` on a view it is allowed to read. **Verify both roles before
  declaring done.**

### 4.2 Retry state on `public.visit_sync_flags`

Add three columns:

| Column | Type | Meaning |
|---|---|---|
| `attempts` | `int NOT NULL DEFAULT 0` | auto-retry attempts consumed |
| `next_attempt_at` | `timestamptz` | when the driver may next try; NULL = not scheduled |
| `auto_retry_state` | `text` | `pending` \| `exhausted` \| `blocked_duplicate` |

Chosen over new columns on `visits` because this table already holds *why a push failed* and is keyed
`PRIMARY KEY (visit_id)`; retry bookkeeping is the same concern.

**RULE 8 (ADR 010) — audit standing check: OPT-OUT, unchanged and documented.** `visit_sync_flags` is
sync-control machinery, not human-editable business data; it carries no audit trigger today (only
`trg_visit_sync_flags_updated_at`). These columns record retry mechanics, not a business fact, so they
introduce nothing an audit trail must attribute. The *visit* rows the retry ultimately writes remain
fully audited via `visits`.

### 4.3 Auto-retry driver — pg_cron `calendar-push-auto-retry`, `*/5 * * * *`

Each tick, for unresolved flags where `next_attempt_at <= now()` and `attempts < 4`:

1. If `fn_visit_push_duplicate_of(visit_id)` is **not** NULL → set
   `auto_retry_state='blocked_duplicate'`, `next_attempt_at=NULL`, **do not consume an attempt**, and
   stop. A human decides from here.
2. Otherwise → `attempts := attempts + 1`, schedule the next slot from the backoff ladder
   (**1 min → 5 min → 15 min → 60 min**), and call `fn_request_jobber_push(visit_id,'upsert')`.
3. On the 4th exhausted attempt → `auto_retry_state='exhausted'`, `next_attempt_at=NULL`.

Success needs no special handling: `jobber-push-visit` already calls `clearFlag()` when a visit
settles (shipped `c865608`), which resolves the flag and drops it off the health board.

⚠ **This job calls `fn_request_jobber_push` directly in SQL. It must NOT use `net.http_post` with an
inline key.** `jobber-visit-drift-reconcile` stores its `x-sync-key` in cleartext in
`cron.job.command`, readable by anyone with `cron.job` SELECT. Do not copy that pattern.
(Separate remediation item — see §8.)

### 4.4 `public.retry_visit_push(p_visit_id bigint, p_force boolean DEFAULT false) → jsonb`

`SECURITY DEFINER`, `SET search_path TO 'public','pg_temp'`, **granted to `authenticated` only**.

| Condition | Returns | Pushes? |
|---|---|---|
| visit missing / `deleted_at` set | `{ok:false, error:'not_found'}` | no |
| duplicate risk, `p_force=false` | `{ok:false, blocked:'duplicate', duplicate_of:<id>, duplicate_of_service:<text>}` | **no** |
| duplicate risk, `p_force=true` | `{ok:true, forced:true}` | yes |
| no duplicate risk | `{ok:true}` | yes |

On any push it resets `attempts=0`, `auto_retry_state='pending'`, `next_attempt_at=NULL` — a human
retry restores the automatic ladder rather than fighting it.

SECURITY DEFINER is required (it writes `visit_sync_flags` and calls a definer-only primitive), so the
pinned `search_path` is mandatory, not decorative.

### 4.5 Extend `ops.v_calendar_push_health`

Append `duplicate_of_visit_id`, `attempts`, `auto_retry_state`. `CREATE OR REPLACE VIEW` may only
**append** columns — appending satisfies that, so grants are preserved and no DROP is needed.

### 4.6 ⚠ NEW `ops.v_calendar_push_health_by_visit` — one row per visit (AMENDMENT, 2026-07-29)

**This section exists because @Building Apps caught a live defect in the §5 contract during review.**

The Calendar drawer collapses the health rows into a `Map` keyed on `visit_id`. That assumes one row
per visit. **The view does not guarantee that** — it is a `UNION ALL` of branches whose predicates
overlap, so a visit can appear more than once and the Map silently keeps an arbitrary winner.

Reproduced live (rollback transaction, 2026-07-29): visit **7409 returned 2 rows at once —
`not_in_jobber` + `push_failed`**.

⚠ **This is not an edge case; `c865608` made it the norm.** Now that the push function records a
reason on every unanticipated failure, *any* failed push on an unlinked Calendar visit produces both
rows. And the `push_failed` row is the one carrying `reason`/`detail`, so the Map can keep the bare
`not_in_jobber` row and drop the only row that explains what went wrong — defeating the entire point
of wiring the failure reason.

**Do NOT fix this by deduping `ops.v_calendar_push_health` itself.** `public.log_calendar_push_health()`
aggregates *every* row into `sync_log.details` and counts them; deduping would silently shrink the ops
log and hide real issues. The diagnostic feed must stay complete.

So: add a second, UI-facing view. One rule, in SQL, that cannot drift the way duplicated client-side
logic would.

```sql
CREATE VIEW ops.v_calendar_push_health_by_visit AS
SELECT DISTINCT ON (h.visit_id)
       h.visit_id, h.client_code, h.client_name, h.visit_date, h.source,
       h.issue, h.reason, h.detail, h.since,
       h.duplicate_of_visit_id, h.attempts, h.auto_retry_state,
       (SELECT array_agg(DISTINCT h2.issue)
          FROM ops.v_calendar_push_health h2
         WHERE h2.visit_id = h.visit_id) AS all_issues
  FROM ops.v_calendar_push_health h
 ORDER BY h.visit_id,
          CASE h.issue WHEN 'push_failed'         THEN 1
                       WHEN 'skip_removal_failed' THEN 2
                       WHEN 'not_in_jobber'       THEN 3
                       ELSE 4 END;
```

Priority is deliberate: **`push_failed` wins because it is the only branch carrying `reason`/`detail`.**
`all_issues` preserves the full set so nothing is lost by collapsing.

Grants: `SELECT` to `authenticated`, `service_role`, `yannick_readonly` (mirroring the base view);
**anon excluded**. New views in an exposed schema come out anon-readable under Supabase's default
privileges — revoke explicitly, do not assume.

**§5 contract changes:** the drawer reads **`v_calendar_push_health_by_visit`**, not
`v_calendar_push_health`.

---

## 5. UI contract (@Building Apps)

**Read** from **`ops.v_calendar_push_health_by_visit`** (NOT the base view — see §4.6): `issue`,
`reason`, `detail`, `attempts`, `auto_retry_state`, `duplicate_of_visit_id`, `all_issues`.
⚠ The drawer's `.select()` is an **explicit column list**, not `*`, so the new columns surface only
once @Building Apps extends that string. The view change will look inert until then — that is
expected, not a failed migration.

**Drawer amber box** — today it renders only `Sync issue: not_in_jobber`. It must additionally show:

- `reason` / `detail` when present (e.g. `push_exception — Jobber API 503`)
- when `auto_retry_state = 'blocked_duplicate'`:
  **"Auto-retry stopped — likely duplicate of visit #<id> on the same day."**
- when `auto_retry_state = 'pending'`: that a retry is scheduled (attempt N of 4), so nobody clicks
  a button the system is about to press itself
- when `auto_retry_state = 'exhausted'`: that automatic retries gave up

**Button** — `Retry sync` → `rpc('retry_visit_push', { p_visit_id })`.
If the response carries `blocked:'duplicate'` → confirmation dialog naming the sibling visit and its
service → on confirm, re-call with `p_force: true`. On success, refetch the drawer.

**UI/UX direction:**

- **Colour: the amber family.** This app already uses amber for Jobber push/sync health, and red is
  taken twice over — the lateness left-edge and the visiting-hours `clock-alert`. A red retry control
  would read as danger and collide with two existing meanings.
- **Position:** inside the existing amber box, below the reason text — the control belongs with the
  problem it solves, not floating among `Mark complete` / `Details` / `Open in Jobber`.
- **Size/style:** secondary/outline, matching the drawer's existing button height so it does not
  outrank `Mark complete`, which is the primary action on that surface.
- **States:** disabled + spinner while in flight; success toast; error toast carrying the returned
  message. Never leave the button in a state where a double-click issues two pushes.
- **Accessibility (@Building Apps amendment, accepted):** the amber box is `role="status"` today,
  correct for `pending` ("aware, working on it"). For **`blocked_duplicate` and `exhausted` the system
  has stopped and needs a human**, so those render `role="alert"`. Same colour, same position,
  different announcement urgency.
- **No countdown.** The drawer already refetches health every 30s (`staleTime: 30_000`), so relative
  copy ("retry scheduled, attempt 2 of 4") self-corrects without countdown machinery — and the backoff
  ladder is "at least this long", not exact (risk #4), so a to-the-minute time would be a lie.

---

## 6. Testing

**Backend (me), before handover:**
1. `fn_visit_push_duplicate_of` against the real 7409/7417 shape (expect 7417) and across all **45**
   same-client/same-day pairs — confirm it never returns a sibling that is itself unlinked or deleted.
2. `retry_visit_push` blocked path and forced path, in `BEGIN … ROLLBACK`.
3. Grant matrix: `authenticated` and `yannick_readonly` can execute what the view needs; `anon` cannot
   execute either function.
4. Auto-retry ladder: seed a flag, confirm attempts increment on schedule, that a duplicate-risk row
   goes `blocked_duplicate` **without** consuming an attempt, and that the 4th failure sets
   `exhausted`.

**Joint with @Building Apps, live:**
5. Force a real push failure on a disposable visit → confirm the drawer shows reason + scheduled
   retry → watch auto-retry clear it with no human action.
6. Force a failure on a visit with a linked same-day sibling → confirm auto-retry **stops** and the
   drawer explains why → click `Retry sync` → confirm dialog names the sibling → confirm → verify the
   visit appears in Jobber.
7. Clean up every test visit; verify zero residue.

---

## 7. Out of scope (v1)

- **Slack escalation on `exhausted`.** Failures run ~0.6/day and the daily `calendar-push-health-check`
  already logs. Ship, then decide from evidence. (YAGNI.)
- **Bulk "retry all".** One button per visit until we see a case where several fail at once that
  auto-retry did not already clear.
- **Retrying `push_failed` causes that are not push-related** (`unmapped_employee`, `no_job_match`).
  Those need a data fix, not a retry; the button should surface the reason and stop.

---

## 8. Open risks and doubts — read before building

1. **The duplicate heuristic will produce false positives.** 45 same-client/same-day pairs exist. Some
   are legitimately two services. This is accepted: the machine refuses, the human overrides. But if
   staff routinely hit the confirm dialog, the heuristic is too broad and should tighten to *same
   `service_line_item_id`* rather than same day. **Watch the override rate.**
2. **The reverse risk is worse and cannot be fully closed.** A sibling in Jobber that is *not* in our
   `entity_source_links` is invisible to this guard, so a duplicate could still be created. The guard
   reduces the risk; it does not eliminate it.
3. **`retry_visit_push` is a user-triggered write to Jobber.** It must be `authenticated`-only, never
   `anon`. The 2026-07-12 harden made anon read-only on business data and this must not reopen that.
4. **`attempts < 4` with a `*/5` cron means the ladder can drift** — a 1-minute backoff is not honoured
   more precisely than the 5-minute tick. Accepted: the ladder is "at least this long", not exact.
   Do not add a second faster cron to fix this.
5. ~~Unverified assumption: that the drawer reads the health view rather than deriving the flag
   client-side.~~ **RESOLVED 2026-07-29** — @Building Apps confirmed against the deployed bundle:
   the drawer queries the view directly and `"not_in_jobber"` appears zero times as a literal, so the
   label is composed from our data. Reviewing that hook is what surfaced the one-row-per-visit defect
   now fixed in §4.6, and revealed that `reason` is already fetched but never rendered — so half the
   §5 ask is pre-built.
6. ⚠ **Pre-existing secret exposure, unrelated to this work but found during it:**
   `cron.job.command` for `jobber-visit-drift-reconcile` contains a plaintext `x-sync-key`. It should
   be rotated and moved to Vault (as `jobber_push_service_key` already is). Flagged to Fred
   2026-07-29.


---

## 9. Post-build corrections (2026-07-29, after the backend shipped)

Two real defects, both found by exercising the system rather than reading it.

### 9.1 The view 403'd for every real user — SECURITY INVOKER inside an owner-rights view

@Building Apps captured `GET /rest/v1/v_calendar_push_health_by_visit?select=… -> 403` from the live
Calendar. Reproduced as the actual role:

```
BEGIN; SET LOCAL ROLE authenticated;
SELECT * FROM ops.v_calendar_push_health_by_visit LIMIT 1;
-- ERROR 42501: permission denied for table entity_source_links
-- CONTEXT: SQL function "fn_visit_push_duplicate_of" statement 1
```

**This is the exact trap §4.1 of this spec warns about, and I verified the wrong half of it.** I checked
that `authenticated` held EXECUTE on the function — necessary, and not sufficient. The function was
SECURITY INVOKER, so it read `entity_source_links` as the *caller*, who has no SELECT on that table.
Table grants launder through an owner-rights view; the function body does not.

Fixed in `2026-07-29b`: the helper is now SECURITY DEFINER with a pinned `search_path`, the pattern
CLAUDE.md already prescribes. Chosen over granting `authenticated` SELECT on the whole cross-system
bridge table.

⚠ **Why every test missed it:** all of them ran through the Management API, i.e. as `postgres`, which
can read everything. `retry_visit_push` also passed because it is SECURITY DEFINER and therefore
called the helper in a definer context — the view was the only path that ran it as the caller.
**A grant matrix proves who may EXECUTE; it says nothing about what the function touches once it runs.
Test as the role, not as the owner.**

### 9.2 `app.suppress_jobber_push` does NOT stop a staged visit from reaching Jobber

Six test visits were staged with the push suppressed, and **five were pushed to Jobber anyway** within
3 minutes, creating real (test-client) visits that then had to be deleted.

Cause: suppression stops the *synchronous trigger*. It does not remove the row from the
**`sync_state='pending'` queue**, and a pre-existing pg_cron drains that queue every 3 minutes:

```
resolve-stale-visit-sync-pending   */3
  WHERE source IN ('visit-calendar','supabase_cron') AND deleted_at IS NULL
    AND updated_at < now() - interval '3 minutes'
    AND visit_status='scheduled' AND sync_state='pending'
```

`trg_mark_visit_sync_pending` sets `pending` on insert, so a suppressed insert still enqueues.

**Correct way to stage a failed-push visit: set `sync_state='failed'`, not `pending`.** That both
matches what the row represents and falls outside the drain cron's predicate. Removal is the sanctioned
path — soft-delete WITHOUT suppression, which pushes the delete and clears Jobber (verified: all five
returned "Visit not found" afterwards).
