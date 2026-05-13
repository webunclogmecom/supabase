# Duplicate primary-property addresses — Prod Supabase
Generated 2026-05-11 16:33:32 UTC.  Total groups: 82.

Source: weekly dedup audit's "duplicate addresses" check. Normalization: lowercase, non-alphanumeric → single space.

## Categories

| Category | Count | Action |
|---|---|---|
| **A1.** Real duplicates — same client, multiple property rows | **61** | **Merge** the duplicate property rows in our DB |
| A2. INACTIVE + ACTIVE shadow — old "NOT USE" rows alongside live | 3 | Archive/delete the inactive shadow |
| A3. Same chain prefix — sister stores at same address | 4 | Confirm with Yannick (usually legit) |
| A4. Different clients sharing address — co-tenants | 14 | Usually legit (condo buildings, plazas), confirm |

---

## A1. Real duplicates (61) — same client_id with multiple property rows

These are the priority. Each entry is a single client whose `properties` table has 2+ rows pointing at the same address. Safe to merge — pick the earliest property_id, delete the others, repoint any FKs.

### `1006 East Hallandale Beach Boulevard unit 4-101`
Normalized: `1006 east hallandale beach boulevard unit 4 101`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 5 | 360 | 205-SAS | ACTIVE | 205- SAS Signor SASSI |
| 469 | 360 | 205-SAS | ACTIVE | 205- SAS Signor SASSI |


### `105 East Hallandale Beach Boulevard`
Normalized: `105 east hallandale beach boulevard`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 84 | 283 | 067-TCE | ACTIVE | 067-TCE The carrot express Central kitchen |
| 539 | 283 | 067-TCE | ACTIVE | 067-TCE The carrot express Central kitchen |


### `10590 Pines Boulevard unit p1a`
Normalized: `10590 pines boulevard unit p1a`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 160 | 307 | 196-PV | ACTIVE | 196-PV PV Pura Vida Pembroke Pines |
| 485 | 307 | 196-PV | ACTIVE | 196-PV PV Pura Vida Pembroke Pines |


### `1101 Brickell Avenue s 113`
Normalized: `1101 brickell avenue s 113`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 38 | 372 | 110-CLA | ACTIVE | 110-CLA Claudie |
| 501 | 372 | 110-CLA | ACTIVE | 110-CLA Claudie |


### `1112 15th Street`
Normalized: `1112 15th street`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 100 | 9 | 040-MV | ACTIVE | 040-MV Maison Valentine |
| 518 | 9 | 040-MV | ACTIVE | 040-MV Maison Valentine |


### `12800 Northeast 12th Avenue`
Normalized: `12800 northeast 12th avenue`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 20 | 327 | - | ACTIVE | Bibi  Shamin |
| 509 | 327 | - | ACTIVE | Bibi  Shamin |


### `151 Northeast 41st Street suite 137`
Normalized: `151 northeast 41st street suite 137`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 7 | 354 | - | ACTIVE | YASU |
| 511 | 354 | - | ACTIVE | YASU |


### `1518 Washington Avenue`
Normalized: `1518 washington avenue`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 174 | 139 | 039-HSE | ACTIVE | 039-HSE Hiro's Sushi Express |
| 479 | 139 | 039-HSE | ACTIVE | 039-HSE Hiro's Sushi Express |


### `1540 Alton Road`
Normalized: `1540 alton road`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 77 | 312 | 203-GF | ACTIVE | 203-GF Merav Halperin - Good Food |
| 486 | 312 | 203-GF | ACTIVE | 203-GF Merav Halperin - Good Food |


### `15903 Biscayne Boulevard`
Normalized: `15903 biscayne boulevard`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 3 | 364 | 206-CAC | ACTIVE | 206-CAC Cacio e Pepe |
| 470 | 364 | 206-CAC | ACTIVE | 206-CAC Cacio e Pepe |


### `16 Fisher Island Drive`
Normalized: `16 fisher island drive`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 192 | 204 | 154-PV | ACTIVE | 154-PV Pura Vida Fisher Island |
| 520 | 204 | 154-PV | ACTIVE | 154-PV Pura Vida Fisher Island |


