# Multi-location client discovery — for Diego / Yannick verification

*Built 2026-06-01 from `reports/_multi_location_discovery.json` (probe
`scripts/probes/_multi_location_discovery.js`). Two signals: (1) client-code suffix
(e.g. `-PV`, `-TCE`), (2) shared address (normalized + lat/long geo, to catch the same
address written differently). Goal: find the clients that are really ONE business with
multiple locations, to model them like Wynd 28 and Casa Neos.*

---

## A. Brand families (same code suffix = one company, multiple sites)

Confirm each is one company; flag any code that doesn't belong.

| Suffix | Brand | # | Type |
|---|---|---|---|
| `-PV` | Pura Vida | 23 | chain — different addresses (048/049/050/051/052/053/054/055/099/104/107/143/154/155/170/175/177/180/181/186/194/196/225) |
| `-TCE` | The Carrot Express | 23 | chain — different addresses (061–081, 092, 169) |
| `-LG` | La Granja | 6 | chain (032/033/034/035/036/178) |
| `-GRO` | Grove Kosher | 4 | chain (022/023/024/025) |
| `-BB` | Bagel Boss | 4 | chain (087/135/136/137) |
| `-G7` | G7 Kitchens | 3 | **019 + 020 same building** (5450 S State Rd 7) + 215 separate |
| `-TRUE` | True Barista | 3 | 209 @ 777 Brickell + **212 + 213 same building** (1395 Brickell) |
| `-FIA` | Fialkoff's | 2 | chain (016 Miami Beach / 017 Surfside) |
| `-KRU` | Krudo | 2 | 031 Fish Market / 230 Warehouse |
| `-MYK` | Myka | 2 | 195 Lincoln Rd / 214 777 Brickell (different sites) |
| `-MP` | Mrs / Mr Pasta | 2 | **same building** (220 SW 31st St) — Mrs. Pasta + Mr. Pasta Factory |
| `-FRK` | Fresko | 2 | adjacent (19048 / 19062 NE 29th) — Fresko + Fresko Bakery |
| `-NU` | Nu Real Food | 2 codes | 045 (3250 NE 1st Ave) / 172 (266 Miracle Mile) — **172 entered twice** |
| `-LTG` | Lettuce & Tomato | 2 codes | **same building** (17070 W Dixie) — restaurant + bakery — **144 entered twice** |
| `-WYN` | Wynd 28 | 5 (Airtable) | same building — **already being merged into one client** |
| `-CN` | Casa Neos | 009 + 207 (the BAR) | same building — **already done** (009-CN client + Bars location) |

*(`-YA` = Yan's test accounts, skip.)*

**Question:** for the real chains (PV, TCE, La Granja, Grove Kosher, Bagel Boss, Fialkoff's,
Krudo, Myka) — do you want each managed as **one client with N locations**, or kept as separate
clients per restaurant? (They have separate addresses, visits and billing, so this is a real choice.)

---

## B. Same address, multiple client records (the Wynd / Casa Neos pattern)

For each: is it **ONE operator with multiple units** (→ we merge into one client + locations,
like Wynd/Casa Neos), or **separate businesses** that just share a building?

**Same brand at one address — looks like multi-unit (high confidence):**
| Address | Clients |
|---|---|
| 5450 S State Rd 7, Ft Lauderdale | G7 Kitchens 34 (`019-G7`) + G7 Roof Top (`020-G7`) |
| 1395 Brickell Ave, Miami | True Barista Temp (`212-TRUE`) + True Barista Grease Trap (`213-TRUE`) |
| 220 SW 31st St, Ft Lauderdale | Mrs. Pasta (`044-MP`) + Mr. Pasta Factory (`221-MP`) |
| 17070 W Dixie Hwy, N Miami Beach | Lettuce & Tomato (`139-LTG`) + its Bakery (`144-LTG`) |
| 19048 / 19062 NE 29th Ave | Fresko (`192-FRK`) + Fresko Bakery (`193-FRK`) |

**Different brands at one address — please confirm if related (food hall / ghost kitchen / same owner?):**
| Address | Clients |
|---|---|
| 777 Brickell Ave, Miami | True Barista Truck (`209-TRUE`) + Myka Brickell (`214-MYK`) |
| 1657 N Miami Ave, suite a | Pura Vida Bakery (`170-PV`) + What Soup (`176-SOU`) |
| 668 W Hallandale Beach Blvd | Kosher Bagel Cove (`030-KGC`) + Bakey (`229-BAK`) |
| 1936 Normandy Dr, Miami Beach | Mosche Elghrissi (`119-ME`) + BMN Normandy (`122-BMN`) |
| 1747 Alton Rd, Miami Beach | Meir Fellig (`128-MF`) + Pummarola (`132-PUM`) |

**Adjacent storefronts — probably separate neighbors, just confirm:**
- ~9543 / 9545 Harding Ave, Surfside — Bagel Boss (`087-BB`) + Kresy Kosher Pizza (`183-KRE`)
- ~9472 / 9476 Harding Ave, Surfside — Hikari Miami (`116-HIK`) + Rustico (`149-RUS`)

---

## C. Duplicate client records (same code entered twice — data cleanup, we'll merge)
- `172-NU` Nu Real Food — Coral Gables: ids 464 + 224
- `144-LTG` Lettuce & Tomato (Bakery): ids 466 + 147

---

## What we need back
1. **List A:** confirm the brand families + whether each chain should become one client with N locations.
2. **List B:** for each shared-address row, tell us "one operator, multiple units" vs "separate businesses."
3. **List C:** OK to merge the duplicates.
