-- 2026-08-06_2110 — the page map must REFUSE when it does not know, and the INSERT trigger must use it
--
-- Fixes two HIGH defects in `2026-08-06_1655`, which I shipped earlier today. Found by an audit Fred
-- asked for after he correctly rejected my claim that ticket 831220's sheet was "never generated".
-- Both are LATENT (no row is wrong today) and both are reachable.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- DEFECT 1 — `fn_sheet_image_position` returns a COLLIDING map, and cannot say "I don't know"
-- ─────────────────────────────────────────────────────────────────────────────
-- Measured on Prod before this migration:
--     fn_sheet_image_position('ticket-831220', 1) = 1     <- identity fallback, no read has suffix 1
--     fn_sheet_image_position('ticket-831220', 2) = 1     <- matches the '1063-2' read
--     fn_sheet_image_position('ticket-831220', 4) = 4     <- against a ONE-image folder
-- Two logical pages resolving to the same image position is not a mapping. The cause is that the
-- folder holds page 2 of sheet 1063 and no page 1, so logical page 1 has no read to match and silently
-- falls through `coalesce` to identity.
--
-- 🛑 THE HEADER OF 1655 ARGUED IDENTITY WAS SAFE BECAUSE "only 5 of 10 reads carry a suffix". That
-- argument is wrong in both directions and I am recording why, because it is the reasoning defect, not
-- the code:
--   * ZERO coverage is the WORST case, not the safest. For ticket-310590 the correct map is 1->2, 2->1;
--     identity is injective and 100% wrong, which is exactly the 8-stamps-on-the-wrong-row scenario
--     1655 exists to prevent. Identity is safe only where it happens to be TRUE, and absence of
--     evidence does not make it true.
--   * FULL coverage is not sufficient either: the body took `order by sr.page limit 1` and never
--     checked that suffix->page is a bijection.
--
-- FIX: once ANY high-confidence suffix read proves this folder's scans are recorded page-by-page,
-- the folder's mapping is CLOSED: a logical page with no matching read is UNKNOWN, and we return NULL
-- so the caller refuses. Identity survives only for folders with no suffix evidence at all (the
-- majority, and the no-op case). Also bound the result to the number of images the folder actually has.
--
-- ⚠ A NULL RETURN IS ONLY SAFE IF EVERY CALLER REFUSES ON NULL. `address_row_map.stamp_page` is
-- nullable with no CHECK, and 1655's placement UPDATE gated only on `s.o_y_pct is not null`, so a NULL
-- page would have been written alongside `stamp_placed_at = now()` and the folder then marked complete:
-- a placed stamp on no page. Both callers are fixed below, in this same transaction.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- DEFECT 2 — the BEFORE INSERT trigger never used the mapping at all
-- ─────────────────────────────────────────────────────────────────────────────
-- `derm.trg_autoplace_generated` writes `NEW.page := geo.o_page; NEW.stamp_page := geo.o_page`
-- straight from the LOGICAL page. 1655 fixed the resolver and left this path untouched, so the two
-- placement routes disagreed. Proven in a rolled-back probe on ticket-310590: the trigger writes
-- stamp_page 1 where the resolver writes 2, and 2 where it writes 1, i.e. exactly inverted.
--
-- Reachable whenever a card is materialised AFTER its sheet links exist (76 of 784 `address_row_map`
-- INSERTs arrived already-placed, including real DERM Tracker writes on 2026-08-03 and 2026-08-05).
-- Live exposure is one folder today, ticket-310590, the only linked multi-page sheet whose scans are
-- out of order. Nothing is currently wrong; this closes it before it fires.
--
-- ⚠ `page` IS ALSO AN IMAGE INDEX, so it had the same bug. `ticket_page_images` groups by `page` and
-- takes `mode(image_url)`, so `page` indexes the image list exactly like `stamp_page` does. Writing
-- the logical page into it on an out-of-order folder mislabels which image the card belongs to.
-- (2026-07-30_2345's rule stands: the RESOLVER must never move `page` on an EXISTING card. This is a
-- BEFORE INSERT on a card being created, which is the one moment `page` is legitimately assigned.)
--
-- 3NF: no new column. Audit: `derm.address_row_map` keeps its existing audit trigger; behaviour here
-- is refuse-more-often, so nothing new is written.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. The map: identity only where there is no evidence; NULL where evidence exists but is silent
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function derm.fn_sheet_image_position(p_dump_folder text, p_logical_page int)
returns int
language plpgsql
stable
security definer
set search_path to 'derm', 'public'
as $function$
declare
  v_pos      int;
  v_has_map  boolean;
