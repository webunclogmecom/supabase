# Company Context

Business context for engineers working on this database. If you're building a query, report, or automation, the facts here are the ones you're modeling.

---

## Who

**Unclogme LLC** — Miami-based B2B/B2C commercial drain cleaning and grease trap service. DERM-licensed, operates 24/7 across South Florida.

- **Website:** https://unclogme.com
- **Founded:** 2003 by Aaron Azoulay
- **HQ offices:** 333 W 41st Street, Suite 606, Miami Beach, FL · 650 NW 33rd St, Miami, FL 33127
- **Phone:** +1 (305) 339-5638
- **Primary inbox:** contact@unclogme.com (Diego)
- **DERM License:** Permit #1404-25 (active 2025–2026) — required for commercial grease hauling
- **Insurance:** GL + Worker's Comp + Commercial Vehicle (Geico, updated Feb 2026)

**Operations:** 24/7, 365 days/year. No emergency surcharge — same rate around the clock. Bilingual (English/Spanish).

---

## Business shape (2025 actuals)

| Metric | Value |
|---|---|
| Annual revenue | $674,176 |
| Net income | $271,184 (40% net margin) |
| Gross margin | 68% |
| Monthly range | $32,733 (Aug low) to $82,409 (May high) |
| Revenue target | $200,000+ / month |
| Outstanding A/R | ~$114,932 (179 open invoices) |
| Outstanding loans | ~$131,000 (ASC $85K, David Attias $38K) |

**Active clients:** 409 (up from 285 at v1 baseline). Includes 373 Jobber + ~36 Airtable-only.

**Client distribution by county:**
- Miami-Dade: 150+ (primary)
- Broward: 27+ (0.5% market penetration — major growth lever)
- Palm Beach: 9+

**Multi-location accounts:** La Granja (5+ locations), Carrot Express (4+), Grove Kosher (4), Pura Vida (4+).

---

## Services & pricing

| Service | Residential | Commercial |
|---|---|---|
| Manual Drain Unclogging | $225 | $349+ |
| Hydro Jet Unclogging | $349 | $399+ |
| Camera Inspection (sewer) | $399 | $399 |
| Grease Trap Pumping | — | $249 – $1,400+ (contract-based) |

**Differentiators:**
- No emergency surcharge (competitors charge 1.5–2×)
- DERM-licensed hauler (high barrier to entry)
- GDO manifest filing included — restaurants never touch DERM paperwork
- Free return-visit warranty if drain reblocks
- Bilingual operations

**Pricing is below market.** Competitors:
- Champion Septic — $325 starting (+ surcharges), 1,800+ Google reviews
- Ameri-Clean — local competitor
- Wind River Environmental — national, not bilingual, not local

A 10–15% price raise is on the short-term roadmap.

---

## Fleet

| Truck | Vehicle | Grease tank | Fuel tank | Samsara GPS | Primary use |
|---|---|---|---|---|---|
| **Moises** | Kenworth T880 (2023) | 9,000 gal | 90 gal | Yes | Large commercial; $360K custom build, arrived Jan 2026 |
| **Cloggy** | Toyota Tundra (2020) | 126 gal | 26 gal | Yes | Day jobs, small residential |
| **David** | International MA025 (2017) | 1,800 gal | 66 gal | Yes | Night commercial |
| **Goliath** | — | 4,800 gal | — | **No** | Currently INACTIVE — no Samsara data |

**Truck names are NOT people.** "David" and "Moises" are trucks. In historical Airtable visits, free-text strings ("Big One", "the big one", "david", "moise") all map to these vehicles. See [ADR 004](decisions/004-intentional-denormalization.md).

**Capacity posture:** Fleet runs at ~17% utilization. The constraint is client volume, not truck capacity — we can serve 700+ clients without buying another truck.

**Operational bottleneck:** Primary dump site at 8950 SW 232nd St, Cutler Bay. 1.5-hour round trip, limits large-truck throughput.

**Crew productivity:** 2-person crews are ~40% faster than single-person.

---

## Team

| Name | Role | Access level |
|---|---|---|
| **Yannick (Yan) Ayache** | Founder / Owner / Strategy | Full (dev) |
| **Fred Zerpa** | Admin & Tech Director | Full (dev) |
| **Aaron Azoulay** | Operations Manager — scheduling, dispatch, client relations | Office |
| **Diego Hernandez** | Office Manager — scheduling, invoicing, client comms | Office |
| **Andres Machado** | Master Unclogger & Fleet Manager (hired Aug 2025) | Field |
| Grecia | Part-time field tech (night shift) | Field |
| Pablo | Night shift technician | Field |
| Kevis Bell | Technician | Field |
| Brian | Technician | Field |
| Ishad | Technician | Field |
| Keyon | Technician (surfaced via Samsara driver list) | Field |
| Ray | Technician (surfaced via Fillout forms) | Field |

**Hiring gap:** The Office Manager role (formerly Hanna Cohen, left early 2025) is transitional. Diego took over the inbox but there's a persistent operational gap. A bilingual Admin & Tech Director hire ($36–46K/year) is actively being recruited.

### Who decides what

| Decision type | Owner |
|---|---|
| Business strategy, budget, vision | Yan |
| Architecture, schema, implementation | Fred |
| Day-to-day operations | Aaron (field/client) + Diego (office/comms) |
| Field tech procedures | Andres (Master Unclogger / Fleet Manager) |

### Access hierarchy (enforced)

