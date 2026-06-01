# The Carrot Express (TCE) — Chain Modeling Decision

**2026-06-01 · from a 5-agent investigation (DB + provenance, Airtable, sync/webhook code, Jobber).**
Cross-checked against live Prod DB, the live Jobber GraphQL API (token valid), Airtable base
`appjMgjjZPeuudqQR`, and the actual webhook source. No mutations made.

**Question:** model TCE — a 23-location chain — given Fred's directive that it's ONE business with N
locations, each location → own GDO → DERM → invoice, while Jobber stays canonical for client/visit/
invoice identity and Airtable is canonical only for DERM + inspections.

---

## 1) Ground truth — TCE is 23 separate clients in EVERY system

| System | How TCE is modeled | Parent/group entity? |
|---|---|---|
| **Jobber** (canonical) | **23 distinct Client records**, each `isCompany`, **1 property each**, own Jobs, own Invoice stream. 23 distinct GIDs, **none shared**. | **None** — only the `-TCE` suffix + brand name. |
| **Airtable** (DERM) | **23 distinct Client records**, one per address, each with its own GDO #, price, AP email. | **None — text only.** `Client Code #3` formula uses `CLIENT XX = "TCE"` as a plain string grouping key (not a linked record/FK). |
| **Our DB** | **23 `clients` rows**, each with its own Jobber gid + AT rec in `entity_source_links` (23 distinct each, none shared). | `group_id` NULL on all 23; `client_groups` empty; `client_locations` for TCE = 0. |

**Each location is a fully self-contained silo** — every cross-sharing check came back empty (no shared
gid/rec, no shared invoice, no DERM spanning >1 TCE client). **Billing is genuinely per-location:**
distinct invoice counts/totals (061-TCE: 36 inv/$9.1K · 092-TCE: 33/$10.5K · 169-TCE: 3/$930), **23
distinct AP inboxes** `{store}accounting@carrotexpress.com`, per-location price (mostly $300; Aventura
Mall $375), one Jobber/QuickBooks customer per location.

**This is the INVERSE of Wynd 28 / Casa Neos** (one Jobber client, many sub-sites, shared billing). TCE
is many Jobber clients, one site each.

Roll-up across 23: 133 visits · 48 service_configs · 15 GDOs (8 have none) · 51 DERM (2026-only) · ~370 invoices.
*(A 24th "Carrot" in Jobber — `082-TFC The Fresh Carrot` — is a different brand, correctly excluded.)*

---

## 2) The workflow today — per-location, end to end

```
Jobber VISIT_COMPLETE  → webhook-jobber.handleVisit   → public.visits (client_id, property_id, job_id)
Airtable DERM row      → webhook-airtable.handleDermRecord → public.derm_manifests (client_id ONLY)
                                                         → manifest_visits (client + GT Last Visit ±2d)
Jobber INVOICE_*       → webhook-jobber.handleInvoice  → public.invoices (client_id, job_id) + back-fill visits.invoice_id
```

- **DERM is attributed PER-CLIENT, never per-GDO, in live code.** `handleDermRecord` sets `client_id`
  only; `gdo_id` is set by a SQL backfill (single-GDO clients only) + the DERM Tracker UI for multi-GDO.
  TCE works automatically **only because each location is its own single-GDO client.**
- **`invoices` has no `property_id` / `client_location_id` / `visit_id`** — grain is Jobber client + job.
  "Invoice per location" works **only because each location is its own Jobber client.**

---

## 3) Decision — `client_groups` (group the 23), NOT a physical collapse to 1 client

**Recommendation: create one `client_groups` row ("The Carrot Express") and set `group_id` on the 23
existing client rows. Do NOT merge them into one `clients` row.** This delivers Fred's "one business, N
locations" view while keeping everything that already works.

| | **A. `client_groups`** (recommended) | **B. collapse to 1 client + 23 `client_locations`** |
|---|---|---|
| Fights the live sync? | No — `group_id` is additive, webhooks never touch it | **Yes** — 23 Jobber GIDs can't merge upstream; every webhook re-splits the merged client until sunset |
| DERM-per-GDO | Works as-is (each loc = 1 client = ≤1 GDO) | **Breaks** — TCE becomes multi-GDO → manual-pick bucket; needs the **unbuilt** `handleDermRecord` GDO-resolution |
| Invoice-per-location | Preserved natively (own Jobber client) | **Breaks** — `invoices` has no location FK; all 23 stores pile onto one client_id |
| Per-location billing (price, AP email, QB customer) | Stays per-location = reality | Contradicts reality; must be moved onto location rows |
| Reversibility | Trivial (null the group_id) | Hard |

**Decisive point:** the `client_locations` spec premise is *"identity-only; visits/frequency/**billing**
stay shared, referenced never copied."* **TCE violates that** — its billing/pricing/AP-email/Jobber-QB
identity are all genuinely per-location. So TCE is a *grouping* case, not a `client_locations` case.
`client_locations` remains correct for the Wynd 28 / Casa Neos shape (one Jobber client, shared billing).

---

## 4) Migration

**Recommended (Option A) — additive, non-breaking, reversible:**
1. Insert 1 `client_groups` row `{name:"The Carrot Express", key/notes:"TCE"}`.
2. `UPDATE clients SET group_id=<TCE> WHERE client_code LIKE '%-TCE'` (verify exactly 23).
3. Teach the client-sync to set `group_id` from the code suffix (Airtable `CLIENT XX`) so new locations auto-group. **Only code touch, purely additive.**
4. (nit) Backfill 2 placeholder GDOs (061-TCE "Not available", 076-TCE "bw") if real permits exist.
→ Nothing repoints, nothing breaks. **Reusable as a generic `suffix → client_groups` recipe for ALL chains.**

**Option B (collapse) — reserve for post-sunset, and only after building first:** a location FK on
`invoices` (+ derivation invoice→job→property→location), the `handleDermRecord` GDO-resolution, and re-
teaching both webhooks the 23→1 mapping — else per-location invoicing + DERM-per-GDO + idempotency break.

---

## 5) Open questions for Fred
1. **Group vs collapse** — accept `client_groups` (group the 23, keep them Jobber-native) as the "one
   business, N locations" model for chains, with the physical collapse reserved for Wynd/Casa-Neos shape / post-sunset?
2. **Billing grain** — confirm chains bill **per-location** (23 AP emails, per-location price, own QB customer). The evidence says yes.
3. **Scope** — TCE only, or all code-suffixed chains in one pass?
4. **DERM-per-GDO on ingest** — greenlight building the `handleDermRecord` GDO-resolution now (so it's ready), or defer until/if a collapse happens?
5. **Sunset sequencing** — tie any physical collapse to the May-2026 Jobber/AT sunset (when re-split risk disappears)?
6. **Placeholder GDOs** — do real permits exist for 061-TCE + 076-TCE?
