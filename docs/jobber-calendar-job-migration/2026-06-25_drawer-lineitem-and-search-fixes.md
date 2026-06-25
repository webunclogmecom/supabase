# Calendar drawer line-item + search fixes (2026-06-25)

*Four issues surfaced while live-testing line-item editing on 112-YA. All fixed + verified.*

## 1. 🔴 Drawer "Services" didn't show a visit's current line items (data-loss risk) — FIXED

**Bug:** opening an existing visit's drawer showed the Services checklist with everything
**unchecked**, even when the visit already had line items. Two consequences: you couldn't
see the current services, and checking a new one + saving **replaced** (dropped) the unseen
existing ones. Prices also never pre-filled.

**Root cause (backend):** `ops.v_calendar_visit_detail.line_items` was built from
`line_items WHERE li.job_id = v.job_id` (JOB-scoped) and omitted `unit_price`. A Service-Call
visit's line items are **visit-scoped** (`visit_id` set, `job_id` null), so the view returned
`[]` for them.

**Fix:**
- Backend (`2026-06-25_fix_visit_detail_lineitems.sql`): the view now returns the **visit's
  own** line items (`visit_id = v.id`, fallback to job line items for SA visits) **with
  `unit_price`**.
- Frontend (Lovable): on drawer open, pre-check the services already on the visit (match line
  item `name` → service title) and pre-fill their saved `unit_price`/`quantity`.

**Verified live:** visit 6806 (line item "19 - Camera Inspection") now opens with **19
checked**, price `$0`, qty `1`. Other services unchecked.

## 2. 🟡 Early visits had DB line items missing from Jobber (create-time drift) — HEALED

Visits created early 2026-06-25 (~8am) had line items in the DB but **none on the Jobber
visit** (created before the line-item push was reliable that morning). Scope was small: 4
candidates (6805/6806/6807/6808). Healed by bumping `line_items_rev` (one clean push each).
**Result:** all 4 now match Jobber. 6805 `[12 …]` and 6806 `[19 …]` were the two drifted ones;
both healed.

## 3. 🟡 Rapid back-to-back saves could duplicate Jobber line items — FIXED

`syncVisitLineItems` (delete-all → recreate) wasn't atomic across **concurrent** pushes — two
saves seconds apart could leave duplicates (e.g. `[19, 19]`).

**Fix** (`jobber-push-visit/index.ts`, deployed v18): a **self-healing dedupe** after create —
re-query the Jobber visit's line items and trim any back to exactly the DB set per name. No-op
when in sync (one extra query). `Q_VISIT_LI` now fetches `name` too.

**Verified:** fired two rapid `line_items_rev` bumps on 6806 → Jobber converged to a **single**
`[19@0]` (count 1).

## 4. 🟡 Visit search crashed on an apostrophe — FIXED

Searching "Yan's Restaurant" white-screened the app. Lovable diagnosed the real root cause:
rows with **null names** broke the client-side filter (the apostrophe search just surfaced
them). **Fix** (Lovable): the search safely ignores rows with null names.

**Verified live:** searching "Yan's Restaurant" on `calendar.unclogme.app` no longer crashes.

## Commits / deploys

- Supabase repo `057454a`: view fix migration + edge-fn dedupe.
- `jobber-push-visit` Edge Function redeployed (v18, `verify_jwt=true`).
- Drift heal: data-only (no commit).
- Lovable project `6533c3ee…`: drawer pre-check + search null-safety, **published** to
  `calendar.unclogme.app`.
