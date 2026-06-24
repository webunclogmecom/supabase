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

`visits.service_type` (GT/CL/LS) is **too blunt** and is NOT the DERM signal: `handleVisit` *defaults*
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

**Monotonic invariant (automated paths):** `set_visit_derm_required` + `rederive_visits_derm_required`
never demote a stored **TRUE** to false/null and never write NULL — they only promote NULL→{true,false}
and false→true. This stops a later non-pump invoice from hiding a pumping visit and protects a human's
NULL→true reclassification. (The one-time backfill is authoritative: it writes the function's verdict
including re-surfacing a stale false→null, protecting only existing trues.)

## Consumers (all key off `derm_required`, NULL-safe)
- `public.manifest_pickable_visits` — `WHERE completed AND (derm_required IS NULL OR = true) AND no manifest`.
- `derm.visits.needs_manifest` = `COALESCE(derm_required, true)` (DERM Tracker "Missing Docs").
- `customer.work_orders` — `WHERE COALESCE(derm_required, true) = true` (Field Portal grease-trap work orders).
- `ops.v_derm_compliance` — missing-manifest count now uses `derm_required` (was `service_type='GT'`);
  the view stays **GT-config-roster scoped** (it joins `service_configs` GT for equipment/frequency), so
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
