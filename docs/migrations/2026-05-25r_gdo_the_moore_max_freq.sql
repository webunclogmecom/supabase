-- 2026-05-25r_gdo_the_moore_max_freq.sql
--
-- Fill in the last bot-failure gap. The Moore (id=59, GDO-14769) returned
-- NULL max_frequency_days from two separate @GDO bot lookups (Phases 2b and
-- 2d) because the bot's PDF parser couldn't extract the cleaning-frequency
-- field from this specific document.
--
-- Post-hoc PDF verification (2026-05-25 PM) — Fred read the actual DERM
-- permit PDF at https://stecmrerportal.blob.core.windows.net/dermdocuments/
-- and confirmed verbatim text:
--
--     "Permit No: GDO-014769-2024/2025 (MGRU)-GEN-OP"
--     "Permit Issued To: MIAMI DD CLUB, LLC DBA MOORE CLUB BEV CO /
--                        MOORE HOTEL BEV CO / MOORE WORKPLACE BEV CO"
--     "Facility Location: 4040 NE 2 AVE (FAC. F) Building [LVL 4]"
--     "shall be cleaned at a minimum every 60 day(s)"
--
-- So max_frequency_days = 60 is PDF-sourced (not bot-sourced).
--
-- PDF on disk during verification:
--   C:\Users\FRED\AppData\Local\Temp\gdo-rename-verify\GDO-14769.pdf
--
-- IDEMPOTENT (Rule 5) · AUDIT (Rule 8) · NEVER HARD-DELETE (Rule 6)

BEGIN;

UPDATE public.gdos
SET max_frequency_days = 60,
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-25 Phase 2 post-hoc] max_frequency_days=60 from MANUAL PDF READ of GDO-014769-2024/2025 DERM permit (Fred verified, 2026-05-25 PM). Bot returned NULL freq on 2 separate lookups due to PDF parser failure on this document. PDF text: "shall be cleaned at a minimum every 60 day(s)". issued_to confirmed: "MIAMI DD CLUB, LLC DBA MOORE CLUB BEV CO".'
WHERE id = 59
  AND gdo_number = 'GDO-14769'
  AND (max_frequency_days IS NULL OR max_frequency_days <> 60);

COMMIT;

-- VERIFY
--   SELECT id, gdo_number, max_frequency_days, permit_expiration::text, status
--   FROM public.gdos WHERE id = 59;
--   Expected: 59 GDO-14769 60 2026-12-31 ACTIVE
--
--   Final ACTIVE coverage:
--   SELECT
--     COUNT(*) FILTER (WHERE status='ACTIVE') AS active,
--     COUNT(*) FILTER (WHERE status='ACTIVE' AND max_frequency_days IS NOT NULL) AS with_freq
--   FROM public.gdos;
--   Expected: 82 ACTIVE / 81 with freq (only Pura Vida 41 still NULL — ops-deferred)
