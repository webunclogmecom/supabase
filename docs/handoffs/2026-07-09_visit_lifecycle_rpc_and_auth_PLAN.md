# PLAN — `set_visit_status` RPC + staff-auth gate (close the anon lifecycle hole)

*2026-07-09. Scoped + approved by Fred. Closes the accepted residual from the visits RLS lockdown
(`159e1c6`): an anon-key holder can still set `visit_status='cancelled'` on any visit → a real Jobber
`visitDelete`, and can still call the intentionally-anon lifecycle RPCs. Multi-phase, spans the
Supabase DB + the Visit Calendar Lovable app (+ a login gate on the other 3 staff apps). DB and app
phases MUST land in the order below — revoking before the apps migrate breaks the Calendar.*

## Why
`public.visits` writes ride the **public anon key** (in every app bundle). The 2026-07-09 column-grant
lockdown closed `deleted_at` + all schedule/attribution columns, but `visit_status` had to stay
grantable because the Calendar writes it directly (complete/incomplete/cancel), and
`visit_status='cancelled'` fires `trg_push_visit_update` → `jobber-push-visit` → a real Jobber
`visitDelete`. So a stranger with the public key can still delete visits from Jobber. The only durable
close is: (a) route every `visit_status` transition through ONE guarded RPC, (b) grant it to
`authenticated` only, (c) require staff login so the apps act as `authenticated`, then (d) revoke the
direct `visit_status`/`completed_at` grants entirely.

## Confirmed decisions (Fred, 2026-07-09)
1. **Auth scope:** the 4 STAFF apps require login — Visit Calendar, Admin Review, DERM Tracker, Stamp
   Studio. **Field Portal stays anon** (customer portal, client-code access, read-only, zero lifecycle
   writes — no residual, must not demand a staff login from customers).
2. **cancel == skip in Jobber:** both remove exactly ONE occurrence from Jobber and PRESERVE the SA
   series (the next scheduled occurrence stays / is promoted). The ONLY difference is the label/reason
   shown in our apps. (Today's raw `cancelled` write does NOT promote the next SA occurrence — the RPC
   fixes that so cancel matches skip.)
3. **Authorization:** ANY logged-in staff user may perform ANY lifecycle action on ANY visit (no
   office-vs-field split for now; the `employees.access_level` data exists to add it later).

## Current reality (verified 2026-07-09)
- **Auth already exists + is used:** 4 `auth.users` (fred@ayache.com, yannick@ayache.com,
  unclogme@unclogme.com, contact@unclogme.com), all signing in (last 2026-07-08). The Calendar client
  already references `auth.getSession` / `onAuthStateChange` / `persistSession` — it is auth-capable;
  it just doesn't REQUIRE a session today.
- **`skip_visit(p_visit_id, p_reason)`** (SECDEF, granted anon+authenticated) already does the SA rule:
  sets `visit_status='skipped'` (→ trigger deletes this Jobber visit) THEN promotes the next scheduled,
  unlinked, in-Jobber-scope SA occurrence for the same `job_id` (marks it `sync_state='pending'` +
  `fn_request_jobber_push(next,'upsert')`). This gap-fill is the reusable core for cancel.
