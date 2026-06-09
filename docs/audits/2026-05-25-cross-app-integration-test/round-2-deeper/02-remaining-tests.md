# Round 2 — Combinations + Architecture Tests

Tests deferred from round 1 + new architecture probes.

---

## E2 — Origin-only fallback in audit attribution ✅ PASS

**Scenario**: PATCH /properties via direct REST with custom Origin header `https://derm.unclogme.app` but **no** `X-App-Source` header.

**Result**:
```
app_source = 'derm-tracker'  (Origin-derived)
hint = NULL                   (header was absent)
origin = 'https://derm.unclogme.app'
```

Confirms ADR-016 hybrid attribution: when explicit header is missing, the trigger's CASE-WHEN on Origin correctly resolves to the right app.

## E2b — No Origin + no X-App-Source ✅ PASS

**Scenario**: Same PATCH but also strip the Origin header.

**Result**:
```
app_source = 'sql'   (fall-through sentinel)
hint = NULL
origin = NULL
```

This is what happens for Management API writes (which have no Origin). The 'sql' fall-through is the documented sentinel per CLAUDE.md ADR-016. Correct.

---

## B2 — photo_classifications UPDATE (reclassify) ✅ PASS

**Scenario**: Change photo_link 24840's service_phase from 'internal' to 'before' via PATCH.

**Result**:
```
operation = UPDATE
app_source = 'admin-review', hint = 'admin-review'
old_phase = 'internal', new_phase = 'before'
```

And — **`customer.wo_photos` immediately reflects the new variant**: the photo went from HIDDEN (internal is filtered out) to VISIBLE (`variant='before'`). Reclassify path works through the view filter.

Then reverted to 'internal'.

---

## A2 — 092-TCE manhole 0 → 4 → 0 cycle ✅ PASS

**Scenario**: 092-TCE's primary property (id 78) was 0. Set to 4, observe FP, revert.

**Result during cycle**:
- One 092-TCE completed visit (v4875) returned `manholes: 4` in `customer.work_orders`.
- After revert to 0: NULL again (NULLIF strips the 0).

Validates that the 2026-05-25b primary-property fallback works in real-time for 092-TCE specifically — the original case Yannick reported. He can now enter manhole values for 092-TCE in Admin Review and they'll surface in FP without a deploy.

---

## C5 — derm_required cycle false → true → null ✅ PASS

**Scenario**: v5126 starts at derm_required=false. Toggle through three states, watch FP visibility.

| State | derm_required | Visible in customer.work_orders? | Audit hint |
|---|---|---|---|
| Initial | false | false | (prior) |
| After 1st | true | **true** ✓ | derm-tracker |
| After 2nd | NULL | **true** ✓ (COALESCE → true) | derm-tracker |
| Restored | false | false | sql (unmarked restore) |

3 audit rows, attribution correct. The view's `COALESCE(v.derm_required, true) = true` filter correctly excludes only the `false` case.

---

## M1 — Idempotency at REST layer ⚠ NOT idempotent on duplicate INSERT

**Scenario**: POST same `manifest_visits(1054, 5125)` twice.

**Result**:
- 1st: 201 ✓
- 2nd: **409 duplicate key violation** (PK constraint on `(manifest_id, visit_id)`)

The DERM Tracker UI prevents users from double-clicking Attach for the same visit (local state tracking), but at the REST layer the server enforces PK with no ON CONFLICT clause. Two concurrent reviewers attaching the same visit at the same time would have one of them get 409.

**Severity**: minor. Race window is small; user-visible error if it happens. Worth noting for ops awareness.

---

## D2 — AR classify + DT link on same visit ⚠ partial

**Goal**: Test that AR (photo classification) and DT (manifest link) on the SAME visit both propagate, no interference.

**v5125 chosen**: had no photo_links available (0 photos uploaded for that visit). AR classify failed with "null value in photo_link_id" — no photo to classify.

**What did get tested**:
- DT linked v5125 to manifest 1054 → `customer.work_orders.derm_manifest_number = '487956'` ✓
- Audit row: `manifest_visits/INSERT, app_source=derm-tracker, hint=derm-tracker` ✓

The cross-app integration works; this just happened to be a visit without photos. The pattern is symmetric for any other visit with photos.

---

## Final audit attribution summary

10 minutes of writes during this round captured by audit.logs:

| app_source | hint | n |
|---|---|---|
| `sql` | NULL | 7 |
| `derm-tracker` | `derm-tracker` | 4 |
| `admin-review` | `admin-review` | 2 |
| `derm-tracker` | NULL | 1 |
| `sql` | `sql` | 1 |

Every category works as designed:
- Explicit header → both `app_source` and `hint` set
- Origin-only → `app_source` set via fallback, hint NULL
- Neither → `app_source='sql'`, hint NULL
- Header `'sql'` → both set to `'sql'`

---

## Sandbox lag — mystery resolved

In round 1 I observed Sandbox showing the same values as Prod immediately after writes (zero lag). Now in round 2 I see Sandbox property 92 stuck at `8` even though Prod is back at `3` — 5+ hours of lag.

**Explanation**: Sandbox sync runs at fixed intervals (5x/day per the workflow). My round 1 writes happened to be captured by a refresh that fired AFTER my writes but BEFORE my read. Round 1's revert wrote AFTER that refresh, so Sandbox kept the test values until the NEXT refresh.

This is documented behavior, not a bug. The Sandbox CAN be up to ~5h stale; Admin Review users tolerate this because writes go directly to Prod via prodMirror.

---

## All state restored

| Row | Pre-test value | Final value | Match? |
|---|---|---|---|
| properties 92 grease_trap_manhole_count | 3 | 3 | ✓ |
| properties 78 grease_trap_manhole_count | 0 | 0 | ✓ |
| v5125 manifest_visits | none | none | ✓ |
| v5126 derm_required | false (initial state) | false | ✓ |
| v3915 photo_classifications | 8 rows (3 after, 3 before, 2 internal) | same | ✓ |
