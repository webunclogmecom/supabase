-- 2026-05-25m_gdo_phase_2b_applies.sql (Viktor-approved 2026-05-25 PM, with conflict adjustment)
--
-- Phase 2b bot-batch applies. Generated from
--   docs/gdo-phase-2-2026-05-25/probes/09_phase_2b_results.json
-- via
--   docs/gdo-phase-2-2026-05-25/probes/10_phase_2b_analyze.py
-- then Viktor-approved on thread ts 1779725868.955249, and hand-edited
-- below for two AMBIGUOUS reclassifications + conflict-with-existing-row
-- adjustment in section 4-5.
--
-- SCOPE
--   1.  23 CONFIRMED_MATCH UPDATEs (max_frequency_days; +expiration if NULL)
--   2.  14 WRONG_CLIENT DEMOTEs to INACTIVE (real GDO at addr, wrong client)
--   3.   4 DIFFERENT_TENANT DEMOTEs to INACTIVE (no permit at addr)
--   4.   1 AMBIGUOUS reclassified to CONFIRMED_MATCH:
--          149-RUS Rustico (id=61). Viktor: "RUSTIKO" = "Rustico" (alt
--          spelling); "BH 9476" = Bay Harbor / 9476 Harding Ave.
--   5.   5 WRONG_GDO_NUMBER in-place UPDATEs (gdo_number + expiration +
--        notes) per Viktor's option (a):
--          - 208-HUB Hubble Bubble Lounge  id=133  GDO-08370 -> GDO-16086
--          - 036-LG  La Granja S Miami    id=125  GDO-12484 -> GDO-11708
--          - 148-MOR The Moore            id=59   GDO-11226 -> GDO-14769
--          - 170-PV  Pura Vida Bakery     id=7    GDO-11433 -> GDO-14681
--          - 155-PV  Pura Vida Flamingo   id=44   GDO-12838 -> GDO-10891
--   6.   2 WRONG_GDO_NUMBER -> DEMOTE (conflict-with-existing-row;
--        adjusted from Viktor's option (a)):
--          - 150-KOS Kosh  id=124  bot recommended GDO-13447, but id=68
--            (025-GRO Grove Kosher) already holds GDO-13447 at 9467 Harding
--            (10 doors from Kosh's 9477 Harding). Likely same business with
--            duplicate client rows.
--          - 172-NU Nu Real Coral gables  id=88  bot recommended GDO-11540,
--            but id=58 (045-NU Nu Real Food) already holds GDO-11540 at
--            3252 Buena Vista (next block from id=88's 3250 NE 1st Ave).
--            Same business, duplicate client rows.
--   7.  DEFERRED: 194-PV Pura Vida 41 (bot returned M & L FOOD MARKET; no
--        name match; Viktor: defer for ops verification).
--
-- TODO FOR FRED/YAN/OPS (not in this migration, surface separately)
--   Resolve duplicate client rows in public.clients:
--     - 150-KOS "Kosh"            vs 025-GRO "Grove Kosher LLC (Harding Ave)"
--     - 172-NU  "Nu Real food..." vs 045-NU "Nu Real Food"
--   Each pair appears to be the same business with two clients.id values.
--
-- IDEMPOTENT (Rule 5): every WHERE filters on current state. Re-run is no-op.
-- AUDIT (Rule 8): public.gdos audit trigger auto-generates app_source='sql' rows.
--
BEGIN;

-- ============================================================
-- 1. 23 CONFIRMED_MATCH UPDATEs (max_frequency_days only)
-- ============================================================
-- Trust bot's frequency_days. Don't overwrite permit_expiration:
--   - Group A (was NULL): use 2026-12-31 (current annual cycle assumption)
--   - Group B (already 2026-12-31 from 25l bulk): keep as-is
-- The bot occasionally returns stale dates (e.g. 2023-12-31 for Marie Blachere);
-- DERM annual renewal makes 2026-12-31 the truth right now.

UPDATE public.gdos SET max_frequency_days = 90, permit_expiration = '2026-12-31',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] CONFIRMED_MATCH via @GDO bot. issued_to="SEAFOOD ON THE TABLE, INC. DBA AROMAS DEL PERU", facility_name="AROMAS DEL PERU", max_frequency_days=90.'
WHERE id = 122 AND gdo_number = 'GDO-03342'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 90) AND (permit_expiration IS NULL OR permit_expiration < '2026-12-31');

UPDATE public.gdos SET max_frequency_days = 30, permit_expiration = '2026-12-31',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] CONFIRMED_MATCH via @GDO bot. issued_to="NB2J INVESTMENTS, LLC DBA FRESKO", facility_name="COOL WILD COMPANY LLC.\DBA THAT COOL CAFE", max_frequency_days=30.'
WHERE id = 129 AND gdo_number = 'GDO-08341'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 30) AND (permit_expiration IS NULL OR permit_expiration < '2026-12-31');

