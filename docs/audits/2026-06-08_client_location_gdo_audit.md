# Client → Location → GDO — DB Structure Audit

**Date:** 2026-06-08 · **Author:** Claude (with Fred)
**Scope:** Whole-DB audit (tables / views / functions) focused on the **client → location → GDO** structure. Confirm our DB does **not** carry forward the "one client row per location" duplication that Jobber / Airtable / Samsara have, and that it models **1 client → N locations → 1 GDO per location** (a GDO = a physical manhole/permit; GDO numbers persist across permit renewals).

---

## Bottom line

The structure is **already designed, sound, and 3NF-correct** — there is a full spec from 2026-05-31 and it is partially implemented. **Our DB has no structural duplication flaw.** It *inherits* Jobber's per-location client rows (unavoidable — Jobber owns client identity per Rule 4), and imposes the correct shape on top via **two native canonical layers**:

- **`client_groups`** — a brand grouping over **N separate billing-clients** (e.g. TCE = 23 Jobber clients → 1 group).
- **`client_locations`** — **N service-areas under ONE billing-client** (e.g. Casa Neos = 1 client → 3 locations, each its own GDO).

The remaining work is **data completeness + one decision to confirm**, *not* a redesign.

---

## 0. "Did we already record this?" — YES, extensively

| Doc | What it is |
|---|---|
| `docs/superpowers/specs/2026-05-31-client-locations-multitenant-design.md` | **Design anchor** (v2). Full model, E-track/D-track/Phase-2 roadmap, open questions. |
| `docs/tce-chain-modeling-decision.md` | 5-agent investigation: **why TCE = `client_groups`, not `client_locations`** (per-location billing). |
| `docs/multi-location-clients-for-diego-yan.md` | Discovery of multi-location candidates (chains vs shared-address). |
| `docs/operations.md#gdo-permits--bound-to-location` | GDO domain rule: **location-bound, number persists on renewal**. |
| `docs/migrations/2026-06-01_client_locations.sql` (+ `b`, `c`, rollback) | Table + column DDL; Casa Neos/Wynd seed; Phase-2 batch-1 dedup + backfill. |
| `docs/gdo-phase-2-2026-05-25/` + `docs/phase2-gdo-verification-message.md` | GDO cleanup + the suspect-2nd-GDO verification queue. |
| Memory `project_client_locations_model` | One-line index of the above. |

So this audit is a **current-state assessment + gap analysis**, layered on the existing spec (which it does not supersede).

---

## 1. DB inventory (complete)

- **39 public tables**, **11 public views + 27 app-schema views** (ops 19, customer 8, field 0), **~20 functions** (public 15, customer 5).
- Client-model tables + key counts: `clients` (395), `client_groups` (1), `client_locations` (14, across 5 clients), `gdos` (166; 9 linked to a location), `properties` (755), `service_configs` (255), `visits` (721), `derm_manifests` (391), `entity_source_links` (21,724).
- Full table list: app_shift_reviews, app_visit_reviews, client_contacts, client_groups, client_locations, clients, derm_email_sends, derm_manifest_number_proposals, derm_manifests, disposal_facilities, employees, entity_source_links, gdos, inspections, invoices, jobber_oversized_attachments, jobs, line_items, manifest_visits, municipality_regulators, notes, photo_classifications, photo_links, photos, properties, quotes, service_configs, service_line_items, sync_cursors, sync_log, vehicle_telemetry_readings, vehicles, visit_assignments, visit_recommendations, visit_sync_flags, visits, webhook_events_log, webhook_tokens, zones.

---

## 2. The client → location → GDO model as built

```
client_groups (brand)            clients (Jobber billing entity, 395)
      ▲  group_id                      │ id
      └──────────────────────────  clients.group_id (FK, nullable)
                                        │
                            client_locations (service-area, 14)   gdos (166)
                              id, client_id FK──────────┐         id
                              name, property_id FK       │        client_id  FK→clients (NOT NULL)
                              status, contact_*          └──◄──── client_location_id FK (nullable, ~1:1)
                                                                  property_id FK→properties (NOT NULL)
                                                                  gdo_number, status, permit_expiration,
                                                                  max_frequency_days, location_label
```

**Two patterns, chosen by Jobber's billing grain:**

| Real-world shape | Jobber | Our model | Example |
|---|---|---|---|
| One business, **N separate billing entities** (each its own invoice / AP email / QB customer / GDO) | N client records | **`client_groups`** + `clients.group_id` | TCE (23), Pura Vida, La Granja |
| One business, **one billing entity**, N service-areas/manholes | 1 client record, N GDOs | **`client_locations`** (1:N) + `gdos.client_location_id` | Casa Neos (3), Wynd 28 (5) |

`client_locations` is **identity-only** (Rule 3): visits / frequency / price / billing stay on their own tables and are *referenced*, never copied. Locations are **native canonical** (Rule 1 / ADR 002) — no `airtable_*` columns; not sourced from Airtable.

---

## 3. Current state vs your three requirements

