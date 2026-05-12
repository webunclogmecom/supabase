# Goliath reattribution list with Airtable Record IDs — 2026-05-12

## Summary

| Correct truck (per Supabase GPS) | Count | AT field update | AI/script can apply? |
|---|---|---|---|
| Moises | 89 | Set `Truck = "Moises 9,000"` | ✅ yes |
| NULL | 30 | No GPS — defer to operator | ⚠ no (manual) |
| NO_MATCH | 8 | No DB match — defer | ⚠ no (manual) |
| Cloggy | 1 | Set `Truck = "Cloggy 120"` | ✅ yes |

## How to apply automatically

A ready-to-execute JSON payload is at `reports/goliath_at_patch_payload_2026_05_12.json`. Format is Airtable's batch-update spec (up to 10 records per PATCH request). Hand it to any AI assistant with Airtable API access, or curl it directly:

```bash
# For each batch of 10 in the JSON file:
curl -X PATCH "https://api.airtable.com/v0/appjMgjjZPeuudqQR/Visits" \\
  -H "Authorization: Bearer $AIRTABLE_API_KEY" \\
  -H "Content-Type: application/json" \\
  -d @batch_N.json
```

Or if you have an MCP-connected Airtable AI assistant: just paste the JSON and ask it to apply each record as a Visits-table update with the given `Truck` field value.


## Moises (89) — set `Truck = "Moises 9,000"`

