# Activity tab — "who did it" attribution — design spec

*2026-06-26. Status: **P1 + P2a + P2b ALL SHIPPED + verified** (facts + Chrome UI).*

## Status / impact review (2026-06-26)

A 4-lens adversarial impact review returned **GO-WITH-CHANGES**. P1+P2a were implemented with the
fixes folded in (migration `2026-06-26_activity_attribution_p1_p2a.sql`); **P2b is gated** (touches the
hot inbound path + has an open product question).

**Corrections from the review (the original "Verified facts" below overstated reach):**
- Only **60 of 452** `visit-calendar` audit rows carry a person (the rest are pre-2026-06-24 anon rows);
  they correctly keep the bare "Edited in Visit Calendar" label.
- The 3 logins (fred@/yannick@/unclogme@) matched **no** `employees.email`, so the migration **seeds**
  `employees.email` for **Fred** + **Yannick** → names now resolve ("Edited in Visit Calendar by Fred",
  verified on visit 5873). A future Diego/office login needs the same seed; until then it shows the email.

**Safety fixes folded in (vs the original design):**
- **Dropped the `audit.log_change` `changed_by` hygiene fix** — not needed (display reads
  `jwt_claims->>'email'`, already captured) and its `::uuid` cast could **abort writes** on a non-uuid
  `sub`. Zero audit-trigger change in P1+P2a.
- Person resolved as a **scalar `LIMIT 1` correlated subquery**, never a JOIN (`employees.email` is not
  unique → a JOIN would multiply history rows across all 4 apps).
- `src` selects **only** `jwt_claims->>'email'` + `request_context->>'actor_name'` — never raw
  `jwt_claims` (15 PII keys; the fn is anon-granted). 8-col signature unchanged.
- Person-resolution stays **inside the human-app WHEN branch**; `p_hide_system` allowlist + system/cron
  branches byte-identical → field-portal/derm-tracker/admin-review + cron labels preserved (verified).
- **Shared `unclogme@unclogme.com`** login → **no by-line** (collapses N humans into one).

**P2b — SHIPPED 2026-06-26** (migration `2026-06-26_activity_attribution_p2b.sql` + `webhook-jobber`
deploy). `handleVisit` routes its **4 visits-writes** through a **dedicated per-write client**
(`x-app-source='jobber'` + `x-actor-name=createdBy` on insert) — NOT the shared singleton, so
clients/jobs/invoices/airtable/samsara attribution is untouched. `createdBy{name{full}}` validated
against the live read-token schema before deploy. `audit.log_change` captures `x-actor-name` into
`request_context` (additive, null-dropped, 120-cap). `get_record_history` 'jobber' branch →
**"Created in Jobber by <createdBy>"** (INSERT, from request_context) / **"Completed in Jobber by
<completed_by>"** (status→completed, from the stored column) / **"Changed in Jobber"** (else).
**Verified:** PostgREST header→audit→render path live ("Changed in Jobber by Yannick Ayache",
"Completed in Jobber by Diego Test", net-zero); hot path intact (single-visit replay HTTP 200,
`*/5` polls success). completedBy = "who marked it complete in Jobber" (often Diego/office) —
accepted per Fred. The original gate notes (now satisfied) follow:

**Original P2b gate (all satisfied):** (1) `webhook-jobber.handleVisit` must use a **dedicated per-write client**
(`createClient(..., {global:{headers:{'x-app-source':'jobber','x-actor-name':<name>}}})`) on **all three**
write paths — NOT the shared `_shared/supabase-client.ts` singleton (also imported by
webhook-airtable/samsara → would mislabel every entity). (2) **Validate** `Visit.createdBy{ name{ full } }`
against the live read-token schema before deploy (the shared `gql()` throws on errors → a bad subfield
halts ALL inbound visit ingestion). (3) Render the **completion** name from the stored
`visits.completed_by` column, not request_context (only `createdBy` lacks a column). (4) **Product
question for Fred:** `completedBy` is often the office processor (Diego), not the field driver — confirm
"Completed in Jobber by <completedBy>" is acceptable. (5) Gate-#4 invariant note: the drift classifier is
safe under the `sql→jobber` relabel **only because** `handleVisit` never writes `visit_date` on
`source IN ('visit-calendar','supabase_cron')` visits — flag the loop-guard as load-bearing.