**(a) "Make sure our DB isn't going through the per-location client duplication."**
→ Our DB mirrors Jobber's client rows (it must — Jobber is the source of client identity). It does **not add** duplication; the `client_groups` / `client_locations` layers are exactly the mechanism that re-imposes the true 1-business structure. The chains present: **PV (24 clients), TCE (23), LG (6), GRO (4), BB (4)**, plus ~10 two-client suffixes. **Only TCE is grouped so far** (`client_groups` = 1).

**(b) "1 client → N locations" (Casa Neos / TCE).**
- **Casa Neos** ✅ — 1 client `009-CN`, 3 locations (Bars→GDO-15062, Kitchens→GDO-10877, Lounge→GDO-16389), all ACTIVE + linked. Textbook.
- **TCE** — 23 separate client rows (061→169-TCE), grouped under `client_group` 2. **Not** collapsed to 1 client + 23 locations (see §4).

**(c) "1 location → 1 GDO" (number persists on renewal).**
→ Modeled by `gdos.client_location_id` (~1:1) + `gdos.client_id` + `gdos.property_id`. **Only 7 clients have >1 active GDO** (= the only true multi-location candidates by this rule):

| client | active GDOs | modeled locations | state |
|---|---|---|---|
| 009-CN Casa Neos | 3 | 3 | ✅ clean |
| 175-PV Pura Vida Brickell 701 | 2 | 2 | ✅ clean (Phase-2 b1) |
| 060-TU Talmudic University | 2 | 0 | ⚠️ 2nd GDO = phantom, pending ops verify |
| 132-PUM Pummarola | 2 | 0 | ⚠️ 2nd GDO = typo-dup (GDO-000951/00951) |
| 155-PV Pura Vida Flamingo | 2 | 0 | ⚠️ phantom, pending verify |
| 170-PV Pura Vida Bakery | 2 | 0 | ⚠️ phantom, pending verify |
| 192-FRK Fresko | 2 | 0 | ⚠️ malformed ("Not available") |

So the multi-location universe is **tiny (7) and already triaged**: 2 clean, 5 with **suspect** 2nd GDOs awaiting DERM-portal verification (per `phase2-gdo-verification-message.md`) — i.e. they may not be real 2nd locations at all.

---

## 4. The central question to confirm — TCE (collapse vs group)

You framed TCE as **"1 client with many locations."** The DB instead has **23 TCE clients in one brand group.** These are reconcilable, and the difference is forced by **billing**:

- In Jobber, each TCE location (Brickell, Kendall, Doral…) is a **separate client** with its **own invoices, AP email, QB customer, price, and GDO**. Merging them into one client would **destroy per-location billing**.
- `client_locations`' premise is "identity-only, **shared** billing." TCE violates that → it correctly uses **`client_groups`** instead (the 5-agent `tce-chain-modeling-decision.md`).
- The `client_group` **gives you the "one TCE" view** for reporting/rollup, while preserving the 23 billing entities.

**Casa Neos is the opposite** — **one** Jobber client, one bill, multiple GDOs → `client_locations`.

> **The rule:** count the **Jobber billing clients** for the business. **N clients → `client_groups`. 1 client → `client_locations`.**

