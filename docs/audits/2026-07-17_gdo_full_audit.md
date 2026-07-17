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

## Part 3 — PDF verification sweep (in progress)

Every distinct valid GDO number on an ACTIVE row → newest OPERATING PERMIT from DERM
(`api-ecmrer.miamidade.gov/derm/documents`, case-number exact-match on digits) → PDF downloaded +
text-extracted → `Permit Issued To` / `Facility Location` compared to the client's full address;
non-exact cases adversarially adjudicated; TIF-only old permits (pypdf can't read) → OCR / the
Slack `@GDO` bot (one thread per client). Results land in this doc when the sweep completes.

Already settled by tonight's fresh reads:
- **GDO-000313 → 060-TU Talmudic** ✓ (current 2026 permit names TALMUDIC COLLEGE @ 4000 ALTON RD;
  DERM's index name "IHOP #36-131" is the stale prior tenant — the June "needs human" is resolved)
- **GDO-013076 ≠ 060-TU** ✗ (PIOLI FAMOSI PER LA PIZZA @ 4000 COLLINS AVE — house-number coincidence)
- **227-PER: keep GDO-03342, drop 02079** (Yan-confirmed; 02079 = Granier Bakery @ 18230 Collins)
- **148-MOR: both permits legit** (Yan-confirmed)
- **132-PUM: GDO-000951 = GDO-00951 typo dup** (permit PDFs zero-pad to 6 digits; compare on digits)

## Open items

- [ ] PDF sweep results + adjudications (Part 3 completion)
- [ ] 114-CI GDO-05104 — old TIF permit (ANGELOS PIZZARAUNTE, exp 2007): 07-09 sweep said it IS at
      3155 NE 163 St; the GDO bot (07-17, Yan's thread) couldn't confirm the house number in any PDF.
      OCR or bot-thread adjudication required; candidate for "no current permit — compliance issue/lead".
- [ ] Wynd 27/28 + tenants: who holds GDO-16146; do tenants have own permits (Fred's explainer awaited)
- [ ] 138-ASW vs 231-CHE — who is at 1522 Washington Ave (GDO-11264)
- [ ] **Airtable corrections for Diego/the office** (28 wrong numbers + 227-PER→GDO-03342 + the
      Casa Neos combined-string convention) — Fred to authorize me applying them via the Airtable MCP,
      or hand the list to the office. Until then the DB guard holds the line.