UPDATE public.gdos SET max_frequency_days = 90, permit_expiration = '2026-12-31',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] CONFIRMED_MATCH via @GDO bot. issued_to="LETTUCE & TOMATO RESTAURANT, LLC", facility_name="LUNA CREPESSE GOURMET DELI & BISTRO", max_frequency_days=90.'
WHERE id = 29 AND gdo_number = 'GDO-08912'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 90) AND (permit_expiration IS NULL OR permit_expiration < '2026-12-31');

UPDATE public.gdos SET max_frequency_days = 60, permit_expiration = '2026-12-31',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] CONFIRMED_MATCH via @GDO bot. issued_to="THE BROTHERS GROUP, LLC. DBA CACIO & PEPE", facility_name="HOLY BAGEL & PIZZARIA", max_frequency_days=60.'
WHERE id = 132 AND gdo_number = 'GDO-09070'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 60) AND (permit_expiration IS NULL OR permit_expiration < '2026-12-31');

UPDATE public.gdos SET max_frequency_days = 90,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] CONFIRMED_MATCH via @GDO bot. issued_to="MEY ENTERPRISE LLC. DBA. KRESY FALAFEL AND PIZZA BAR", facility_name="BONE ROME", max_frequency_days=90.'
WHERE id = 34 AND gdo_number = 'GDO-14528'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 90);

UPDATE public.gdos SET max_frequency_days = 30,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] CONFIRMED_MATCH via @GDO bot. issued_to="GOURMET HOSPITALITY GROUP LLC DBA MUTRA", facility_name="SAPMAHASARN, LLC.", max_frequency_days=30.'
WHERE id = 95 AND gdo_number = 'GDO-11986'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 30);

UPDATE public.gdos SET max_frequency_days = 60,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] CONFIRMED_MATCH via @GDO bot. issued_to="KRUDO, LLC", facility_name="KRUDO, LLC", max_frequency_days=60.'
WHERE id = 101 AND gdo_number = 'GDO-13141'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 60);

UPDATE public.gdos SET max_frequency_days = 30,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] CONFIRMED_MATCH via @GDO bot. issued_to="CARROT LOVE BRICKELL OPERATING LLC DBA CARROT EXPRESS", facility_name="STARBUCKS COFFEE", max_frequency_days=30.'
WHERE id = 77 AND gdo_number = 'GDO-06012'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 30);

UPDATE public.gdos SET max_frequency_days = 30,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] CONFIRMED_MATCH via @GDO bot. issued_to="MOZART CAFE SUNNY ISLES, INC. DBA MOZART CAFFE & CONVENIENCE", facility_name="COLLINS CONVENIENCE STORE", max_frequency_days=30.'
WHERE id = 52 AND gdo_number = 'GDO-06762'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 30);

UPDATE public.gdos SET max_frequency_days = 30,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] CONFIRMED_MATCH via @GDO bot. issued_to="ANGIE PERUVIAN KITCHEN, INC DBA SEVENTEEN SUSHI & BAR", facility_name="ANGIE PERUVIAN KITCHEN, INC dba SEVENTEEN SUSHI & BAR", max_frequency_days=30.'
WHERE id = 54 AND gdo_number = 'GDO-00092'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 30);

UPDATE public.gdos SET max_frequency_days = 60,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] CONFIRMED_MATCH via @GDO bot. issued_to="PURA VIDA AVENTURA PARK SQUARE LLC", facility_name="DELICIOUS RAW AVENTURA LLC.", max_frequency_days=60.'
WHERE id = 119 AND gdo_number = 'GDO-12970'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 60);

