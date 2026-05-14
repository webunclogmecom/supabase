# Yan — service config fix list

_Generated 2026-05-14 from live Supabase audit. 77 total rows across 3 priority buckets._

Fix everything in Airtable. Our DB syncs on the next `populate.js --step=5` run.

## Part 1 — NEEDS_FREQ (2 rows) — HIGH PRIORITY

These have a price set but no cadence, so the daily cron **won't schedule any upcoming visits for them**. Set the freq in AT (`GT/CL/WD Frequency` in days).

| Client | Service | Price | Set freq to… |
|---|---|---|---|
| 090-OAK OAK One Oak Beachwalk | CL | $0.00 | ? days |
| 169-TCE TCE The Carrot Express Oakland Park | CL | $200.00 | ? days |

## Part 2 — NEEDS_PRICE (3 rows) — MEDIUM PRIORITY

These have a cadence so the cron schedules them, but they have no `$ per Visit` in AT, so any invoice will land at $0.

| Client | Service | Freq (days) | Set price to… |
|---|---|---|---|
| 049-PV PV Pura Vida (Bay Harbor) | CL | 60 | $? |
| 110-CLA CLA Claudie | CL | 30 | $? |
| 139-LTG LTG Lettuce and Tomato | CL | 60 | $? |

## Part 3 — NEEDS_BOTH (72 rows) — LOW PRIORITY (decide: real or noise)

These came from AT clients where the `Service Type` multi-select has a service ticked (GT/CL/WD) but **neither cadence nor price is filled in**. Either:

- **The client really gets this service** → fill freq + price in AT
- **The service-type checkbox was aspirational / left over** → uncheck it in AT

Most of these are WD (Water Discharge) — that program may not have fully rolled out yet. Either way, deciding will clear the noise from the data model.

