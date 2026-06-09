# Cross-check: our `public.gdos` vs Yan's "Miami-Dade Grease Trap Universe" sheet

Source: https://docs.google.com/spreadsheets/d/1KMfZnd2GURwJzSCcelfa8TzyxmYs4ByPjALZqov3vhw/edit?gid=154422364 (tab "GDO Permit #")
Run: 2026-05-25 PM

## Headline counts

- Our ACTIVE gdos: **84**
- Of which valid-format (`GDO-\d{3,6}`): **81**
- Yan's sheet rows: **8,165** (full Miami-Dade DERM universe)
- Of our 81 valid: **76 found in Yan's sheet** (94%), **5 missing**

## 1. 🟡 Garbage in OUR DB — 3 ACTIVE rows with `gdo_number='BW'/'bw'`

These are Broward-county clients that should not have a Miami-Dade DERM GDO at all. Phase 2 didn't catch them because the bot only looks up valid-format gdo_numbers.

| id | gdo_number | client | address |
|---|---|---|---|
| 137 | BW | 044-MP Mrs. Pasta | 220 SW 31st St, Fort Lauderdale |
| 138 | bw | 076-TCE Carrot Express Hollywood | 1818 Hollywood Blvd, Hollywood |
| 139 | BW | 024-GRO Grove Kosher LLC (Fort Lauderdale) | 2889 Stirling Rd, Fort Lauderdale |

**Recommended action:** demote these 3 rows to `status='INACTIVE'`. Could also just set `gdo_number=NULL`, but per the table contract `gdo_number` is `NOT NULL`. Demote is cleaner.

## 2. 🟡 Missing in Yan's sheet — 5 of our GDOs not in Yan's data

| Our gdo | Client | Notes |
|---|---|---|
| GDO-00951 | 132-PUM Pummarola | Phase 2 renamed from `GDO-000951` (typo fix). Yan's sheet has NEITHER number → our typo-correction may be wrong, gdo may not exist in DERM at all |
| GDO-04840 | 004-BAO Baoli Miami | Yan doesn't have it. Verify against DERM. |
| GDO-09852 | 002-41 41 Pizza and Bakery | Yan doesn't have it. Verify. |
| GDO-10249 | 171-CAF Ironside Cafe | Phase 2 renamed from `GDO-10248`. Yan has **`GDO-10248`** still listed — our rename may have been wrong |
| GDO-14965 | 041-MB Marie Blachere | Yan doesn't have it. Verify (note: this is a CHAIN — Marie Blachere expansion). |

## 3. 🔴 In-place rename audit — 4 of 8 renames look problematic

In Phase 2 we renamed 8 `gdo_number`s in place based on bot's `name_match=true`. Cross-checking against Yan's sheet:

| Client | Old → New | Old in Yan? | New in Yan? | Notes |
|---|---|---|---|---|
| 208-HUB Hubble Bubble Lounge | GDO-08370 → GDO-16086 | no | yes (no biz name) | ✓ clean |
| 036-LG La Granja S Miami | GDO-12484 → GDO-11708 | no | yes ("LA GRANJA ON NORTH MIAMI BEACH") | ✓ clean |
| **148-MOR The Moore** | **GDO-11226 → GDO-14769** | **YES ("ELASTIKA BEV CO")** | yes ("MOORE CLUB BEV CO/MOORE HOTEL BEV CO/MOORE WORKPLACE BEV CO") | **🔴 Multi-permit case we missed.** The Moore property has BOTH GDOs (different facilities). We assigned only the new one. Same pattern as Casa Neos. |
| **170-PV Pura Vida Bakery** | **GDO-11433 → GDO-14681** | **YES (no biz)** | yes ("PURA VIDA MIAMI") | **🔴 Both still active in Yan's data.** Pura Vida Bakery may legitimately have both permits. |
| **155-PV Pura Vida Flamingo** | **GDO-12838 → GDO-10891** | **YES (no biz)** | yes (no biz) | **🔴 Both still active.** Multi-permit? |
| 132-PUM Pummarola | GDO-000951 → GDO-00951 | no | no | 🔴 NEITHER in Yan — our typo fix may not match any real DERM permit |
| **060-TU Talmudic University** | **GDO-13076 → GDO-00313** | **YES (no biz)** | yes (no biz) | **🔴 Both in Yan.** Talmudic may have both permits (different campuses?) |
| **171-CAF Ironside Cafe** | **GDO-10248 → GDO-10249** | **YES ("no biz")** | no | **🔴 Our rename is wrong.** Yan only has 10248. We renamed to a number that doesn't exist in Yan's data. |

**Net:** 6 of 8 in-place renames have either:
- The OLD gdo_number still in Yan's data (suggests we may have wrongly demoted/renamed a valid permit), OR
- The NEW gdo_number missing from Yan's data (suggests we renamed to a non-existent number)

This warrants a Phase 2-style PDF re-verification on these 6 rows.

## 4. 🟡 Real expiration mismatches — 7 cases where Phase 2's bulk `2026-12-31` is wrong

Phase 2 bulk-updated every ACTIVE `permit_expiration < 2026-01-01` to `2026-12-31` on the annual-cycle assumption. Yan's sheet (sourced from DERM directly) shows the actual expiration is OLDER on these 7:

