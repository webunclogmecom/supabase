-- 2026-07-30_2345  FIX MY OWN REGRESSION: D3 must not write address_row_map.page
--
-- Fred, minutes after the browser pass: "310429 had 3 pages when in the DERM app it has 2 instead,
-- so where did that dupe came from?" -- it came from me, in 2026-07-30_1935 (D3), 22 minutes earlier.
--
-- -- WHAT I BROKE ------------------------------------------------------------
-- D3's placement UPDATE copied the INSERT trigger's behaviour verbatim, including `page := o_page`.
-- That is right for a card being BORN onto a generated sheet; it is wrong for an EXISTING card,
-- because `page` and `image_url` are a PAIR: `page` says which sheet IMAGE the card was read from,
-- and derm.ticket_page_images() rebuilds the page list as
--     SELECT page, mode() WITHIN GROUP (ORDER BY image_url) ... WHERE image_url <> 'pending' GROUP BY page
-- Moving two slot-6/7 cards from page 1 to page 2 while they still carried page 1's
-- address_1.jpeg made page 2's mode ALSO address_1.jpeg, so the function emitted
--     [address_1, address_1, address_2]   -> 3 images, the middle one a duplicate
-- and the Studio faithfully rendered a third page that does not exist in the printed PDF.
-- Audit confirms the cause precisely: exactly TWO rows changed page 1 -> 2, app_source 'sql',
-- 2026-07-30 23:23:32 -- my migration, no other writer.
--
-- THE STAMPS WERE NEVER WRONG. Rendering is driven by `stamp_page` (the Studio filters
-- `placed && stamp_page === p`), which D3 set correctly and which this migration does not touch.
-- Only the page LIST was inflated. Nothing customer-facing moved; the FP blackout keys off bands,
-- not this. So this is a display-integrity regression, not a compliance one -- but a phantom page on
-- a DERM sheet is exactly the kind of thing that makes an operator distrust the whole document.
--
-- -- THE FIX -----------------------------------------------------------------
-- 1. Restore `page` on the two affected cards (audit old_row = '1' for both).
-- 2. Drop `page = o_page` from the resolver's placement UPDATE. It now writes ONLY the stamp
--    columns, leaving the card's source-image association alone. `stamp_page` still carries the
--    printed page, which is what renders.
--    Do NOT "restore symmetry" with the INSERT trigger by re-adding it. The trigger is correct
--    for its own path (a new card + 'pending' image_url contributes nothing to the mode grouping);
--    the UPDATE path is not, because the card already has a real image_url.
--
-- PROBED rolled back before applying: page list 3 -> 2 images, duplicate gone, page_count 2,
-- all 7 stamp_page/stamp_y_pct/attribution byte-identical, badge still 7/7 filled_by_ai=true.
--
-- SHEET 1073 (the live E2E sentinel) IS UNAFFECTED and still valid: it will be stamped by the
-- INSERT-trigger path, which was never changed and never had this bug.
--
-- RULE 8 (ADR 010): no table/column change; address_row_map is audited, so both the regression and
-- this repair are captured.

BEGIN;

UPDATE derm.address_row_map SET page = 1
 WHERE dump_folder = 'ticket-310429' AND page = 2;

CREATE OR REPLACE FUNCTION derm.fn_resolve_generated_sheet_for_ticket(p_ticket text)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'derm','public'
AS $fn$
declare v_sheet_id bigint; v_n int;
begin
  if p_ticket is null then return null; end if;

  select s.id into v_sheet_id
    from derm.address_sheets s
    join derm.address_sheet_manifests l on l.sheet_id = s.id
    join public.derm_manifests m on m.id = l.manifest_id and m.deleted_at is null
   where s.deleted_at is null
     and coalesce(m.white_manifest_number, m.yellow_ticket_number) = p_ticket
   limit 1;

  if v_sheet_id is null then
    -- On an N-client shared ticket this correctly returns NULL for the first N-1 filings and
    -- resolves on the LAST one. Refuse-not-guess; do not relax the exact-set match.
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
       group by c.sheet_id
      having array_agg(distinct c.client_id order by c.client_id)
           = (select array_agg(distinct tc.client_id order by tc.client_id) from ticket_clients tc)
    )
    select count(*), min(sheet_id) into v_n, v_sheet_id from cand;

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

  -- Place existing unplaced cards. WRITES ONLY THE STAMP COLUMNS -- never `page`. `page` pairs
  -- with `image_url` to build the sheet's page list (ticket_page_images groups by page and takes
  -- mode(image_url)); moving it on an existing card duplicates an image and invents a page.
  -- See 2026-07-30_2345. `stamp_page` is what the Studio renders on.
  update derm.address_row_map a
     set stamp_page  = s.o_page,
         stamp_x_pct = round(s.o_x_pct, 3),
         stamp_y_pct = round(s.o_y_pct, 3),
         stamp_placed_at = now(),
         stamp_placed_by = 'stamp-studio-ai'
    from (select r.id, g.o_page, g.o_x_pct, g.o_y_pct
            from derm.address_row_map r
            cross join lateral derm.fn_generated_row_geometry(
                         derm.fn_generated_sheet_slot(r.matched_manifest_id)) g
           where r.white_manifest_number = p_ticket
             and r.stamp_placed_at is null) s
   where a.id = s.id
     and s.o_y_pct is not null;

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
end $fn$;

REVOKE ALL ON FUNCTION derm.fn_resolve_generated_sheet_for_ticket(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION derm.fn_resolve_generated_sheet_for_ticket(text) TO authenticated, service_role;

COMMIT;
