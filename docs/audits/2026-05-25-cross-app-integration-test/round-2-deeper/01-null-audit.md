# Comprehensive NULL Field Audit

Per-field NULL count across every view each app surfaces. Each field
categorized by root cause and whether it's a real bug, expected design, or
ops backfill gap.

---

## TIER 1 — RED / Blocking for users

### F1 — 177 active clients can't log into Field Portal (NULL slug)

**View**: `customer.clients.slug` definition is `lower(c.client_code)`.
**Root cause**: 186 of 385 clients (48%) have `client_code IS NULL`. Of those, **177 have `status='ACTIVE' OR 'RECURRING'`** — active customers who genuinely should be able to use FP.

**Sample affected clients**:
- Noa (id 462)
- Sammy the plumber (id 461)
- MR. Pasta FACTORY (id 459)
- Mr sharon (id 457)
- Marinos Pizza Pasta (id 451)
- Carne en Vara (id 448)
- Yes Market Miami beach (id 388)
- 1265 NBP, LLC (id 387)

**Why NULL**: `client_code` is sourced from Airtable. New Jobber-only clients (created after Airtable enrichment stopped or never enrolled in the Airtable tracker) lack a code. Per CLAUDE.md rule 4: Jobber is canonical for client identity; Airtable is enrichment.

**Fix options** (Fred decision needed — slug semantics matter for QR sign printing):
- **(A)** Add `'c-' || c.id` fallback when client_code IS NULL → 177 active clients can immediately log in via `/c-462`. Doesn't break any existing QR (existing slugs from client_code stay intact).
- **(B)** Backfill `client_code` for those 177 clients (manual or batch-generated). Affects Airtable tracker.
- **(C)** Keep them out of FP — design choice (e.g., these clients are too new / not yet ready for customer portal).

**Status**: documented, not auto-applied. Decision required.

---

### F2 — All 4 vehicles have NULL `decal_number` → `decal` field always blank in FP/AR

| Vehicle | decal_number |
|---|---|
| Moises | NULL |
| Cloggy | NULL |
| David | NULL |
| Goliath | NULL |

**Root cause**: `vehicles.decal_number` was added to the schema but never backfilled. Likely sourced from Samsara or Airtable PRE-POST. Since none are set, the `customer.work_orders.decal` column is 100% NULL.

**Fix**: backfill `vehicles.decal_number` from Samsara API (truck registration info) or Airtable. 4 manual UPDATEs. Generates 4 audit rows.

**Status**: documented, not auto-applied. Needs ground-truth decal numbers from Fred.

---

### F3 — Every customer.permits row has NULL `permit_url` (0/236 sc.permit_document_path set)

**View**: `customer.permits.permit_url = sc.permit_document_path`
**Root cause**: 236 service_configs rows total. ZERO have `permit_document_path` populated.

**Impact**: FP "Compliance Documents" section shows the permit numbers (e.g., "Grease Trap, Monthly, Permit #ABC123") but customers cannot view the actual permit document. The view exposes a column that's never populated.

**Fix**: backfill permit PDFs from Airtable (GDOs table had them) or upload manually. Generates 236 audit rows if done in bulk.

**Status**: documented, not auto-applied. Backfill task.

---

## TIER 2 — YELLOW / Design gaps (not bugs, but worth knowing)

### F4 — `duration_minutes` 100% NULL in visits_with_review (Admin Review)

**Root cause**: column probably computed from `actual_arrival_at` and `actual_departure_at` (Samsara-derived) — both 100% NULL because Samsara GPS sync to those columns isn't wired yet. Until Samsara visit-window detection is implemented, duration stays NULL.

**Status**: Future work, depends on Samsara integration. Not actionable now.

### F5 — `customer.wo_photos` only 1.5% photo coverage (75 of 4908 photos surface)

**Root cause**:
- 4803 photos have NO photo_classifications row → invisible to FP
- 105 have rows: 44 'after', 30 'before', 30 'internal' (hidden), 1 'extra'
- The view filters to `service_phase IN ('before', 'after', 'extra')` so 'internal' + 'unknown' photos hide from FP (intentional)
- Most visits haven't been reviewed in Admin Review yet → photos stay un-classified → hidden

