# DERM-required by line-item (canonical mapping + derivation)

**Status: IMPLEMENTED 2026-06-24** (migration `migrations/2026-06-24_derm_required_from_line_items.sql`,
ADR [018](../decisions/018-derm-required-from-line-items.md)). Supersedes the 2026-06-02 stopgap.

**Source of truth:** Fred's Google Sheet — https://docs.google.com/spreadsheets/d/19ArflSwdhcpnu1U6Lii5q2VFmDLjwskurDCghN0aanE/edit (gid=0). Column **"Requires DERM reporting"** (Y/N) per formatted line-item type (01–27).

## The rule
**A visit requires a DERM manifest iff it includes a "Pumping" line item** — Grease Trap (incl. grease
*interceptor*), Grey Water, or Lift Station pumping. Everything else (Cleaning, Hydrojet, Unclogging,
Camera/Dye/Assessment, Labor, Parts, Warranty, fees, GDO reporting) does **not**.

`service_line_items.requires_derm = true` for exactly codes **{01, 02, 03, 04, 09, 10, 11}** (all Pumping;
01–04 = Service Agreement, 09–11 = Service Call). This column is already correct and matches the sheet.

`visits.service_type` is **too blunt** and is NOT the DERM signal: `handleVisit` *defaults*
service_type to GT (so cleaning visits looked GT), and grey-water pumping is coded CL but DOES need DERM.
The line items are the real signal.

## How `visits.derm_required` is derived

`public.fn_line_item_requires_derm(name)` → boolean (nullable):
1. **Taxonomy-formatted** `"NN - ..."` → authoritative `requires_derm` for that code.
2. else **free-text PUMPING** (`fn`'s `PUMP_RE`): a regulated vessel (grease trap / grease interceptor /
   interceptor / grey water / lift station, typo-tolerant "Tap"/"Lyft") near a pump word in either order,
   or an explicit pump-out (any word-form: pump/pumped/pumping/pumps out) → **true**. PUMP is tested
   **before** NONPUMP so a co-occurring fee/cleaning token can never downgrade a pumping line.
3. else **free-text recognized NON-pumping** (cleaning, hydrojet, unclog, camera, dye, assess, inspect,
   labor, parts, warranty, fees, install, repair, …) → **false**.
4. else **NULL** (unknown — e.g. bare "Service Agreement"/"Service", "Oil pumping").

`public.fn_visit_requires_derm(visit_id)` → boolean (nullable): classifies the **UNION** of the visit's
line items across all three scopes (visit-scoped `visit_id`, invoice-scoped `invoice_id`, job-scoped
`job_id`), then:
- **any** item true → **true** (union, so pumping carried on the job/invoice is never masked);
- has items, all classified, none true → **false**;
- otherwise (some unknown, or no items) → **NULL**.

**NULL is the safe default** — every consumer treats `derm_required IS NULL OR = true` as *still needs a
manifest* (surfaced for review), so a genuinely-ambiguous visit is never silently dropped. False
negatives (hiding a real DERM visit) are worse than noise.

## Keeping it fresh (three writers)
- **Calendar** — `create_calendar_visit` RPC sets it from the chosen `service_line_item` ids (`bool_or(requires_derm)`).
- **Jobber sync** — `webhook-jobber.handleVisit` calls `set_visit_derm_required(visit_id)` after storing
  the visit's line items (near-real-time, every poll).
- **Nightly catch-up** — pg_cron `derm-required-rederive` (03:20 ET) runs `rederive_visits_derm_required()`
  for line items that arrive later (esp. invoices). Watchdog idempotent: a 2nd run touches 0 rows.
  **Skips human-locked rows** (`derm_required_locked` — see below).

**Monotonic invariant (automated paths):** `set_visit_derm_required` + `rederive_visits_derm_required`
never demote a stored **TRUE** to false/null and never write NULL — they only promote NULL→{true,false}
and false→true. This stops a later non-pump invoice from hiding a pumping visit and protects a human's
NULL→true reclassification. (The one-time backfill is authoritative: it writes the function's verdict
including re-surfacing a stale false→null, protecting only existing trues.)

## Human override — `derm_required_locked` (2026-07-03)

**Problem it solves:** the monotonic `false→true` promotion above is line-item-blind to *human judgement*.
When Diego/Yannick click **"DERM not required"** in the DERM Tracker, the app writes `derm_required = false`.
But the nightly re-derive's guard is `derm_required IS NOT TRUE`, which treats that human **false** exactly
like an unknown **NULL** and re-promotes it to **true** whenever the job/invoice carries a pumping line item.
Result (Yannick, 2026-07-02): visits keep **re-appearing in "Missing Docs"** the morning after they were
marked not-required. Sample visit 5745 (214-MYK) flip-flopped 6× — human `→false` at 15:38, cron `→true`
at 07:20, every day. Audit: **139 human "not required" decisions**, of which **36 the cron had already
flipped back to Required**.

**The model (migration `2026-07-03_derm_required_manual_lock.sql`):**
- `public.visits.derm_required` **stays the single effective value** every consumer reads — no view rewrite.
- New additive column `public.visits.derm_required_locked boolean NOT NULL DEFAULT false` = "a human set
  this deliberately; automation must not touch it."