| AT Record ID | AT Visit Date | Client Code | Service | AT Status | DB visit_id | DB date (if mismatch) |
|---|---|---|---|---|---|---|
| `recDEMfdVtjcJlzO4` | 2026-05-05 | 114-CI | GT | Completed | 3913 | 2026-05-04 |
| `recKEOIHIiOVRZ7cs` | 2026-04-30 | 061-TCE | GT | Completed | 3896 |  |
| `recLdB6o3i7xOLDrB` | 2026-04-28 | 063-TCE | GT | Completed | 1803 |  |
| `recWSWNMkOJ6m9oV5` | 2026-04-28 | 031-KRU | GT | Completed | 1800 |  |
| `rec38GFQumIoxqgcp` | 2026-04-26 | 093-KC | GT | Completed | 1783 |  |
| `rec8Dw7vo5KxWKOE2` | 2026-04-26 | 114-CI | GT | Completed | 1785 |  |
| `recI7orpza14hhXZu` | 2026-04-26 | 169-TCE | GT | Completed | 1781 |  |
| `recZGDOrl5mswM0li` | 2026-04-26 | 106-ALC | GT | Completed | 1784 |  |
| `recyP2MG4hswc6OlO` | 2026-04-26 | 152-DAV | GT | Completed | 1782 |  |
| `recPjb2gybvhwabvz` | 2026-04-23 | 008-CV | GT | Completed | 1776 |  |
| `recVsAz8QkHXoqil0` | 2026-04-23 | 150-KOS | GT | Completed | 1773 |  |
| `recgh4wiKSWrhViBj` | 2026-04-23 | 149-RUS | GT | Completed | 1774 |  |
| `reciF3hPMvkqZznk8` | 2026-04-23 | 049-PV | GT | Completed | 1777 |  |
| `recAU8SzcYCPIvja6` | 2026-04-22 | 017-FIA | GT | Completed | 1775 | 2026-04-23 |
| `recfmwsceSLTa0027` | 2026-04-22 | 025-GRO | GT | Completed | 1769 |  |
| `rec2RsP4EpKU6clps` | 2026-04-20 | 034-LG | GT | Completed | 1736 |  |
| `recnufo2HgjMk9WwG` | 2026-04-20 | 065-TCE | GT | Completed | 1734 |  |
| `recoy06tAtCZSw6IB` | 2026-04-20 | 148-MOR | GT | Completed | 1737 |  |
| `recxoPoTtBthIqc9E` | 2026-04-20 | 026-HAP | GT | Completed | 1735 |  |
| `rec3etIIWKun44cHX` | 2026-04-19 | 111-YC | GT | Completed | 1728 |  |
| `recB3jiuZSewZm6Be` | 2026-04-19 | 032-LG | GT | Completed | 1726 |  |
| `recNbbfv1sncn7xLT` | 2026-04-19 | 033-LG | GT | Completed | 1727 |  |
| `recQLICfmV7MSSEjK` | 2026-04-16 | 135-BB | GT | Completed | 1722 |  |
| `recVY9dZccLgu6ali` | 2026-04-16 | 051-PV | GT | Completed | 1718 |  |
| `recZOsynLDLhTwyPb` | 2026-04-16 | 023-GRO | GT | Completed | 1719 |  |
| `reccJH7piG6rXXVCe` | 2026-04-16 | 064-TCE | GT | Completed | 1723 |  |
| `recczPUkjR2nYLyh1` | 2026-04-16 | 081-TCE | GT | Completed | 1720 |  |
| `recM5jJIYGRO6U2ZF` | 2026-04-14 | 187-HAI | GT | Completed | 1709 |  |
| `recc5PRYvtvasg0Oy` | 2026-04-11 | 012-DKC | GT | Completed | 1613 | 2026-04-12 |
| `recFvXX2aOp0YiLZQ` | 2026-04-10 | 103-BWC | GT | Completed | 1610 |  |
| `reciNQwxmrprpigWk` | 2026-04-10 | 090-OAK | GT | Completed | 1609 |  |
| `recv2QmdlpVMvbh6V` | 2026-04-10 | 067-TCE | GT | Completed | 1608 |  |
| `rec2z6PTJ6t745UXE` | 2026-04-08 | 137-BB | GT | Completed | 1590 |  |
| `recgBG0G0JGrr4fNf` | 2026-04-08 | 015-FLA | GT | Completed | 1591 |  |
| `recx85btAmCOogVrF` | 2026-04-08 | 193-FRK | GT | Completed | 1592 |  |
| `recbESp9yK6v8SQyg` | 2026-04-07 | 087-BB | GT | Completed | 1586 |  |
| `reccMgsGJ8bHbi77g` | 2026-04-07 | 091-SB | GT | Completed | 1587 |  |
| `rec1l8adVkMB6fDXa` | 2026-04-06 | 179-CIG | GT | Completed | 1582 |  |
| `recB6N5enqdm8inkL` | 2026-04-06 | 001-17 | GT | Completed | 1580 |  |
| `recb1TYzo8KZsDhk1` | 2026-04-06 | 014-JOY | GT | Completed | 1581 |  |
| `reccynvtFPtOICo5W` | 2026-04-06 | 040-MV | GT | Completed | 1579 |  |
| `rec8Urxy7LCkYZUKB` | 2026-03-31 | 062-TCE | GT | Completed | 1563 | 2026-04-01 |
| `recNbZUPjTM3YpVeK` | 2026-03-31 | 199-JZ | GT | Completed | 1568 | 2026-04-01 |
| `recVHhH25bOwrXBCX` | 2026-03-31 | 181-PV | GT | Completed | 1564 | 2026-04-01 |
| `recXxuUJoBjV47rIx` | 2026-03-31 | 139-LTG | GT | Completed | 1566 | 2026-04-01 |
| `recmwGqMjqL8qPGTB` | 2026-03-31 | 144-LTG | GT | Completed | 1567 | 2026-04-01 |
| `recq1CBaFZOg5dADt` | 2026-03-31 | 056-STM | GT | Completed | 1565 | 2026-04-01 |
| `recDEzi0NspNtozpv` | 2026-03-30 | 186-PV | GT | Completed | 1560 | 2026-03-31 |
| `recJnADC9sSK4G3Xi` | 2026-03-30 | 133-MUT | GT | Completed | 1557 | 2026-03-31 |
| `recztk3n8dLF5yNBr` | 2026-03-30 | 182-PAL | GT | Completed | 1558 | 2026-03-31 |
| `recWT3Q77LRz1KbK3` | 2026-03-26 | 072-TCE | GT | Completed | 1544 |  |
| `recm8Zwcv5ccIusdz` | 2026-03-26 | 200-PALO | GT | Completed | 1546 |  |
| `recpcu3PUwQAozs2Q` | 2026-03-26 | 188-ACA | GT | Completed | 1543 |  |
| `recDPkt8LnmdBddTd` | 2026-03-25 | 024-GRO | GT | Completed | 1537 |  |
| `recIVqxdiXGH4J5p4` | 2026-03-25 | 028-HUM | GT | Completed | 1541 |  |
| `recIxfJu8Jns6p2ba` | 2026-03-25 | 030-KGC | GT | Completed | 1540 |  |
| `recqJ4aZ8yDr1lH87` | 2026-03-25 | 117-BH | GT | Completed | 1542 |  |
| `recvnP4aJpMjhp4jy` | 2026-03-25 | 106-ALC | GT | Completed | 1538 |  |
| `recweJj3b9ThEScNQ` | 2026-03-24 | 041-MB | GT | Completed | 1529 |  |
| `recCkKIqfFMhbPgSN` | 2026-03-18 | 033-LG | GT | Completed | 1512 |  |
| `recbAESudIvdgbXxQ` | 2026-03-17 | 099-PV | GT | Completed | 1501 |  |
| `rec4afe2mPwaeo8oc` | 2026-03-16 | 071-TCE | GT | Completed | 1492 |  |
| `rec6mO5kCDQEeBvHJ` | 2026-03-16 | 104-PV | GT | Completed | 1497 |  |
| `recXi2wzU8pwjqoFr` | 2026-03-16 | 036-LG | GT | Completed | 1493 |  |
| `rece4ku33S2Ocevov` | 2026-03-16 | 068-TCE | GT | Completed | 1494 |  |
| `reczKrzV54Undl48o` | 2026-03-16 | 092-TCE | GT | Completed | 1495 |  |
| `recNmzu6uGE4FzsQN` | 2026-03-15 | 034-LG | GT | Completed | 1487 |  |
| `recj9yJDNPp2JaU4u` | 2026-03-15 | 035-LG | GT | Completed | 1489 |  |
| `recmlacC1AjRUE6RU` | 2026-03-15 | 026-HAP | GT | Completed | 1490 |  |
| `rectzPZEZYOF1tdwi` | 2026-03-12 | 013-DIM | GT | Completed | 1484 |  |
| `rec6kDpTGp2mRscm8` | 2026-03-11 | 009-CN | GT | Completed | 1478 |  |
| `recqSEFGA7zFX3Y40` | 2026-03-11 | 170-PV | GT | Completed | 1479 |  |
| `rectdHRu6a9ibehra` | 2026-03-11 | 176-SOU | GT | Completed | 1480 |  |
| `recOmtkaP7aTx4puG` | 2026-03-10 | 020-G7 | GT | Completed | 1473 |  |
| `recXXOk3SSIfaE2ZO` | 2026-03-10 | 090-OAK | GT | Completed | 1472 |  |
| `recc2P43HOeNwftqw` | 2026-03-10 | 067-TCE | GT | Completed | 1470 |  |
| `recsLXu2ZD0m0sKxw` | 2026-03-10 | 019-G7 | GT | Completed | 1474 |  |
| `recvNfkNsHgP60JM6` | 2026-03-08 | 196-PV | GT | Completed | 1455 |  |
| `rec2ZeCpk6Jg2TVde` | 2026-03-05 | 198-ARY | GT | Completed | 1445 |  |
| `rec5N3HnI5FS5zPrM` | 2026-03-05 | 087-BB | GT | Completed | 1446 |  |
| `rec66VPPqiRUKsaXU` | 2026-03-05 | 183-KRE | GT | Completed | 1451 |  |
| `recEe9g8098o0gxeP` | 2026-03-05 | 029-JOS | GT | Completed | 1448 |  |
| `recyxZXHH8au7FipH` | 2026-03-05 | 091-SB | GT | Completed | 1450 |  |
| `recJFCjCsRzeGYPDH` | 2026-03-04 | 040-MV | GT | Completed | 1441 |  |
| `recKWJleOKxTs7nye` | 2026-03-04 | 132-PUM | GT | Completed | 1443 |  |
| `recLdsU8TnjBqouNo` | 2026-03-04 | 171-CAF | GT | Completed | 1440 |  |
| `recYnIXppOzaRhHGC` | 2026-03-04 | 039-HSE | GT | Completed | 1444 |  |
| `recMXe1ew0ydh0uW0` | 2026-03-03 | 109-RAB | GT | Completed | 1437 |  |
| `recdpPSoHC65oCAnt` | 2026-03-03 | 155-PV | GT | Completed | 1434 |  |

