-- 2026-08-06_2210 — read a sheet's IDENTITY even when it is already fully stamped
--
-- Fred: "run the OCR on the remaining folders."
--
-- 🛑 WHY A SECOND TARGET FUNCTION EXISTS, AND WHY THE FIRST ONE COULD NOT BE WIDENED.
-- `derm.fn_sheet_number_ocr_targets` (the cron's list) selects only folders holding an UNPLACED row,
-- on the stated reasoning that "a fully-placed sheet can never be auto-placed again: reading it
-- changes no decision." That reasoning is correct for the question the cron asks (what can I still
-- stamp?) and WRONG for the question this asks (which physical sheet is this?).
--
-- The cost of conflating them is already on the books: **ticket 831710 was fully placed, completed,
-- and linked to the WRONG sheet** (the paper reads 1008, the DB recorded 1079, and the linked sheet
-- was created a day AFTER the dump). The cron could never have looked at it, because it was already
-- placed. The sweep was structurally blind to the exact defect it would otherwise have caught.
-- That is the same shape as the audit-trail trap in the root CLAUDE.md: an instrument that only
-- observes one state cannot report on the other, and its silence reads as health.
--
-- So the cron keeps its narrow, cheap list, and identity questions get their own explicit list.
-- Measured now: the cron's list offers 0 targets while 26 folders (43 page images) with real ticket
-- numbers and service dates on/after the sequence start have never been read at all.
--
-- ⚠ NOT restricted to `ticket-%` folders. The cron excludes every other shape because the historical
-- `window<N>-sheet<M>` set has no generated-sheet link and reading it burns vision calls for nothing.
-- But `derm/<n>` and `backfill-<n>` are the OLDEST folders, which makes them exactly the ones that
-- can predate sheet recording (address_sheets starts at 1064, 2026-07-28). Excluding them here would
-- reproduce the blindness this function exists to remove. `window%` stays excluded: still no links.
--
-- 3NF: no new state, a pure selection function. Audit: reads only.

begin;

create or replace function derm.fn_sheet_number_ocr_targets_for(
  p_tickets text[], p_limit integer default 20)
returns table(dump_folder text, ticket text, page integer, image_url text)
language sql
stable
security definer
set search_path to 'derm', 'public'
as $function$
  with want as (
    select distinct r.dump_folder, r.white_manifest_number as ticket
      from derm.address_row_map r
     where r.white_manifest_number = any(p_tickets)
       and r.dump_folder not like 'window%'
  )
  select w.dump_folder, w.ticket, g.ord::int as page, g.url as image_url
    from want w
    cross join lateral (
      -- ⚠ ticket_page_images(), never address_row_map.image_url, which is STALE (page-2 rows point at
      -- address_1 and some are the literal 'pending').
      select ord, url
        from unnest(derm.ticket_page_images(w.ticket)) with ordinality as u(url, ord)
    ) g
   where g.url is not null
     and g.url <> 'pending'
     -- idempotent: never re-read a page we already have a read for
     and not exists (select 1
                       from derm.address_sheet_scan_reads sr
                      where sr.dump_folder = w.dump_folder and sr.page = g.ord)
   order by w.dump_folder, g.ord
   limit greatest(1, least(coalesce(p_limit, 20), 60));
$function$;

comment on function derm.fn_sheet_number_ocr_targets_for(text[],integer) is
  'Explicit sheet-number OCR targets for named tickets, REGARDLESS of placement state. The cron''s '
  'fn_sheet_number_ocr_targets only offers folders with an unplaced row, so it can never read a '
  'fully-placed sheet: that is how ticket 831710 sat linked to the wrong sheet, complete and green. '
  'This answers "which sheet is this?", not "what can I stamp?". Idempotent: skips pages already read.';

revoke all on function derm.fn_sheet_number_ocr_targets_for(text[],integer) from public, anon, authenticated;
grant execute on function derm.fn_sheet_number_ocr_targets_for(text[],integer) to service_role;

commit;

-- Verify: the cron list must be unchanged (0 today), while this returns the 43 unread page images
-- across the 26 candidate folders when handed their ticket numbers.
