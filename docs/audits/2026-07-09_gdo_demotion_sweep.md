# GDO demotion sweep — re-verify the DEMOTED rows (2026-07-09)

Follow-up to `2026-07-09_gdo_reverify_3clients.md` (where 2 of 3 demotions were FALSE). Re-verified the
**8 demoted-INACTIVE `public.gdos` rows carrying a real `GDO-#####` on an ACTIVE/RECURRING client** (plus
233-AH, already done). Method: DERM `api-ecmrer` search from each client's primary address + a caseNumber
search for the demoted GDO itself; read every candidate PDF's **printed `Facility Location`** (ground
truth — the index only carries house#+zip). Every non-trivial verdict was re-checked by an independent
**adversarial skeptic** (`wf_1c61c8b6-ced` prior + `wf_ba4cb6c5-3ae` here) — which caught three things my
first pass got wrong.

## Result: 7 of 8 demotions CORRECT, 1 FALSE

| Client | Demoted GDO | Where the demoted GDO actually is (PDF) | Verdict | Client's real permit |
|---|---|---|---|---|
| 025-GRO Grove Kosher | GDO-04943 | old 2015 permit, superseded | ✅ correct | **GDO-13447** ACTIVE (9467 Harding) |
| 036-LG La Granja S. Miami | GDO-11708 | `1901 NE 163 ST` (La Granja NMB) | ✅ correct | GDO-12484 ACTIVE (exp 2019 — old) |
| 045-NU Nu Real Food | GDO-07733 | `266 MIRACLE MILE` (Coral Gables = 172-NU) | ✅ correct | **GDO-11540** ACTIVE (id 58) — its note was FALSE, corrected |
| **114-CI Ceviche Inka** | **GDO-05104** | **`3155 NE 163 ST` = the client's exact address** | ❌ **FALSE demotion** | un-demoted GDO-05104 (see below) |
| 155-PV Pura Vida Flamingo | GDO-10891 | `1601 COLLINS AVE` (Loews) | ✅ correct | GDO-12838 ACTIVE (1504 Bay Rd) |
| 170-PV Pura Vida Bakery | GDO-14681 | `12 NE 17 ST` (Pura Vida Miami) | ✅ correct | **none** (see mis-attribution below) |
| 175-PV Pura Vida Brickell 701 | GDO-11228 | `1104 S MIAMI AVE` (= 050-PV) | ✅ correct | GDO-02560 ACTIVE (701 Brickell) |
| 233-AH Aloft | GDO-15303 | `2920 NE 207 ST (106-B)` Lucciano's | ✅ correct (done 07-09) | none (hotel; must apply) |
| 241-WYN Wynd 27 | GDO-13814 | `124 NW 28 ST` (Pasta = 242-WYN) | ✅ correct | GDO-16146 ACTIVE (127 NW 27 #105) |

So the **2026-06-28 "PDF verify" demotions were all reliable** (the demoted GDO genuinely sits at a
different address/unit, and most clients already hold their correct permit). The lone false demotion,
**114-CI**, came from the same sloppy **2026-05-25 "@GDO bot" house-number-only** method as yesterday's two:
it claimed `3155 NE 163 ST` "belongs to GDO-11886 Polynesio" — but Polynesio is at **`13155 W Okeechobee Rd,
Hialeah Gardens`** (a `3155`/`13155` substring coincidence). GDO-05104 (ANGELOS PIZZARAUNTE → … → Ceviche
Inka) is the unit's permit of record — but **expired ~2007** (TIF images only).

## Writes (idempotent, guarded, audited; backups in `backups/2026-07-09_gdo_*`)

1. **114-CI id 127** — un-demoted GDO-05104: INACTIVE→ACTIVE, `permit_expiration=2007-01-14`, ingested the
   permit TIF (`gdo/GDO-05104.tif`, serves 200), corrected the false Polynesio note. **⚠ expired ~2007 →
   Ceviche Inka needs a current permit.**
2. **045-NU id 58** — corrected the FALSE note on GDO-11540 (it IS `STALK AND SPADE MIDTOWN DBA NU REAL FOOD
   @ 3250 NE 1 AVE #117`, ACTIVE, valid 2026 — the note wrongly said "no permit here / belongs to 100
   Montaditos"). 045-NU (Midtown #117) and 172-NU (Coral Gables) are DISTINCT locations, not duplicates.
3. **172-NU id 200** — refreshed GDO-07733 `permit_expiration` 2025-12-31 → 2026-12-31 (per current PDF).

## New mis-attributions found + fixed (were ACTIVE, not demoted)

- **GDO-11433** (`TIGER LIGHT DBA TAULA FRESH MEDITERRANEAN @ 1657 N MIAMI AVE #E`) was **ACTIVE on TWO
  wrong clients** — **170-PV** "Pura Vida Bakery" (id 142) **and 176-SOU** "What Soup" (id 104), both listed
  at `1657 N Miami Ave` **unit #A**. Taula (#E) is neither, and there is **no Taula/Tiger Light client** in
  the DB. Demoted GDO-11433 on both (ids 142 + 104). (The stored file `gdo/GDO-11433.pdf` is also mislabeled
  — it contains GDO-14681's content.)

## ⚠ Flags for ops / Fred (out of this sweep's write scope)

- **1657 N Miami Ave #A tangle:** two co-located RECURRING clients — **170-PV Pura Vida Bakery** + **176-SOU
  What Soup** — at the same suite A (likely a stale/duplicate after a tenant change). Unit #A's only DERM
  permit was **GDO-12531 (SKYVILLE), expired 2021**; neither client has a current own permit. Ops to resolve
  which #A client is current and obtain a permit.
- **Compliance (permits lapsed):** 114-CI (2007), 170-PV/176-SOU (#A last permit 2021), 036-LG GDO-12484
  (2019). These clients need to renew/apply.
- **Minor freshness:** 025-GRO id 68 GDO-13447 shows `permit_expiration=2025-12-04` but DERM now reads
  2026-12-31 (not touched — non-demoted row).

All demoted rows kept their prior notes (append-only). No hard deletes; soft status only.