| gdo | client | ours | Yan (real) |
|---|---|---|---|
| GDO-06762 | 094-MOZ Mozart Cafe | 2026-12-31 | **2025-12-31** |
| GDO-11271 | 137-BB Bagel Boss Aventura | 2026-12-31 | **2025-12-31** |
| GDO-13822 | 066-TCE Carrot Express Buena Vista | 2026-12-31 | **2024-12-31** |
| GDO-14294 | 047-PAM Pamplemousse | 2026-12-31 | **2024-12-31** |
| GDO-14528 | 183-KRE Kresy Kosher | 2026-12-31 | **2025-12-31** |
| GDO-14769 | 148-MOR The Moore | 2026-12-31 | **2025-12-31** |
| GDO-16086 | 208-HUB Hubble Bubble Lounge | 2026-12-31 | **2025-12-31** |

**Interpretation:** these permits were NOT renewed to 2026 yet (or are actually expired). Our bulk fix was too optimistic. Either:
- DERM hasn't issued the renewal yet (annual cycle hasn't completed for these specific facilities)
- The permittee actually let the permit lapse

Both 2024-12-31 ones are particularly concerning — over a year expired. Worth flagging to ops.

## 5. 🔴 Business-name mismatches — 3 likely WRONG_CLIENT cases we missed

Phase 2 classified these as CONFIRMED_MATCH because the bot's `issued_to` partially matched. But Yan's sheet shows the actual business at the address is unrelated:

| gdo | our client | Yan's Business Name |
|---|---|---|
| GDO-09925 | 092-TCE Carrot Express Coral Gables | **CAFE ITALIANO** |
| GDO-12066 | 018-FUE Fuego By Mana | **CAMPANIA COOL FIRED PIZZA MIA** (could be Fuego's DBA — verify) |
| GDO-13822 | 066-TCE Carrot Express Buena Vista | **100 MONTADITOS** (also flagged in #4 above for stale expiration) |

**Action:** demote candidates (same pattern as Phase 2's 53 demotes).

## 6. 🔴 Address-cross-reference findings (NEW — second pass)

Initial diff only matched by `gdo_number`. Second pass also matched by `(house_number, street)` against Yan's data. Results:

| Metric | Count |
|---|---|
| Our gdo + address both match Yan exactly | 32 |
| Our gdo_number doesn't appear at our address per Yan | 4 |
| Our address has no Yan match by (house, street) | 33 (street normalizer too narrow — needs refinement) |
| House+zip fallback resolved | 15 |

### 6a. 🔴 Our `gdo_number` is missing from the address per Yan

| Client | Our gdo at our addr | Yan's gdo at same addr | Interpretation |
|---|---|---|---|
| **047-PAM Pamplemousse On the bay** @ 910 West Ave | GDO-14294 | **GDO-09736** | **Our gdo is wrong.** Pamplemousse should be GDO-09736 per Yan. (Also flagged in #4 with stale 2024 expiration — consistent picture: GDO-14294 isn't actually theirs.) |
| **168-AVA AVA** @ 2889 McFarlane Rd | GDO-15675 | **GDO-10238** | Our gdo may be wrong. Yan has GDO-10238 at this address. |
| **009-CN Casa Neos** @ 40 SW North River Dr | GDO-15062 (BARS) + GDO-16389 (LOUNGE) | only GDO-10877 (KITCHENS) at base address | Not a problem — Yan's sheet has BARS and LOUNGE under suite-specific addresses (#FAC.B and #Suite 301 per the PDFs we verified). Our matcher just didn't reach them. |

### 6b. 🟡 Multi-tenant buildings — additional permits at our addresses we don't service

These addresses have MULTIPLE permits in Yan's sheet — ours is one of them but there are others. Could be sales leads (other businesses we could service) OR data quality issues (we're tagged to wrong suite).

| Address | Our client + gdo | Other Yan permits at same address |
|---|---|---|
| **110 Washington Ave** | 107-PV Pura Vida SOBE = GDO-07696 (#C-2) | GDO-07169 (#CU-9), GDO-13065 (#CU-3+CU-4) — 2 other tenants we don't service |
| **1756 N Bayshore Dr** | 053-PV Pura Vida Edgewater = GDO-12345 (#100) | GDO-05270 (#124) — 1 other tenant |
| **1101 Brickell Ave** | 110-CLA Claudie = GDO-12517 (#N-110 Bldg N) | GDO-09594 (#N-110) — 1 other tenant or DBA |
| **3450 NW 83 Ave** | 074-TCE Carrot Express Doral = GDO-11170 | GDO-12209 (#148-150) — Yan only shows -12209 at this suite. **Our GDO-11170 may be wrong; should verify.** |
| **5850 SW** | 071-TCE Carrot Express South Miami = GDO-09881 (#5850 SW 72 St #B) | GDO-00426 (#5850 SW 73 St) — different street, same number |

## 7. ⚠ Caveat — 33 of our addresses couldn't be normalize-matched

My street-name normalizer missed 33 of our 84 ACTIVE rows. Common causes: extra ", USA" suffixes, alternate ordinal spellings ("2nd" vs "Second"), 5-digit zip embedded in middle of string. The 33 unmatched rows might contain MORE address-mismatches not surfaced above. Worth a manual sweep with a better address parser.

## Recommended follow-up migrations

1. **`25x` — demote the 3 Broward garbage rows** (low risk, mechanical)
2. **`25y` — demote the 3 business-name mismatches** (Cafe Italiano, Campania, 100 Montaditos)
3. **`25z` — investigate + correct the 6 problematic renames** via PDF lookup on the OLD numbers (Phase 2-style verification)
4. **`25aa` — investigate the 5 missing-from-Yan** GDOs via direct DERM portal lookup
5. **Adjust the 7 stale-expiration overrides** — revert our bulk 2026-12-31 to the real dates from Yan (or re-verify via DERM); flag as renewal-pending for ops