### `1636 Meridian Avenue`
Normalized: `1636 meridian avenue`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 51 | 298 | 043-MIL | ACTIVE | 043-MIL Mila |
| 536 | 298 | 043-MIL | ACTIVE | 043-MIL Mila |


### `1666 79th Street Causeway suite 102`
Normalized: `1666 79th street causeway suite 102`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 272 | 178 | 147-OST | ACTIVE | 147-OST Maison Ostrow |
| 467 | 178 | 147-OST | ACTIVE | 147-OST Maison Ostrow |


### `17092 West Dixie Highway`
Normalized: `17092 west dixie highway`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 23 | 368 | 031-KRU | ACTIVE | 031-KRU Krudo Fish Market |
| 512 | 368 | 031-KRU | ACTIVE | 031-KRU Krudo Fish Market |


### `1745 Cleveland Road Miami Beach, FL, 33141 US`
Normalized: `1745 cleveland road miami beach fl 33141 us`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 162 | 381 | 112-YA | ACTIVE | 112-YA Yan's Restaurant |
| 493 | 381 | 112-YA | ACTIVE | 112-YA Yan's Restaurant |


### `1751 Alton Road`
Normalized: `1751 alton road`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 47 | 316 | 001-17 | ACTIVE | 001-17 17 Restaurant and Sushi Bar |
| 517 | 316 | 001-17 | ACTIVE | 001-17 17 Restaurant and Sushi Bar |


### `18106 West Dixie Highway`
Normalized: `18106 west dixie highway`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 43 | 383 | 191-TEN | ACTIVE | 191-TEN Tends |
| 480 | 383 | 191-TEN | ACTIVE | 191-TEN Tends |


### `19004 Northeast 29th Avenue`
Normalized: `19004 northeast 29th avenue`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 65 | 274 | 058-SOH | ACTIVE | 058-SOH Soho Asian Bar and Grill |
| 537 | 274 | 058-SOH | ACTIVE | 058-SOH Soho Asian Bar and Grill |


### `1906 Collins Avenue`
Normalized: `1906 collins avenue`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 164 | 4 | 004-BAO | ACTIVE | 004-BAO Baoli Miami |
| 516 | 4 | 004-BAO | ACTIVE | 004-BAO Baoli Miami |


### `2104 Northeast 123rd Street`
Normalized: `2104 northeast 123rd street`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 196 | 209 | 165-LPB | ACTIVE | 165-LPB La Plaza Bakery And Coffee |
| 494 | 209 | 165-LPB | ACTIVE | 165-LPB La Plaza Bakery And Coffee |


### `2188 Northeast 123rd Street`
Normalized: `2188 northeast 123rd street`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 124 | 125 | 133-MUT | ACTIVE | 133-MU Mutra |
| 466 | 125 | 133-MUT | ACTIVE | 133-MU Mutra |


### `2243 Northwest 2nd Avenue`
Normalized: `2243 northwest 2nd avenue`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 66 | 290 | 111-YC | ACTIVE | 111-YC Yann Couvreur |
| 519 | 290 | 111-YC | ACTIVE | 111-YC Yann Couvreur |


### `2440 Northeast Miami Gardens Drive STE #107`
Normalized: `2440 northeast miami gardens drive ste 107`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 152 | 362 | 063-TCE | ACTIVE | 063-TCE The Carrot Express (Aventura) |
| 489 | 362 | 063-TCE | ACTIVE | 063-TCE The Carrot Express (Aventura) |


### `2530 Pine Tree Drive`
Normalized: `2530 pine tree drive`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 44 | 323 | 013-DIM | ACTIVE | 013-DIM Daughter of Israel Mikvah |
| 535 | 323 | 013-DIM | ACTIVE | 013-DIM Daughter of Israel Mikvah |


### `259 Miracle Mile`
Normalized: `259 miracle mile`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 78 | 279 | 092-TCE | ACTIVE | 092-TCE The carrot express Coral Gables |
| 505 | 279 | 092-TCE | ACTIVE | 092-TCE The carrot express Coral Gables |


### `2602 East Hallandale Beach Boulevard`
Normalized: `2602 east hallandale beach boulevard`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 90 | 292 | 090-OAK | ACTIVE | 090-OAK One Oak Beachwalk |
| 542 | 292 | 090-OAK | ACTIVE | 090-OAK One Oak Beachwalk |


