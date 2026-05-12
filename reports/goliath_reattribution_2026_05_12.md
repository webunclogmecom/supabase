# Goliath reattribution list — 2026-05-12

## What this is

128 Airtable 2026 visits have `Truck = "Goliath 5,000"`. Goliath was decommissioned 2026-05-01 and has zero Samsara telemetry, so those labels can't reflect reality. Our Supabase `visits.vehicle_id` is derived from Samsara GPS cross-reference against property coordinates (ADR 012). This list maps each AT Goliath-labeled visit to our DB's correctly-attributed truck.

Matching strategy: AT has empty `Jobber Visit ID` on these 128 visits, so we match by (`Client Code` + `Visit Date` ±1 day). The ±1 day tolerance catches the common ET-vs-UTC date confusion between AT and Jobber.

## Summary

| Our DB says truck = | Count | Action for ops |
|---|---|---|
| Moises | 89 | Update Airtable Truck → **Moises 9,000** |
| NULL | 30 | GPS had no overlap (telemetry gap or off-site work) — defer to operator memory |
| NO_MATCH | 8 | No matching Supabase visit found — AT-only entry; check separately |
| Cloggy | 1 | Update Airtable Truck → **Cloggy 120** |

## Full reattribution list

Grouped by correct truck for ops convenience. Sorted by visit_date desc within each group.


### Moises (89)

