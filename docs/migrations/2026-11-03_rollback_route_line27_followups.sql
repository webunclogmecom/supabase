-- ROLLBACK of 2026-11-03_1848_route_line27_followups. The three bodies as they were just before it, captured from
-- pg_get_functiondef / pg_get_viewdef on 2026-11-03 (not retyped). Undoing it drops the two bsi_route health items,
-- lets derm.gdo_report_status list a Boca Raton client's line-27 visits again, and takes DISTINCT ON out of the
-- health scan (two items with one key would then stop the whole health email).
-- ORDER (added 2026-11-03 ~20:50 ET): run 2026-11-03_rollback_route_line27_alerts.sql FIRST (this file puts back a
-- logger body whose block that migration rewrote); 2026-11-03_rollback_route_line27_ccn_to_bsi.sql, if wanted, comes
-- after this one. Rehearsed as one chain, undone (scratchpad chain_rollbacks.mjs). Enforced since 2026-11-03 ~23:10 ET:
-- the guard below refuses unless the logger is the body 2026-11-03_1848 left (md5 21e2025e...).
begin;
set local lock_timeout = '3s';
set local search_path = public, extensions;
do $g$
begin
  if md5((select prosrc from pg_proc where oid = 'public.log_rpa_derm_health()'::regprocedure)) <> '21e2025e707c5db977b5434261c0f276' then
    raise exception 'rollback: log_rpa_derm_health is not the body 2026-11-03_1848 left (run 2026-11-03_rollback_route_line27_alerts.sql first); nothing was changed';
  end if;
end $g$;
CREATE OR REPLACE FUNCTION public.fn_health_alert_scan(p_stale_days integer DEFAULT 3, p_renotify_days integer DEFAULT 7)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'ops', 'pg_temp'
AS $function$
DECLARE
  v_new      jsonb;
  v_stale    jsonb;
  v_resolved jsonb;
BEGIN
  -- (a) record everything currently open
  INSERT INTO public.health_alert_state (check_name, item_key, first_seen_at, last_seen_at)
  SELECT i.check_name, i.item_key, now(), now()
    FROM ops.v_health_items i
  ON CONFLICT (check_name, item_key) DO UPDATE
    SET last_seen_at = now(),
        -- an item that comes BACK starts its clock again; it is a new occurrence,
        -- not a continuation of the one that was fixed.
        first_seen_at   = CASE WHEN public.health_alert_state.resolved_at IS NOT NULL
                               THEN now() ELSE public.health_alert_state.first_seen_at END,
        alert_count     = CASE WHEN public.health_alert_state.resolved_at IS NOT NULL
                               THEN 0 ELSE public.health_alert_state.alert_count END,
        last_alerted_at = CASE WHEN public.health_alert_state.resolved_at IS NOT NULL
                               THEN NULL ELSE public.health_alert_state.last_alerted_at END,
        resolved_at     = NULL;

  -- (b) anything we knew about that is no longer reported has resolved
  UPDATE public.health_alert_state s
     SET resolved_at = now()
   WHERE s.resolved_at IS NULL
     AND NOT EXISTS (SELECT 1 FROM ops.v_health_items i
                      WHERE i.check_name = s.check_name AND i.item_key = s.item_key);

  -- (c) NEW: open, never emailed about
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'check_name', s.check_name, 'item_key', s.item_key,
           'open_days', floor(extract(epoch FROM now() - s.first_seen_at)/86400)::int,
           'item', i.item) ORDER BY s.check_name, s.item_key), '[]'::jsonb)
    INTO v_new
    FROM public.health_alert_state s
    JOIN ops.v_health_items i ON i.check_name = s.check_name AND i.item_key = s.item_key
   WHERE s.resolved_at IS NULL AND s.alert_count = 0
     AND (s.acknowledged_until IS NULL OR s.acknowledged_until < now());

  -- (d) STALE: open >= p_stale_days, already emailed at least once, and due again
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'check_name', s.check_name, 'item_key', s.item_key,
           'open_days', floor(extract(epoch FROM now() - s.first_seen_at)/86400)::int,
           'alert_count', s.alert_count,
           'item', i.item) ORDER BY s.first_seen_at), '[]'::jsonb)
    INTO v_stale
    FROM public.health_alert_state s
    JOIN ops.v_health_items i ON i.check_name = s.check_name AND i.item_key = s.item_key
   WHERE s.resolved_at IS NULL AND s.alert_count > 0
     AND (s.acknowledged_until IS NULL OR s.acknowledged_until < now())
     -- 2026-09-24_2350: an hour of tolerance. last_alerted_at is stamped a moment AFTER this scan's now(),
     -- so an exact comparison missed the 7th daily run by under a second and re-sent on day 8.
     AND now() - s.first_seen_at >= make_interval(days => p_stale_days) - interval '1 hour'
     AND (s.last_alerted_at IS NULL
          OR now() - s.last_alerted_at >= make_interval(days => p_renotify_days) - interval '1 hour');

  -- (e) RESOLVED since we last spoke. Rides along; never triggers a send by itself.
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'check_name', s.check_name, 'item_key', s.item_key) ORDER BY s.check_name), '[]'::jsonb)
    INTO v_resolved
    FROM public.health_alert_state s
   WHERE s.resolved_at IS NOT NULL
     AND s.alert_count > 0
     AND (s.last_alerted_at IS NULL OR s.resolved_at > s.last_alerted_at);

  RETURN jsonb_build_object(
    'should_send', (jsonb_array_length(v_new) > 0 OR jsonb_array_length(v_stale) > 0),
    'stale_days', p_stale_days,
    'new', v_new, 'stale', v_stale, 'resolved', v_resolved);