### `2726 Griffin Road`
Normalized: `2726 griffin road`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 36 | 332 | 127-PC | ACTIVE | 127-PC Puya Cantina |
| 459 | 332 | 127-PC | ACTIVE | 127-PC Puya Cantina |


### `2885 Northwest 36th Street`
Normalized: `2885 northwest 36th street`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 69 | 295 | 032-LG | ACTIVE | 032-LG La Granja 36th St |
| 475 | 295 | 032-LG | ACTIVE | 032-LG La Granja 36th St |


### `2889 Stirling Road Stirling Square`
Normalized: `2889 stirling road stirling square`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 137 | 36 | 024-GRO | ACTIVE | 024-GRO Grove Kosher LLC (Fort Lauderdale) |
| 533 | 36 | 024-GRO | ACTIVE | 024-GRO Grove Kosher LLC (Fort Lauderdale) |


### `3034 Grand Avenue`
Normalized: `3034 grand avenue`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 113 | 375 | 186-PV | ACTIVE | 186-PV Pura Vida Coconut Grove |
| 507 | 375 | 186-PV | ACTIVE | 186-PV Pura Vida Coconut Grove |


### `311 Northwest South River Drive`
Normalized: `311 northwest south river drive`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 115 | 259 | 197-BGT | ACTIVE | 197-BGT Bagatelle Miami River |
| 471 | 259 | 197-BGT | ACTIVE | 197-BGT Bagatelle Miami River |


### `3155 Northeast 163rd Street`
Normalized: `3155 northeast 163rd street`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 11 | 359 | 114-CI | ACTIVE | 114-CI Ceviche inka |
| 502 | 359 | 114-CI | ACTIVE | 114-CI Ceviche inka |


### `3818 Northeast 1st Avenue`
Normalized: `3818 northeast 1st avenue`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 144 | 38 | 052-PV | ACTIVE | 052-PV Pura Vida Design District |
| 496 | 38 | 052-PV | ACTIVE | 052-PV Pura Vida Design District |


### `40 Northeast 41st Street`
Normalized: `40 northeast 41st street`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 8 | 353 | - | ACTIVE | Le Specialita |
| 510 | 353 | - | ACTIVE | Le Specialita |


### `40 Southwest North River Drive`
Normalized: `40 southwest north river drive`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 42 | 369 | 009-CN | ACTIVE | 009-CN Casa Neos |
| 504 | 369 | 009-CN | ACTIVE | 009-CN Casa Neos |


### `4141 Nautilus Drive`
Normalized: `4141 nautilus drive`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 133 | 44 | - | ACTIVE | Excelsior Condo |
| 515 | 44 | - | ACTIVE | Excelsior Condo |


### `419 North Federal Highway 104`
Normalized: `419 north federal highway 104`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 85 | 294 | 103-BWC | ACTIVE | 103-BWC Barrel Wine & Cheese Wine Bar and Restaurant |
| 543 | 294 | 103-BWC | ACTIVE | 103-BWC Barrel Wine & Cheese Wine Bar and Restaurant |


### `4221 Pine Tree Drive`
Normalized: `4221 pine tree drive`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 26 | 352 | 204-JCC | ACTIVE | 204-JCC JCC |
| 487 | 352 | 204-JCC | ACTIVE | 204-JCC JCC |


### `4535 Post Avenue`
Normalized: `4535 post avenue`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 93 | 358 | - | ACTIVE | Sam Bogo |
| 500 | 358 | - | ACTIVE | Sam Bogo |


### `515 East Las Olas Boulevard`
Normalized: `515 east las olas boulevard`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 112 | 15 | 075-TCE | ACTIVE | 075-TCE The carrot express Fort Lauderdale |
| 538 | 15 | 075-TCE | ACTIVE | 075-TCE The carrot express Fort Lauderdale |


### `551 Lincoln Road unit 5`
Normalized: `551 lincoln road unit 5`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 46 | 346 | 195-MYK | ACTIVE | 195-MYK Myka Lincoln LLC |
| 481 | 346 | 195-MYK | ACTIVE | 195-MYK Myka Lincoln LLC |


### `613 West Hallandale Beach Boulevard`
Normalized: `613 west hallandale beach boulevard`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 13 | 330 | 106-ALC | ACTIVE | 106-ALC A la Carte |
| 464 | 330 | 106-ALC | ACTIVE | 106-ALC A la Carte |


