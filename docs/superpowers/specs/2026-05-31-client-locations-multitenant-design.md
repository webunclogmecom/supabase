# Client Locations (Multi-Tenant) — DB Design / Anchor Document

**Status: DESIGN — not yet implemented**
**Date: 2026-05-31**
**Owner (DB): this repo (`Supabase/`) · Owner (apps): `Building Apps/` (Lovable) sessions**
**Driving case: Wynd 28 (`public.clients.id = 233`) · 5 Airtable tenant-clients `216-220-WYN`**

> Purpose: a single self-contained anchor so this change can be executed across **multiple Claude Code
> sessions without losing context** (Fred's explicit concern). Read this top-to-bottom before touching
> the DB or any app. The SQL in §9 is **NOT-YET-APPLIED**. The one decision that gates real work is
> §11 Q1 (per-tenant DERM — real Miami-Dade requirement vs Diego's reporting convenience).

---

## 1. Title + status

See header. This document supersedes nothing; it is the canonical spec for `public.client_locations`.
When the migrations in §9 are applied, change the status line to `IMPLEMENTED <date>` and record the
applied filenames; keep the rest as the historical design record.

---

## 2. Problem & context

**Wynd 28 is ONE real client** — a food-hall building at 127 NW 27th St, Miami. In Jobber and in our DB
it is a **single client**: `public.clients.id = 233`, `client_code = NULL`, `status = ACTIVE`
(Jobber gid `Z2lkOi8vSm9iYmVyL0NsaWVudC8xMjYxNDIwNDg=`).

It contains **5 restaurant TENANTS** that exist **only in Airtable** as 5 separate Clients records
(base `appjMgjjZPeuudqQR`, table `tbl5lXLtHKUWilDDj`). They are **NOT in Jobber**:

| AT code | Tenant name | AT record id |
|---|---|---|
| 216-WYN | Pasta | `recQDk0XC002RZbHc` |
| 217-WYN | Presidente | `reclOvCnNC9OzBv3j` |
| 218-WYN | CU4 | `recwVPjJV8qtbSRBL` |
| 219-WYN | Nino Gordo | `recOHiK46Vw0gx4ZI` |
| 220-WYN | Pari Pari | `recz4f4YH8wrc21Fk` |

*(Historically 6 exist: 4 active + 2 closed. Per Fred 2026-06-01: **model 5 as active for now**; the
2 closed are not seeded yet.)* Proof they are AT-only: `Supabase/docs/reports/jobber_at_diff.json`
lists all five under `at_only`, corroborated by probes 89/91/93/94.

**Why Diego created them:** **per-restaurant DERM reporting** — he wanted each restaurant to get its own
DERM report filed with Miami-Dade DERM. This is the crux and the source of the only hard open question.

**Physical reality:** all 5 tenants **share ONE grease trap**, serviced by **ONE visit on one date**.
This is *unlike* Casa Neos (see §3).

**The duplication problem we are killing:** if we model the 5 tenants as 5 real clients (or as 5
properties), then the one shared visit / trap / frequency / billing event fans out into 5 — corrupting
visit counts, service-due math, route stops, and billing.

**Goal:** **1 client → N named tenant-locations.** One shared visit, one trap, one frequency, one
billing line — **never duplicated per tenant**. Tenants get a stable name/identity (and a place to hang
per-tenant DERM later) without forking the shared service.

---

## 3. Current schema — what already exists

The schema **already supports 1-client → N-properties** and per-property facilities. Nothing new is
needed to *store* the shared service; the gap is purely a per-tenant **identity** row.

| Table | Grain | Relevant columns |
|---|---|---|
| `clients` | the business | `id, client_code, name, status, client_class, group_id, balance, notes` |
| `properties` | a physical service site | `id, client_id FK, name, address, …, is_primary, is_billing, grease_trap_manhole_count, default_disposal_facility_id` |
| `service_configs` | a subscription line | `id, client_id FK, service_type, frequency_days, price_per_visit, equipment_size_gallons, property_id FK` |
| `gdos` | a permitted facility (DERM unit) | `id, client_id FK, gdo_number, location_label, property_id FK, permit_expiration, status, max_frequency_days` |
| `visits` | one service event | `id, client_id FK, property_id FK (ONE), job_id, vehicle_id, visit_date, service_type, derm_required, source, deleted_at` |
| `derm_manifests` | one filed manifest | `id, client_id FK, white_manifest_number, yellow_ticket_number, gdo_id FK, disposal_facility_id FK, service_date, …` (no `location_id`/`property_id`) |
| `manifest_visits` | M:N visits↔manifests | `(visit_id FK, manifest_id FK)` — **already M:N**, PK both |
| `entity_source_links` | cross-system ID bridge (ADR 002) | `entity_type, entity_id, source_system, source_id, source_name, match_method, match_confidence` |

**Key facts the design leans on:**
- A **visit carries exactly ONE `property_id`** — so a tenant cannot be a `property` without splitting the visit.
- The **DERM "which facility" pointer is `gdos.id` (`derm_manifests.gdo_id`)**, not a location/property pointer. A GDO = `(client, property, location_label)`.
- `manifest_visits` is **already M:N** → one visit *can* link to N manifests (its real purpose: one dump run spanning several *distinct clients'* visits).

### Casa Neos contrast — OUT OF SCOPE, leave as-is

| | Wynd 28 (this design) | Casa Neos (`009-CN`, `id 369`) |
|---|---|---|
| What it is | 1 building, **multiple tenants** | **1 restaurant**, multiple service points |
| Service points | **1 shared trap, 1 visit/date** | 3 GDO/manhole groups, different max-frequencies, **separate visits** |
| DB model | 1 client + **N `client_locations`** | 1 client + 3 GDOs on **one `property_id=42`**, disambiguated by `gdos.location_label` = KITCHENS/BARS/LOUNGE |
| Action | build `client_locations` | **do nothing** — already correctly modeled |

**Do NOT put Casa Neos in `client_locations`.** Multi-service-point ≠ multi-tenant. (Live note: Casa
Neos's 15 `derm_manifests` are all `gdo_id = NULL` today — per-facility DERM attribution exists in the
schema but has never been populated for anyone; see §6.)

---

## 4. Decision — Approach A (`client_locations` table)

**Adopt Approach A: a new lightweight `public.client_locations` table — 1 client → N named tenant-locations.**
Visits / GDOs / frequency / price / billing stay shared on their existing tables and are **referenced,
never copied**.

**3NF rationale (ADR 005):** PK is `id`. Every non-key column (`client_id`, `name`, `property_id`,
`status`, `contact_*`, `notes`) depends on the whole key and nothing else. `property_id` is a *reference*
to the shared building (FK), **not a snapshot** of any property attribute (Rule 3). No
frequency/price/trap-size/visit columns live here — those belong to `service_configs`/`gdos`/`visits`
at the client+property grain.

**Rejected alternatives:**

| Approach | What it is | Why rejected |
|---|---|---|
| **B — tenants as `properties`** | 5 property rows under client 233 | A visit has **one `property_id`**; properties imply separate service points + manholes/GDO. Splits the shared visit. Wrong grain. |
| **C — 5 separate clients under a `client_group`** | TCE-chain pattern | Re-creates the exact **visit duplication** we are killing. Also violates "Jobber owns identity" (the 5 aren't in Jobber) and the upstream-migration rule. |

---

## 5. Table design

### DDL (canonical shape; full migration in §9a)

```sql
CREATE TABLE public.client_locations (
  id             BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  client_id      BIGINT       NOT NULL REFERENCES public.clients(id) ON DELETE CASCADE,
  name           TEXT         NOT NULL,
  property_id    BIGINT       REFERENCES public.properties(id) ON DELETE SET NULL,
  status         TEXT         NOT NULL DEFAULT 'active' CHECK (status IN ('active','closed')),
  contact_name   TEXT,
  contact_phone  TEXT,
  contact_email  TEXT,
  notes          TEXT,
  created_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);
-- UNIQUE (client_id, name)  -- idempotent-seed ON CONFLICT target
-- indexes on client_id, property_id
-- trigger set_updated_at_client_locations  -> public.set_updated_at()
-- trigger audit_client_locations           -> audit.log_change()   (opt-in, ADR 010)
-- RLS anon-permissive FOR ALL (ship-first); grants to anon/authenticated/service_role
```

### ASCII ER — where `client_locations` plugs in

```
                         ┌──────────────────────┐
                         │  clients (id=233)    │  ← Jobber-born identity (ONE row)
                         │  "Wynd 28"           │
                         └─────────┬────────────┘
              ┌────────────────────┼─────────────────────────────┐
              │ 1:N                │ 1:N                          │ 1:N
              ▼                    ▼                              ▼
   ┌────────────────────┐  ┌────────────────────┐      ┌────────────────────────┐
   │ properties         │  │ service_configs    │      │ client_locations  *NEW* │
   │ (shared building,  │  │ (1 shared GT line, │      │  216 Pasta             │
   │  e.g. id=217)      │  │  freq/price)       │      │  217 Presidente        │
   └─────────┬──────────┘  └────────────────────┘      │  218 CU4               │
             │ property_id (FK, reference only)  ┌──────│  219 Nino Gordo        │
             │◄─────────────────────────────────┘      │  220 Pari Pari         │
             │                                          └───────────┬────────────┘
             │ 1:N                                                  │ (FUTURE, §6 path 2 only)
             ▼                                                      │ gdos.client_location_id
   ┌────────────────────┐        ┌──────────────────────┐          │
   │ gdos               │◄───────│ derm_manifests       │          │
   │ (per-facility,     │ gdo_id │ (client_id, gdo_id,  │          ▼
   │  location_label)   │        │  white_manifest#)    │   (a GDO MAY point at a
   └─────────┬──────────┘        └──────────┬───────────┘    tenant-location instead
             │                              │ M:N             of a free-text label)
             │              ┌───────────────┘
             ▼              ▼
   ┌────────────────────┐  ┌──────────────────────┐
   │ visits (ONE shared │  │ manifest_visits      │   AT codes 216-220-WYN map to
   │  visit, ONE        │──│ (visit_id,           │   client_locations.id via
   │  property_id)      │  │  manifest_id) M:N    │   entity_source_links
   └────────────────────┘  └──────────────────────┘   (entity_type='client_location')
```

**Reading the ER:** `client_locations` hangs off `clients` purely as identity, optionally grouped under
the shared `property`. It **does not sit between** `clients` and `visits/service_configs` — those keep
their existing direct FKs to `clients`/`properties`, so the shared service is never duplicated. The only
DERM linkage (and only on §6 path 2) is `gdos.client_location_id` → `client_locations.id`; `derm_manifests`
itself gains **no** new column.

---

## 6. DERM integration

This is the reason the 5 AT tenants exist, and the only place a genuine open question remains.

### How DERM links today (3 levels)
1. **Per-client (required):** `derm_manifests.client_id → clients.id`.
2. **Per-visit (M:N, sparse):** `manifest_visits(manifest_id, visit_id)` — populated by the webhook
   matching completed GT visits within ±2 days of `GT Last Visit` (window is unreliable; weekly backfill
   via the AT `Visits` field is the canonical fixer).
3. **Per-GDO (nullable, mostly unused):** `derm_manifests.gdo_id → gdos.id` — added in migration
   `2026-05-20g` precisely to attribute a manifest to a specific facility (Bar vs Kitchen). Auto-linked
   only for single-GDO clients; **multi-GDO clients (Casa Neos, and by design Wynd) stay NULL** pending
   ops to pick the facility.

**So the canonical "which restaurant" pointer is `gdo_id`, not a location pointer.**

### The PDF is already multi-facility (decisive)
The DERM Address PDF (`Building Apps/unclogme-pdf-service/pdf_service/app.py`,
`_manifest_row_to_input`) renders **ONE manifest (one `white_manifest_number`) with MULTIPLE
`FacilityRow` siblings** — each row = one facility (`gdo_number` + `facility_name` + `facility_address`
+ `client_code`). The city-facing artifact is inherently multi-facility. So "each restaurant appears on
the DERM filing" does **not** require 5 separate manifest rows.

### Recommendation
1. **Make `client_locations` the facility grain and bind GDOs to it** — *if and only if* §11 Q1 says
   per-tenant DERM is real. Add `gdos.client_location_id BIGINT NULL → client_locations.id` (a clean,
   non-breaking `ALTER`, deferred to a follow-up migration). A GDO already means "a permitted facility";
   `client_locations` gives it a real FK target instead of a free-text `location_label`.
2. **Do NOT add `location_id`/`property_id` to `derm_manifests`.** Its facility pointer stays **`gdo_id`**.
   Tenant identity is derived: `derm_manifests.gdo_id → gdos.client_location_id → client_locations`.
   A parallel `location_id` would be a second competing "which facility" key — a normalization smell.
3. **Model Wynd as ONE visit → ONE manifest → N facility lines**, not 5 manifests. Matches physical
   reality (one trap, one pump, one dump ticket). **Five same-client manifests sharing one
   `white_manifest_number` would collide** with the webhook's `(client_id, white_manifest_number)` dedup
   (lines 553–567) because all 5 tenants are `client_id=233` → a unique-constraint violation. Concrete
   schema evidence that one-manifest-many-facilities is the intended model.
4. **Keep `manifest_visits` M:N for its real purpose** (one dump run spanning multiple *distinct clients'*
   visits) — do not repurpose it to fan one shared-trap visit into 5.
5. **Backfill prerequisite:** the 5 Wynd GDOs are **absent** from `gdos` (client 233 has 0). They were
   never ingested from AT. Ingesting them is a prerequisite to any per-tenant DERM (same gap that leaves
   Casa Neos's 15 manifests at `gdo_id = NULL`).

### The open question (see §11 Q1)
**Is per-restaurant DERM a real Miami-Dade requirement, or Diego's reporting convenience?**
- DERM permits **per facility** (GDO), confirmed via the repo's own domain research (`gdo-phase-2`
  README, "confirmed via web research + Fred 2026-05-25"). Migration `2026-05-20g` line 13 **explicitly
  names "216-220 WYN" as the same pattern as Casa Neos's BAR.** Diego's instinct aligns with how the
  city permits work.
- **But we cannot confirm from data** whether each Wynd tenant holds a distinct `GDO-#####`, because Wynd
  has 0 GDOs ingested. If each tenant has its own GDO → per-tenant DERM is unambiguously required (Casa
  Neos pattern). If all 5 share **one** GDO on the shared trap → "5 separate reports" is a
  presentation choice, satisfied by one manifest with 5 facility lines.

**Net:** `client_locations` plugs in **underneath `gdos`**, never into `derm_manifests` directly. This
migration deliberately ships **no** DERM FK yet (§9 is identity-only); the DERM wiring is a small,
non-breaking follow-up gated on Q1.

---

## 7. Sync / seed

**Recommendation: one-time idempotent SEED script. Do NOT patch `webhook-airtable`.**

### Today's behavior — the 5 AT records are silently DROPPED (not phantom clients)
- `webhook-airtable` **never inserts a client** — the only client `INSERT` in `supabase/functions/` is
  in `webhook-jobber` (`index.ts:320-323`). `handleClientRecord` *resolves* an existing client and bails:
  `findEntityBySourceId('client','airtable', recordId)` → null, then `clients.client_code = '216-WYN'…`
  → miss (no Jobber-born client carries those codes), then `if (!clientId) { …skipping; return }`
  (lines 197-200). **So there is no cleanup debt — the seed is purely additive.**

### Seed vs webhook — why seed wins
| | One-time seed | Webhook patch |
|---|---|---|
| Records | 5 (finite, known) | 5 (same) |
| Value lifespan | **Permanent** | ~3 weeks until AT sunsets, then dead code |
| Code risk | Isolated, idempotent; touches nothing live | Modifies the **most-patched** production handler (the 2026-05-13 "307 drift" function) for the 200+-client hot path |
| Detection problem | **Avoided** — hard-codes 5 AT ids → tenant names → parent `client_id=233` | Must distinguish "tenant" from "client" via fragile signals (WYN suffix / address clustering / a parent field that doesn't exist in AT) |
| Post-sunset | None | Becomes dead code to rip out (`project_post_sunset_cleanup.md`) |

AT sunsets in ~3 weeks and is best-effort/non-authoritative here (canonical only for `derm_manifests`+
`inspections`). Building live plumbing whose entire useful life is 3 weeks, against the riskiest handler,
to manage 5 static rows, is the wrong trade.

### `entity_source_links` design (per row, net-new `entity_type`)
```
entity_type      = 'client_location'        -- grep-confirmed nowhere today; type-agnostic helper, zero schema change
entity_id        = <new client_locations.id>
source_system    = 'airtable'
source_id        = 'recQDk0XC002RZbHc'       -- AT rec-id (house convention, verified 2026-06-01)
source_name      = '216-WYN Pasta'          -- code + tenant name, for debugging
match_method     = 'manual'
match_confidence = 1.00
```
- Satisfies both ADR-002 uniques — `(entity_type, entity_id, source_system)` and
  `(entity_type, source_system, source_id)` — since each tenant is 1 location ↔ 1 AT record (1:1).
- **Free correctness on the destroyed path:** `webhook-airtable` derives the soft-delete table as
  `` `${entity_type}s` `` (lines 920, 984), special-casing only `derm_manifest`. `client_location` →
  `client_locations` resolves correctly with **no special-casing**.
- **`source_id` format note — RESOLVED 2026-06-01:** existing `entity_type='client'` AT links store the
  Airtable **record id** as `source_id` (verified live: `rec03SARDaMyqHJZf` / `source_name='155-PV Pura
  Vida Flamingo'`). So §9b uses the **rec-id** for `source_id` and `'code name'` for `source_name`. The 5
  WYN rec-ids were re-verified against base `appjMgjjZPeuudqQR` (`reports/_wyn_at_verify.json`): 216→`recQDk0XC002RZbHc`,
  217→`reclOvCnNC9OzBv3j`, 218→`recwVPjJV8qtbSRBL`, 219→`recOHiK46Vw0gx4ZI`, 220→`recz4f4YH8wrc21Fk`.

### "Only migrate from upstream" rule — COMPLIANT
- The canonical entity (Wynd 28, id 233) is **already in Jobber** — we invent **no** client.
- The tenant names **ARE upstream data** (real AT records), recorded with provenance in
  `entity_source_links` (`source_system='airtable'`) — textbook AT-as-enrichment (same as AT already
  enriches access_hours/zone/county).
- It doesn't break wipe+repop: `client_locations` repopulates from the same AT snapshot
  (`jobber_at_diff.json` preserves all 5 names + ids). Every row is sourced, not orphan-invented.
- **Guardrail:** run the seed **while AT records are still readable** (or from the captured snapshot).
  After sunset the seed *is* the canonical record — the intended outcome.

---

## 8. Downstream / app impact

**Headline: `client_locations` is purely additive — nothing breaks at the SQL level.** Every consuming
view already collapses to **one identity row per `client_id`** (`c.name AS client_name`) and picks **one
property** (`is_primary`/`LIMIT 1`). Wynd 28 already appears as a single row everywhere. The real
question is *which surfaces should now show 5 tenant names where they show 1* — a view + app-UI change,
**not migration-forced**. The one load-bearing case is **DERM Tracker** (per-tenant DERM is the whole
reason the 5 AT clients exist).

| View / App surface | Change needed | Owner |
|---|---|---|
| `public.client_locations` (new table) | Create; opt-in audit trigger; loose ref to `properties` | **DB** |
| `derm.visits` | Optional: add `location_name` (join `client_locations`); decide row grain (1 shared visit vs N tenant rows) | **DB** (view) |
| `derm.manifests` | Expose `location_name` *if* manifests gain tenant attribution (via `gdo_id` path) | **DB** (view) |
| `derm.manifest_visits` | Expose `location_name` for linkage display | **DB** (view) |
| `public.manifest_pickable_visits` | Expose tenant rows in `/upload` picker **if** per-tenant DERM | **DB** (view) |
| `public.derm_manifests` | **No new column.** (Per-tenant DERM attribution rides `gdo_id → gdos.client_location_id`; M:N `manifest_visits` already supports N manifests/visit.) | **DB** — *gated on §11 Q1* |
| `gdos` | **Only if per-tenant DERM:** add nullable `client_location_id` FK → `client_locations` (non-breaking ALTER, follow-up migration) | **DB** — *gated on §11 Q1* |
| **DERM Tracker app** (visit list `/`, `/upload` matcher, manifest list, search) | Show/select the 5 tenant-locations; attribute manifest to a tenant; search by tenant name | **Building Apps** (Lovable) — *gated on §11 Q1* |
| `ops.v_calendar_visit` | Optional: surface `location_name` on card; keep **ONE** shared Wynd visit (never fan to 5) | **DB** (view) / **Building Apps** (display) |
| **Visit Calendar app** | Cosmetic only: show "Wynd 28" (or "+5 tenants"); **no** per-tenant visit creation | **Building Apps** (Lovable) |
| `ops.v_route_today` | None required (route = one physical shared stop); optional `location_name` | DB (optional) |
| `ops.v_service_due` / `clients_due_service` / `ops.v_derm_compliance` | **No change — must stay client/trap grain** (per-tenant would double-count the shared frequency/trap) | **DB (do-not-touch)** |
| `ops.v_gdo_expiry` | None — already per-gdo/property grain | n/a |
| `customer.clients` / `customer.work_orders` / `customer.scheduled_visits` (Field Portal) | **No change if portal stays per-client.** Per-tenant login/pages require a location-scoped slug + `client_location_id` filter | **DB** (views) + **Building Apps** — *gated on §11 Q1* |
| `customer.permits` / `inspection_items` / `recommendations` / `wo_photos` | None | n/a |
| `visits_recent` / `visits_with_status` | None (cosmetic) | n/a |

**Field Portal note:** it logs in by `client_code → customer.clients (slug = lower(client_code))`. Wynd
233 has `client_code = NULL` and the tenants have AT-only codes → **no tenant can log in today**. Per-tenant
portal pages are only justified if DERM goes per-tenant (Q1); per-client is the lower-friction default.

**Audit note:** `client_locations` itself opts into audit (human-editable identity). If `gdos`/
`derm_manifests` later gain a column, it's auto-captured (both already audited) — no new trigger.

**Bottom line for any session:** the single decision that propagates is **§11 Q1**. If per-tenant DERM
→ `gdos.client_location_id` (DB) + `location_name` on the 4 `derm.*`/picker views (DB) + DERM Tracker UI
(Building Apps). If once-per-trap → `client_locations` is invisible to every app, a pure identity/label
convenience. `ops.v_service_due`/`v_derm_compliance`/billing views **stay client-grain regardless.**

---

## 9. Migration plan

> **ALL SQL BELOW IS NOT-YET-APPLIED.** Review, then apply to Prod (`wbasvhvvismukaqdnouk`) via the
> Management API / psql. House style matches `2026-05-27_zones_reference_table.sql` +
> `2026-05-14d_photo_classifications.sql`. Canonical functions confirmed against repo:
> `public.set_updated_at()` and `audit.log_change()` (+ `CREATE TRIGGER audit_<table>`).
>
> **Companion action (same cycle, else a false Slack alarm fires on first write):** add
> `client_locations:INSERT`, `client_locations:UPDATE`, `client_locations:DELETE` to `ANON_ALLOWED` in
> `Supabase/scripts/alerts/audit_critical_poll.js` (ADR 010 §Tier-1 condition 4). Tracked as Execution
> step E2 / spawn-task.

### 9a. `Supabase/docs/migrations/2026-06-01_client_locations.sql` (DDL)

```sql
-- 2026-06-01_client_locations.sql
--
-- New canonical table public.client_locations: one client -> N named
-- tenant-locations. Driven by "Wynd 28" (public.clients id=233, a food-hall at
-- 127 NW 27th St) that physically contains multiple restaurant TENANTS sharing
-- ONE grease trap and serviced by ONE visit. Tenants need a separate
-- NAME/IDENTITY for operations and (pending) per-tenant DERM reporting, but
-- must NEVER fork the shared visit / trap / frequency / billing.
--
-- BACKGROUND
--   The 5 Wynd 28 tenants (216-WYN Pasta, 217-WYN Presidente, 218-WYN CU4,
--   219-WYN Nino Gordo, 220-WYN Pari Pari) exist today ONLY in Airtable as 5
--   separate Clients records (codes 216-220-WYN, base appjMgjjZPeuudqQR).
--   Diego created them so each restaurant gets its own DERM report filed with
--   Miami-Dade DERM. They are NOT in Jobber; Jobber has the single client
--   (id=233). Modelling them as 5 Prod clients re-creates the visit duplication
--   we are killing (rejected Approach C); as properties is wrong (a visit has
--   ONE property_id; properties imply separate service points — Approach B).
--
-- DESIGN (Approach A)
--   client_locations is a LIGHTWEIGHT identity table only. Visits, GDOs,
--   service frequency, price and billing stay shared at the client/property
--   level and are referenced (never copied). property_id is nullable and points
--   at the shared building property so the UI can group tenants.
--
-- 3NF (ADR 005): every column depends on the whole key (id) and nothing else.
--   property_id is a *reference* (FK), not a copy of any property column. NO
--   frequency / price / trap-size / visit columns (Rule 3 -> those live on
--   service_configs / gdos / visits at the client+property grain).
-- Source-agnostic (Rule 1 / ADR 002): zero airtable_* columns. AT codes map in
--   via entity_source_links (entity_type='client_location') in 2026-06-01b.
-- Idempotent (Rule 5): IF NOT EXISTS; triggers DROP-then-CREATE; policies dropped first.
-- Audit (Rule 8 / ADR 010): OPT-IN (name, status, contact_*, notes editable).
-- RLS (ship-first): anon-permissive FOR ALL; revoke in the later hardening pass.

BEGIN;

-- 1. Table -----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.client_locations (
  id             BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  client_id      BIGINT       NOT NULL REFERENCES public.clients(id) ON DELETE CASCADE,
  name           TEXT         NOT NULL,
  property_id    BIGINT       REFERENCES public.properties(id) ON DELETE SET NULL,
  status         TEXT         NOT NULL DEFAULT 'active'
                              CHECK (status IN ('active', 'closed')),
  contact_name   TEXT,
  contact_phone  TEXT,
  contact_email  TEXT,
  notes          TEXT,
  created_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.client_locations IS
  'Named tenant-locations within a single client (1 client -> N tenants). For multi-tenant clients like Wynd 28 (id=233) where several restaurants share ONE grease trap + ONE visit but need separate identity / per-tenant DERM. Lightweight identity only: visits, GDOs, frequency, price, billing stay shared on their own tables and are referenced, NEVER duplicated here. Created 2026-06-01, see migration 2026-06-01_client_locations.sql.';
COMMENT ON COLUMN public.client_locations.client_id IS
  'Owning client. FK -> clients(id) ON DELETE CASCADE. Wynd 28 tenants all carry client_id=233.';
COMMENT ON COLUMN public.client_locations.name IS
  'Tenant display name (e.g. "Pasta", "Nino Gordo"). The per-tenant identity ops + DERM needed.';
COMMENT ON COLUMN public.client_locations.property_id IS
  'Shared building property this tenant occupies. FK -> properties(id) ON DELETE SET NULL. A reference for UI grouping, NOT a copy of any property attribute. Nullable: a tenant may be recorded before its property row exists.';
COMMENT ON COLUMN public.client_locations.status IS
  'active | closed. Per-tenant lifecycle (Wynd 28 has 4 active + 2 historically closed). Independent of the parent client.status.';
COMMENT ON COLUMN public.client_locations.contact_name IS
  'Optional per-tenant contact name. Independent of the client-level contact.';
COMMENT ON COLUMN public.client_locations.updated_at IS
  'Auto-bumped to now() on UPDATE by set_updated_at_client_locations (Rule 7). Never set manually.';

-- 2. FK indexes (Postgres does NOT auto-index FK columns) ------------------
CREATE INDEX IF NOT EXISTS idx_client_locations_client_id
  ON public.client_locations (client_id);
CREATE INDEX IF NOT EXISTS idx_client_locations_property_id
  ON public.client_locations (property_id);

-- Prevent duplicate tenant names under one client; ON CONFLICT target for seed.
CREATE UNIQUE INDEX IF NOT EXISTS uq_client_locations_client_name
  ON public.client_locations (client_id, name);

-- 3. updated_at trigger (Rule 7) — canonical public.set_updated_at() -------
DROP TRIGGER IF EXISTS set_updated_at_client_locations ON public.client_locations;
CREATE TRIGGER set_updated_at_client_locations
  BEFORE UPDATE ON public.client_locations
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- 4. Audit trigger (Rule 8 — opt-in) --------------------------------------
DROP TRIGGER IF EXISTS audit_client_locations ON public.client_locations;
CREATE TRIGGER audit_client_locations
  AFTER INSERT OR UPDATE OR DELETE ON public.client_locations
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- 5. RLS — anon-permissive (ship-first; revoke in later hardening pass) ----
ALTER TABLE public.client_locations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS client_locations_anon_all ON public.client_locations;
CREATE POLICY client_locations_anon_all
  ON public.client_locations FOR ALL TO anon
  USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS client_locations_authenticated_all ON public.client_locations;
CREATE POLICY client_locations_authenticated_all
  ON public.client_locations FOR ALL TO authenticated
  USING (true) WITH CHECK (true);

-- 6. Grants ----------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON public.client_locations TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE         ON public.client_locations TO anon;
-- ^ anon write revoked in the future security-hardening pass once apps mature.

COMMIT;

-- POST-MIGRATION VERIFICATION ---------------------------------------------
-- 1. Columns:   SELECT column_name,data_type,is_nullable FROM information_schema.columns
--               WHERE table_schema='public' AND table_name='client_locations' ORDER BY ordinal_position;
-- 2. Audit on:  SELECT operation,count(*) FROM audit.logs
--               WHERE table_name='client_locations' GROUP BY operation;   -- expect 5 INSERT after seed
-- 3. RLS on:    SELECT relrowsecurity FROM pg_class WHERE relname='client_locations';  -- expect true
```

### 9b. `Supabase/docs/migrations/2026-06-01b_seed_wynd28_client_locations.sql` (Wynd 28 seed)

```sql
-- 2026-06-01b_seed_wynd28_client_locations.sql
--
-- Seed the 5 active Wynd 28 tenants into public.client_locations (client_id=233)
-- and map their Airtable codes 216-220-WYN into entity_source_links
-- (entity_type='client_location'). Fred 2026-06-01: model 5 as ACTIVE for now
-- (the 2 historically-closed tenants are NOT seeded; add later as status='closed').
--
-- DEPENDS ON: 2026-06-01_client_locations.sql (table must exist).
-- Idempotent (Rule 5): client_locations ON CONFLICT (client_id, name) DO NOTHING;
--   entity_source_links ON CONFLICT (entity_type, source_system, source_id) DO NOTHING.
-- property_id resolved by sub-select (NOT hardcoded) -> stays correct across envs.
-- Source-agnostic (Rule 1): AT codes live in entity_source_links, never on the table.
--
-- NOTE (source_id format): RESOLVED 2026-06-01 — existing entity_type='client' AT links
-- store the Airtable rec-id as source_id (e.g. rec03SARDaMyqHJZf, source_name='155-PV
-- Pura Vida Flamingo'). So source_id below = AT rec-id (re-verified live against base
-- appjMgjjZPeuudqQR), source_name = 'code name'. Matches house convention.

BEGIN;

-- 1. The 5 active tenants --------------------------------------------------
WITH bldg AS (
  SELECT id AS property_id
  FROM public.properties
  WHERE client_id = 233
  ORDER BY is_primary DESC NULLS LAST, id ASC
  LIMIT 1
)
INSERT INTO public.client_locations (client_id, name, property_id, status)
SELECT 233, t.name, bldg.property_id, 'active'
FROM (VALUES
  ('Pasta'),
  ('Presidente'),
  ('CU4'),
  ('Nino Gordo'),
  ('Pari Pari')
) AS t(name)
CROSS JOIN bldg
ON CONFLICT (client_id, name) DO NOTHING;

-- 2. Map Airtable codes 216-220-WYN -> the new client_location ids ---------
INSERT INTO public.entity_source_links
  (entity_type, entity_id, source_system, source_id, source_name,
   match_method, match_confidence, synced_at, created_at)
SELECT
  'client_location', cl.id, 'airtable', m.source_id, m.source_name,
  'manual', 1.00, now(), now()
FROM public.client_locations cl
JOIN (VALUES
  -- (name, AT rec-id -> source_id, 'code name' -> source_name); rec-ids verified vs base appjMgjjZPeuudqQR 2026-06-01
  ('Pasta',      'recQDk0XC002RZbHc', '216-WYN Pasta'),
  ('Presidente', 'reclOvCnNC9OzBv3j', '217-WYN Presidente'),
  ('CU4',        'recwVPjJV8qtbSRBL', '218-WYN CU4'),
  ('Nino Gordo', 'recOHiK46Vw0gx4ZI', '219-WYN Nino Gordo'),
  ('Pari Pari',  'recz4f4YH8wrc21Fk', '220-WYN Pari Pari')
) AS m(name, source_id, source_name) ON m.name = cl.name
WHERE cl.client_id = 233
ON CONFLICT (entity_type, source_system, source_id) DO NOTHING;

COMMIT;

-- POST-SEED VERIFICATION ---------------------------------------------------
-- 1. 5 rows, same building property:
--    SELECT cl.id,cl.name,cl.property_id,p.name AS property_name,cl.status
--    FROM public.client_locations cl LEFT JOIN public.properties p ON p.id=cl.property_id
--    WHERE cl.client_id=233 ORDER BY cl.name;            -- 5 rows, identical property_id, active
-- 2. 5 AT links 1:1:
--    SELECT esl.source_id,esl.source_name,cl.name
--    FROM public.entity_source_links esl JOIN public.client_locations cl ON cl.id=esl.entity_id
--    WHERE esl.entity_type='client_location' AND esl.source_system='airtable' ORDER BY esl.source_id;
-- 3. Reverse lookup:
--    SELECT entity_id FROM public.entity_source_links
--    WHERE entity_type='client_location' AND source_system='airtable' AND source_id='219-WYN';
```

### 9c. `Supabase/docs/migrations/2026-06-01_rollback_client_locations.sql` (rollback)

```sql
-- 2026-06-01_rollback_client_locations.sql
--
-- Reverses 2026-06-01_client_locations.sql + 2026-06-01b_seed_wynd28...sql.
-- Order matters: delete the entity_source_links rows FIRST (polymorphic bridge,
-- ADR 002 -> no FK to client_locations, so DROP TABLE would orphan them), then
-- DROP TABLE (CASCADE removes triggers/policies/indexes). public.set_updated_at()
-- and audit.log_change() are SHARED -> do NOT drop them.
--
-- Hard-delete (Rule 6): deleting the bridge rows is permitted (mechanical cleanup
-- tied to a table drop). No canonical business data lost — Wynd 28 tenant truth
-- still lives in Airtable (codes 216-220-WYN).

BEGIN;
DELETE FROM public.entity_source_links WHERE entity_type = 'client_location';
DROP TABLE IF EXISTS public.client_locations CASCADE;
COMMIT;

-- Post-rollback:
--   SELECT to_regclass('public.client_locations');                              -- NULL
--   SELECT count(*) FROM public.entity_source_links WHERE entity_type='client_location';  -- 0
-- (audit.logs rows from the seed INSERTs are retained per ADR 010 — append-only.)
```

---

## 10. Generalization — find other multi-tenant clients later

Read-only probe to write to `Supabase/scripts/probes/find_multi_tenant_clients.sql`. Four independent
heuristics; the Wynd 28 cluster should surface in H1/H2/H4 (doubles as validation). **Triage each
candidate by hand — do not auto-migrate.**

```sql
-- find_multi_tenant_clients.sql  (READ-ONLY probe — surfaces migration candidates)

-- H1. Same normalized street address, multiple DISTINCT clients (strongest signal).
WITH norm AS (
  SELECT p.client_id, c.name AS client_name, c.client_code, c.status,
         p.city, p.zip,
         regexp_replace(lower(regexp_replace(coalesce(p.address,''),
           '\m(ste|suite|unit|apt|#|no\.?)\M.*$','','i')),'\s+',' ','g') AS addr_key
  FROM public.properties p JOIN public.clients c ON c.id=p.client_id
  WHERE p.address IS NOT NULL
)
SELECT addr_key, city, zip,
       count(DISTINCT client_id) AS distinct_clients,
       array_agg(DISTINCT client_code ORDER BY client_code) FILTER (WHERE client_code IS NOT NULL) AS codes,
       array_agg(DISTINCT client_name ORDER BY client_name) AS names
FROM norm GROUP BY addr_key, city, zip
HAVING count(DISTINCT client_id) > 1
ORDER BY distinct_clients DESC, addr_key;

-- H2. Airtable client-code suffix clusters (e.g. -WYN, -TCE). Reads codes from
--     entity_source_links so AT-only codes (not yet on clients.client_code) are caught.
WITH at_codes AS (
  SELECT esl.entity_id AS client_id, esl.source_id AS at_code, esl.source_name,
         upper(regexp_replace(esl.source_id,'^.*-','')) AS code_suffix
  FROM public.entity_source_links esl
  WHERE esl.entity_type IN ('client','client_location')
    AND esl.source_system='airtable' AND esl.source_id ~ '-[A-Za-z]{2,4}$'
)
SELECT code_suffix, count(*) AS member_codes, count(DISTINCT client_id) AS distinct_clients,
       array_agg(at_code ORDER BY at_code) AS codes
FROM at_codes GROUP BY code_suffix HAVING count(*) > 1
ORDER BY member_codes DESC, code_suffix;

-- H3. Name patterns — one base name with tenant/unit qualifiers (lower precision; review queue).
WITH base AS (
  SELECT c.id, c.name, c.client_code, c.status,
         trim(regexp_replace(c.name,'\s*[-–/(].*$','')) AS base_name
  FROM public.clients c WHERE c.status IN ('ACTIVE','RECURRING')
)
SELECT lower(base_name) AS base_name_key, count(*) AS distinct_clients,
       array_agg(name ORDER BY name) AS names,
       array_agg(client_code ORDER BY client_code) FILTER (WHERE client_code IS NOT NULL) AS codes
FROM base WHERE length(base_name) >= 4
GROUP BY lower(base_name) HAVING count(*) > 1
ORDER BY distinct_clients DESC, base_name_key;

-- H4 (cross-check). Two client records already pointing at the EXACT same properties.id
--     = near-certain multi-tenant OR a dup-client to merge (compare vs 2026-05-25w before deciding).
SELECT p.id AS property_id, p.address,
       count(DISTINCT p.client_id) AS distinct_clients,
       array_agg(DISTINCT p.client_id) AS client_ids
FROM public.properties p
GROUP BY p.id, p.address HAVING count(DISTINCT p.client_id) > 1
ORDER BY distinct_clients DESC;
```

**Triage rule (per candidate, before migrating):**
- Shares **one trap + one visit on one date** → `client_locations` (this pattern). E.g. Wynd 28.
- One restaurant, **multiple service points / manhole groups / separate visits** → leave as multiple
  `properties` + `gdos` under one client (Casa Neos `009-CN` — do **NOT** put in `client_locations`).
- Genuinely **duplicate** client records of one business → that's a **merge**, not a tenant split →
  route to `Supabase/docs/migrations/2026-05-25w_merge_duplicate_clients.sql`.

---

## 11. Open questions & decisions needed from Fred

1. **(CRUX — blocks DERM wiring & app work) Do the 5 Wynd tenants each hold a distinct Miami-Dade
   `GDO-#####`, or do they share ONE GDO on the shared trap?** This single fact decides "5 GDO rows + 5
   DERM filings" (Casa Neos pattern) vs "1 GDO + 5 facility lines on one filing." Wynd has **0 GDOs** in
   our DB, so it cannot be answered from data — Diego / AT / the DERM portal must confirm.
2. ~~**(Verify before applying the seed) `source_id` format**~~ **— RESOLVED 2026-06-01: `source_id` = AT
   rec-id.** Existing `entity_type='client'` AT links store the Airtable record id (`rec03SARDaMyqHJZf`,
   `source_name='155-PV Pura Vida Flamingo'`). §9b now uses rec-ids (the 5 WYN ids re-verified live against
   base `appjMgjjZPeuudqQR`). **No open action.**
3. **Did Diego's "each restaurant gets its own DERM report" mean 5 physically separate
   `white_manifest_number`s, or 5 facility lines on ONE manifest the city receives?** The DERM Address
   PDF is inherently multi-facility, so "each restaurant appears on the filing" may already be satisfied
   by one manifest. Confirm what the city actually requires for a *shared* trap.
4. **If shared-GDO:** confirm we still create 5 `client_locations` for naming/identity (yes, per "separate
   name/identity only") but attribute DERM at the **building** level (one GDO, one manifest, tenants as
   facility lines).
5. **Backfill trigger:** Casa Neos's 15 manifests are all `gdo_id = NULL` today — per-facility DERM
   attribution has **never** been populated for anyone. Is wiring Wynd the moment to also backfill Casa
   Neos's `gdo_id`s, or does per-facility attribution stay deferred ops work (DERM Tracker Phase 3)?
6. **`derm_manifests.client_id` is slated to be dropped** once `gdo_id` is fully populated (migration 20g
   3NF note). If Wynd manifests must attach to a tenant that may **not** have its own GDO, dropping
   `client_id` removes the only client pointer for non-GDO rows. Confirm `client_id` **stays** until
   `gdo_id`/`client_location_id` coverage is complete.
7. **Closed tenants:** seed only the 5 active now (Fred said so), or also insert the 2 historically-closed
   tenants as `status='closed'` for history? (Trivial to add later.)

---

## 12. Execution workflow

Ordered. Each step notes its blocker. Steps **E1–E4 are unblocked** (pure identity, safe to ship now);
the DERM/app track (**D1–D5**) is **blocked on Q1**.

| # | Step | Owner | Blocked on |
|---|---|---|---|
| **E1** | ✅ **DONE 2026-06-01** — `source_id` format = AT rec-id (verified); §9b locked to the 5 rec-ids, re-verified live vs base `appjMgjjZPeuudqQR`. | DB | — |
| **E2** | Add `client_locations:{INSERT,UPDATE,DELETE}` to `ANON_ALLOWED` in `Supabase/scripts/alerts/audit_critical_poll.js`. | DB | — (must precede E4 or first write alarms) |
| **E3** | Apply **9a** DDL to Prod (`wbasvhvvismukaqdnouk`). Run the 3 post-migration checks. | DB | E1 (format decided) |
| **E4** | Apply **9b** seed. Run the 3 post-seed checks (5 rows, 5 links, reverse lookup). | DB | E3 |
| **E5** | Write the **9c** rollback + **§10** probe files to the repo (don't run rollback). Update `Supabase/docs/schema.md` to list `client_locations`. Commit + push. | DB | E4 |
| **— DECISION GATE —** | **Fred/Diego answer Q1** (per-tenant DERM real? distinct GDOs?). Everything below waits. | Fred | external (DERM portal/Diego) |
| **D1** | *If once-per-trap:* **STOP.** `client_locations` is identity-only; apps unaffected. Optionally add cosmetic `location_name` to display views. Done. | — | Q1 = "shared" |
| **D2** | *If per-tenant:* ingest the 5 Wynd GDOs into `gdos` (currently 0) — same gap blocking Casa Neos. | DB | Q1 = "per-tenant" |
| **D3** | Follow-up migration: `ALTER TABLE public.gdos ADD COLUMN client_location_id BIGINT NULL REFERENCES public.client_locations(id)` (non-breaking). Seed each Wynd GDO's `client_location_id`. **No `derm_manifests` column.** | DB | D2 |
| **D4** | Add `location_name` to `derm.visits` / `derm.manifests` / `derm.manifest_visits` / `public.manifest_pickable_visits` (via `gdos.client_location_id` join). Decide row grain (1 shared visit vs N tenant rows). | DB | D3 |
| **D5** | DERM Tracker app: show/select 5 tenant-locations; attribute manifest to a tenant; search by tenant name. Model one visit → one manifest → N facility lines (PDF already multi-`FacilityRow`). | Building Apps (Lovable) | D4 |
| **D6** | (Optional, Q5) Backfill Casa Neos `gdo_id`s on its 15 manifests if Fred wants per-facility attribution turned on org-wide. | DB / ops | Q5 |

**Resumption note for a future session:** check whether `to_regclass('public.client_locations')` is
non-NULL (E3 done?) and whether 5 rows exist for client 233 (E4 done?). If both true and Q1 is still
unanswered, the work is correctly **parked at the decision gate** — do not start D-track until Fred
answers Q1. `ops.v_service_due` / `v_derm_compliance` / billing views must remain client-grain at every
step.

---

### Reference files (all absolute)
- House-style templates: `C:\Users\FRED\Desktop\Virtrify\Yannick\Claude\Supabase\docs\migrations\2026-05-27_zones_reference_table.sql`, `...\2026-05-14d_photo_classifications.sql`
- ADRs: `...\Supabase\docs\decisions\002-entity-source-links.md`, `...\005-3nf-standing-check.md`, `...\010-audit-trail.md`
- GDO precedent (names 216-220 WYN + Casa Neos): `...\Supabase\docs\migrations\2026-05-20g_gdos_table_and_backfill.sql`
- Merge-vs-split playbook (triage): `...\Supabase\docs\migrations\2026-05-25w_merge_duplicate_clients.sql`
- AT-only proof for all 5 WYN: `...\Supabase\docs\reports\jobber_at_diff.json`
- Webhook drop-gate / only-client-INSERT: `...\Supabase\supabase\functions\webhook-airtable\index.ts` (lines 197-200), `...\webhook-jobber\index.ts` (lines 320-323)
- Bridge helper (type-agnostic): `...\Supabase\supabase\functions\_shared\entity-links.ts`
- Multi-facility DERM PDF: `C:\Users\FRED\Desktop\Virtrify\Yannick\Claude\Building Apps\unclogme-pdf-service\pdf_service\app.py` (`_manifest_row_to_input`)
- Audit-alert allow-list to update (E2): `...\Supabase\scripts\alerts\audit_critical_poll.js` (`ANON_ALLOWED`)

### New files this design produces (suggested paths)
- `Supabase\docs\migrations\2026-06-01_client_locations.sql` (9a)
- `Supabase\docs\migrations\2026-06-01b_seed_wynd28_client_locations.sql` (9b)
- `Supabase\docs\migrations\2026-06-01_rollback_client_locations.sql` (9c)
- `Supabase\scripts\probes\find_multi_tenant_clients.sql` (§10)