## Cloggy (1) — set `Truck = "Cloggy 120"`

| AT Record ID | AT Visit Date | Client Code | Service | AT Status | DB visit_id | DB date (if mismatch) |
|---|---|---|---|---|---|---|
| `recGug63bXy9X5itQ` | 2026-04-09 | 032-LG | GT | Completed | 1596 |  |

## NULL (30)

| AT Record ID | AT Visit Date | Client Code | Service | AT Status | DB visit_id | DB date (if mismatch) |
|---|---|---|---|---|---|---|
| `rechNUoglldTGMiPD` | 2026-05-06 | 208-HUB | GT | Upcoming | 3921 | 2026-05-05 |
| `rec9ggGIbxlcBaeZU` | 2026-04-28 | 022-GRO | GT | Completed | 1721 | 2026-04-27 |
| `recVgt7TeAeBFJ9I9` | 2026-04-28 | 199-JZ | GT | Completed | 1799 |  |
| `rec2rdvfbkuglVwWB` | 2026-04-27 | 178-LG | GT | Completed | 1790 |  |
| `recNZNQlRKdjtWwrC` | 2026-04-27 | 205-SAS | GT | Completed | 1788 |  |
| `recZHAueOkUbx7YJ7` | 2026-04-27 | 206-CAC | GT | Completed | 1789 |  |
| `recDh0TSiVzRLq3dS` | 2026-04-22 | 009-CN | GT | Completed | 1738 |  |
| `recal08mXDKlY0jAg` | 2026-04-22 | 016-FIA | GT | Completed | 1614 |  |
| `rectcqtGbYXMxJ7KO` | 2026-04-21 | 013-DIM | GT | Completed | 1746 |  |
| `recGagmf68sMdFjST` | 2026-04-19 | 045-NU | GT | Completed | 1729 |  |
| `recqRamnqKJB01Yo4` | 2026-04-19 | 084-ULT | GT | Completed | 1575 |  |
| `recm7q5UG5U8VlmOl` | 2026-04-16 | 042-MT | GT | Completed | 1713 | 2026-04-15 |
| `recs6GyJ8BCLMsCnJ` | 2026-04-16 | 007-CC | GT | Completed | 1607 |  |
| `rectyGIbyjTICUQ9V` | 2026-04-15 | 083-SHUL | GT | Completed | 1598 |  |
| `recLn80N1vov1Ulwn` | 2026-04-14 | 043-MIL | GT | Completed | 1622 | 2026-04-13 |
| `recTYqLLh4VAqZF7m` | 2026-04-14 | 019-G7 | GT | Completed | 1611 |  |
| `recWJT5KgPZD6F4E2` | 2026-04-14 | 043-MIL | GT | Completed | 1622 | 2026-04-13 |
| `recqmpPi1xcP0azS5` | 2026-04-14 | 058-SOH | GT | Completed | 1594 |  |
| `rec0xi4wpASvPD1UQ` | 2026-04-13 | 036-LG | GT | Completed | 1620 |  |
| `recAaHfDbZvGnWVg8` | 2026-04-13 | 092-TCE | GT | Completed | 1619 |  |
| `recP6KXuHQqCGwYXH` | 2026-04-13 | 140-TYO | GT | Completed | 1621 |  |
| `recJlcFS1DYUWsRWm` | 2026-04-08 | 192-FRK | GT | Completed | 1593 |  |
| `recAoJEe3CTT6nYpX` | 2026-04-01 | 197-BGT | GT | Completed | 1573 | 2026-04-02 |
| `recYjpVYjQ3JX2tg5` | 2026-04-01 | 061-TCE | GT | Completed | 1571 | 2026-04-02 |
| `receMMg0cJjl7zdYQ` | 2026-04-01 | 047-PAM | GT | Completed | 1572 | 2026-04-02 |
| `recUo4AH3OGH5KwPA` | 2026-03-24 | 089-COW | GT | Completed | 1532 |  |
| `recfAVnjz2yj9Uh73` | 2026-03-24 | 111-YC | GT | Completed | 1530 |  |
| `recfPxv3yQbJcPcFk` | 2026-03-19 | 175-PV | GT | Completed | 1516 |  |
| `rec4lZmcxsd1qW2tA` | 2026-03-09 | 061-TCE | GT | Completed | 1464 |  |
| `rec1MUIdvnnisnaW5` | 2026-03-05 | 174-VIN | GT | Completed | 1452 |  |

## NO_MATCH (8)

| AT Record ID | AT Visit Date | Client Code | Service | AT Status | DB visit_id | DB date (if mismatch) |
|---|---|---|---|---|---|---|
| `rec0KVO4FWO4vQOhi` | 2026-05-08 | 212-TRUE | GT | Completed | - |  |
| `recK7T1yjVLhxdMuk` | 2026-04-27 | 207-BAR | GT | Completed | - |  |
| `recbT0g2skRydNOUW` | 2026-04-14 | 057-SLS | GT | Completed | - |  |
| `recu4cDNkjVzr3tIM` | 2026-04-14 | 174-VIN | GT | Completed | - |  |
| `recVR9jpKoGQRpejY` | 2026-04-06 | 174-VIN | GT | Completed | - |  |
| `recofaFKFtWwY7pft` | 2026-04-06 | 174-VIN | GT | Completed | - |  |
| `recLAifhG7DLsldZl` | 2026-03-23 | 076-TCE | GT | Completed | - |  |
| `recYZ8c5oC9EcdPEX` | 2026-03-23 | 044-MP | GT | Completed | - |  |