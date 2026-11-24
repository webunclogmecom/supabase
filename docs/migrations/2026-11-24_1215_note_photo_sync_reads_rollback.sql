-- Rollback of 2026-11-24_1215_note_photo_sync_reads.sql (Trello #247).
-- Run ONLY after scripts/sync/sync_jobber_note_photos.js no longer calls these functions (or the sync breaks).
begin;
drop function if exists public.note_photo_sync_targets(integer, bigint);
drop function if exists public.note_photo_sync_visit(bigint);
drop function if exists public.note_photo_sync_photo_id(text);
commit;