### `658 West Hallandale Beach Boulevard`
Normalized: `658 west hallandale beach boulevard`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 25 | 318 | 028-HUM | ACTIVE | 028-HUM Hummus Achla |
| 527 | 318 | 028-HUM | ACTIVE | 028-HUM Hummus Achla |


### `701 Brickell Avenue`
Normalized: `701 brickell avenue`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 132 | 343 | 175-PV | ACTIVE | 175-PV Pura Vida Brickell 701 |
| 499 | 343 | 175-PV | ACTIVE | 175-PV Pura Vida Brickell 701 |


### `7145 Collins Avenue`
Normalized: `7145 collins avenue`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 105 | 281 | 061-TCE | ACTIVE | 061-TCE The carrot express 71st Collins |
| 478 | 281 | 061-TCE | ACTIVE | 061-TCE The carrot express 71st Collins |


### `7351 West Atlantic Avenue Villages of Oriole Plaza`
Normalized: `7351 west atlantic avenue villages of oriole plaza`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 60 | 291 | 023-GRO | ACTIVE | 023-GRO Grove Kosher LLC (Delray Beach) |
| 534 | 291 | 023-GRO | ACTIVE | 023-GRO Grove Kosher LLC (Delray Beach) |


### `740 Arthur Godfrey Road`
Normalized: `740 arthur godfrey road`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 182 | 131 | 136-BB | ACTIVE | 136-BB Bagel Boss Miami Beach |
| 477 | 131 | 136-BB | ACTIVE | 136-BB Bagel Boss Miami Beach |


### `7535 North Kendall Drive`
Normalized: `7535 north kendall drive`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 145 | 72 | 099-PV | ACTIVE | 099-PV Pura Vida Dadeland |
| 497 | 72 | 099-PV | ACTIVE | 099-PV Pura Vida Dadeland |


### `7972 Biscayne Point Circle`
Normalized: `7972 biscayne point circle`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 50 | 350 | - | ACTIVE | Brook Eadler |
| 491 | 350 | - | ACTIVE | Brook Eadler |


### `8400 Northwest 53rd Street unit f108`
Normalized: `8400 northwest 53rd street unit f108`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 166 | 341 | 177-PV | ACTIVE | 177-PV pura Vida Doral |
| 495 | 341 | 177-PV | ACTIVE | 177-PV pura Vida Doral |


### `8950 Southwest 232nd Street`
Normalized: `8950 southwest 232nd street`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 98 | 365 | 000-DH | ACTIVE | 000-DH Homestead Dump |
| 476 | 365 | 000-DH | ACTIVE | 000-DH Homestead Dump |


### `9467 Harding Avenue`
Normalized: `9467 harding avenue`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 24 | 384 | 025-GRO | ACTIVE | 025-GRO Grove Kosher LLC (Harding Ave) |
| 482 | 384 | 025-GRO | ACTIVE | 025-GRO Grove Kosher LLC (Harding Ave) |


### `9472 Harding Avenue`
Normalized: `9472 harding avenue`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 82 | 300 | 116-HIK | ACTIVE | 116-HIK Hikari Miami |
| 465 | 300 | 116-HIK | ACTIVE | 116-HIK Hikari Miami |


### `9491 Harding Avenue`
Normalized: `9491 harding avenue`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 201 | 143 | 141-NEY | ACTIVE | 141-NEY Neya |
| 483 | 143 | 141-NEY | ACTIVE | 141-NEY Neya |


### `9517 Harding Avenue`
Normalized: `9517 harding avenue`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 58 | 288 | 029-JOS | ACTIVE | 029-JOS Josh's Deli |
| 508 | 288 | 029-JOS | ACTIVE | 029-JOS Josh's Deli |


### `9519 Harding Avenue`
Normalized: `9519 harding avenue`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 126 | 31 | 082-TFC | ACTIVE | 082-TFC The fresh Carrot of Surfside |
| 461 | 31 | 082-TFC | ACTIVE | 082-TFC The fresh Carrot of Surfside |


### `9540 Collins Avenue`
Normalized: `9540 collins avenue`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 48 | 366 | 083-SHUL | ACTIVE | 083-SHUL The Shul |
| 532 | 366 | 083-SHUL | ACTIVE | 083-SHUL The Shul |


