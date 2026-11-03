-- Line-27 routing standing check (migration 2026-11-03_1830, Trello #169). Read-only. Healthy = every row 'ok'.
--   1. no line-27 visit of a client that files with BSI reaches the DERM fields, held queue or mismatch view;
--   2. no client has both a live GDO permit and a live Boca Raton property (the rule would silently pick DERM);
--   3. no live CCN sits on a client that files with DERM;
--   4. CONTROLS: the rule is in the three bodies, and it says Grove Kosher (client 357) files with BSI.
-- The behaviour proof with a line 27 actually on a Boca job (old bodies show Grove, new ones do not) is
-- docs/migrations/2026-11-03_1830_route_line27_ccn_to_bsi_PROOF.sql, which ends in ROLLBACK: re-run it to re-prove.
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
  select 'no client with both a live GDO and a live Boca Raton property',
         (select count(distinct g.client_id) from public.gdos g
           join public.properties p on p.client_id = g.client_id and p.deleted_at is null and lower(btrim(p.city)) = 'boca raton'
          where g.permit_type = 'GDO' and g.status in ('ACTIVE', 'EXPIRED'))
  union all
  select 'no live CCN on a client that files with DERM',
         (select count(*) from public.gdos g
           where g.permit_type = 'CCN' and g.status in ('ACTIVE', 'EXPIRED')
             and not public.fn_client_files_with_bsi(g.client_id))
  union all
  select 'CONTROL: the rule is in the three bodies',
         (case when position('fn_client_files_with_bsi' in pg_get_viewdef('public.v_derm_portal_fields'::regclass)) > 0 then 0 else 1 end
        + case when position('fn_client_files_with_bsi' in pg_get_viewdef('public.v_gdo_reporting_derm_mismatch'::regclass)) > 0 then 0 else 1 end
        + case when position('fn_client_files_with_bsi' in (select prosrc from pg_proc where oid = 'public.log_rpa_derm_health()'::regprocedure)) > 0 then 0 else 1 end)
  union all
  select 'CONTROL: Grove Kosher (357) files with BSI', case when public.fn_client_files_with_bsi(357) then 0 else 1 end
)
select check_name, case when bad = 0 then 'ok' else 'FAIL: ' || bad end as status from checks;