**→ Confirm:** is the group-based "one TCE" view what you want (keep 23 billing clients, grouped), or do you intend something else? (If you ever truly want "1 TCE client," that's a Jobber-side merge that loses per-location billing — not recommended.)

---

## 5. Findings (by severity)

### Structure — PASS (no redesign needed)
- 3NF / identity-only `client_locations`, native-canonical, correct FK graph, GDO location-bound with persistent number, audit-trail on `client_locations`. All consistent with Rules 1–8.

### MEDIUM (completeness)
- **M1 — Chains not grouped.** Only TCE has a `client_group`. PV (24), LG (6), GRO (4), BB (4), and the ~10 two-client suffixes have **no brand group** → no "one business" rollup. Additive fix.
- **M2 — Suspect multi-GDO clients unresolved.** 5 of 7 multi-GDO clients (060-TU, 132-PUM, 155-PV, 170-PV, 192-FRK) have an unverified 2nd GDO (typo/phantom/malformed). Until verified, we can't tell "real 2nd location" from "dirty data." Ops/DERM-portal verification queue.
- **M3 — Wynd 28 GDOs not ingested.** 5 locations seeded, 0 GDOs linked (D-track, blocked on the `228-WYN` Jobber code + DERM-portal pull).
- **M4 — `gdos.client_location_id` is not UNIQUE.** The "1 location = 1 GDO" rule is modeled by convention, not enforced. A second GDO could be linked to one location with no DB guard.

### LOW
- **L1 — 207-CN (Casa Neos) is Airtable-only**, absent from our DB. Clarify: a 2nd Casa Neos venue, or a duplicate/legacy AT record? (AT sunsets — if it's a real venue it must arrive via Jobber or be a native location.)
- **L2 — Property over-count.** **354/395 clients have >1 property** (755 total) — far more than the 7 multi-GDO. Properties carry Jobber billing+service addresses and likely duplicates; **properties ≠ locations.** Don't infer multi-location from property count. Worth a separate property-dedup pass.
- **L3 — Single-GDO clients have no location row (spec Q5, open).** 388 clients are implicitly "1 location." Decide whether to materialize a trivial 1-location row each (uniformity for apps) or keep implicit.

---

## 6. Recommended changes (prioritized)

1. **Confirm the model (your call — §4):** group-based "one TCE", `client_locations` for single-billing multi-area. (The DB already encodes this; just confirm it matches intent.) **No code needed if confirmed.**
2. **M1 — Complete chain grouping** (additive, low-risk): create `client_groups` for PV, LG, GRO, BB, etc. and set `clients.group_id`, exactly like TCE. One-pass backfill from the `client_code` suffix + name, reviewed.
3. **M4 — Enforce 1-GDO-per-location**: add a partial UNIQUE index `gdos(client_location_id) WHERE client_location_id IS NOT NULL`. Cheap structural guard.
4. **M2 — Verify the 5 suspect 2nd GDOs** (ops/DERM portal, already queued) → then either model as `client_locations` (real 2nd manhole) or soft-delete (typo/phantom). This finishes Phase-2.
5. **M3 — Wynd GDO ingestion** (D-track) once `228-WYN` is set in Jobber.
6. **L1 — Resolve 207-CN**: confirm whether it's a real 2nd Casa Neos venue (→ Jobber client or native location) or a legacy AT dup to drop.
7. **L2 — Property-dedup investigation** (separate from this audit): why 354 clients have >1 property; dedup to the true service-address grain.
8. **Apps/views — surface locations**: `derm.*` + DERM Tracker need `location_name` so DERM/manifests attribute to the right manhole (D4/D5 in the spec).

---

## 7. What is already correct (do **not** change)

- The **two-layer model** (`client_groups` for chains, `client_locations` for single-billing multi-area) is the right answer and matches the business reality. Don't collapse TCE; don't force a location row where there's one GDO.
- `gdos` location-binding + persistent number = correct per the DERM domain rule.
- Locations stay **identity-only + native canonical** — keep visits/billing referenced, never copied; never source location identity from Airtable.

---

## 8. References
Spec `docs/superpowers/specs/2026-05-31-client-locations-multitenant-design.md` · `docs/tce-chain-modeling-decision.md` · `docs/operations.md#gdo-permits--bound-to-location` · migrations `2026-06-01_client_locations.sql` / `…b_seed_casa_neos_wynd…` / `…c_phase2_gdo_dedup…` · `docs/phase2-gdo-verification-message.md` · ADR 002 (entity-source-links), ADR 011 (source-of-truth) · Memory `project_client_locations_model`.

---

## 9. 2026-06-08 — Fred directive + build progress

**Directive (Fred):** the **location** is the service unit — it owns the **manhole/GDO**, its **billing/invoices**, and its **visits**. A **visit attaches to a location, not directly to a client** (reach the client *through* the location). One client → many locations. And: "group all the clients" (chains).

### Stage 1 — DONE ✅ (commit `9a9ece8`, migration `2026-06-08_client_groups_chains.sql`)
Grouped every clear brand-chain under `client_groups` (the brand = "client"; each store stays its own Jobber billing entity = the "location" that owns billing/invoices/GDO/visits). **10 brands now:** Pura Vida (24), The Carrot Express (23), La Granja (6), Grove Kosher (4), Bagel Boss (4), Myka / Nu Real Food / Krudo / Fresko / Mr.&Mrs. Pasta (2 each). 71 clients grouped, 324 standalone.
**Held for review (NOT grouped — not chains):** G7 (single-venue areas?), TRUE (truck dedup?), FIA (duplicate clients?).

### Stage 2 — DONE ✅ (migration `2026-06-08b_location_service_grain.sql` + `webhook-jobber` deploy)
Decisions taken (AskUserQuestion 2026-06-08): **(1) a visit maps to MANY locations** (one pump visit services several manholes) → `public.visit_locations` (M:N; each manhole still gets its own DERM via `manifest_visits`); **(2) every client gets ≥1 location** → materialized a default `'Main'` for the 390 single-site clients (**404 locations; all 395 clients covered**).
- **1 GDO per location** enforced (partial UNIQUE on `gdos.client_location_id`); **108 GDOs linked**.
- `visit_locations` backfilled: **664 historical + all 21 upcoming visits** attributed to GDO-confirmed manhole(s). **5 pending:** Wynd (D-track GDO ingestion) + 045-NU (its 2 facilities need GDO linkage).
- `webhook-jobber` `handleVisit` now maintains `visit_locations` on every sync — seeds only when a visit has none, so FP/ops manual tags survive replays. **Verified live:** replay ok=23 fail=0, 0 duplicate links, 0 webhook failures.

### Remaining follow-ups (not blocking)
- Wire **FP / billing / DERM** to read at the location grain (apps: LEFT-JOIN `visit_locations`, fall back to client when none).
- Link **045-NU**'s GDOs to its 2 facilities; ingest **Wynd**'s GDOs (D-track) → then its visits auto-attribute.
- Review the 3 held codes (**G7, TRUE, FIA** — areas vs duplicates); finish Phase-2 suspect-GDO verification (060-TU, 132-PUM, 155-PV, 170-PV, 192-FRK); **property-dedup** pass (354 multi-property clients).
