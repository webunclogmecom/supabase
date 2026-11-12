-- No close-out row may call a visit's time settled while another visit was completed inside its stay (Trello vpF5PLQj,
-- 2026-11-12; Fred: "do the nightly fix").
-- The nightly's close-out (plan 5.5 b) holds a kept visit for a person (proposed, method shared_tap) when another
-- completed visit of the same truck has its completion ("tap") inside the stay. Until
-- 2026-11-12_1330_time_on_site_recheck_read_taps it saw only visits dated one day around the run, so a visit completed
-- days after its own date was missed (8853 / 8886, corrected by 2026-11-12_1140).
-- Check, must be 0:
--   settled_with_tap  current applied nightly_self rows whose stay (the row's new_* times, else the visit's) holds the
--                     completion of another completed, not deleted visit of the same truck, ANY date, ANY client.
-- Positive control: the same test over SUPERSEDED rows must find rows 2150 (8853, tap 8854) and 2188 (8886, tap 8882),
-- the two S6 rows this rule exists for. If it does not, the test is blind and its 0 proves nothing.
-- Healthy = status 'ok'. Read-only. Run as owner (Management API).
with hits as (
  select l.id, l.visit_id, l.superseded_at is null as is_current, o.id as other
    from public.visit_time_on_site_corrections l
    join public.visits v on v.id = l.visit_id
    join public.visits o on o.id <> v.id and o.vehicle_id = coalesce(l.new_vehicle_id, v.vehicle_id)
     and o.visit_status = 'completed' and o.deleted_at is null
     and o.completed_at between coalesce(l.new_arrival, v.actual_arrival_at) and coalesce(l.new_departure, v.actual_departure_at)
   where l.status = 'applied' and l.method = 'nightly_self'
), c as (
  select (select count(distinct id) from hits where is_current) as settled_with_tap,
         (select jsonb_agg(distinct jsonb_build_object('row', id, 'visit', visit_id, 'other', other)) from hits where is_current) as detail,
         (select count(*) from hits where not is_current and (id, visit_id, other) in ((2150, 8853, 8854), (2188, 8886, 8882))) as control_found
)
select case when control_found < 2 then 'control_failed'
            when settled_with_tap > 0 then 'fail'
            else 'ok' end as status,
       settled_with_tap, control_found, detail
  from c;
