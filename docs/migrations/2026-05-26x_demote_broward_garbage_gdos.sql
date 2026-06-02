-- 2026-05-26x_demote_broward_garbage_gdos.sql
--
-- Yan's "Miami-Dade Grease Trap Universe" sheet cross-check (2026-05-25)
-- surfaced 3 ACTIVE gdos rows with garbage gdo_number values ('BW' or 'bw').
-- All 3 clients are in BROWARD County (Hollywood / Fort Lauderdale) and
-- therefore cannot have a Miami-Dade DERM GDO. The 'BW' placeholder was
-- likely a Broward marker from an earlier import that bypassed the
-- gdo_number format check (gdos.gdo_number has no CHECK constraint today).
--
-- Phase 2's @GDO bot only looks up valid-format GDO-\d{3,6} numbers, so
-- these never appeared in the bot batches and weren't auto-cleaned.
--
-- Action: demote all 3 rows to status='INACTIVE' with a clear note. Do NOT
-- delete (Rule 6). Clients themselves stay ACTIVE — they're real UnclogMe
-- customers, just not subject to Miami-Dade DERM compliance.
--
-- IDEMPOTENT (Rule 5) · AUDIT (Rule 8) · NEVER HARD-DELETE (Rule 6)

BEGIN;

UPDATE public.gdos
SET status = 'INACTIVE',
    notes = COALESCE(notes || E'\n', '') ||
            '[2026-05-26] DEMOTED. gdo_number="BW"/"bw" was a Broward placeholder from an earlier import. Client is in Broward County (Hollywood/Fort Lauderdale) and therefore not subject to Miami-Dade DERM. Confirmed against Yan''s Miami-Dade GDO Universe sheet (gid 154422364) which has no permit at this address. Client itself stays ACTIVE; only the GDO row is demoted.'
WHERE id IN (137, 138, 139)
  AND status = 'ACTIVE';

COMMIT;

-- VERIFY
--   SELECT id, gdo_number, status FROM public.gdos WHERE id IN (137, 138, 139);
--   Expected: all 3 INACTIVE
--
--   SELECT COUNT(*) FILTER (WHERE g.status='ACTIVE')::int AS active_count
--   FROM public.gdos g;
--   Expected: 84 - 3 = 81
