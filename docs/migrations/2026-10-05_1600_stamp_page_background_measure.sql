-- Stamp Studio: every page of a sheet not completed is measured in the background
--
-- Fred, 2026-10-05: "yes measure in the background" (asked: the in-app Re-measure is gone, so a new
-- handwritten page has no machine measurement and derm.save_page_bands' independent check, "a drawn
-- row may not cross a measured line between two clients", has nothing to check against).
--
-- THE PIECES
-- * derm.page_reference_attempts: one row per (folder, page), the attempt ledger. Three attempts per
--   image; a replaced image (new url or etag) gets a fresh budget. Rule 8: OPT-OUT, a machine ledger
--   (the measurement itself lands in page_rule_scans / page_row_rules through record_page_rules).
-- * derm.v_page_reference_backlog: every page of every sheet in derm.v_stamp_sheets that is NOT
--   completed, whose CURRENT image has no runlen-v2 or template-v1 scan yet (any grade: a page the
--   detector cannot read is recorded FAILED once and not retried; a replaced scan is measured again).
--   Carries the page's Limit, which the measurement uses as its window, exactly as the app did.
-- * public.fn_request_page_reference_measure(): the cron wrapper. No HTTP when the backlog is empty.
--   Two pages per run, the attempt recorded BEFORE the request (a dead worker still uses its budget).
-- * derm.fn_page_reference_measured(folder, page, image_url, result, error): what edge fn
--   measure-page-reference hands back. Writes through derm.record_page_rules as
--   'runlen-v2-<ET date>' (the validator still judges; FAILED is recorded without lines), and updates
--   the ledger. runlen-v2 ranks BELOW human-v1 and template-v1, so a background measurement never
--   replaces lines a person or the generated-sheet finisher recorded. On a page nobody has drawn, it
--   is what Draw the bands opens with.
-- * pg_cron `page-reference-measure` '8-58/10 * * * *'.
-- * derm.save_page_bands now trusts only a measurement graded OK as its reference (measured: with no
--   window, 934861 p1 grades IRREGULAR and its labels disagree with the app's own measurement).
-- The pipeline (detectRules + classifyPage, shared modules) is proven equal to the app's own
-- measurements on 8 real scans: scripts/checks/page_reference_classifier.mjs.
-- Scope is sheets NOT completed on purpose: completed sheets are not being drawn on, and writing new
-- reference scans under hundreds of served pages would only add noise.
-- Only JPEG scans are measured (the server decodes JPEG only): 199 of 203 page images are JPEG and all
-- 22 since September; a PNG page is reported as an error and stops after three attempts.
-- At install every sheet is completed, so the backlog is empty and the cron makes no HTTP call; the
-- VERIFY reopens ticket-306915 inside rolled-back blocks. 10 pages lose the independent check by the
-- save_page_bands change (their best measurement is IRREGULAR or SPARSE).
-- Named _1600 so it sorts after _1545 (it replaces save_page_bands, which _1545 last replaced);
-- applied 2026-10-05 about 13:20 ET.
-- Rule 8: derm.page_reference_attempts OPTS OUT of audit (a machine retry ledger; the measurement
-- itself is recorded in page_rule_scans / page_row_rules).

begin;

create table derm.page_reference_attempts (
  dump_folder     text        not null,
  page            integer     not null,
  image_url       text        not null,
  source_etag     text,
  attempts        integer     not null default 0,
  first_attempt_at timestamptz not null default now(),
  last_attempt_at timestamptz not null default now(),
  last_outcome    text,
  last_reason     text,
  primary key (dump_folder, page)
);
comment on table derm.page_reference_attempts is
  'Background measuring of Stamp Studio pages (edge fn measure-page-reference): one row per page, attempts per current image. 2026-10-05.';
revoke all on derm.page_reference_attempts from public, anon, authenticated;
grant select, insert, update on derm.page_reference_attempts to service_role;

create view derm.v_page_reference_backlog as
with open_pages as (
  select s.dump_folder, s.white_manifest_number, p.page::integer as page, p.url as image_url
    from derm.v_stamp_sheets s
    cross join lateral unnest(s.page_image_urls) with ordinality as p(url, page)
   where not s.completed and p.url is not null
), cur as (
  select o.*, derm._img_etag(o.image_url) as source_etag,
         e.top_pct, e.bottom_pct
    from open_pages o
    left join derm.page_block_extents e on e.dump_folder = o.dump_folder and e.effective_page = o.page
)
select c.dump_folder, c.white_manifest_number, c.page, c.image_url, c.source_etag, c.top_pct, c.bottom_pct,
       case when a.dump_folder is null
              or a.image_url is distinct from c.image_url
              or a.source_etag is distinct from c.source_etag then 0
            else a.attempts end as attempts_on_this_image,
       a.last_outcome, a.last_reason, a.last_attempt_at
  from cur c
  left join derm.page_reference_attempts a on a.dump_folder = c.dump_folder and a.page = c.page
 where not exists (
   select 1 from derm.page_rule_scans sc
    where sc.dump_folder = c.dump_folder and sc.effective_page = c.page
      and (sc.source like 'runlen-v2-%' or sc.source like 'template-v1-%')
      and ((sc.source_etag is not null and sc.source_etag = c.source_etag)
           or (sc.source_etag is null and sc.source_url = c.image_url)));
comment on view derm.v_page_reference_backlog is
  'Pages of Stamp sheets not completed whose current scan has no machine measurement yet. 2026-10-05.';
revoke all on derm.v_page_reference_backlog from public, anon, authenticated;
grant select on derm.v_page_reference_backlog to service_role;

create function derm.fn_page_reference_measured(p_dump_folder text, p_page integer, p_image_url text,
                                                p_result jsonb, p_error text)
returns jsonb
language plpgsql
security definer
set search_path to 'derm', 'public'
as $function$
declare
  v_rec jsonb;
  v_outcome text;
begin
  if p_error is not null or p_result is null then
    update derm.page_reference_attempts
       set last_outcome = 'error', last_reason = left(coalesce(p_error, 'no result'), 300), last_attempt_at = now()
     where dump_folder = p_dump_folder and page = p_page;
    return jsonb_build_object('wrote', false, 'outcome', 'error');
  end if;

  v_rec := derm.record_page_rules(
    p_dump_folder, p_page,
    'runlen-v2-' || to_char(now() at time zone 'America/New_York', 'YYYY-MM-DD'),
    p_image_url,
    coalesce(p_result->'rules', '[]'::jsonb),
    jsonb_build_object('grade', coalesce(p_result->>'grade', 'FAILED'),
                       'detail', 'background measurement: ' || coalesce(p_result->>'detail', ''),
                       'image_w', p_result->'image_w', 'image_h', p_result->'image_h', 'skew', p_result->'skew'),
    false);

  v_outcome := case when coalesce((v_rec->>'wrote')::boolean, false) then 'measured ' || coalesce(v_rec->>'grade', '')
                    else 'not written: ' || coalesce(v_rec->>'skipped', v_rec->>'grade', '') end;
  update derm.page_reference_attempts
     set last_outcome = v_outcome, last_reason = left(coalesce(v_rec->>'detail', ''), 300), last_attempt_at = now()
   where dump_folder = p_dump_folder and page = p_page;
  return v_rec || jsonb_build_object('outcome', v_outcome);
end
$function$;
revoke all on function derm.fn_page_reference_measured(text, integer, text, jsonb, text) from public, anon, authenticated;
grant execute on function derm.fn_page_reference_measured(text, integer, text, jsonb, text) to service_role;

create function public.fn_request_page_reference_measure()
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_key text; t record;
begin
  if not exists (select 1 from derm.v_page_reference_backlog where attempts_on_this_image < 3) then
    return;   -- nothing to measure: no HTTP call
  end if;
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'edge_invoke_service_key';
  if v_key is null then
    raise warning 'edge_invoke_service_key vault secret missing; skipping the background page measuring';
    return;
  end if;
  for t in select * from derm.v_page_reference_backlog where attempts_on_this_image < 3
            order by dump_folder, page limit 2 loop
    insert into derm.page_reference_attempts (dump_folder, page, image_url, source_etag, attempts, last_outcome)
    values (t.dump_folder, t.page, t.image_url, t.source_etag, 1, 'requested')
    on conflict (dump_folder, page) do update
       set attempts = case when derm.page_reference_attempts.image_url is distinct from excluded.image_url
                             or derm.page_reference_attempts.source_etag is distinct from excluded.source_etag
                           then 1 else derm.page_reference_attempts.attempts + 1 end,
           image_url = excluded.image_url, source_etag = excluded.source_etag,
           last_outcome = 'requested', last_attempt_at = now();
    perform net.http_post(
      url := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/measure-page-reference',
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
      body := jsonb_build_object('dump_folder', t.dump_folder, 'page', t.page, 'image_url', t.image_url,
                                 'top_pct', t.top_pct, 'bottom_pct', t.bottom_pct),
      timeout_milliseconds := 120000);
  end loop;
end
$function$;
revoke all on function public.fn_request_page_reference_measure() from public, anon, authenticated;

select cron.schedule('page-reference-measure', '8-58/10 * * * *', 'select public.fn_request_page_reference_measure()');


-- save_page_bands: trust only an OK reference (one line changed from the live body)
CREATE OR REPLACE FUNCTION derm.save_page_bands(p_dump_folder text, p_effective_page integer, p_source_url text, p_rules jsonb, p_meta jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
declare
  v_src     text := 'human-v1-' || to_char(now() at time zone 'America/New_York', 'YYYY-MM-DD');
  v_rec     jsonb;
  v_rows    integer;
  v_bad     text;
  v_cards   integer;
  v_ext     jsonb;
  v_msg     text;
  v_actor   text := derm._actor('stamp-studio');
  v_wm      text;
  v_npages  integer;
  v_etag    text;
  v_ref     text;
  -- 0.5pp, not the 0.35 of G9: measured 2026-10-05, a correct hand line on 836057 p1 sits 0.365pp from the
  -- template line (0.322 from the detector line). The cases this check exists for are 1pp and more off.
  v_tol     constant numeric := 0.5;
  v_top     numeric;
  v_bot     numeric;
begin
  perform derm._require_stamp_key();

  if p_dump_folder is null or p_effective_page is null then
    raise exception 'Something went wrong identifying this page. Reload the sheet and try again.'
      using detail = 'blocker=bad_arguments';
  end if;

  select r.white_manifest_number into v_wm from derm.address_row_map r
   where r.dump_folder = p_dump_folder and r.white_manifest_number is not null limit 1;
  if v_wm is not null then
    v_npages := coalesce(array_length(derm.ticket_page_images(v_wm), 1), 0);
    if p_effective_page < 1 or p_effective_page > v_npages then
      raise exception 'This page is no longer on the sheet. Reload the sheet.'
        using detail = format('blocker=no_such_page folder=%s page=%s pages=%s', p_dump_folder, p_effective_page, v_npages);
    end if;
  end if;

  v_rec := derm.record_page_rules(p_dump_folder, p_effective_page, v_src, p_source_url, p_rules,
                                  coalesce(p_meta, '{}'::jsonb) || '{"grade":"OK"}'::jsonb, false);
  if not coalesce((v_rec->>'wrote')::boolean, false) then
    raise exception '%', coalesce(nullif(v_rec->>'hint', ''),
                                  'These lines cannot be saved. Draw the two Limit bands and a client band on every printed line between them.')
      using detail = 'blocker=lines_refused ' || coalesce(v_rec->>'reject', v_rec->>'detail', v_rec->>'skipped', '');
  end if;

  select count(*), min(p.y0_pct), max(p.y1_pct) into v_rows, v_top, v_bot
    from derm.fn_page_slots_preview(p_dump_folder, p_effective_page) p;
  if v_rows < 1 then
    raise exception 'Draw both Limit bands, the top and the bottom of Section B.'
      using detail = 'blocker=no_rows_formed';
  end if;

  -- the independent check: the machine measurement of THIS scan, when there is one
  v_etag := derm._img_etag(p_source_url);
  select s.source into v_ref
    from derm.page_rule_scans s
   where s.dump_folder = p_dump_folder and s.effective_page = p_effective_page
     and (s.source like 'runlen-v2-%' or s.source like 'template-v1-%')
     -- 2026-10-05 (background measuring): only a measurement graded OK is trusted as the reference; an
     -- IRREGULAR or SPARSE one can mislabel lines (934861 p1 measured with no window)
     and s.grade = 'OK'
     and ((s.source_etag is not null and s.source_etag = v_etag)
          or (s.source_etag is null and s.source_url = p_source_url))
   order by s.scanned_at desc
   limit 1;
  if v_ref is not null then
    if exists (select 1
                 from derm.fn_page_slots_preview(p_dump_folder, p_effective_page) p
                 join derm.page_row_rules x on x.dump_folder = p_dump_folder and x.effective_page = p_effective_page
                                           and x.source = v_ref and x.kind = 'boundary'
                where x.rule_pct > p.y0_pct + v_tol and x.rule_pct < p.y1_pct - v_tol
                  -- the machine's first and last line are the edges of the list (or the form's
                  -- header/footer bar): a Limit drawn a little past them only reaches into the form
                  -- itself, never into another client's row (836057 p1, 0.4pp below the last line)
                  and x.rule_pct > (select min(y.rule_pct) from derm.page_row_rules y where y.dump_folder = p_dump_folder
                                      and y.effective_page = p_effective_page and y.source = v_ref and y.kind = 'boundary')
                  and x.rule_pct < (select max(y.rule_pct) from derm.page_row_rules y where y.dump_folder = p_dump_folder
                                      and y.effective_page = p_effective_page and y.source = v_ref and y.kind = 'boundary')) then
      raise exception 'A row you drew crosses a printed line between two clients. Put each band on a printed line: on the line between two clients, not inside a row.'
        using detail = format('blocker=row_crosses_printed_line folder=%s page=%s reference=%s', p_dump_folder, p_effective_page, v_ref);
    end if;
    -- NO Limit-coverage check against the reference: a machine scan can count the form's footer bar
    -- as a row line (measured on 836624 p1: 64.956), which would refuse a correct drawing. A Limit
    -- that leaves a printed row out is covered instead by the never-narrow rule in
    -- _write_page_extent_from_slots on every page that already has a blackout area.
  end if;

  -- stamps WITHOUT a band take the row their point sits in; they must sit alone inside one
  create temp table if not exists _spb_cards (id bigint, k integer, banded boolean) on commit drop;
  truncate _spb_cards;
  insert into _spb_cards
  select r.id,
         (select p.slot_index from derm.fn_page_slots_preview(p_dump_folder, p_effective_page) p
           where r.stamp_y_pct >= p.y0_pct and r.stamp_y_pct <= p.y1_pct
           order by p.slot_index desc limit 1),
         (r.band_y0_pct is not null and r.band_y1_pct is not null)
    from derm.address_row_map r
   where r.dump_folder = p_dump_folder
     and coalesce(r.stamp_page, r.page) = p_effective_page
     and r.stamp_y_pct is not null and r.stamp_placed_at is not null;

  select string_agg(derm._card_label(id), ', ' order by id) into v_bad from _spb_cards where not banded and k is null;
  if v_bad is not null then
    raise exception 'The stamp of % is outside the new rows. Move it into its row, or remove it, then save the bands again.', v_bad
      using detail = 'blocker=stamp_outside_rows';
  end if;
  select string_agg(labels, '; ') into v_bad
    from (select string_agg(derm._card_label(c.id), ' and ' order by c.id) as labels
            from _spb_cards c
           where c.k is not null
             and (not c.banded or exists (select 1 from _spb_cards o where o.k = c.k and not o.banded))
           group by c.k having count(*) > 1 and bool_or(not c.banded)) d;
  if v_bad is not null then
    raise exception '% are in the same row. Each client needs its own row: move one stamp, then save the bands again.', v_bad
      using detail = 'blocker=two_stamps_one_row';
  end if;

  delete from derm.page_slots where dump_folder = p_dump_folder and effective_page = p_effective_page;
  insert into derm.page_slots (dump_folder, effective_page, slot_index, y0_pct, y1_pct, source, set_by)
  select p_dump_folder, p_effective_page, p.slot_index, p.y0_pct, p.y1_pct, p.source, v_actor
    from derm.fn_page_slots_preview(p_dump_folder, p_effective_page) p;

  -- only unbanded stamps are banded; a banded stamp keeps its band and carries a row number only
  -- when that band IS the row
  update derm.address_row_map r
     set slot_index = c.k,
         band_y0_pct = round(s.y0_pct, 3), band_y1_pct = round(s.y1_pct, 3),
         band_source = 'slot', band_set_at = now(), band_set_by = v_actor
    from _spb_cards c
    join derm.page_slots s on s.dump_folder = p_dump_folder and s.effective_page = p_effective_page and s.slot_index = c.k
   where r.id = c.id and not c.banded;
  update derm.address_row_map r
     set slot_index = case when round(s.y0_pct, 3) = r.band_y0_pct and round(s.y1_pct, 3) = r.band_y1_pct then c.k end
    from _spb_cards c
    left join derm.page_slots s on s.dump_folder = p_dump_folder and s.effective_page = p_effective_page
                               and s.slot_index = c.k
   where r.id = c.id and c.banded
     and r.slot_index is distinct from (case when round(s.y0_pct, 3) = r.band_y0_pct and round(s.y1_pct, 3) = r.band_y1_pct
                                             then c.k end);
  select count(*) into v_cards from _spb_cards;

  update derm.address_row_map r set slot_index = null
   where r.dump_folder = p_dump_folder and coalesce(r.stamp_page, r.page) = p_effective_page
     and r.slot_index is not null and r.stamp_y_pct is null;

  begin
    v_ext := derm._write_page_extent_from_slots(p_dump_folder, p_effective_page);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    raise exception '%', coalesce(derm._geometry_refusal_sentence(v_msg), 'These bands cannot be saved.')
      using detail = 'blocker=geometry_refused ' || v_msg;
  end;

  return jsonb_build_object('rows', v_rows, 'stamps_in_rows', v_cards, 'grade', v_rec->>'grade',
                            'lines', v_rec->'rules_written', 'checked_against', v_ref, 'extent', v_ext);
end
$function$
;


-- VERIFY. Every sheet is completed at install (0 open pages, so the backlog is empty and the cron
-- makes no HTTP call). The probes therefore reopen a completed fixture, ticket-306915 (2 pages, each
-- with an OK runlen-v2 scan of its current image), inside rolled-back sub-blocks.
do $verify$
declare n int; v jsonb; t text; v_before text; v_after text; v_rules jsonb; v_url text;
begin
  -- grants: nothing for staff or anon (Supabase default privileges grant BY NAME, so read the ACL)
  select relacl::text into t from pg_class where oid = 'derm.page_reference_attempts'::regclass;
  if t like '%authenticated%' or t like '%anon%' then raise exception 'VERIFY: ledger ACL %', t; end if;
  select relacl::text into t from pg_class where oid = 'derm.v_page_reference_backlog'::regclass;
  if t like '%authenticated%' or t like '%anon%' then raise exception 'VERIFY: backlog ACL %', t; end if;
  if has_function_privilege('authenticated', 'derm.fn_page_reference_measured(text,integer,text,jsonb,text)', 'EXECUTE')
     or has_function_privilege('anon', 'derm.fn_page_reference_measured(text,integer,text,jsonb,text)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.fn_request_page_reference_measure()', 'EXECUTE')
     or has_function_privilege('anon', 'public.fn_request_page_reference_measure()', 'EXECUTE') then
    raise exception 'VERIFY: a background-measuring function is executable by staff or anon'; end if;
  if not has_function_privilege('service_role', 'derm.fn_page_reference_measured(text,integer,text,jsonb,text)', 'EXECUTE') then
    raise exception 'VERIFY: service_role cannot report a measurement'; end if;
  if position('s.grade = ''OK''' in pg_get_functiondef('derm.save_page_bands(text,integer,text,jsonb,jsonb)'::regprocedure)) = 0
     or position('s.grade <> ''FAILED''' in pg_get_functiondef('derm.save_page_bands(text,integer,text,jsonb,jsonb)'::regprocedure)) > 0 then
    raise exception 'VERIFY: save_page_bands does not require an OK reference'; end if;
  if not exists (select 1 from cron.job where jobname = 'page-reference-measure' and schedule = '8-58/10 * * * *' and active) then
    raise exception 'VERIFY: cron job missing'; end if;

  -- 1. the backlog: a measured page is not listed; a replaced scan is; three attempts are the budget
  begin
    update derm.stamp_sheet_status set completed = false where dump_folder = 'ticket-306915';
    select count(*) into n from derm.v_page_reference_backlog where dump_folder = 'ticket-306915';
    if n <> 0 then raise exception 'VERIFY backlog: both pages are measured, yet % listed', n; end if;
    update derm.page_rule_scans set source_etag = 'x-not-this-image'
     where dump_folder = 'ticket-306915' and effective_page = 2 and source like 'runlen-v2-%';
    select count(*) into n from derm.v_page_reference_backlog
     where dump_folder = 'ticket-306915' and page = 2 and attempts_on_this_image = 0;
    if n <> 1 then raise exception 'VERIFY backlog: a page whose scan changed is not listed (%)', n; end if;
    -- the wrapper records the attempt before asking (the request is queued, and rolled back here)
    perform public.fn_request_page_reference_measure();
    select attempts, last_outcome into n, t from derm.page_reference_attempts
     where dump_folder = 'ticket-306915' and page = 2;
    if n is distinct from 1 or t is distinct from 'requested' then
      raise exception 'VERIFY wrapper: attempt not recorded (% %)', n, t; end if;
    update derm.page_reference_attempts set attempts = 3 where dump_folder = 'ticket-306915' and page = 2;
    select attempts_on_this_image into n from derm.v_page_reference_backlog where dump_folder = 'ticket-306915' and page = 2;
    if n <> 3 then raise exception 'VERIFY budget: % attempts shown', n; end if;
    perform public.fn_request_page_reference_measure();
    select attempts into n from derm.page_reference_attempts where dump_folder = 'ticket-306915' and page = 2;
    if n <> 3 then raise exception 'VERIFY budget: a spent page was asked again (%)', n; end if;
    update derm.page_reference_attempts set source_etag = 'an-older-image' where dump_folder = 'ticket-306915' and page = 2;
    select attempts_on_this_image into n from derm.v_page_reference_backlog where dump_folder = 'ticket-306915' and page = 2;
    if n <> 0 then raise exception 'VERIFY budget: a replaced image did not get a fresh budget (%)', n; end if;
    raise exception 'rollback-probe';
  exception when raise_exception then
    if sqlerrm <> 'rollback-probe' then raise; end if;
  end;

  -- 2. the recorder: an error updates the ledger; a result is written as runlen-v2 BELOW the served lines
  begin
    insert into derm.page_reference_attempts (dump_folder, page, image_url, attempts) values ('ticket-306915', 1, 'x', 1);
    v := derm.fn_page_reference_measured('ticket-306915', 1, 'x', null, 'probe error');
    if v->>'outcome' <> 'error' then raise exception 'VERIFY recorder error path: %', v; end if;
    select last_outcome into t from derm.page_reference_attempts where dump_folder = 'ticket-306915' and page = 1;
    if t <> 'error' then raise exception 'VERIFY ledger not updated on error: %', t; end if;

    select source_url into v_url from derm.page_rule_scans
     where dump_folder = 'ticket-306915' and effective_page = 1 and source = 'runlen-v2-2026-08-21';
    select jsonb_agg(jsonb_build_object('pct', rule_pct, 'kind', kind, 'run', run_frac, 'ink', ink_frac) order by rule_pct)
      into v_rules from derm.page_row_rules
     where dump_folder = 'ticket-306915' and effective_page = 1 and source = 'runlen-v2-2026-08-21';
    -- a person's lines on this page (rank above runlen-v2), so the served set must not move
    insert into derm.page_rule_scans (dump_folder, effective_page, source_url, n_rules, n_boundaries, grade, detail, source, scanned_at, source_etag)
    values ('ticket-306915', 1, v_url, 0, 0, 'OK', 'probe', 'human-v1-2000-01-01', now() - interval '1 day', derm._img_etag(v_url));
    insert into derm.page_row_rules (dump_folder, effective_page, rule_pct, ink_frac, source, detected_at, run_frac, kind, kind_confirmed)
    select dump_folder, effective_page, rule_pct, ink_frac, 'human-v1-2000-01-01', now(), run_frac, kind, true
      from derm.page_row_rules where dump_folder = 'ticket-306915' and effective_page = 1 and source = 'runlen-v2-2026-08-21';
    select max(source) into v_before from derm.v_page_printed_rules where dump_folder = 'ticket-306915' and effective_page = 1;
    if v_before <> 'human-v1-2000-01-01' then raise exception 'VERIFY setup: served %', v_before; end if;

    v := derm.fn_page_reference_measured('ticket-306915', 1, v_url,
           jsonb_build_object('grade', 'OK', 'detail', 'probe', 'rules', v_rules, 'image_w', 1700, 'image_h', 2200, 'skew', 0), null);
    if v->>'outcome' <> 'measured OK' then raise exception 'VERIFY recorder result path: %', v; end if;
    if not exists (select 1 from derm.page_rule_scans
                    where dump_folder = 'ticket-306915' and effective_page = 1 and grade = 'OK'
                      and source = 'runlen-v2-' || to_char(now() at time zone 'America/New_York', 'YYYY-MM-DD')
                      and detail like 'background measurement: %') then
      raise exception 'VERIFY recorder: no runlen-v2 scan written'; end if;
    select max(source) into v_after from derm.v_page_printed_rules where dump_folder = 'ticket-306915' and effective_page = 1;
    if v_after <> v_before then raise exception 'VERIFY rank: a background measurement replaced the served lines (% -> %)', v_before, v_after; end if;
    select last_outcome into t from derm.page_reference_attempts where dump_folder = 'ticket-306915' and page = 1;
    if t <> 'measured OK' then raise exception 'VERIFY ledger after a result: %', t; end if;
    raise exception 'rollback-probe';
  exception when raise_exception then
    if sqlerrm <> 'rollback-probe' then raise; end if;
  end;
end $verify$;

commit;
