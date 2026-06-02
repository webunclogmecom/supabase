Phase 2b bot batch done. 50 GDOs through @GDO bot, results classified.

**Distribution:**
- CONFIRMED_MATCH: 23 (safe `max_frequency_days` UPDATEs)
- WRONG_CLIENT: 14 (DEMOTE — real GDO, wrong client linked)
- DIFFERENT_TENANT: 4 (DEMOTE — no permit for our client at address)
- WRONG_GDO_NUMBER: 7 (**NEEDS DECISION** — bot has correct gdo_number, want me to re-link?)
- AMBIGUOUS: 2 (deferred, need your eye)

**Critical bot quirk learned:** the bot's `facility_name` field grabs an unrelated permit at the same address — it's misleading. The reliable field is `issued_to` (e.g. "NB2J INVESTMENTS, LLC DBA FRESKO"). My classifier now keys off `issued_to` + `name_match`, which validates correctly.

**Asks (in priority order):**

1. **Approve draft migration `2026-05-25m`** which ships the 23 CONFIRMED_MATCH UPDATEs + 18 demotes. Path: `docs/migrations/2026-05-25m_gdo_phase_2b_applies.sql`. After ship: ACTIVE 131 -> 113, max_frequency_days non-NULL 6 -> 29.

2. **WRONG_GDO_NUMBER (7 rows)** — bot's `issued_to` confirms our CLIENT but says we have the wrong gdo_number. Options:
   - (a) UPDATE `gdo_number` in place (keeps row id + audit chain; simple)
   - (b) DEMOTE the wrong row + INSERT a new row with bot's gdo_number (cleaner history)
   - (c) DEMOTE the wrong row, no insert (let ops verify before re-adding)
   List:
   - 150-KOS Kosh (id=124): our `GDO-04943` -> bot `GDO-13447` (`GROVE KOSHER LLC`)
   - 208-HUB Hubble Bubble Lounge (id=133): our `GDO-08370` -> bot `GDO-16086` (`HUBBLE BUBBLE CORP DBA HUBBLE BUBBLE`)
   - 036-LG La Granja South Miami (id=125): our `GDO-12484` -> bot `GDO-11708` (`FG GROUP INT'L, CORP. DBA LA GRANJA ON NORTH MIAM...`)
   - 148-MOR The Moore (id=59): our `GDO-11226` -> bot `GDO-14769` (`MIAMI DD CLUB, LLC dba MOORE CLUB BEV CO / MOORE ...`)
   - 170-PV Pura Vida Bakery (id=7): our `GDO-11433` -> bot `GDO-14681` (`PURA VIDA ENTERPRISES LLC DBA PURA VIDA MIAMI`)
   - 172-NU Nu Real food - Coral gables (id=88): our `GDO-07733` -> bot `GDO-11540` (`STALK AND SPADE MIDTOWN LLC DBA NU REAL FOOD`)
   - 155-PV Pura Vida Flamingo (id=44): our `GDO-12838` -> bot `GDO-10891` (`PURA VIDA COLLINS LOEWS LLC`)

3. **AMBIGUOUS (2 rows)** — defer with reasoning:
   - 149-RUS Rustico (id=61, `GDO-08499`): bot returned `BH 9476 INVESTMENTS LLC DBA RUSTIKO` — edge case, want your judgment.
   - 194-PV Pura Vida 41 (id=72, `GDO-03375`): bot returned `COLLINS & 74 STREET CORP. DBA M & L FOOD MARKET` — edge case, want your judgment.

4. Anything you want me to spot-check from the 23 CONFIRMED_MATCH before I apply?
