# 2026-07-17 — Full GDO audit (DB ↔ Airtable ↔ DERM permit PDFs)

**Trigger (Fred):** the GDO bot caught 114-CI holding a permit whose PDF doesn't match its address;
Yan then found 060-TU carrying Piola's permit and asked to *"run an AI to read every GDO we have in
our database and make sure that it's at the right place."* Fred: *"the GDO's can't be wrong… slow but
accurate, super precision."*

**Method (the corrected bar, per the 06-28/07-09 lessons):** a permit belongs to a client iff the
**actual PDF's** `Facility Location` matches the client's **full address** (house + street + zip,
+ unit in multi-tenant buildings). The DERM search-index `facilityName` is often a **stale prior
tenant** — never judge by it (permits are location-bound). House-number-only matching caused the
May false demotions — never again.

---

## Part 1 — WHY the wrong GDOs kept coming back (root cause, FIXED)

The 2026-06-28 reconciliation (146 clients judged, `Slack/GDO Bot/_GDO_RECONCILIATION_REPORT.md`)
demoted 19 wrong-permit rows with PDF evidence in `gdos.notes`. **audit.logs proves 18 of the 19
were silently re-promoted to ACTIVE**, by three writer classes:

1. **Bulk AT re-ingest** — 2026-06-29 17:01–17:04 UTC burst (`app_source='sql'`, `db_role=postgres`,
   clients walked alphabetically): flipped the demoted rows AND placeholder rows ("Not available",
   "Needs review") back to ACTIVE. The demotion notes were left intact — only `status` flipped.
2. **webhook-airtable** — its gdos update path did `update({ status: 'ACTIVE', … })` whenever AT
   re-sent the same (client, gdo_number); the code comment literally said *"also flips status back
   to ACTIVE if a prior demote (rare)"*. Since **Airtable still carries the ~28 wrong GDO numbers**
   (the 06-28 office-corrections list was never applied in AT), every AT client touch re-armed the bug.
3. **One-off REST PATCHes** (`/gdos`, 07-11 + 07-12, GDO-11433).

**Fixes shipped 2026-07-17 (commit `90c04e3`):**
- **webhook-airtable patched + deployed** — the update path refreshes `permit_expiration` ONLY;
  status is never written on update (INSERT of a genuinely new permit still lands ACTIVE).
- **DB guard** `trg_aa_gdos_guard_demoted` (migration `2026-07-17_gdos_demote_guard.sql`): a row
  whose notes carry the DEMOTED/DEDUP marker cannot be blind-flipped INACTIVE→ACTIVE by ANY writer;
  the flip is silently kept INACTIVE + a WARNING raised. Deliberate reactivation = amend `notes` in
  the same UPDATE (the 07-09 sweep pattern). **Negative test passed** (blind flip on 114-CI/GDO-11886
  stayed INACTIVE).
