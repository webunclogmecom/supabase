-- ============================================================================
-- 2026-11-03_1830_route_line27_ccn_to_bsi  Line-27 visits of a Boca Raton client go to BSI, never to the DERM queue
-- ============================================================================
-- THE ASK
--   Trello 0lAWU6Ge (#169). Fred, 2026-11-03: the BSI bot files "Only line item 27 visits ... That are from Boca Raton";
--   then "Leads + routing now". Plan docs/specs/2026-11-03-boca-bsi-leads-and-filing-plan.md, section 8.3, stage S4.
-- WHY (measured 2026-11-03): v_derm_portal_fields keeps every line-27 visit (fn_visit_is_gdo_reporting) and joins only
--   GDO- permits. A Boca Raton line-27 visit (a CCN, no GDO) would therefore sit in v_derm_portal_queue_held as
--   no_permit, and log_rpa_derm_health() would email a daily "enter the client's GDO permit" item per visit plus a
--   line27_no_permit_clients item per client: wrong advice for Boca. It has not fired only because no Boca job, visit
--   or invoice carries line 27 yet. This must ship BEFORE the office adds line 27 to a Boca job.
-- WHAT
--   NEW public.fn_client_files_with_bsi(client): true when the client has NO live GDO permit (ACTIVE or EXPIRED; a live
--     GDO always wins) AND (it has a live Boca Raton property, OR it is a test client holding a live CCN: 112-YA,
--     whose properties are in Miami, is the smoke-test client). SECURITY DEFINER, search_path ''.
--   Three anchored edits of live bodies (md5 pinned before and after; columns, owner and grants unchanged):
--     public.v_derm_portal_fields            WHERE gains AND NOT fn_client_files_with_bsi(v.client_id)
--     public.v_gdo_reporting_derm_mismatch   the same clause
--     public.log_rpa_derm_health()           its line27_no_permit_clients query skips those clients
--   Every other DERM reader (v_derm_portal_queue, _queue_held, _dryrun, v_rpa_derm_health, derm.visit_gdo_*,
--   fn_record_manual_gdo_report, fn_requeue_derm_portal, the gdo_no_permit items) reads v_derm_portal_fields, so the
--   rule reaches them without an edit.
-- GRANTS: the new function is revoked from PUBLIC and anon, and granted to postgres, authenticated, service_role and
--   every role that can SELECT a view built on the two edited views (computed below), because a function inside an
--   owner-rights view runs with the CALLER's EXECUTE (Supabase CLAUDE.md, the asymmetry). Asserted afterwards.
-- PROOF, in three parts:
--   1. 2026-11-03_1830_route_line27_ccn_to_bsi_PROOF.sql (this file with every check, ending in ROLLBACK; HTTP 201
--      twice on 2026-11-03 ~16:48 ET): (a) md5 of every row of v_derm_portal_fields, v_derm_portal_queue,
--      v_derm_portal_queue_held, v_gdo_reporting_derm_mismatch and v_rpa_derm_health equal before and after;
--      (b) with line 27 on Grove Kosher's job 1325 the OLD bodies show Grove (3+ rows) and list 022-GRO, the NEW
--      bodies show neither.
--   2. Here, while the views are locked, only the cheap part: fields, queue and held hashed before and after (about
--      0.4 s; the mismatch and health views take 2.2 and 2.5 s, too long to hold a lock the DERM Tracker waits on).
--   3. After the commit: the mismatch and health views compared with a snapshot taken just before the apply, and the
--      positive control re-run rolled back (scripts/checks/bsi_routing.sql).
-- LOCKS: CREATE OR REPLACE VIEW locks two views the GDO bot and the DERM Tracker read: lock_timeout 3s, about half a
--   second held; applied clear of the backup dump (:17 on even UTC hours).
-- ROLLBACK: docs/migrations/2026-11-03_rollback_route_line27_ccn_to_bsi.sql
-- ============================================================================
begin;
set local lock_timeout = '3s';
set local search_path = public, extensions;   -- pg_get_viewdef text below is written and re-read under this path

do $pre$
begin
  if md5(pg_get_viewdef('public.v_derm_portal_fields'::regclass, false)) <> 'e6b1167b167d0fc07cb40262f512dc94' then
    raise exception 'route M: v_derm_portal_fields changed since this migration was written';
  end if;
  if md5(pg_get_viewdef('public.v_gdo_reporting_derm_mismatch'::regclass, false)) <> '824b66ccdcbe9e6bf4f50ad63470ce94' then
    raise exception 'route M: v_gdo_reporting_derm_mismatch changed since this migration was written';
  end if;
  if md5((select prosrc from pg_proc where oid = 'public.log_rpa_derm_health()'::regprocedure)) <> '7fab5d6618275c287dbdb4ed2eaad41f' then
    raise exception 'route M: log_rpa_derm_health changed since this migration was written';
  end if;
  if to_regprocedure('public.fn_client_files_with_bsi(bigint)') is not null then
    raise exception 'route M: fn_client_files_with_bsi already exists';
  end if;
end $pre$;

-- the "before" picture of the three cheap views (the full proof is the _PROOF file)
create temp table _route_before on commit drop as
select 'fields' as v, md5(coalesce(string_agg(t::text, '|' order by t::text), '')) as h from public.v_derm_portal_fields t
union all select 'queue', md5(coalesce(string_agg(t::text, '|' order by t::text), '')) from public.v_derm_portal_queue t
union all select 'held', md5(coalesce(string_agg(t::text, '|' order by t::text), '')) from public.v_derm_portal_queue_held t;

-- 1. the rule
create function public.fn_client_files_with_bsi(p_client_id bigint) returns boolean
language sql stable security definer set search_path = ''
as $fn$
  select not exists (select 1 from public.gdos g
                      where g.client_id = p_client_id and g.permit_type = 'GDO' and g.status in ('ACTIVE', 'EXPIRED'))
     and (exists (select 1 from public.properties p
                   where p.client_id = p_client_id and p.deleted_at is null and lower(btrim(p.city)) = 'boca raton')
          or (coalesce(public.fn_is_non_customer(p_client_id), false)
              and exists (select 1 from public.gdos g
                           where g.client_id = p_client_id and g.permit_type = 'CCN' and g.status in ('ACTIVE', 'EXPIRED'))))
$fn$;
comment on function public.fn_client_files_with_bsi(bigint) is
  'True when this client''s line-27 reports go to BSI Online (City of Boca Raton), not to the Miami-Dade DERM portal: '
  'no live GDO permit (a live GDO always wins) and a live Boca Raton property, or a test client holding a live CCN. '
  'Read by v_derm_portal_fields, v_gdo_reporting_derm_mismatch and log_rpa_derm_health (2026-11-03_1830, Trello #169).';
revoke all on function public.fn_client_files_with_bsi(bigint) from public, anon;

do $grants$
declare r record;
begin
  -- every role that can read a view resting on the two edited views (recursively), plus the two API roles that read
  -- the DERM Tracker's views; never anon
  for r in
    with recursive deps(oid) as (
      select 'public.v_derm_portal_fields'::regclass::oid
      union select 'public.v_gdo_reporting_derm_mismatch'::regclass::oid
      union
      select rw.ev_class from deps d
        join pg_depend dp on dp.refobjid = d.oid and dp.classid = 'pg_rewrite'::regclass
        join pg_rewrite rw on rw.oid = dp.objid
       where rw.ev_class <> d.oid
    )
    select distinct ro.rolname
      from deps d cross join pg_roles ro
     where ro.rolname not in ('anon', 'postgres') and ro.rolname not like 'pg\_%'
       and has_table_privilege(ro.oid, d.oid, 'SELECT')
    union select 'authenticated' union select 'service_role'
  loop
    execute format('grant execute on function public.fn_client_files_with_bsi(bigint) to %I', r.rolname);
  end loop;
end $grants$;

-- 2. the three anchored edits
do $edit$
declare d text; a text; b text;
begin
  d := rtrim(btrim(pg_get_viewdef('public.v_derm_portal_fields'::regclass, false)), ';');
  a := 'WHERE ((v.deleted_at IS NULL) AND fn_visit_is_gdo_reporting(v.id))';
  b := 'WHERE ((v.deleted_at IS NULL) AND fn_visit_is_gdo_reporting(v.id) AND (NOT public.fn_client_files_with_bsi(v.client_id)))';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'route M: fields anchor not found once'; end if;
  execute 'create or replace view public.v_derm_portal_fields as ' || replace(d, a, b);

  d := rtrim(btrim(pg_get_viewdef('public.v_gdo_reporting_derm_mismatch'::regclass, false)), ';');
  a := 'AND (fn_visit_requires_derm(v.id) IS FALSE))';
  b := 'AND (fn_visit_requires_derm(v.id) IS FALSE) AND (NOT public.fn_client_files_with_bsi(v.client_id)))';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'route M: mismatch anchor not found once'; end if;
  execute 'create or replace view public.v_gdo_reporting_derm_mismatch as ' || replace(d, a, b);

  d := pg_get_functiondef('public.log_rpa_derm_health()'::regprocedure);
  a := E'           group by c.client_code, c.name) x;';
  b := E'             and not public.fn_client_files_with_bsi(c.id)   -- 2026-11-03_1830: a Boca Raton client files with BSI\n           group by c.client_code, c.name) x;';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'route M: health anchor not found once'; end if;
  execute replace(d, a, b);
end $edit$;

-- VERIFY
do $verify$
declare v_bad text; r record;
begin
  -- the three edits landed
  if position('fn_client_files_with_bsi' in pg_get_viewdef('public.v_derm_portal_fields'::regclass, false)) = 0
     or position('fn_client_files_with_bsi' in pg_get_viewdef('public.v_gdo_reporting_derm_mismatch'::regclass, false)) = 0
     or position('fn_client_files_with_bsi' in (select prosrc from pg_proc where oid = 'public.log_rpa_derm_health()'::regprocedure)) = 0 then
    raise exception 'route M VERIFY: an edit did not land';
  end if;

  -- nothing moves today in the three cheap views (the two slow ones are compared after the commit)
  select string_agg(b.v, ', ') into v_bad
    from _route_before b
    join (select 'fields' as v, md5(coalesce(string_agg(t::text, '|' order by t::text), '')) as h from public.v_derm_portal_fields t
          union all select 'queue', md5(coalesce(string_agg(t::text, '|' order by t::text), '')) from public.v_derm_portal_queue t
          union all select 'held', md5(coalesce(string_agg(t::text, '|' order by t::text), '')) from public.v_derm_portal_queue_held t) a
      on a.v = b.v
   where a.h is distinct from b.h;
  if v_bad is not null then raise exception 'route M VERIFY: rows moved today in %', v_bad; end if;

  -- grants: every role that reads a dependent view can run the rule; anon cannot
  if has_function_privilege('anon', 'public.fn_client_files_with_bsi(bigint)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'public.fn_client_files_with_bsi(bigint)', 'EXECUTE')
     or not has_function_privilege('service_role', 'public.fn_client_files_with_bsi(bigint)', 'EXECUTE') then
    raise exception 'route M VERIFY: function grants are not as intended';
  end if;
  for r in select ro.rolname from pg_roles ro
            where ro.rolname not in ('anon', 'postgres') and ro.rolname not like 'pg\_%'
              and (has_table_privilege(ro.oid, 'public.v_derm_portal_fields', 'SELECT')
                   or has_table_privilege(ro.oid, 'public.v_derm_portal_queue', 'SELECT'))
              and not has_function_privilege(ro.oid, 'public.fn_client_files_with_bsi(bigint)', 'EXECUTE') loop
    raise exception 'route M VERIFY: % reads the DERM views but cannot run the rule', r.rolname;
  end loop;
end $verify$;

commit;
