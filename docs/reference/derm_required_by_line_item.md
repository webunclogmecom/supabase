# DERM-required by line-item (canonical mapping + derivation)

**Status: IMPLEMENTED 2026-06-24** (migration `migrations/2026-06-24_derm_required_from_line_items.sql`,
ADR [018](../decisions/018-derm-required-from-line-items.md)). Supersedes the 2026-06-02 stopgap.

**Source of truth:** Fred's Google Sheet — https://docs.google.com/spreadsheets/d/19ArflSwdhcpnu1U6Lii5q2VFmDLjwskurDCghN0aanE/edit (gid=0). Column **"Requires DERM reporting"** (Y/N) per formatted line-item type (01–27).

## The rule
**A visit requires a DERM manifest iff it includes a "Pumping" line item** — Grease Trap (incl. grease
*interceptor*), Grey Water, or Lift Station pumping. Every other **service** (Cleaning, Hydrojet,
Unclogging, Camera/Dye/Assessment, Labor, Parts, Warranty) does **not**.

🛑 **FEE AND ADMIN LINES ARE A THIRD CATEGORY: THEY ABSTAIN, and they are NOT in the "does not" set.**
Corrected 2026-08-06 (migration `2026-08-06_1448_fee_lines_are_derm_neutral.sql`, commit `0af47f1`);
this line previously listed "fees, GDO reporting" alongside Cleaning and Labor, which was the exact
encoding removed as a compliance hazard. Codes **25 (Credit card fee), 26 (ACH Fee), 27 (GDO Online
Reporting)** carry `service_line_items.reason IN ('fee','other')`, and `fn_line_item_requires_derm`
answers **NULL** for them. On code 05 (Main Line Cleaning) a FALSE is a real statement: a cleaning
service genuinely does not require DERM. On a credit card fee it is not a statement at all. A payment
fee says nothing about whether the work needed a manifest, and storing "no" where the truth is "this
line does not say" is what makes the SC fee mirror dangerous (worked through under the derivation
section below).

`service_line_items.requires_derm = true` for exactly codes **{01, 02, 03, 04, 09, 10, 11}** (all Pumping;
01–04 = Service Agreement, 09–11 = Service Call). This column is already correct and matches the sheet.
⚠ It is **NOT NULL**, so it cannot express "this line does not say". That is why the abstention lives in
the function and not in the column: widening the column would have touched all 28 catalogue rows.

`visits.service_type` is **too blunt** and is NOT the DERM signal: `handleVisit` *defaults*
service_type to GT (so cleaning visits looked GT), and grey-water pumping is coded CL but DOES need DERM.
The line items are the real signal.

## How `visits.derm_required` is derived

`public.fn_line_item_requires_derm(name)` → boolean (nullable):
1. **Taxonomy-formatted** `"NN - ..."` → the catalogue's `requires_derm` for that code, **except**
   `reason IN ('fee','other')` (codes 25/26/27), which return **NULL**.
   ⚠ **This step used to read "authoritative `requires_derm`" with no exception. That is FALSE as of
   2026-08-06.** The taxonomy branch is authoritative for *service* codes only and abstains on
   fee/admin codes. **Scope is deliberately narrow:** only this authoritative branch changed, because a
   mirrored line always hits it ("25 - Credit card fee (3.53%)" carries its code prefix). The free-text
   branch (3) still answers FALSE for a fee-ish string, since that same regex also covers
   cleaning/camera/labour where FALSE genuinely IS evidence.
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

### 🛑 Why the fee abstention is load-bearing: reverting 25/26/27 to FALSE evicts 33 live visits

This is the mechanism, and it is worth following once because the "simplification" back to FALSE looks
harmless from the catalogue side.

`fn_visit_requires_derm` folds the reachable lines with `bool_or`, and `customer.work_orders` ends
`COALESCE(v.derm_required, true) = true`. That view is the client's **DERM compliance surface by
design** (Fred, 2026-08-05: *"we only show derms required jobs to the work orders"*), so a FALSE does
not merely drop a chip, it removes the visit from the client's Field Portal record.

1. A Service Call visit reaches **no** job-scoped line today, so it derives **NULL**, which every
   consumer reads as "still needs a manifest".
2. Mirror a fee line onto that job and the visit now reaches **exactly one** line.
3. If that line answered **FALSE**, the visit derives FALSE, i.e. "definitively not required".
4. The nightly `derm-required-rederive` writes precisely that NULL to FALSE fill, and the monotonic
   guard does not stop it: it only blocks demoting a known TRUE.

**33 live visits across 22 non-SA jobs sit in exactly that shape.** Measured impact of the abstention
itself was **zero** and the zero is instrumented: 826 visits reach a fee line today (positive control,
must be non-zero), 1741 reach any line, **0** derives changed, because on every one of them a real
service line already decides the outcome through `bool_or`. This is a guard installed ahead of the
hazard, not a repair, so "it changed nothing" is not an argument for removing it.