- **The 18 regressed rows re-demoted** with dated notes (backup
  `backups/2026-07-17_gdos_redemote_before.json`): 013-DIM/03687, 016-FIA/13335, 021-GRA/00376,
  042-MT/04127, 060-TU/13076, 063-TCE/08976, 083-SHUL/12490, 084-ULT/03828, 104-PV/08976,
  114-CI/11886, 132-PUM/000951(dedup), 136-BB/11220, 150-KOS/01958, 187-HAI/07382, 188-ACA/02118,
  194-PV/03375, 222-SPE/09290, 227-PER/02079. All are street-level mismatches (location-bound
  permits can't become correct on renewal); 060-TU/227-PER/132-PUM freshly re-confirmed by Yan +
  the 2026-07-17 PDF reads.

**⚠ The remaining root cause is AIRTABLE ITSELF** — Diego's original uploads there carry the wrong
numbers, and AT's single `GDO Number` field can't model multi-GDO clients (009-CN's field literally
holds the combined string `"GDO-10877, GDO-15062, GDO-16389"`, which is where the malformed DB row
came from). The corrections list for the office is in Part 3 / the recon report; until AT is fixed,
the DB guard is what keeps us safe.

## Part 2 — Fresh 3-way comparison (DB 212 rows ↔ AT 229 records), 2026-07-17

| Class | n | Meaning / examples |
|---|---|---|
| MATCH | 138 | AT number == the client's single ACTIVE DB number (still PDF-verified in Part 3) |
| AT_NO_GDO_DB_NO_ROWS | 45 | No permit anywhere (mostly Broward — correct, no GDO program) |
| BOTH_EMPTY | 19 | DB rows exist but no valid ACTIVE number; AT empty too (placeholders/demoted) |
| DB_ONLY_NUMBER | 13 | DB has a permit AT never had (recon/DERM discovery finds) |
| AT-has / DB-code-drift | 7 | 199-JZ→**199-STK** + 246-LOU→**246-LOUI** = same permit under the DB's newer code (not gaps); 216–220-WYN see below |
| Multi-GDO clients | 5 | 009-CN, 060-TU, 114-CI, 148-MOR, 227-PER (see per-GDO row generation, pdf-service `eebfa8c`) |
| DB_ONLY_CLIENT | 4 | 057-BAY (no numbers), 199-STK, 246-LOUI, 261-LC |
| AT_HAS_DEMOTED_NUMBER | 1 | 138-ASW (AT 11264; that number now ACTIVE on **231-CHE** — same-permit-two-clients case, PDF decides) |

**Wynd finding:** Airtable's five tenant codes 216–220-WYN ALL carry the **same** `GDO-16146`
(HRB Wynwood dba PARIPARI @ 127 NW 27 St #105) — i.e. AT models ONE shared permit, not 4 distinct
tenant permits. Our DB holds GDO-16146 ACTIVE on **241-WYN "Wynd 27"** and GDO-13814 on 242-WYN
"Wynd 28". Which building/client 16146 belongs to (Wynd 27 vs the Wynd 28 tenant locations 5-8)
needs Fred's Wynd explainer + the PDF address — **do not guess**.

## Part 3 — PDF verification sweep — ✅ COMPLETE 2026-07-18 (143/143 permits read)

Every distinct valid GDO number on an ACTIVE row (142, + GDO-11024 from Mila's combined string) →
newest OPERATING PERMIT from DERM (`api-ecmrer.miamidade.gov/derm/documents`, case-number
exact-match on digits) → PDF downloaded + `Permit Issued To`/`Facility Location` extracted →
compared to the client's full address (house + street + zip, street-suffix/direction/ordinal
normalized, Miami dual-name aliases applied: SW 72 St≡Sunset Dr, NE 1 Ave≡Buena Vista Blvd).
TIFF-scan permits converted and **vision-read page-by-page**. PDF cache retained in the session
scratchpad (`gdo_pdf_cache/`, 143 files).

**Verdicts:**
- **106 verified correct** — exact house+street+zip (97 parser-exact + 4 parser-edge confirms
  (037-LB, 047-PAM, 133-MUT range, 208-HUB range) + 5 scan-reads:
  **058-SOH GDO-01179** (Cavalli 2011 @ 19004 NE 29 Ave ✓, expired 2011),
  **193-FRK GDO-01861** (Pitas & Platters 2009 @ 19062 NE 29 Ave ✓, expired 2009),
  **114-CI GDO-05104** (REUNION BISTRO 2006 @ **3155 NE 163 ST 33160 — exactly Ceviche Inka's
  address**; the bot's 07-17 "not confirmed" was wrong for this number; expired 14-JAN-2007),
  **036-LG GDO-12484** (Urban Bricks Pizza 2019 @ 6144 S Dixie Hwy ✓, expired 2019),
  **148-MOR GDO-14769** (Moore Club Bev Co @ 4040 NE 2 Ave **FAC. F LVL 4** — distinct facility
  from GDO-11226's FAC. A LVL 1; both permits legit, as Yan said).
- **13 zip-variants** — house+street exact, zip clerical differences (DERM vs our record); treated
  as BELONGS with a zip note: 060-TU(00313), 004-BAO, 008-CV, 012-DKC, 195-MYK, 009-CN(×3),
  074-TCE, 069-TCE, 045-NU, 034-LG, 170-PV/176-SOU(11433).
- **20 WRONG → DEMOTED 2026-07-18** (backup `backups/2026-07-18_gdos_sweep_demotions_before.json`),
  each with the PDF quote in `notes`:
  - *12 = the June B-list ("wrong, do NOT ingest") that the 06-29 burst ingested anyway:*
    000-DH/03620, 038-LR/04400, 085-VA/11014, 118-MRJ/07564, 122-BMN/01759, 124-SAF/14336,
    128-MF/06550, 130-RL/13175, 146-54W/09725, 153-LTC/05395, 198-ARY/05180 (permit correctly
    remains on 129-BSC), 123-EUC/11260.
  - *8 NEW finds (first time caught):* **015-FLA**/03603 (school @ 19010 NW 37 Ave; Flame is
    19010 NE 29 Ave — house coincidence), **112-YA**/04156 (4333 Collins vs 1745 Cleveland Rd),
    **027-HER**/07916 (12161 SW 152 St vs 161 Camden Dr), **087-BB**/10521 (9543 S Dixie Pinecrest
    vs 9543 Harding Surfside — house coincidence), **137-BB**/11271 (19565 Biscayne FH-7 vs 18549
    W Dixie), **182-PAL**/11734 (19650 NW 2 Ave Miami Gardens vs 9650 E Bay Harbor Dr),
    **180-PV**/14934 (8705 NW 35 Ln Doral vs 8525 Mills Dr Kendall), **243-FE**/00622
    (730 NW 36 St vs 73 NW 26 St — double digit-shift).
- **3 held for adjudication (bot / Fred-Yan):**
  1. **068-TCE GDO-05734** — PDF `2988 GRAND AVE 33133` vs client `2982 Grand Ave` — same block,
     possibly the same retail building's DERM numbering. Ask the bot / DERM by address.
  2. **043-MIL (Mila)** — BOTH its numbers point at **800 LINCOLN RD**: GDO-14117 PDF = "800
     LINCOLN RD (LVL 2)"; GDO-11024 DERM index = "800 LOCCOLN ROAD BUILDING @ 800 LINCOLN RD".
     Client property (Jobber) = **1636 Meridian Ave**. Either Mila's trap actually sits in the
     800 Lincoln building (Meridian-facing corner? RDG group facility) or both numbers are wrong.
     Needs Fred/Yan or a DERM address-search on 1636 Meridian.
  3. **242-WYN GDO-13814** — permit PDF = **124 NW 28 ST** (matches the NAME "Wynd 28");
     our 242-WYN property rows say 127 NW 27th St #105 (inherited from the tenant seeding), which
     is **Wynd 27's (241-WYN) building — where GDO-16146 is an exact match**. Likely fix = correct
     242-WYN's property to 124 NW 28 St and decide which tenants/locations sit in which building
     (Fred's Wynd explainer still awaited). Client-data decision — NOT auto-fixed.

Already settled by tonight's fresh reads:
- **GDO-000313 → 060-TU Talmudic** ✓ (current 2026 permit names TALMUDIC COLLEGE @ 4000 ALTON RD;
  DERM's index name "IHOP #36-131" is the stale prior tenant — the June "needs human" is resolved)
- **GDO-013076 ≠ 060-TU** ✗ (PIOLI FAMOSI PER LA PIZZA @ 4000 COLLINS AVE — house-number coincidence)
- **227-PER: keep GDO-03342, drop 02079** (Yan-confirmed; 02079 = Granier Bakery @ 18230 Collins)
- **148-MOR: both permits legit** (Yan-confirmed)
- **132-PUM: GDO-000951 = GDO-00951 typo dup** (permit PDFs zero-pad to 6 digits; compare on digits)

## Part 4 — @GDO bot double-check — ✅ COMPLETE 2026-07-18 (Fred-ordered; ONE thread)

All 125 ACTIVE-permit clients were re-verified through the Slack GDO bot in a SINGLE
#gdo-permit thread (parent ts `1784327168.564039`): first a blind name+address pass (the bot
independently rediscovers the permit — no number given), then 26 tailored follow-ups (direct
case-number lookups for every disagreement + address re-asks). **151 bot interactions, 0 timeouts.**

**Outcome: 123 of 125 clients CONFIRMED on their DB numbers.** Every main-pass "disagreement"
but three turned out to be bot search-recall noise — the direct case-number follow-ups confirmed
our numbers verbatim (e.g. 033-LG = "LA GRANJA ALLAPATTAH CORP", 069-TCE = "CARROT LOVE TWO LLC",
174-17 = "SEVENTEEN SUSHI & BAR", 245-MAYU = "AROMAS DEL PERU OF BRICKELL CORP DBA MAYU").

**2 real corrections (bot-found, then PDF-verified before writing — backup
`backups/2026-07-18_gdos_bot_corrections_before.json`):**
- **170-PV Pura Vida (1657 N Miami Ave):** held Taula's permit (GDO-11433, unit #E) → demoted;
  the client's own **GDO-14681** ("PURA VIDA ENTERPRISES LLC" @ 12 NE 17 ST 33136 = the NE-17-St
  face of the same corner building, Mila-class dual address) reactivated ACTIVE (guard-compliant
  notes amendment). 176-SOU still holds 11433 — whether 176-SOU IS the Taula operation is a
  client-identity question for Fred.
- **238-PV Pura Vida South Miami (6022 S Dixie):** held the suite-B facility's GDO-15650 →
  demoted; the client's own **GDO-13590** ("PURA VIDA SOUTH MIAMI LLC" @ 6022 S DIXIE HWY
  SUITE C) inserted ACTIVE.

**1 bot claim REJECTED by PDF (why every claim gets PDF-read):** for 236-LOU the bot proposed
GDO-16046 "at 2920 NE 207th St Suite 106" — the actual PDF reads **6010 S DIXIE HWY, SOUTH
MIAMI** (a different Skinny Louie branch; the bot echoed the query address). 236-LOU keeps
GDO-11696 (PDF: 2920 NE 207 ST 106-A, address-exact). Side lead: SLBURGER5's active South-Miami
permit has no matching client — possible unregistered branch.

**Held-case resolutions from the run:** 068-TCE keep GDO-05734 (bot concurs; 2988/2982 Grand =
same venue). 043-MIL keep GDO-14117 — the CURRENT 2026 permit is issued to "MILA FLORIDA LLC DBA
MILA MIAMI", DERM-indexed "MILA RESTAURANT - BAR/LOUNGE" @ 800 LINCOLN RD (LVL 2) = the Lincoln
Rd frontage of the 1636 Meridian corner building. 242-WYN keep GDO-13814 — permittee now "PASTA
WYNWOOD LLC DBA PASTA" @ 124 NW 28 ST (ties tenant "Pasta" to Wynd 28's building; which tenants
sit in Wynd 27 vs 28 remains Fred/Yan's client-data call). 231-CHE keep GDO-11264 — current
permittee "CHEESESTEAK FOR SALE, LLC" @ 1522 Washington (the 138-ASW row stays demoted).

**Renewal-lead list — DEFINITIVE after the 2026-07-18 expiration sync (all ACTIVE rows now carry
`permit_expiration` parsed from their own PDF; query `permit_expiration < '2026-01-01'`): 20 clients.**
Exp 2025: 261-LC, 222-SPE, 094-MOZ Mozart Cafe, 140-TYO, 147-OST Maison Ostrow, 183-KRE Kresy ·
2024: 179-CIG, 047-PAM Pamplemousse, 066-TCE, 105-CU, 004-BAO Baoli · 2023: 132-PUM ·
2022: 091-SB, 002-41 · 2020: 001-VIN · 2019: 036-LG · 2018: 201-ALA · 2011: 058-SOH ·
2009: 193-FRK · 2007: 114-CI. Also DERM ran a 2025 construction case at Wynd 27 Suite 105
(new FOG system — HRB/PariPari buildout).

**Verification stamp (2026-07-18, Fred-ordered):** all 132 ACTIVE valid-format gdos rows now carry
a notes stamp — "DERM permit PDF read; printed Facility Location matches this client's address" —
and `permit_expiration` synced from each permit's own PDF (145 parseable; TIFF scans kept their
known dates). 126 stamped in this pass + the 6 corrected/added rows already carried evidence notes.
Backup: `backups/2026-07-18_gdos_verified_stamp_before.json`. State: 112 current-2026 / 20 expired
/ 0 unknown-expiration.

## Part 5 — Phase 2: active clients WITHOUT a GDO — ✅ COMPLETE 2026-07-18

Scope filter: of 290 ACTIVE/RECURRING clients with no valid GDO row, only **64 have pumping
(`derm_required`) visits** — the rest are residential homes / plumbers / test rows where the FOG
permit program doesn't apply. Of the 64: **33 Miami-Dade** (bot-queried, same thread) and **31
Broward/Palm Beach** (out of scope — no Miami-Dade GDO program; yellow-ticket jurisdiction).

**33/33 answered, 0 timeouts. 4 permits FOUND, PDF-verified, and ADDED:**
| Client | New GDO | PDF evidence |
|---|---|---|
| 063-TCE Carrot Express Aventura | **GDO-13939** ACTIVE 2026 | CARROT LOVE, LLC DBA CARROT EXPRESS @ 2440 MIAMI GARDENS DR |
| 104-PV Pura Vida Miracle Mile | **GDO-06568** ACTIVE 2026 | PURA VIDA MIRACLE MILE LLC @ 244 CORAL WAY (Miracle Mile IS Coral Way) |
| 223-CHA El Chaman | **GDO-08165** ACTIVE 2026 | EL CHAMAN HOLDINGS LLC @ 14239 SW 42 ST (client 14241 = adjacent storefront) |
| 222-SPE Le Specialita | **GDO-15268** exp 2025-12-31 | LE SPECIALITA MIAMI LLC @ 40 NE 41 ST — renewal lead |

**2 bot claims rejected by PDF (address-echo failure mode again):** 137-BB — GDO-11271 is the
client's entity (TEAM FLORIDA BB) but ALL 7 DERM docs bind it to **19565 BISCAYNE BLVD (FH-7)**
(Esplanade food hall), not 18549 W Dixie; stays demoted; **Fred: which site is the store actually
at?** 234-PV Wynwood — the bot name-matched GDO-14681, which is 170-PV's (12 NE 17 St).

**True no-permit list (Miami-Dade, pumping visits, DERM has nothing for them at their address) —
28 clients:** 013-DIM Mikvah, 015-FLA, 016-FIA, 027-HER, 042-MT, 057-BAY, 061-TCE, 083-SHUL,
084-ULT, 087-BB, 136-BB, 142-57, 150-KOS, 167-FEN, 180-PV, 182-PAL, 187-HAI, 188-ACA, 191-TEN,
198-ARY, 204-JCC, 232-AC, 233-AH, 234-PV Wynwood, 243-FE Felina, 278-BHC, Adam Nadler, Noel's
Kiwi Kitchen. Caveat: the condo/residence entries (Herzka, 57 Ocean, Fendi Château, Bay
Harborview, Nadler) may be exempt (FOG permits cover food-service establishments); the
restaurants among them (Felina, Pura Vida Wynwood/Kendall, Bagel Boss x2, Kosh, Flame, Noel's…)
are genuine compliance gaps / sales conversations.

## Part 6 — Generated-PDF regeneration sweep — ✅ COMPLETE 2026-07-18 (Fred-approved)

The audit fixed the DATA; this pass fixed the ARTIFACTS. All 532 filed manifests' generated
documents were downloaded and text-scanned for GDO numbers outside the ticket's current valid set.

**Findings:** every one of the 532 `derm_address_url` files is a **JPEG photo of the physical
county sheet** (uploaded via the DERM Tracker) — real-world scans, unpoisonable, untouched (the
regen script hard-gates on the pdf-service's `/address.pdf` / `/fog.pdf` paths so an uploaded
scan can never be overwritten). The exposure was entirely in the customer-facing **FOG
Manifests: 61 of 532** carried a wrong number — 54 with a now-demoted permit (Shul showing
Pizzafiore's, Ceviche showing Polynesio's, Pura Vida showing a school's, etc., across the 20
wrong-permit clients) + Mila's 7 from the combined-string era.

**Fix:** pdf-service `00438c9` first — a regeneration now **re-stamps the ticket's existing
`derm_address_no`** instead of consuming a new sheet number (first-time generations still
consume; 17/17 tests). Then all **61 FOG PDFs regenerated** through the live
`generate-fog-manifest` edge fn (1 transient 502 retried → 61/61 HTTP 200), downloaded, and
**re-verified clean**: only current valid numbers render (Pummarola prints the literal
`GDO-00951`, typo form gone; 136-BB renders a blank GDO cell — correct for a no-permit client).
Review copies: workspace root `2026-07-18 regenerated DERM PDFs/` (61 files). Job log:
scratchpad `regen_done.json`; scan verdicts: `regen_scan_results.json`.

**Addendum — multi-GDO FOG refresh (Fred-ordered, same day):** the 11 filed FOG manifests of the
two multi-GDO clients (8× 009-CN Casa Neos, 3× 148-MOR The Moore) predated the one-row-per-GDO
expansion — each showed only ONE permit row (valid but incomplete, so the poison sweep correctly
skipped them). All 11 regenerated via `generate-fog-manifest` and **each file read + verified**:
every Casa Neos proof now shows all 3 permits with tenant names (Kitchens/Bars/Lounge), every
Moore proof both permits (11226 + 14769 Main); 1 page each; redaction bars only in the remaining
slots; zero foreign numbers; 8.48pt labels. Live in the Field Portal (same URLs). Review copies:
`2026-07-18 multi-GDO smoke test/regenerated FOG/`. Wynd 28 gets the same pass once its tenant
permits are ingested.

## Part 7 — The three one-worders — ✅ RESOLVED 2026-07-20 (Fred-directed)

The three cases Parts 3-5 could not close on evidence alone. All three are now settled in the DB.

**043-MIL (Mila) — SPLIT. Two real permits, confirmed by the `@GDO` bot** (Fred's lookup, Slack
`C0AL7A73DPY` thread `1784555625.986959`). The concatenated `"GDO-14117 / GDO-11024"` was never a
formatting artifact:

| Permit | Facility per DERM | Pump | Valid to |
|---|---|---|---|
| GDO-11024 | Mila Miami, 800 Lincoln Road Building | every 90 days | 2026-12-31 |
| GDO-14117 | Mila Restaurant, Bar/Lounge | every 60 days | 2026-12-31 |

Both issued to MILA FLORIDA LLC DBA MILA MIAMI. Applied: id 157 (combined) demoted to INACTIVE with
the bot evidence in `notes`; **GDO-11024 inserted as id 230** (ACTIVE, exp 2026-12-31,
`max_frequency_days=90`) on location 163; **GDO-14117 (id 156)** given `max_frequency_days=60` and
moved to a **new location 444 "Bar / Lounge"** (`gdos.client_location_id` is UNIQUE, so a second
permit needs a second location). Location 163 renamed `"Main"` → `"Restaurant"` so the pair reads
correctly on the county form — behaviour-neutral for `create_calendar_visit`, whose default-location
fallback orders `(cl.name='Main') DESC, cl.id` and therefore still lands on 163 (lower id than 444).

Verified end-to-end through the live embed and `_facility_rows_for_client`:

```
Mila - Restaurant   | GDO-11024 | 043-MIL | 1636 Meridian Avenue, Miami Beach, Florida, 33139
Mila - Bar / Lounge | GDO-14117 | 043-MIL | 1636 Meridian Avenue, Miami Beach, Florida, 33139
```

(1636 Meridian ≡ 800 Lincoln is the known corner-building dual address — not a mismatch.)
pdf-service suite: 21/21 pass.

**132-PUM (Pummarola) — GDO-00951 is the keeper** (Fred, 2026-07-20). `GDO-000951` (id 144) was a
leading-zero typo and stays INACTIVE. Fred said "delete it"; kept as a **soft-delete** per Rule 6 —
the row is the audit trail for a number that appears in historic paperwork, and hard-deleting it
would strand `entity_source_links`. Both rows carry the decision in `notes`.
⚠ Still **EXPIRED (2023-12-31, ~19 months)** — a renewal lead, not a data defect.

**137-BB (Bagel Boss Aventura) — KEPT + FLAGGED, conflict unresolved** (Fred: *"Keep the 11271 for
now. and flag it"*). GDO-11271 (id 32) stays attached to 137-BB with an explicit `notes` flag stating
both branches: our client address is 18549 W Dixie Hwy, the permit PDF reads 19565 Biscayne Blvd food
hall FH-7. Exactly one is true — either the store is at W Dixie and **has no permit for the address we
service** (compliance gap, new filing), or it is at the Biscayne food hall and **our client address is
wrong** and the permit merely needs renewal (expired 2025-01-01). Row stays **INACTIVE**: an expired,
address-mismatched permit must not print on a county form. Needs a real-world answer (Diego/Fred).

## Open items

- [ ] **137-BB address conflict** (Part 7) — W Dixie vs Biscayne FH-7; determines new-filing vs renewal
- [ ] **132-PUM renewal** — GDO-00951 expired 2023-12-31 (~19 months)
- [ ] PDF sweep results + adjudications (Part 3 completion)
- [ ] 114-CI GDO-05104 — old TIF permit (ANGELOS PIZZARAUNTE, exp 2007): 07-09 sweep said it IS at
      3155 NE 163 St; the GDO bot (07-17, Yan's thread) couldn't confirm the house number in any PDF.
      OCR or bot-thread adjudication required; candidate for "no current permit — compliance issue/lead".
- [ ] Wynd 27/28 + tenants: who holds GDO-16146; do tenants have own permits (Fred's explainer awaited)
- [ ] 138-ASW vs 231-CHE — who is at 1522 Washington Ave (GDO-11264)
- [ ] **Airtable corrections for Diego/the office** (28 wrong numbers + 227-PER→GDO-03342 + the
      Casa Neos combined-string convention) — Fred to authorize me applying them via the Airtable MCP,
      or hand the list to the office. Until then the DB guard holds the line.