---

*Original design (2026-06-26, approved):*

## Goal

In the visit drawer's **Activity** tab, show **who** made each change:
- **Calendar edits** → the logged-in person ("Edited in Calendar by **Diego**"), falling back to
  their login email when it doesn't map to an employee.
- **Jobber-originated changes** → name the actor **where Jobber provides it** (created / completed),
  and an honest **"Changed in Jobber"** for reschedules/edits (Jobber exposes no editor).

Also (already shipped): the **"Show Jobber sync changes" toggle defaults ON** (`p_hide_system=false`).

## Verified facts (live, 2026-06-26)

- **The Calendar already logs in per-user.** All 425 `app_source='visit-calendar'` audit rows carry the
  real person in `audit.logs.jwt_claims` — `role='authenticated'`, `sub`, and `email` (e.g.
  `fred@ayache.com`). `auth.users` has 3 accounts (fred@, yannick@, unclogme@).
- **But `changed_by` is NULL on every row** (all app_sources, 0/12751+ populated): `audit.log_change`
  sets `changed_by` from the legacy GUC `request.jwt.claim.sub` (empty), not from the populated
  `request.jwt.claims` JSON. The identity is captured (`jwt_claims`) but never read into a usable column.
- **`employees` has `email`** (no `auth_user_id` column) — so login→person resolves by **email join**.
- **`get_record_history` actor label is app-level only** (`2026-06-25_audit_trail_phase1.sql:264-273`):
  human apps → `'Edited in ' || initcap(app_source)`; `'%-cron'`/`jobber-reconcile` → `'System (Jobber sync)'`;
  **everything else (incl. `app_source='jobber'`) → `'System'`**. It never resolves a person.
- **Jobber API actor fields (introspected live):** `Visit.createdBy` → the Jobber **user**
  (`{ id, name{ full } }`, e.g. "Yannick Ayache"); `Visit.completedBy` → completer **name** (scalar string);
  **`updatedBy`/`lastEditedBy` do NOT exist** → Jobber cannot tell us who *rescheduled/edited* a visit.
  Root `event`/`webHookEvent` queries are webhook-payload lookups, not a who-did-what feed.
- **Inbound Jobber changes are currently mislabeled.** `webhook-jobber.handleVisit` writes server-side
  with no `x-app-source` + empty Origin → `app_source='sql'` → "System". The gate-#4 **adopt** path does
  send `x-app-source='jobber'` → `app_source='jobber'`, which today still renders "System" (no case for it).

## Design

### Part 1 — Calendar edits → the person  *(works retroactively on existing rows)*

`get_record_history` resolves the actor for human-app rows from the row's own `jwt_claims`:
- `email := jwt_claims->>'email'`; resolve `employees.full_name WHERE lower(email)=lower(@email)`.
- `actor_label := 'Edited in ' || <app> || ' by ' || COALESCE(employee_full_name, email, '')`.
  Fallback chain: employee name → login email → bare app label (current behavior) if no claims.
- Add `l.jwt_claims` to the function's `src` CTE (currently not selected) so the CASE can read it.
- **Correctness fix** to `audit.log_change`: also set `changed_by` from `jwt_claims->>'sub'` going forward
  (`COALESCE(NULLIF(current_setting('request.jwt.claim.sub',true),'')::uuid, (jwt_claims->>'sub')::uuid)`),
  so the column is no longer perpetually null. (Display keys off the email; this is hygiene.)

3NF: the person is **resolved on read** via an email join — nothing copied. Clean.

### Part 2 — Jobber-originated changes → name where Jobber gives it, else honest

**2a. Label Jobber changes (quick).** `get_record_history`: add an `app_source='jobber'` case →
`'Changed in Jobber'` (today it falls to "System"). This immediately fixes the gate-#4 **adopt**
(reschedule) display — Fred's "Diego reschedules in Jobber" case → "Changed in Jobber".