UPDATE public.gdos SET max_frequency_days = 60,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] CONFIRMED_MATCH via @GDO bot. issued_to="TJM HOSPITALITY GROUP, LLC DBA. COWY BURGER/THE WHITE ELEPHA", facility_name="ALTOR RESTAURANT", max_frequency_days=60.'
WHERE id = 12 AND gdo_number = 'GDO-10820'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 60);

UPDATE public.gdos SET max_frequency_days = 30,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] CONFIRMED_MATCH via @GDO bot. issued_to="CARROT LOVE COCONUT GROVE OPERATING LLC, DBA: CARROT EXPRESS", facility_name="HAAGEN-DAZS ICE CREAM", max_frequency_days=30.'
WHERE id = 41 AND gdo_number = 'GDO-05734'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 30);

UPDATE public.gdos SET max_frequency_days = 90,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] CONFIRMED_MATCH via @GDO bot. issued_to="MARIE BLACHERE HYDE MIAMI BAKERY, LLC", facility_name="MARIE BLACHERE HYDE MIAMI BAKERY, LLC", max_frequency_days=90.'
WHERE id = 69 AND gdo_number = 'GDO-14965'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 90);

UPDATE public.gdos SET max_frequency_days = 90,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] CONFIRMED_MATCH via @GDO bot. issued_to="PAMPLEMOUSSE ON THE BAY LLC D/B/A PAMPLEMOUSSE ON THE BAY", facility_name="PAMPLEMOUSSE ON THE BAY LLC", max_frequency_days=90.'
WHERE id = 84 AND gdo_number = 'GDO-14294'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 90);

UPDATE public.gdos SET max_frequency_days = 90,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] CONFIRMED_MATCH via @GDO bot. issued_to="CARROT LOVE RIVER LANDING LLC DBA CARROT EXPRESS", facility_name="CARROT EXPRESS", max_frequency_days=90.'
WHERE id = 114 AND gdo_number = 'GDO-14514'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 90);

UPDATE public.gdos SET max_frequency_days = 90,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] CONFIRMED_MATCH via @GDO bot. issued_to="AVIMARKABE CORP. DBA FUEGO BY MANA", facility_name="CCFP MIAMI, LLC. DBA CAMPANIA COOL FIRED PIZZA MIA", max_frequency_days=90.'
WHERE id = 30 AND gdo_number = 'GDO-12066'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 90);

UPDATE public.gdos SET max_frequency_days = 90,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] CONFIRMED_MATCH via @GDO bot. issued_to="CARROT LOVE CITY PLACE OPERATING LLC DBA CARROT EXPRESS", facility_name="MIXTURA RESTAURANT", max_frequency_days=90.'
WHERE id = 118 AND gdo_number = 'GDO-11170'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 90);

UPDATE public.gdos SET max_frequency_days = 30,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] CONFIRMED_MATCH via @GDO bot. issued_to="SHEPHERD ARTISAN COFFEE, LLC", facility_name="SHEPPERD PRTISON COFFEE", max_frequency_days=30.'
WHERE id = 80 AND gdo_number = 'GDO-10285'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 30);

UPDATE public.gdos SET max_frequency_days = 90,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] CONFIRMED_MATCH via @GDO bot. issued_to="AVA COCONUT GROVE LLC DBA AVA MEDITERRAEGEAN", facility_name="AVA RESTAURANT", max_frequency_days=90.'
WHERE id = 15 AND gdo_number = 'GDO-15675'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 90);

UPDATE public.gdos SET max_frequency_days = 30,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] CONFIRMED_MATCH via @GDO bot. issued_to="PURA VIDA DESIGN DISTRICT, LLC.", facility_name="BLUE BOTTLE COFFEE", max_frequency_days=30.'
WHERE id = 103 AND gdo_number = 'GDO-11710'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 30);

UPDATE public.gdos SET max_frequency_days = 90,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] CONFIRMED_MATCH via @GDO bot. issued_to="SBH FISH N'' CHIPS LLC. DBA BUBBY''S FISH N CHIPS", facility_name="MIAMI KOSHER DELI", max_frequency_days=90.'
WHERE id = 83 AND gdo_number = 'GDO-09945'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 90);

