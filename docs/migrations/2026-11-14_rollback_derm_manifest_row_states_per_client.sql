-- ROLLBACK of 2026-11-14_0135_derm_manifest_row_states_per_client.sql (the row states core and the per-client read).
--
-- Puts derm.manifest_row_states() back to its 2026-11-13_0148 body (verbatim, md5 17b8b7193288cc5a1ce5ee87f0b118eb with carriage returns
-- removed; its grants are kept by CREATE OR REPLACE), then drops derm.manifest_row_states_for_client(bigint) and
-- derm.fn_manifest_row_states_core(). Guarded: refuses unless the live wrapper is the body this migration applied, and
-- refuses while derm.get_manifest_dialog(text) still exists (it reads the core: roll that one back first).
-- A portal build that already reads the per-client function shows its Compliance icons as "could not be read" until the
-- function is back; the Manifests list (DERM Tracker setting) keeps working.

BEGIN;
SET LOCAL lock_timeout = '3s';

do $pin$
begin
  if md5(replace(pg_get_functiondef('derm.manifest_row_states()'::regprocedure), chr(13), '')) <> 'ff7778cd3fb4ec915a6dd56ce2629a1c' then
    raise exception 'derm.manifest_row_states() is not the body of 2026-11-14_0135_derm_manifest_row_states_per_client; do not undo blindly';
  end if;
  if to_regprocedure('derm.get_manifest_dialog(text)') is not null then
    raise exception 'derm.get_manifest_dialog(text) still reads the core: undo that migration first';
  end if;
end
$pin$;

drop function derm.manifest_row_states_for_client(bigint);

