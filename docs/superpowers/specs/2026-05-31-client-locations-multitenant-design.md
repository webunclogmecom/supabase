# Client Locations — DB Design / Anchor Document (v2 · GDO-grain)

**Status: IMPLEMENTED (identity layer) 2026-06-01 — migrations `2026-06-01` + `2026-06-01b` applied to Prod (§13). D-track (Wynd DERM) + Phase-2 (other multi-GDO clients) pending (§12).**
**Date: 2026-05-31 (v1) · rewritten 2026-06-01 (v2, after Fred's GDO-grain reframe)**
**Owner (DB): this repo (`Supabase/`) · Owner (apps): `Building Apps/` (Lovable)**
**Driving cases: Wynd 28 (`clients.id=233`, food-hall, 5 tenants) + Casa Neos (`clients.id=369`, 3 service areas)**

> Single self-contained anchor so this change survives across Claude Code sessions
> without losing context (Fred's explicit concern). Read top-to-bottom before touching
> the DB. **v2 supersedes v1** (v1 modelled Wynd tenants from Airtable rec-ids and left
> Casa Neos out of scope; Fred's 2026-06-01 reframe makes the model GDO-grain, native,
> and general). The exact applied SQL lives in the three `2026-06-01*` migration files
> referenced in §9 — those files are canonical if this doc ever drifts.

---

## 1. What changed v1 → v2 (read this first)

Fred's 2026-06-01 reframe (verbatim drivers):
- *"1 client with multiple locations (or tenants, or whatever it is) — each location (tenant or w.e) have a GDO. This is true for Casa Neos, and for Wynd 28, and for all others."*
- *"AT is gonna be sunset this week … I don't want the tenants/locations in Airtable."*
- *"I will remove the client codes of each tenant of Wynd 28 … it's gonna be only 1 client like `228-WYN Wynd 28`, same in Jobber."*
- Q1 answered: **each tenant/location has its OWN distinct GDO.**

| Topic | v1 (rejected) | **v2 (this doc)** |
|---|---|---|
| Grain | tenants = name-only identity | **location = a GDO-bearing service unit** (general) |
| `gdos.client_location_id` | deferred, gated on Q1 | **core column, in the base migration** (Q1 = yes) |
| Tenant identity source | Airtable rec-ids (`216-220-WYN`) via `entity_source_links` | **native canonical rows**; Wynd names lifted from AT once, before sunset; **no AT links** |
| Casa Neos | out of scope ("do nothing") | **folded in as the proof case** (3 locations ↔ 3 existing GDOs) |
| Wynd 28 | 5 AT tenant-clients | **1 client** (id 233); Fred sets one code `228-WYN` in Jobber→syncs; 5 native locations |
| Scope now | Wynd only | **Casa Neos (3) + Wynd (5)**; the other 10 multi-GDO clients staged behind a GDO-dedup cleanup |

---

## 2. Problem & context

A **location** is a named service unit under one client, each holding its own Miami-Dade
**GDO** (grease-control permit) and therefore its own DERM reporting line:

- **Wynd 28** (`clients.id=233`, food hall at 127 NW 27th St, Jobber gid `…MjYxNDIwNDg=`) —
  5 restaurant **tenants**: Pasta / Presidente / CU4 / Nino Gordo / Pari Pari. They share
  **ONE grease trap + ONE visit**, but each needs its own DERM filing. Today they exist
  ONLY as 5 throwaway Airtable clients `216-220-WYN` Diego made for DERM reporting.
- **Casa Neos** (`clients.id=369`, `009-CN`) — 3 service **areas**: Kitchens / Bars /
  Lounge, each its own GDO with its own max-frequency (60/90/30 d) and its own visit cadence.

Same abstraction, two shapes (shared-trap vs per-area). Neither has a place to store the
**location identity**: Casa Neos fakes it in `gdos.location_label` (free text); Wynd 28
parks it in Airtable. **Airtable sunsets this week**, so the identity must become native
+ canonical. Modelling locations as separate *clients* (the Airtable hack) fans the one
shared visit / trap / frequency / billing into N — corrupting visit counts, service-due
math, route stops, billing. **Goal: 1 client → N locations, shared service referenced
never copied, each location linked to its GDO.**

---

## 3. Audit findings (ground truth, 2026-06-01)

From `reports/_gdo_locations_audit.json` (probe `scripts/probes/_audit_gdo_locations.js`):

| Fact | Value | Consequence for the design |
|---|---|---|
| GDOs total | **160** across **146** clients | location↔GDO is the real grain |
| GDO count per client | 134×1, 10×2, 2×3 | only **12** clients are multi-location candidates |
| **Clean** multi-location sets | **Casa Neos only** (KITCHENS/BARS/LOUNGE) | seed it; it's the proof |
| Dirty multi-GDO clients | 11 of 12 | typo-dups `GDO-000951`/`GDO-00951`, `…-DUPMERGE-147`, `"Needs review"`, `"Not available"` → **do NOT auto-fan into locations** |
| `gdos.location_label` populated | **18/160** (89% NULL) | unusable as a bulk name source; fine for Casa Neos |
| `entity_source_links` for `entity_type='gdo'` | **none** | GDOs are already native/DERM-sourced → **locations are native too**, zero AT dependency |
| Wynd 28 GDOs ingested | **0** | locations must exist *before* their GDO → need the table; ingest GDOs in D-track |
| `derm_manifests.gdo_id` populated | 563/977 | per-facility DERM attribution partly exists already |
| `client_location` as an `entity_type` | absent | net-new type, no collision |

**The decisive findings:** (a) multi-GDO ≠ clean multi-location — a blind backfill
manufactures garbage, so **seed only the clean cases now**; (b) GDOs carry no source
links — so `client_locations` is **native canonical**, matching Fred's "no tenants in AT."

---

## 4. Decision — the model

**`client → N public.client_locations`, and each location links to its GDO via a new core
column `gdos.client_location_id` (~1:1, nullable until the permit is ingested).**

```
            clients (id=233 Wynd / id=369 Casa Neos)   ← ONE Jobber-born client
                 │ 1:N
                 ▼
        client_locations  *NEW*        property_id (FK, reference)──► properties (shared building)
         Wynd: Pasta/Presidente/…       (visits, service_configs, billing stay on
         Casa: Kitchens/Bars/Lounge      clients/properties — shared, NEVER copied)
                 ▲ client_location_id (FK, ON DELETE SET NULL)
                 │ 1 location : 0..N gdos (usually 1)
            gdos (the DERM permit)  ──gdo_id──►  derm_manifests (one manifest, N facility lines)
```

- **Identity only.** No frequency / price / trap-size / visit columns. Those stay on
  `service_configs` / `visits` at the client+property grain and are referenced.
- **Shared service preserved.** A `visit` still carries ONE `property_id`; Wynd's one
  visit is never split. Casa Neos keeps its per-area cadence (its GDOs differ in frequency).
- **DERM rides the GDO**, never a new `derm_manifests` column (see §6).

**Rejected (unchanged from v1):** tenants-as-`properties` (a visit has one `property_id`;
splits the shared visit) and tenants-as-5-clients (re-creates the duplication; violates
"Jobber owns identity" + "only migrate from upstream").

---

## 5. Table design

Full DDL: **`docs/migrations/2026-06-01_client_locations.sql`** (canonical). Shape:

```sql
public.client_locations (
  id BIGINT GENERATED ALWAYS AS IDENTITY PK,
  client_id   BIGINT NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
  name        TEXT   NOT NULL,                       -- "Pasta", "Kitchens"
  property_id BIGINT REFERENCES properties(id) ON DELETE SET NULL,  -- shared building (reference)
  status      TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','closed')),
  contact_name/contact_phone/contact_email TEXT,     -- optional per-location contact
  notes       TEXT,
  created_at/updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
UNIQUE (client_id, name)                  -- idempotent-seed ON CONFLICT target
indexes on client_id, property_id
trigger set_updated_at_client_locations  -> public.set_updated_at()
trigger audit_client_locations           -> audit.log_change()        (opt-in, ADR 010)
RLS: anon SELECT only; authenticated/service_role FOR ALL             (anon write deferred to app-wiring)

-- core link added in the same migration:
ALTER TABLE public.gdos ADD COLUMN client_location_id BIGINT
  REFERENCES public.client_locations(id) ON DELETE SET NULL;         -- + index + comment
```

**3NF (ADR 005):** every column depends on `id` and nothing else; `property_id` /
`gdos.client_location_id` are FK *references*, not copies (Rule 3). **RLS is read-only for
anon** (no app writes locations yet) — anon INSERT/UPDATE + the `audit_critical_poll`
`ANON_ALLOWED` entry land in the migration that wires the first writing app (DERM Tracker).

---

## 6. DERM integration

Per-location DERM is now **confirmed real** (Q1 = each location has its own GDO), so the
DERM track is GO (no longer gated). Rules:

1. **Tenant attribution rides the GDO:** `derm_manifests.gdo_id → gdos.client_location_id
   → client_locations`. **No `location_id`/`property_id` column on `derm_manifests`** — a
   second "which facility" key would be a normalization smell.
2. **One visit → one manifest → N facility lines, NOT N manifests.** The DERM Address PDF
   (`Building Apps/unclogme-pdf-service/pdf_service/app.py`, `_manifest_row_to_input`)
   already renders one `white_manifest_number` with multiple `FacilityRow`s. Five
   same-client manifests sharing one number would **collide** on the webhook's
   `(client_id, white_manifest_number)` dedup. (Wynd shared-trap = one manifest, 5 lines.
   Casa Neos per-area = its existing per-GDO manifests.)
3. **Prereq for Wynd DERM:** ingest Wynd's 5 GDOs (currently 0) from the DERM portal /
   Viktor lookup, then set each new `gdos.client_location_id`. That's D2–D3 in §12.
4. `manifest_visits` stays M:N for its real purpose (one dump run spanning *distinct
   clients'* visits) — never repurposed to fan one shared-trap visit into 5.

---

## 7. Seed strategy

Full SQL: **`docs/migrations/2026-06-01b_seed_casa_neos_wynd_client_locations.sql`**.

- **Casa Neos (369):** insert 3 locations (Kitchens/Bars/Lounge, property 42), then
  `UPDATE gdos SET client_location_id` matching `upper(location_label)` → links its 3 GDOs.
- **Wynd 28 (233):** insert 5 native locations (names from `reports/_wyn_at_verify.json`,
  captured from AT 2026-06-01 before sunset), property 217. **No GDO link** (0 ingested);
  provenance is a `notes` string, not an AT source link. Wynd's single `client_code`
  (`228-WYN`) is set by Fred in Jobber and flows in via `webhook-jobber` — **not seeded here**.
- **Everyone else (the 10 dirty multi-GDO clients):** **NOT seeded.** Staged as a Phase-2
  triaged backfill after a GDO-dedup cleanup (§10).

Idempotent: `ON CONFLICT (client_id, name) DO NOTHING`; the GDO-link `UPDATE` is guarded
by `IS DISTINCT FROM`; `property_id` resolved by `is_primary` sub-select (never hardcoded).
**"Only migrate from upstream" — compliant:** the client (Wynd 233) is in Jobber; the
location names are real AT data lifted with provenance; nothing is orphan-invented.

---

## 8. Downstream / app impact

**Purely additive — nothing breaks at the SQL level.** Every existing view already
collapses to one identity row per `client_id` and one property, so Wynd/Casa Neos still
render as single rows until a surface opts in to show locations.

| Surface | Change | When |
|---|---|---|
| `public.client_locations`, `gdos.client_location_id` | create / add | **now (E-track)** |
| `ops.v_service_due` / `v_derm_compliance` / billing views | **none — must stay client/trap grain** | never (do-not-touch) |
| `ops.v_calendar_visit`, `ops.v_route_today` | optional cosmetic `location_name`; keep ONE shared Wynd visit | optional |
| `derm.visits` / `derm.manifests` / `manifest_pickable_visits` | add `location_name` via `gdos.client_location_id`; choose row grain | **D-track** |
| **DERM Tracker app** | show/select the N locations; attribute manifest to a location; search by location | **D-track** (Building Apps) |
| **Field Portal** | per-client login unchanged; per-location pages only if needed later | optional |

Field Portal note: it logs in by `client_code`; Wynd 233 gets `228-WYN` (Fred, in Jobber)
so it can log in as one client. Per-location pages are a later, optional refinement.

---

## 9. Migration plan (three files)

> Applied to Prod (`wbasvhvvismukaqdnouk`) via the Management API on 2026-06-01. See §13
> for the verification results. House style matches `2026-05-27_zones_reference_table.sql`.

1. **`docs/migrations/2026-06-01_client_locations.sql`** — table + `gdos.client_location_id`
   + indexes + triggers + RLS (anon read-only) + grants.
2. **`docs/migrations/2026-06-01b_seed_casa_neos_wynd_client_locations.sql`** — Casa Neos 3
   (+ GDO links) and Wynd 5 (native).
3. **`docs/migrations/2026-06-01_rollback_client_locations.sql`** — drop column then table
   (run only to reverse).

---

## 10. Generalization — Phase 2 (staged, triaged)

The model is general ("true for all others"), but the **data is not clean enough to
auto-apply**. Read-only probe: **`scripts/probes/find_multi_location_candidates.sql`**
(H1 multi-GDO candidates + dirtiness flag, H2 malformed GDO numbers, H3 same-address
multi-client, H4 under-seeded coverage gap).

**Phase-2 order (do NOT auto-migrate):**
1. **GDO-dedup cleanup** — resolve `GDO-000951`/`GDO-00951`, `…-DUPMERGE-147`,
   `"Needs review"`, `"Not available"` (route real dups to `2026-05-25w_merge_duplicate_clients.sql`).
2. Decide a **name source** for bulk locations (label is 89% NULL): DERM facility name?
   manual? (Open Q below.)
3. Backfill `client_locations` (one per clean GDO) for the remaining real multi-location
   clients; link `gdos.client_location_id`.
4. Decide whether single-GDO clients (134) get a trivial 1-location row for uniformity, or
   stay implicit (client = its sole location).

### Phase-2 batch 1 — APPLIED 2026-06-01 (migration `2026-06-01c`)

Evidence: `reports/_gdo_dedup_evidence.json` (all 26 GDOs on the 12 multi-GDO clients, with
manifest-reference + permit-doc signals).

- **Soft-deleted 5 invalid GDO rows** (status→INACTIVE, 0 manifests + no doc each, reversible):
  132-PUM `GDO-000951` (typo-dup of `GDO-00951`), 043-MIL `"Needs review"` + `"GDO-14117 / GDO-11024"`,
  192-FRK `"Not available"`, 193-FRK `"Not available"`. → those clients collapse to a single facility.
- **Backfilled 6 locations** for the 3 confirmed multi-facility clients (different street addresses),
  naming = label-else-street-address (Fred): 025-GRO (9467 Harding + Adriana), 045-NU (266 Miracle
  Mile + 3250 NE 1st Ave), 175-PV (701 Brickell + 1104 S Miami) — each linked to its GDO.
- **HELD pending Diego/Yannick DERM verification** (`docs/phase2-gdo-verification-message.md`): the 3
  "phantom" same-property 2nd GDOs — 060-TU `GDO-13076`, 155-PV `GDO-12838`, 170-PV `GDO-11433` — plus
  two flags (Mila possible `GDO-11024`; Fresko Bakery `GDO-01861` is INACTIVE).
- **Single-facility clients NOT given a trivial location** (Q5 deferred): Pummarola, Mila, Fresko,
  Fresko Bakery, 139-LTG.

After this batch: `client_locations` = 14 rows (Casa Neos 3 + Wynd 5 + 6 here); `gdos.client_location_id` set on 9.

---

## 11. Open questions

| # | Question | Status |
|---|---|---|
| Q1 | Does each tenant/location hold a **distinct GDO**? | **ANSWERED (Fred 2026-06-01): yes.** Drove the GDO-grain model. |
| Q2 | `entity_source_links.source_id` format for AT clients | **MOOT in v2** — no AT links created (locations are native). |
| Q3 | **Name source for the Phase-2 bulk backfill** (label 89% NULL)? DERM facility name vs manual. | OPEN (Phase-2 only; does not block E-track). |
| Q4 | **GDO-dedup** of the 10 dirty multi-GDO clients — when? | OPEN (prereq to Phase-2 backfill; flagged as a separate task). |
| Q5 | **Single-GDO clients (134):** materialize a 1-location row each for uniformity, or leave implicit? | OPEN (Phase-2). |
| Q6 | Wynd's single `client_code` (`228-WYN`?) — Fred sets it in Jobber; confirm final value. | OPEN (Fred, external; syncs via webhook). |
| Q7 | Backfill Casa Neos's NULL `derm_manifests.gdo_id`s now (org-wide per-facility DERM), or defer? | OPEN (DERM Tracker Phase 3). |

---

## 12. Execution workflow

**E-track (identity — applied now):**

| # | Step | State |
|---|---|---|
| E1 | Apply `2026-06-01_client_locations.sql` (table + `gdos.client_location_id`) | §13 |
| E2 | Apply `2026-06-01b` seed (Casa Neos 3 + links, Wynd 5) | §13 |
| E3 | Verify (8 rows; 3 GDOs linked; 5 Wynd unlinked; RLS on; audit captured) | §13 |
| E4 | Update `docs/schema.md`; commit + push all four files + this doc | §13 |

**D-track (Wynd DERM — unblocked by Q1, needs the GDOs):**

| # | Step | Blocked on |
|---|---|---|
| D1 | Fred sets Wynd's single code `228-WYN` in Jobber → syncs `clients.client_code` | Fred |
| D2 | Ingest Wynd's 5 GDOs (DERM portal / Viktor lookup) into `gdos` | DERM portal |
| D3 | Set each new Wynd `gdos.client_location_id` (match GDO → Pasta/…); same `UPDATE` shape as Casa Neos | D2 |
| D4 | Add `location_name` to `derm.visits`/`derm.manifests`/`manifest_pickable_visits` (via `gdos.client_location_id`) | D3 |
| D5 | DERM Tracker app: show/select 5 locations; attribute manifest; search by location | D4 (Building Apps) |

**Phase-2 track (the other 10 multi-GDO clients):** §10 — GDO-dedup → name source → backfill.

**Resumption check for a future session:** `to_regclass('public.client_locations')` non-NULL
(E1 done) and 8 rows for clients (233,369) (E2 done). `ops.v_service_due` /
`v_derm_compliance` / billing views must stay client/trap grain at every step.

---

## 13. Applied — verification log

**Applied to Prod (`wbasvhvvismukaqdnouk`) 2026-06-01** via the Management API
(`scripts/probes/_apply_client_locations.js`; raw results `reports/_apply_client_locations.json`).

| Check | Result |
|---|---|
| `public.client_locations` exists | ✅ `to_regclass` = `client_locations` |
| `gdos.client_location_id` added | ✅ column present, FK → `client_locations(id)` ON DELETE SET NULL, indexed |
| RLS enabled | ✅ `relrowsecurity = true` (anon **SELECT**, authenticated **ALL**) |
| Rows seeded | ✅ **8** — Casa Neos 3 (Kitchens/Bars/Lounge → prop 42); Wynd 5 (Pasta/Presidente/CU4/Nino Gordo/Pari Pari → prop 217) |
| Casa Neos GDOs linked | ✅ 3/3 — GDO-10877→Kitchens, GDO-15062→Bars, GDO-16389→Lounge |
| Wynd locations unlinked | ✅ 5/5 (0 GDOs ingested yet — expected; D-track) |
| Audit trail | ✅ 8 `client_locations` INSERT + 3 `gdos` UPDATE in `audit.logs` |

**Reversible:** `docs/migrations/2026-06-01_rollback_client_locations.sql` (drops column then table).
**E-track complete.** Next: **D1** (Fred sets Wynd's single code in Jobber) → **D2** (ingest Wynd's 5 GDOs) → **D3** link → DERM Tracker. Phase-2 (other 10 multi-GDO clients) gated on GDO-dedup (§10).

---

### Reference files (absolute)
- Migrations: `…\Supabase\docs\migrations\2026-06-01_client_locations.sql`, `…\2026-06-01b_seed_casa_neos_wynd_client_locations.sql`, `…\2026-06-01_rollback_client_locations.sql`
- Probe (Phase-2 discovery): `…\Supabase\scripts\probes\find_multi_location_candidates.sql`
- Audit ground truth: `…\Supabase\reports\_gdo_locations_audit.json` (probe `…\scripts\probes\_audit_gdo_locations.js`)
- Wynd names captured pre-sunset: `…\Supabase\reports\_wyn_at_verify.json`
- House-style template: `…\Supabase\docs\migrations\2026-05-27_zones_reference_table.sql`
- ADRs: `…\docs\decisions\002-entity-source-links.md`, `…\005-3nf-standing-check.md`, `…\010-audit-trail.md`
- Multi-facility DERM PDF: `…\Building Apps\unclogme-pdf-service\pdf_service\app.py` (`_manifest_row_to_input`)
- Audit-alert allow-list (for D-track app-wiring): `…\Supabase\scripts\alerts\audit_critical_poll.js` (`ANON_ALLOWED`)