⚠ The first version of that measurement was **vacuous and also said 0 of 1741**: the regex was written
`'^\\s*2[567]\\s*-'` from a JS string, and a doubled backslash in SQL is a literal backslash, so it
matched nothing and the control returned 0 visits reaching a fee line, which is impossible with 166 fee
rows live. Rewritten with the escape-free POSIX class `[[:space:]]` the control returned 826 and the
real answer was still 0. **Never accept a 0 here without the control printed beside it.**

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
  🛑 **THIS IS THE HARMFUL ACTION ON SOME ROWS. Check the derive first.** Unlocking hands the row to the
  nightly re-derive, and where the derive lands **FALSE** the visit disappears from
  `customer.work_orders` entirely, taking the client's whole service record with it (driver, truck,
  decal, manholes, ticket, trap condition, facility), not just a DERM flag. Two visits are
  **deliberately excluded and must never be unlocked: 1260 (083-SHUL) and 1476 (133-MUT)** (both derive
  FALSE while carrying a real manifest link). Run `fn_visit_requires_derm(visit_id)` before clearing any
  lock, and read the 2026-08-05 section below before touching one at all.

  ⚠ Note also that the DERM Tracker no longer takes this path. Since 2026-08-05 the app writes through
  `set_visit_derm_required_manual` / `set_visits_derm_required_manual`, where `p_value = NULL` means
  "I have no opinion" and RELEASES the lock. A direct `UPDATE` on `derm_required` from an app is
  prohibited; this SQL recipe is an operator action only.

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

🛑 **THE TWO RECIPES ON THIS PAGE ARE NOT INTERCHANGEABLE, AND ONE OF THEM CAN HIDE A CLIENT'S RECORD
(annotated 2026-08-07).**

| action | where `derm_required` ends up | what the client sees |
|---|---|---|
| **RE-REQUIRE**: unlock, then write `true` (the recipe directly above) | `true`, locked again by the write | record stays visible in `customer.work_orders`. **Always safe.** |
| **UNLOCK AND LET IT RE-DERIVE** (the bare `derm_required_locked = false` recipe under the model section) | whatever `fn_visit_requires_derm` returns, which may be **`false`** | on a `false` the visit leaves `customer.work_orders` and the client's **entire** service record for it disappears |

The second is not hypothetical. **1260 (083-SHUL) and 1476 (133-MUT) both derive `false` while carrying
a real `manifest_visits` link**, so unlocking either erases that client's record while a manifest sits
on file. They were deliberately held back on 2026-08-05; see the section below.

⚠ **And the 2026-07-03 precedent immediately following is NOT a template for them.** Those 6 rows were
re-required to `true` *and then* unlocked, which is safe precisely because they carry pumping line items
and re-derive to `true`. Applying "re-required + unlocked" to a visit that derives `false` produces the
opposite outcome overnight. Check `fn_visit_requires_derm(visit_id)` before you copy the pattern.

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

### 2026-08-05: 7 value-less locks cleared, and **two that must never be unlocked**

Migration `2026-08-05_0620_derm_unlock_seven_null_locked_visits.sql` (commit `35fdb13`). A lock whose
`derm_required` is **NULL** carries no human decision at all: the lock trigger fires on any DERM-Tracker
touch, so a row could be locked without a value ever being set. Those locks only block the nightly
re-derive, so clearing them lets the derive fill the unknown.

**Unlocked and re-derived to `true`** (verified live 2026-08-06, all 7 are now `derm_required = true`,
`derm_required_locked = false`): **1334, 1547, 1597, 5100, 5101, 5745, 5830**.

🛑 **1260 (083-SHUL) and 1476 (133-MUT) WERE DELIBERATELY HELD BACK. DO NOT UNLOCK THEM.**
Both are `derm_required IS NULL`, locked, and **`fn_visit_requires_derm` derives `false`** for each,
and both carry a `manifest_visits` link. Unlocking them lets the re-derive write `false`, and
`customer.work_orders` filters on `COALESCE(derm_required, true) = true` **by design** (Fred, 2026-08-05:
*"we only show derms required jobs to the work orders"*). So the visit would not merely lose a DERM chip,
its **entire service record would disappear from the client's Field Portal** while a real manifest sits on
file. `NULL` is fail-safe here and `false` is not. Re-verified against live data 2026-08-06.

**1533 (175-PV) was also skipped**, for the opposite reason: it derives `NULL`, so unlocking it is inert.

⚠ **This caveat applies to the unlock recipe above.** Before clearing `derm_required_locked` on ANY
NULL-valued lock, check `fn_visit_requires_derm(visit_id)` first. If it derives `false` and the visit has
a manifest link, leave the lock alone.

⚠ **Do not quote a frozen lock count.** The migration recorded 164 -> 157 alive locks; measured 2026-08-06
it was already **158**, because every DERM-Tracker touch locks another row. The number drifts upward by
design. Count it, do not cite it.

⚠ **Two different trios are in circulation and they are NOT the same set.** This migration held back
**1260, 1476, 1533** (selected on "would unlocking cause harm"). `Supabase/CLAUDE.md` separately tracks
**1260, 1476, 3923** as load-bearing manifest-link contradictions (selected on "a manifest is on file
while `derm_required` is not true"). 3923 (165-LPB) is a different situation: it is `false` and **not
locked**. Do not treat one list as a copy of the other.

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