- Trigger `trg_derm_required_lock` (`BEFORE UPDATE OF derm_required`): detects the DERM Tracker the same
  way `audit.log_change` does (request header `x-app-source='derm-tracker'` / origin `derm.unclogme.app`).
  - A **DERM-Tracker** write that changes `derm_required` → set `derm_required_locked = true` (auto-lock).
  - Any **other** writer (cron / `handleVisit` / raw SQL) that tries to change a locked value → reverted to
    the human value. **The lock is enforced no matter which code path attempts the override** — this is the
    real guarantee; the `AND derm_required_locked IS NOT TRUE` guards added to `rederive_visits_derm_required`
    + `set_visit_derm_required` are belt-and-suspenders (they don't even attempt a locked row).
- **No DERM Tracker app change** — the existing "DERM not required" button now sticks automatically.
- To hand a visit back to auto-classification: set `derm_required_locked = false` explicitly.

Verified 2026-07-03: restored + locked all 139 human decisions; ran the real cron → **0** promoted, 0
residual; Missing-Docs **52 → 23**; trigger blocks an auto-writer on a locked row and still lets an
**unlocked** visit auto-promote. Restore backup: `backups/2026-07-03_derm_required_restore_backup.json`.

**Hardening (migration `2026-07-03b_derm_lock_hardening.sql`, after an adversarial smoke-test review —
no must-fix defects found):** (1) the header cast is now wrapped in an `EXCEPTION` guard (matches
`audit.log_change`) so a malformed `request.headers` GUC degrades to "not derm-tracker" instead of
aborting the write; (2) origin match is `ILIKE` (case-insensitive); (3) the trigger dropped its
value-change `WHEN` gate — it now fires on any `derm_required`-targeted write, so a human re-clicking
"not required" on an **already-false** visit still locks it (closing a latent gap where such a no-op
click left the row unlocked and re-promotable). Robustness note for the DERM Tracker app: the auto-lock
relies on the app sending `x-app-source: derm-tracker` (or a `derm.unclogme.app` origin) — treat that
header as a release invariant; belt-and-suspenders would be for the app to set `derm_required_locked`
explicitly on a "not required" write.

### Compliance review surface — `ops.v_derm_human_override_conflict`

Locking a human "not required" **overrides** the auto pumping-line-item verdict, so those visits vanish
from every missing-docs surface — which tensions ADR-018's "pumping verdict is a monotonic compliance
floor / a false-negative is worse than over-surfacing." As of 2026-07-03 there are **36** such conflicts
(human-locked `false` **but** `fn_visit_requires_derm = true`), **30 completed with no manifest, 27
overdue >14 days** (e.g. 070-TCE v1240 182d, 057-BAY lift-station v1344/1352/1498/…, 112-YA v1468). The
view `ops.v_derm_human_override_conflict` lists them (worst-overdue first) so Yannick can confirm each
"not required" call was correct rather than trusting it blindly. To re-require one: **clear
`derm_required_locked` FIRST (its own UPDATE — the lock trigger doesn't fire on a lock-only change),
then set `derm_required = true`** (a single combined UPDATE gets the value reverted by the lock trigger).

**2026-07-03 (later): the 6 `has_manifest=true` rows were FIXED** (Fred approved; found by Supabase 2 via
v5842/104-PV): visits 1707, 5028, 4901, 4836, 5841, 5842 each had a REAL linked manifest (white #s
821472/825560/825450/827989/828601×2) + pumping line items, yet carried a human "not required" override —
mis-clicks contradicted by the manifest on file. All re-required + unlocked (backup
`backups/2026-07-03_derm_override_manifest_contradiction_fix.json`); none re-enter Missing Docs (they have
manifests). **The review surface is now 30 rows, all no-manifest overrides — pending Yannick's review.**

**Full-population consistency audit (2026-07-03, Fred ask — do NOT re-litigate):** across all 1,550 live
visits the ONLY human-override-vs-manifest contradictions were the 6 above (fixed; 0 remain). Additionally
**23 auto-false + 45 NULL visits carry a linked manifest — audited, NOT bugs**: the 23 have genuinely
non-pumping line items (hydrojet/camera/repairs — sheet says N) and got the manifest via the client-level
over-linking pattern (their neighboring pumping visits all have their own manifests — mis-link hypothesis
tested and dead); the 45 NULLs are pre-taxonomy unknowns that display as Documented (NULL=required +
has_manifest). All other integrity checks zero (no links to deleted visits/manifests, no scheduled-with-
manifest, no over-linked visits). v5830 (053-PV): human not-required decision PRESERVED (dump ticket
828601 does not cover 053-PV) — stays on the review surface.

## Consumers (all key off `derm_required`, NULL-safe)
- `public.manifest_pickable_visits` — `WHERE completed AND (derm_required IS NULL OR = true) AND no manifest`.
- `derm.visits.needs_manifest` = `COALESCE(derm_required, true)` (DERM Tracker "Missing Docs").
- `customer.work_orders` — `WHERE COALESCE(derm_required, true) = true` (Field Portal grease-trap work orders).
- `ops.v_derm_compliance` — missing-manifest count now uses `derm_required` (was `service_type='GT'`);
  the view stays **Pumping-config-roster scoped** (`service_type = 'Pumping'`, formerly 'GT') (it joins `service_configs` GT for equipment/frequency), so
  grey-water/lift-station-**only** clients are tracked via `derm.visits`, not this ops dashboard.

## Live result (2026-06-24 backfill, 706 completed visits)
**436 true / 176 false / 94 null.** Notable corrections vs the old service_type heuristic: **41 GT visits
→ false** (verified: all cleaning/unclog/camera/fees, no pumping line), **18 CL visits → true** (grey-water
pumping). The 94 NULL are generic "Service Agreement"/"Service"/bare "Lyft Station" — surfaced for review,
will resolve once Jobber line items are reformatted to the 01–27 taxonomy.

## Full code mapping (matches the sheet)
DERM-required (`Y`): 01,02,03,04 (SA Pumping) · 09,10,11 (SC Pumping). All others (05–08, 12–27) = `N`.

Rollback: `public.derm_required_backfill_snapshot_2026_06_24` (visit_id, service_type, prior value);
`cron.unschedule('derm-required-rederive')` to stop the nightly job without reverting the migration.
