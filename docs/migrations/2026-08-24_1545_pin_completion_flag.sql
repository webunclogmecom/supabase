-- ============================================================================
-- 2026-08-24_1545  The completion flag stops lying, and stops overwriting a human
-- ============================================================================
--
-- Fred: "pin the completion flag".
--
-- ---------------------------------------------------------------------------
-- PART 0.  TWO DEFECTS IN ONE CLAUSE OF derm.fn_resolve_generated_sheet_for_ticket
-- ---------------------------------------------------------------------------
--
-- 1. **The auto-complete leg never asked whether the stamps could be DRAWN.** Its only condition
--    was "no card in this folder is unplaced". That is precisely why the Studio showed
--    **"3/3 stamped" over a blank sheet** for ticket 833395 after an address image was deleted:
--    the counter reads stamp_placed_at and the renderer reads stamp_page, and only the second one
--    had broken. A stamp addressing a page outside the ticket image list is not a completed sheet.
--
-- 2. **It re-asserted completed = true over a deliberate re-open.** Measured from audit.logs on
--    ticket-833395:
--        04:48:14  INSERT  completed -> true    app_source=sql               (the original resolve)
--        10:56:39  UPDATE  true -> false        app_source=derm-stamp-studio (Fred)
--        11:25:41  UPDATE  false -> true        app_source=sql               (this leg, via a repair)
--
--    🛑 **The human case is not the important one.** derm.trg_zx_generated_sheet_return_review
--    writes the SAME completed=false as the MACHINE request for a visual check when a returned
--    sheet photo arrives, and it has fired 4 times (ticket-831710, 831938, 832194, 311045). So this
--    leg could discard a review request another trigger had just raised. Row triggers fire
--    alphabetically and zx sorts before zy, so on a single statement the request and its erasure
--    would land microseconds apart, in one transaction, with nothing to show for it.
--    ⇒ Fred use of completed=false matches this estate own semantics. The resolver was the outlier.
--
-- ---------------------------------------------------------------------------
-- PART 1.  THE PIN, AND WHY NOT A NEW VOCABULARY
-- ---------------------------------------------------------------------------
--
-- public.clients.status_source already solves exactly this shape: a machine sync kept undoing a
-- deliberate human deactivation, and the intent had to be STORED because the upstream has no idea
-- anything was decided here. CLAUDE.md says plainly: do not invent a second mechanism for the next
-- column that needs one.
--
-- So derm.stamp_sheet_status gains reopened_at / reopened_by, maintained by a trigger:
--   completed true -> false   record who re-opened it
--   anything -> true          clear it, because the review has been answered
-- and the auto-complete leg simply refuses to touch a row with reopened_at set.
--
-- A row that has NEVER been completed has reopened_at NULL, so first-time auto-completion is
-- untouched. That distinction is the whole point: "not yet completed" and "deliberately re-opened"
-- were previously the same state.
--
-- ---------------------------------------------------------------------------
-- PART 2.  HOW THE FUNCTION BODY WAS PRODUCED
-- ---------------------------------------------------------------------------
--
-- CREATE OR REPLACE takes the WHOLE body, so everything not reproduced is silently deleted --
-- 2026-08-06_1316 is the standing record of what that costs (seven silent deletions, 3.5 hours of
-- runtime failures). The body below was NOT retyped. It is the live pg_get_functiondef output with
-- two additive predicates spliced in by scripts/probes/tmp/patch-resolver.js, which asserts each
-- anchor matches exactly once, reverses the splice and requires byte equality with the original,
-- and refuses on any deleted line.
--
--   old 155 lines -> new 174 lines.  20 lines ADDED, 0 deleted, 1 clause extended
--   (the "where not ... completed;" line lost its semicolon to a continuation).
--
-- PART 5 additionally keeps the PREVIOUS body under a temporary name and requires it to FAIL where
-- the new one passes. A matrix with zero failures is an untested instrument.
--
-- ---------------------------------------------------------------------------
-- ADR 010 rule 8 (audit): derm.stamp_sheet_status is ALREADY audited, and adding a column to an
-- audited table is captured automatically (full-row JSONB) with no trigger work needed.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 3.  The pin
-- ---------------------------------------------------------------------------

ALTER TABLE derm.stamp_sheet_status
  ADD COLUMN IF NOT EXISTS reopened_at timestamptz,
  ADD COLUMN IF NOT EXISTS reopened_by text;

COMMENT ON COLUMN derm.stamp_sheet_status.reopened_at IS
  'Set when a completed sheet is deliberately re-opened, by a person in the Studio or by '
  'derm.trg_zx_generated_sheet_return_review when a returned sheet photo arrives. While it is set, '
  'derm.fn_resolve_generated_sheet_for_ticket will NOT auto-complete the sheet. Cleared when the '
  'sheet is completed again. NULL on a sheet that has simply never been completed -- that is a '
  'different state, and the two used to be indistinguishable. '
  'See docs/migrations/2026-08-24_1545_pin_completion_flag.sql.';

