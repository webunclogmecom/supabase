# NULL audit + Goliath reattribution list — 2026-05-12


# PART A — NULL audit across canonical fields

## A1. visits — NULL count per key field, by service_type + status

| service_type | status | total | null client | null property | null job | null vehicle | null invoice | null start | null completed | null title |
|---|---|---|---|---|---|---|---|---|---|---|
| CL | completed | 91 | 0 | 79 | 0 | 36 | 15 | 0 | 0 | 0 |
| CL | scheduled | 4 | 0 | 1 | 0 | 4 | 4 | 1 | 4 | 0 |
| GT | completed | 346 | 0 | 298 | 1 | 85 | 9 | 0 | 0 | 0 |
| GT | scheduled | 65 | 0 | 55 | 0 | 65 | 65 | 0 | 65 | 0 |
| NULL | completed | 57 | 0 | 49 | 0 | 29 | 12 | 0 | 0 | 0 |
| NULL | scheduled | 30 | 0 | 28 | 0 | 30 | 30 | 1 | 30 | 0 |

## A2. Visits with NULL service_type — what are their titles?

Total visits 2026+ with NULL service_type: **75**

| Count | Title (Jobber-sourced job title — inferServiceType regex didn't match) |
|---|---|
| 27 | 112-YA Yan's Restaurant - GT & CLeaning |
| 11 | 057-BAY Bayshore executive Plaza (SLS Shaulson Lyft Station) - Lyft station cleaning |
| 7 | 000-DH Homestead Dump - Dump |
| 3 | 083-SHUL The Shul - Service |
| 2 | 104-PV Pura Vida Miracle Mile LLC - indoor Manhole Cover |
| 1 | 093-KC KC Market - Adjust lids |
| 1 | DUMP Pompano - Dump Pompano |
| 1 | Le Specialita |
| 1 | ASAP pluming repairs - Service |
| 1 | Laura odette - Service |
| 1 | Asap pluming repairs - Hydro Cleaning line |
| 1 | 170-PV Pura Vida Bakery - Grease pumping |
| 1 | 114-CI Ceviche inka - Service |
| 1 | 195-MYK Myka Lincoln LLC - Service |
| 1 | 043-MIL Mila - Drain Repair |
| 1 | FFM Services LLC - Service |
| 1 | 110-CLA Claudie - Service |
| 1 | Sigalit abramov - Service |
| 1 | 165-LPB La Plaza Bakery And Coffee - Service |
| 1 | 021-GRA Granada Condo - riser repair |
| 1 | Yes Market Miami beach - camera inspection |
| 1 | 083-SHUL The Shul - Lyft station cleaning |
| 1 | Myka Brickell FT LLC - ask aaron |
| 1 | 189-FRE Miami Fresh Fish Market - Service |
| 1 | Pura Vida 41 - Service |
| 1 | 070-TCE The carrot express Miami shores - Repair Pump |
| 1 | Andrew Saka - Toilet repair |
| 1 | JCC - Take pictures |
| 1 | Hubble Bubble Lounge - Service |
| 1 | 191-TEN Tends - Service |

## A3. Completed 2026 visits with NULL vehicle_id (truck attribution gap)

| month | completed | null_vehicle | % null |
|---|---|---|---|
| 2026-01 | 96 | 15 | 15.6% |
| 2026-02 | 95 | 25 | 26.3% |
| 2026-03 | 122 | 21 | 17.2% |
| 2026-04 | 144 | 63 | 43.8% |
| 2026-05 | 37 | 26 | 70.3% |

NULL vehicle_id means the truck-attribution autopilot (ADR 012) couldn't find Samsara GPS pings within 150m of the property during the visit window. Causes: telemetry gap, off-site work (catering at a different venue), parking-behind-building beyond 150m, or property GPS error.

## A4. service_configs — NULL count per field (active recurring clients)

| service_type | total | null/zero freq | null first_visit | null last_visit | null/zero price | null equipment size |
|---|---|---|---|---|---|---|
| CL | 60 | 1 | 60 | 4 | 60 | 60 |
| GT | 135 | 0 | 135 | 135 | 135 | 37 |
| WD | 1 | 0 | 1 | 1 | 1 | 1 |

## A5. Active recurring clients with NULL or $0 service_configs.price_per_visit

30 client × service rows with NULL/zero price (showing first 30 by client_code):

| client_code | client_name | service | freq | price |
|---|---|---|---|---|
| 001-17 | 001-17 17 Restaurant and Sushi Bar | GT | 30d | null |
| 003-BC | 003-BC Bagel Cove | GT | 60d | null |
| 004-BAO | 004-BAO Baoli Miami | CL | 30d | null |
| 004-BAO | 004-BAO Baoli Miami | GT | 60d | null |
| 007-CC | 007-CC Cafe Club | GT | 60d | null |
| 008-CV | 008-CV Cafe Vert | GT | 90d | null |
| 009-CN | 009-CN Casa Neos | GT | 30d | null |
| 010-CS | 010-CS Chima Steakhouse | GT | 60d | null |
| 011-CCC | 011-CCC Cine Citta Cafe (Franck Taieb) | GT | 120d | null |
| 012-DKC | 012-DKC Danziguer Kosher Catering | CL | 30d | null |
| 012-DKC | 012-DKC Danziguer Kosher Catering | GT | 60d | null |
| 013-DIM | 013-DIM Daughter of Israel Mikvah | CL | 30d | null |
| 013-DIM | 013-DIM Daughter of Israel Mikvah | GT | 30d | null |
| 014-JOY | 014-JOY The Joyce | GT | 30d | null |
| 015-FLA | 015-FLA Flame | GT | 60d | null |
| 016-FIA | 016-FIA Florida Food Eats LLC Fialkoff’s | CL | 60d | null |
| 016-FIA | 016-FIA Florida Food Eats LLC Fialkoff’s | GT | 60d | null |
| 017-FIA | 017-FIA Florida Food Eats LLC Fialkoff’s | CL | 60d | null |
| 017-FIA | 017-FIA Florida Food Eats LLC Fialkoff’s | GT | 30d | null |
| 019-G7 | 019-GT G7 Kitchens 34 | CL | 30d | null |
| 019-G7 | 019-GT G7 Kitchens 34 | GT | 30d | null |
| 020-G7 | 020-G7 G7 Roof Top | GT | 60d | null |
| 021-GRA | 021-GRA Granada Condo | CL | 364d | null |
| 021-GRA | 021-GRA Granada Condo | GT | 360d | null |
| 022-GRO | 022-GRO Grove Kosher LLC (Boca Raton) | GT | 60d | null |
| 023-GRO | 023-GRO Grove Kosher LLC (Delray Beach) | GT | 60d | null |
| 024-GRO | 024-GRO Grove Kosher LLC (Fort Lauderdal | GT | 60d | null |
| 025-GRO | 025-GRO Grove Kosher LLC (Harding Ave) | CL | 90d | null |
| 025-GRO | 025-GRO Grove Kosher LLC (Harding Ave) | GT | 30d | null |
| 026-HAP | 026-HAP Happea's | CL | 60d | null |


# PART B — Goliath reattribution list (Airtable Truck="Goliath 5,000" 2026 visits)

## What this is

Airtable's `Truck` field on the Visits table has 128 visits in 2026 incorrectly labeled `Goliath 5,000`. Goliath was decommissioned 2026-05-01 and never had Samsara telemetry, so those labels can't be right. Our Supabase DB derives `visits.vehicle_id` from Samsara GPS cross-reference (ADR 012), so it has the correct truck. This table cross-references the two.

Use this list to manually update the Airtable Truck field. For visits where our DB has `NULL` truck (Samsara had no GPS overlap with the property during the visit), the truck can't be determined automatically — flag those for ops to recall or to defer.

### Pulling Airtable visits with Truck="Goliath 5,000"...

Found **128** Airtable 2026 visits with Goliath label.

### Cross-referencing with our DB (Supabase GPS-derived truck)...

### Summary of correct attribution per our DB

| Our DB says truck = | Count | Action for ops |
|---|---|---|
| NO_JOBBER_ID | 128 | AT visit has no Jobber link; check separately |

### Full reattribution list (CSV-friendly)

| Airtable Visit Date | Client Code | Service | AT Status | AT Truck (wrong) | Our DB truck (correct) | Our visit_id | Notes |
|---|---|---|---|---|---|---|---|
| 2026-05-08 | 212-TRUE | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-05-06 | 208-HUB | GT | Upcoming | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-05-05 | 114-CI | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-30 | 061-TCE | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-28 | 022-GRO | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-28 | 063-TCE | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-28 | 199-JZ | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-28 | 031-KRU | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-27 | 178-LG | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-27 | 207-BAR | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-27 | 205-SAS | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-27 | 206-CAC | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-26 | 093-KC | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-26 | 114-CI | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-26 | 169-TCE | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-26 | 106-ALC | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-26 | 152-DAV | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-23 | 008-CV | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-23 | 150-KOS | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-23 | 149-RUS | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-23 | 049-PV | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-22 | 017-FIA | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-22 | 009-CN | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-22 | 016-FIA | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-22 | 025-GRO | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-21 | 013-DIM | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-20 | 034-LG | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-20 | 065-TCE | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-20 | 148-MOR | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-20 | 026-HAP | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-19 | 111-YC | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-19 | 032-LG | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-19 | 045-NU | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-19 | 033-LG | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-19 | 084-ULT | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-16 | 135-BB | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-16 | 051-PV | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-16 | 023-GRO | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-16 | 064-TCE | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-16 | 081-TCE | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-16 | 042-MT | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-16 | 007-CC | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-15 | 083-SHUL | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-14 | 043-MIL | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-14 | 187-HAI | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-14 | 019-G7 | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-14 | 043-MIL | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-14 | 057-SLS | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-14 | 058-SOH | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-14 | 174-VIN | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-13 | 036-LG | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-13 | 092-TCE | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-13 | 140-TYO | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-11 | 012-DKC | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-10 | 103-BWC | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-10 | 090-OAK | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-10 | 067-TCE | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-09 | 032-LG | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-08 | 137-BB | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-08 | 192-FRK | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-08 | 015-FLA | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-08 | 193-FRK | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-07 | 087-BB | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-07 | 091-SB | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-06 | 179-CIG | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-06 | 001-17 | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-06 | 174-VIN | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-06 | 014-JOY | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-06 | 040-MV | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-06 | 174-VIN | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-01 | 197-BGT | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-01 | 061-TCE | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-04-01 | 047-PAM | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-31 | 062-TCE | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-31 | 199-JZ | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-31 | 181-PV | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-31 | 139-LTG | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-31 | 144-LTG | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-31 | 056-STM | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-30 | 186-PV | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-30 | 133-MUT | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-30 | 182-PAL | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-26 | 072-TCE | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-26 | 200-PALO | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-26 | 188-ACA | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-25 | 024-GRO | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-25 | 028-HUM | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-25 | 030-KGC | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-25 | 117-BH | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-25 | 106-ALC | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-24 | 089-COW | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-24 | 111-YC | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-24 | 041-MB | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-23 | 076-TCE | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-23 | 044-MP | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-19 | 175-PV | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-18 | 033-LG | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-17 | 099-PV | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-16 | 071-TCE | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-16 | 104-PV | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-16 | 036-LG | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-16 | 068-TCE | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-16 | 092-TCE | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-15 | 034-LG | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-15 | 035-LG | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-15 | 026-HAP | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-12 | 013-DIM | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-11 | 009-CN | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-11 | 170-PV | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-11 | 176-SOU | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-10 | 020-G7 | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-10 | 090-OAK | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-10 | 067-TCE | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-10 | 019-G7 | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-09 | 061-TCE | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-08 | 196-PV | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-05 | 174-VIN | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-05 | 198-ARY | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-05 | 087-BB | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-05 | 183-KRE | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-05 | 029-JOS | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-05 | 091-SB | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-04 | 040-MV | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-04 | 132-PUM | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-04 | 171-CAF | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-04 | 039-HSE | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-03 | 109-RAB | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |
| 2026-03-03 | 155-PV | GT | Completed | Goliath 5,000 | NO_JOBBER_ID | - |  |