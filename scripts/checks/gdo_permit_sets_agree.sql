-- "Which GDO permits does this client have" must give ONE answer everywhere a person reads it.
-- Compares the DB readers with public.dump_visit_gdo_numbers (ACTIVE, ^GDO-[0-9]+$, sorted by number):
--   derm.visits.gdo_number              (DERM Tracker, joined ", " since 2026-10-21_1715, Trello YAAcQNtJ)
--   ops.v_calendar_visit.gdo_permits    (Visit Calendar, since 2026-09-28_1515)
-- The pdf-service _active_gdos and derm.record_generated_sheet_preview are checked against generated sheets by
-- 2026-09-28_1435's VERIFY 4; they are not readable from here.
-- Healthy = one row, status 'ok'. Anything else names what drifted. Read-only.
with canon as (
  select d.visit_id, nullif(array_to_string(d.gdo_numbers, ', '), '') as permits
  from public.dump_visit_gdo_numbers((select array_agg(id) from public.visits where deleted_at is null)) d
),
derm_bad as (
  select dv.id from derm.visits dv join canon c on c.visit_id = dv.id
  where dv.gdo_number is distinct from c.permits
),
cal_bad as (
  select cv.id from ops.v_calendar_visit cv join canon c on c.visit_id = cv.id
  where (select nullif(string_agg(p ->> 'gdo_number', ', ' order by ord), '')
           from jsonb_array_elements(cv.gdo_permits) with ordinality as t(p, ord)) is distinct from c.permits
),
control as (
  -- positive control: Casa Neos's visit 6570 must read its three permits in both readers
  select (select gdo_number from derm.visits where id = 6570) as derm_6570,
         (select string_agg(p ->> 'gdo_number', ', ') from ops.v_calendar_visit cv,
                 jsonb_array_elements(cv.gdo_permits) p where cv.id = 6570) as cal_6570
)
select case
         when ctl.derm_6570 is distinct from 'GDO-10877, GDO-15062, GDO-16389' then 'CONTROL FAILED: derm.visits 6570 = ' || coalesce(ctl.derm_6570, 'null')
         when ctl.cal_6570 is distinct from 'GDO-10877, GDO-15062, GDO-16389' then 'CONTROL FAILED: v_calendar_visit 6570 = ' || coalesce(ctl.cal_6570, 'null')
         when (select count(*) from derm_bad) + (select count(*) from cal_bad) > 0 then 'DRIFT'
         else 'ok' end as status,
       (select count(*) from canon) as visits_checked,
       (select count(*) from derm_bad) as derm_visits_differ,
       (select array_agg(id order by id) from (select id from derm_bad limit 20) x) as derm_sample,
       (select count(*) from cal_bad) as calendar_differ,
       (select array_agg(id order by id) from (select id from cal_bad limit 20) x) as calendar_sample
from control ctl;