### `9543 Harding Avenue`
Normalized: `9543 harding avenue`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 106 | 34 | 087-BB | ACTIVE | 087-BB Bagel Boss Harding Ave |
| 462 | 34 | 087-BB | ACTIVE | 087-BB Bagel Boss Harding Ave |


### `9545 Harding Avenue`
Normalized: `9545 harding avenue`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 172 | 237 | 183-KRE | ACTIVE | 183-KRE Kresy Kosher Pizza & Falafel Bar |
| 468 | 237 | 183-KRE | ACTIVE | 183-KRE Kresy Kosher Pizza & Falafel Bar |


### `9561 Harding Avenue`
Normalized: `9561 harding avenue`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 86 | 299 | 091-SB | ACTIVE | 091-SB Street Bar |
| 463 | 299 | 091-SB | ACTIVE | 091-SB Street Bar |


### `9802 Northeast 2nd Avenue`
Normalized: `9802 northeast 2nd avenue`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 74 | 380 | 070-TCE | ACTIVE | 070-TCE The carrot express Miami shores |
| 460 | 380 | 070-TCE | ACTIVE | 070-TCE The carrot express Miami shores |


---

## A2. INACTIVE + ACTIVE shadow (3)

Old client rows ("NOT USE...") sitting at the same address as the live client. Archive or delete the INACTIVE rows.

### `10800 Biscayne Boulevard`
Normalized: `10800 biscayne boulevard`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 301 | 155 | - | INACTIVE | NOT USE bayshore plaza |
| 40 | 322 | 057-BAY | ACTIVE | 057-BAY Bayshore executive Plaza (SLS Shaulson Lyft Station) |


### `1882 Northwest 21st Street`
Normalized: `1882 northwest 21st street`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 395 | 242 | - | ACTIVE | Riviera Hospitality LLC |
| 163 | 268 | - | INACTIVE | Commissary toilet |


### `7500 Southwest 120th Street`
Normalized: `7500 southwest 120th street`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 344 | 112 | - | ACTIVE | Rachid chef |
| 123 | 120 | 129-BSC | INACTIVE | 129-BSC Bet Shira Congretation |


---

## A3. Same chain prefix (4)

### `1002 East Hallandale Beach Boulevard`
Normalized: `1002 east hallandale beach boulevard`  •  3 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 286 | 74 | - | ACTIVE | MGM Construction Group |
| 2 | 373 | 093-KC | ACTIVE | 093-KC KC Market |
| 523 | 373 | 093-KC | ACTIVE | 093-KC KC Market |


### `16145 Biscayne Boulevard`
Normalized: `16145 biscayne boulevard`  •  3 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 177 | 265 | - | ACTIVE | JZ Steak House NOT USE |
| 117 | 363 | 199-JZ | ACTIVE | 199-STK JZ Steak House |
| 490 | 363 | 199-JZ | ACTIVE | 199-STK JZ Steak House |


### `2889 McFarlane Road`
Normalized: `2889 mcfarlane road`  •  3 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 281 | 175 | - | ACTIVE | Ava Coconut Grove (NOT USE) |
| 63 | 305 | 168-AVA | ACTIVE | 168-AVA AVA |
| 506 | 305 | 168-AVA | ACTIVE | 168-AVA AVA |


### `433 West 41st Street`
Normalized: `433 west 41st street`  •  3 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 41 | 342 | 189-FRE | ACTIVE | 189-FRE Miami Fresh Fish Market |
| 484 | 342 | 189-FRE | ACTIVE | 189-FRE Miami Fresh Fish Market |
| 22 | 377 | - | ACTIVE | Millennium management |


---

## A4. Different clients, same address — likely co-tenants (14)

Condo buildings, mixed-use plazas, food halls. Usually legitimate — multiple businesses operating at the same street address. Worth a glance to confirm but no action expected unless one looks wrong.

