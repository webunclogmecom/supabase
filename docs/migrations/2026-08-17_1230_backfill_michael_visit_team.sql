-- 2026-08-17_1230 — backfill Michael Escobar onto the visits Jobber already assigned him
--
-- Follows 2026-08-17_1210, which created employee 40 and the Jobber bridge row. Until
-- that link existed, webhook-jobber's syncVisitTeamFromJobber resolved his user id to
-- null and SILENTLY dropped him from every crew (it skips unresolvable members with no
-- error and no log).
--
-- ⚠ WHY NOBODY SAW IT. He is always paired with Aaron or Anthony, so each visit still
-- showed *a* driver and nothing looked broken. He was simply erased from the crew.
-- Only Yannick noticed, by looking for him specifically. A visit assigned to him ALONE
-- would have gone fully crewless, which is the louder version of the same bug.
--
-- Source of truth is Jobber, queried live: 10 visits between 2026-08-12 and 2026-08-17
-- carry "Michael Escobar" in assignedUsers. All 10 resolve to our visit rows via
-- entity_source_links, 0 unresolved.
--
-- ⚠ visit_team is INSERT-only here. We do NOT delete or reorder existing members: the
-- other crew resolved correctly and must be left exactly as-is. We also do NOT touch
-- visits.assigned_driver_id — Michael joined existing crews, he is not their primary,
-- and rewriting the primary would change the displayed driver on 10 completed visits.
-- Rule 5: guarded by NOT EXISTS, so a re-run is a no-op.
insert into public.visit_team (visit_id, employee_id)
select v.id, 40
from public.v_visits_live v
where v.id in (6339,6664,6995,6587,7768,7769,6791,6788,6741,6726)
  and not exists (select 1 from public.visit_team t where t.visit_id = v.id and t.employee_id = 40);

do $do$
declare n int; missing int;
begin
  select count(*) into n from public.visit_team
   where employee_id = 40 and visit_id in (6339,6664,6995,6587,7768,7769,6791,6788,6741,6726);
  if n <> 10 then raise exception 'expected Michael on 10 visits, found %', n; end if;

  -- the other crew must have survived untouched
  select count(*) into missing from (
    select visit_id from public.visit_team
     where visit_id in (6339,6664,6995,6587,7768,7769,6791,6788,6741,6726)
     group by visit_id having count(*) < 2) z;
  if missing > 0 then raise exception '% visits lost their original crew', missing; end if;

  raise notice 'Michael added to 10 visits, all original crew intact';
end
$do$;
