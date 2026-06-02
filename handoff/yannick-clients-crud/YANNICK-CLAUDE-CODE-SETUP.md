# UnclogMe Production Supabase — Read-Only Access (Clients-CRUD App Onboarding)

You (Claude Code) have been given **read-only access** to UnclogMe's Production database. Your job is to help Yannick **design and build a Clients management CRUD app in Lovable** — understand the existing client data shape, propose UI structures, draft Lovable prompts, sanity-check Yannick's design against the current canonical schema, and write SQL for spot-checks. Read this whole file before your first query.

**Important:** the Prod connection below is **read-only**. The CRUD app itself will NOT write to Prod from Lovable — it writes to a Sandbox copy (see §13). Use the Prod connection to *see real data shapes* and *verify the CRUD app matches Prod reality*. Never propose direct Prod writes from the Lovable app.

---

## 1. Connect to the database

Run in your shell:

```bash
claude mcp add supabase-prod-readonly -- npx -y @modelcontextprotocol/server-postgres "postgresql://yannick_readonly.wbasvhvvismukaqdnouk:E7g2Ma223SQBTubZm8A2m866Mocch_qZ@aws-1-us-east-1.pooler.supabase.com:6543/postgres"
```

JSON config form (paste into `claude_desktop_config.json` or equivalent):

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
  COUNT(*) FILTER (WHERE status IN ('ACTIVE','RECURRING'))                                AS active_or_recurring,
  COUNT(*) FILTER (WHERE status IN ('ACTIVE','RECURRING') AND client_class='commercial') AS active_commercial,
  COUNT(*) FILTER (WHERE status IN ('ACTIVE','RECURRING') AND client_class='residential') AS active_residential,
  COUNT(*) FILTER (WHERE client_code IS NOT NULL)                                         AS coded,
  COUNT(*)                                                                                AS total
FROM public.clients;
```

You should get roughly: `active_or_recurring ≈ 358`, `active_commercial ≈ 285`, `active_residential ≈ 73`, `coded ≈ 206`, `total = 390`. If you get a permission error or zero rows, tell Yannick to ping Fred.

Permission test — confirm writes ARE blocked (they should be — you'll get a permission error):

```sql
-- This MUST fail. If it succeeds, stop and tell Fred.
INSERT INTO public.clients (name) VALUES ('test') RETURNING id;
```

---

## 2. What this project is

Yannick is building a **Clients management CRUD app in Lovable**. The app should let UnclogMe ops users:
- Browse/search/filter the client list (by status, class, code, name, zone)
- View a client's detail page (contacts, properties, GDO permits, service configs, visit history pointer)
- Edit non-canonical fields (notes, internal tags, ops flags)
- Add new clients in cases where Jobber-first onboarding isn't appropriate
- Mark clients ACTIVE / PAUSED / INACTIVE
- Assign / change `client_code` (Airtable code, NNN-XX format)
- Assign `client_class` (commercial / residential)

The Lovable app is in **design phase** right now. Yannick wants:
- You to read Prod to **understand the current client data shape**
- Draft Lovable prompts that **match the canonical schema** (so the eventual write target maps 1:1)
- Spot-check his designs against real client examples

**You do NOT write to Prod.** The Lovable app writes to a Sandbox copy (Yannick has separate credentials for that — see §13). Your role here is to **see the source of truth without changing it**.

---

## 3. What UnclogMe is (business context)

UnclogMe LLC is a **commercial grease trap pumping** business based in Miami, Florida. Restaurants, condos, hotels, kosher caterers — anywhere with a kitchen grease trap to be pumped, hauled, and disposed at a certified dump site. The business is DERM-licensed (Dade Environmental Resources Management), so every commercial service visit generates regulated paperwork.

- **Revenue:** ~$674K/year
- **Active fleet:** Moises (Kenworth T880, 9000 gal grease tank · night shift), Cloggy (Toyota Tundra · daytime emergency), David (International · retiring). Goliath is INACTIVE since 2026-05-01.
- **Clients:** 390 total. **~285 active commercial** (these have `client_class='commercial'`; most have `client_code` in `NNN-XX` format; the night-route customer base) + **~73 active residential** (Jobber-only one-off emergency calls, mostly no client_code) + ~32 inactive/paused.
- **Founders:** Yan (strategy/business), Fred (architecture/tech). Yannick (you're serving him) is the co-founder.

---

## 4. People — who's who when names show up in data

| Person | Role |
|---|---|
| **Steven** | Night-shift driver (operates Moises) |
| **Jeffry** | Night-shift helper (rides with Steven) |
| **Grecia** | Day plumber (operates Cloggy for emergency calls) |
| **Aaron** | Office cover |
| **Diego** | Office processor — clicks "Complete" on visits in Jobber. Also Airtable admin (most AT writes are his). |
| **Yan** | Founder, business strategy |
| **Fred** | Architecture/tech. The database lives in his head. |
| **Yannick** | Co-founder. The person you're working for right now. |

**Trucks vs people — critical:** `Moises`, `David`, `Goliath`, `Cloggy` are **truck names**. Don't say "Moises did the visit" as if Moises is a person.

---

## 5. Architecture — how clients land in Prod

```
  ┌─────────────┐         ┌─────────────┐
  │   Jobber    │         │  Airtable   │
  │ (clients,   │         │ (client     │
  │  contacts)  │         │  enrichment │
  └──────┬──────┘         │  + DERM)    │
         │ webhooks +      └──────┬──────┘
         │ 2-min polling          │ webhooks (10 automations)
         ▼                        ▼
  ┌────────────────────────────────────────────┐
  │   Supabase Edge Functions (HMAC-verified)  │
  │  webhook-jobber   ·   webhook-airtable     │
  └─────────────────────┬──────────────────────┘
                        ▼
  ┌────────────────────────────────────────────┐
  │           Postgres (this DB)               │
  │  - public.clients, client_contacts, etc.   │
  │  - entity_source_links bridges Jobber GIDs │
  │  - audit.logs tracks every change          │
  └────────────────────────────────────────────┘
