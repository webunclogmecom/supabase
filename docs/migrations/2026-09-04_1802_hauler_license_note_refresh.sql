-- 2026-09-04_1802_hauler_license_note_refresh.sql
--
-- WHY. `2026-09-04_1738` stored the Dade hauler license with a note saying the shipped code spelled
-- it `LW 1133` with a space, called it a DECAL, and that "both flagged, neither changed here". Fred
-- then decided both open points, so that note is now stale in the one direction that matters: it
-- tells a reader the code disagrees with the table when the code has been brought into line.
--
--   Fred, 2026-09-04: "yes fix city-letter.ts and the other copy." / "Keep the Hyphen over a
--   white-space."
--
-- WHAT CHANGED OUTSIDE THIS MIGRATION (already deployed and verified against the LIVE bodies, not
-- the git tree):
--   supabase/functions/_shared/city-letter.ts              -> send-derm-email v50
--   supabase/functions/send-visit-photos-email/index.ts    -> send-visit-photos-email v30
-- In both: the constants were renamed DERM_DECALS -> HAULER_LICENSES (and the _TEXT twin), the value
-- respelled `LW 1133` -> `LW-1133`, and the comment claiming these are decals and "NOT the hauler
-- licence number" was replaced with Fred's canonical table.
--
-- ⚠ THE RENDERED FOOTER CHANGED, and it is regulator-facing. It reads
--   "Licensed Grease Trap Hauler" / "Miami-DADE: LW-1133 · Broward: WT-26-0104"
-- on both the city letter and the visit-photos email, in the HTML and the plain-text parts. Only the
-- hyphen moved; the numbers are unchanged. The heading was always right, which is the strongest
-- argument that these were hauler licenses all along.
--
-- ⚠ NOT changed, still open: no row exists for #1404-25. docs/company.md:16 still calls it the DERM
-- License and memory calls it the Miami-Dade Licensed Grease Trap Hauler number. If LW-1133 is the
-- Dade hauler license then Dade has two credentials or one record is wrong. Do NOT guess.
--
-- No schema change. One NOTE column on one row.

update public.company_hauler_licenses
   set notes = 'Fred 2026-09-04. Hyphen is deliberate: "Keep the Hyphen over a white-space." '
               'Shipped code was corrected to match on 2026-09-04 (_shared/city-letter.ts and '
               'send-visit-photos-email/index.ts, constants renamed to HAULER_LICENSES, deployed as '
               'send-derm-email v50 / send-visit-photos-email v30). Renders on the regulator-facing '
               'footer of both emails. STILL OPEN: where #1404-25 fits.'
 where jurisdiction = 'Miami-Dade'
   and license_number = 'LW-1133'
   and status = 'ACTIVE';

update public.company_hauler_licenses
   set notes = 'Fred 2026-09-04. Goes in the Hauler License # field of FDEP form 62-705.300(3) (the '
               'Broward Address). Also renders on the regulator-facing footer of the city letter and '
               'the visit-photos email. Confirmed a HAULER LICENSE, not a decal; the Broward per-truck '
               'decals are 07675 (Moises) and 07058 (David) in public.vehicle_decals.'
 where jurisdiction = 'Broward'
   and license_number = 'WT-26-0104'
   and status = 'ACTIVE';
