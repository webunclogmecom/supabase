-- 2026-08-06_1655 — the PAPER decides which row a stamp lands on
--                   (and REPAIRS the regression I shipped in 2026-08-06_1316)
--
-- Fred: "do both, but can we keep the certainty really high so we minimize the stamping landing on
-- another clients row? think about this, maybe training, adapting a tool to this, or what."
--
-- ─────────────────────────────────────────────────────────────────────────────
-- 🛑 PART 0 — WHAT 2026-08-06_1316 BROKE. READ THIS BEFORE THE FEATURE.
-- ─────────────────────────────────────────────────────────────────────────────
-- 1316's header said the anti-AI auto-complete clause was the only change and that the rest was
-- "re-stated here in full ... not because any of it moved." That was FALSE. It was retyped rather
-- than copied, and it silently lost the following, all restored here from 2026-08-05_0023:
--
--   * 🛑 IT DID NOT COMPILE AT RUNTIME. Candidate selection became
--     `select s.sheet_id ... having count(*) = 1` with no GROUP BY, which Postgres rejects with
--     42803. Proven directly: `select x from (select 1 x) s having count(*)=1` -> 42803, while
--     `select max(x) ...` returns 1 for one row and NO rows for zero or many. So from 13:16 today
--     the resolver RAISED for every ticket that was not already resolved, instead of returning null.
--     The correct shape is 0023's CTE + `select count(*), min(sheet_id) into v_n, v_sheet_id`.
--   * the `derm_manifests.derm_address_no` write — dropped entirely, so resolved tickets stopped
--     recording which sheet number they landed on.
--   * `v_dump_date` semantics — 0023 uses `min(m.service_date)` (when the work happened, which is
--     what the causality guard means); 1316 changed it to `max(m.dump_ticket_date)`.
--   * `deleted_at is null` on `address_sheets` in both the already-resolved lookup and candidacy —
--     a soft-deleted sheet could be resolved onto.
--   * `on conflict (sheet_id, manifest_id) do update set slot = excluded.slot` -> `do nothing`,
--     so a corrected slot would no longer be applied.
--   * the sheet-number gate inside CANDIDATE SELECTION (1316 kept it only at placement).
--   * `and s.o_y_pct is not null` on placement, and `where not ... completed` on the completion
--     upsert.
--
-- ⚠ The lesson, and it is the one this repo keeps paying for: **CREATE OR REPLACE needs the whole
-- body, so the whole body must be COPIED, never retyped from memory.** A migration whose header
-- says "nothing else moved" is a claim that has to be diffed, not asserted. `2026-08-06_1316` is
-- already on origin; it is corrected forward here rather than rewritten, per the audit-trail rule.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- PART 1 — THE ACTUAL FEATURE: relax the MATCHING, tighten the PLACEMENT
-- ─────────────────────────────────────────────────────────────────────────────
-- `derm.address_sheet_row_reads` (2026-08-06_1422) records what a vision pass READ in each printed
-- Section B row. Validated against the images BY EYE before anything was built on it:
--   * 10/10 page reads over TWO passes matched the paper exactly, all 21 rows, 3 tickets.
--   * Includes sheet 1081 page 2, carrying BOTH '061-TCE The carrot express 71st Collins' and
--     '062-TCE The carrot express Aventura Mall', read in the right order. That pair is the mis-place
--     a facility-NAME match would make, which is why the gate compares the CLIENT CODE.
--   * Gate controls, three directions: right client -> TRUE 8/8; wrong client -> FALSE 8/8; right
--     client forced onto row 5 -> FALSE for rows 1-4, TRUE only for the client that really is row 5.
--     That third control is what proves it is POSITION-sensitive and not merely client-sensitive;
--     a gate that always returned TRUE would have passed the first two.
--
-- 🛑 AND IT IMMEDIATELY CAUGHT A REAL ONE. Ticket 310590's scans are stored in REVERSE page order
-- (image position 1 is printed page 2). Relaxed the obvious way, all 8 of its stamps would have
-- landed on another client's row — 047-PAM printed over 010-CS's line — on a document the Field
-- Portal serves to clients. The gate refused 8 of 9 outright.
--
-- ⚠ THE EVIDENCE HAD BEEN IN THE DB FOR FIVE DAYS: `address_sheet_scan_reads` already held '1074-2'
-- for position 1 and '1074-1' for position 2. The sheet-number OCR records the printed page in the
-- SUFFIX and nobody consumed it. Hence `fn_sheet_image_position` below.
--
-- ⚠ NO EXISTING STAMP IS WRONG. Both multi-page folders carrying AI placements were re-checked
-- against the paper: ticket-831938 8/8, ticket-310429 7/7. They are the only 2 of 31 multi-page
-- folders with AI stamps; the other 29 were placed by hand with the page on screen. Prevention,
-- not remediation.
--
-- 3NF: no new column; mapping and verdict are computed on read from what was measured.
-- Audit: `derm.address_row_map` + `derm.stamp_sheet_status` already carry audit triggers.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Printed page  ->  image position
-- ─────────────────────────────────────────────────────────────────────────────
-- `stamp_page` is a POSITIONAL index into ticket_page_images(wm) (the Studio's page-list invariant),
-- while sheet geometry numbers pages LOGICALLY (slots 1-5 = printed page 1). They agree only when
-- the scans happen to be stored in printed order; when they disagree every stamp lands on the wrong
-- page, silently, because both numbers are plausible.
--
-- ⚠ IDENTITY FALLBACK IS DELIBERATE AND IS THE COMMON CASE: only 5 of 10 scan reads carry a suffix,
-- so most folders have no opinion and must behave exactly as today. Do NOT infer an order from
-- filenames — address_1/address_2 is precisely the ordering that was wrong.
create or replace function derm.fn_sheet_image_position(p_dump_folder text, p_logical_page int)
returns int
language sql
stable
security definer
set search_path to 'derm', 'public'
as $$
  select coalesce(
    (select sr.page
       from derm.address_sheet_scan_reads sr
      where sr.dump_folder = p_dump_folder
        and sr.confidence  = 'high'
        and sr.sheet_no_read ~ '-[0-9]+$'
        and split_part(sr.sheet_no_read, '-', 2)::int = p_logical_page
      order by sr.page
      limit 1),
    p_logical_page);
$$;

comment on function derm.fn_sheet_image_position(text,int) is
  'Translates a LOGICAL printed sheet page into the IMAGE POSITION holding it, using the page suffix '
  'the sheet-number OCR already records (''1074-2'' = printed page 2). Identity fallback when no '
  'high-confidence suffix exists (the majority case). Exists because ticket-310590''s scans are '
  'stored in reverse page order, which would have put all 8 of its stamps on the wrong page.';

revoke all on function derm.fn_sheet_image_position(text,int) from public, anon, authenticated;
grant execute on function derm.fn_sheet_image_position(text,int) to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Does the paper confirm EVERY row this ticket would place on this sheet?
-- ─────────────────────────────────────────────────────────────────────────────
-- Authorises the RELAXED matching path only. Demands `IS TRUE` per row, so an unread row (NULL) and
-- a contradicted row (FALSE) both refuse. "No evidence against" is not evidence for, and this is
-- the function where that distinction lives.
create or replace function derm.fn_sheet_rows_all_confirmed(
  p_ticket text, p_sheet_id bigint, p_dump_folder text)
returns boolean
language sql
stable
security definer
set search_path to 'derm', 'public'
as $$
  select coalesce(bool_and(
           derm.fn_row_read_confirms(
             p_dump_folder,
             derm.fn_sheet_image_position(p_dump_folder, ((asc2.slot - 1) / 5) + 1),
             ((asc2.slot - 1) % 5) + 1,
             c.client_code) is true
         ), false)
    from derm.address_sheet_clients asc2
    join public.clients c on c.id = asc2.client_id
   where asc2.sheet_id = p_sheet_id
     and asc2.client_id in (
           select m.client_id
             from public.derm_manifests m
            where coalesce(m.white_manifest_number, m.yellow_ticket_number) = p_ticket
              and m.deleted_at is null);
$$;

comment on function derm.fn_sheet_rows_all_confirmed(text,bigint,text) is
  'TRUE only when the scanned sheet positively names the right client on EVERY row this ticket would '
  'stamp. Unread rows count as refusal, not consent. Gates the relaxed matching path only.';

revoke all on function derm.fn_sheet_rows_all_confirmed(text,bigint,text) from public, anon, authenticated;
grant execute on function derm.fn_sheet_rows_all_confirmed(text,bigint,text) to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2b. The row index must count the SHEET's roster, not the ticket's manifests
-- ─────────────────────────────────────────────────────────────────────────────
-- The old body summed printed rows over `address_sheet_manifests` for THIS TICKET below the slot.
-- That silently assumes the sheet contains exactly the ticket's manifests. When the sheet prints a
-- facility filed on a DIFFERENT ticket, that row is not counted and every row below it shifts UP by
-- one — i.e. every stamp below the gap lands on the next client's line.
--
-- Ticket 310590 is exactly that: sheet 1074 prints 165-LPB at slot 3, but 165-LPB's manifest went to
-- ticket 310607. Measured under the old body: 186-PV computed slot 3 instead of 4, and 010-CS, 189-FRE,
-- 070-TCE, 191-TEN all shifted. The row gate refused 6 of 8, which is the gate doing its job, but the
-- underlying arithmetic is what is wrong. `address_sheet_clients` is the authoritative printed roster,
-- so count over that.
--
-- (The `greatest(1, count(active GDOs))` term is unchanged: a multi-GDO client prints one row per GDO.)
--
-- ⚠ EQUIVALENCE ON TODAY'S DATA IS PROVEN BY CONSTRUCTION, NOT BY THE TEST. Old and new agree on all
-- 18 currently-linked manifests — but the control says **0 sheets currently have a roster larger than
-- their linked set**, so that comparison CANNOT distinguish the two formulas. It is evidence of no
-- regression and nothing more; do not cite "18/18 identical" as evidence the new arithmetic is right.
-- The evidence that it is right is the independent one: under the new body all 8 of ticket-310590's
-- rows land on the row the scanned sheet names (verified by eye), versus 2 of 8 before.
CREATE OR REPLACE FUNCTION derm.fn_generated_sheet_slot(p_manifest_id bigint)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
  with me as (
    select l.sheet_id, l.slot as my_slot
      from public.derm_manifests m
      join derm.address_sheet_manifests l on l.manifest_id = m.id
      join derm.address_sheets s on s.id = l.sheet_id and s.deleted_at is null
     where m.id = p_manifest_id and m.deleted_at is null
     order by l.slot nulls last
     limit 1
  ), before as (
    select greatest(1, (select count(*) from public.gdos gd
                         where gd.client_id = ac.client_id and gd.status = 'ACTIVE'
                           and gd.gdo_number ~ '^GDO-[0-9]+$'))::int as rows_printed
      from derm.address_sheet_clients ac
      join me on ac.sheet_id = me.sheet_id
     where ac.slot < me.my_slot
  )
  -- NULL when the order was never recorded: caller must refuse, not guess.
  select case when (select my_slot from me) is not null
              then 1 + coalesce((select sum(rows_printed) from before), 0)::int
         end;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. The resolver — 2026-08-05_0023's body, restored verbatim, plus 4 deltas
-- ─────────────────────────────────────────────────────────────────────────────
--   (d1) auto-complete no longer excludes AI-placed sheets      [Fred, was 1316's only intended change]
--   (d2) placement writes stamp_page as the IMAGE POSITION      [new]
--   (d3) placement refuses a row the paper contradicts          [new, disagreement-only]
--   (d4) a RELAXED candidate path, gated on full row confirmation [new]
CREATE OR REPLACE FUNCTION derm.fn_resolve_generated_sheet_for_ticket(p_ticket text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
declare v_sheet_id bigint; v_n int; v_dump_date date; v_folder text;
begin
  if p_ticket is null then return null; end if;

  -- 2026-08-04: a generated sheet created after the work happened cannot be the sheet the driver
  -- physically carried. NOTE min(service_date), not dump_ticket_date (1316 changed this in error).
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
    -- On an N-client shared ticket this correctly returns NULL for the first N-1 filings and
    -- resolves on the LAST one. Refuse-not-guess.
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
         -- 2026-08-04 CAUSALITY GUARD
         and v_dump_date is not null
         and (s.created_at at time zone 'America/New_York')::date <= v_dump_date
         -- 2026-08-05 SHEET-NUMBER GATE (disagreement-only). ⚠ STRIP THE PAGE SUFFIX: a multi-page
         -- form prints "1072-1"/"1072-2" while our sheet_no is 1072; comparing raw would refuse
         -- ticket 310429, a CORRECT placement.
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

    -- (d4) RELAXED path — only when STRICT matched nothing, and only with the paper's positive
    -- consent on every row this ticket would stamp. Two real shapes, both seen 2026-08-06:
    --   * SUPERSET — sheet 1074 prints 9 facilities but only 8 manifests were filed against ticket
    --     310590 (165-LPB's went to 310607), so exact-set can never match. A sheet listing MORE than
    --     we filed is normal: a facility can be written down and billed on another ticket.
    --   * DUPLICATE — sheets 1077/1078 have byte-identical rosters, so single-candidate refuses.
    --     Row confirmation cannot separate them (identical rosters confirm identically), so the
    --     SHEET NUMBER read off the paper breaks the tie: ticket 310607 reads '1078' at high
    --     confidence. Identification, not preference.
    -- ⚠ The SUBSET direction stays forbidden: a ticket naming a client the sheet does not print
    -- means we are looking at the wrong sheet, and no row check can rescue that.
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
           -- the paper must NAME this sheet (positively, not merely fail to contradict it)
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

  -- Place existing unplaced cards. WRITES ONLY THE STAMP COLUMNS -- never `page`. `page` pairs with
  -- `image_url` to build the sheet's page list (ticket_page_images groups by page and takes
  -- mode(image_url)); moving it on an existing card duplicates an image and invents a page.
  -- See 2026-07-30_2345. `stamp_page` is what the Studio renders on.
  update derm.address_row_map a
     set stamp_page  = s.img_page,
         stamp_x_pct = round(s.o_x_pct, 3),
         stamp_y_pct = round(s.o_y_pct, 3),
         stamp_placed_at = now(),
         stamp_placed_by = 'stamp-studio-ai'
    from (select r.id,
                 -- (d2) logical printed page -> image position
                 derm.fn_sheet_image_position(r.dump_folder, g.o_page) as img_page,
                 g.o_x_pct, g.o_y_pct
            from derm.address_row_map r
            cross join lateral derm.fn_generated_row_geometry(
                         derm.fn_generated_sheet_slot(r.matched_manifest_id)) g
            join public.clients cl on cl.id = r.matched_client_id
           where r.white_manifest_number = p_ticket
             and r.stamp_placed_at is null
             -- 2026-08-04 CAUSALITY GUARD, defence in depth
             and v_dump_date is not null
             and exists (
                   select 1
                     from derm.address_sheet_manifests l
                     join derm.address_sheets sh on sh.id = l.sheet_id and sh.deleted_at is null
                    where l.manifest_id = r.matched_manifest_id
                      and (sh.created_at at time zone 'America/New_York')::date <= v_dump_date
                      -- 2026-08-05 SHEET-NUMBER GATE, disagreement-only
                      and not exists (
                            select 1
                              from derm.address_sheet_scan_reads sr
                             where sr.dump_folder = r.dump_folder
                               and sr.sheet_no_read is not null
                               and split_part(sr.sheet_no_read, '-', 1) <> sh.sheet_no::text))
             -- (d3) ROW GATE, disagreement-only. `IS NOT FALSE` (not `IS TRUE`) keeps this
             -- monotonic: a sheet with no row reads is unaffected, exactly as before. Only an
             -- actual contradiction blocks. This is the leg that refuses ticket-310590's 8 rows.
             and derm.fn_row_read_confirms(
                   r.dump_folder,
                   derm.fn_sheet_image_position(r.dump_folder, g.o_page),
                   ((derm.fn_generated_sheet_slot(r.matched_manifest_id) - 1) % 5) + 1,
                   cl.client_code) is not false
         ) s
   where a.id = s.id
     and s.o_y_pct is not null;

  -- (d1) 2026-08-06: an AI-placed generated sheet now auto-completes like any other. The
  -- 2026-08-04 "no AI placement" clause is gone (Fred). The wrong-stamp risk it guarded now sits
  -- upstream where it belongs: causality guard + sheet-number gate + the row gate above, which
  -- refuse to PLACE rather than refusing to FINISH.
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

-- VERIFICATION (rolled-back probe BEFORE trusting it, never after):
--   * the function must not raise for an unresolved ticket (the 1316 42803 regression);
--   * ticket-310607 resolves to sheet 1078 (not 1077) and places 4 rows, all gate-confirmed;
--   * ticket-310590 places its 8 rows at CORRECTED image positions (047-PAM on position 2);
--   * ticket-831938 / ticket-310429 untouched;
--   * a sheet with no row reads behaves exactly as before.