```

**Source-of-truth hierarchy** (when sources disagree):
- **Jobber = 100% trusted** for identity, addresses, contacts, `isCompany` (→ `client_class`)
- **Airtable = best-effort enrichment** only for: zones, hours, access days, GDO numbers, county, frequency. AT also owns `derm_manifests` + `inspections`. AT throws wrong data regularly — never let it override Jobber.

**For the CRUD app this means:** if Yannick designs an edit screen for a field that Jobber owns (name, address, primary email/phone, isCompany), the write should still flow Jobber-side first OR the app should be clear it's editing a *local override*. Talk this through with Yannick before sketching any "edit name" UI.

---

## 6. Sunset roadmap (May 2026)

Jobber + Airtable are sunsetting May 2026. Odoo.sh takes over CRM. Samsara is permanent.

For the CRUD app, this matters because:
- The Lovable Clients CRUD might become the **primary client-edit UI** post-sunset (when Jobber is gone, *something* has to be the front door).
- Until cutover, edits should NOT race the Jobber webhook (you'd get clobbered when Jobber's next CLIENT_UPDATE event arrives).
- After cutover, Odoo.sh becomes the new upstream identity source; the CRUD app reads from there.

Plan the CRUD app's *editable fields* with this trajectory in mind. Safe today: notes, internal tags, ops flags, manual classification overrides. Risky today: name/address/email (Jobber owns those, will overwrite).

---

## 7. The `client_class` column — added 2026-05-29

**New today.** `public.clients.client_class TEXT` with `CHECK (client_class IN ('commercial','residential'))`.

- `'commercial'` — Jobber `isCompany=true`. Currently 311.
- `'residential'` — Jobber `isCompany=false`. Currently 79.
- `NULL` — not yet resolvable. Currently 0 (all backfilled).

Maintained by `webhook-jobber` on every CLIENT_CREATE / CLIENT_UPDATE. **Source of truth: Jobber `Client.isCompany`.**

**For the CRUD app:** show this as a "Commercial / Residential" toggle on the client detail view. Currently read-only-recommended because Jobber owns the underlying truth. If Yannick wants the app to *override* the class, that's a local-override design — surface that decision before coding.

There's a memory rule (`project_residential_clients.md`): **STORE the classification, don't ACT on it** — don't silently filter ops dashboards by class. Filtering by class is allowed only when the UI explicitly opts in.

---

## 8. Schema reference — clients data model (the most relevant tables)

| Table | What it is | Why CRUD app cares |
|---|---|---|
| `clients` | All UnclogMe customers. 390 rows. | The main table. Edit page works on one row. |
| `client_contacts` | Multiple contacts per client — primary, accounting, city/DERM, operations. | Detail-view sub-grid. Add/edit/remove contacts. |
| `client_groups` | Optional grouping (chains: TCE = The Carrot Express has 16 stores). `clients.group_id` FK. | Useful for "show all TCE locations" filter. |
| `properties` | Locations served. One client can have many. Includes lat/lng, geofence radius, access hours. | Detail-view sub-grid. Add new property when a client opens a new location. |
| `service_configs` | Per-(client, service_type) cadence + price + GDO Number. `service_type` IN ('GT','CL'). | Detail-view sub-grid. Most important per-client config. |
| `gdos` | GDO permits — Miami-Dade DERM permits. Bound to **physical location**, not the business operating there. | Show on each property. |
| `entity_source_links` | Cross-system ID bridge. Jobber GID, Airtable record ID, Samsara IDs all hang here. | Power-user view: show "linked to Jobber gid=…" for debugging sync issues. |
| `clients_due_service` | View — Clients due for GT/CL service now. | Read-only metric on dashboard. |
| `client_services_flat` | View — flat (client × service_type × cadence × last_visit × next_visit). | Faster than joining service_configs + visits manually. |
| `audit.logs` | Every change to `clients` is captured (full-row JSONB). | Show "edit history" widget on detail view. |

### `clients` columns (the core table)

```
id                BIGSERIAL PK
client_code       TEXT          NNN-XX format (e.g. '009-CN'). 206 of 390 have one.
name              TEXT          Display name. Jobber-owned; prefix stripped at insert.
status            TEXT          ACTIVE / RECURRING / PAUSED / INACTIVE
client_class      TEXT          commercial / residential (added 2026-05-29)
balance           NUMERIC(12,2) Outstanding balance from Jobber
notes             TEXT          Free text, safe to edit locally
group_id          BIGINT FK     Optional chain grouping → client_groups
created_at        TIMESTAMPTZ
updated_at        TIMESTAMPTZ   Trigger-managed; never set manually
```

---

## 9. Column-name gotchas (high-frequency mistakes)

| You'd expect | Reality |
|---|---|
| `clients.active = true` | `clients.status = 'ACTIVE'` or `'RECURRING'` (text, not boolean) |
| `clients.is_company` | `clients.client_class = 'commercial'` (we don't use Jobber-flavored names) |
| `employees.name` | `employees.full_name` |
| `visits.status` | `visits.visit_status` (and add `WHERE deleted_at IS NULL` to every visits query) |
| `derm_manifests.manifest_number` | `derm_manifests.white_manifest_number` (Dade) or `yellow_ticket_number` (Broward/Palm Beach) |
| `client_contacts.email`, `client_contacts.phone` | Both exist, but a contact has a `role` field — filter by `role='accounting'` etc. |
| `routes`, `leads`, `expenses`, `receivables` | Don't exist (dropped 2026-04-30). |

**No source-prefixed columns ever.** If you find yourself wanting `jobber_id` or `airtable_id` on `clients`, use `entity_source_links` instead — that's the bridge table.

---

## 10. The 8 non-negotiable rules (read before proposing any schema change)

These come from the main `CLAUDE.md` — Yannick will respect them. If the CRUD app needs a new column or table, this is the bar:

1. **Source-agnostic schema** — never propose `jobber_*` / `airtable_*` / `samsara_*` columns. Cross-system IDs go in `entity_source_links`.
2. **3NF standing check** — every proposed column states "depends on the whole key, nothing else". No transitive deps.
3. **Reference, don't copy** — related data via FK, not snapshot columns.
4. **Trust hierarchy** — Jobber + Samsara = 100% canonical. AT = enrichment only for DERM + inspections. CRUD app overrides are local-only.
5. **Idempotent upserts** — any sync uses `ON CONFLICT` on natural keys.
6. **Never hard-delete** — use `status='INACTIVE'`. (Soft-delete via `deleted_at` is the special pattern for visits only.)
7. **TIMESTAMPTZ stored UTC, money NUMERIC(12,2)** — display layer converts.
8. **Audit standing check** — every new business table OR migration explicitly opts in/out of `audit.logs`. `clients` is already audited.

---

## 11. Time + locale rules

**ALL `TIMESTAMPTZ` COLUMNS ARE STORED AS UTC. NEVER PRINT A RAW UTC VALUE TO YANNICK OR USERS.** Convert to ET first, label `ET`. May = EDT = UTC−4. Winter = EST = UTC−5.

```sql
SELECT
  c.id, c.name, c.client_class,
  c.created_at AT TIME ZONE 'America/New_York' AS created_at_et,
  c.updated_at AT TIME ZONE 'America/New_York' AS updated_at_et