UPDATE public.gdos SET max_frequency_days = 90,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] CONFIRMED_MATCH via @GDO bot. issued_to="CARROT EXPRESS MIAMI SHORES LLC", facility_name="FUENTE OVEJUNA", max_frequency_days=90.'
WHERE id = 90 AND gdo_number = 'GDO-11328'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 90);

-- ============================================================
-- 2. 14 WRONG_CLIENT DEMOTEs to INACTIVE
-- ============================================================
-- DB had wrong client linked to a real GDO at the address;
-- the actual permit holder is in bot.issued_to.

-- id=130 GDO-01861 (193-FRK Fresko Bakery)
UPDATE public.gdos SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] DEMOTED. GDO-01861 actually belongs to "PITAS & PLATTERS RESTAURANT" per @GDO bot. Fresko Bakery has no DERM permit at its address.'
WHERE id = 130 AND gdo_number = 'GDO-01861' AND status = 'ACTIVE';

-- id=128 GDO-02118 (188-ACA Hebrew Academy)
UPDATE public.gdos SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] DEMOTED. GDO-02118 actually belongs to "SAN LAZARO CAFETERIA, INC." per @GDO bot. Hebrew Academy has no DERM permit at its address.'
WHERE id = 128 AND gdo_number = 'GDO-02118' AND status = 'ACTIVE';

-- id=131 GDO-05563 (203-GF Merav Halperin - Good Food)
UPDATE public.gdos SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] DEMOTED. GDO-05563 actually belongs to "FIRST MOON HOLDINGS LLC D/B/A CHINA MOON" per @GDO bot. Merav Halperin - Good Food has no DERM permit at its address.'
WHERE id = 131 AND gdo_number = 'GDO-05563' AND status = 'ACTIVE';

-- id=134 GDO-06685 (210-KAY Kayitili)
UPDATE public.gdos SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] DEMOTED. GDO-06685 actually belongs to "KORNDOG, LLC DBA KORNDOG" per @GDO bot. Kayitili has no DERM permit at its address.'
WHERE id = 134 AND gdo_number = 'GDO-06685' AND status = 'ACTIVE';

-- id=123 GDO-07382 (187-HAI Shalom Haifa)
UPDATE public.gdos SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] DEMOTED. GDO-07382 actually belongs to "MACITAS RESTAURANT, INC." per @GDO bot. Shalom Haifa has no DERM permit at its address.'
WHERE id = 123 AND gdo_number = 'GDO-07382' AND status = 'ACTIVE';

-- id=135 GDO-08422 (214-MYK Myka Brickell FT LLC)
UPDATE public.gdos SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] DEMOTED. GDO-08422 actually belongs to "777 BRICKELL PARTNERS LLC DBA TRULUCK''S SEAFOOD STEAK & CRAB" per @GDO bot. Myka Brickell FT LLC has no DERM permit at its address.'
WHERE id = 135 AND gdo_number = 'GDO-08422' AND status = 'ACTIVE';

-- id=18 GDO-11202 (202-CAP Capas Burger)
UPDATE public.gdos SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] DEMOTED. GDO-11202 actually belongs to "LR SUSHI LLC DBA TYO SUSHI" per @GDO bot. Capas Burger has no DERM permit at its address.'
WHERE id = 18 AND gdo_number = 'GDO-11202' AND status = 'ACTIVE';

-- id=92 GDO-11220 (136-BB Bagel Boss Miami Beach)
UPDATE public.gdos SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] DEMOTED. GDO-11220 actually belongs to "POLLO OPERATIONS, INC. DBA POLLO TROPICAL #0236" per @GDO bot. Bagel Boss Miami Beach has no DERM permit at its address.'
WHERE id = 92 AND gdo_number = 'GDO-11220' AND status = 'ACTIVE';

-- id=106 GDO-11260 (123-EUC Euclid LLC)
UPDATE public.gdos SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] DEMOTED. GDO-11260 actually belongs to "MAIA SPIRITS & WINES LLC DBA AZUL SPIRITS & WINE, INC" per @GDO bot. Euclid LLC has no DERM permit at its address.'
WHERE id = 106 AND gdo_number = 'GDO-11260' AND status = 'ACTIVE';

