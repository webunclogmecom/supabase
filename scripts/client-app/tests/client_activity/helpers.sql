-- Value helpers for client.get_client_activity. __S__ = audit (migration) or pg_temp (test).
-- Neither is granted to anyone: only the owner-run reader calls them.

CREATE OR REPLACE FUNCTION __S__.fn_activity_norm(p jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  -- SQL null, JSON null, '' , {} and an array of only empties are one "empty", so a null -> '' write is not a change.
  select case
    when p is null or p = 'null'::jsonb or p = '""'::jsonb or p = '{}'::jsonb then null
    when jsonb_typeof(p) = 'array' then (
      select case when count(*) filter (where e is not null and e <> 'null'::jsonb and e <> '""'::jsonb) = 0 then null
                  else jsonb_agg(case when e = 'null'::jsonb or e = '""'::jsonb then 'null'::jsonb else e end order by o) end
        from jsonb_array_elements(p) with ordinality x(e, o))
    else p end
$function$;

CREATE OR REPLACE FUNCTION __S__.fn_activity_sentence(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  -- 'action_required' -> 'Action required'
  select case when nullif(btrim(p), '') is null then null
              else upper(left(replace(btrim(p), '_', ' '), 1)) || lower(substr(replace(btrim(p), '_', ' '), 2)) end
$function$;

CREATE OR REPLACE FUNCTION __S__.fn_activity_value(p jsonb, p_type text, p_fk_table text, p_fk_label_col text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v jsonb := __S__.fn_activity_norm(p);
  r text;
begin
  -- clients.primary_contact_ref: null and 'client_record' both mean the Jobber client record
  if p_type = 'contact_ref' then
    if v is null or v #>> '{}' = 'client_record' then return 'Client record'; end if;
    if v #>> '{}' like 'ours:%' then
      select coalesce(nullif(btrim(c.name), ''), c.email) into r from public.client_contacts c
       where c.id = nullif(split_part(v #>> '{}', ':', 2), '')::bigint;
    elsif v #>> '{}' like 'jobber:%' then
      select coalesce(nullif(btrim(c.name), ''), c.email) into r from public.client_jobber_contacts c
       where c.id = nullif(split_part(v #>> '{}', ':', 2), '')::bigint;
    end if;
    return coalesce(r, 'A contact no longer on file');
  end if;
  if v is null then return null; end if;
  case p_type
    when 'address' then
      return nullif(concat_ws(', ', nullif(btrim(v ->> 0), ''), nullif(btrim(v ->> 1), ''), nullif(btrim(v ->> 2), '')), '');
    when 'pin' then
      if v ->> 0 is null or v ->> 1 is null then return null; end if;
      return round((v ->> 0)::numeric, 5)::text || ', ' || round((v ->> 1)::numeric, 5)::text;
    when 'geofence' then
      return nullif(concat_ws(', ', __S__.fn_activity_sentence(v ->> 0), (v ->> 1) || ' m'), '');
    when 'role' then
      return case when v ->> 0 = 'other' and nullif(btrim(v ->> 1), '') is not null then btrim(v ->> 1)
                  else __S__.fn_activity_sentence(v ->> 0) end;
    when 'zone' then
      select coalesce(nullif(z.short_label, ''), z.code) || coalesce(' (' || nullif(z.label, '') || ')', '') into r
        from public.zones z where z.id = (v #>> '{}')::bigint;
      return coalesce(r, 'Zone #' || (v #>> '{}'));
    when 'schedule' then
      -- the site's own clock strings, never a time zone conversion; 00:00 - 00:00 is all day
      return (
        with d as (
          select u.ord, v -> u.k as h from unnest(array['mon','tue','wed','thu','fri','sat','sun']) with ordinality u(k, ord)),
        t as (
          select ord, case when h is null or h = 'null'::jsonb then 'closed'
                           when h ->> 'open' = '00:00' and h ->> 'close' = '00:00' then 'all day'
                           else to_char((h ->> 'open')::time, 'FMHH12:MI AM') || ' - ' || to_char((h ->> 'close')::time, 'FMHH12:MI AM') end as txt
            from d),
        g as (select ord, txt, ord - row_number() over (partition by txt order by ord) as grp from t),
        runs as (select txt, min(ord) as a, max(ord) as b, count(*) as n from g group by txt, grp)
        select string_agg(
                 case when n = 1 then (array['Mon','Tue','Wed','Thu','Fri','Sat','Sun'])[a]
                      when n = 2 then (array['Mon','Tue','Wed','Thu','Fri','Sat','Sun'])[a] || ' and ' || (array['Mon','Tue','Wed','Thu','Fri','Sat','Sun'])[b]
                      else (array['Mon','Tue','Wed','Thu','Fri','Sat','Sun'])[a] || ' to ' || (array['Mon','Tue','Wed','Thu','Fri','Sat','Sun'])[b] end
                 || ' ' || txt, ', ' order by a)
          from runs);
    when 'list' then
      if jsonb_typeof(v) <> 'array' then return v #>> '{}'; end if;
      return (select string_agg(x, ', ') from jsonb_array_elements_text(v) x where x <> 'null');
    when 'changed' then return null;
    when 'removed' then return null;
    when 'enum' then return __S__.fn_activity_sentence(v #>> '{}');
    when 'jobstatus' then return __S__.fn_activity_sentence(v #>> '{}');
    when 'days' then return case when v #>> '{}' = '0' then 'Not recurring' else (v #>> '{}') || ' days' end;
    when 'gallons' then return (v #>> '{}') || ' gal';
    when 'date', 'datetime', 'money', 'bool', 'fk' then return audit.render_value(v, p_type, p_fk_table, p_fk_label_col);
    else return v #>> '{}';
  end case;
end $function$;
