-- derm_visit_sheets_live_only_on_live_links.sql  (Trello #192, migration 2026-11-13_1600)
--
-- A LIVE Broward per-visit sheet (derm.manifest_visit_sheets, deleted_at IS NULL) must sit on a LIVE manifest AND on a
-- visit that is still linked to it. Otherwise it keeps its number in manifest_visit_sheets_sheet_no_uniq, and when the
-- visit is filed again its printed number is refused with 409: manifest 317956 (Diego, 2026-11-13) could not save
-- 4 of its 9 sheets after a delete and a re-file, and the form listed every client as "already filed".
--
-- Read only. Every row must read 'ok'. Run with: node scripts/q.js scripts/checks/derm_visit_sheets_live_only_on_live_links.sql <out.json>
--
-- CONTROLS, so a clean result means something:
--   * the rule's two triggers exist and are enabled, and record_manifest_visit_sheet carries the retired-number step.
--     Before 2026-11-13_1600 these rows FAIL (the rule was not there), so the check fails on the old state.
--   * the check can see live sheets at all (more than 0), so an empty table cannot pass for a clean one.
with live as (
  select s.manifest_id, s.visit_id, s.sheet_no, m.deleted_at as manifest_deleted_at,
         exists (select 1 from public.manifest_visits mv where mv.manifest_id = s.manifest_id and mv.visit_id = s.visit_id) as linked
    from derm.manifest_visit_sheets s
    join public.derm_manifests m on m.id = s.manifest_id
   where s.deleted_at is null
)
select 'live sheet on a deleted manifest' as check_name,
       count(*) filter (where manifest_deleted_at is not null) as n,
       case when count(*) filter (where manifest_deleted_at is not null) = 0 then 'ok' else 'FAIL' end as status,
       string_agg(manifest_id || ':' || visit_id || ':' || sheet_no, ', ') filter (where manifest_deleted_at is not null) as detail
  from live
union all
select 'live sheet on an unlinked visit',
       count(*) filter (where not linked),
       case when count(*) filter (where not linked) = 0 then 'ok' else 'FAIL' end,
       string_agg(manifest_id || ':' || visit_id || ':' || sheet_no, ', ') filter (where not linked)
  from live
union all
select 'CONTROL: live sheets exist to check',
       count(*),
       case when count(*) > 0 then 'ok' else 'FAIL' end,
       null
  from live
union all
select 'CONTROL: the delete and unlink triggers are on',
       count(*),
       case when count(*) = 2 then 'ok' else 'FAIL' end,
       string_agg(tgname, ', ')
  from pg_trigger
 where tgname in ('trg_zs_retire_visit_sheets_on_delete', 'trg_zs_retire_visit_sheet_on_unlink')
   and tgenabled = 'O' and not tgisinternal
union all
select 'CONTROL: a re-filed visit keeps its retired sheet number',
       (position('RE-FILED AFTER A DELETE OR AN UNLINK' in pg_get_functiondef('public.record_manifest_visit_sheet(bigint,bigint,text,text)'::regprocedure)) > 0)::int,
       case when position('RE-FILED AFTER A DELETE OR AN UNLINK' in pg_get_functiondef('public.record_manifest_visit_sheet(bigint,bigint,text,text)'::regprocedure)) > 0
            then 'ok' else 'FAIL' end,
       null;
