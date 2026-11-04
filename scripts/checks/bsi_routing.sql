-- Line-27 routing standing check (migrations 2026-11-03_1830, _1848_route_line27_followups, _2039_route_line27_alerts,
-- _2255_route_line27_alert_keys and 2026-11-04_0042_route_line27_alert_set_keys, Trello #169). Read-only, run by hand.
-- Healthy = every row 'ok'.
--   1. no line-27 visit of a client that files with BSI reaches the DERM fields, held queue, mismatch view or
--      derm.gdo_report_status; the DERM fields hold exactly the GDO-reporting visits with a live manifest of the
--      clients that do NOT file with BSI, and derm.gdo_report_status exactly those visits with or without a manifest,
--      each counted on its own (an inverted rule empties them and fails those rows today; a removed rule changes
--      nothing today and fails the CONTROL text row). The mismatch view has no such row: it holds 0 rows today, so no
--      count could show an inversion there, and the CONTROL text row is its only cover;
--   2. the two shapes the per-client rule cannot route, as log_rpa_derm_health raises them (bsi_route_gdo_and_boca /
--      bsi_route_other_city): line-27 WORK at a Boca Raton property of a client with a live GDO, and line-27 work at a
--      property elsewhere (or none) of a client that files with BSI. Line-27 work is the health items' own test: an
--      open job's own lines (at the job's property) or a GDO-reporting visit since the launch cutoff that was not
--      skipped or cancelled (its visit, invoice or job line; at the visit's property). An address with no work, such as
--      a billing address, never counts;
--   3. no line 27 on a routed client that Yan has not matched to its BSI record through leads.decide_client (a 'same'
--      decision links the record to the property). No decision was recorded on 2026-11-03, so line-27 WORK on ANY routed
--      client fails this row, Grove Kosher included (line 27 on a skipped or cancelled visit, or on a visit before the
--      cutoff, is not work); the five with no BSI record at all (081-TCE, 319-CAP, 135-BB,
--      361-SFG and Olympus) can never pass it. A matched client WITH line 27 is not a failure: the health item
--      bsi_route_unfiled reminds Yan to file it on BSI Online by hand until the bot exists;
--   4. no live property whose city is near "Boca Raton" without reading plainly as it: a spelling the one test misses
--      (an accent, "Boka", "City of Boca Raton", "West Boca Raton"), or one it reads as Boca Raton only by its prefix
--      ("Boca Raton West", "Boca Raton (Unincorporated)"). A person decides. This row repeats the helper's letters-only
--      normalization ON PURPOSE, to list the plain spellings; the routing itself only calls fn_city_is_boca_raton. (A
--      missed Boca Raton client has no GDO, so the health email also shows it as a no-permit item once line 27 is on an
--      open job of a client with a code, line27_no_permit_clients, or on a visit with a live manifest, gdo_no_permit;
--      line 27 on any other visit alone shows nothing.);
--   5. no live CCN sits on a client that files with DERM;
--   6. the newest health-logger run names no client that files with BSI among its line-27 no-permit clients. This
--      reads the logger's own output, so it tests the deployed code from the first run after 2026-11-04 09:00 UTC (a
--      run before _1830 had no such code); a client that started to file with BSI after that run would show here until
--      the next run (09:00 UTC, 04:00 ET in winter);
--   7. CONTROLS, on function code with its -- and /* */ comments removed (a string literal could still stand in for a
--      call): the rule is in the three views, the logger's no-permit exclusion and the rule's one Boca Raton test are
--      there; the MD5 OF THE LOGGER'S ROUTING BLOCK is the one 2026-11-04_0042 proved, which is what catches that fix
--      being undone or the block retyped (changed it on purpose? prove the new one as that VERIFY did, then update the
--      md5); the newest run is under 26 hours old and its no-permit items are the ones it counted; the DERM side is not
--      empty; the test reads the spellings it should; the rule says Grove Kosher (client 357) files with BSI.
-- Known, and not a failure: client 245 (no code, jobs archived) has a Boca Raton property (668, where its jobs are) and
-- a BILLING address in Beverly Hills marked Dade (396, no job, no visit). Line 27 on its jobs would raise only
-- bsi_route_unfiled (and fail the row "no line 27 on a routed client not matched to a BSI record"); a billing address
-- is not work.
-- The behaviour proofs (old bodies show the visits or miss the shape, new ones do not) are the VERIFY blocks of _1848
-- (its case c2 had no old-body control), _2039 (cases 1 to 4; case 5 had none), _2255 (A, B and D; E's control was the
-- pre-grant 42501; C had none) and 2026-11-04_0042 (A to D, each with the old body as a control; E is a regression
-- check), and for _1830 docs/migrations/2026-11-03_1830_route_line27_ccn_to_bsi_PROOF.sql. That every row can fail is
-- re-run by scripts/checks/bsi_routing_mutations.mjs (each case undone).
with routed as (
  select c.id from public.clients c where public.fn_client_files_with_bsi(c.id)
), w as (   -- line-27 work: the health items' test, kept identical
  select j.client_id, j.property_id from public.jobs j join public.line_items li on li.job_id = j.id and li.visit_id is null
   where public.fn_line_item_is_gdo_reporting(li.name) and j.job_status not in ('archived', 'destroyed')
  union all
  select v.client_id, v.property_id from public.visits v
   where v.deleted_at is null and v.visit_date >= public.rpa_launch_cutoff()
     and coalesce(v.visit_status, '') not in ('skipped', 'cancelled')
     and public.fn_visit_is_gdo_reporting(v.id)
), wk as (
  select w.client_id, coalesce(public.fn_city_is_boca_raton(p.city), false) as at_boca
    from w left join public.properties p on p.id = w.property_id
   where not exists (select 1 from public.v_non_customer_clients n where n.client_id = w.client_id)
), l27 as materialized (   -- the GDO-reporting visits of clients that file with DERM, counted on their own
  select v.id from public.visits v
   where v.deleted_at is null and public.fn_visit_is_gdo_reporting(v.id) and not public.fn_client_files_with_bsi(v.client_id)
     and exists (select 1 from public.clients c where c.id = v.client_id)
), dermable as (   -- of those, the ones the DERM fields should hold: a live manifest
  select l.id from l27 l
   where exists (select 1 from public.manifest_visits mv join public.derm_manifests m on m.id = mv.manifest_id and m.deleted_at is null
                  where mv.visit_id = l.id)
), src as (   -- function code with its -- and /* */ comments removed, so a comment can never stand in for a call
  select 'logger' as k, regexp_replace(regexp_replace(prosrc, '/[*].*?[*]/', '', 'g'), '--[^' || chr(10) || ']*', '', 'g') as code
    from pg_proc where oid = 'public.log_rpa_derm_health()'::regprocedure
  union all
  select 'rule', regexp_replace(regexp_replace(prosrc, '/[*].*?[*]/', '', 'g'), '--[^' || chr(10) || ']*', '', 'g')
    from pg_proc where oid = 'public.fn_client_files_with_bsi(bigint)'::regprocedure
), last_run as (
  select s.details, s.started_at from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.started_at desc, s.id desc limit 1
), checks as (
  select 'no routed client in the DERM fields' as check_name,
         (select count(*) from public.v_derm_portal_fields f where f.client_id in (select id from routed)) as bad
  union all
  select 'the DERM fields hold exactly the line-27 visits with a manifest of clients that file with DERM',
         (select count(*) from ((select f.visit_id from public.v_derm_portal_fields f except select d.id from dermable d)
                                union all
                                (select d.id from dermable d except select f.visit_id from public.v_derm_portal_fields f)) x)
  union all
  select 'derm.gdo_report_status holds exactly the line-27 visits of clients that file with DERM',
         (select count(*) from ((select s.visit_id from derm.gdo_report_status s except select l.id from l27 l)
                                union all
                                (select l.id from l27 l except select s.visit_id from derm.gdo_report_status s)) x)
  union all
  select 'no routed client held in the DERM queue',
         (select count(*) from public.v_derm_portal_queue_held h join public.visits v on v.id = h.visit_id
           where v.client_id in (select id from routed))
  union all
  select 'no routed client in the line-27 / DERM-required mismatch view',
         (select count(*) from public.v_gdo_reporting_derm_mismatch m where m.client_id in (select id from routed))
  union all
  select 'no routed client in derm.gdo_report_status',
         (select count(*) from derm.gdo_report_status s where s.client_id in (select id from routed))
  union all
  select 'no line-27 work at a Boca Raton property of a client with a live GDO',
         (select count(distinct wk.client_id) from wk
           where wk.at_boca
             and exists (select 1 from public.gdos g
                          where g.client_id = wk.client_id and g.permit_type = 'GDO' and g.status in ('ACTIVE', 'EXPIRED')))
  union all
  select 'no line-27 work at a property elsewhere of a client that files with BSI',
         (select count(distinct wk.client_id) from wk where not wk.at_boca and wk.client_id in (select id from routed))
  union all
  select 'no line 27 on a routed client not matched to a BSI record',
         (select count(*) from public.clients c
           where c.id in (select id from routed) and c.id in (select client_id from wk)
             and not exists (select 1 from leads.establishments e join public.properties p on p.id = e.property_id
                              where p.client_id = c.id and p.deleted_at is null and e.status = 'ACTIVE'))
  union all
  select 'no live property whose city is near Boca Raton without reading plainly as it',
         (select count(*) from public.properties p
           where p.deleted_at is null
             and (translate(lower(p.city), 'áàâäãåéèêëíìîïóòôöõúùûüñç', 'aaaaaaeeeeiiiiooooouuuunc') ~ 'bo[ck]+a|raton'
                  or public.fn_city_is_boca_raton(p.city))
             and regexp_replace(lower(p.city), '[^a-z]+', '', 'g') not in ('bocaraton', 'bocaratonfl', 'bocaratonflorida'))
  union all
  select 'no live CCN on a client that files with DERM',
         (select count(*) from public.gdos g
           where g.permit_type = 'CCN' and g.status in ('ACTIVE', 'EXPIRED')
             and not public.fn_client_files_with_bsi(g.client_id))
  union all
  select 'the newest health-logger run names no client that files with BSI as a line-27 no-permit client',
         (select count(*) from last_run r cross join lateral jsonb_array_elements(r.details -> 'reasons') e
            join public.clients c on c.client_code = e ->> 'client_code'
           where e ? 'jobs' and public.fn_client_files_with_bsi(c.id))
  union all
  select 'CONTROL: the rule is in the three views and the logger''s no-permit exclusion, with the one Boca Raton test in the rule',
         (case when position('fn_client_files_with_bsi' in pg_get_viewdef('public.v_derm_portal_fields'::regclass)) > 0 then 0 else 1 end
        + case when position('fn_client_files_with_bsi' in pg_get_viewdef('public.v_gdo_reporting_derm_mismatch'::regclass)) > 0 then 0 else 1 end
        + case when position('fn_client_files_with_bsi' in pg_get_viewdef('derm.gdo_report_status'::regclass)) > 0 then 0 else 1 end
        + case when position('not public.fn_client_files_with_bsi(c.id)' in (select code from src where k = 'logger')) > 0 then 0 else 1 end
        + case when position('fn_city_is_boca_raton' in (select code from src where k = 'rule')) > 0 then 0 else 1 end)
  union all
  select 'CONTROL: the logger''s routing block is the one 2026-11-04_0042 proved',
         (select case when md5(substring(code from position('into rc' in code)
                                         for position('if jsonb_array_length(rc)' in code) - position('into rc' in code)))
                           = '71aca9d1f9424a736c817b9b197578d6' then 0 else 1 end
            from src where k = 'logger')
  union all
  select 'CONTROL: the newest logger run is under 26 hours old and its no-permit items are the ones it counted',
         coalesce((select case when r.started_at > now() - interval '26 hours'
                                    and (select count(*) from jsonb_array_elements(r.details -> 'reasons') e where e ? 'jobs')
                                        = (r.details ->> 'line27_no_permit_clients')::int then 0 else 1 end
                     from last_run r), 1)
  union all
  select 'CONTROL: the DERM side is not empty (the DERM fields and derm.gdo_report_status hold visits)',
         case when exists (select 1 from public.v_derm_portal_fields) and exists (select 1 from derm.gdo_report_status) then 0 else 1 end
  union all
  select 'CONTROL: the Boca Raton test reads the spellings it should',
         case when public.fn_city_is_boca_raton('Boca Raton') and public.fn_city_is_boca_raton('Boca Raton, FL')
                   and not public.fn_city_is_boca_raton('Delray Beach') and not public.fn_city_is_boca_raton('West Boca Raton')
              then 0 else 1 end
  union all
  select 'CONTROL: Grove Kosher (357) files with BSI', case when public.fn_client_files_with_bsi(357) then 0 else 1 end
)
select check_name, case when bad = 0 then 'ok' else 'FAIL: ' || bad end as status from checks;
