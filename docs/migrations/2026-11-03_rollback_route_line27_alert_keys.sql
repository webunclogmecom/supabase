-- ROLLBACK of 2026-11-03_2255_route_line27_alert_keys. public.log_rpa_derm_health as it was just before it, captured from
-- pg_get_functiondef on 2026-11-03 (not retyped, md5-checked), and service_role's EXECUTE on
-- public.fn_city_is_boca_raton taken back, with the helper's previous comment.
-- ORDER: run 2026-11-04_rollback_route_line27_alert_set_keys.sql first (this file's guard refuses until it has run),
-- then this, before 2026-11-03_rollback_route_line27_alerts.sql (whose guard refuses until this file has run), then
-- 2026-11-03_rollback_route_line27_followups.sql, then 2026-11-03_rollback_route_line27_ccn_to_bsi.sql.
-- Each guard checks that the live body is the one its own migration left, so a wrong order is refused, not applied.
-- Undoing this brings back routing items keyed on kind and client only (a client's later line-27 visits raise nothing
-- new, and a silence hides them), items raised by an address with no work (a billing address), and a service_role
-- call of the logger that fails 42501.
begin;
set local lock_timeout = '3s';
set local search_path = public, extensions;
do $g$
begin
  if md5((select prosrc from pg_proc where oid = 'public.log_rpa_derm_health()'::regprocedure)) <> '57a1cad01dac85dc947dfa8a5fb1f462' then
    raise exception 'rollback: log_rpa_derm_health is not the body 2026-11-03_2255 left (run 2026-11-04_rollback_route_line27_alert_set_keys.sql first); nothing was changed';
  end if;
end $g$;
CREATE OR REPLACE FUNCTION public.log_rpa_derm_health()
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
declare h record; reasons jsonb := '[]'::jsonb; attn boolean := false; np jsonb; nc jsonb; pc jsonb; rc jsonb;
begin
  select * into h from public.v_rpa_derm_health;
  if h.queue_depth > 0 and (h.last_real_attempt is null or h.last_real_attempt < now() - interval '26 hours') then
    attn := true; reasons := reasons || jsonb_build_object('kind','no_recent_attempts','queue_depth',h.queue_depth,'last_real_attempt',h.last_real_attempt);
  end if;
  if h.store_failed_total > 0 then attn := true; reasons := reasons || jsonb_build_object('kind','evidence_lost_store_failed','count',h.store_failed_total); end if;
  if h.visits_ge3_attempts > 0 then attn := true; reasons := reasons || jsonb_build_object('kind','retry_loop_visits','count',h.visits_ge3_attempts); end if;
  if h.gdo_not_derm_required > 0 then attn := true; reasons := reasons || jsonb_build_object('kind','gdo_code27_not_derm_required','count',h.gdo_not_derm_required); end if;
  if h.stale_leases > 0 then attn := true; reasons := reasons || jsonb_build_object('kind','rpa_lease_no_result','count',h.stale_leases); end if;
  -- 2026-10-20: a GDO-reporting visit whose client has no ACTIVE permit is never served (v_derm_portal_queue
  -- skips gdo_id IS NULL). One item per visit, keyed on visit_id by ops.v_health_items, emailed the day it appears.
  select coalesce(jsonb_agg(jsonb_build_object('kind','gdo_no_permit','visit_id',q.visit_id,'client_code',q.client_code,
           'visit_date',q.visit_date,'manifest_id',q.manifest_id,
           'reason','no ACTIVE GDO permit on file for this client, so its DERM online report cannot be filed',
           'what_to_do','Diego or Yan: confirm the client''s own GDO permit (the county PDF issued to this business at this address) and enter it with its PDF in the Client App; the visit then files by itself on the next bot pass, even if late. Never enter a permit found at the address under another business. If the client has no permit, decide whether it is still billed 27 - GDO Online Reporting.')
         order by q.visit_id), '[]'::jsonb)
    into np
    from public.v_derm_portal_queue_held q
   where q.held_by = 'no_permit'
     and not exists (select 1 from public.derm_portal_submissions s
                      where s.visit_id = q.visit_id and not s.dry_run
                        and (s.status = 'SUCCESS' or s.portal_confirmation is not null));
  if jsonb_array_length(np) > 0 then attn := true; reasons := reasons || np; end if;
  -- Upstream of the visits: an open job billing 27 - GDO Online Reporting for a client with no ACTIVE permit
  -- (Yan, 2026-09-04: the list of locations with online reporting and no GDO permit). Keyed on client_code.
  select coalesce(jsonb_agg(jsonb_build_object('client_code',x.client_code,'client',x.name,'jobs',x.jobs,
           'issue','an open job bills 27 - GDO Online Reporting but the client has no ACTIVE GDO permit',
           'what_to_do','Diego or Yan: get the client''s own GDO permit (county PDF) and enter it in the Client App before its next visit, or take line 27 off the job if the client has no permit.')
         order by x.client_code), '[]'::jsonb)
    into nc
    from (select c.client_code, c.name, jsonb_agg(distinct j.job_number) as jobs
            from public.jobs j
            join public.clients c on c.id = j.client_id
            join public.line_items li on li.job_id = j.id and li.visit_id is null
           where public.fn_line_item_is_gdo_reporting(li.name)
             and j.job_status not in ('archived','destroyed')
             and c.client_code is not null
             and not exists (select 1 from public.v_non_customer_clients n where n.client_id = c.id)
             and not exists (select 1 from public.gdos g
                              where g.client_id = c.id and g.status = 'ACTIVE' and g.gdo_number ~ '^GDO-[0-9]+$')
             and not public.fn_client_files_with_bsi(c.id)   -- 2026-11-03_1830: a Boca Raton client files with BSI
           group by c.client_code, c.name) x;
  if jsonb_array_length(nc) > 0 then attn := true; reasons := reasons || nc; end if;
  -- 2026-10-20 (follow-up): a visit filed under a permit that has since left the client's ACTIVE permits, while it has
  -- another permit. The queue files the current permit too; a person decides whether that was a replacement or a
  -- second trap. Keyed on visit_id (such a visit has a permit, so it is never also a gdo_no_permit item).
  select coalesce(jsonb_agg(jsonb_build_object('kind','gdo_filed_permit_changed','visit_id',x.visit_id,'client_code',x.client_code,
           'reason','filed with DERM under ' || x.filed_permit || ', which is no longer an ACTIVE permit of this client; its current permit is filed separately',
           'what_to_do','Diego or Yan: check whether ' || x.filed_permit || ' was replaced (the visit is then reported under both numbers) or is a separate trap.')
         order by x.visit_id), '[]'::jsonb)
    into pc
    from (select distinct on (s.visit_id) s.visit_id, c.client_code, coalesce(g.gdo_number, 'permit id ' || s.gdo_id) as filed_permit
            from public.derm_portal_submissions s
            join public.visits v on v.id = s.visit_id
            left join public.clients c on c.id = v.client_id
            left join public.gdos g on g.id = s.gdo_id
           where not s.dry_run and (s.status = 'SUCCESS' or s.portal_confirmation is not null) and s.gdo_id is not null
             and v.visit_date >= public.rpa_launch_cutoff()
             and not exists (select 1 from public.v_derm_portal_fields f where f.visit_id = s.visit_id and f.gdo_id = s.gdo_id)
             and exists (select 1 from public.v_derm_portal_fields f where f.visit_id = s.visit_id and f.gdo_id is not null)
           order by s.visit_id, s.created_at desc) x;
  if jsonb_array_length(pc) > 0 then attn := true; reasons := reasons || pc; end if;
  -- 2026-11-03_1848 / _2039: the line-27 routing works per client (fn_client_files_with_bsi), so two client shapes
  -- send some line-27 visits to the wrong place, and a client that files with BSI is filed by nobody yet (the BSI bot
  -- is plan S6-S8). A client "has line 27" when an open job's own lines carry it, or a visit since the launch cutoff
  -- is GDO-reporting (its visit, invoice or job line: fn_visit_is_gdo_reporting, the routing's own test). Never a
  -- test client; one item per client and kind, keyed on its kind (which carries the client id).
  select coalesce(jsonb_agg(x.item order by x.k), '[]'::jsonb)
    into rc
    from (with l27 as (
            select j.client_id from public.jobs j join public.line_items li on li.job_id = j.id and li.visit_id is null
             where public.fn_line_item_is_gdo_reporting(li.name) and j.job_status not in ('archived', 'destroyed')
            union
            select v.client_id from public.visits v
             where v.deleted_at is null and v.visit_date >= public.rpa_launch_cutoff()
               and public.fn_visit_is_gdo_reporting(v.id))
          select 'bsi_route_gdo_and_boca:' || c.id as k,
                 jsonb_build_object('kind', 'bsi_route_gdo_and_boca:' || c.id, 'client_code', c.client_code, 'client', c.name,
                   'issue', 'this client has a Miami-Dade GDO permit AND a Boca Raton property, so all its line-27 visits, Boca Raton ones included, are filed with Miami-Dade',
                   'what_to_do', 'Fred: the line-27 routing works per client and cannot send this client''s visits to two places. Check which property the line-27 work is for (a Boca Raton property files on BSI Online, never with Miami-Dade).') as item
            from public.clients c
           where c.id in (select l.client_id from l27 l)
             and exists (select 1 from public.gdos g
                          where g.client_id = c.id and g.permit_type = 'GDO' and g.status in ('ACTIVE', 'EXPIRED'))
             and exists (select 1 from public.properties p
                          where p.client_id = c.id and p.deleted_at is null and public.fn_city_is_boca_raton(p.city))
             and not exists (select 1 from public.v_non_customer_clients n where n.client_id = c.id)
          union all
          select 'bsi_route_other_city:' || c.id,
                 jsonb_build_object('kind', 'bsi_route_other_city:' || c.id, 'client_code', c.client_code, 'client', c.name,
                   'issue', 'this client files with BSI (a Boca Raton property, no GDO permit) but also has a property in another city, whose line-27 visits are kept out of the Miami-Dade queue and its alerts',
                   'what_to_do', 'Fred: the line-27 routing works per client and cannot send this client''s visits to two places. Check the other property (a wrong city, or a Miami-Dade location that needs its GDO permit entered).')
            from public.clients c
           where c.id in (select l.client_id from l27 l)
             and public.fn_client_files_with_bsi(c.id)
             and exists (select 1 from public.properties p
                          where p.client_id = c.id and p.deleted_at is null and not public.fn_city_is_boca_raton(p.city))
             and not exists (select 1 from public.v_non_customer_clients n where n.client_id = c.id)
          union all
          select 'bsi_route_unfiled:' || c.id,
                 jsonb_build_object('kind', 'bsi_route_unfiled:' || c.id, 'client_code', c.client_code, 'client', c.name,
                   'issue', 'this client files with BSI Online (City of Boca Raton) and line 27 is on its work, but nothing files BSI reports yet, so these visits are kept out of the Miami-Dade queue and filed by no one',
                   'what_to_do', 'Yan: file this client''s grease trap reports on BSI Online by hand (the BSI bot is not built yet). If the client is not in the City of Boca Raton program (no BSI record), take line 27 off its job.')
            from public.clients c
           where c.id in (select l.client_id from l27 l)
             and public.fn_client_files_with_bsi(c.id)
             and not exists (select 1 from public.v_non_customer_clients n where n.client_id = c.id)) x;
  if jsonb_array_length(rc) > 0 then attn := true; reasons := reasons || rc; end if;
  insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
  values ('rpa-derm-health', now(), now(), coalesce(h.queue_depth,0),
          case when attn then 'attention' else 'ok' end,
          jsonb_build_object('queue_depth',h.queue_depth,'last_real_attempt',h.last_real_attempt,
                             'success_24h',h.success_24h,'store_failed_total',h.store_failed_total,
                             'visits_ge3_attempts',h.visits_ge3_attempts,
                             'gdo_not_derm_required',h.gdo_not_derm_required,
                             'stale_leases',h.stale_leases,'held_no_permit',jsonb_array_length(np),'line27_no_permit_clients',jsonb_array_length(nc),'bsi_route_conflicts',jsonb_array_length(rc),'reasons',reasons));
  return case when attn then 1 else 0 end;
end $function$;
revoke execute on function public.fn_city_is_boca_raton(text) from service_role;
comment on function public.fn_city_is_boca_raton(text) is 'True when a property''s city reads Boca Raton, by its letters only and case-blind ("Boca Raton", "BOCA RATON", "Boca Raton, FL" and a non-breaking space all count; "Boca" alone and "West Boca Raton" do not). The one test the line-27 routing (fn_client_files_with_bsi), its health items in log_rpa_derm_health and scripts/checks/bsi_routing.sql use (2026-11-03_2039). It reads the city NAME, so a "Boca Raton" address outside the City limits counts too.';
do $v$
begin
  if md5((select prosrc from pg_proc where oid = 'public.log_rpa_derm_health()'::regprocedure)) <> '8b58a04cb61ed27fa29ee460797b6c12'
     or has_function_privilege('service_role', 'public.fn_city_is_boca_raton(text)', 'EXECUTE') then
    raise exception 'rollback VERIFY: not back to the body and grants of 2026-11-03_2039';
  end if;
end $v$;
commit;