-- id=23 GDO-11264 (138-ASW Arepas & Sand Wish ( Helen & ...)
UPDATE public.gdos SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] DEMOTED. GDO-11264 actually belongs to "CHEESESTEAK FOR SALE, LLC" per @GDO bot. Arepas & Sand Wish ( Helen & Jeff ) has no DERM permit at its address.'
WHERE id = 23 AND gdo_number = 'GDO-11264' AND status = 'ACTIVE';

-- id=98 GDO-11014 (085-VA Villa Azur)
UPDATE public.gdos SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] DEMOTED. GDO-11014 actually belongs to "NEARLEX LLC. DBA: DON PIETRO GELATO NORTH MIAMI BEACH" per @GDO bot. Villa Azur has no DERM permit at its address.'
WHERE id = 98 AND gdo_number = 'GDO-11014' AND status = 'ACTIVE';

-- id=49 GDO-08976 (063-TCE The Carrot Express (Aventura))
UPDATE public.gdos SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] DEMOTED. GDO-08976 actually belongs to "MDCPS-COCONUT PALM K-8 ACADEMY" per @GDO bot. The Carrot Express (Aventura) has no DERM permit at its address.'
WHERE id = 49 AND gdo_number = 'GDO-08976' AND status = 'ACTIVE';

-- id=87 GDO-03828 (084-ULT Ultra Padel Club)
UPDATE public.gdos SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] DEMOTED. GDO-03828 actually belongs to "MDCPS-SOUTHWOOD MIDDLE SCHOOL" per @GDO bot. Ultra Padel Club has no DERM permit at its address.'
WHERE id = 87 AND gdo_number = 'GDO-03828' AND status = 'ACTIVE';

-- id=43 GDO-14031 (105-CU Cook Unity)
UPDATE public.gdos SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] DEMOTED. GDO-14031 actually belongs to "SABORES LATINOS MIAMI LLC" per @GDO bot. Cook Unity has no DERM permit at its address.'
WHERE id = 43 AND gdo_number = 'GDO-14031' AND status = 'ACTIVE';

-- ============================================================
-- 3. 4 DIFFERENT_TENANT DEMOTEs to INACTIVE
-- ============================================================
-- Bot returned a different GDO at the address that doesn't match
-- our client by name. Our row is wrong on both axes.

-- id=127 GDO-05104 (114-CI Ceviche inka)
UPDATE public.gdos SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] DEMOTED. GDO-05104 does not appear at this address per @GDO bot. Address belongs to GDO-11886 "POLYNESIO LAKE RESTAURANT & BAR, INC." — different tenant, different GDO. Ceviche inka has no DERM permit here.'
WHERE id = 127 AND gdo_number = 'GDO-05104' AND status = 'ACTIVE';

-- id=121 GDO-11308 (201-ALA Aladdin Mediterranean food)
UPDATE public.gdos SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] DEMOTED. GDO-11308 does not appear at this address per @GDO bot. Address belongs to GDO-11629 "TORRE''S STORE CORP D/B/A U GAS" — different tenant, different GDO. Aladdin Mediterranean food has no DERM permit here.'
WHERE id = 121 AND gdo_number = 'GDO-11308' AND status = 'ACTIVE';

-- id=66 GDO-05180 (198-ARY Aryeh Hochner)
UPDATE public.gdos SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] DEMOTED. GDO-05180 does not appear at this address per @GDO bot. Address belongs to GDO-03278 "FAIRFIELD INN & SUITES" — different tenant, different GDO. Aryeh Hochner has no DERM permit here.'
WHERE id = 66 AND gdo_number = 'GDO-05180' AND status = 'ACTIVE';

-- id=53 GDO-12490 (083-SHUL The Shul)
UPDATE public.gdos SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] DEMOTED. GDO-12490 does not appear at this address per @GDO bot. Address belongs to GDO-10255 "PPG BAY HARBOR OWNER LLC" — different tenant, different GDO. The Shul has no DERM permit here.'
WHERE id = 53 AND gdo_number = 'GDO-12490' AND status = 'ACTIVE';