- **No `cancel` RPC exists** — cancel is only the raw `visit_status='cancelled'` direct write (the hole).
- **`delete_calendar_visit(p_visit_id)`** (SECDEF) = hard lifecycle (sets `deleted_at` → Jobber delete);
  stays as-is (that's "this visit should not exist", distinct from cancel/skip).
- **Push delete-arm** (`jobber-push-visit` `handle()`): `op='delete'` when `deleted_at` OR
  `visit_status IN ('cancelled','skipped')` → one `visitDelete` on this visit's GID. So the RPC does
  NOT push the delete itself — setting the status fires the trigger; the RPC only owns the DB write +
  the SA gap-fill.
- **Current direct anon/authenticated `visits` writes to migrate/keep** (from the 2026-07-09 bundle
  audit): Calendar → `visit_status`, `completed_at` (MIGRATE to RPC); Admin Review → `manhole_count`
  (KEEP direct, not a delete vector); DERM Tracker → `derm_required` (KEEP direct, not a delete vector).

---

## Part A — `public.set_visit_status` RPC

**Signature:** `set_visit_status(p_visit_id bigint, p_status text, p_reason text DEFAULT NULL) RETURNS public.visits`
- SECURITY DEFINER, `SET search_path=public`.
- **GRANT EXECUTE TO `authenticated` ONLY** (NOT anon, NOT during-phase — see rollout). `REVOKE` from
  PUBLIC/anon.
- Guard: require an authenticated caller — `IF auth.uid() IS NULL THEN RAISE EXCEPTION 'login required'`
  (defence beyond the grant, so even a mis-grant can't let anon through).

**Allowed transitions** (reject anything else with a clear message):

| p_status | precondition | DB effect | Jobber (via trigger) | SA series |
|---|---|---|---|---|
| `completed` | current = scheduled | `visit_status='completed'`, `completed_at=now()`, `completed_by`=caller's employee | (no delete; existing complete behavior) | untouched |
| `scheduled` (uncomplete) | current = completed | `visit_status='scheduled'`, `completed_at=NULL` | (no delete) | untouched |
| `skipped` | current = scheduled | `visit_status='skipped'`, `skip_reason=p_reason` | delete THIS visit | **promote next occurrence** |
| `cancelled` | current IN (scheduled, completed) | `visit_status='cancelled'`, `skip_reason=p_reason` | delete THIS visit | **promote next occurrence** |

- `skipped` + `cancelled` share ONE code path (the existing `skip_visit` gap-fill: find + `sync_state
  ='pending'` + `fn_request_jobber_push` the next scheduled/unlinked/in-scope SA occurrence for the same
  `job_id`). Refactor `skip_visit`'s promotion block into a helper `fn_promote_next_sa_occurrence(job_id)`
  and call it from both `set_visit_status` and the (retained) `skip_visit`.
- `source` normalization identical to `skip_visit` (keep visit-calendar/supabase_cron, else set
  visit-calendar) so the push trigger fires.
- `FOR UPDATE` row lock; reject `deleted_at IS NOT NULL`.
- Attribution: the RPC runs SECDEF so the audit `app_source` resolves from the caller origin
  (visit-calendar / admin-review); the caller's `auth.uid()` → the acting user is captured in
  `completed_by` for complete, and can be recorded in the audit `request_context` (jwt sub) for others.
- **`skip_visit`/`unskip_visit` stay** (DERM/other callers may use them) but their anon grant is revoked
  in Phase 3 (authenticated-only, or route through set_visit_status).

**Acceptance (Phase 1):** call the RPC with a service-role/authenticated JWT for each transition on a
112-YA TEST visit; verify DB state + that skip/cancel of an SA occurrence deletes ONLY that Jobber visit
and the next occurrence is present in Jobber; illegal transitions raise; anon EXECUTE is denied.

## Part B — staff-auth gate (the 4 staff apps)
Each of **Visit Calendar, Admin Review, DERM Tracker, Stamp Studio**:
- On load, `supabase.auth.getSession()`; if no session → render a login screen (email + password against
  the existing `auth.users`); gate the app UI behind an active session; `onAuthStateChange` to react to
  logout/expiry. (The clients are already auth-capable; this is a routing/guard addition, not new infra.)
- After login the app's PostgREST calls carry the user JWT → role `authenticated` → `set_visit_status`
  (and the retained direct `manhole_count`/`derm_required` writes) run as `authenticated`.
- **Field Portal: NO change** (stays anon/customer-code, read-only).
- Staff accounts: 4 exist; add the rest of the crew/office as needed (Supabase Auth dashboard or an
  invite flow) — enumerate real staff with Fred before cutover.
- Owner: the **Building Apps session** (Lovable app changes) — coordinate via WORKING-NOW.md.

**Acceptance (Phase 2):** each staff app requires login (no-session → login screen, live-verified);
after login, every existing write path works (Calendar complete/incomplete/cancel/skip via the RPC +
edit/create/delete/ripple; Admin Review manhole; DERM toggle; Stamp writes); Field Portal unchanged.

## Part C — final DB lock
Once Phase 2 is live-verified on all 4 apps:
- `REVOKE UPDATE (visit_status, completed_at) ON public.visits FROM anon, authenticated;`
  (lifecycle becomes RPC-only; `manhole_count`, `derm_required` grants remain — authenticated-only after
  the login gate, and they are not Jobber-delete vectors).
- Revoke the anon EXECUTE on `skip_visit`/`unskip_visit`/`delete_calendar_visit`/`edit_calendar_visit`/
  `ripple_reschedule_visit`/`create_calendar_visit` → `authenticated` only (so an anon key can't call
  the lifecycle RPCs either). Verify each app still calls them as authenticated post-login.
- **Negative test (must now PASS-as-blocked):** with the raw anon key (extracted from a bundle),
  `PATCH visit_status='cancelled'` → 42501; `rpc/set_visit_status` → 401/permission denied;
  `rpc/delete_calendar_visit` → denied. Re-run the full `rls_verify.js` matrix.

## Rollout order (STRICT — do not collapse)
1. **Phase 1 (DB, low risk):** ship `set_visit_status` + `fn_promote_next_sa_occurrence`; grant
   authenticated. Keep ALL current grants intact → zero app impact. Verify via authenticated JWT.
2. **Phase 2 (apps, Building Apps session):** migrate Calendar lifecycle → RPC; add login gate to the 4
   staff apps. Publish + live-verify each. (Field Portal untouched.)
3. **Phase 3 (DB lock):** revoke direct `visit_status`/`completed_at` + anon EXECUTE on the lifecycle
   RPCs. Re-run negative tests. Residual CLOSED.

## Risks / rollback
- **Ordering:** revoking in Phase 3 before Phase 2 ships breaks the Calendar (403 on complete/cancel).
  Gate Phase 3 on a written "all 4 apps migrated + verified" checkpoint.
- **Stale tabs:** a staff member on a pre-migration cached tab hits 403 after Phase 3 → refresh + login
  fixes. Announce before Phase 3.
- **Auth friction:** requiring login changes daily staff UX — confirm the crew has accounts + the login
  is smooth before cutover.
- **Rollback:** each phase is independently revertable — Phase 3 by re-`GRANT`ing the columns; Phase 1
  RPC is additive. Backup grants/policies before Phase 3 (as done for the lockdown).

## Out of scope (future)
- Office-vs-field authorization inside `set_visit_status` (data exists; add when needed).
- Migrating `manhole_count`/`derm_required` to RPCs (not delete vectors; low priority).
- MFA / SSO for staff.

## Dependencies / ownership
- **DB (Phase 1, 3):** this (Supabase) session lane.
- **Apps (Phase 2):** Building Apps / Lovable session — the login gate + Calendar RPC wiring.
- Coordinate the phase handoffs via WORKING-NOW.md. Update `docs/security.md` (residual → CLOSED) +
  `CLAUDE.md` (staff apps now auth-gated) at Phase 3 ship.