| AT Visit Date | Client Code | Service | AT Status | DB visit_id | DB title | DB date (if mismatch) |
|---|---|---|---|---|---|---|
| 2026-05-05 | 114-CI | GT | Completed | 3913 | 114-CI Ceviche inka - Grease trap Servic | 2026-05-04 |
| 2026-04-30 | 061-TCE | GT | Completed | 3896 | 061-TCE The carrot express 71st Collins  |  |
| 2026-04-28 | 063-TCE | GT | Completed | 1803 | 063-TCE The Carrot Express (Aventura) -  |  |
| 2026-04-28 | 031-KRU | GT | Completed | 1800 | 031-KRU Krudo Fish Market - Grease Trap  |  |
| 2026-04-26 | 093-KC | GT | Completed | 1783 | 093-KC KC Market - Grease Trap Pumping |  |
| 2026-04-26 | 114-CI | GT | Completed | 1785 | 114-CI Ceviche inka - Grease trap Servic |  |
| 2026-04-26 | 169-TCE | GT | Completed | 1781 | 169-TCE The Carrot Express Oakland Park  |  |
| 2026-04-26 | 106-ALC | GT | Completed | 1784 | 106-ALC A la Carte - Grease Trap Pumping |  |
| 2026-04-26 | 152-DAV | GT | Completed | 1782 | 152-DAV Davinci - Grease Trap Pumping an |  |
| 2026-04-23 | 008-CV | GT | Completed | 1776 | 008-CV Cafe Vert - Grease Trap Pumping |  |
| 2026-04-23 | 150-KOS | GT | Completed | 1773 | 150-KOS Kosh - Grease Trap Pumping |  |
| 2026-04-23 | 149-RUS | GT | Completed | 1774 | 149-RUS Rustico - Grease Trap Pumping |  |
| 2026-04-23 | 049-PV | GT | Completed | 1777 | 049-PV Pura Vida (Bay Harbor) - Grease T |  |
| 2026-04-22 | 017-FIA | GT | Completed | 1775 | 017-FIA Florida Food Eats LLC Fialkoff’s | 2026-04-23 |
| 2026-04-22 | 025-GRO | GT | Completed | 1769 | 025-GRO Grove Kosher LLC (Harding Ave) - |  |
| 2026-04-20 | 034-LG | GT | Completed | 1736 | 034-LG La Granja Calle 8 - Grease Trap P |  |
| 2026-04-20 | 065-TCE | GT | Completed | 1734 | 065-TCE The carrot express Brickell - Gr |  |
| 2026-04-20 | 148-MOR | GT | Completed | 1737 | 148-MOR The Moore - Grease Trap Pumping  |  |
| 2026-04-20 | 026-HAP | GT | Completed | 1735 | 026-HAP Happea's - Grease Trap Pumping & |  |
| 2026-04-19 | 111-YC | GT | Completed | 1728 | 111-YC Yann Couvreur - Grease Trap Pumpi |  |
| 2026-04-19 | 032-LG | GT | Completed | 1726 | 032-LG La Granja 36th St - Grease Trap P |  |
| 2026-04-19 | 033-LG | GT | Completed | 1727 | 033-LG La Granja Allapattah - Grease Tra |  |
| 2026-04-16 | 135-BB | GT | Completed | 1722 | 135-BB Bagel Boss Boca Raton - Grease Tr |  |
| 2026-04-16 | 051-PV | GT | Completed | 1718 | 051-PV Pura Vida Delray - Grease Trap Pu |  |
| 2026-04-16 | 023-GRO | GT | Completed | 1719 | 023-GRO Grove Kosher LLC (Delray Beach)  |  |
| 2026-04-16 | 064-TCE | GT | Completed | 1723 | 064-TCE The carrot express Boca Raton -  |  |
| 2026-04-16 | 081-TCE | GT | Completed | 1720 | 081-TCE The carrot express West Boca, Sh |  |
| 2026-04-14 | 187-HAI | GT | Completed | 1709 | 187-HAI Shalom Haifa - Grease trap pumpi |  |
| 2026-04-11 | 012-DKC | GT | Completed | 1613 | 012-DKC Danziguer Kosher Catering - Grea | 2026-04-12 |
| 2026-04-10 | 103-BWC | GT | Completed | 1610 | 103-BWC Barrel Wine & Cheese Wine Bar an |  |
| 2026-04-10 | 090-OAK | GT | Completed | 1609 | 090-OAK One Oak Beachwalk - Grease Trap  |  |
| 2026-04-10 | 067-TCE | GT | Completed | 1608 | 067-TCE The carrot express Central kitch |  |
| 2026-04-08 | 137-BB | GT | Completed | 1590 | 137-BB Bagel Boss Aventura - Grease Trap |  |
| 2026-04-08 | 015-FLA | GT | Completed | 1591 | 015-FLA Flame - Grease Trap Pumping & Wa |  |
| 2026-04-08 | 193-FRK | GT | Completed | 1592 | 193-FRK Fresko Bakery - Grease Trap Pump |  |
| 2026-04-07 | 087-BB | GT | Completed | 1586 | 087-BB Bagel Boss Harding Ave - Grease T |  |
| 2026-04-07 | 091-SB | GT | Completed | 1587 | 091-SB Street Bar - Grease Trap Pumping |  |
| 2026-04-06 | 179-CIG | GT | Completed | 1582 | 179-CIG Espanola Cigars - Grease Trap Pu |  |
| 2026-04-06 | 001-17 | GT | Completed | 1580 | 001-17 17 Restaurant and Sushi Bar - Gre |  |
| 2026-04-06 | 014-JOY | GT | Completed | 1581 | 167-JOY The Joyce - Grease trap pumping |  |
| 2026-04-06 | 040-MV | GT | Completed | 1579 | 040-MV Maison Valentine - Grease Trap Pu |  |
| 2026-03-31 | 062-TCE | GT | Completed | 1563 | 062-TCE The carrot express Aventura Mall | 2026-04-01 |
| 2026-03-31 | 199-JZ | GT | Completed | 1568 | 199-STK JZ Steak House - Grease Trap Pum | 2026-04-01 |
| 2026-03-31 | 181-PV | GT | Completed | 1564 | 181-PV Pura Vida Esplanade (Aventura) -  | 2026-04-01 |
| 2026-03-31 | 139-LTG | GT | Completed | 1566 | 139-LTG Lettuce and Tomato - Grease Trap | 2026-04-01 |
| 2026-03-31 | 144-LTG | GT | Completed | 1567 | 144-LTG (Bakery) Lettuce and Tomato Rest | 2026-04-01 |
| 2026-03-31 | 056-STM | GT | Completed | 1565 | 056-STM Sarah's Tent Market - Grease Tra | 2026-04-01 |
| 2026-03-30 | 186-PV | GT | Completed | 1560 | 186-PV Pura Vida Coconut Grove - Grease  | 2026-03-31 |
| 2026-03-30 | 133-MUT | GT | Completed | 1557 | 133-MU Mutra - Grease Trap Pumping | 2026-03-31 |
| 2026-03-30 | 182-PAL | GT | Completed | 1558 | 182-PAL The Palm - Grease trap pumping & | 2026-03-31 |
| 2026-03-26 | 072-TCE | GT | Completed | 1544 | 072-TCE The carrot express Sunset Harbor |  |
| 2026-03-26 | 200-PALO | GT | Completed | 1546 | Palomar - Grease Trap Pumping |  |
| 2026-03-26 | 188-ACA | GT | Completed | 1543 | 188-ACA Hebrew Academy - Service Agreeme |  |
| 2026-03-25 | 024-GRO | GT | Completed | 1537 | 024-GRO Grove Kosher LLC (Fort Lauderdal |  |
| 2026-03-25 | 028-HUM | GT | Completed | 1541 | 028-HUM Hummus Achla - Grease Trap Pumpi |  |
| 2026-03-25 | 030-KGC | GT | Completed | 1540 | 030-KGC Kosher Bagel Cove - Grease Trap  |  |
| 2026-03-25 | 117-BH | GT | Completed | 1542 | 117-BH Food Art Catering / Bh gourmet -  |  |
| 2026-03-25 | 106-ALC | GT | Completed | 1538 | 106-ALC A la Carte - Grease Trap Pumping |  |
| 2026-03-24 | 041-MB | GT | Completed | 1529 | 041-MB Marie Blachere - Grease Trap Pump |  |
| 2026-03-18 | 033-LG | GT | Completed | 1512 | 033-LG La Granja Allapattah - Grease Tra |  |
| 2026-03-17 | 099-PV | GT | Completed | 1501 | 099-PV Pura Vida Dadeland - Grease Trap  |  |
| 2026-03-16 | 071-TCE | GT | Completed | 1492 | 071-TCE The carrot express South Miami - |  |
| 2026-03-16 | 104-PV | GT | Completed | 1497 | 104-PV Pura Vida Miracle Mile LLC - Grea |  |
| 2026-03-16 | 036-LG | GT | Completed | 1493 | 036-LG La Granja South Miami - Grease Tr |  |
| 2026-03-16 | 068-TCE | GT | Completed | 1494 | 068-TCE The carrot express Coconut grove |  |
| 2026-03-16 | 092-TCE | GT | Completed | 1495 | 092-TCE The carrot express Coral Gables  |  |
| 2026-03-15 | 034-LG | GT | Completed | 1487 | 034-LG La Granja Calle 8 - Grease Trap P |  |
| 2026-03-15 | 035-LG | GT | Completed | 1489 | 035-LG La Granja Downtown - Grease Trap  |  |
| 2026-03-15 | 026-HAP | GT | Completed | 1490 | 026-HAP Happea's - Grease Trap Pumping & |  |
| 2026-03-12 | 013-DIM | GT | Completed | 1484 | 013-DIM Daughter of Israel Mikvah - Hydr |  |
| 2026-03-11 | 009-CN | GT | Completed | 1478 | 009-CN Casa Neos - Grease Trap Pumping |  |
| 2026-03-11 | 170-PV | GT | Completed | 1479 | 170-PV Pura Vida Bakery - Grease pumping |  |
| 2026-03-11 | 176-SOU | GT | Completed | 1480 | 176-SOU What Soup - Grease Trap Pumping |  |
| 2026-03-10 | 020-G7 | GT | Completed | 1473 | 020-G7 G7 Roof Top - Grease Trap Pumping |  |
| 2026-03-10 | 090-OAK | GT | Completed | 1472 | 090-OAK One Oak Beachwalk - Grease Trap  |  |
| 2026-03-10 | 067-TCE | GT | Completed | 1470 | 067-TCE The carrot express Central kitch |  |
| 2026-03-10 | 019-G7 | GT | Completed | 1474 | 019-GT G7 Kitchens 34&35 - Grease Trap P |  |
| 2026-03-08 | 196-PV | GT | Completed | 1455 | PV Pura Vida Pembroke Pines - Pictures |  |
| 2026-03-05 | 198-ARY | GT | Completed | 1445 | Aryeh Hochner - Grease Trap Pumping |  |
| 2026-03-05 | 087-BB | GT | Completed | 1446 | 087-BB Bagel Boss Harding Ave - Grease T |  |
| 2026-03-05 | 183-KRE | GT | Completed | 1451 | 183-KRE Kresy Kosher Pizza & Falafel Bar |  |
| 2026-03-05 | 029-JOS | GT | Completed | 1448 | 029-JOS Josh's Deli - Grease Trap Pumpin |  |
| 2026-03-05 | 091-SB | GT | Completed | 1450 | 091-SB Street Bar - Grease Trap Pumping |  |
| 2026-03-04 | 040-MV | GT | Completed | 1441 | 040-MV Maison Valentine - Grease Trap Pu |  |
| 2026-03-04 | 132-PUM | GT | Completed | 1443 | 132-PU Pummarola - Grease Trap Pumping & |  |
| 2026-03-04 | 171-CAF | GT | Completed | 1440 | 171-KA Kaffe - Grease Pumping |  |
| 2026-03-04 | 039-HSE | GT | Completed | 1444 | 039-HSE Hiro's Sushi Express - Grease Tr |  |
| 2026-03-03 | 109-RAB | GT | Completed | 1437 | 109-RAB Rice and Beans - Grease Trap Pum |  |
| 2026-03-03 | 155-PV | GT | Completed | 1434 | 155-PV Pura Vida Flamingo - Grease Trap  |  |

### Cloggy (1)

| AT Visit Date | Client Code | Service | AT Status | DB visit_id | DB title | DB date (if mismatch) |
|---|---|---|---|---|---|---|
| 2026-04-09 | 032-LG | GT | Completed | 1596 | 032-LG La Granja 36th St - Hydrojet Clea |  |

### NULL (30)

| AT Visit Date | Client Code | Service | AT Status | DB visit_id | DB title | DB date (if mismatch) |
|---|---|---|---|---|---|---|
| 2026-05-06 | 208-HUB | GT | Upcoming | 3921 | Hubble Bubble Lounge - Service | 2026-05-05 |
| 2026-04-28 | 022-GRO | GT | Completed | 1721 | 022-GRO Grove Kosher LLC (Boca Raton) -  | 2026-04-27 |
| 2026-04-28 | 199-JZ | GT | Completed | 1799 | 199-STK JZ Steak House - Grease Trap Pum |  |
| 2026-04-27 | 178-LG | GT | Completed | 1790 | 178-LG La Granja Flager - Grease Trap Pu |  |
| 2026-04-27 | 205-SAS | GT | Completed | 1788 | Sassi - Grease Trap pumping |  |
| 2026-04-27 | 206-CAC | GT | Completed | 1789 | Cacio e Pepe - Grease trap pumping |  |
| 2026-04-22 | 009-CN | GT | Completed | 1738 | 009-CN Casa Neos - Grease Trap Pumping |  |
| 2026-04-22 | 016-FIA | GT | Completed | 1614 | 016-FIA Florida Food Eats LLC Fialkoff’s |  |
| 2026-04-21 | 013-DIM | GT | Completed | 1746 | 013-DIM Daughter of Israel Mikvah - Hydr |  |
| 2026-04-19 | 045-NU | GT | Completed | 1729 | 045-NU Nu Real Food - Grease Trap Pumpin |  |
| 2026-04-19 | 084-ULT | GT | Completed | 1575 | 084-ULT Ultra Padel Club - Grey Water Pu |  |
| 2026-04-16 | 042-MT | GT | Completed | 1713 | 042-MT Miami twist LLC - emergency call | 2026-04-15 |
| 2026-04-16 | 007-CC | GT | Completed | 1607 | 007-CC Cafe Club - Grease Trap Pumping |  |
| 2026-04-15 | 083-SHUL | GT | Completed | 1598 | 083-SHUL The Shul - Grease Trap Pumping  |  |
| 2026-04-14 | 043-MIL | GT | Completed | 1622 | 043-MIL Mila - Grease Trap Pumping & War | 2026-04-13 |
| 2026-04-14 | 019-G7 | GT | Completed | 1611 | 019-GT G7 Kitchens 34&35 - Grease Trap P |  |
| 2026-04-14 | 043-MIL | GT | Completed | 1622 | 043-MIL Mila - Grease Trap Pumping & War | 2026-04-13 |
| 2026-04-14 | 058-SOH | GT | Completed | 1594 | 058-SOH Soho Asian Bar and Grill - Greas |  |
| 2026-04-13 | 036-LG | GT | Completed | 1620 | 036-LG La Granja South Miami - Grease Tr |  |
| 2026-04-13 | 092-TCE | GT | Completed | 1619 | 092-TCE The carrot express Coral Gables  |  |
| 2026-04-13 | 140-TYO | GT | Completed | 1621 | 140-TCY Tacos yoyo - Grease Trap Pumping |  |
| 2026-04-08 | 192-FRK | GT | Completed | 1593 | 192-FRK Fresko - Grease Trap Pumping |  |
| 2026-04-01 | 197-BGT | GT | Completed | 1573 | Bagatelle Miami River - Grease Trap Pump | 2026-04-02 |
| 2026-04-01 | 061-TCE | GT | Completed | 1571 | 061-TCE The carrot express 71st Collins  | 2026-04-02 |
| 2026-04-01 | 047-PAM | GT | Completed | 1572 | 047-PAM Pamplemousse On the bay - Grease | 2026-04-02 |
| 2026-03-24 | 089-COW | GT | Completed | 1532 | 089-COW Cowy Burger - Grease Trap Pumpin |  |
| 2026-03-24 | 111-YC | GT | Completed | 1530 | 111-YC Yann Couvreur - Grease Trap Pumpi |  |
| 2026-03-19 | 175-PV | GT | Completed | 1516 | 175-PV Pura Vida Brickell 701 - Grease T |  |
| 2026-03-09 | 061-TCE | GT | Completed | 1464 | 061-TCE The carrot express 71st Collins  |  |
| 2026-03-05 | 174-VIN | GT | Completed | 1452 | 174-VIN Vincenzos Pizzeria - Grease Trap |  |

### NO_MATCH (8)

| AT Visit Date | Client Code | Service | AT Status | DB visit_id | DB title | DB date (if mismatch) |
|---|---|---|---|---|---|---|
| 2026-05-08 | 212-TRUE | GT | Completed | - |  |  |
| 2026-04-27 | 207-BAR | GT | Completed | - |  |  |
| 2026-04-14 | 057-SLS | GT | Completed | - |  |  |
| 2026-04-14 | 174-VIN | GT | Completed | - |  |  |
| 2026-04-06 | 174-VIN | GT | Completed | - |  |  |
| 2026-04-06 | 174-VIN | GT | Completed | - |  |  |
| 2026-03-23 | 076-TCE | GT | Completed | - |  |  |
| 2026-03-23 | 044-MP | GT | Completed | - |  |  |