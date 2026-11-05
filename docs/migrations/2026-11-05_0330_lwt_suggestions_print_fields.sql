-- 2026-11-05_0330 ET · Monthly Report page: a stop picked from a visit prints exactly as the bot prints it (Trello EOnFKqSK, #173)
--
-- Found while building the page, against the real feed. A ticket nobody logged is built from visits the person picks, and
-- that row goes on the county's form. The bot prints a client as "street, city, ST zip" (monthly_fetch.compose_address) with
-- derm.v_lwt_monthly_rows' cleaned name. derm.lwt_stop_suggestions returned the raw name, the street and the city, no state
-- and no ZIP, so a picked stop would have printed differently from every other row on the page.
--
-- This adds form_name and form_address to each suggested visit, from two small functions. Nothing else in the reply moves.
-- The view keeps its own copy of the state rule on purpose (a change there rewrites a view six things read): the VERIFY below
-- compares the two on every row the view has, so they cannot drift unnoticed in this migration; scripts/lwt-monthly/run.mjs
-- does not cover this, the page's check against the feed does (docs in the spec).
--
-- Rule 8: no table. Rollback: 2026-11-05_0330_lwt_suggestions_print_fields_rollback.sql

BEGIN;

SET LOCAL lock_timeout = '3s';

create or replace function derm.fn_lwt_form_name(p_name text)
 returns text
 language sql
 immutable
 set search_path to ''
as $function$
  select replace(replace(replace(replace(replace(replace(replace(p_name,
    chr(8217), ''''), chr(8216), ''''), chr(8220), '"'), chr(8221), '"'), chr(8211), '-'), chr(8212), '-'), chr(160), ' ')
$function$;

-- "street, city, ST zip". A state that is not two letters is withheld, as the bot withholds it: an address is never guessed.
create or replace function derm.fn_lwt_form_address(p_address text, p_city text, p_state text, p_zip text)
 returns text
 language sql
 immutable
 set search_path to ''
as $function$
  with s as (select derm.fn_normalize_state_input(p_state) st),
  c as (
    select case
      when p_state is null then null
      when upper(translate(st, chr(201) || chr(233), 'Ee')) = any (array['FL', 'FLORIDA']) then 'FL'
      when upper(translate(st, chr(201) || chr(233), 'Ee')) = any (array['CA', 'CALIFORNIA']) then 'CA'
      when upper(translate(st, chr(201) || chr(233), 'Ee')) = any (array['NY', 'NEW YORK']) then 'NY'
      when upper(translate(st, chr(201) || chr(233), 'Ee')) = any (array['QC', 'QUEBEC']) then 'QC'
      when st ~ '^[A-Za-z]{2}$' then upper(st)
      else null end state
    from s
  )
  select array_to_string(array_remove(array[
           nullif(btrim(p_address), ''),
           nullif(btrim(p_city), ''),
           nullif(btrim(concat_ws(' ', c.state, nullif(btrim(p_zip), ''))), '')], null), ', ')
    from c
$function$;

revoke all on function derm.fn_lwt_form_name(text) from public, anon, authenticated, service_role;
revoke all on function derm.fn_lwt_form_address(text, text, text, text) from public, anon, authenticated, service_role;

do $splice$
declare
  v_def text := pg_get_functiondef('derm.lwt_stop_suggestions(date,bigint)'::regprocedure);
  a1 text := $a$select v.id visit_id, v.visit_date, v.vehicle_id, v.title, c.client_code, c.name client_name,$a$;
  a2 text := $a$'visit_id', visit_id, 'visit_date', visit_date, 'client_code', client_code, 'client_name', client_name,$a$;
begin
  if md5(v_def) <> '40ac337ca82b40b2e1ff69e4cc8bde06' then raise exception 'derm.lwt_stop_suggestions changed; re-splice from the live body'; end if;
  if (length(v_def) - length(replace(v_def, a1, ''))) / length(a1) <> 1 then raise exception 'anchor 1 not found once'; end if;
  if (length(v_def) - length(replace(v_def, a2, ''))) / length(a2) <> 1 then raise exception 'anchor 2 not found once'; end if;
  execute replace(replace(v_def, a1, a1
      || E'\n           derm.fn_lwt_form_name(c.name) form_name,'
      || E'\n           derm.fn_lwt_form_address(coalesce(p.address, pp.address), coalesce(p.city, pp.city), coalesce(p.state, pp.state), coalesce(p.zip, pp.zip)) form_address,'),
    a2, a2 || E'\n           ''form_name'', form_name, ''form_address'', form_address,');
end $splice$;

-- VERIFY ----------------------------------------------------------------------------------------------------------
do $verify$
declare n bigint; bad bigint; v jsonb;
begin
  -- The rule on its own, with values that must and must not print.
  if derm.fn_lwt_form_address('1 A St', 'Miami', 'Florida', '33101') <> '1 A St, Miami, FL 33101' then raise exception 'VERIFY: full address'; end if;
  if derm.fn_lwt_form_address('1 A St', 'Miami', 'fl', null) <> '1 A St, Miami, FL' then raise exception 'VERIFY: no zip'; end if;
  if derm.fn_lwt_form_address('1 A St', 'Miami', null, '33101') <> '1 A St, Miami, 33101' then raise exception 'VERIFY: no state'; end if;
  if derm.fn_lwt_form_address('1 A St', 'Miami', 'Atlantis', '33101') <> '1 A St, Miami, 33101' then raise exception 'VERIFY: a bad state must be withheld'; end if;
  if derm.fn_lwt_form_address(null, null, null, null) <> '' then raise exception 'VERIFY: empty'; end if;
  if derm.fn_lwt_form_name('Joe' || chr(8217) || 's' || chr(160) || 'Grill') <> 'Joe''s Grill' then raise exception 'VERIFY: name'; end if;

  -- Against every row the bot's own view holds: the same name, the same state.
  select count(*), count(*) filter (where
           derm.fn_lwt_form_name(c.name) is distinct from r.client_name
           or derm.fn_lwt_form_address(p.address, p.city, p.state, p.zip) is distinct from derm.fn_lwt_form_address(r.address, r.city, r.state, r.zip))
    into n, bad
    from derm.v_lwt_monthly_rows r
    join public.visits vv on vv.id = r.visit_id
    join public.clients c on c.id = vv.client_id
    join public.properties p on p.id = vv.property_id;
  if n < 100 then raise exception 'VERIFY: the control read too few rows (%)', n; end if;
  if bad <> 0 then raise exception 'VERIFY: % of % rows differ from the view', bad, n; end if;

  -- The reply itself carries the fields, on a day with real visits.
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  v := derm.lwt_stop_suggestions('2026-10-16', 1);
  if jsonb_array_length(v -> 'visits') = 0 then raise exception 'VERIFY: no visits came back, so nothing was tested'; end if;
  if exists (select 1 from jsonb_array_elements(v -> 'visits') e where not (e ? 'form_name' and e ? 'form_address')) then raise exception 'VERIFY: a visit without its print fields'; end if;
  if has_function_privilege('authenticated', 'derm.fn_lwt_form_address(text,text,text,text)', 'EXECUTE') then raise exception 'VERIFY: helper is callable'; end if;
  perform set_config('request.jwt.claims', '', true);
end $verify$;

COMMIT;
