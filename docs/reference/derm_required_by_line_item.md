# DERM-required by line-item / service type (canonical mapping)

**Source of truth:** Fred's Google Sheet — https://docs.google.com/spreadsheets/d/19ArflSwdhcpnu1U6Lii5q2VFmDLjwskurDCghN0aanE/edit (gid=0). Column A = "Requires DERM reporting" (Y/N), Column B = the formatted line-item type, Column C = the `#`. Re-export (`/export?format=csv&gid=0`) if the sheet changes — the sheet is canonical, this file is a snapshot captured 2026-06-02.

## The rule
**A visit requires a DERM manifest iff it includes a "Pumping" line item** (Grease Trap, Grey Water, or Lift Station pumping). Everything else — Cleaning, Warranty, Unclogging, Camera/Dye/Assessment, Labor, Parts, fees, GDO reporting — does **not** require DERM. (Confirms the earlier finding: the coarse `visits.service_type` GT/CL/LS code is too blunt — e.g. "03 - Pumping - Grey Water" is coded `CL` but DOES need DERM. The line-item type is the real signal.)

## Full mapping (snapshot 2026-06-02)

| # | Line item | DERM? |
|---|-----------|:---:|
| 01 | Service Agreement - Pumping - Grease Trap & Tank Cleaning | **Y** |
| 02 | Service Agreement - Pumping - Grease Trap | **Y** |
| 03 | Service Agreement - Pumping - Grey Water | **Y** |
| 04 | Service Agreement - Pumping - Lift Station & Tank Cleaning | **Y** |
| 05 | Service Agreement - Cleaning - Main Line Cleaning | N |
| 06 | Service Agreement - Cleaning - Aux Cleaning | N |
| 07 | Service Agreement - Cleaning - Tank Cleaning | N |
| 08 | Service Agreement - Warranty of Drainage | N |
| 09 | Service Call - Pumping - Grease Trap & Tank Cleaning | **Y** |
| 10 | Service Call - Pumping - Grey Water | **Y** |
| 11 | Service Call - Pumping - Lift Station & Tank Cleaning | **Y** |
| 12 | Service Call - Cleaning - Main Line Cleaning | N |
| 13 | Service Call - Cleaning - Auxiliary Line Cleaning | N |
| 14 | Service Call - Cleaning - Tank Cleaning | N |
| 15 | Service Call - Unclogging - Residential - Manual | N |
| 16 | Service Call - Unclogging - Residential - Hydrojet | N |
| 17 | Service Call - Unclogging - Commercial - Manual | N |
| 18 | Service Call - Unclogging - Commercial - Hydrojet | N |
| 19 | Service Call - Camera Inspection | N |
| 20 | Service Call - Dye Test | N |
| 21 | Service Call - Assessment | N |
| 22 | Service Call - Labor | N |
| 23 | Service Call - Parts | N |
| 24 | Service Call - Labor BUS | N |
| 25 | Credit card fee (3.53%) | N |
| 26 | ACH Fee (1%) | N |
| 27 | GDO Online Reporting | N |

**DERM-required set: `#` ∈ {01, 02, 03, 04, 09, 10, 11}** (all "Pumping").

## Planned fix (deferred — not yet applied)
Replace the current **stopgap** (`manifest_pickable_visits` offers ALL non-GT visits; `derm.visits` flags all `derm_required IS NOT false` visits as Missing Docs — see `migrations/2026-06-02_manifest_pickable_all_service_types.sql`) with this precise per-type rule:
1. Populate `visits.derm_required` from the visit's line items via this mapping (true iff it has a Pumping line item). Likely in the Jobber sync / a backfill keyed on `line_items.name` matched to the `#`/type.
2. Once `derm_required` is reliable, both `manifest_pickable_visits` and `derm.visits.needs_manifest` key off `derm_required` only (drop the service_type heuristics). Then cleaning/unclogging visits correctly show "Not Required" and only Pumping visits are fileable + flagged.

This is the clean version of the "it's per-visit, not by service type" option Fred deferred on 2026-06-02.
