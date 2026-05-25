# Round 2 — Fixes Applied + Source-Alignment Findings

## Source-of-truth alignment for the 3 Tier 1 RED findings

Per Fred's clarification: "check with our DB if it's correctly aligned, and to then check with the source services like Jobber, Airtable and Samsara is to see if they're actually NULL or it's not saved correctly in our DB."

### F1 — 177 clients with NULL client_code → Field Portal slug = NULL

**Source check**: Compared all 177 by client `name` against the AT `Clients` table.

| Lookup result | Count |
|---|---|
| Found in AT with a `Client Code #3` formula filled | 0 |
| Found in AT without a code | 0 |
| **Not in AT at all** | **177** |

**Verdict**: **NOT a sync bug.** These 177 clients exist only in Jobber and have never been added to the Airtable client tracker. Per CLAUDE.md trust hierarchy, Jobber is canonical for client identity; AT is enrichment. The Client Code #3 is an AT-computed formula that only exists when a client row exists in AT.

**To resolve**: Yannick (or whoever owns Airtable) needs to add these 177 clients to AT and assign codes. There is no DB-side fix.

---

### F2 — 4 vehicles with NULL decal_number

**Source check (Samsara)**: All 4 trucks (Moises, Cloggy, David, Goliath) queried via Samsara `/fleet/vehicles`. The available fields are:

```
id, name, vin, esn, serial, cameraSerial, make, model, year,
harshAccelerationSettingType, notes, externalIds, gateway,
vehicleRegulationMode
```

`licensePlate` is undefined; **there is no decal-equivalent field in Samsara.** Goliath is also not in Samsara at all (matches MEMORY entry — decommissioned 2026-02-16).

**Source check (Airtable Vehicles)**: 4 records with fields `Year, Vehicle Type, Notes, Capacity (Gallons), Make, Vehicle Name, Primary Use, Status`. **No decal field either.**

**Verdict**: **NOT a sync bug.** The DERM Decal "LW 1133" displayed in FP header is a physical sticker issued by Miami-Dade DERM and printed on the truck. It's not in any electronic upstream source. To populate `vehicles.decal_number`, someone has to read the decal off the truck and enter it manually.

**To resolve**: 4 manual `UPDATE vehicles SET decal_number = '<value>'` once Fred provides them.

---

### F3 — 149 service_configs with NULL permit_document_path AND 41 with NULL permit_number

**Source check (Airtable Clients)**: AT has a `GDO PDF` (multipleAttachments) field AND a `GDO Number` (text) field on the Clients table — one value per client, applied to all service types.

Cross-checked against 175 DB ACTIVE/RECURRING clients with a client_code:

| Field | AT has value, DB MISSING | AT aligned w/ DB | AT NULL |
|---|---|---|---|
| `GDO PDF` → `permit_document_path` | **101** | 0 | 74 |
| `GDO Number` → `permit_number` | **41** | 131 | 24 |
| AT `manholes` → `properties.grease_trap_manhole_count` | 0 | 93 | 82 |

**Verdict**:
- `manholes`: **already aligned** — sync IS pulling it correctly when AT has a value.
- `permit_number`: **real sync gap**. The webhook-airtable code apparently only writes it to the GT service_config, but AT has one GDO per client which applies to ALL service types (CL/WD/LS). 41 of these are real backfill opportunities.
- `permit_document_path`: **real sync gap, but harder**. AT stores PDFs as multipleAttachments with short-lived (~2h) presigned URLs. We can't just save the URL — we need to download → Supabase Storage upload → save the storage path.

---

## Fix applied — `permit_number` backfill (41 rows)

The 41 service_configs (CL/WD/LS types for clients whose GT entry already had a permit_number, but the non-GT entries didn't) backfilled from AT `GDO Number`.

Junk values filtered out: `bw`, `Not available`. Only `^GDO-\d+$` patterns accepted.

| Before | After |
|---|---|
| `customer.permits` row count: **131** | **172** (+41, +31%) |
| Backfilled service_configs.permit_number | 41 ✓ |
| Still-NULL for these clients (those backfilled): 0 ✓ |
| Audit rows generated: 41 (app_source=sql, hint=NULL) |

Verified: re-running the alignment check shows `still_null: 0` for these clients. The 24 still-NULL AT entries are junk values that don't match the GDO pattern and were skipped intentionally.

**Forward fix not in this run**: patch `webhook-airtable/index.ts` to write `GDO Number` to ALL service_configs (not just GT) when AT updates. Otherwise re-runs of the backfill keep being needed when new clients land.

---

## Fix surfaced — `permit_document_path` backfill (101 candidates), NOT applied

Each PDF needs: download from AT → upload to Supabase Storage → save the bucket path. 101 files × (~hundreds of KB each) = a substantial backfill.

**Decision needed from Fred**: which Supabase Storage bucket should `permit_document_path` point to? (`GT - Visits Images` already exists; could go there in a `/permits/{client_id}/...` subfolder, or a new `permits` bucket.)

Once decided, the backfill script:
1. For each of the 101 AT clients with `GDO PDF`, fetch the AT attachment URL
2. Download bytes
3. Upload to Supabase Storage at chosen path
4. UPDATE `service_configs.permit_document_path = '<storage_path>'`

Plus webhook-airtable patch so future AT updates trigger the same workflow automatically.

---

## NULL audit re-categorized — corrected understanding

After source-alignment, the original Tier 1 RED findings become:

| Finding | Original cat. | After alignment | Action |
|---|---|---|---|
| F1 — 177 NULL client_codes | RED | **Real upstream gap** (Yannick) | AT data entry |
| F2 — 4 NULL decals | RED | **Real upstream gap** (DERM portal) | Manual entry |
| F3a — 41 NULL permit_numbers | RED | **Sync bug — FIXED** | ✓ backfilled |
| F3b — 101 NULL permit URLs | RED | **Sync bug — partial fix** | Storage backfill pending Fred |

So 1 of 4 originally-flagged is fixed in this commit. 1 is a partial fix waiting on storage decision. 2 are real upstream gaps unfixable from the DB side.
