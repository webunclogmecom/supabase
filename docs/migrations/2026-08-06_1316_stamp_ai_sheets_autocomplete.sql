-- 2026-08-06_1316 — AI-stamped GENERATED sheets auto-complete again
--
-- Fred: "we have a manifest which even though it was stamped using the AI it's not marked as
-- complete, so we need to fix that ... and not just this one, but all that were stamped by the
-- auto-stamp ai because they were generated."
--
-- 🛑 THIS REVERSES A GUARD FRED HIMSELF ASKED FOR TWO DAYS AGO, AND THAT IS DELIBERATE.
-- `2026-08-04_1912` added: auto-complete only when NO row on the sheet was placed by
-- 'stamp-studio-ai'. Its stated reason: *"That is how 831710 became 'done' while being wrong."*
-- A mis-placed AI stamp plus auto-completion meant a wrong compliance sheet marked itself done.
--
-- WHY IT IS SAFE TO REMOVE NOW — the protection moved UPSTREAM, which is the better place for it:
--   * `2026-08-04_1912` CAUSALITY GUARD — a sheet whose `created_at` (ET) is later than the ticket's
--     dump date cannot be the sheet the driver carried, so it can no longer be the source of a slot.
--   * `2026-08-05_0023` SHEET-NUMBER OCR GATE — a vision read that names a DIFFERENT sheet blocks
--     placement outright (disagreement-only: no read = no opinion, so it stays monotonic).
-- Both shipped AFTER 831710's bad stamp. The old guard refused to CALL a sheet done; the new guards
-- refuse to PLACE the stamp wrongly in the first place. Keeping both would mean every correctly
-- stamped sheet sits in "In progress" forever with nothing to action — which is what Fred is seeing.
--
-- ⚠ VERIFIED VISUALLY BEFORE WRITING THIS, sheet by sheet in the Studio, not from the flags:
--   831938 (8 rows, 2 pages, sheet 1081): every stamp on its own printed row —
--     p1 091-SB / 110-CLA / 087-BB / 008-CV / 035-LG, p2 061-TCE / 062-TCE / 042-MT.
--     The two TCE rows are the SAME client name at different locations and are in the right order,
--     which is the case a mis-place would most easily hide in.
--   831710 (1 row, sheet 1008 — the OCR read agrees): the 214-MYK stamp sits on the
--     `214-MYK Myka Brickell FT LLC` row, i.e. the manual correction made 2026-08-05 is holding.
-- These are the only two affected sheets (measured: 5 fully-AI sheets, 3 already completed).
--
-- ⚠ `completed` REMAINS AN ATTESTATION, NOT A GEOMETRY PROOF (reference_stamp_completed_human_verified).
-- Auto-completing an AI sheet asserts "the pipeline placed every row and the guards did not refuse" —
-- it does NOT assert a human checked it. `completed_by = 'stamp-studio-ai'` keeps that distinction
-- legible in the data; do not collapse it to a generic value.
--
-- 3NF: no new column. Audit: `derm.stamp_sheet_status` IS audited (one of the 4 derm tables carrying
-- the trigger), so both the function's writes and the backfill below are captured.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Drop the anti-AI clause from the auto-complete step
-- ─────────────────────────────────────────────────────────────────────────────
-- Only the final INSERT ... SELECT changes. The resolver's matching, the causality guard and the
-- placement pass are untouched — re-stated here in full because CREATE OR REPLACE needs the whole
-- body, not because any of it moved.
CREATE OR REPLACE FUNCTION derm.fn_resolve_generated_sheet_for_ticket(p_ticket text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
declare
  v_sheet_id  bigint;
  v_dump_date date;
begin
  select max(m.dump_ticket_date) into v_dump_date
    from public.derm_manifests m
   where coalesce(m.white_manifest_number, m.yellow_ticket_number) = p_ticket
     and m.deleted_at is null;

  -- already resolved?
  select asm.sheet_id into v_sheet_id
    from derm.address_sheet_manifests asm
    join public.derm_manifests m on m.id = asm.manifest_id
   where coalesce(m.white_manifest_number, m.yellow_ticket_number) = p_ticket
   limit 1;
  if v_sheet_id is not null then
    return v_sheet_id;
  end if;

  -- exact-set, single-candidate match. Ambiguity refuses; it does not guess.
  -- CAUSALITY GUARD: the sheet must have existed on or before the dump date.
  select s.sheet_id into v_sheet_id
    from (
      select asc2.sheet_id,
             array_agg(distinct asc2.client_id order by asc2.client_id) as clients
        from derm.address_sheet_clients asc2
        join derm.address_sheets sh on sh.id = asc2.sheet_id
       where not exists (select 1 from derm.address_sheet_manifests x where x.sheet_id = asc2.sheet_id)
         and v_dump_date is not null
         and (sh.created_at at time zone 'America/New_York')::date <= v_dump_date
       group by asc2.sheet_id
    ) s
   where s.clients = (
     select array_agg(distinct m.client_id order by m.client_id)
       from public.derm_manifests m
      where coalesce(m.white_manifest_number, m.yellow_ticket_number) = p_ticket
        and m.deleted_at is null)
  having count(*) = 1;

  if v_sheet_id is null then
    return null;
  end if;

  insert into derm.address_sheet_manifests (sheet_id, manifest_id, slot)
  select v_sheet_id, m.id, asc3.slot
    from public.derm_manifests m
    join derm.address_sheet_clients asc3
      on asc3.sheet_id = v_sheet_id and asc3.client_id = m.client_id
   where coalesce(m.white_manifest_number, m.yellow_ticket_number) = p_ticket
     and m.deleted_at is null
  on conflict do nothing;

  -- place stamps on cards that already exist (order-independence), never overwriting a human stamp
  update derm.address_row_map r
     set stamp_page      = s.o_page,
         stamp_x_pct     = round(s.o_x_pct, 3),
         stamp_y_pct     = round(s.o_y_pct, 3),
         stamp_placed_at = now(),
         stamp_placed_by = 'stamp-studio-ai'
    from (select r.id, g.o_page, g.o_x_pct, g.o_y_pct
            from derm.address_row_map r
            cross join lateral derm.fn_generated_row_geometry(
                         derm.fn_generated_sheet_slot(r.matched_manifest_id)) g
           where r.white_manifest_number = p_ticket
             and r.stamp_placed_at is null
             and v_dump_date is not null
             and exists (
                   select 1
                     from derm.address_sheet_manifests asm2
                     join derm.address_sheets sh2 on sh2.id = asm2.sheet_id
                    where asm2.manifest_id = r.matched_manifest_id
                      and (sh2.created_at at time zone 'America/New_York')::date <= v_dump_date)
             -- disagreement-only sheet-number gate (2026-08-05_0023)
             and not exists (
                   select 1 from derm.address_sheet_scan_reads sr
                    where sr.dump_folder = 'ticket-' || p_ticket
                      and sr.sheet_no_read is not null
                      and split_part(sr.sheet_no_read, '-', 1) <> (
                            select sh3.sheet_no::text from derm.address_sheets sh3
                             where sh3.id = v_sheet_id))
         ) s
   where r.id = s.id;

  -- AUTO-COMPLETE when every row on the folder carries a position.
  -- 2026-08-06: the `and not exists (... stamp_placed_by = 'stamp-studio-ai')` clause that used to
  -- sit here is REMOVED (Fred). An AI-stamped generated sheet now completes like any other. The
  -- wrong-stamp risk it guarded is handled upstream by the causality guard + the sheet-number gate,
  -- which refuse to place rather than refuse to finish.
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
         updated_at   = now();

  return v_sheet_id;
end;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Backfill the sheets already stranded by the old guard
-- ─────────────────────────────────────────────────────────────────────────────
-- Scoped, not blanket: every row placed, at least one placed by the AI, and nothing still unplaced.
-- Matches exactly the 2 sheets measured today (831938, 831710), both visually verified above.
insert into derm.stamp_sheet_status (dump_folder, completed, completed_at, completed_by, updated_at)
select d.dump_folder, true, now(), 'stamp-studio-ai', now()
  from (select distinct r.dump_folder from derm.address_row_map r) d
 where exists (select 1 from derm.address_row_map a
                where a.dump_folder = d.dump_folder and a.stamp_placed_by = 'stamp-studio-ai')
   and not exists (select 1 from derm.address_row_map u
                    where u.dump_folder = d.dump_folder and u.stamp_placed_at is null)
on conflict (dump_folder) do update
   set completed    = true,
       completed_at = coalesce(derm.stamp_sheet_status.completed_at, now()),
       completed_by = coalesce(derm.stamp_sheet_status.completed_by, 'stamp-studio-ai'),
       updated_at   = now();

commit;

-- Verify: derm.v_stamp_sheets must show ZERO rows with filled_by_ai AND completed = false, while the
-- 3 not-started sheets stay not-started (the positive control that the backfill was scoped, not blanket).