-- ============================================================
-- 4. 1 AMBIGUOUS reclassified to CONFIRMED_MATCH (per Viktor)
-- ============================================================
-- 149-RUS Rustico (id=61, GDO-08499). Bot returned name_match=false but
-- issued_to "BH 9476 INVESTMENTS LLC DBA RUSTIKO" — Viktor: same business,
-- alt spelling (Italian "Rustico" vs stylized "Rustiko"). BH 9476 = Bay
-- Harbor / 9476 Harding Ave (matches the area). Rustico is Group B (had
-- 2026-12-31 expiration from 25l bulk), so only max_frequency_days needs
-- the update.
UPDATE public.gdos SET max_frequency_days = 90,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] CONFIRMED_MATCH via @GDO bot (initially flagged AMBIGUOUS; Viktor confirmed RUSTIKO = Rustico alt spelling). issued_to="BH 9476 INVESTMENTS LLC DBA RUSTIKO", max_frequency_days=90.'
WHERE id = 61 AND gdo_number = 'GDO-08499'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 90);

-- ============================================================
-- 5. 5 WRONG_GDO_NUMBER in-place UPDATEs (Viktor option a)
-- ============================================================
-- Bot's issued_to confirms our CLIENT but says we have the wrong
-- gdo_number. UPDATE in place: gdo_number, permit_expiration (to current
-- annual cycle), and max_frequency_days when bot returned it. Add a
-- canonical correction note.

-- 208-HUB Hubble Bubble Lounge: GDO-08370 -> GDO-16086 (issued_to: HUBBLE BUBBLE CORP DBA HUBBLE BUBBLE)
UPDATE public.gdos SET gdo_number = 'GDO-16086', permit_expiration = '2026-12-31',
    max_frequency_days = 90,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] WRONG_GDO_NUMBER corrected from GDO-08370 to GDO-16086 per @GDO bot lookup. issued_to="HUBBLE BUBBLE CORP DBA HUBBLE BUBBLE", max_frequency_days=90, expiration set to current cycle.'
WHERE id = 133 AND gdo_number = 'GDO-08370';

-- 036-LG La Granja South Miami: GDO-12484 -> GDO-11708 (issued_to: FG GROUP INT'L, CORP. DBA LA GRANJA ON NORTH MIAM...)
UPDATE public.gdos SET gdo_number = 'GDO-11708', permit_expiration = '2026-12-31',
    max_frequency_days = 60,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] WRONG_GDO_NUMBER corrected from GDO-12484 to GDO-11708 per @GDO bot lookup. issued_to="FG GROUP INT''L, CORP. DBA LA GRANJA ON NORTH MIAMI", max_frequency_days=60, expiration set to current cycle.'
WHERE id = 125 AND gdo_number = 'GDO-12484';

-- 148-MOR The Moore: GDO-11226 -> GDO-14769 (facility: MIAMI DD CLUB, LLC dba MOORE CLUB BEV CO)
-- Bot returned NULL frequency_days for this row; skip the max_frequency_days update.
UPDATE public.gdos SET gdo_number = 'GDO-14769', permit_expiration = '2026-12-31',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] WRONG_GDO_NUMBER corrected from GDO-11226 to GDO-14769 per @GDO bot lookup. facility_name="MIAMI DD CLUB, LLC dba MOORE CLUB BEV CO", expiration set to current cycle. max_frequency_days remains NULL (bot did not extract it; rerun in Phase 2c).'
WHERE id = 59 AND gdo_number = 'GDO-11226';

-- 170-PV Pura Vida Bakery: GDO-11433 -> GDO-14681 (issued_to: PURA VIDA ENTERPRISES LLC DBA PURA VIDA MIAMI)
UPDATE public.gdos SET gdo_number = 'GDO-14681', permit_expiration = '2026-12-31',
    max_frequency_days = 90,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] WRONG_GDO_NUMBER corrected from GDO-11433 to GDO-14681 per @GDO bot lookup. issued_to="PURA VIDA ENTERPRISES LLC DBA PURA VIDA MIAMI", max_frequency_days=90, expiration set to current cycle.'
WHERE id = 7 AND gdo_number = 'GDO-11433';

