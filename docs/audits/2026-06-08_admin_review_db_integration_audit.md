# Admin Review App — DB Integration Audit + Sandbox→Prod Migration Plan

**Date:** 2026-06-08 · **Author:** Claude (Supabase session) · **Skill:** `unclogme-db-integration-audit`
**Scope (DB side):** how Admin Review connects to the DB today, what must change to move it off the old Sandbox onto Prod canonical, and how it lines up with the new location/manhole grain. App-side contract is documented in `Building Apps/Admin Review/docs/03-data-model.md`; the other session owns the React/Lovable changes.

---

## 0. What Admin Review is + the workflow

"**Grease Buddy — Daily Job Review Queue**" — internal ops tool (Yannick / Fred / Aaron), Lovable project `8eec2ff9-…`, live at `grease-buddy-dash.lovable.app`. It outgrew the original photo classifier; it's now a **job-review / shift-review / bonus** tool.

| Route | Workflow | Writes |
|---|---|---|
| `/` Daily Job Review Queue | stats (jobs / pending / approved / flagged / **total bonuses**), filters, **Shift Forms Pending** + **Job Review Pending** | — (read-only) |
| `/review/:jobId` | per-visit: classify photos (before/after/internal/extra), **edit manhole count**, decide **bonus / quality / invoice / notes** | `app_visit_reviews`, `photo_classifications`, `visits.manhole_count`, `properties.grease_trap_manhole_count` |
| `/review-shift/:shiftId` | pre/post-shift inspection review + driver **bonus** decision | `app_shift_reviews` |

---

## 1. Current DB connection — VERIFIED 2026-06-08 (docs + live Lovable Q&A)

Dual-client, **anon publishable key** (no auth/service-role), both send `X-App-Source: admin-review`:

| Client | Resolves to | Used for |
|---|---|---|
| `supabase` (`client.ts`, `VITE_SUPABASE_URL`) | **Sandbox #1** `ubtlwpcyntelgbykdatn` | **ALL reads + ALL primary writes** |
| `prodMirror` (`prod-mirror.ts`, `VITE_PROD_SUPABASE_URL`) | **Prod** `wbasvhvvismukaqdnouk` | **mirror writes only** (non-blocking try/catch) |

**Lovable confirmed (live, 2026-06-08), resolving the doc contradiction:**
1. `VITE_SUPABASE_URL` = **Sandbox** `https://ubtlwpcyntelgbykdatn.supabase.co`.
2. **Every** `supabase.from(...)` read *and* primary write hits Sandbox; `prodMirror` is only the secondary mirror.
3. `useSaveVisitReview` / `useSaveShiftReview` import **only** the Sandbox client — they never touch `prodMirror`. The mirror covers **only** `photo_classifications`, `visits.manhole_count`, `properties.grease_trap_manhole_count`.
4. `reviewed_by` / `bonus_decided_by` stay **NULL** — no auth layer, so no user-id at write time.

→ **`Building Apps/Admin Review/docs/09-known-issues.md #3` is stale** (it claims reads moved to Prod after the 2026-05-14 rewire). Reads are Sandbox. *(App-side doc fix — flag to the other session.)*

Other facts: **no `insert` / no `delete` anywhere — only `upsert` / `update`**; photo `<img>`s load by plain HTTPS from Prod Storage (`GT - Visits Images`), not via an SDK client.

**Reads (15, all from Sandbox):** `visits_with_review` (view), `visits`, `visit_assignments`, `employees`, `vehicles`, `jobs`, `line_items`, `properties`, `clients`, `photo_links`, `photos`, `photo_classifications`, `inspections`, `app_visit_reviews`, `app_shift_reviews`.

---

## 2. The migration problem

The app's **core output — the review/bonus decisions — lives only on Sandbox #1**, not in canonical Prod:

- **`app_visit_reviews` = 18 rows, `app_shift_reviews` = 2 rows on Sandbox; the Prod copies are EMPTY (0 rows).** The Prod mirror does not cover them.
- They survive the 5×/day Sandbox refresh **only because they are NOT in `sandbox_refresh.sh`'s `CANONICAL_TABLES`** — the refresh's `TRUNCATE … CASCADE` skips them. That preservation is incidental, not guaranteed.
- They use **legacy `external_*` keys** (`external_visit_id`, `external_employee_id`) + an **`app_` prefix**, and are **not audited**.

So bonus/payroll decisions are invisible to any Prod consumer (payroll, ops dashboards) and sit on a non-canonical, non-backed-up project. **This is what the Sandbox→Prod move must fix.**

---

## 3. DB Integration Audit — findings (the two review tables)

Prod shapes today (empty shells): `app_visit_reviews` PK `external_visit_id`; `app_shift_reviews` PK `(external_employee_id, shift_date)`; both have `review_status` CHECK (pending/approved/flagged) + `bonus_status` CHECK (pending/approved/denied), `timestamptz` columns, RLS enabled, anon `SELECT`-only grant, an `updated_at` trigger but **no `audit.log_change`**.

