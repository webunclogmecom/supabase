# Phase 2c — 50-GDO Bot Batch Results

Total: 36 rows · Generated from `12_phase_2c_results.json`

## Counts (auto-apply vs defer)

**Auto-applying:**
- CONFIRMED_MATCH: **12**
- WRONG_CLIENT (clean DEMOTE, low name similarity): **9**
- DIFFERENT_TENANT (clean DEMOTE, low name similarity): **3**
- NO_PERMIT (DEMOTE): **0**

**Deferring to Viktor:**
- WRONG_GDO_NUMBER (all): **1** — bot's `name_match` is unreliable; identity-changing UPDATE is too risky to auto-apply
- WRONG_CLIENT with name similarity (SUSPECT_NAME_VARIATION): **1** — might actually be matches
- DIFFERENT_TENANT with name similarity: **0** — might actually be matches
- AMBIGUOUS / ERROR: **0**


## CONFIRMED_MATCH (auto-apply) (12)

| id | gdo_number | client_code | client_name | bot_freq | bot_exp | bot_issued_to | name_sim |
|---|---|---|---|---|---|---|---|
| 76 | GDO-09017 | 033-LG | La Granja Allapattah | 90 | 2026-12-31 | LA GRANJA ALLAPATTAH CORP DBA LA GR... | 0.6 |
| 78 | GDO-09077 | 178-LG | La Granja Flager | 90 | 2026-12-31 | LA GRANJA FLAGLER CORPORATION DBA L... | 0.53 |
| 79 | GDO-06989 | 039-HSE | Hiro's Sushi Express | 30 | 2026-12-31 | HIRO'S SUSHI EXPRESS | 1.0 |
| 81 | GDO-15359 | 145-NON | International Foods By Noni... | 90 | 2026-12-31 | INTERNATIONAL FOODS BY NONI LLC | 0.82 |
| 85 | GDO-05180 | 129-BSC | Bet Shira Congretation | 90 | 2026-12-31 | BET SHIRA CONGREGATION | 0.95 |
| 91 | GDO-11186 | 086-ZAK | Zak the Baker | 30 | 2026-12-31 | ZTB I, LLC DBA ZAK THE BAKER | 0.82 |
| 93 | GDO-03917 | 014-JOY | The Joyce | 60 | 2026-12-31 | CORNER ESPANOLA LLC. DBA. THE JOYCE | 0.38 |
| 96 | GDO-00992 | 029-JOS | Josh's Deli | 30 | 2026-12-31 | CHOW DOWN GRILL, INC. DBA JOSH'S DE... | 0.53 |
| 102 | GDO-08912 | 139-LTG | Lettuce and Tomato | 90 | 2026-12-31 | LETTUCE & TOMATO RESTAURANT, LLC | 1.0 |
| 107 | GDO-07696 | 107-PV | Pura Vida SOBE | 60 | 2026-12-31 | PURA VIDA MIAMI, LLC DBA PURA VIDA ... | 0.51 |
| 112 | GDO-13822 | 066-TCE | The carrot express Buena Vi... | 30 | 2024-12-31 | SANTA TERESA GROUP LLC DBA 100 MONT... | 0.37 |
| 117 | GDO-11228 | 050-PV | Pura Vida Brickell | 60 | 2026-12-31 | PURA VIDA BRICKELL LLC DBA PURA VID... | 0.78 |

## WRONG_CLIENT clean DEMOTE (auto-apply) (9)

| id | gdo_number | client_code | client_name | bot_freq | bot_exp | bot_issued_to | name_sim |
|---|---|---|---|---|---|---|---|
| 75 | GDO-00548 | 200-PALO | Palomar | 90 | 2026-12-31 | SOBE ALTON LLC DBA OSTERIA MORINI | 0.31 |
| 82 | GDO-04127 | 042-MT | Miami twist LLC | 90 | 2022-12-31 | PESKARA, LLC DBA DENNY'S #7134 | 0.09 |
| 97 | GDO-14934 | 180-PV | Pura Vida Kendall | 90 | 2026-12-31 | JEN'S CHICKEN PEN, INC. DBA CHICK-F... | 0.28 |
| 104 | GDO-11433 | 176-SOU | What Soup | 90 | 2026-12-31 | TIGER LIGHT, LLC DBA TAULA FRESH ME... | 0.2 |
| 105 | GDO-13175 | 130-RL | Richard Lonnie | 60 | 2026-12-31 | OUTBACK STEAKHOUSE OF FLORIDA LLC D... | 0.24 |
| 108 | GDO-04400 | 038-LR | Le rond | 90 | 2026-12-31 | 3500 HOTEL LLC. DBA CAMPO | 0.26 |
| 109 | GDO-05395 | 153-LTC | LTC Rentals | 90 | 2026-12-31 | VIVARIA FLORIDA, LLC DBA LANDSHARK ... | 0.21 |
| 111 | GDO-07564 | 118-MRJ | Mr Jones | 30 | 2026-12-31 | VENTURA CAPITAL ONE, LLC DBA CAVALI... | 0.24 |
| 116 | GDO-03620 | 000-DH | Homestead Dump | 90 | 2026-12-31 | MDCPS-HORACE MANN MIDDLE SCHOOL | 0.22 |

## DIFFERENT_TENANT clean DEMOTE (auto-apply) (3)

| id | gdo_number | client_code | client_name | bot_freq | bot_exp | bot_issued_to | name_sim |
|---|---|---|---|---|---|---|---|
| 89 | GDO-11230 | 037-LB | Le Basilic | 60 | 2026-12-31 | SHELBORNE HOTEL PARTNERS WC LP DBA ... | 0.29 |
| 94 | GDO-08682 | 012-DKC | Danziguer Kosher Catering | 90 | 2026-12-31 | FAIRFIELD INN & SUITES | 0.22 |
| 113 | GDO-06550 | 128-MF | Meir Fellig | 90 | 2026-12-31 | MDCPS-PALM SPRINGS NORTH ELEMENTARY | 0.13 |

## NO_PERMIT (auto-apply) (0)

_(none)_

## WRONG_GDO_NUMBER — DEFER (1)

| id | gdo_number | client_code | client_name | bot_freq | bot_exp | bot_issued_to | name_sim |
|---|---|---|---|---|---|---|---|
| 99 | GDO-10248 | 171-CAF | Ironside Cafe | 90 | 2022-12-31 | THE OM CENTER, LLC DBA PIZZA AT IRO... | 0.46 |

## WRONG_CLIENT SUSPECT_NAME_VARIATION — DEFER (1)

| id | gdo_number | client_code | client_name | bot_freq | bot_exp | bot_issued_to | name_sim |
|---|---|---|---|---|---|---|---|
| 86 | GDO-05625 | 011-CCC | Cine Citta Cafe (Franck Tai... | 90 | 2026-12-31 | CINE CITTA, LLC | 0.61 |

## DIFFERENT_TENANT with name similarity — DEFER (0)

_(none)_

## AMBIGUOUS / ERROR (defer) (0)

_(none)_