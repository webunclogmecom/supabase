-- ROLLBACK of 2026-11-19_1740_gdos_148mor_merge_duplicate_permits.sql (Trello #227).
-- Puts rows 307, 311 and 182 back to their values before the merge (also in backups/2026-11-19_gdos_148MOR_merge_227.json).
-- 307 and 311 carry "DEDUP" notes: fn_gdos_guard_demoted keeps a DEDUP row INACTIVE unless the notes change in the same
-- UPDATE, so this rollback clears the notes it added in the same statement.
do $rb$
begin
  update public.gdos set status = 'ACTIVE', notes = nullif(regexp_replace(coalesce(notes, ''), E'\\n?DEDUP 2026-11-19 \\(Trello #227\\)[^\\n]*', ''), '')
   where id = 307 and status = 'INACTIVE';
  update public.gdos set status = 'EXPIRED', notes = nullif(regexp_replace(coalesce(notes, ''), E'\\n?DEDUP 2026-11-19 \\(Trello #227\\)[^\\n]*', ''), '')
   where id = 311 and status = 'INACTIVE';
  update public.gdos set max_frequency_days = 90, notes = nullif(regexp_replace(coalesce(notes, ''), E'\\n?2026-11-19 \\(Trello #227\\): 60 days[^\\n]*', ''), '')
   where id = 182 and max_frequency_days = 60;
end
$rb$;
