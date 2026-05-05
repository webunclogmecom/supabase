# Yan to-do list — service config + abandoned client review

_Generated 2026-05-04 from Supabase audit (after fixing 58 visits stuck in 'scheduled' status due to a polling-cron bug)._

## Part 1: Fix 3 service-config frequencies in Airtable

These have invalid frequencies (0 days = invalid, >180 days = once a year or worse). Fix in Airtable — the webhook syncs to our DB automatically.

| Client code | Client name | Broken configs | Issue |
|---|---|---|---|
| 021-GRA | 021-GRA Granada Condo | CL=364, GT=360 | way too long (>180 days) |
| 056-STM | 056-STM Sarah's Tent Market | CL=240 | way too long (>180 days) |
| 167-FEN | 167-FEN Fendi Château Residences | CL=0 | zero — never service |

## Part 2: Review 13 abandoned clients — activate or mark INACTIVE/PAUSED

These are ACTIVE/Recuring clients with EITHER no completed visit ever OR last visit was more than 2x their service frequency ago. Decide each: schedule a first/next visit OR change status to INACTIVE/PAUSED.

| # | Client code | Client name | Configs | Last visit | Days since |
|---|---|---|---|---|---|
| 1 | 066-TCE | 066-TCE The carrot express Buena Vista M | CL:120 | never | ∞ |
| 2 | 073-TCE | 073-TCE The carrot express Coconut Creek | CL:120 | never | ∞ |
| 3 | 074-TCE | 074-TCE The carrot express Doral | CL:120 | never | ∞ |
| 4 | 079-TCE | 079-TCE The carrot express Plantation | CL:120 | never | ∞ |
| 5 | 080-TCE | 080-TCE The carrot express River Landing | CL:120 | never | ∞ |
| 6 | 107-PV | 107-PV Pura Vida SOBE | CL:90 | never | ∞ |
| 7 | 134-SC | 134-SC Shepherd Coffee | GT:90 | never | ∞ |
| 8 | 138-ASW | 138-ASW Arepas & Sand Wish ( Helen & Jef | GT:120 | never | ∞ |
| 9 | 142-57 | 142- 57 Ocean Residences | GT:60 | never | ∞ |
| 10 | 145-NON | International Foods By Noni (Arepas Noni | GT:60 | never | ∞ |
| 11 | 174-VIN | 174-VIN Vincenzos Pizzeria | GT:30 | 2026-03-05 | 61 |
| 12 | 180-PV | 180-PV Pura Vida Kendall | GT:60 | never | ∞ |
| 13 | 201-ALA | 201-ALA Aladdin Mediterranean food | GT:70 | never | ∞ |

## Part 3: Other items needing review

- **140-TYO typo**: in our DB the client_code is `140-TYO` but the Jobber/Airtable name is `140-TCY Tacos yoyo`. Pick one canonical spelling.
- **26 TCE chain locations on CL=120 days** — if 4 months between cleanings is the agreed chain standard, no action.
- **43 DERM manifests with NULL service_date** — sync gap from Airtable. Either Airtable rows are missing the date and need backfill, or accept the legacy gap.
- **8 commercial visits with no photos** — drivers should be taking photos. Visit IDs: 1241(174-VIN), 1279(170-PV), 1289(182-PAL), 1320(043-MIL), 1396(025-GRO), 1468(112-YA), 1716(195-MYK), 1730(191-TEN).
- **201-ALA Aladdin** — residential site, removed from list (had a meeting visit Apr 22 not tracked as service).
