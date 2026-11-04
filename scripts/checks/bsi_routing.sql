-- Line-27 routing standing check (migrations 2026-11-03_1830, _1848_route_line27_followups and _2039_route_line27_alerts,
-- Trello #169). Read-only. Healthy = every row 'ok'.
--   1. no line-27 visit of a client that files with BSI reaches the DERM fields, held queue, mismatch view or
--      derm.gdo_report_status;
--   2. the two client shapes the per-client rule cannot route (log_rpa_derm_health raises them daily as
--      bsi_route_gdo_and_boca:<id> / bsi_route_other_city:<id>): a live GDO plus a live Boca Raton property, and a
--      client routed to BSI that has line 27 and a property in another city. "Has line 27" is the health items' own
--      test: an open job's own lines, or a GDO-reporting visit since the launch cutoff (its visit, invoice or job line);
--   3. no line 27 on a routed client we have not matched to a BSI record (081-TCE, 319-CAP, 135-BB, 361-SFG and
--      Olympus on 2026-11-03: Yan's review decides where they file first). A matched client WITH line 27 is not a
--      failure: the health item bsi_route_unfiled:<id> reminds Yan to file it on BSI Online by hand until the bot exists;
--   4. no live property whose city mentions Boca but does not read as Boca Raton (public.fn_city_is_boca_raton): a
--      spelling the rule would miss, or a West Boca address a person should look at;
--   5. no live CCN sits on a client that files with DERM;
--   6. CONTROLS: the rule is in the four bodies and uses the one Boca Raton test; the three health items are in
--      log_rpa_derm_health; the test reads the spellings it should; the rule says Grove Kosher (client 357) files with BSI.
-- Known, and not a failure: client 245 (no code, jobs archived) has a Boca Raton property and a 'Beverly Hills'
-- property marked Dade; it would raise bsi_route_other_city and bsi_route_unfiled the day line 27 reaches it.
-- The behaviour proofs (old bodies show the visits or miss the shape, new ones do not) are the VERIFY blocks of those
-- migrations and docs/migrations/2026-11-03_1830_route_line27_ccn_to_bsi_PROOF.sql.
with routed as (
  select c.id from public.clients c where public.fn_client_files_with_bsi(c.id)
), l27 as (   -- the health items' test, kept identical
  select j.client_id from public.jobs j join public.line_items li on li.job_id = j.id and li.visit_id is null
   where public.fn_line_item_is_gdo_reporting(li.name) and j.job_status not in ('archived', 'destroyed')
  union
  select v.client_id from public.visits v
   where v.deleted_at is null and v.visit_date >= public.rpa_launch_cutoff() and public.fn_visit_is_gdo_reporting(v.id)
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
           join public.properties p on p.client_id = g.client_id and p.deleted_at is null and public.fn_city_is_boca_raton(p.city)
          where g.permit_type = 'GDO' and g.status in ('ACTIVE', 'EXPIRED'))
  union all
  select 'no routed client with line 27 and a property in another city',
         (select count(*) from public.clients c
           where c.id in (select id from routed) and c.id in (select client_id from l27)
             and not exists (select 1 from public.v_non_customer_clients n where n.client_id = c.id)
             and exists (select 1 from public.properties p
                          where p.client_id = c.id and p.deleted_at is null and not public.fn_city_is_boca_raton(p.city)))
  union all
  select 'no line 27 on a routed client not matched to a BSI record',
         (select count(*) from public.clients c
           where c.id in (select id from routed) and c.id in (select client_id from l27)
             and not exists (select 1 from public.v_non_customer_clients n where n.client_id = c.id)
             and not exists (select 1 from leads.establishments e join public.properties p on p.id = e.property_id
                              where p.client_id = c.id and p.deleted_at is null and e.status = 'ACTIVE'))
  union all
  select 'no live property whose city mentions Boca but does not read as Boca Raton',
         (select count(*) from public.properties p
           where p.deleted_at is null and p.city ~* 'boca' and not public.fn_city_is_boca_raton(p.city))
  union all
  select 'no live CCN on a client that files with DERM',
         (select count(*) from public.gdos g
           where g.permit_type = 'CCN' and g.status in ('ACTIVE', 'EXPIRED')
             and not public.fn_client_files_with_bsi(g.client_id))
  union all
  select 'CONTROL: the rule is in the four bodies with the one Boca Raton test, the three items in the health logger',
         (case when position('fn_client_files_with_bsi' in pg_get_viewdef('public.v_derm_portal_fields'::regclass)) > 0 then 0 else 1 end
        + case when position('fn_client_files_with_bsi' in pg_get_viewdef('public.v_gdo_reporting_derm_mismatch'::regclass)) > 0 then 0 else 1 end
        + case when position('fn_client_files_with_bsi' in pg_get_viewdef('derm.gdo_report_status'::regclass)) > 0 then 0 else 1 end
        + case when position('fn_client_files_with_bsi' in (select prosrc from pg_proc where oid = 'public.log_rpa_derm_health()'::regprocedure)) > 0 then 0 else 1 end
        + case when position('fn_city_is_boca_raton' in (select prosrc from pg_proc where oid = 'public.fn_client_files_with_bsi(bigint)'::regprocedure)) > 0 then 0 else 1 end
        + case when position('bsi_route_gdo_and_boca' in (select prosrc from pg_proc where oid = 'public.log_rpa_derm_health()'::regprocedure)) > 0
                and position('bsi_route_other_city' in (select prosrc from pg_proc where oid = 'public.log_rpa_derm_health()'::regprocedure)) > 0
                and position('bsi_route_unfiled' in (select prosrc from pg_proc where oid = 'public.log_rpa_derm_health()'::regprocedure)) > 0
               then 0 else 1 end)
  union all
  select 'CONTROL: the Boca Raton test reads the spellings it should',
         case when public.fn_city_is_boca_raton('Boca Raton') and public.fn_city_is_boca_raton('Boca Raton, FL')
                   and not public.fn_city_is_boca_raton('Delray Beach') and not public.fn_city_is_boca_raton('West Boca Raton')
              then 0 else 1 end
  union all
  select 'CONTROL: Grove Kosher (357) files with BSI', case when public.fn_client_files_with_bsi(357) then 0 else 1 end
)
select check_name, case when bad = 0 then 'ok' else 'FAIL: ' || bad end as status from checks;
