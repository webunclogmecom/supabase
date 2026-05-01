-- =============================================================================
-- Merge duplicate primary properties — 2026-05-01
-- =============================================================================
-- 21 clients have two is_primary=TRUE rows for the same physical address,
-- differing only in formatting (Jobber-style "...city, state, zip, USA"
-- vs stripped, case, trailing whitespace, "Ave" vs "Avenue", "#104" vs
-- "104", etc.). All represent the same property — one was inserted via
-- populate.js step 6 (Jobber-formatted), the other via a later sync or
-- the gidless-merge ESL transfer.
--
-- Strategy:
--   - Keep the OLDER row (lower id) — typically has richer city/state/zip
--   - COALESCE missing fields from newer into older (no data lost)
--   - Reassign FK refs (visits, jobs, quotes, notes) from newer → older
--   - Reassign photo_links (entity_type='property') from newer → older
--   - Drop newer's ESL rows, then delete newer property
-- =============================================================================

BEGIN;

CREATE TEMP TABLE merge_pairs (keeper_id bigint, loser_id bigint) ON COMMIT DROP;
INSERT INTO merge_pairs VALUES
  (98, 425),    -- 000-DH
  (87, 436),    -- 027-HER
  (55, 411),    -- 034-LG
  (334, 409),   -- 038-LR
  (121, 437),   -- 062-TCE
  (106, 420),   -- 087-BB
  (362, 431),   -- 094-MOZ
  (85, 433),    -- 103-BWC
  (348, 416),   -- 108-ROA
  (119, 427),   -- 139-LTG
  (190, 428),   -- 142-57
  (120, 405),   -- 144-LTG
  (14, 452),    -- 152-DAV
  (63, 414),    -- 168-AVA
  (200, 432),   -- 172-NU
  (132, 404),   -- 175-PV
  (116, 435),   -- 181-PV
  (206, 421),   -- 190-LOU
  (46, 415),    -- 195-MYK
  (115, 422),   -- 197-BGT
  (77, 408);    -- 203-GF

-- 1. COALESCE missing fields from loser onto keeper (no data lost)
UPDATE properties k SET
  city = COALESCE(k.city, l.city),
  state = COALESCE(k.state, l.state),
  zip = COALESCE(k.zip, l.zip),
  county = COALESCE(k.county, l.county),
  zone = COALESCE(k.zone, l.zone),
  latitude = COALESCE(k.latitude, l.latitude),
  longitude = COALESCE(k.longitude, l.longitude),
  geofence_radius_meters = COALESCE(k.geofence_radius_meters, l.geofence_radius_meters),
  geofence_type = COALESCE(k.geofence_type, l.geofence_type),
  access_hours_start = COALESCE(k.access_hours_start, l.access_hours_start),
  access_hours_end = COALESCE(k.access_hours_end, l.access_hours_end),
  access_days = COALESCE(k.access_days, l.access_days),
  grease_trap_manhole_count = GREATEST(k.grease_trap_manhole_count, l.grease_trap_manhole_count),
  notes = COALESCE(k.notes, l.notes)
FROM merge_pairs m, properties l
WHERE k.id = m.keeper_id AND l.id = m.loser_id;

-- 2. Reassign FK references (visits, jobs, quotes, notes) — all NO ACTION
UPDATE visits SET property_id = m.keeper_id FROM merge_pairs m WHERE visits.property_id = m.loser_id;
UPDATE jobs   SET property_id = m.keeper_id FROM merge_pairs m WHERE jobs.property_id   = m.loser_id;
UPDATE quotes SET property_id = m.keeper_id FROM merge_pairs m WHERE quotes.property_id = m.loser_id;
UPDATE notes  SET property_id = m.keeper_id FROM merge_pairs m WHERE notes.property_id  = m.loser_id;

-- 3. Reassign photo_links (polymorphic, no FK constraint)
UPDATE photo_links pl SET entity_id = m.keeper_id
FROM merge_pairs m
WHERE pl.entity_type = 'property' AND pl.entity_id = m.loser_id;

-- 4. Move ESL refs for property — avoid UNIQUE conflict on (entity_type, source_system, source_id):
--    if keeper already has an ESL for the same source_system, prefer keeper's; drop loser's.
DELETE FROM entity_source_links del
USING merge_pairs m, entity_source_links keep
WHERE del.entity_type = 'property' AND del.entity_id = m.loser_id
  AND keep.entity_type = 'property' AND keep.entity_id = m.keeper_id
  AND keep.source_system = del.source_system;

-- Move surviving ESLs (no conflict) onto keeper
UPDATE entity_source_links esl SET entity_id = m.keeper_id
FROM merge_pairs m
WHERE esl.entity_type = 'property' AND esl.entity_id = m.loser_id;

-- 5. Delete the loser properties
DELETE FROM properties WHERE id IN (SELECT loser_id FROM merge_pairs);

COMMIT;
