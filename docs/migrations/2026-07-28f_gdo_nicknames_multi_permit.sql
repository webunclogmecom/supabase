-- ============================================================================
-- 2026-07-28f — GDO nicknames for the 3 remaining multi-permit clients
-- ============================================================================
-- Fred, 2026-07-28, supplying the facts himself for the 7 permits that
-- 2026-07-28e deliberately SKIPPED as ambiguous (multi-permit clients cannot be
-- defaulted to 'Main' without inventing data).
--
-- 043-MIL Mila — both permits held by MILA FLORIDA LLC at the same address,
--   split by grease-producing AREA:
--     GDO-11024 = restaurant operation, pumped every 90 days
--     GDO-14117 = bar/lounge,          pumped every 60 days
--   (Both max_frequency_days already match those numbers in the DB. Verified,
--   not assumed, so nothing to correct there.)
--
-- 148-MOR The Moore — Fred asked for "a more generic/semantic way" to reference
--   these two rather than pasting the legal entity names onto the card. That is
--   exactly the nickname/location_label split this schema already has:
--     nickname       = the short human label for WHICH area (what a driver reads)
--     location_label = the full permit/legal descriptor (what the permit carries)
--   Both location_labels are currently NULL, so the full detail is ADDITIVE here
--   and no existing value is overwritten:
--     GDO-11226 -> nickname 'Elastika',     label 'The Moore - Elastika Bev Co'
--     GDO-14769 -> nickname 'Club & Hotel', label 'The Moore - Moore Club / Hotel
--                                                  / Workplace Bev Co (Facility F, Level 4)'
--   Display is COALESCE(nickname, location_label, gdo_number), so the short
--   nickname wins on the card while the long descriptor stays queryable.
--
-- 242-WYN Wynd 28 — three separate tenants, each its own operator entity, so the
--   tenant name IS the semantic label:
--     GDO-13814 = Pasta       (Pasta Wynwood LLC)          90 days
--     GDO-14760 = Nino Gordo  (Super Escuadron Ninja LLC)  60 days  <- permit EXPIRED
--     GDO-16146 = Pari Pari   (HRB Wynwood LLC)            60 days
--   GDO-13814's location_label currently holds 'Wynd 28' (the CLIENT name, not a
--   facility) which is the one-column-several-meanings problem; the nickname now
--   overrides it for display and the stale label is left in place rather than
--   silently rewritten.
--
-- ⚠ NOT DONE HERE, DELIBERATELY: GDO-14760 has permit_expiration 2025-12-31 yet
-- status='ACTIVE'. Fred confirmed the permit is expired. Flipping status is NOT a
-- cosmetic edit: shared-block stamping emits one Section B row per ACTIVE
-- well-formed permit, so demoting it would REMOVE Nino Gordo's row from future
-- sheets. That is an ops decision for Fred, raised separately, not smuggled into
-- a naming migration.
--
-- AUDIT (ADR 010): public.gdos is audited, so these UPDATEs are captured in full.
-- ============================================================================

begin;

-- 043-MIL Mila (area-based, mirrors the Casa Neos Kitchen/Bar/Lounge pattern)
update public.gdos set nickname = 'Restaurant'   where gdo_number = 'GDO-11024' and nickname is null;
update public.gdos set nickname = 'Bar & Lounge' where gdo_number = 'GDO-14117' and nickname is null;

-- 148-MOR The Moore (short nickname + full descriptor, only where label is NULL)
update public.gdos set nickname = 'Elastika'     where gdo_number = 'GDO-11226' and nickname is null;
update public.gdos set nickname = 'Club & Hotel' where gdo_number = 'GDO-14769' and nickname is null;
update public.gdos set location_label = 'The Moore - Elastika Bev Co'
  where gdo_number = 'GDO-11226' and location_label is null;
update public.gdos set location_label = 'The Moore - Moore Club / Hotel / Workplace Bev Co (Facility F, Level 4)'
  where gdo_number = 'GDO-14769' and location_label is null;

-- 242-WYN Wynd 28 (tenant-based)
update public.gdos set nickname = 'Pasta'      where gdo_number = 'GDO-13814' and nickname is null;
update public.gdos set nickname = 'Nino Gordo' where gdo_number = 'GDO-14760' and nickname is null;
update public.gdos set nickname = 'Pari Pari'  where gdo_number = 'GDO-16146' and nickname is null;

commit;
