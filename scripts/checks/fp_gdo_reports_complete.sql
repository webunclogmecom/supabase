-- fp_gdo_reports_complete.sql: every GDO report the county took (a SUCCESS or a portal confirmation, not a dry run) on a
-- GDO permit that is not INACTIVE shows on its visit in the Field Portal (customer.gdo_reports, reported = true).
-- Why (2026-11-03, Trello ObKqzi47): the view joined ACTIVE permits only, so the filings on an EXPIRED permit (Fred
-- 2026-10-30: "file it with the expired one") were hidden from the client: 7849 and 7992. Fixed by 2026-11-03_1600.
-- Run read-only as the owner (Management API). Expect: missing = [] and control_reported_rows > 0 (a zero control means
-- the instrument read nothing, not that all is well). On the pre-1600 view this returns missing = [7849, 7992].
select json_build_object(
  'missing', coalesce((
    select json_agg(json_build_object('visit_id', s.visit_id, 'submission', s.id, 'gdo', g.gdo_number, 'permit_status', g.status) order by s.visit_id)
      from public.derm_portal_submissions s
      join public.gdos g on g.id = s.gdo_id and g.status <> 'INACTIVE' and g.gdo_number ~ '^GDO-[0-9]+$'
      join public.visits v on v.id = s.visit_id and v.deleted_at is null
     where not s.dry_run and (s.status = 'SUCCESS' or s.portal_confirmation is not null)
       and public.fn_visit_is_gdo_reporting(v.id)
       and not exists (select 1 from customer.gdo_reports r where r.visit_id = s.visit_id and r.gdo_id = s.gdo_id and r.reported)), '[]'::json),
  'control_reported_rows', (select count(*) from customer.gdo_reports r where r.reported),
  'expired_rows_without_a_filing', (select count(*) from customer.gdo_reports r join public.gdos g on g.id = r.gdo_id where g.status = 'EXPIRED' and not r.reported)
) as j;