begin
  if p_dump_folder is null or p_logical_page is null or p_logical_page < 1 then
    return null;
  end if;

  -- an exact, high-confidence match: this printed page IS at this image position
  select sr.page into v_pos
    from derm.address_sheet_scan_reads sr
   where sr.dump_folder = p_dump_folder
     and sr.confidence  = 'high'
     and sr.sheet_no_read ~ '-[0-9]+$'
     and split_part(sr.sheet_no_read, '-', 2)::int = p_logical_page
   order by sr.page
   limit 1;

  if v_pos is not null then
    return v_pos;
  end if;

  -- No match. Does this folder have a page map AT ALL? If it does, the map is CLOSED and this page
  -- is genuinely unknown: refuse rather than fall back to a coincidence.
  select exists (
    select 1 from derm.address_sheet_scan_reads sr
     where sr.dump_folder = p_dump_folder
       and sr.confidence  = 'high'
       and sr.sheet_no_read ~ '-[0-9]+$'
  ) into v_has_map;

  if v_has_map then
    return null;     -- caller MUST refuse
  end if;

  -- No evidence either way: identity. This is the pre-2026-08-06 behaviour and the majority case,
  -- and it MUST stay a no-op.
  --
  -- ⚠ A page-count bound was written here and REMOVED, because it was wrong and the control caught it.
  -- It derived the folder's image count from `count(distinct address_row_map.page)`, on the assumption
  -- that `page` enumerates the images. It does not: ticket-831938's cards all carry `page = 1` while
  -- its stamps legitimately span stamp_page 1 and 2, so the bound returned NULL for page 2 of a
  -- two-page sheet and put 3 of 29 already-correct AI rows into disagreement with the map.
  -- `address_row_map.image_url` is separately known to be STALE, so it is not a substitute source.
  -- There is no cheap, trustworthy per-folder page count here, and an unreliable bound is worse than
  -- none: the closed-world rule above is what actually prevents a wrong page, and it needs no count.
  return p_logical_page;
end;
$function$;

comment on function derm.fn_sheet_image_position(text,int) is
  'Logical printed sheet page -> image position, from the page suffix the sheet-number OCR records '
  '(''1074-2'' = printed page 2). Returns NULL when the folder HAS a page map but this page is not in '
  'it (closed-world: refuse, never guess), and NULL for a page beyond the folder''s image count. '
  'Identity only when there is no suffix evidence at all. EVERY caller must refuse on NULL: '
  'address_row_map.stamp_page is nullable, so a NULL would otherwise be written as a placed stamp.';

revoke all on function derm.fn_sheet_image_position(text,int) from public, anon, authenticated;
grant execute on function derm.fn_sheet_image_position(text,int) to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Caller A: the BEFORE INSERT trigger now maps, and refuses on NULL
-- ─────────────────────────────────────────────────────────────────────────────
-- Adds the image-position mapping and the row-read gate. Keeps the existing "no row_index fallback"
-- rule verbatim, which is load-bearing and must not be softened.
create or replace function derm.trg_autoplace_generated()
 returns trigger
 language plpgsql
as $function$
declare geo record; v_slot integer; v_img integer; v_code text;
begin
  if NEW.white_manifest_number is not null
     and NEW.stamp_placed_at is null
     and derm.fn_sheet_is_generated(NEW.white_manifest_number) then
    v_slot := derm.fn_generated_sheet_slot(NEW.matched_manifest_id);
    -- ⚠ NO row_index fallback. row_index is card-creation order and is provably
    -- unrelated to printed order (309898: printed slot 1 is row_index 5).
    -- Guessing here writes a stamp onto another client's row.
    if v_slot is not null then
      select * into geo from derm.fn_generated_row_geometry(v_slot);

      -- 2026-08-06_2110: the LOGICAL page is not the image position when the scans are stored out of
      -- printed order. Writing geo.o_page directly is inverted on ticket-310590. NULL = we do not
      -- know which image this page is, so do not place.
      v_img := derm.fn_sheet_image_position(NEW.dump_folder, geo.o_page);

      select c.client_code into v_code from public.clients c where c.id = NEW.matched_client_id;

      if v_img is not null
         and geo.o_y_pct is not null
         -- row gate, disagreement-only (same semantics as the resolver): if the scanned sheet names
         -- a DIFFERENT client on this row, refuse. No read = no opinion = unchanged behaviour.
         and (v_code is null
              or derm.fn_row_read_confirms(
                   NEW.dump_folder, v_img, ((v_slot - 1) % 5) + 1, v_code) is not false)
      then
        NEW.page            := v_img;
        NEW.stamp_page      := v_img;
        NEW.stamp_x_pct     := round(geo.o_x_pct, 3);
        NEW.stamp_y_pct     := round(geo.o_y_pct, 3);
        NEW.stamp_placed_at := now();
        NEW.stamp_placed_by := 'stamp-studio-ai';
      end if;
    end if;
  end if;
  return NEW;