**Status**: Correct-by-design. As Admin Review reviewers catch up, more photos surface. Not a bug.

---

## TIER 3 — Dead/dormant columns (visible in views but never written)

These columns are exposed in views but have 100% NULL because no UI surface writes them. Either delete the column projection or accept it'll be NULL until a future feature lands.

### customer.work_orders (FP)
| Column | source | Why NULL |
|---|---|---|
| `decal` | veh.decal_number | F2 — vehicles.decal_number never backfilled |
| `manhole_breakdown` | v.manhole_breakdown | column on visits, no UI writes it |
| `ticket_number` | v.ticket_number | column on visits, no UI writes it |
| `trap_condition` | v.trap_condition_notes | column on visits, no UI writes it |
| `wwtp_ticket_number` | dm.wwtp_ticket_number | column on derm_manifests, never populated |

### customer.clients (FP)
| Column | source | Why NULL |
|---|---|---|
| `group_name` | cg.name via LEFT JOIN client_groups | no client_groups rows |
| `material` | sc_gt.material_type | column never populated |
| `disposal_facility` | df.name via LEFT JOIN | properties.default_disposal_facility_id never set (1/516 properties) |
| `gdo_permit_url` | sc_gt.permit_document_path | F3 |
| `access_notes` | p.access_notes | column never populated |

### customer.scheduled_visits (FP)
| Column | Why NULL |
|---|---|
| `scheduled_window` | column on visits never populated |

### derm.visits (DERM Tracker)
| Column | Why NULL |
|---|---|
| `technician` | column never populated (derm tracker UI doesn't write) |
| `notes` | same |

### derm.manifests (DERM Tracker)
| Column | Why NULL |
|---|---|
| `dump_location` | never populated (Airtable had it; current sync doesn't) |
| `driver_name` | never populated |
| `gallons` | never populated |
| `wwtp_receipt_number`, `wwtp_receipt_document_path`, `wwtp_ticket_number` | never populated |
| `disposal_facility_id` | 899/900 NULL — manifests don't carry facility link |

### derm.gdos (DERM Tracker)
| Column | Why NULL |
|---|---|
| `permit_document_path` | same as F3 |
| `location_label` 89%, `notes` 89% | rarely populated |

---

## TIER 4 — Expected partial NULL (legitimate data shape)

| Column | NULL % | Why |
|---|---|---|
| `start_at` / `end_at` / `completed_at` in visits | 42% | Scheduled (future) visits have no time data yet. 0% NULL on completed visits → correct. |
| `derm_required` | 76% NULL on derm.visits | Most visits leave it NULL (means "default true"); only the explicit DERM-not-required get false. |
| `yellow_ticket_number` on derm.manifests | 88% NULL | Most manifests are Dade (white). Only 12% are Broward (yellow). |
| `gdo_number` in derm.visits | 35% NULL | Visits where the GDO isn't yet assigned. |
| `derm_manifest_url` in customer.work_orders | 81% NULL | View nullifies when `white_manifest_number` is duplicated AND for the 27% with no manifest linked at all. |

---

## TIER 5 — Empty views (will populate over time)

| View | rows | Why empty |
|---|---|---|
| `customer.recommendations` | 0 | visit_recommendations table has 0 rows (feature not exercised) |
| `customer.client_access_photos` | 0 | no photos uploaded with `entity_type='client' OR 'property'` |
| `derm.gdos.manifest_count` (computed) | varies | gdos exist but per-gdo manifest counts are populating |

---

## Summary

| Tier | Findings | Action required |
|---|---|---|
| Tier 1 — RED | 3 (slug, decal, permit_url) | Need Fred decisions / backfills |
| Tier 2 — YELLOW | 2 (duration, photo coverage) | Future Samsara work / waiting on AR reviewers |
| Tier 3 — Dead columns | 17 across all views | Either remove from view def or wait for feature surface |
| Tier 4 — Expected partial | 5 | Correct behavior, no action |
| Tier 5 — Empty views | 3 | Will populate organically |

**TL;DR**: 4 truly blocking real-world issues, and they're all backfill/data-hygiene problems, not code bugs. The view layer is healthy. The data layer has known gaps.