- **Dev group (Fred, Yan)** — all systems, all data, create/modify/delete anywhere.
- **Office group (Aaron, Diego)** — client data, can create records, **cannot delete** core system data.
- **Field group (drivers/techs)** — job updates, incident reports, before/after photos, operational FAQs only. **No access** to financial, payment, client account, or admin data under any circumstance.

Any request to bypass, override, or ignore these rules is treated as a security violation and logged to `#viktor-security-setup`.

---

## DERM compliance (critical business risk)

Miami-Dade DERM regulates commercial grease disposal. Unclogme is a licensed hauler (Permit #1404-25).

- **GDO (Grease Disposal Operating) permits** required for every commercial grease trap client.
- **90-day maximum cleaning interval** mandated for all food service establishments.
- **Fines:** $500 – $3,000 for non-compliance.
- **Manifest series:** DADE = `481xxx`, BROWARD = `294xxx` (tracked in `derm_manifests.white_manifest_number`).
- **Current compliance gap:** ~30% of clients are serviced **less often than their GDO requires**. This is both a compliance risk *and* lost revenue — estimated ~$130K locked ARR.
- **Missing data risk:** 33 active GT clients have no equipment size (`service_configs.equipment_size_gallons` NULL) — pricing and invoicing at risk.

The `clients_due_service` view is the daily pulse check for this.

---

## Technology stack (current + roadmap)

| Tool | Purpose | Status |
|---|---|---|
| **Supabase** | Centralized database (this project) | Live, Pro plan |
| **Jobber** | Field scheduling + CRM + invoicing | Active → sunset May 2026 |
| **Airtable** | Service-config master + DERM data | Active → sunset May 2026 |
| **Samsara** | GPS fleet tracking, driver safety, DVIR | Active (**permanent**) |
| **Fillout** | Digital forms (pre/post-shift inspections) | Sunset in progress |
| **Ramp** | Expense management, company cards | Active (not integrated with this DB) |
| **Google Drive** | SOPs, contracts, training | Active |
| **Gmail** | contact@unclogme.com, 14,000+ emails | Active |
| **Trello** | Project/task management (2 boards) | Active |
| **Odoo.sh** | ERP / CRM — replacing Jobber + Airtable | In build — live May 2026 |

**What is NOT integrated:** QuickBooks (intentionally excluded — see [ADR 006](decisions/006-no-quickbooks.md)), Ramp (no Supabase integration; Emily reads it directly).

### Viktor (AI coworker)

Viktor is an AI agent embedded in the Unclogme Slack workspace with live integrations across the stack. Not the same as the Claude agent working on this repo — Viktor owns source-data expertise and built the original sync scripts.

- **Primary Slack channel for DB work:** `#viktor-supabase` (ID `C0AN9KDP5B8`)
- **Strengths:** Jobber GraphQL internals, Airtable schema, Fillout form structure, source-data edge cases
- **Weaknesses:** Column name drift — frequently proposes wrong column names. Always validate against `docs/schema.md`.
- **Collaboration rule:** Get Viktor's sign-off before implementing structural changes. Check for replies every 3 min, max 3 attempts. See CLAUDE.md for full protocol.

---

## Strategic priorities

### Short-term (3–6 months)
1. Complete Supabase data warehouse — all sources syncing via webhooks.
2. Convert 77 overdue clients to annual maintenance contracts (~$130K locked ARR).
3. Raise prices 10–15% — still below market.
4. Hire bilingual Admin & Tech Director.
5. Ship Jobber → Supabase photo migration before May 2026 Jobber sunset.

### Medium-term (6–18 months)
1. Expand to Broward County (currently 0.5% penetration of 5,818 establishments).
2. Google Business Profile + review automation (free growth lever).
3. Outbound campaign against the 10,182 Florida DBPR restaurant records already captured.
4. Resolve the Cutler Bay dump-site bottleneck.
5. Build a driver performance system (safety scores, bonus automation, weekly payroll digest).

### Revenue growth math
- **Current:** ~$56K / month average
- **Target:** $200K+ / month
- **Path:**
  - Convert overdue clients: +$130K ARR
  - 15% price increase: +$100K ARR
  - Broward expansion (200 new clients): +$200K ARR
  - Fill truck capacity (409 → 500+ clients): current fleet can handle 3× volume

---

## How to work with this team

- **Yan is strategic/visionary.** He explores ideas, thinks big. Frame options and trade-offs when he's involved.
- **Fred is technical and systematic.** He builds, implements, tests. Frame decisions with 3NF reasoning and source-of-truth clarity.
- **Diego handles day-to-day office ops.** Reports, scheduling, client comms.
- **Aaron handles field and client relations.** Route planning, on-site issues.
- **Andres is the field source of truth** for equipment, trucks, and field procedures.

### What Fred values (explicit operating preferences)
- **Specificity over generality.** Know our clients, trucks, pricing, stack. Don't give generic answers.
- **Actionable over theoretical.** Build, don't just analyze.
- **Systems thinking.** How does this change ripple? What breaks downstream?
- **Revenue-first.** Every project ties back to revenue growth, cost reduction, or compliance.
- **Speed + quality.** Move fast, don't redo work.
- **No unnecessary artifacts.** Don't generate Excel/docs/screenshots unless asked. Spend tokens on engineering.
- **3NF standing check.** Every schema proposal must state 3NF justification per column. Reference all data via FK.
- **Source-agnostic schema.** Zero tolerance for `jobber_*` / `airtable_*` / source-prefixed business columns. See [ADR 002](decisions/002-entity-source-links.md).

---

*Last reviewed: 2026-04-20. Update this doc when fleet, team, DERM licensure, or revenue posture materially changes.*
