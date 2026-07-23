-- ============================================================================
-- 2026-07-23b - GDO reporting: FLAG code-27 visits that are NOT DERM-required
-- ============================================================================
-- Fred 2026-07-23: keep the GDO queue eligibility on the "27 - GDO Online Reporting"
-- line item alone -- do NOT gate the queue on derm_required. Instead FLAG any code-27
-- visit whose service is not DERM-manifest-requiring, so a mis-applied add-on surfaces
-- for review rather than being silently dropped. GDO online reporting only applies to
-- services that produce a DERM manifest (pumping/disposal); a code-27 on a non-pumping
-- service is an anomaly worth a human look.
--
-- Signal: has the code-27 line item (fn_line_item_is_gdo_reporting on the visit's line
-- items) AND fn_visit_requires_derm(v.id) IS FALSE. Uses the LIVE function, not the
-- derm_required COLUMN, so a merely-unstamped column (NULL, before the nightly rederive)
-- is NOT a false positive -- only a DEFINITIVELY non-DERM service flags. Currently 0.
--
-- Additive + safe: a new detail view + one metric on v_rpa_derm_health + one attention
-- reason in log_rpa_derm_health (surfaced daily by pg_cron rpa-derm-health-check ->
-- sync_log status='attention'). The GDO queue/dryrun views + edge fns are UNTOUCHED.
-- Views -> no audit trigger.
-- ============================================================================

-- 1. Detail view: which code-27 visits are not DERM-required (empty in the healthy case)
create or replace view public.v_gdo_reporting_derm_mismatch as
select v.id as visit_id, v.client_id, c.client_code, c.name as client_name,
       v.visit_date, v.service_type, v.derm_required,
       exists (select 1 from public.manifest_visits mv
               join public.derm_manifests m on m.id = mv.manifest_id and m.deleted_at is null
               where mv.visit_id = v.id) as has_manifest
from public.visits v
join public.clients c on c.id = v.client_id
where v.deleted_at is null
  and exists (select 1 from public.line_items li
              where li.visit_id = v.id and public.fn_line_item_is_gdo_reporting(li.name))
  and public.fn_visit_requires_derm(v.id) is false;

comment on view public.v_gdo_reporting_derm_mismatch is
  'Anomaly flag: visits carrying the "27 - GDO Online Reporting" line item whose service is definitively NOT DERM-manifest-requiring (fn_visit_requires_derm=false). GDO reporting is only for pumping/disposal services, so a hit means the add-on was likely mis-applied to a non-pumping visit -- review. Surfaced daily via v_rpa_derm_health.gdo_not_derm_required + log_rpa_derm_health. 2026-07-23b.';

-- 2. Add the metric to the health watchdog (append column; existing columns unchanged)
create or replace view public.v_rpa_derm_health as
 select ( select count(*) as count from v_derm_portal_queue) as queue_depth,
    ( select max(derm_portal_submissions.created_at) as max
        from derm_portal_submissions
       where not derm_portal_submissions.dry_run) as last_real_attempt,
    ( select count(*) as count
        from derm_portal_submissions
       where not derm_portal_submissions.dry_run and derm_portal_submissions.status = 'SUCCESS'::text
         and derm_portal_submissions.created_at > (now() - '24:00:00'::interval)) as success_24h,
    ( select count(*) as count
        from derm_portal_submissions
       where not derm_portal_submissions.dry_run and derm_portal_submissions.screenshot_missing_reason = 'STORE_FAILED'::text) as store_failed_total,
    ( select count(*) as count
        from ( select derm_portal_submissions.visit_id
                 from derm_portal_submissions
                where not derm_portal_submissions.dry_run
                group by derm_portal_submissions.visit_id
               having count(*) >= 3) q) as visits_ge3_attempts,
    ( select count(*) as count from v_gdo_reporting_derm_mismatch) as gdo_not_derm_required;

-- 3. Wire the flag into the daily attention logic
create or replace function public.log_rpa_derm_health()
 returns integer
 language plpgsql
as $function$
declare h record; reasons jsonb := '[]'::jsonb; attn boolean := false;
begin
  select * into h from public.v_rpa_derm_health;
  if h.queue_depth > 0 and (h.last_real_attempt is null or h.last_real_attempt < now() - interval '26 hours') then
    attn := true; reasons := reasons || jsonb_build_object('kind','no_recent_attempts','queue_depth',h.queue_depth,'last_real_attempt',h.last_real_attempt);
  end if;
  if h.store_failed_total > 0 then attn := true; reasons := reasons || jsonb_build_object('kind','evidence_lost_store_failed','count',h.store_failed_total); end if;
  if h.visits_ge3_attempts > 0 then attn := true; reasons := reasons || jsonb_build_object('kind','retry_loop_visits','count',h.visits_ge3_attempts); end if;
  if h.gdo_not_derm_required > 0 then attn := true; reasons := reasons || jsonb_build_object('kind','gdo_code27_not_derm_required','count',h.gdo_not_derm_required); end if;
  insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
  values ('rpa-derm-health', now(), now(), coalesce(h.queue_depth,0),
          case when attn then 'attention' else 'ok' end,
          jsonb_build_object('queue_depth',h.queue_depth,'last_real_attempt',h.last_real_attempt,
                             'success_24h',h.success_24h,'store_failed_total',h.store_failed_total,
                             'visits_ge3_attempts',h.visits_ge3_attempts,
                             'gdo_not_derm_required',h.gdo_not_derm_required,'reasons',reasons));
  return case when attn then 1 else 0 end;
end $function$;