| Client | Service | Decision |
|---|---|---|
| 004-BAO BAO Baoli Miami | WD | fill in or uncheck |
| 009-CN CN Casa Neos | WD | fill in or uncheck |
| 012-DKC DKC Danziguer Kosher Catering | WD | fill in or uncheck |
| 014-JOY JOY The Joyce | CL | fill in or uncheck |
| 021-GRA GRA Granada Condo | WD | fill in or uncheck |
| 022-GRO GRO Grove Kosher LLC (Boca Raton) | CL | fill in or uncheck |
| 023-GRO GRO Grove Kosher LLC (Delray Beach) | CL | fill in or uncheck |
| 024-GRO GRO Grove Kosher LLC (Fort Lauderdale) | CL | fill in or uncheck |
| 026-HAP HAP Happea's | WD | fill in or uncheck |
| 031-KRU KRU Krudo Fish Market | WD | fill in or uncheck |
| 032-LG LG La Granja 36th St | WD | fill in or uncheck |
| 033-LG LG La Granja Allapattah | WD | fill in or uncheck |
| 034-LG LG La Granja Calle 8 | WD | fill in or uncheck |
| 035-LG LG La Granja Downtown | WD | fill in or uncheck |
| 036-LG LG La Granja South Miami | WD | fill in or uncheck |
| 037-LB LB Le Basilic | CL | fill in or uncheck |
| 039-HSE HSE Hiro's Sushi Express | CL | fill in or uncheck |
| 039-HSE HSE Hiro's Sushi Express | WD | fill in or uncheck |
| 042-MT MT Miami twist LLC | CL | fill in or uncheck |
| 043-MIL MIL Mila | WD | fill in or uncheck |
| 045-NU NU Nu Real Food | CL | fill in or uncheck |
| 047-PAM PAM Pamplemousse On the bay | WD | fill in or uncheck |
| 058-SOH SOH Soho Asian Bar and Grill | WD | fill in or uncheck |
| 062-TCE TCE The carrot express Aventura Mall | WD | fill in or uncheck |
| 063-TCE TCE The Carrot Express (Aventura) | WD | fill in or uncheck |
| 064-TCE TCE The carrot express Boca Raton | WD | fill in or uncheck |
| 065-TCE TCE The carrot express Brickell | WD | fill in or uncheck |
| 066-TCE TCE The carrot express Buena Vista Miami | WD | fill in or uncheck |
| 067-TCE TCE The carrot express Central kitchen | WD | fill in or uncheck |
| 068-TCE TCE The carrot express Coconut grove | WD | fill in or uncheck |
| 069-TCE TCE The carrot express Downtown | WD | fill in or uncheck |
| 070-TCE TCE The carrot express Miami shores | WD | fill in or uncheck |
| 071-TCE TCE The carrot express South Miami | WD | fill in or uncheck |
| 072-TCE TCE The carrot express Sunset Harbor | WD | fill in or uncheck |
| 073-TCE TCE The carrot express Coconut Creek | WD | fill in or uncheck |
| 074-TCE TCE The carrot express Doral | WD | fill in or uncheck |
| 075-TCE TCE The carrot express Fort Lauderdale | WD | fill in or uncheck |
| 076-TCE TCE The carrot express Hollywood | WD | fill in or uncheck |
| 077-TCE TCE The carrot express Kendall | WD | fill in or uncheck |
| 078-TCE TCE The carrot express Pembroke Pines | WD | fill in or uncheck |
| 079-TCE TCE The carrot express Plantation | WD | fill in or uncheck |
| 080-TCE TCE The carrot express River Landing | WD | fill in or uncheck |
| 081-TCE TCE The carrot express West Boca, Shadowwood Plaza | WD | fill in or uncheck |
| 089-COW COW Cowy Burger | WD | fill in or uncheck |
| 092-TCE TCE The carrot express Coral Gables | WD | fill in or uncheck |
| 093-KC KC KC Market | CL | fill in or uncheck |
| 093-KC KC KC Market | WD | fill in or uncheck |
| 109-RAB RAB Rice and Beans | CL | fill in or uncheck |
| 110-CLA CLA Claudie | WD | fill in or uncheck |
| 132-PUM PU Pummarola | CL | fill in or uncheck |
| 132-PUM PU Pummarola | WD | fill in or uncheck |
| 133-MUT MU Mutra | CL | fill in or uncheck |
| 142-57 57 Ocean Residences | CL | fill in or uncheck |
| 152-DAV DAV Davinci | CL | fill in or uncheck |
| 154-PV PV Pura Vida Fisher Island | CL | fill in or uncheck |
| 155-PV PV Pura Vida Flamingo | CL | fill in or uncheck |
| 168-AVA AVA AVA | CL | fill in or uncheck |
| 169-TCE TCE The Carrot Express Oakland Park | WD | fill in or uncheck |
| 170-PV PV Pura Vida Bakery | CL | fill in or uncheck |
| 174-VIN VIN Vincenzos Pizzeria | WD | fill in or uncheck |
| 175-PV PV Pura Vida Brickell 701 | CL | fill in or uncheck |
| 176-SOU SOU What Soup | CL | fill in or uncheck |
| 177-PV PV pura Vida Doral | CL | fill in or uncheck |
| 179-CIG CIG Espanola Cigars | CL | fill in or uncheck |
| 179-CIG CIG Espanola Cigars | WD | fill in or uncheck |
| 181-PV PV Pura Vida Esplanade (Aventura) | CL | fill in or uncheck |
| 182-PAL PAL The Palm | CL | fill in or uncheck |
| 186-PV PV Pura Vida Coconut Grove | CL | fill in or uncheck |
| 191-TEN TEN Tends | CL | fill in or uncheck |
| 199-JZ STK JZ Steak House | CL | fill in or uncheck |
| 208-HUB HUB Hubble Bubble Lounge | CL | fill in or uncheck |
| 215-GT G7 Kitchen 35 | GT | fill in or uncheck |

## Part 4 — Other anomalies spotted during audit

- **175-PV Pura Vida Brickell** — `GT First Visit Date = 2028-11-29` in AT. Typo, 2.5 years in the future. Skews our anchor calculation. Fix to the real first-visit date.
- **140-TYO Tacos Yoyo** — AT has `Client Code #3 = 140-TCY`. Jobber and our DB say `140-TYO`. Fix AT to match.
- **"Casa Neos BAR" record in AT** — exists with no Jobber link. Either onboard it as a real second location of 009-CN Casa Neos, or delete from AT.
- **AT "Recuring" single-select option** — typo with one r. We normalize to "RECURRING" on read. Renaming the AT option to "Recurring" would clean it at the source.

## When done

Ping Fred — we re-run `node scripts/populate/populate.js --step=5 --execute --confirm` to pull the updated configs into Supabase. ~30s.
