-- 2026-08-04_1912  derm.fn_resolve_generated_sheet_for_ticket
-- ============================================================================
-- WHY
-- ----------------------------------------------------------------------------
-- The Stamp Studio auto-stamp placed a client on the WRONG ROW of a compliance
-- document, silently, and then marked the sheet completed.
--
-- Ticket 831710: we generated address sheet 1079 (one client, 214-MYK at slot 1)
-- but the driver filled out a DIFFERENT, pre-printed pad sheet numbered 1008,
-- on which 214-MYK is row 2 and row 1 is 053-PV Pura Vida Edgewater. The
-- function placed slot-1 geometry onto a sheet that was never ours, so the
-- 214-MYK chip landed on another client's row. Found by a full visual audit of
-- all 17 AI stamps (16 were correct); row 921 was corrected by hand.
--
-- The function trusted `address_sheet_clients.slot` -- the order OUR PDF
-- generator recorded -- and never checked that the scan on file is that sheet.
--
-- THE GUARD (and why it is a predicate, not a heuristic)
-- ----------------------------------------------------------------------------
-- A sheet that did not exist when the truck left cannot be the sheet the driver
-- carried. That is physical causality. Measured on all three generated sheets
-- ever matched to a ticket:
--
--     sheet 1071   created ET 2026-07-28   dump 2026-07-28   same day  -> correct
--     sheet 1072   created ET 2026-07-30   dump 2026-07-30   same day  -> correct
--     sheet 1079   created ET 2026-08-03   dump 2026-08-02   +1 DAY    -> WRONG
--
-- So: never match or place from a generated sheet whose `created_at` (in ET) is
-- later than the ticket's dump date.
--
-- LIMITS -- do not read this as complete cover:
--   * It does NOT catch a pad sheet used while an OLDER generated sheet already
--     exists. That passes the timing test and can still mis-stamp. Catching it
--     needs the sheet number read off the paper and compared to
--     `address_sheets.sheet_no`; that layer is deliberately NOT in this change.
--   * Sample is three sheets (2 pass, 1 fails). The argument is causal, not
--     statistical, but it has only been exercised against three real sheets.
--
-- DETAILS THAT MATTER
--   * Compare in ET. `service_date` is a date and `created_at` is timestamptz;
--     a UTC comparison flips any sheet generated late in the evening.
--   * Use `created_at`, NOT `last_generated_at`. A regenerated sheet must keep
--     its original existence date or the guard weakens every time a PDF is
--     re-rendered.
--   * Fails CLOSED on a null dump date, matching this function's own
--     "refuse-not-guess" principle. Safe today: 0 of 592 live manifests have a
--     null `service_date`.
--   * The guard is applied to BOTH the candidate match and the placement.
--     Gating only the match would leave branch 1 (sheet already linked) placing
--     from a pre-existing bad link on any re-run.
--
-- ALSO: NO AUTO-COMPLETE ON AI-PLACED SHEETS  (Fred, "A + D")
--   The function used to mark a sheet `completed` as soon as every row had a
--   position. That is how 831710 became "done" while being wrong. It now only
--   auto-completes when NO row on the sheet was placed by 'stamp-studio-ai'.
--   Fully-human sheets keep today's behaviour exactly.
--
-- 3NF: no new column, no denormalisation. Audit: derm.address_row_map is not
-- audited; this function is unchanged in that respect.
-- ============================================================================

CREATE OR REPLACE FUNCTION derm.fn_resolve_generated_sheet_for_ticket(p_ticket text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
declare v_sheet_id bigint; v_n int; v_dump_date date;
begin
  if p_ticket is null then return null; end if;

  -- 2026-08-04: the dump date for this ticket. A generated sheet created after
  -- this date cannot be the sheet the driver physically carried.
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
         -- 2026-08-04 CAUSALITY GUARD: the sheet must have existed on the dump date.
         and v_dump_date is not null
         and (s.created_at at time zone 'America/New_York')::date <= v_dump_date
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
             and r.stamp_placed_at is null
             -- 2026-08-04 CAUSALITY GUARD, defence in depth: the sheet this card's slot
             -- comes from must itself have existed on the dump date. Gating only the
             -- candidate match above would still place from a pre-existing bad link.
             and v_dump_date is not null
             and exists (
                   select 1
                     from derm.address_sheet_manifests l
                     join derm.address_sheets sh on sh.id = l.sheet_id and sh.deleted_at is null
                    where l.manifest_id = r.matched_manifest_id
                      and (sh.created_at at time zone 'America/New_York')::date <= v_dump_date)
         ) s
   where a.id = s.id
     and s.o_y_pct is not null;

  -- 2026-08-04: only auto-complete a sheet that carries NO AI placement. An AI-placed
  -- sheet must be confirmed by a human in the Studio; auto-completing it is how a wrong
  -- stamp became "done" on ticket 831710.
  insert into derm.stamp_sheet_status (dump_folder, completed, completed_at, completed_by, updated_at)
  select d.dump_folder, true, now(), 'stamp-studio-ai', now()
    from (select distinct r.dump_folder from derm.address_row_map r
           where r.white_manifest_number = p_ticket) d
   where not exists (select 1 from derm.address_row_map r2
                      where r2.dump_folder = d.dump_folder and r2.stamp_placed_at is null)
     and not exists (select 1 from derm.address_row_map r3
                      where r3.dump_folder = d.dump_folder
                        and r3.stamp_placed_by = 'stamp-studio-ai')
  on conflict (dump_folder) do update
     set completed    = true,
         completed_at = coalesce(derm.stamp_sheet_status.completed_at, now()),
         completed_by = coalesce(derm.stamp_sheet_status.completed_by, 'stamp-studio-ai'),
         updated_at   = now()
   where not derm.stamp_sheet_status.completed;

  return v_sheet_id;
end $function$;
