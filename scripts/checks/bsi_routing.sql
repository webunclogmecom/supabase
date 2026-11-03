-- Line-27 routing standing check (migrations 2026-11-03_1830 and 2026-11-03_1848_route_line27_followups, Trello #169).
-- Read-only. Healthy = every row 'ok'.
--   1. no line-27 visit of a client that files with BSI reaches the DERM fields, held queue, mismatch view or
--      derm.gdo_report_status;
--   2. the two client shapes the per-client rule cannot route (log_rpa_derm_health raises them daily as
--      bsi_route_gdo_and_boca:<id> / bsi_route_other_city:<id>): a live GDO plus a live Boca Raton property, and a
--      client routed to BSI with line 27 on an open job and a property in another city;
--   3. no live CCN sits on a client that files with DERM;
--   4. CONTROLS: the rule is in the four bodies and the two health items are in log_rpa_derm_health; the rule says Grove
--      Kosher (client 357) files with BSI.
-- Known, and not a failure: client 245 (no code, jobs archived) has a Boca Raton property and a 'Beverly Hills'
-- property marked Dade; it would raise bsi_route_other_city the day line 27 reaches an open job of it.
-- The behaviour proofs (old bodies show the visits, new ones do not; each health item fires on its shape) are the
-- VERIFY blocks of those two migrations and docs/migrations/2026-11-03_1830_route_line27_ccn_to_bsi_PROOF.sql.
with routed as (
  select c.id from public.clients c where public.fn_client_files_with_bsi(c.id)
), checks as (
  select 'no routed client in the DERM fields' as check_name,
         (select count(*) from public.v_derm_portal_fields f where f.client_id in (select id from routed)) as bad
  union all
  select 'no routed client held in the DERM queue',
         (select count(*) from public.v_derm_portal_queue_held h join public.clients c on c.client_code = h.client_code
           where c.id in (select id from routed))
  union all
  select 'no routed client in the line-27 / DERM-required mismatch view',
         (select count(*) from public.v_gdo_reporting_derm_mismatch m where m.client_id in (select id from routed))
  union all
  select 'no routed client in derm.gdo_report_status',
         (select count(*) from derm.gdo_report_status s where s.client_id in (select id from routed))
  union all
  select 'no client with both a live GDO and a live Boca Raton property',
         (select count(distinct g.client_id) from public.gdos g
           join public.properties p on p.client_id = g.client_id and p.deleted_at is null and lower(btrim(p.city)) = 'boca raton'
          where g.permit_type = 'GDO' and g.status in ('ACTIVE', 'EXPIRED'))
  union all
  select 'no routed client with line 27 on an open job and a property in another city',
         (select count(*) from public.clients c
           where c.id in (select id from routed)
             and not exists (select 1 from public.v_non_customer_clients n where n.client_id = c.id)
             and exists (select 1 from public.properties p
                          where p.client_id = c.id and p.deleted_at is null and lower(btrim(coalesce(p.city, ''))) <> 'boca raton')
             and exists (select 1 from public.jobs j join public.line_items li on li.job_id = j.id and li.visit_id is null
                          where j.client_id = c.id and public.fn_line_item_is_gdo_reporting(li.name)
                            and j.job_status not in ('archived', 'destroyed')))
  union all
  select 'no live CCN on a client that files with DERM',
         (select count(*) from public.gdos g
           where g.permit_type = 'CCN' and g.status in ('ACTIVE', 'EXPIRED')
             and not public.fn_client_files_with_bsi(g.client_id))
  union all
  select 'CONTROL: the rule is in the four bodies, the two items in the health logger',
         (case when position('fn_client_files_with_bsi' in pg_get_viewdef('public.v_derm_portal_fields'::regclass)) > 0 then 0 else 1 end
        + case when position('fn_client_files_with_bsi' in pg_get_viewdef('public.v_gdo_reporting_derm_mismatch'::regclass)) > 0 then 0 else 1 end
        + case when position('fn_client_files_with_bsi' in pg_get_viewdef('derm.gdo_report_status'::regclass)) > 0 then 0 else 1 end
        + case when position('fn_client_files_with_bsi' in (select prosrc from pg_proc where oid = 'public.log_rpa_derm_health()'::regprocedure)) > 0 then 0 else 1 end
        + case when position('bsi_route_gdo_and_boca' in (select prosrc from pg_proc where oid = 'public.log_rpa_derm_health()'::regprocedure)) > 0
                and position('bsi_route_other_city' in (select prosrc from pg_proc where oid = 'public.log_rpa_derm_health()'::regprocedure)) > 0
               then 0 else 1 end)
  union all
  select 'CONTROL: Grove Kosher (357) files with BSI', case when public.fn_client_files_with_bsi(357) then 0 else 1 end
)
select check_name, case when bad = 0 then 'ok' else 'FAIL: ' || bad end as status from checks;
