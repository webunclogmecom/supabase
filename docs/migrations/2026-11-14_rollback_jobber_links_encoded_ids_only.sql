-- 2026-11-14_rollback_jobber_links_encoded_ids_only.sql
-- Undoes 2026-11-14_0805_jobber_links_encoded_ids_only.sql.
--
-- PART A (always): drop the CHECK, so a bare-number Jobber id is accepted again.
-- PART B (only if the two duplicate rows must come back, which re-creates the double): the rows are NOT in this
-- public repo. Restore them from the workspace backup backups/2026-11-14_quote_doubles_166_167.json, quote first,
-- then its link, each with json_populate_record and the backup's own row, for example:
--   INSERT INTO public.quotes SELECT * FROM json_populate_record(NULL::public.quotes, '<quotes[0] of the backup>');
--   INSERT INTO public.entity_source_links SELECT * FROM json_populate_record(NULL::public.entity_source_links, '<links[0] of the backup>');
-- (after PART A, or the CHECK refuses the link). Then the same for the second.

BEGIN;
ALTER TABLE public.entity_source_links DROP CONSTRAINT IF EXISTS entity_source_links_jobber_id_encoded;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'entity_source_links_jobber_id_encoded') THEN
    RAISE EXCEPTION 'ROLLBACK VERIFY: the CHECK is still there';
  END IF;
END $$;
COMMIT;
