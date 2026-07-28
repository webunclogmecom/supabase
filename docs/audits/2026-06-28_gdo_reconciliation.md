# GDO Reconciliation — DB `gdos` ↔ Airtable ↔ DERM permit PDF (2026-06-28)

Three-way reconciliation of every client's Grease Disposal Operator permit. Sources:
- **DB** `public.gdos` (148 active at start)
- **Airtable** Clients table `GDO Number`/`GDO PDF`/exp/freq (193 clients — the *richer* source)
- **DERM** `api-ecmrer.miamidade.gov/derm/documents` by `caseNumber` → official facility name + address (truth)

**Method:** for all 150 distinct GDO numbers, fetched the DERM record; for the 146 clients with a real permit, a 12-agent workflow judged attribution by **full street address** (house+street+zip+unit), fetching the actual PDF and reading "Permit Issued To"/"Facility Location" for every NO/MAYBE. Result: 116 belong, 29 do not, 1 maybe.

**Key lesson:** the DERM search-index `facilityName` is frequently a **stale prior tenant**; a name mismatch at the same full address is location-bound and BELONGS. The genuine wrong matches are **house-number coincidences on a different street/zip** (e.g. synagogues assigned a public-school permit, Granada Condo assigned McDonald's — both at the same house number on a different street). This corrected three false demotions I made 2026-06-27 (050-PV/190-LOU/202-CAP — their live PDFs name the client itself).

## DB actions applied (all via `gdos`, audited by `audit_gdos`, reversible — INACTIVE never hard-delete)

| Action | Count | Codes |
|---|---|---|
| **Demoted** (wrong, was ACTIVE) | 16 | 013-DIM, 016-FIA, 021-GRA, 036-LG, 042-MT, 063-TCE, 083-SHUL, 084-ULT, 104-PV, 114-CI, 136-BB, 150-KOS, 187-HAI, 188-ACA, 194-PV, 222-SPE |
| **Reactivated** (wrongly demoted 6-27) | 3 | 050-PV, 190-LOU, 202-CAP |
| **Ingested** valid AT permit | 13 | 002-41, 048-PV, 066-TCE, 105-CU, 108-ROA, 113-ORO, 116-HIK, 129-BSC, 138-ASW, 144-LTG, 172-NU, 183-KRE, 200-PALO |
| **Fixed** | 2 | 227-PER (demoted stale GDO-02079, kept correct GDO-03342); 132-PUM (deduped GDO-000951, kept GDO-00951) |

Coverage 128 → **125/204** active clients (removed 16 wrong permits, added/restored 16 correct ones; net reflects clients whose only permit was wrong and has no replacement yet). All 34 changes re-queried + asserted PASS.

## Held for human review
- **060-TU** Talmudic University (AT pizzeria + DB IHOP both at building #4000 different streets — neither names the university)
- **206-CAC** Cacio e Pepe (Biscayne Blvd house matches, DERM zip 33162 vs 33160 — likely clerical)
- **216/217/218/219-WYN** (med-confidence, all share GDO-16146 — confirm same Wynwood/PariPari venue before ingest)

## Airtable side — list handed to Fred, NOT written
28 clients have a wrong GDO Number in Airtable (same house-number coincidence) + 227-PER needs GDO-02079→GDO-03342. 220-WYN/239-COM are Airtable-only (not clients in our DB). Full per-client list with DERM PDF evidence: `Slack/GDO Bot/_GDO_RECONCILIATION_REPORT.md` (kept local — contains client addresses, not committed to this public repo).


## Deep PDF verification — opened all 115 active permit PDFs (2026-06-28)

Downloaded + text-extracted every active permit; a 10-agent workflow address-matched each printed "Facility Location" to the client. Result: **102 CORRECT, 5 genuinely WRONG (demoted), 8 flagged → resolved below.**

**Demoted (mis-bound — a different location/business permit on the wrong client; each has a correct twin or is plainly wrong):**
- 060-TU GDO-13076 → 4000 Collins "Pioli Pizza" (client is Talmudic U, 4000 Alton). Twin GDO-00313 kept.
- 155-PV GDO-10891 → 1601 Collins "Pura Vida Collins/Loews" (client is Bay Rd). Twin GDO-12838 kept.
- 170-PV GDO-14681 → 12 NE 17 St "Pura Vida" (client is 1657 N Miami Ave).
- 175-PV GDO-11228 → 1104 S Miami "Pura Vida Brickell" = the 050-PV permit (client is 701 Brickell). Twin GDO-02560 kept.
- 180-PV GDO-14934 → 8705 NW 35 Ln Doral "Chick-fil-A" (client is Pura Vida Kendall, 8525 Mills Dr).

**Permit BELONGS, but our CLIENT ADDRESS is slightly off (GDO kept active — fix the client address, not the GDO):**
- 043-MIL GDO-14117 — issued to "MILA MIAMI"; permit at 800 Lincoln Rd, DB client addr 1636 Meridian Ave.
- 137-BB GDO-11271 — issued to "BAGEL BOSS OF AVENTURA"; permit 19565 Biscayne, DB addr 18549 W Dixie Hwy.
- 068-TCE GDO-05734 — issued to "CARROT EXPRESS"; permit 2988 Grand Ave, DB addr 2982 (house# off by 6).
- 066-TCE GDO-13822 — same house+zip (3252 / 33137); permit street "NE 1 Ave" vs DB "Buena Vista Blvd" (same corner).
- 176-SOU GDO-11433 — same house+street (1657 N Miami Ave); permit zip 33132/unit #E vs DB 33136/suite a.
- 148-MOR GDO-14769 — scanned-image PDF; DERM index confirms "MOORE @ 4040 2nd Ave 33137" = client. Correct.

**OPEN — needs Fred's call:** 242-WYN GDO-13814 — ingested 2026-06-27 on the stale index name "Wynwood 28 Shell"; the actual PDF is "PASTA WYNWOOD LLC" at 124 NW 28 St, while client "Wynd 28" is at 127 NW 27th St. Different name + address (one block off). Left ACTIVE pending confirmation of Wynd 28's real location/permit.

Active real-permit gdos now: ~110 rows / 105 clients, all either address-matched to their client or flagged above. 22 placeholder ("Not available") rows were demoted separately.