CREATE OR REPLACE FUNCTION derm.fn_stamp_sheet_reopen_pin()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $fn$
begin
  if OLD.completed and not NEW.completed then
    NEW.reopened_at := now();
    NEW.reopened_by := coalesce(nullif(current_setting('request.jwt.claim.email', true), ''),
                                current_user);
  elsif NEW.completed then
    -- the review has been answered, so re-arm auto-completion
    NEW.reopened_at := null;
    NEW.reopened_by := null;
  end if;
  return NEW;
end $fn$;

DROP TRIGGER IF EXISTS trg_aa_reopen_pin ON derm.stamp_sheet_status;
CREATE TRIGGER trg_aa_reopen_pin
  BEFORE UPDATE ON derm.stamp_sheet_status
  FOR EACH ROW EXECUTE FUNCTION derm.fn_stamp_sheet_reopen_pin();

-- ---------------------------------------------------------------------------
-- PART 4.  The resolver: live body + two additive predicates. See PART 2.
-- ---------------------------------------------------------------------------
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
     -- 2026-08-24: "no card is unplaced" was the ONLY condition here, and it never asked whether
     -- the stamps can be DRAWN. That is exactly why the Studio reported "3/3 stamped" over a blank
     -- sheet for ticket 833395 after an address image was deleted: the counter reads
     -- stamp_placed_at, the renderer reads stamp_page, and only the second had broken.
     -- A stamp addressing a page outside the ticket's image list is not a completed sheet.
     and not exists (select 1 from derm.address_row_map r3
                      where r3.dump_folder = d.dump_folder
                        and r3.stamp_placed_at is not null
                        and (r3.stamp_page is null or r3.stamp_page < 1
                             or r3.stamp_page > coalesce(array_length(
                                  derm.ticket_page_images(r3.white_manifest_number), 1), 0)))
  on conflict (dump_folder) do update
     set completed    = true,
         completed_at = coalesce(derm.stamp_sheet_status.completed_at, now()),
         completed_by = coalesce(derm.stamp_sheet_status.completed_by, 'stamp-studio-ai'),
         updated_at   = now()
   where not derm.stamp_sheet_status.completed
     -- 2026-08-24: ... and NOT when a person or another trigger deliberately RE-OPENED it.
     -- Measured on ticket-833395: a human set completed=false at 10:56:39 ET and this leg silently
     -- restored true at 11:25:41. The bigger case is not the human one --
     -- derm.trg_zx_generated_sheet_return_review writes the same false as the MACHINE's request for
     -- a visual check when a returned sheet photo arrives, and it has fired 4 times, so this leg
     -- was also able to discard a review request microseconds after another trigger raised it.
     -- Same pin as public.clients.status_source; do not invent a second mechanism.
     and derm.stamp_sheet_status.reopened_at is null;

  return v_sheet_id;
end $function$;

-- ---------------------------------------------------------------------------
-- PART 5.  VERIFY. The previous body is the control and must fail both cells.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm._ctl_old_resolver(p_ticket text)
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

DO $verify$
DECLARE
  v_new_reopened boolean; v_old_reopened boolean;
  v_new_unrender boolean; v_old_unrender boolean;
  v_new_normal   boolean;
  v_pin_at timestamptz; v_pin_by text;