-- 155-PV Pura Vida Flamingo: GDO-12838 -> GDO-10891 (issued_to: PURA VIDA COLLINS LOEWS LLC)
UPDATE public.gdos SET gdo_number = 'GDO-10891', permit_expiration = '2026-12-31',
    max_frequency_days = 60,
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] WRONG_GDO_NUMBER corrected from GDO-12838 to GDO-10891 per @GDO bot lookup. issued_to="PURA VIDA COLLINS LOEWS LLC", max_frequency_days=60, expiration set to current cycle.'
WHERE id = 44 AND gdo_number = 'GDO-12838';

-- ============================================================
-- 6. 2 WRONG_GDO_NUMBER -> DEMOTE (conflict-with-existing-row)
-- ============================================================
-- Bot's corrected gdo_number already exists on another row in our DB,
-- linked to a duplicate client. UPDATE in place would violate gdo_number
-- uniqueness (operationally) and create data confusion. DEMOTE the wrong
-- row instead; the correct linkage is already preserved on the sibling.

-- 150-KOS Kosh id=124 -- GDO-13447 already at id=68 (025-GRO Grove Kosher LLC, 9467 Harding Ave; Kosh sits at 9477 Harding next door).
UPDATE public.gdos SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] DEMOTED. Bot recommended GDO-13447 for this row but id=68 (025-GRO Grove Kosher LLC, 9467 Harding) already holds GDO-13447 — same business / address neighbors (10 doors apart). Clients 150-KOS "Kosh" and 025-GRO "Grove Kosher LLC" appear to be duplicate client rows; flag for ops cleanup. Demoting this row instead of UPDATE-in-place to avoid duplicate gdo_number.'
WHERE id = 124 AND gdo_number = 'GDO-04943' AND status = 'ACTIVE';

-- 172-NU Nu Real food - Coral gables id=88 -- GDO-11540 already at id=58 (045-NU Nu Real Food, 3252 Buena Vista; id=88 at 3250 NE 1st Ave is the same block).
UPDATE public.gdos SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') || '[2026-05-25 Phase 2b] DEMOTED. Bot recommended GDO-11540 for this row but id=58 (045-NU Nu Real Food, 3252 Buena Vista) already holds GDO-11540 — same business / adjacent block. Clients 172-NU "Nu Real food - Coral gables" and 045-NU "Nu Real Food" appear to be duplicate client rows; flag for ops cleanup. Demoting this row instead of UPDATE-in-place to avoid duplicate gdo_number.'
WHERE id = 88 AND gdo_number = 'GDO-07733' AND status = 'ACTIVE';

COMMIT;

-- ============================================================
-- VERIFICATION (run after apply)
-- ============================================================
-- 1. CONFIRMED_MATCH UPDATEs landed (24 = 23 original + Rustico)
--    SELECT COUNT(*) FROM gdos
--    WHERE max_frequency_days IS NOT NULL AND notes LIKE '%[2026-05-25 Phase 2b] CONFIRMED_MATCH%';
--    Expected: 24
--
-- 2. 5 WRONG_GDO_NUMBER in-place UPDATEs landed
--    SELECT id, gdo_number FROM gdos WHERE id IN (133, 125, 59, 7, 44);
--    Expected: GDO-16086, GDO-11708, GDO-14769, GDO-14681, GDO-10891 (none of the old numbers)
--
-- 3. ACTIVE count
--    SELECT COUNT(*) FILTER (WHERE status='ACTIVE')::int FROM gdos;
--    Expected: 131 - 18 - 2 = 111 (4 WRONG_CLIENT_2a + 14 WRONG_CLIENT_2b + 4 DIFFERENT_TENANT + 2 conflict-demote = 24 INACTIVE total)
--
-- 4. INACTIVE count
--    SELECT COUNT(*) FILTER (WHERE status='INACTIVE')::int FROM gdos;
--    Expected: 4 + 14 + 4 + 2 = 24
--
-- 5. Phase 2b audit rows generated
--    SELECT COUNT(*) FROM audit.logs
--    WHERE table_name='gdos' AND changed_at > now() - interval '5 minutes' AND app_source='sql';
--    Expected: at least 31 = 23 confirmed + 1 Rustico + 5 in-place + 2 demote + 14 wrong-client + 4 diff-tenant. Audit may merge identical UPDATEs if a row was already in the target state (idempotent re-run).
