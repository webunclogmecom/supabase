# GDO backfill — fill the FP "Permit Number" links (2026-07-08)

Fred: find every client missing their GDO in the DB, run the GDO bot to get it, save it so the
Field Portal's Permit Number → GDO-document link works. FP reads `customer.permits`, whose
`permit_url` **is** `gdos.permit_document_path` — so the work is entirely on `public.gdos` +
the public `gdo-permits` bucket. Start state: **175 ACTIVE gdos / 134 with a permit PDF**.
End state: **182 ACTIVE / 160 with a working canonical PDF link. Zero orphaned paths.**

## Gap A — ACTIVE rows missing the PDF (41 → 0 actionable)

- **18 rows with real GDO numbers** → `scripts/sync/cron_gdo_permit_pdf_ingest.js --apply`
  resolved all 18 from the bot JSONs + live DERM case-number lookup, uploaded to
  `gdo-permits/gdo/<GDO>.pdf`, linked. 0 errors.
- **16 rows (June AT-ingest wave) stored ABSOLUTE stecmrerportal blob URLs** instead of bucket
  paths — flagged by the ingest script's orphan check. All 16 downloaded + normalized into the
  bucket (`scripts/probes/normalize_external_gdo_pdf_paths.js`, re-runnable; backup
  `backups/2026-07-08_gdo_external_paths_backup.json`). External DERM URLs can rot; canonical
  paths can't.
- The remaining 23 were placeholders ("Not available"/"Needs review") → part of Gap B.

## Gap B — clients with NO usable GDO row (62 searched)

62 Dade ACTIVE/RECURRING clients had no ACTIVE real-numbered gdos row (44 no row at all + 18
placeholder-only). Method: DERM `api-ecmrer` operating-permit search by house#+zip AND by
facility name (404 distinct candidate permits) → **57-agent adjudication workflow** applying the
2026-06-28 reconciliation rules (permits are location-bound; judge by FULL address; stale index
names belong; house-number coincidences don't; the PDF is truth) → **adversarial skeptic
re-verified every FOUND independently** (re-fetched the PDF, re-read the printed address, DB
cross-checked the number). 13 FOUND (all upheld, high confidence), 44 NO_PERMIT, 0 uncertain.

### Written (9 clients + 1 demote — backup `backups/2026-07-08_gdo_gap_b_backup.json`)

| Client | GDO | Exp | Max freq | How written |
|---|---|---|---|---|
| 140-TYO | GDO-09027 | 2025-12-31 | 30d | ACTIVE placeholder updated in place |
| 210-KAY | GDO-06685 | 2026-12-31 | 60d | existing INACTIVE row reactivated |
| 211-TRE | GDO-07330 | 2026-12-31 | 30d | insert |
| 231-CHE | GDO-11264 | 2026-12-31 | 90d | insert; **gdos id 23 (138-ASW, same number) demoted** — the 2026 PDF names Cheesesteak For Sale LLC at 1522 Washington Ave; 138-ASW is the prior tenant (client already INACTIVE) |
| 236-LOU | GDO-11696 | 2026-12-31 | 60d | insert |
| 239-COM | GDO-07617 | 2026-12-31 | 30d | insert |
| 241-WYN | GDO-16146 | 2026-12-31 | 60d | insert — PDF matches the exact unit (127 NW 27 St #105, "PARIPARI" = location-bound name) |
| 246-LOUI | GDO-12656 | 2026-12-31 | 60d | insert |
| 261-LC | GDO-05216 | 2025-12-31 | 90d | insert (2025 permit is the newest on file) |

All 9 PDFs ingested to the bucket + linked; verified rendering in `customer.permits`
(permit_number + frequency + permit_url) and serving publicly (200 application/pdf).

### Held for Fred (found but NOT written)

| Client | Found | Why held |
|---|---|---|
| 036-LG | GDO-12484 (exp **2019**, 90d) | newest doc on file is 7 years old — location's case exists, no current permit indexed |
| 058-SOH | GDO-01179 (exp **2011**) | 15 years stale; the same number already sits INACTIVE on 058-SOH (id 126) |
| 193-FRK | GDO-01861 (exp **2009**) | 17 years stale |
| 057-BAY | **PSO-00025** (exp 2019) | not a GDO — a Private Sanitary Sewer operating permit (client is a lift station); `customer.permits` labels everything "Grease Trap", so storing a PSO there is Fred's call |

### No permit exists in DERM (44 + 5 with zero search hits)

Adjudicated NO_PERMIT (address searched, candidates all rejected as different locations):
015-FLA, 027-HER, 061-TCE, 087-BB, 119-ME, 120-DVR, 125-EI, 126-YM, 167-FEN, 201-ALA, 204-JCC,
223-CHA, 233-AH, 234-PV, 247-EC, 248-BPM, 250-LP, 251-AS, 252-OAU, 253-CG, 254-LB, 255-ACS,
257-ERI, 258-PIO, 259-RH, 262-JM, 263-LF, 264-HW, 265-MM, 266-S1G, 268-BE, 269-SB, 270-T4A,
271-MLN, 272-1265, 273-YMB, 274-CEV, 275-MLP, 276-BRC, 278-BHC, 280-AN, 281-MA, 282-GP, 777-YA.
Zero DERM hits at all: 121-FRO, 142-57, 191-TEN, 232-AC, 285-NAH.
Mostly the new 247–285 client wave — plausibly never permitted (or Broward-side operations).
These are the real compliance follow-up: they may need to APPLY for a GDO, not just find one.

## Files

- Detailed per-client verdicts + candidate sets (contain client addresses — **kept local, NOT in
  this public repo**): `Slack/GDO Bot/_gap_b_verdicts_2026-07-08.json` + `_gap_b_candidates_2026-07-08.json`
- Scripts: `scripts/sync/cron_gdo_permit_pdf_ingest.js` (existing, re-run),
  `scripts/probes/normalize_external_gdo_pdf_paths.js` (new, re-runnable)
- Backups: `backups/2026-07-08_gdo_external_paths_backup.json`, `backups/2026-07-08_gdo_gap_b_backup.json`

All gdos writes audited (`audit_gdos`), soft-status only, idempotent/guarded. No schema changes.