CREATE OR REPLACE FUNCTION derm.manifest_row_states()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_out jsonb;
begin
  -- The gate, word for word the one of derm.get_visit_report.
  perform hr.fn_require_app('derm_tracker', 'view');
  if nullif(current_setting('request.jwt.claims', true), '') is not null
     and coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    if auth.uid() is null then
      raise exception 'authentication required' using errcode = '28000';
    end if;
    if not public.fn_is_staff_email(lower(coalesce(auth.jwt() ->> 'email', ''))) then
      raise exception 'not a staff account' using errcode = '42501';
    end if;
  end if;

  with
  -- Test and fixture clients, by the registry the bell uses (public.fn_is_non_customer reads this view).
  tc as materialized (
    select distinct n.client_id from public.v_non_customer_clients n where n.kind = any (array['test', 'fixture'])
  ),
  -- Every live manifest row (one client on one ticket), with the list's own row key.
  m as materialized (
    select dm.id,
           coalesce(dm.white_manifest_number, dm.yellow_ticket_number, '') as num,
           coalesce(dm.yellow_ticket_number, '') <> '' as is_yellow,
           case when coalesce(dm.white_manifest_number, dm.yellow_ticket_number, '') = '' then 'No number'
                when coalesce(dm.yellow_ticket_number, '') <> '' then 'Broward #' || coalesce(dm.white_manifest_number, dm.yellow_ticket_number)
                else 'Miami-Dade #' || coalesce(dm.white_manifest_number, dm.yellow_ticket_number) end as key,
           coalesce(dm.dump_ticket_date, dm.service_date) as dump_date,
           dm.dump_ticket_date is null as no_dump_date,
           dm.yellow_ticket_number is null and (dm.white_manifest_number is null or length(dm.white_manifest_number) < 5) as no_number,
           dm.derm_manifest_url is null as no_receipt,
           coalesce(dm.derm_address_url, '') <> '' or coalesce(cardinality(dm.derm_address_extra_urls), 0) > 0 as has_scan,
           dm.notes is not null as has_note,
           exists (select 1 from tc where tc.client_id = dm.client_id) as is_test
      from public.derm_manifests dm
     where dm.deleted_at is null
  ),
  -- PAPERS. "Documented" has one meaning: derm.manifest_health says fully_complete on every row of the ticket.
  h as materialized (
    select mh.id, mh.health_state from derm.manifest_health mh
  ),
  -- Which piece is missing, asked only for the rows that are not complete.
  gap as materialized (
    select m.key, m.no_receipt, m.no_number, m.no_dump_date, m.has_note,
           not derm.fn_manifest_address_documented(m.id) as no_address
      from m left join h on h.id = m.id
     where h.health_state is distinct from 'fully_complete'
  ),
  row_gap as materialized (
    select g.key,
           count(*) as n,
           count(*) filter (where g.no_receipt) as n_receipt,
           count(*) filter (where g.no_address) as n_address,
           count(*) filter (where g.no_number) as n_number,
           count(*) filter (where g.no_dump_date) as n_date,
           bool_and(g.has_note) as all_noted
      from gap g
     group by g.key
  ),
  -- The live visits linked to each manifest row.
  lv as materialized (
    select mv.manifest_id, mv.visit_id, v.client_id, v.property_id
      from public.manifest_visits mv
      join m on m.id = mv.manifest_id
      join public.visits v on v.id = mv.visit_id and v.deleted_at is null
  ),
  mvis as materialized (
    select distinct lv.manifest_id from lv
  ),
  -- The send rule: a client row with no document to send (no blacked-out copy and no Broward per-visit form).
  fog as materialized (
    select r.manifest_id, r.send_blocker from public.v_derm_manifest_email_readiness r
  ),
  -- STAMPS. The cards, and the sheets as the Stamp list defines them.
  cards as materialized (
    select r.id, r.white_manifest_number as wm, r.matched_manifest_id as mid, r.matched_client_id as cid, r.manual_code,
           coalesce(r.stamp_page, r.page) as pg, r.stamp_y_pct is not null as has_pos, r.stamp_placed_at,
           r.band_y0_pct as y0, r.band_y1_pct as y1
      from derm.address_row_map r
  ),
  sh as materialized (
    select s.white_manifest_number as wm, s.dump_folder, s.completed, s.completed_at, s.placed_rows, s.total_rows
      from derm.v_stamp_sheets s
  ),
  sh_open as materialized (
    select s.white_manifest_number as wm, s.skipped, s.skip_reason
      from derm.v_stamp_sheets s
     where not s.completed
  ),
  -- The bell's rule (derm.fn_stamp_open_sheets): a sheet is a test sheet when every client it names, on the live
  -- manifests under its number and on its cards, is a test or fixture client. A card known only by a hand-typed code
  -- counts as a real client.
  sheet_test as materialized (
    select k.wm, bool_and(k.is_test) as test
      from (select m.num as wm, m.is_test from m
            union all
            select c.wm, exists (select 1 from tc where tc.client_id = c.cid)
              from cards c
             where c.cid is not null or c.manual_code is not null) k
     group by k.wm
  ),
  sheet as materialized (
    select s.wm, s.dump_folder, s.completed_at, s.placed_rows, s.total_rows,
           case when coalesce(o.skipped, false) then 'skipped'
                when s.completed then 'completed'
                when s.placed_rows > 0 then 'in_progress'
                else 'not_started' end as state,
           case when coalesce(o.skipped, false) then o.skip_reason end as skip_reason,
           coalesce(t.test, false) as test
      from sh s
      left join sh_open o on o.wm = s.wm
      left join sheet_test t on t.wm = s.wm
  ),
  -- A row finds its sheets through the cards' own manifest rows. Three sheets sit under a number one digit off their
  -- real ticket, so the number is not used. Only a sheet that no card places on any live row falls back to its number
  -- (0 today), and says so in "via", so that it cannot vanish from the list.
  sheet_key as materialized (
    select distinct s.wm, m.key, m.num, 'cards'::text as via
      from sheet s
      join cards c on c.wm = s.wm
      join m on m.id = c.mid
    union all
    select s.wm, k.key, k.num, 'number'::text
      from sheet s
      join (select distinct m.num, m.key from m) k on k.num = s.wm
     where not exists (select 1 from cards c join m on m.id = c.mid where c.wm = s.wm)
  ),
  row_sheets as materialized (
    select k.key,
           jsonb_agg(jsonb_build_object('folder', s.dump_folder, 'number', s.wm, 'state', s.state, 'placed', s.placed_rows,
                                        'total', s.total_rows, 'skip_reason', s.skip_reason, 'via', k.via, 'test', s.test)
                     order by (s.wm = k.num) desc, s.wm) as sheets,
           bool_or(s.state in ('not_started', 'in_progress')) as any_open,
           bool_and(s.state = 'skipped') as all_skipped,
           bool_and(s.state = 'skipped' and coalesce(s.skip_reason, '') = 'record_only') as all_record_only,
           bool_and(s.test) as all_test,
           coalesce(sum(s.placed_rows) filter (where s.state in ('not_started', 'in_progress')), 0) as open_placed,
           coalesce(sum(s.total_rows) filter (where s.state in ('not_started', 'in_progress')), 0) as open_total,
           -- the tooltip counts the sheet under the row's own number when there is one (a second sheet holds the same paper again)
           (array_agg(s.placed_rows order by (s.wm = k.num) desc, (s.state = 'completed') desc, s.wm))[1] as placed,
           (array_agg(s.total_rows order by (s.wm = k.num) desc, (s.state = 'completed') desc, s.wm))[1] as total,
           (array_agg(s.skip_reason order by (s.wm = k.num) desc, s.wm) filter (where s.state = 'skipped'))[1] as skip_reason
      from sheet_key k
      join sheet s on s.wm = k.wm
     group by k.key
  ),
  -- THE CLIENT COPIES. A client row with a visit and no document to send, and what its stamp cards say about it.
  blocked as materialized (
    select m.key, m.id as mid
      from m
      join fog f on f.manifest_id = m.id and f.send_blocker is not null
      join mvis on mvis.manifest_id = m.id
  ),
  bcard as materialized (
    select b.key, b.mid, c.id as card_id, c.wm, c.pg, c.y0, c.y1, c.stamp_placed_at, s.dump_folder, s.completed_at,
           coalesce(s.state, 'none') as sheet_state,
           c.has_pos and c.stamp_placed_at is null as held,
           -- the page of the sheet was never uploaded (the health check's own test, derm.fn_card_page_missing)
           c.stamp_placed_at is not null and derm.fn_card_page_missing(c.wm, c.pg) as page_missing
      from blocked b
      join cards c on c.mid = b.mid
      left join sheet s on s.wm = c.wm
  ),
  bman as materialized (
    select x.key, x.mid,
           bool_or(x.sheet_state in ('not_started', 'in_progress')) as on_open,
           bool_or(x.sheet_state = 'completed') as on_completed,
           bool_or(x.sheet_state = 'completed' and x.page_missing) as page_missing,
           bool_or(x.sheet_state = 'completed' and x.held) as held,
           bool_or(x.sheet_state = 'completed' and x.stamp_placed_at is not null) as placed,
           -- A copy follows Mark completed in seconds (redact-manifest-sheet v47). While the sheet was completed, or the
           -- stamp placed, less than 20 minutes ago, a missing copy is "being made". 20 minutes is the line the health
           -- check already draws (derm.v_blackout_completed_unpublished), so the row and the health email agree.
           bool_or(x.sheet_state = 'completed' and x.stamp_placed_at is not null
                   and greatest(x.completed_at, x.stamp_placed_at) > now() - interval '20 minutes') as young,
           min(x.dump_folder) filter (where x.sheet_state = 'completed') as folder
      from bcard x
     group by x.key, x.mid
  ),
  -- A stamp that has a place on the sheet but no placed time: it was taken back, or never confirmed. The day it was
  -- taken back is in the audit trail of the card. Two such stamps of two clients on one printed line (their bands
  -- overlap on the same page) are "clients that share one printed line".
  -- ponytail: one read of audit.logs per held stamp on a completed sheet (2 on 2026-11-13). If held stamps ever number
  -- in the dozens, read the audit trail once for all of them, or keep the day on the card.
  held as materialized (
    select x.key, x.mid, x.wm, x.pg, x.y0, x.y1,
           (select max(a.changed_at) from audit.logs a
             where a.table_schema = 'derm' and a.table_name = 'address_row_map' and (a.record_pk ->> 'id') = x.card_id::text
               and a.old_row ->> 'stamp_placed_at' is not null and a.new_row ->> 'stamp_placed_at' is null) as since
      from bcard x
     where x.held and x.sheet_state = 'completed'
  ),
  held_man as materialized (
    select hh.mid, max(hh.since) as since,
           bool_or(exists (select 1 from held o
                            where o.wm = hh.wm and o.pg = hh.pg and o.mid <> hh.mid and o.y0 < hh.y1 and hh.y0 < o.y1)) as shares
      from held hh
     group by hh.mid
  ),
  cause as materialized (
    select b.key, b.mid, n.folder,
           case
             when n.mid is null then case when rs.any_open is false and rs.all_skipped is false then 'no_card' end
             when n.on_open then null                   -- the sheet is still to stamp: the stamps state says it
             when not n.on_completed then null          -- the sheet is skipped: nothing is expected
             when n.page_missing then 'page_missing'    -- a paper is missing: the papers state says it
             when n.held then 'held'
             when n.placed and n.young then 'making'
             when n.placed then 'not_made'
             else 'stamp_missing'
           end as cause
      from blocked b
      left join bman n on n.mid = b.mid
      left join row_sheets rs on rs.key = b.key
  ),
  row_copies as materialized (
    select c.key,
           count(*) as n_no_copy,
           count(*) filter (where c.cause = 'held' and coalesce(hm.shares, false)) as n_shared,
           count(*) filter (where c.cause = 'held' and not coalesce(hm.shares, false)) as n_again,
           count(*) filter (where c.cause = 'stamp_missing') as n_unplaced,
           count(*) filter (where c.cause in ('not_made', 'no_card')) as n_not_made,
           count(*) filter (where c.cause = 'making') as n_making,
           count(*) filter (where c.cause = 'page_missing') as n_page,
           max(hm.since) filter (where c.cause = 'held' and coalesce(hm.shares, false)) as shared_since,
           min(c.folder) filter (where c.cause = 'not_made') as why_folder
      from cause c
      left join held_man hm on hm.mid = c.mid
     where c.cause is not null
     group by c.key
  ),
  row_pages as materialized (
    select x.key, array_agg(distinct x.pg order by x.pg) as pages
      from bcard x
     where x.sheet_state = 'completed' and x.page_missing
     group by x.key
  ),
  -- Why a copy was not made, in the database's own words (derm.fn_sheet_publishable, then derm.fn_publishable_hint).
  -- ponytail: one call costs about 0.1 s, so at most 3 sheets are asked per read; a fourth says "Tell Fred" until the
  -- first three are fixed. Raise the limit if that ever hides a reason someone needs.
  why as materialized (
    select f.folder, derm.fn_sheet_publishable(f.folder) as blocker
      from (select distinct rc.why_folder as folder from row_copies rc where rc.why_folder is not null order by 1 limit 3) f
  ),
  -- THE CITY. A (client row, client) pair counts when the client was visited at an address with a city inbox and the
  -- visit is not grey water: the list's own count (derm.manifests.city_total_count).
  cv as materialized (
    select distinct lv.visit_id
      from lv
      join public.properties p on p.id = lv.property_id and p.deleted_at is null
     where cardinality(coalesce(p.city_emails, '{}'::text[])) > 0
  ),
  cs as materialized (
    select s.visit_id, s.state, s.not_for_city
      from cv
      join public.v_visit_city_email_state s on s.visit_id = cv.visit_id
  ),
  city_sent as materialized (
    select distinct e.visit_id from public.v_visit_city_email_sends e where e.with_manifest
  ),
  pair as materialized (
    select m.key, lv.manifest_id, lv.client_id,
           bool_or(cs.state = 'needs_city_email') as ready,
           bool_or(cs.state = 'report_sent_manifest_follows') as follows,
           bool_or(cs.state = 'before_go_live') as old
      from lv
      join m on m.id = lv.manifest_id
      join cs on cs.visit_id = lv.visit_id
     where lv.client_id is not null and not cs.not_for_city
     group by m.key, lv.manifest_id, lv.client_id
  ),
  -- The list's own rule for "sent": a city email that carried the manifest, on any visit of that client on the ticket.
  got as materialized (
    select distinct m.key, lv.client_id
      from lv
      join m on m.id = lv.manifest_id
      join city_sent s on s.visit_id = lv.visit_id
  ),
  row_city as materialized (
    select p.key,
           count(*) as total,
           count(*) filter (where g.key is not null) as sent,
           count(*) filter (where g.key is null and p.ready and f.send_blocker is null) as due,
           count(*) filter (where g.key is null and p.ready and f.send_blocker is not null) as waits_copy,
           count(*) filter (where g.key is null and not p.ready and p.follows) as follows,
           count(*) filter (where g.key is null and not p.ready and not p.follows and p.old) as old
      from pair p
      left join got g on g.key = p.key and g.client_id = p.client_id
      left join fog f on f.manifest_id = p.manifest_id
     group by p.key
  ),
  -- A VISIT DATED AFTER THE DUMP, by more than the one day the database allows.
  late as materialized (
    select m.key, count(distinct c.visit_id) as n, min(c.days_after_offload) as d_min, max(c.days_after_offload) as d_max
      from derm.v_manifest_link_date_conflicts c
      join m on m.id = c.manifest_id
     where c.violates_guard
     group by m.key
  ),
  rk as materialized (
    select m.key,
           array_agg(m.id order by m.id) as manifest_ids,
           max(m.dump_date) as dump_date,
           bool_or(m.is_yellow) as is_yellow,
           bool_or(m.has_scan) as has_scan,
           bool_and(m.is_test) as all_test,
           count(mvis.manifest_id) as n_with_visit
      from m
      left join mvis on mvis.manifest_id = m.id
     group by m.key
  ),
  f as (
    select rk.key, rk.manifest_ids, rk.dump_date, rk.is_yellow, rk.has_scan, rk.n_with_visit,
           rk.all_test and coalesce(rs.all_test, true) as test,
           coalesce(rs.sheets, '[]'::jsonb) as sheets,
           g.key is not null as has_gap,
           g.key is not null and g.all_noted as noted,
           -- "Kept for the record": a ticket from before 2026 whose every sheet a person skipped as "Old visit, entered
           -- for the record only". All three must hold, so nothing else turns grey by this rule.
           g.key is not null and not g.all_noted and rk.dump_date < date '2026-01-01' and coalesce(rs.all_record_only, false) as record,
           g.n, g.n_receipt, g.n_address, g.n_number, g.n_date,
           rs.key is not null as has_sheet, rs.any_open, rs.all_skipped, rs.open_placed, rs.open_total, rs.placed, rs.total, rs.skip_reason,
           coalesce(rc.n_no_copy, 0) as n_no_copy, coalesce(rc.n_shared, 0) as n_shared, coalesce(rc.n_again, 0) as n_again,
           coalesce(rc.n_unplaced, 0) as n_unplaced, coalesce(rc.n_not_made, 0) as n_not_made, coalesce(rc.n_making, 0) as n_making,
           coalesce(rc.n_page, 0) as n_page, rc.shared_since, rp.pages,
           case when w.blocker is not null then rtrim(split_part(btrim(derm.fn_publishable_hint(w.blocker)), '. ', 1), '.')
                else 'The copy was not made. Tell Fred' end as why,
           ct.key is not null as has_city, ct.total as c_total, ct.sent as c_sent, ct.due as c_due, ct.waits_copy as c_waits,
           ct.follows as c_follows, ct.old as c_old,
           lt.n as late_n, lt.d_min as late_min, lt.d_max as late_max
      from rk
      left join row_gap g on g.key = rk.key
      left join row_sheets rs on rs.key = rk.key
      left join row_copies rc on rc.key = rk.key
      left join row_pages rp on rp.key = rk.key
      left join why w on w.folder = rc.why_folder
      left join row_city ct on ct.key = rk.key
      left join late lt on lt.key = rk.key
  ),
  y as (
    select f.key, f.manifest_ids, f.test, f.sheets,
      -- PAPERS
      case
        when (f.has_gap and not f.noted and not f.record) or f.n_page > 0 then
          jsonb_build_object('s', 'bad',
            'code', case when f.has_gap and not f.noted and not f.record then 'missing' else 'page_missing' end,
            't', 'Missing Docs',
            'd', concat_ws('. ',
                   case when f.has_gap and not f.noted and not f.record and f.n_receipt > 0
                        then 'The receipt photo, for ' || f.n_receipt || case when f.n_receipt = 1 then ' client' else ' clients' end end,
                   case when f.has_gap and not f.noted and not f.record and f.n_address > 0
                        then case when f.is_yellow and not f.has_scan then 'The visit form' else 'The address sheet' end
                             || ', for ' || f.n_address || case when f.n_address = 1 then ' client' else ' clients' end end,
                   case when f.has_gap and not f.noted and not f.record and f.n_number > 0
                        then 'The manifest number, for ' || f.n_number || case when f.n_number = 1 then ' client' else ' clients' end end,
                   case when f.has_gap and not f.noted and not f.record and f.n_date > 0
                        then 'The dump date, for ' || f.n_date || case when f.n_date = 1 then ' client' else ' clients' end end,
                   case when f.has_gap and not f.noted and not f.record and f.n_receipt + f.n_address + f.n_number + f.n_date = 0
                        then 'A field is missing' end,
                   case when f.n_page > 0
                        then case when cardinality(f.pages) = 1 then 'Page ' else 'Pages ' end || array_to_string(f.pages, ', ')
                             || ' of the address sheet. ' || f.n_page
                             || case when f.n_page = 1 then ' client has no copy' else ' clients have no copy' end end),
            'clients', case when f.has_gap and not f.noted and not f.record then f.n else f.n_page end,
            'group', 'Add a document')
        when f.noted then
          jsonb_build_object('s', 'na', 'code', 'noted',
            't', case when f.n_receipt > 0 and f.n_address + f.n_number + f.n_date = 0 then 'Receipt missing, noted'
                      when f.n_address > 0 and f.n_receipt + f.n_number + f.n_date = 0 then 'Address sheet missing, noted'
                      else 'Papers missing, noted' end,
            'd', 'A note on the manifest explains it')
        when f.record then
          jsonb_build_object('s', 'na', 'code', 'record', 't', 'Kept for the record',
            'd', 'A ' || to_char(f.dump_date, 'YYYY') || ' ticket'
                 || case when f.n_receipt > 0 and f.n_address > 0 then ' with no scan' else ', entered for the record only' end)
        else
          jsonb_build_object('s', 'ok', 'code', 'on_file', 't', 'Papers on file', 'd', 'The manifest and the receipt photo')
      end as papers,
      -- STAMPS: the sheet's own state
      case
        when not f.has_sheet then
          jsonb_build_object('s', 'na', 'code', 'none', 't', 'Nothing to stamp',
            'd', case when f.is_yellow then 'One form per visit' else 'No address sheet on this ticket' end)
        when f.any_open then
          jsonb_build_object('s', 'warn', 'code', case when f.open_placed > 0 then 'in_progress' else 'not_started' end,
            't', 'Stamps to place', 'd', f.open_placed || ' of ' || f.open_total || ' placed',
            'placed', f.open_placed, 'total', f.open_total, 'group', 'Address sheet')
        when f.all_skipped then
          jsonb_build_object('s', 'na', 'code', 'skipped', 't', 'Skipped',
            'd', case f.skip_reason
                   when 'record_only' then 'Old visit, entered for the record only'
                   when 'no_sheet' then 'No paper sheet was filled for this visit'
                   when 'sheet_lost' then 'The paper sheet is lost'
                   when 'handled_elsewhere' then 'Handled outside the app'
                   else 'Other' end)
        else
          jsonb_build_object('s', 'ok', 'code', 'completed', 't', 'Address sheet completed',
            'd', f.placed || ' of ' || f.total || case when f.total = 1 then ' stamp placed' else ' stamps placed' end,
            'placed', f.placed, 'total', f.total)
      end as stamps,
      -- THE CLIENT COPIES: a second fact, only on a completed sheet
      case
        when not f.has_sheet or f.any_open or f.all_skipped then null
        when f.n_shared > 0 then
          jsonb_build_object('s', 'bad', 'code', 'shared_line',
            't', f.n_shared || ' clients share one printed line',
            'd', case when f.n_shared = 2 then 'Both' else 'All ' || f.n_shared end || ' held back'
                 || coalesce(' since ' || to_char(f.shared_since at time zone 'America/New_York', 'Mon FMDD'), ''),
            'clients', f.n_shared, 'since', (f.shared_since at time zone 'America/New_York')::date, 'group', 'Address sheet')
        when f.n_not_made > 0 then
          jsonb_build_object('s', 'bad', 'code', 'not_made',
            't', case when f.n_not_made = 1 then '1 client has no copy' else f.n_not_made || ' clients have no copy' end,
            'd', f.why, 'clients', f.n_not_made, 'group', 'Address sheet')
        when f.n_again > 0 then
          jsonb_build_object('s', 'warn', 'code', 'stamp_again',
            't', case when f.n_again = 1 then '1 stamp must be placed again' else f.n_again || ' stamps must be placed again' end,
            'd', case when f.n_again = 1 then '1 client has no copy' else f.n_again || ' clients have no copy' end,
            'clients', f.n_again, 'group', 'Address sheet')
        when f.n_unplaced > 0 then
          jsonb_build_object('s', 'warn', 'code', 'stamp_missing',
            't', case when f.n_unplaced = 1 then '1 stamp is not placed' else f.n_unplaced || ' stamps are not placed' end,
            'd', case when f.n_unplaced = 1 then '1 client has no copy' else f.n_unplaced || ' clients have no copy' end,
            'clients', f.n_unplaced, 'group', 'Address sheet')
        when f.n_making > 0 then
          jsonb_build_object('s', 'na', 'code', 'making', 't', 'Copies being made',
            'd', (f.n_with_visit - f.n_no_copy) || ' of ' || f.n_with_visit, 'clients', f.n_making)
      end as copies,
      -- THE CITY
      case
        when not f.has_city then
          jsonb_build_object('s', 'na', 'code', 'none', 't', 'No city program', 'd', 'Nothing to send', 'total', 0, 'sent', 0, 'due', 0)
        when f.c_due > 0 then
          jsonb_build_object('s', 'warn', 'code', 'due', 't', 'Not sent to city',
            'd', f.c_due || ' of ' || f.c_total || case when f.c_total = 1 then ' client' else ' clients' end || '. Send it from the three dots',
            'total', f.c_total, 'sent', f.c_sent, 'due', f.c_due, 'group', 'Send to city')
        when f.c_sent >= f.c_total then
          jsonb_build_object('s', 'ok', 'code', 'sent', 't', 'Sent to city',
            'd', f.c_sent || ' of ' || f.c_total || case when f.c_total = 1 then ' client' else ' clients' end,
            'total', f.c_total, 'sent', f.c_sent, 'due', 0)
        when f.c_follows > 0 then
          jsonb_build_object('s', 'na', 'code', 'follows', 't', 'Not sent to city',
            'd', 'The report went without the manifest. The automatic email follows',
            'total', f.c_total, 'sent', f.c_sent, 'due', 0)
        when f.c_waits > 0 then
          jsonb_build_object('s', 'na', 'code', 'waits_copy', 't', 'Not sent to city',
            'd', 'It waits for the client copy', 'total', f.c_total, 'sent', f.c_sent, 'due', 0)
        when f.c_old > 0 then
          jsonb_build_object('s', 'na', 'code', 'before_go_live', 't', 'Not sent to city (before Sep 15)',
            'd', 'Before the city email went live', 'total', f.c_total, 'sent', f.c_sent, 'due', 0)
        else
          jsonb_build_object('s', 'na', 'code', 'not_due', 't', 'Nothing due to the city',
            'd', 'No visit on this ticket needs a city copy', 'total', f.c_total, 'sent', f.c_sent, 'due', 0)
      end as city,
      -- A VISIT DATED AFTER THE DUMP
      case when f.late_n > 0 then
        jsonb_build_object('s', 'warn', 'code', 'after_dump',
          't', case when f.late_n = 1 then '1 visit is dated after the dump' else f.late_n || ' visits are dated after the dump' end,
          'd', case when f.late_min = f.late_max then f.late_max || ' days after' else f.late_min || ' to ' || f.late_max || ' days after' end,
          'visits', f.late_n, 'days', f.late_max, 'group', 'Check a visit')
      end as visit
    from f
  ),
  z as (
    select y.*,
           case when 'bad' in (y.papers ->> 's', y.stamps ->> 's', coalesce(y.copies ->> 's', ''), y.city ->> 's') then 'bad'
                when 'warn' in (y.papers ->> 's', y.stamps ->> 's', coalesce(y.copies ->> 's', ''), y.city ->> 's', coalesce(y.visit ->> 's', '')) then 'warn'
                else 'ok' end as worst
      from y
  )
  select coalesce(jsonb_object_agg(z.key, jsonb_strip_nulls(jsonb_build_object(
           'key', z.key,
           'manifest_ids', to_jsonb(z.manifest_ids),
           'needs', z.worst <> 'ok',
           'worst', z.worst,
           'test', z.test,
           'papers', z.papers,
           'stamps', z.stamps,
           'copies', z.copies,
           'city', z.city,
           'visit', z.visit,
           'sheets', z.sheets))), '{}'::jsonb)
    into v_out
    from z;

  return v_out;
end
$function$;

drop function derm.fn_manifest_row_states_core();

notify pgrst, 'reload schema';

do $verify$
begin
  if md5(replace(pg_get_functiondef('derm.manifest_row_states()'::regprocedure), chr(13), '')) <> '17b8b7193288cc5a1ce5ee87f0b118eb' then
    raise exception 'verify_fail: derm.manifest_row_states() is not the 2026-11-13_0148 body';
  end if;
  if to_regprocedure('derm.fn_manifest_row_states_core()') is not null or to_regprocedure('derm.manifest_row_states_for_client(bigint)') is not null then
    raise exception 'verify_fail: the core or the per-client read is still there';
  end if;
  if has_function_privilege('anon', 'derm.manifest_row_states()', 'execute') or not has_function_privilege('authenticated', 'derm.manifest_row_states()', 'execute') then
    raise exception 'verify_fail: the grants of derm.manifest_row_states() are not what they were';
  end if;
  raise notice 'verify ok: derm.manifest_row_states() is the 2026-11-13_0148 body again';
end $verify$;

COMMIT;