BEGIN
  ------------------------------------------------------------------------
  -- 5.1  The pin trigger itself: true -> false records, -> true clears.
  ------------------------------------------------------------------------
  BEGIN
    BEGIN
      UPDATE derm.stamp_sheet_status SET completed = false WHERE dump_folder = 'ticket-833395';
      SELECT reopened_at, reopened_by INTO v_pin_at, v_pin_by
        FROM derm.stamp_sheet_status WHERE dump_folder = 'ticket-833395';
      RAISE EXCEPTION 'rollback_the_probe';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'rollback_the_probe' THEN RAISE; END IF;
    END;
    IF v_pin_at IS NULL OR v_pin_by IS NULL THEN
      RAISE EXCEPTION 're-opening a completed sheet did not record reopened_at/by';
    END IF;
    RAISE NOTICE 'OK: re-open recorded at % by %', v_pin_at, v_pin_by;
  END;

  ------------------------------------------------------------------------
  -- 5.2  CELL A: a RE-OPENED sheet. New body must leave it alone; the OLD body
  --      must re-complete it, which is the defect Fred hit.
  ------------------------------------------------------------------------
  BEGIN
    BEGIN
      UPDATE derm.stamp_sheet_status SET completed = false WHERE dump_folder = 'ticket-833395';
      PERFORM derm.fn_resolve_generated_sheet_for_ticket('833395');
      SELECT completed INTO v_new_reopened FROM derm.stamp_sheet_status WHERE dump_folder = 'ticket-833395';
      RAISE EXCEPTION 'rollback_the_probe';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'rollback_the_probe' THEN RAISE; END IF;
    END;
    BEGIN
      UPDATE derm.stamp_sheet_status SET completed = false WHERE dump_folder = 'ticket-833395';
      PERFORM derm._ctl_old_resolver('833395');
      SELECT completed INTO v_old_reopened FROM derm.stamp_sheet_status WHERE dump_folder = 'ticket-833395';
      RAISE EXCEPTION 'rollback_the_probe';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'rollback_the_probe' THEN RAISE; END IF;
    END;
    IF v_new_reopened IS NOT FALSE THEN
      RAISE EXCEPTION 'THE PIN DOES NOT HOLD: the new body re-completed a re-opened sheet';
    END IF;
    IF v_old_reopened IS NOT TRUE THEN
      RAISE EXCEPTION 'CONTROL FAILED: the old body did NOT re-complete a re-opened sheet, so this cell proves nothing';
    END IF;
    RAISE NOTICE 'CELL A OK: re-opened sheet stays false on the new body, was re-completed by the old';
  END;

  ------------------------------------------------------------------------
  -- 5.3  CELL B: an UNRENDERABLE sheet -- every card placed, all addressing a page
  --      that does not exist. This is literally the "3/3 over a blank sheet" state.
  --      reopened_at is cleared first so this cell tests renderability ALONE.
  ------------------------------------------------------------------------
  BEGIN
    BEGIN
      UPDATE derm.stamp_sheet_status SET completed = false WHERE dump_folder = 'ticket-833395';
      UPDATE derm.stamp_sheet_status SET reopened_at = NULL, reopened_by = NULL
       WHERE dump_folder = 'ticket-833395';
      UPDATE derm.address_row_map SET stamp_page = 9 WHERE white_manifest_number = '833395';
      PERFORM derm.fn_resolve_generated_sheet_for_ticket('833395');
      SELECT completed INTO v_new_unrender FROM derm.stamp_sheet_status WHERE dump_folder = 'ticket-833395';
      RAISE EXCEPTION 'rollback_the_probe';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'rollback_the_probe' THEN RAISE; END IF;
    END;
    BEGIN
      UPDATE derm.stamp_sheet_status SET completed = false WHERE dump_folder = 'ticket-833395';
      UPDATE derm.stamp_sheet_status SET reopened_at = NULL, reopened_by = NULL
       WHERE dump_folder = 'ticket-833395';
      UPDATE derm.address_row_map SET stamp_page = 9 WHERE white_manifest_number = '833395';
      PERFORM derm._ctl_old_resolver('833395');
      SELECT completed INTO v_old_unrender FROM derm.stamp_sheet_status WHERE dump_folder = 'ticket-833395';
      RAISE EXCEPTION 'rollback_the_probe';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'rollback_the_probe' THEN RAISE; END IF;
    END;
    IF v_new_unrender IS NOT FALSE THEN
      RAISE EXCEPTION 'THE RENDERABILITY GUARD DOES NOT HOLD: the new body completed a sheet whose stamps cannot be drawn';
    END IF;
    IF v_old_unrender IS NOT TRUE THEN
      RAISE EXCEPTION 'CONTROL FAILED: the old body did NOT complete the unrenderable sheet, so this cell proves nothing';
    END IF;
    RAISE NOTICE 'CELL B OK: unrenderable sheet stays false on the new body, was completed by the old';
  END;

  ------------------------------------------------------------------------
  -- 5.4  CELL C, THE ONE THAT STOPS THIS BEING A BLANKET REFUSAL: a normal sheet,
  --      never re-opened, all stamps renderable, MUST still auto-complete.
  ------------------------------------------------------------------------
  BEGIN
    BEGIN
      UPDATE derm.stamp_sheet_status SET completed = false WHERE dump_folder = 'ticket-833395';
      UPDATE derm.stamp_sheet_status SET reopened_at = NULL, reopened_by = NULL
       WHERE dump_folder = 'ticket-833395';
      PERFORM derm.fn_resolve_generated_sheet_for_ticket('833395');
      SELECT completed INTO v_new_normal FROM derm.stamp_sheet_status WHERE dump_folder = 'ticket-833395';
      RAISE EXCEPTION 'rollback_the_probe';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'rollback_the_probe' THEN RAISE; END IF;
    END;
    IF v_new_normal IS NOT TRUE THEN
      RAISE EXCEPTION 'REGRESSION: the new body refuses to auto-complete a perfectly healthy sheet';
    END IF;
    RAISE NOTICE 'CELL C OK: a healthy, never-re-opened sheet still auto-completes';
  END;

  ------------------------------------------------------------------------
  -- 5.5  Nothing leaked out of the rolled-back probes.
  ------------------------------------------------------------------------
  IF NOT EXISTS (SELECT 1 FROM derm.stamp_sheet_status
                  WHERE dump_folder = 'ticket-833395' AND completed AND reopened_at IS NULL) THEN
    RAISE EXCEPTION 'a probe leaked a status change onto ticket-833395';
  END IF;
  IF EXISTS (SELECT 1 FROM derm.address_row_map
              WHERE white_manifest_number = '833395' AND stamp_page <> 1) THEN
    RAISE EXCEPTION 'a probe leaked a stamp_page change onto ticket-833395';
  END IF;
END $verify$;

DROP FUNCTION derm._ctl_old_resolver(text);

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'derm' AND p.proname = '_ctl_old_resolver') THEN
    RAISE EXCEPTION 'the control function survived the drop';
  END IF;
  RAISE NOTICE 'ALL OK: completion now requires renderable stamps and respects a deliberate re-open';
END $$;

COMMIT;