end $function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Caller B: the resolver's placement UPDATE must skip a NULL image position
-- ─────────────────────────────────────────────────────────────────────────────
-- Only the placement UPDATE's WHERE changes: `and s.img_page is not null` beside the existing
-- `s.o_y_pct is not null`. Everything else is 2026-08-06_1655 verbatim.
CREATE OR REPLACE FUNCTION derm.fn_resolve_generated_sheet_for_ticket(p_ticket text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
declare v_sheet_id bigint; v_n int; v_dump_date date; v_folder text;
begin
  if p_ticket is null then return null; end if;

  select min(m.service_date) into v_dump_date
    from public.derm_manifests m
   where coalesce(m.white_manifest_number, m.yellow_ticket_number) = p_ticket
     and m.deleted_at is null;

  select s.id into v_sheet_id
    from derm.address_sheets s
    join derm.address_sheet_manifests l on l.sheet_id = s.id
    join public.derm_manifests m on m.id = l.manifest_id and m.deleted_at is null
   where s.deleted_at is null
     and coalesce(m.white_manifest_number, m.yellow_ticket_number) = p_ticket
   limit 1;

  select r.dump_folder into v_folder
    from derm.address_row_map r
   where r.white_manifest_number = p_ticket
   limit 1;

  if v_sheet_id is null then
    with ticket_clients as (
      select distinct m.client_id
        from public.derm_manifests m
       where coalesce(m.white_manifest_number, m.yellow_ticket_number) = p_ticket
         and m.deleted_at is null
    ), cand as (
      select c.sheet_id
        from derm.address_sheet_clients c
        join derm.address_sheets s on s.id = c.sheet_id and s.deleted_at is null
       where not exists (select 1 from derm.address_sheet_manifests l where l.sheet_id = c.sheet_id)
         and v_dump_date is not null
         and (s.created_at at time zone 'America/New_York')::date <= v_dump_date
         and not exists (
               select 1
                 from derm.address_sheet_scan_reads sr
                where sr.dump_folder = 'ticket-' || p_ticket
                  and sr.sheet_no_read is not null
                  and split_part(sr.sheet_no_read, '-', 1) <> s.sheet_no::text)
       group by c.sheet_id
      having array_agg(distinct c.client_id order by c.client_id)
           = (select array_agg(distinct tc.client_id order by tc.client_id) from ticket_clients tc)
    )
    select count(*), min(sheet_id) into v_n, v_sheet_id from cand;

    if v_n = 0 and v_folder is not null and v_dump_date is not null then
      with ticket_clients as (
        select distinct m.client_id
          from public.derm_manifests m
         where coalesce(m.white_manifest_number, m.yellow_ticket_number) = p_ticket
           and m.deleted_at is null
      ), cand2 as (
        select c.sheet_id
          from derm.address_sheet_clients c
          join derm.address_sheets s on s.id = c.sheet_id and s.deleted_at is null
         where not exists (select 1 from derm.address_sheet_manifests l where l.sheet_id = c.sheet_id)
           and (s.created_at at time zone 'America/New_York')::date <= v_dump_date
           and exists (
                 select 1
                   from derm.address_sheet_scan_reads sr
                  where sr.dump_folder = v_folder
                    and sr.confidence  = 'high'
                    and sr.sheet_no_read is not null
                    and split_part(sr.sheet_no_read, '-', 1) = s.sheet_no::text)
           and derm.fn_sheet_rows_all_confirmed(p_ticket, c.sheet_id, v_folder)
         group by c.sheet_id
        having array_agg(distinct c.client_id order by c.client_id)
            @> (select array_agg(distinct tc.client_id order by tc.client_id) from ticket_clients tc)
      )
      select count(*), min(sheet_id) into v_n, v_sheet_id from cand2;
    end if;

    if v_n <> 1 then return null; end if;

    insert into derm.address_sheet_manifests (sheet_id, manifest_id, slot)
    select v_sheet_id, m.id, c.slot
      from public.derm_manifests m
      join derm.address_sheet_clients c
        on c.client_id = m.client_id and c.sheet_id = v_sheet_id
     where coalesce(m.white_manifest_number, m.yellow_ticket_number) = p_ticket
       and m.deleted_at is null
    on conflict (sheet_id, manifest_id) do update set slot = excluded.slot;

    update public.derm_manifests m
       set derm_address_no = (select s.sheet_no from derm.address_sheets s where s.id = v_sheet_id)
     where coalesce(m.white_manifest_number, m.yellow_ticket_number) = p_ticket
       and m.deleted_at is null
       and m.derm_address_no is distinct from (select s.sheet_no from derm.address_sheets s where s.id = v_sheet_id);
  end if;

  update derm.address_row_map a
     set stamp_page  = s.img_page,
         stamp_x_pct = round(s.o_x_pct, 3),
         stamp_y_pct = round(s.o_y_pct, 3),
         stamp_placed_at = now(),
         stamp_placed_by = 'stamp-studio-ai'
    from (select r.id,
                 derm.fn_sheet_image_position(r.dump_folder, g.o_page) as img_page,
                 g.o_x_pct, g.o_y_pct
            from derm.address_row_map r
            cross join lateral derm.fn_generated_row_geometry(
                         derm.fn_generated_sheet_slot(r.matched_manifest_id)) g
            join public.clients cl on cl.id = r.matched_client_id
           where r.white_manifest_number = p_ticket
             and r.stamp_placed_at is null
             and v_dump_date is not null
             and exists (
                   select 1
                     from derm.address_sheet_manifests l
                     join derm.address_sheets sh on sh.id = l.sheet_id and sh.deleted_at is null
                    where l.manifest_id = r.matched_manifest_id
                      and (sh.created_at at time zone 'America/New_York')::date <= v_dump_date
                      and not exists (
                            select 1
                              from derm.address_sheet_scan_reads sr
                             where sr.dump_folder = r.dump_folder
                               and sr.sheet_no_read is not null
                               and split_part(sr.sheet_no_read, '-', 1) <> sh.sheet_no::text))
             and derm.fn_row_read_confirms(
                   r.dump_folder,
                   derm.fn_sheet_image_position(r.dump_folder, g.o_page),
                   ((derm.fn_generated_sheet_slot(r.matched_manifest_id) - 1) % 5) + 1,
                   cl.client_code) is not false
         ) s
   where a.id = s.id
     and s.o_y_pct is not null
     -- 2026-08-06_2110: NULL means "we do not know which image this printed page is". Placing anyway
     -- would write stamp_page = NULL with stamp_placed_at = now(), i.e. a placed stamp on no page,
     -- and the auto-complete leg below would then mark the folder done.
     and s.img_page is not null;

  insert into derm.stamp_sheet_status (dump_folder, completed, completed_at, completed_by, updated_at)
  select d.dump_folder, true, now(), 'stamp-studio-ai', now()
    from (select distinct r.dump_folder from derm.address_row_map r
           where r.white_manifest_number = p_ticket) d
   where not exists (select 1 from derm.address_row_map r2
                      where r2.dump_folder = d.dump_folder and r2.stamp_placed_at is null)
  on conflict (dump_folder) do update
     set completed    = true,
         completed_at = coalesce(derm.stamp_sheet_status.completed_at, now()),
         completed_by = coalesce(derm.stamp_sheet_status.completed_by, 'stamp-studio-ai'),
         updated_at   = now()
   where not derm.stamp_sheet_status.completed;

  return v_sheet_id;
end $function$;

commit;

-- VERIFY (all four must hold):
--   1. fn_sheet_image_position('ticket-831220', 1) IS NULL   (was 1, colliding with page 2)
--      fn_sheet_image_position('ticket-831220', 2)  = 1      (the real mapping, unchanged)
--   2. fn_sheet_image_position('ticket-310590', 1)  = 2 and (…, 2) = 1   (unchanged, still correct)
--   3. a folder with NO suffix reads still returns identity (the no-op majority case)
--   4. no existing placed row changes: every AI-placed row's stamp_page still equals the mapping.
