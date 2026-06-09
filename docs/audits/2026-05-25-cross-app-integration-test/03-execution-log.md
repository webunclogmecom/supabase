# Execution Log

Running record of test results.

Status legend: ✅ pass · ❌ fail · 🔧 fix-applied · ⚠ partial

---

## Group A — Manholes (Admin Review)

### A1 — Property 66 manhole 6 → 9 (111-YC Yann Couvreur) ✅
- Action: AR /review/4901, pencil-edit Manholes, set 9
- Network: `PATCH /properties?id=eq.66`, x-app-source=admin-review
- DB: properties 66 = 9 ✓
- Audit: 1 row, app=admin-review, hint=admin-review, old=6 new=9

### A3 — Property 92 manhole 3 → 8 (001-VIN Vincenzos) ✅
- Action: AR /review/5130, pencil-edit, set 8
- Network: `PATCH /properties?id=eq.92`, x-app-source=admin-review
- DB: properties 92 = 8 ✓
- Audit: 1 row hint=admin-review, old=3 new=8

### A5 — Sandbox read-after-write lag ⚠ INTERESTING
- After A1+A3, queried Sandbox-1 immediately for properties 66 + 92
- Sandbox showed 9 + 8 (matching Prod, ZERO lag)
- Either lucky timing or there's a faster sync path than 5x/day full refresh
- Filed as finding

### Architecture note — UI doesn't expose per-visit override
- AR's pencil edit on visit page goes to `properties.grease_trap_manhole_count`, NOT `visits.manhole_count`
- "Use default" button likely sets visits.manhole_count = NULL (clears per-visit override)
- Building Apps' diagnosis confirmed: zero visits in DB have manhole_count set, by design

---

## Group B — Photo Classifications (Admin Review)

### B1 — Confirm 25-photo batch on v5128 (Mila) ✅
- Action: clicked first "Before" on photo_link 30174, then clicked "Confirm (24 unclassified)"
- Network: dual POST to Sandbox + Prod photo_classifications, both 201
- Body: 25 rows — 1 with phase=before, 24 with phase=unknown
- DB Prod: 25 photo_classifications rows now exist for v5128 (30174-30198)
- Audit: 25 INSERT rows, all hint=admin-review

### UX finding — Confirm is all-or-nothing
- Clicking a phase button only sets local UI state
- "Confirm (N unclassified)" submits all photos in batch, with unclassified→'unknown' default
- This forces reviewer to acknowledge every photo (good UX)
- Restore.sql MUST handle this: 25 new rows on v5128 not in original snapshot

---
