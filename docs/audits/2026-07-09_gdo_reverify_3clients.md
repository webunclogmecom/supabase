# GDO re-verify — 037-LB / 201-ALA / 233-AH (2026-07-09)

Fred asked to run a GDO lookup for 3 Miami-Dade clients "with no `gdos` row but should (Dade, active
SA)". **The premise was wrong for all three** — each already had a `gdos` row, and each had been
**DEMOTED** by an earlier (May/June) house-number-only re-audit. Re-searching DERM `api-ecmrer` and
reading each candidate permit PDF's **printed `Facility Location`** (the ground truth — the search index
only carries house# + zip, which does NOT distinguish streets/units that share them) showed **2 of the 3
demotions were FALSE**.

Method: for each client, DERM search by house+zip / street+zip / facility-name (2020-floor + no-date),
dedup by case number, download every candidate PDF, extract `Permit No` / `Permit Issued To` /
`Facility Location` / validity / frequency, and adjudicate by the location-bound rule (permit belongs to
the physical unit; same-exact-address name-mismatch still BELONGS; different STREET or house# or UNIT =
reject). Every verdict was re-checked by an independent **adversarial skeptic** (workflow
`wf_1c61c8b6-ced`) that re-searched from the address and re-read the PDFs.

## Findings + writes

| Client | Status | Row | GDO | Verdict | Action |
|---|---|---|---|---|---|
| **037-LB** Le Basilic | INACTIVE | 89 | GDO-11230 | Demotion **FALSE** — GDO-11230 PDF prints `1801 WEST AVE` (holder now **MOLOKO S B LLC**, valid 2026, 90d). The demotion confused it with `1801 COLLINS AVE` (Shelborne/PAULINE=GDO-16296) which shares house#1801+zip33139. `1801 PURDY AVE` (SARDINIA=GDO-05138) also shares them. Location-bound → belongs; Le Basilic is the prior/inactive tenant. | **Refreshed row 89**: `permit_expiration` 2025-12-31→**2026-12-31**, `max_frequency_days` null→**90**, correction note appended. (PDF path already present.) |
| **201-ALA** Aladdin Mediterranean food | RECURRING | 121 | GDO-11308 | Demotion **FALSE** — GDO-11308 PDF prints `Issued To: ALADDIN MARKET & FOOD, INC.` at `20 NE 167 ST` (name **and** address match). The demotion's "belongs to U GAS / GDO-11629" is wrong (U GAS is at 15200 NE 6 Ave); McDonald's GDO-01181 is at house# **200** NE 167 St. **⚠ Permit EXPIRED 2018-12-31**, no renewal indexed since. | **Completed row 121**: INACTIVE→**ACTIVE**, `permit_expiration`=**2018-12-31**, `client_location_id`=307, **ingested the PDF** (`gdo/GDO-11308.pdf`, serves 200). Now surfaces in `customer.permits` for FP. **Compliance: needs renewal.** |
| **233-AH** Aloft hotels | ACTIVE | 189 | GDO-15303 | Demotion **CORRECT** — GDO-15303 PDF is `LUCCIANO'S USN 6, LLC` at `2920 NE 207 ST (106-B)` (ice cream, expired 2024), a different UNIT. The building's only other GDO, **GDO-11696** (`SKINNY LOUIE`, 106-A), already belongs to **236-LOU**. Aloft (the hotel) has **no GDO of its own**. | **No change** (row 189 correctly INACTIVE/demoted). Aloft must apply if it operates a FOG device. |

All writes idempotent + guarded (`WHERE id=… AND gdo_number=…`), audited (`audit.logs`, rows 89+121),
notes append-only (prior demotion notes preserved for the trail). Backup:
`backups/2026-07-09_gdo_reverify_before.json`. End state: **182 ACTIVE gdos** (201-ALA's row flipped
INACTIVE→ACTIVE; the count net-changes by +1).

## ⚠ Broader lead — the demotions are systemically suspect

**88 `gdos` rows carry a "DEMOTED" note; ~18 mention house-number matching.** The 2 false demotions here
both came from that same house-number-only method. **~8 demoted-INACTIVE rows with a real `GDO-#####`
number sit on ACTIVE/RECURRING clients** and warrant the same PDF-address re-verification: 025-GRO
(GDO-04943), 036-LG (GDO-11708), 045-NU (GDO-07733), 114-CI (GDO-05104), 155-PV (GDO-10891), 170-PV
(GDO-14681), 175-PV (GDO-11228), 241-WYN (GDO-13814). (233-AH/GDO-15303 was demoted correctly, so not all
demotions are wrong — each must be checked against its PDF's printed `Facility Location`.)

Tooling used (re-runnable): the standalone lookup replicates `Slack/DERM/mcp_derm_lookup/server.py`
(DERM `api-ecmrer` cascade + pypdf extraction). See memory [[feedback_gdo_name_match_required]].