END $function$;
create or replace view derm.gdo_report_status as
SELECT v.id AS visit_id,
    v.client_id,
    c.client_code,
    c.name AS client_name,
    v.visit_date,
    last.manifest_id,
    last.status,
    last.portal_confirmation,
    last.failure_reason,
    last.last_attempt_at,
        CASE
            WHEN ((last.status = 'SUCCESS'::text) OR (last.portal_confirmation IS NOT NULL)) THEN 'reported'::text
            WHEN (last.status IS NULL) THEN 'pending'::text
            WHEN (NOT last.retryable) THEN 'failed'::text
            ELSE 'pending'::text
        END AS report_state
   FROM ((visits v
     JOIN clients c ON ((c.id = v.client_id)))
     LEFT JOIN LATERAL ( SELECT s.manifest_id,
            s.status,
            s.portal_confirmation,
            s.failure_reason,
            s.retryable,
            s.created_at AS last_attempt_at
           FROM derm_portal_submissions s
          WHERE ((s.visit_id = v.id) AND (NOT s.dry_run))
          ORDER BY ((s.status = 'SUCCESS'::text) OR (s.portal_confirmation IS NOT NULL)) DESC, s.created_at DESC
         LIMIT 1) last ON (true))
  WHERE ((v.deleted_at IS NULL) AND fn_visit_is_gdo_reporting(v.id));
CREATE OR REPLACE FUNCTION public.log_rpa_derm_health()
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
declare h record; reasons jsonb := '[]'::jsonb; attn boolean := false; np jsonb; nc jsonb; pc jsonb;
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
  insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
  values ('rpa-derm-health', now(), now(), coalesce(h.queue_depth,0),
          case when attn then 'attention' else 'ok' end,
          jsonb_build_object('queue_depth',h.queue_depth,'last_real_attempt',h.last_real_attempt,
                             'success_24h',h.success_24h,'store_failed_total',h.store_failed_total,
                             'visits_ge3_attempts',h.visits_ge3_attempts,
                             'gdo_not_derm_required',h.gdo_not_derm_required,
                             'stale_leases',h.stale_leases,'held_no_permit',jsonb_array_length(np),'line27_no_permit_clients',jsonb_array_length(nc),'reasons',reasons));
  return case when attn then 1 else 0 end;
end $function$;
commit;
