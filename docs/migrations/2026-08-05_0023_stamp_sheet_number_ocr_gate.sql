-- 2026-08-05_0023  derm.address_sheet_scan_reads + sheet-number gate on the auto-place
-- ============================================================================
-- WHY
-- ----------------------------------------------------------------------------
-- Layer A2 of the Stamp auto-place fix. The 2026-08-04_1912 causality guard
-- ("a sheet created after the dump cannot be the sheet the driver carried")
-- closes the case we actually hit, but it does NOT catch a pre-printed pad
-- sheet used while an OLDER generated sheet already exists -- that passes the
-- timing test and can still mis-stamp.
--
-- The only way to know which physical sheet a scan is, is to read the number
-- DERM already prints in the top-right corner (1008, 1059, 1071, 1072-1).
--
-- 🛑 NOT AN OPTION: putting a QR code, barcode or any mark on the sheet.
--    Fred 2026-08-04: "The sheets cannot have a QR Code ... the sheets should
--    only be filled with data ... adding a QR code is not valid." It is a
--    regulator-facing compliance form. Reading what it already says is fine;
--    altering it is not. That idea was proposed and rejected -- do not revive it.
--
-- WHAT THIS ADDS
-- ----------------------------------------------------------------------------
-- 1. `derm.address_sheet_scan_reads` -- what a vision reader saw on a SCANNED
--    page. One row per (dump_folder, page). This is an OBSERVATION of the
--    paper, deliberately separate from `derm.address_sheets`, which is the
--    sheet WE generated. Conflating the two is the whole bug.
--
-- 2. A gate in `fn_resolve_generated_sheet_for_ticket`.
--
-- 🛑 THE GATE IS DISAGREEMENT-ONLY. THIS IS THE LOAD-BEARING DECISION.
--      read exists AND != our sheet_no  -> refuse to place
--      no read yet                      -> fall through to the causality guard
--
--    Failing closed on a missing read would disable auto-stamping entirely
--    until someone runs the OCR script, i.e. break the feature in order to
--    protect it. Disagreement-only is MONOTONIC: adding OCR data can only ever
--    make the system stricter, never looser. That is what lets the reader run
--    on a schedule or by hand without sitting on the critical path.
--
-- 3NF: `sheet_no_read` is an observation, not a copy of `address_sheets.sheet_no`
-- -- the entire point is that the two can differ. No denormalisation.
-- Audit: derm tables are not audited; this one records its own provenance
-- (model, confidence, read_at) instead.
-- ============================================================================

create table if not exists derm.address_sheet_scan_reads (
  dump_folder   text        not null,
  page          int         not null default 1,
  sheet_no_read text,                      -- NULL = reader ran and could not read it
  raw_read      text,                      -- exactly what the model returned, for audit
  confidence    text        not null default 'unknown',   -- high | low | unreadable
  model         text        not null,
  image_url     text,
  read_at       timestamptz not null default now(),
  primary key (dump_folder, page)
);

comment on table derm.address_sheet_scan_reads is
  'What a vision reader saw printed on a SCANNED DERM address sheet page. An observation of the paper, '
  'NOT a copy of derm.address_sheets.sheet_no (which is the sheet WE generated). The two differing is '
  'the signal, not an error. Written by scripts/sync/ocr_address_sheet_numbers.js.';

comment on column derm.address_sheet_scan_reads.sheet_no_read is
  'The number printed top-right on the scan. NULL means the reader ran and could not read it, which is '
  'different from having no row at all (reader never ran). Do not collapse those two states.';

revoke all on derm.address_sheet_scan_reads from public, anon;
grant select on derm.address_sheet_scan_reads to authenticated;

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
         -- 2026-08-05 SHEET-NUMBER GATE (disagreement-only): if a vision read exists for
         -- this ticket's scan and it names a DIFFERENT sheet, this candidate is not the
         -- paper the driver used. No read yet -> no opinion, fall through to causality.
         and not exists (
               select 1
                 from derm.address_sheet_scan_reads sr
                where sr.dump_folder = 'ticket-' || p_ticket
                  and sr.sheet_no_read is not null
                  -- ⚠ STRIP THE PAGE SUFFIX. A multi-page form prints "1072-1" / "1072-2"
                  -- while our sheet_no is 1072. Comparing raw would refuse ticket 310429,
                  -- which is a CORRECT placement. Caught by the control set 2026-08-05.
                  and split_part(sr.sheet_no_read, '-', 1) <> s.sheet_no::text)
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
                      and (sh.created_at at time zone 'America/New_York')::date <= v_dump_date
                      -- 2026-08-05 SHEET-NUMBER GATE, same disagreement-only semantics.
                      and not exists (
                            select 1
                              from derm.address_sheet_scan_reads sr
                             where sr.dump_folder = r.dump_folder
                               and sr.sheet_no_read is not null
                               and split_part(sr.sheet_no_read, '-', 1) <> sh.sheet_no::text))
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
