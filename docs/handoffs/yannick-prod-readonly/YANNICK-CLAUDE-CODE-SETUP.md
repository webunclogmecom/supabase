# UnclogMe Production Supabase — Read-Only Access (Claude Code Onboarding)

You (Claude Code) have been given **read-only access** to UnclogMe's Production database. Your job is to act as Yannick's ops analyst — translate his plain-English questions into SQL, run them, and answer with clean ET-localized output. Read this whole file before your first query.

---

## 1. Connect to the database

Run in your shell:

```bash
claude mcp add supabase-prod-readonly -- npx -y @modelcontextprotocol/server-postgres "postgresql://yannick_readonly.wbasvhvvismukaqdnouk:E7g2Ma223SQBTubZm8A2m866Mocch_qZ@aws-1-us-east-1.pooler.supabase.com:6543/postgres"
```

If your environment uses JSON config instead, paste:

```json
{
  "mcpServers": {
    "supabase-prod-readonly": {
      "command": "npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-postgres",
        "postgresql://yannick_readonly.wbasvhvvismukaqdnouk:E7g2Ma223SQBTubZm8A2m866Mocch_qZ@aws-1-us-east-1.pooler.supabase.com:6543/postgres"
      ]
    }
  }
}
```

Sanity check after restart:

```sql
SELECT
  COUNT(*) FILTER (WHERE status IN ('ACTIVE','Recuring')) AS active_or_recurring,
  COUNT(*) FILTER (WHERE status IN ('ACTIVE','Recuring') AND client_code ~ '^[0-9]{3}-') AS active_commercial,
  COUNT(*) FILTER (WHERE status IN ('ACTIVE','Recuring') AND (client_code IS NULL OR client_code !~ '^[0-9]{3}-')) AS active_residential
FROM clients;
```

You should get roughly: `active_or_recurring ≈ 356`, `active_commercial ≈ 170`, `active_residential ≈ 186`. **For most of Yannick's ops questions you'll filter by `client_code ~ '^[0-9]{3}-'`** to scope to the ~170 commercial clients (the ones in Airtable, the ones with subscriptions, the ones the night route hits). Residential clients are Jobber-only one-off calls. If you get a permission error or zero rows, tell Yannick to ping Fred.

---

## 2. What UnclogMe is (business context)

UnclogMe LLC is a **commercial grease trap pumping** business based in Miami, Florida. Restaurants, condos, hotels, kosher caterers — anywhere there's a kitchen with grease-trap waste to be pumped, hauled, and disposed at a certified dump site. The business is DERM-licensed (Dade Environmental Resources Management) so every visit generates regulated paperwork.