**2b. Name the Jobber actor where Jobber provides it.** Thread the actor through the inbound path so a
captured name renders:
- `webhook-jobber.handleVisit` sends `x-app-source: 'jobber'` on its visit writes (so inbound Jobber
  changes read "…in Jobber", not "System"), plus `x-actor-name: <name>` **only when Jobber gives one**:
  - on **create** of a `source='jobber'` visit → `createdBy.name.full` (add `createdBy{ name{ full } }`
    to handleVisit's visit query),
  - on **completion** → `completedBy` (already pulled).
- `audit.log_change` captures `x-actor-name` into `request_context` (alongside origin/method).
- `get_record_history` renders: INSERT → `'Created in Jobber by <actor>'`; completion (status→completed)
  → `'Completed in Jobber by <actor>'`; otherwise `'Changed in Jobber'`. Actor pulled from
  `request_context->>'actor_name'`; absent → no "by".

3NF: the Jobber actor name is **point-in-time request context** (Jobber doesn't keep it on the visit and
we don't store Jobber users) — captured into `request_context` jsonb like origin/app_source, not a
duplicated business column. Consistent with ADR 016.

### Part 3 — Frontend (Lovable Calendar)

`get_record_history` already feeds the Activity tab's actor label; richer `actor_label` strings render
with no frontend change. Confirm in the **Chrome UI** that the labels appear (and tweak only if the
component truncates/transforms the label). The toggle-default ON is already published.

## Phasing

1. **P1 + P2a** (quick, low-risk, high-value, retroactive): `get_record_history` person-resolution +
   `'jobber'` label case + the `audit.log_change` `changed_by` fix. No edge-function/hot-path change.
2. **P2b** (Jobber actor names): `webhook-jobber.handleVisit` threads `x-app-source='jobber'` +
   `x-actor-name`, and `audit.log_change` captures it. Hot inbound path — deploy + verify carefully.

## Architecture / compliance

- **No new tables, no new business columns.** Person resolved on read (email join); Jobber actor stored
  as audit request-context (jsonb), per ADR 016. No source-prefixed columns.
- `get_record_history` stays the single audited door (table whitelist + column allowlist unchanged);
  only the `actor_label` projection + the `src` CTE's `jwt_claims`/`request_context` selection change.
- `audit.log_change` change is additive (capture more context); existing attribution preserved.

## Testing  *(facts + Chrome UI, per Fred)*

- **P1 (facts):** call `get_record_history('visits', <a 112-YA-style visit Fred edited>)` and assert a
  Calendar row's `actor_label` = "Edited in Visit Calendar by <Fred's employee name or fred@ayache.com>".
  Verify the email→employee join resolves for a seeded employee; verify the email fallback for an
  unmapped login.
- **P2a (facts):** on a gate-#4 adopt audit row (`app_source='jobber'`), assert `actor_label='Changed in
  Jobber'` (not "System").
- **P2b (facts):** induce a Jobber-side **completion** + **create** on a far-future test visit (write
  token), let the inbound poll replay, assert the audit row carries `request_context->>'actor_name'` and
  `get_record_history` renders "Completed in Jobber by <name>" / "Created in Jobber by <name>". Net-zero
  revert.
- **Chrome UI:** open the visit drawer → Activity tab on the live app; confirm (a) it defaults to showing
  Jobber sync changes, (b) a Calendar edit shows the person, (c) a Jobber change shows "…in Jobber"
  (named where available). Screenshot evidence.

## Open items / rollout

- **Crew/office logins (onboarding, not a build):** per-person Calendar names require each office
  scheduler's Supabase login email to match their `employees.email`. Today only fred@/yannick@/unclogme@
  exist; Diego (and any other scheduler) needs a login. Until then, their edits show the email or the
  logged-in account in use.
- **Jobber reschedule actor is permanently unavailable** (Jobber API limit) → "Changed in Jobber" is the
  ceiling for that case; revisit only if Jobber adds an editor/activity field.
