-- ============================================================================
-- 2026-08-17_1210 — add driver Michael Escobar and bridge him to Jobber
-- ============================================================================
-- Yannick in #general, 2026-08-17: *"for some reason Michael Escobar does not show
-- on calendar, he has been in jobber for few weeks"*. Fred: *"I see no Michael
-- Escobar ... I see you mean the new Driver."*
--
-- 🛑 ROOT CAUSE, AND IT IS NOT A CALENDAR BUG. WE DO NOT SYNC EMPLOYEES FROM JOBBER
-- AT ALL. `sync-jobber-poll`'s ENTITIES list covers clients, jobs, visits, invoices,
-- properties and quotes; there is no users entity, and `webhook-jobber` has no user
-- handler (grep for handleUser/USER_UPDATE returns nothing). A new Jobber team member
-- therefore NEVER arrives on his own. Employees are hand-created, and this is the
-- manual step nobody knew was required.
--
-- 🛑 WHY HE WAS INVISIBLE RATHER THAN ERRORING. Visits DO pull
-- `assignedUsers { nodes { id } }`, and webhook-jobber's syncVisitTeamFromJobber does:
--     for (const member of nodes) {
--       const empId = await findEntityBySourceId('employee','jobber', member.id)
--       if (empId) want.add(empId)          // <-- unknown user SILENTLY skipped
--     }
--     delete from visit_team where visit_id = ...   // wipes the crew FIRST
--     insert the resolved ids
-- With no bridge row his id resolves to null and is dropped with no error and no log.
-- A visit assigned only to him ends up with an EMPTY visit_team. That is exactly the
-- "does not show on calendar" symptom, and it has been true for the weeks he has been
-- in Jobber. The Calendar team picker lists ACTIVE employees, so he could not appear
-- there either: measured, the picker showed exactly the 7 ACTIVE rows.
--
-- ⇒ THE BRIDGE ROW IS THE LOAD-BEARING HALF. An employees row alone puts him in the
-- picker but still drops every Jobber-side assignment.
--
-- IDENTITY, taken from Jobber rather than guessed (user 4255910):
--   name  Michael Escobar     email michaelescobar1606@gmail.com
--   status ACTIVATED          isAccountAdmin false
--   GID   Z2lkOi8vSm9iYmVyL1VzZXIvNDI1NTkxMA==
--
-- ⚠ NAMING FOLLOWS THE EXISTING CONVENTION, WHICH IS NOT OBVIOUS. Every ACTIVE driver
-- is stored first-name-only (Mark, Anthony, Grecia, Aaron), and the FULL names in the
-- table are all INACTIVE duplicates of those same people ("Mark noltion" id 36,
-- "Anthony Clark" id 38). So the active record is "Michael". Storing "Michael Escobar"
-- would read as the retired-duplicate shape and would look wrong in the picker beside
-- the others.
--
-- ⚠ `source_id` MUST be the FULL GID, not the numeric id. Measured: all 16 existing
-- employee->jobber links store `Z2lkOi8vSm9iYmVyL1VzZXIv...`. The bare 4255910 that
-- appears in the manage_team URL would never match.
--
-- Rule 1 (source-agnostic schema): no jobber_* column is added; identity goes in
-- entity_source_links, which is what that table exists for.
-- Rule 8 (audit): public.employees carries the audit trigger already, so the insert is
-- captured. entity_source_links is a sync bridge and is audit opt-OUT by design.
-- Rule 5 (idempotent): both inserts are guarded, so a re-run is a no-op.
-- ============================================================================

do $do$
declare v_emp_id bigint; v_gid text := 'Z2lkOi8vSm9iYmVyL1VzZXIvNDI1NTkxMA==';
begin
  -- already linked? then nothing to do
  select entity_id into v_emp_id
    from public.entity_source_links
   where entity_type='employee' and source_system='jobber' and source_id = v_gid;
  if v_emp_id is not null then
    raise notice 'Jobber user % already links to employee % — nothing to do', v_gid, v_emp_id;
    return;
  end if;

  -- guard against a same-named row created by hand in the meantime
  select id into v_emp_id from public.employees
   where lower(full_name) in ('michael','michael escobar') limit 1;

  if v_emp_id is null then
    insert into public.employees (full_name, role, status, email, access_level, color_hex)
    values ('Michael', 'Technician', 'ACTIVE', 'michaelescobar1606@gmail.com', 'field', '#0EA5E9')
    returning id into v_emp_id;
    raise notice 'created employee % (Michael)', v_emp_id;
  else
    raise notice 'reusing existing employee %', v_emp_id;
  end if;

  insert into public.entity_source_links
    (entity_type, entity_id, source_system, source_id, source_name, match_method, match_confidence)
  values ('employee', v_emp_id, 'jobber', v_gid, 'Michael Escobar', 'manual', 1);

  raise notice 'linked employee % to Jobber %', v_emp_id, v_gid;
end
$do$;

-- ============================================================================
-- VERIFY
-- ============================================================================
do $do$
declare v_emp record; v_link int; v_active int;
begin
  select e.* into v_emp
    from public.employees e
    join public.entity_source_links l
      on l.entity_type='employee' and l.entity_id=e.id and l.source_system='jobber'
   where l.source_id = 'Z2lkOi8vSm9iYmVyL1VzZXIvNDI1NTkxMA==';

  if v_emp.id is null then raise exception 'Michael is not linked to Jobber 4255910'; end if;
  if v_emp.status <> 'ACTIVE' then
    raise exception 'employee % is %, must be ACTIVE or the Calendar picker hides him', v_emp.id, v_emp.status;
  end if;

  -- exactly one jobber link, or findEntityBySourceId becomes ambiguous
  select count(*) into v_link from public.entity_source_links
   where entity_type='employee' and source_system='jobber'
     and source_id='Z2lkOi8vSm9iYmVyL1VzZXIvNDI1NTkxMA==';
  if v_link <> 1 then raise exception 'expected 1 jobber link, found %', v_link; end if;

  -- the picker should now list 8 ACTIVE employees (it showed 7 before)
  select count(*) into v_active from public.employees where status='ACTIVE';
  if v_active < 8 then raise exception 'only % ACTIVE employees; expected at least 8', v_active; end if;

  raise notice 'employee % (%) ACTIVE, 1 jobber link, % ACTIVE employees total',
    v_emp.id, v_emp.full_name, v_active;
end
$do$;