### HIGH (fix before/at Prod cutover)
| Table | Issue | Violation | Fix |
|---|---|---|---|
| both | **`app_` prefix** | not canonical naming (app-tier marker) | rename → `visit_reviews` / `shift_reviews` (mirrors `photo_classifications`) |
| both | **`external_*` keys** | legacy Sandbox markers, not canonical FK columns | `external_visit_id` → `visit_id bigint FK→visits(id)`; `external_employee_id` → `employee_id bigint FK→employees(id)` |
| both | **not audited** | bonus/payroll-affecting + human-edited → ADR 010 requires opt-in | add `audit.log_change` trigger (app_source already attributes `admin-review`) |
| both | **no real FKs** | Prod is canonical → integrity must be enforced | FK `visit_id`/`employee_id` + `reviewed_by`/`bonus_decided_by` → `employees(id)` |
| both | **anon `SELECT` only** | the app writes via anon (like `photo_classifications`) | anon `INSERT`/`UPDATE` RLS (anon-permissive, ship-first) — until Phase-2 auth |

### MEDIUM
| Table | Issue | Fix |
|---|---|---|
| both | FK columns unindexed | index `visit_id` (PK covers) / `employee_id`, `shift_date` |
| both | `reviewed_by`/`bonus_decided_by` always NULL | acceptable pre-auth; Phase-2 auth fills them (ties to "role-based delete" item) |

### PASS (already correct)
`timestamptz` everywhere, `numeric` n/a, `CHECK` enums on both status columns, RLS enabled, 3NF (one review per visit / per (employee, shift_date); every non-key attr depends on the key, nothing copied).

### DOMAIN FLAGS
- **App-native data, no upstream source.** The skill flags "net-new rows with no upstream" — but review/bonus decisions are *legitimately* app-sourced (the app IS their system of record), not fabricated canonical rows. Migrating the real 18+2 is correct. They are operational/payroll data → belong in canonical Prod, not stranded on Sandbox.

---

## 4. Schema placement decision (mine, per the handoff)

**Recommendation: `public` canonical base tables** `visit_reviews` + `shift_reviews`, following the **`photo_classifications` precedent** (an app-written, operational, shared table that lives in `public`, the Admin Review app writes it via anon RLS, Field Portal reads it through `customer.wo_photos`).

Rationale: review/bonus decisions are **operational, payroll-relevant, and cross-app** (payroll reads bonus, ops reads review status) — not app-private UI state. The schema-per-app pattern reserves app schemas (`customer.*`, future `review.*`) for an app's **read views over public**; the canonical write data belongs in `public`. So:
- `public.visit_reviews` + `public.shift_reviews` = canonical (the decisions).
- a future **`review.*`** schema = Admin Review's read views (queue, detail) over `public.*` — the same move Field Portal made with `customer.*`. That's the end-state that also kills the 5-hour Sandbox read lag.