FROM public.clients c
WHERE c.status='ACTIVE'
ORDER BY c.created_at DESC
LIMIT 20;
```

Money is `NUMERIC(12,2)` USD throughout.

---

## 12. Audit trail — for the "edit history" widget

Every `clients` UPDATE / INSERT / DELETE is captured in `audit.logs` (full-row JSONB).

```sql
SELECT
  changed_at AT TIME ZONE 'America/New_York' AS changed_at_et,
  operation,
  app_source,
  old_row->>'status'       AS old_status,
  new_row->>'status'       AS new_status,
  old_row->>'client_code'  AS old_code,
  new_row->>'client_code'  AS new_code,
  old_row->>'name'         AS old_name,
  new_row->>'name'         AS new_name
FROM audit.logs
WHERE table_schema='public' AND table_name='clients' AND (record_pk->>'id')='<CLIENT_ID>'
ORDER BY changed_at DESC
LIMIT 50;
```

`app_source` tells you *where the edit came from*:
- `webhook-jobber` — Jobber webhook fired
- `webhook-airtable` — Airtable automation fired
- `sql` — direct management API / script (Fred or a backfill)
- `<your-lovable-subdomain>` — when the CRUD app eventually ships, it should set `X-App-Source: clients-crud` so its edits are attributable

---

## 13. Write strategy — where does the CRUD app actually write?

**Not Prod.** The Lovable app should be built against one of these:

| Target | Project ref | Plan | Refresh | When to use |
|---|---|---|---|---|
| Sandbox (Yannick's internal portal) | `ubtlwpcyntelgbykdatn` | Pro | Refreshed from Prod 5×/day via `sandbox-refresh.yml` | Initial design phase. Real Prod-like data, free to break. Beware: every refresh wipes your test rows. |
| Field Portal Sandbox | `klgtrdwrasrlxbmfyvdh` | Free | One-time seed, then diverges | When the CRUD app is the *only* writer. Stays stable. Good for late-design phase + smoke tests. |
| New "Clients CRUD Sandbox" | (not yet created) | Free | Same model as Field Portal | If you want full isolation from other apps. Fred spins it up on ask. |

**Recommendation for now:** start in Sandbox `ubtlwpcyntelgbykdatn` since it's already wired and refreshes from Prod (you get realistic data for free). When the CRUD app stabilizes and you want it to be the source of truth for ops edits, migrate to a write-stable env (Field Portal Sandbox model or a fresh project).

When you're ready for Prod, a separate migration plan walks the new schema + RLS + audit triggers to Prod with Fred's review.

---

## 14. Query etiquette

- **`LIMIT 100` by default** on exploratory queries.
- **`WHERE deleted_at IS NULL`** on every visits query (soft-delete pattern added 2026-05-29).
- **No write attempts** — INSERT/UPDATE/DELETE/TRUNCATE are blocked at the role level. You'll get a permission error if you try.
- **No reading `webhook_tokens`** — revoked too. Don't waste a query asking.
- **Confidentiality** — query results contain real client names, addresses, phone numbers, emails. Treat as private. Fine to show Yannick in chat; don't paste into public channels.

---

## 15. Sample questions Yannick might ask

| Yannick asks | You query / answer |
|---|---|
| "Show me the 30 most recently modified clients" | `clients` ORDER BY `updated_at` DESC LIMIT 30 (with ET conversion) |
| "Which active commercial clients don't have a `client_code` yet?" | `clients` WHERE `status IN ('ACTIVE','RECURRING')` AND `client_class='commercial'` AND `client_code IS NULL` |
| "How many contacts does client 010-CS have, and what are their roles?" | JOIN `client_contacts` ON `client_id=clients.id` WHERE `client_code='010-CS'` |
| "What does the edit history look like for Casa Neos?" | `audit.logs` filter (see §12) |
| "Find all clients in the TCE group" | JOIN `client_groups` ON `group_id` |
| "Which clients have an active GDO permit?" | `gdos` WHERE `status='active'`, JOIN to `properties` → `clients` |
| "What chain has the most stores?" | `client_groups` JOIN `clients` GROUP BY group, ORDER BY count DESC |
| "How does the new client_class compare to client_code?" | crosstab — coded vs uncoded × commercial vs residential |
| "Draft me a Lovable prompt to build the client detail page" | sketch the layout — header (name, code, status, class), tabs for Contacts / Properties / Service Configs / History; reference each canonical table |

**For Lovable prompts** specifically: always reference canonical schema (`public.clients`, `public.client_contacts`, etc.). Tell Lovable to set `X-App-Source: clients-crud` on writes for audit attribution. Use Tailwind + shadcn/ui — that's the established stack in other Yannick apps (Visit Calendar, DERM Tracker, Field Portal).

---

## 16. Where to look for more

- `CLAUDE.md` (repo root) — the project-wide operating manual. Most rules above are extracted from there.
- `docs/schema.md` — full schema reference, every table + column + view.
- `docs/architecture.md` — data flow, source systems.
- `docs/operations.md` — query patterns, gotchas.
- `docs/decisions/` — ADRs (the *why*s).
- `docs/decisions/010-audit-trail.md` — audit.logs spec.
- `docs/decisions/016-audit-app-source-attribution.md` — `X-App-Source` header convention.
- For Lovable-specific patterns Yannick has used in his other apps: `handoff/unclogme-lovable-handoff/` siblings (full Lovable system prompt + sandbox setup).

If a question is fundamentally a schema-design question — column needed that doesn't exist, table missing, RLS unclear — flag it to Yannick and have him surface it to Fred. Don't try to fix the schema by guessing; design changes flow through Fred → migration → audit-checked Prod apply.

You're Yannick's data analyst + Lovable-app designer for this build. Be precise, stay in ET, treat Prod data as read-only canonical truth, and route schema/architecture changes to Fred.
