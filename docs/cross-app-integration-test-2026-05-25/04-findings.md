# Cross-App Integration Test — Findings (2026-05-25)

## TL;DR

Tested live writes from **Admin Review → Prod**, **DERM Tracker → Prod**, and read propagation through **Field Portal** (Prod `customer.*` views). Surfaced 2 real bugs + 1 data-integrity gap + 2 architectural notes. Both bug fixes shipped during the run. Pipeline + audit attribution end-to-end is intact.

---

## Findings

### F1 — RED — `customer.work_orders.manholes` doesn't fall back when `visits.property_id IS NULL`

**Surfaced by**: A1 (manhole edit on 111-YC).
After AR changed property 66 (Yann Couvreur's primary) to 9, only 1 of 9 client visits showed manholes in FP. The other 8 visits had `visits.property_id IS NULL` so the previous COALESCE chain bottomed out.

**Scope on Prod**:
- 424 eligible visits (completed + derm_required != false)
- **324 (76%) have `property_id IS NULL`**
- Of those, **214 could be resolved** by falling back to the client's primary property

**Fix applied** (`docs/migrations/2026-05-25b_customer_work_orders_primary_property_fallback.sql`):
Extended the COALESCE chain with a `client_id + is_primary=true` lookup.

**Impact verified**:
| Stage | Visits with manhole shown |
|---|---|
| Before any fix this morning | 0 |
| After 2026-05-25a | 57 (13%) |
| After 2026-05-25b | **270 (64%)** |

Browser-verified end-to-end via `fp.unclogme.app/111-yc` — historical visit v1728 (Apr 19) now shows `Manholes 9` (was `—`).

**Follow-up ops task (not in this run)**: backfill `visits.property_id` for the 324 NULL rows from the client's primary property. Generates 324 audit rows; needs explicit Fred go-ahead.

---

### F2 — YELLOW — Admin Review's "Confirm" button is all-or-nothing

**Surfaced by**: B1 (photo classification on v5128 Mila).

When you classify N of M photos in a visit and click **Confirm (X unclassified)**, Admin Review POSTs ALL M photos to `photo_classifications` — with unclassified ones defaulting to `service_phase = 'unknown'`. The customer.wo_photos view filters out 'unknown' (and 'internal'), so only the actively-classified photos surface to FP.

**Verdict**: Working as designed. Not a bug — UX forces reviewer to acknowledge every photo, and the view hides the 'unknown' placeholders.

**Side note**: 25 audit rows in one click (24 'unknown' + 1 real). Audit log volume scales with visit photo count, not with reviewer's classification choices. Worth knowing for capacity planning.

---

### F3 — Architectural — AR's pencil edit on visit detail goes to *property*, not *per-visit override*

**Surfaced by**: A3 (intended to set visit-level override on v5130).

I tried to set `visits.manhole_count = 8` via the UI pencil on the visit detail page. The PATCH went to `/properties?id=eq.92` — Admin Review updates the **property default**, not the per-visit override. The "Use default" button likely sets `visits.manhole_count = NULL` (clears any override), but there's no UI affordance to *set* a per-visit override.

Confirms Building Apps' diagnosis: ZERO visits in DB have `visits.manhole_count` set, because Admin Review never writes it. The column is dead code unless a future UI exposes it. The view's per-visit override slot in COALESCE is currently always NULL.

---

### F4 — GREEN — Sandbox-1 reads zero lag vs Prod (right after Prod writes)

**Surfaced by**: A5 measurement.

Immediately after AR wrote to Prod via prodMirror, I queried Sandbox-1 (where AR reads from) for the same property IDs — and Sandbox showed the new values matching Prod. This contradicts the assumption that Sandbox is up-to-5-hours stale.

**Hypotheses (not investigated)**:
- (a) Sandbox refresh ran in the last few minutes (lucky timing)
- (b) prodMirror also writes Sandbox (worth grepping AR for `supabase`-keyed dual-write)
- (c) Some triggered replication I don't know about

Doesn't block anything — Sandbox showing fresher than expected is GOOD. Flagged for understanding.

---

### F5 — YELLOW — visits.property_id is widely NULL (324/424 = 76% of eligible visits)

Surfaced by F1. The Jobber sync evidently didn't backfill `visits.property_id` for historic visits. Mitigated by F1's view fallback, but the underlying data gap remains.

---

## Architecture confirmations

### Audit attribution (E1)

32 audit rows generated across the test, each attributed correctly:

| App | Table | Op | n | hint value |
|---|---|---|---|---|
| admin-review | photo_classifications | INSERT | 25 | admin-review |
| admin-review | properties | UPDATE | 2 | admin-review |
| derm-tracker | manifest_visits | DELETE | 2 | derm-tracker |
| derm-tracker | manifest_visits | INSERT | 2 | derm-tracker |
| derm-tracker | visits | UPDATE | 1 | derm-tracker |

ADR-016 X-App-Source attribution working end-to-end. Both apps' header → request_context → audit row chain intact.

### FP customer schema isolation (E4)

All FP reads observed during testing went through `accept-profile: customer` to `customer.*` views (`customer.work_orders`, `customer.wo_photos`, etc.) — never directly to `public.*`. The schema-per-app pattern from ADR is honored.

### Calendar wiring (E3)

`monthly-visitor-cheer.lovable.app` returns "Project not found" (404). ZERO `supabase.co` requests captured. Calendar is NOT live, NOT wired to any Supabase project. Confirms the original mapping that it's still a mock-data prototype.

### C-group propagation (manifest links)

| Test | Action | FP effect |
|---|---|---|
| C1 | DT attach v5132 → #825167 | n/a (immediate move test, replaced by C3 result) |
| C2 | DT unlink v5127 | v5127 derm_manifest_number → null in customer.work_orders ✓ |
| C3 | DT move v5132 to #487956 | v5132 customer.work_orders.derm_manifest_number = '487956' ✓ |
| C4 | DT toggle v4901 derm_required=false | v4901 EXCLUDED from customer.work_orders (FP service history loses it) ✓ |
| C5 | (skipped UI revert — restore handled it) | n/a |

---

## What was tested vs not

✅ Done: A1, A3, A5 (lag), B1, C1, C2, C3, C4, D1 (cross-app same visit), E1 audit, E3 calendar, E4 schema, post-fix verification
⏸ Deferred: A2 (counter-case already verified in prior session), A4 (use default — same write path as A1), B2-B5 (reclassify variants — same code path), C5 (UI revert — no per-row affordance), C6 (attach picker already validated)
🔧 Skipped because already known: 092-TCE "—" rendering, FP slug login

---

## Files left behind

- `docs/migrations/2026-05-25b_customer_work_orders_primary_property_fallback.sql` — keep, this is the fix
- `docs/cross-app-integration-test-2026-05-25/` — keep as artifact (4 docs + restored snapshot + probes)
- Disposable probes inside `probes/` — to clean up

## Restoration check

Final DB state matches snapshot exactly:
- properties 66=6, 92=3 (matched pre-test) ✓
- v4901 derm_required = NULL ✓
- manifest_visits: only the 3 original rows (v3915→976, v4742→1046, v5127→1055) ✓
- v5128 photo_classifications = 0 ✓
- v5132 manifest_visits = 0 (matches pre-test) ✓