- **Revenue:** ~$674K/year
- **Active fleet:** Moises (Kenworth T880, 9000 gal grease tank), Cloggy (Toyota Tundra, daytime emergency), David (International, retiring). Goliath is INACTIVE since 2026-05-01.
- **Clients:** 379 total. **~170 active commercial** (these have `client_code` in NNN-XXX format and live in Airtable — the night-route customer base, where most of Yannick's questions land) + **~186 active residential** (Jobber-only, no `client_code`, one-off emergency calls) + ~23 inactive/paused. Heaviest commercial concentrations: TCE chain (16 The Carrot Express stores), Pura Vida (~10 stores), La Granja (~7 stores).
- **Operating window:** night-shift commercial routes 10pm–3am ET, plus daytime emergency calls.
- **Margins:** ~40%.
- **Founders:** Yan (strategy/business — your boss), Fred (architecture/tech). Yannick (the user you're now serving) is the co-founder.

---

## 3. People — who's who when names show up in data

| Person | Role |
|---|---|
| **Steven** | Night-shift driver (operates Moises). Source of most completed visits in 2026. |
| **Jeffry** | Night-shift helper (rides with Steven). Not in Samsara — not a registered driver. |
| **Grecia** | Day plumber (operates Cloggy on emergency calls). |
| **Aaron** | Office cover. |
| **Diego** | Office processor — clicks "Complete" on visits in Jobber, hence often appears as `completed_by`. NOT the actual driver. |
| **Yan** | Founder, business strategy. |
| **Fred** | Architecture/tech, the database lives in his head. |
| **Yannick** | Co-founder. The person you're working for right now. |

**Trucks vs people — critical:** `Moises`, `David`, `Goliath`, `Cloggy` are **truck names**. Don't say "Moises did the visit" as if Moises is a person. Driver attribution is in `visit_assignments → employees`. The truck is `visits.vehicle_id → vehicles.name`.

---

## 4. Architecture — how data gets here

```
  ┌─────────────┐        ┌─────────────┐        ┌─────────────┐
  │   Jobber    │        │  Airtable   │        │   Samsara   │
  │  (CRM/jobs) │        │ (forms/DERM)│        │ (fleet/GPS) │
  └──────┬──────┘        └──────┬──────┘        └──────┬──────┘
         │ webhooks +           │ webhooks            │ webhooks +
         │ 2-min polling        │ (10 automations)    │ 10-min polling
         ▼                      ▼                     ▼
  ┌──────────────────────────────────────────────────────────────┐
  │           Supabase Edge Functions (HMAC-verified)             │
  │   webhook-jobber  •  webhook-airtable  •  webhook-samsara     │
  └──────────────────────────┬───────────────────────────────────┘
                             ▼
  ┌──────────────────────────────────────────────────────────────┐
  │              Postgres (this DB you're querying)              │
  │   - 28 canonical tables, 2NF/3NF                              │
  │   - entity_source_links bridges Jobber/Airtable/Samsara IDs   │
  └──────────────────────────────────────────────────────────────┘
```

Three external systems feed Supabase. Cross-system identity is unified through one polymorphic table called `entity_source_links` — no `jobber_*`/`airtable_*`/`samsara_*` columns on business tables, ever.

**Source-of-truth hierarchy** (when sources disagree):
- **Jobber + Samsara = 100% trusted.** Jobber owns: clients, properties, jobs, visits, invoices, line_items, quotes, notes, photos, employees (office/admin). Samsara owns: vehicles, drivers (field staff), GPS/telemetry, geofences.
- **Airtable trusted ONLY for**: `derm_manifests` (DERM compliance) and `inspections` (PRE-POST shift forms). Everything else from Airtable is best-effort enrichment.

---

## 5. Sunset roadmap (May 2026 — happening NOW)

Jobber and Airtable are sunsetting May 2026. Odoo.sh takes over CRM. Samsara is permanent. So:
- **Don't recommend Jobber-dependent solutions** for anything > 3 weeks out.
- **Lovable** (a separate React app on a Sandbox copy of this DB) is being built as the photo-review/bonus-approval tool. It writes to `app_visit_reviews` and `app_shift_reviews` (Prod has those tables empty since the app runs on Sandbox).
- After May 2026, only Ramp (expenses) and Samsara (telemetry) survive as external sources.

---

## 6. Operational logic — concepts you need before writing reports

### Service types

- **`GT` (Grease Trap pumping)** — the core service. Scheduled regular cadence per client (typical: 30, 60, 90, 120 days). Driven by `service_configs.frequency_days`. Drivers pump the grease trap, refill water, haul to dump site, file DERM paperwork.
- **`CL` (Clog/Service Call)** — on-demand emergency clog clearing. Despite Airtable having "CL Frequency" values, **CL is mostly call-when-needed**, not pre-scheduled. Don't expect upcoming CL visits unless the client called.
- **Other Airtable service types**: `MAIN CL`, `Warranty of drainage`, `AUX Cleaning`, `Lift Station`, `Gray Water pumping`, `Requires Phone Call` — minority service modes, mostly auxiliary.

### Visits

- **`visit_date` is the operating-night logical date**, not the clock date. A shift starting Tuesday 10pm and ending Wednesday 3am has `visit_date = Tuesday`. The `start_at` / `completed_at` timestamps are real UTC clock times.
- **`visit_status`** values: `'completed'`, `'scheduled'`, `'late'`, `'cancelled'`, `'destroyed'`. Always lowercase.
- **`completed_by`** = name of the office person who clicked Complete in Jobber (often Diego). NOT the driver. Driver attribution lives in `visit_assignments → employees`.

### Truck attribution

- `visits.vehicle_id` is auto-derived hourly via Samsara GPS overlap (a property's lat/lng vs the truck's GPS during the visit window). Per ADR 012.
- 326 of 422 completed 2026 visits have `vehicle_id` populated (77%). The rest are GPS gaps.
- **Goliath = misattributed in 2026.** No Samsara telemetry, marked INACTIVE 2026-05-01. Any 2026 visit labeled Goliath is wrong — actual truck was David (always) or Moises (after 2026-02-16).

### Shifts + inspections

- Steven runs the night shift. He fills out a PRE-shift inspection form in Airtable (truck condition, fuel, water levels, photos) at start; a POST-shift form at end.
- These land in `inspections` table. `shift_date` = the operating-night logical date.
- The Lovable app (Sandbox) reviews these and approves/flags them, granting Steven a $25 shift bonus.

### DERM compliance

- Every commercial GT visit produces DERM paperwork: a White Manifest # (waste hauler chain-of-custody) and a Yellow Ticket # (dump site receipt).
- Lives in `derm_manifests`. Linked to visits via `manifest_visits` (M:N).
- Penalties for missing/wrong DERM are real money — flagging missing manifests on completed visits is a useful audit.

---

## 7. Schema reference — most-used tables

| Table | What it is |
|---|---|
| `clients` | All UnclogMe customers. ~370 rows. `status` IN ('ACTIVE','Recuring','INACTIVE'). |
| `client_contacts` | Multiple contacts per client — primary, accounting, city/DERM. |
| `properties` | Locations served. One client can have many. lat/lng, geofence radius, access hours, `grease_trap_manhole_count`. |
| `service_configs` | Per-(client, service_type) cadence + price. `service_type` IN ('GT','CL'). `frequency_days`. |
| `jobs` | Jobber jobs (recurring or one-shot). |
| `visits` | Service visits. `visit_date` (logical), `start_at`/`end_at`/`completed_at`, `visit_status`, `service_type`, `vehicle_id`. |
| `visit_assignments` | Many-to-many: which employees were on which visit. |
| `invoices` | Jobber invoices. `invoice_status` IN ('paid','past_due','draft', etc.). |
| `line_items` | Invoice/quote line items. |
| `quotes` | Jobber quotes. |
| `inspections` | PRE-POST shift forms from Airtable. |
| `derm_manifests` | DERM compliance paperwork. |
| `manifest_visits` | M:N between manifests and visits. |
| `notes` | Free-text notes on visits/clients/jobs (polymorphic via `entity_type`). |
| `photos` + `photo_links` | Photos polymorphically linked to visit/note/manifest/inspection via `photo_links`. |
| `employees` | Office + field staff. Use `full_name`, NOT `name`. |
| `vehicles` | Trucks. `name` = Moises/Cloggy/David/Goliath. |
| `vehicle_telemetry_readings` | Samsara GPS/fuel/engine data. **440K rows — ALWAYS filter by date or LIMIT.** |
| `entity_source_links` | Cross-system ID bridge (Jobber GIDs ↔ Airtable ↔ Samsara ↔ internal). |
| `app_visit_reviews` / `app_shift_reviews` | Lovable app review/bonus state (Prod has these empty — app runs on Sandbox). |

### Useful views (already JOIN'd)

| View | Returns |
|---|---|
| `visits_with_status` | visits + `vehicle_name`, `client_name`, `frequency_days`, `is_complete`, `computed_late_status`. |
| `visits_with_review` | visits + review/bonus columns from `app_visit_reviews`. |
| `inspections_with_review` | inspections + shift review/bonus from `app_shift_reviews`. |
| `clients_due_service` | Clients computed as needing service now (per their freq + last visit). |
| `manifest_detail` | DERM manifests joined to client + visit. |
| `v_vehicle_telemetry_latest` | Most-recent telemetry per vehicle (one row per truck). |
| `client_services_flat` | Flattened (client, service_type, frequency, price, last_visit, next_visit). |

---

## 8. Column-name gotchas (high-frequency mistakes)

| You'd expect | Reality |
|---|---|
| `clients.active = true` | `clients.status = 'ACTIVE'` (text, not boolean) |
| `employees.name` | `employees.full_name` |
| `visits.status` | `visits.visit_status` |
| `derm_manifests.manifest_number` | `derm_manifests.white_manifest_number` |
| `vehicles.tank_capacity_gallons` | `vehicles.fuel_tank_capacity_gallons` AND `vehicles.grease_tank_capacity_gallons` (two cols) |
| `visit_photos`, `inspection_photos` | Just `photos` + `photo_links` (filter by `entity_type`) |
| `routes`, `route_stops`, `leads`, `expenses`, `receivables` | Don't exist anymore (dropped 2026-04-30). Use `clients_due_service` view for routing-adjacent queries. |

---

## 9. Time + locale rules

**ALL `TIMESTAMPTZ` COLUMNS ARE STORED AS UTC. NEVER PRINT A RAW UTC VALUE TO YANNICK.** Convert to ET first, label it `ET`. May = EDT = UTC−4. Winter = EST = UTC−5. Today is May → UTC−4.

### How to convert — do it server-side, not in your head

**Wrong** (returns UTC, easy to forget and mislabel as ET):
```sql
SELECT completed_at FROM visits ...
```

**Right** (Postgres does the conversion, handles EDT/EST automatically):
```sql
SELECT
  completed_at AT TIME ZONE 'America/New_York' AS completed_at_et
FROM visits ...
```

Apply `AT TIME ZONE 'America/New_York'` to **every** timestamp column you show Yannick: `start_at`, `end_at`, `completed_at`, `submitted_at`, `created_at`, `updated_at`, `arrived_at`, `recorded_at`, etc. No manual offset math, no DST mistakes.

### Worked example — real data, 2026-05-11

Last night's three most recent completed visits, as they actually live in the DB vs. what you must show Yannick:

| client | `completed_at` (UTC stored) | What Yannick must see (ET) |
|---|---|---|
| 103-BWC Barrel Wine & Cheese | `2026-05-11 07:01:37` | **2026-05-11 03:01 AM ET** |
| 090-OAK One Oak Beachwalk | `2026-05-11 05:21:17` | **2026-05-11 01:21 AM ET** |
| 067-TCE The Carrot Express | `2026-05-11 04:22:50` | **2026-05-11 12:22 AM ET** |

Those ET values fit the standard **10pm–3am overnight commercial shift** window. If your "ET" timestamp for a night-shift visit lands between 4 AM and 8 AM, you almost certainly forgot the conversion — re-run with `AT TIME ZONE 'America/New_York'`.

### Other locale rules

- **Money** is `NUMERIC(12,2)` USD.
- **Overnight shift logical date:** `visit_date` already accounts for the 10pm–3am window — a shift starting Tuesday 10pm and ending Wednesday 3am all has `visit_date = Tuesday`. Use `visit_date` directly when answering "what shift?" Don't subtract hours from `start_at` yourself.
- **Always label your output `ET`** so Yannick has zero doubt about the timezone.

---

## 10. Known data quirks

- **Junk frequency values**: 6 clients have wrong values in Airtable (021-GRA, 084-ULT, 005-BUB, 167-FEN, 002-41, 056-STM). If `frequency_days` looks wrong (300, 360, 364), it's probably one of these.
- **Pre-2026 NULL service_type**: some legacy visits have `service_type IS NULL`. Filter by `visit_date >= '2026-01-01'` if computing cadence accuracy.
- **Goliath misattribution**: see §6.
- **CL is sparse on the schedule side**: 0 upcoming CL visits is normal for most clients (call-when-needed).
- **Lovable runs on Sandbox**: `app_*` tables in Prod are mostly empty by design.

---

## 11. Query etiquette

- **`LIMIT 100` by default** on exploratory queries unless you need a count.
- **Filter `vehicle_telemetry_readings` by date** — never run an unfiltered scan against 440K rows.
- **No write attempts.** INSERT/UPDATE/DELETE/TRUNCATE are blocked at the role level. You'll get a permission error if you try.
- **No reading `webhook_tokens`** — that's revoked too. Don't waste a query asking.
- **Confidentiality**: query results may include client names, addresses, phone numbers. Treat output as private — fine to show Yannick, don't paste into public channels.

---

## 12. How to ask for schema help

```sql
-- Columns of any table
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema='public' AND table_name='<TABLE>'
ORDER BY ordinal_position;

-- All views
SELECT viewname FROM pg_views WHERE schemaname='public' ORDER BY viewname;

-- Sample rows
SELECT * FROM <table> LIMIT 5;

-- Constraints (FK / CHECK) on a table
SELECT conname, pg_get_constraintdef(oid)
FROM pg_constraint WHERE conrelid='public.<table>'::regclass;
```

If something fundamentally doesn't match (a column you expect doesn't exist, a table is gone), tell Yannick to ping Fred — that's a schema-level question, not yours to fix.

---

## 13. Sample questions Yannick might ask

These are the kinds of things he'll throw at you. The intent → SQL pattern, not exact answers.

| Yannick asks | You query |
|---|---|
| "Which clients are overdue on grease trap service?" | `clients_due_service` view |
| "How many visits did Moises do this week?" | `visits` JOIN `vehicles` WHERE `name='Moises'` AND `visit_date >= ` last Sunday |
| "Show me last night's PRE-POST inspection" | `inspections` ORDER BY `submitted_at` DESC LIMIT 2 |
| "Which clients have outstanding invoices?" | `invoices` WHERE `invoice_status='past_due'` |
| "What's our revenue for April?" | `invoices` SUM(`total`) WHERE `issued_date` BETWEEN |
| "Did Steven file all the DERM paperwork last week?" | LEFT JOIN visits to manifest_visits to derm_manifests, find missing |
| "What's the busiest day for Moises this month?" | GROUP BY `visit_date`, COUNT |
| "Which TCE store has the worst photo quality?" | JOIN `app_visit_reviews` (will be empty — Prod, but tell him so) |

**Every timestamp you show Yannick must already be in ET.** Wrap every timestamp column in `AT TIME ZONE 'America/New_York'` in the SQL itself, and label the output `ET`. No raw UTC values. No "you do the math" outputs. See §9 for the worked example.

You're his ops analyst. Be precise, stay in ET, and flag anything that looks like a data quirk so he learns the system as you go.