*(Alternative — base tables inside a `review`/`ops` schema — is viable but departs from the `photo_classifications` precedent and splits canonical operational data out of `public`. I don't recommend it. Flagging the choice; veto if you disagree.)*

---

## 5. Migration plan (staged — execute when you say go; not done yet)

**A. Create canonical tables on Prod** — `public.visit_reviews` + `public.shift_reviews` (DDL in §7), with FKs, CHECKs, indexes, RLS (anon-permissive), audit triggers.

**B. Migrate the data Sandbox → Prod** — copy the 18 + 2 rows. The `external_*` values **are** canonical ids (the app reads Sandbox visits/employees which mirror Prod), so the mapping is direct: `external_visit_id → visit_id`, `external_employee_id → employee_id`. Read Sandbox via the Management API (same `SUPABASE_PAT`, project ref `ubtlwpcyntelgbykdatn`). **Verify FK integrity first** — drop/repair any `external_visit_id` not present in Prod `visits` (soft-deleted/changed) before insert.

**C. Add to `sandbox_refresh.sh` `CANONICAL_TABLES`** — so Sandbox mirrors Prod going forward. **ORDER MATTERS:** do this *after* B. If added before the data is on Prod, the next refresh `TRUNCATE`s the Sandbox copies and reloads 0 rows → **data loss of the 18+2**.

**D. Re-point the app (app-side, Lovable):** minimal = point the two `useSave*Review` hooks at the Prod client + the new column names (`visit_id`/`employee_id`); ideal = the full **single-Prod-client + `review.*` schema** refactor (Field Portal's `customer.*` pattern) which also fixes the 5-hour read lag. I'll draft the Lovable prompt when you're ready.

**E. Retire the legacy `app_*` tables** (Prod empty copies + Sandbox originals) after the app cuts over and a verification window passes. Soft-step: rename to `_deprecated_*` first, drop later.

---

## 6. How it connects to the NEW DB changes

- **Manhole count → manhole *locations*.** `/review/:jobId` already edits `visits.manhole_count`. The new grain replaces that with **which manholes** a visit serviced, via the contract already shipped: read `public.visit_manhole_options`, write `public.set_visit_manholes(visit_id, location_ids[])`. The review screen is the right home for it (you said so) — it resolves multi-manhole attribution (Casa Neos) and feeds per-manhole DERM. *(The count column can stay as a secondary field or be retired once locations are tagged.)*
- **Prod-direct unlocks the live grain.** Once Admin Review reads Prod (step D), it sees `visit_locations` / `client_locations` / the new GDO links live, with no Sandbox lag.
- **Reviewer identity (Phase-2 auth)** will fill `reviewed_by`/`bonus_decided_by` and tie into the planned role-based-delete RLS (Building Apps rule #7).

---

## 7. Migration SQL (ready — apply at step A)

```sql
-- public.visit_reviews — per-visit review/bonus decisions (canonical; from app_visit_reviews)
CREATE TABLE IF NOT EXISTS public.visit_reviews (
  visit_id          bigint PRIMARY KEY REFERENCES public.visits(id) ON DELETE CASCADE,
  review_status     text NOT NULL DEFAULT 'pending' CHECK (review_status = ANY (ARRAY['pending','approved','flagged'])),
  reviewed_at       timestamptz,
  reviewed_by       bigint REFERENCES public.employees(id) ON DELETE SET NULL,
  bonus_status      text NOT NULL DEFAULT 'pending' CHECK (bonus_status = ANY (ARRAY['pending','approved','denied'])),
  bonus_decided_at  timestamptz,
  bonus_decided_by  bigint REFERENCES public.employees(id) ON DELETE SET NULL,
  bonus_denial_note text,
  quality_flag_note text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

-- public.shift_reviews — per-driver-shift review/bonus (canonical; from app_shift_reviews)
CREATE TABLE IF NOT EXISTS public.shift_reviews (
  employee_id       bigint NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  shift_date        date   NOT NULL,
  review_status     text NOT NULL DEFAULT 'pending' CHECK (review_status = ANY (ARRAY['pending','approved','flagged'])),
  reviewed_at       timestamptz,
  reviewed_by       bigint REFERENCES public.employees(id) ON DELETE SET NULL,
  bonus_status      text NOT NULL DEFAULT 'pending' CHECK (bonus_status = ANY (ARRAY['pending','approved','denied'])),
  bonus_decided_at  timestamptz,
  bonus_decided_by  bigint REFERENCES public.employees(id) ON DELETE SET NULL,
  bonus_denial_note text,
  shift_quality_note text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (employee_id, shift_date)
);

CREATE INDEX IF NOT EXISTS idx_shift_reviews_employee ON public.shift_reviews(employee_id);

-- updated_at + audit (ADR 010 opt-in)
CREATE TRIGGER trg_visit_reviews_updated_at BEFORE UPDATE ON public.visit_reviews FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_shift_reviews_updated_at BEFORE UPDATE ON public.shift_reviews FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER audit_visit_reviews AFTER INSERT OR UPDATE OR DELETE ON public.visit_reviews FOR EACH ROW EXECUTE FUNCTION audit.log_change();
CREATE TRIGGER audit_shift_reviews AFTER INSERT OR UPDATE OR DELETE ON public.shift_reviews FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- grants + RLS (anon-permissive write, ship-first; tighten at Phase-2 auth)
ALTER TABLE public.visit_reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shift_reviews ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE ON public.visit_reviews TO anon;
GRANT SELECT, INSERT, UPDATE ON public.shift_reviews TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.visit_reviews TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.shift_reviews TO authenticated;
GRANT ALL ON public.visit_reviews TO service_role;
GRANT ALL ON public.shift_reviews TO service_role;
-- policies: anon SELECT/INSERT/UPDATE permissive (DROP POLICY IF EXISTS … then CREATE; one per cmd)
```

*(Exact policy DDL + the data-copy + the `sandbox_refresh` line get finalized when we run the move. `set_updated_at` is the existing canonical updated_at function — confirm its name at apply time.)*

---

## 8. Open decisions for Fred
1. **Schema placement** — confirm `public.visit_reviews` / `public.shift_reviews` (my recommendation), vs a `review`/`ops` base-table schema.
2. **Move scope** — minimal (re-point the 2 review hooks to Prod) **or** full single-Prod-client + `review.*` refactor (kills the 5h lag; bigger app change).
3. **Timing** — do the move now, or stage it after the manhole-location wiring on `/review/:jobId`.
4. **Manhole count** — keep `visits.manhole_count` alongside `visit_locations`, or retire it once locations are tagged?