### `4101 Pine Tree Drive`
Normalized: `4101 pine tree drive`  •  9 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 319 | 2 | - | ACTIVE | Fake restaurant |
| 363 | 42 | - | ACTIVE | Aaron Azoulay |
| 240 | 80 | - | ACTIVE | Parking |
| 222 | 86 | - | ACTIVE | Michael and Ruth Friedman |
| 397 | 264 | 198-ARY | ACTIVE | 198-ARY Aryeh Hochner |
| 91 | 277 | 012-DKC | ACTIVE | 012-DKC Danziguer Kosher Catering |
| 474 | 277 | 012-DKC | ACTIVE | 012-DKC Danziguer Kosher Catering |
| 19 | 376 | - | ACTIVE | Tower 41 Association  Building |
| 503 | 376 | - | ACTIVE | Tower 41 Association  Building |


### `5450 S State Road 7 #7`
Normalized: `5450 s state road 7 7`  •  4 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 161 | 26 | 020-G7 | ACTIVE | 020-G7 G7 Roof Top |
| 541 | 26 | 020-G7 | ACTIVE | 020-G7 G7 Roof Top |
| 75 | 289 | 019-G7 | ACTIVE | 019-GT G7 Kitchens 34&35 |
| 540 | 289 | 019-G7 | ACTIVE | 019-GT G7 Kitchens 34&35 |


### `1657 North Miami Avenue suite a`
Normalized: `1657 north miami avenue suite a`  •  3 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 157 | 221 | 176-SOU | Recuring | 176-SOU What Soup |
| 16 | 382 | 170-PV | ACTIVE | 170-PV Pura Vida Bakery |
| 473 | 382 | 170-PV | ACTIVE | 170-PV Pura Vida Bakery |


### `777 Brickell Avenue`
Normalized: `777 brickell avenue`  •  3 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 30 | 348 | - | ACTIVE |  |
| 524 | 348 | - | ACTIVE |  |
| 529 | 454 | - | ACTIVE | True Barista Truck |


### `1000 East Hallandale Beach Boulevard`
Normalized: `1000 east hallandale beach boulevard`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 223 | 149 | - | ACTIVE | Oasis Hallandale commercial condominium 2 association |
| 131 | 161 | 151-OAS | ACTIVE | 151-OAS Oasis Hallandale Master Association BUILDING 1 |


### `1250 South Miami Avenue`
Normalized: `1250 south miami avenue`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 205 | 241 | - | ACTIVE | Piola |
| 56 | 276 | 026-HAP | Recuring | 026-HAP Happea's |


### `13823 Southwest 88th Street`
Normalized: `13823 southwest 88th street`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 521 | 450 | - | ACTIVE | Aromas del Peru |
| 522 | 451 | - | ACTIVE |  |


### `1395 Brickell Avenue`
Normalized: `1395 brickell avenue`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 530 | 455 | - | ACTIVE |  |
| 531 | 456 | - | ACTIVE | True Barista Temporally truck |


### `17030 West Dixie Highway`
Normalized: `17030 west dixie highway`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 213 | 152 | 145-NON | ACTIVE | International Foods By Noni (Arepas Noni) |
| 304 | 153 | - | ACTIVE | 145- International Foods By Noni (Arepas Noni) |


### `1747 Alton Road`
Normalized: `1747 alton road`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 399 | 331 | 128-MF | ACTIVE | 128-MF Meir Fellig |
| 45 | 333 | 132-PUM | Recuring | 132-PU Pummarola |


### `1936 Normandy Drive`
Normalized: `1936 normandy drive`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 320 | 65 | 122-BMN | ACTIVE | 122-BMN BMN Normandy LLC |
| 337 | 69 | 119-ME | ACTIVE | 119-ME Mosche Elghrissi |


### `5818 Stirling Road`
Normalized: `5818 stirling road`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 386 | 33 | - | ACTIVE | Zohar's Gelato & Pizza Hollywood |
| 389 | 52 | 088-SH | PAUSED | 088-SH Sushi House |


### `7580 Northeast 4th Court`
Normalized: `7580 northeast 4th court`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 175 | 222 | 171-CAF | ACTIVE | 171-CAF Ironside Cafe |
| 235 | 223 | - | ACTIVE | 000- Kaffe |


### `9427 Harding Avenue`
Normalized: `9427 harding avenue`  •  2 property rows

| property_id | client_id | client_code | status | name |
|---|---|---|---|---|
| 305 | 150 | - | ACTIVE | The Harbour Grill |
| 251 | 205 | - | ACTIVE | Wok N Roll |

