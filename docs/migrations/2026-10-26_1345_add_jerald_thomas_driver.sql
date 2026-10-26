-- ============================================================================
-- 2026-10-26_1345 — add driver Jerald Thomas and bridge him to Jobber
-- ============================================================================
-- Serena in Slack (#C0AMWRK02SW, 2026-10-26): "We have a new night driver, Jerald Thomas. I added him in Jobber but I
-- can't add him on the HR app. Could you please add him, he starts tonight." Fred: "add him to our db".
--
-- Same shape as 2026-08-17_1210 (Michael Escobar), because nothing syncs employees from Jobber: a new Jobber user arrives
-- here only by hand, and without the entity_source_links row webhook-jobber's syncVisitTeamFromJobber drops him from every
-- crew with no error. The HR App has no "add person" (hr.update_employee only edits), which is why Serena could not.
--
-- IDENTITY, read from Jobber (user 4448278, created 2026-10-25T14:38Z, status ACTIVATED, not an admin):
--   name   Jerald Thomas
--   GID    Z2lkOi8vSm9iYmVyL1VzZXIvNDQ0ODI3OA==   (the FULL base64 GID; the bare 4448278 in the manage_team URL never matches)
-- His email and phone are set by a separate statement that is NOT in this public repo (they are a person's private contact
-- details); they match Jobber's.
--
-- CHOICES:
--   full_name 'Jerald Thomas' (match Jobber; no enforced convention, Michael's record also carries his full name)
--   role 'Technician' (the DUMP driver picker lists role='Technician'), access_level 'field' (the Field group defaults
--   apply; D17: a field person cannot be given View or Edit), hire_date 2026-10-26 ("he starts tonight"),
--   payroll_week_start_day left at the default (5, Friday).
--   color_hex '#2563EB' (blue-600, a free swatch of the HR App palette), measured against the four axes of Building Apps
--   rule 4b: nearest current person CIEDE2000 18.7, DUMP reserved hues 39.7, zone fills/dots and truck colours 10.0;
--   as a DUMP driver name on #050506 3.94:1 (the names are 24-30px, large text), white avatar letter 5.17:1.
--   Changeable in the HR App (Edit details > Color).
--
-- Jobber has assigned him no visit yet: 263 visits from 2026-10-24 to 2026-12-31 scanned live, 0 carry him (control: the
-- same scan finds Michael on 26), so there is no crew to backfill.
--
-- NOT DONE HERE, an admin decides in the HR App: his hourly rate and his two bonus amounts. Until then he earns $0 bonus and
-- log_hr_bonus_health lists hr_bonus:no_amount for him (the 2026-10-19_1200 rule: no company fallback).
--
-- Rule 1: identity in entity_source_links, no jobber_* column. Rule 5: guarded, a re-run is a no-op.
-- Rule 8: public.employees is audited (audit_employees); entity_source_links is a sync bridge, audit opt-out by design.
-- ============================================================================

do $do$
declare v_emp_id bigint; v_gid text := 'Z2lkOi8vSm9iYmVyL1VzZXIvNDQ0ODI3OA==';
begin
  select entity_id into v_emp_id
    from public.entity_source_links
   where entity_type='employee' and source_system='jobber' and source_id = v_gid;
  if v_emp_id is not null then
    raise notice 'Jobber user % already links to employee % - nothing to do', v_gid, v_emp_id;
    return;
  end if;

  select id into v_emp_id from public.employees where lower(full_name) in ('jerald', 'jerald thomas') limit 1;

  if v_emp_id is null then
    insert into public.employees (full_name, role, status, access_level, color_hex, hire_date)
    values ('Jerald Thomas', 'Technician', 'ACTIVE', 'field', '#2563EB', date '2026-10-26')
    returning id into v_emp_id;
    raise notice 'created employee % (Jerald Thomas)', v_emp_id;
  else
    raise notice 'reusing existing employee %', v_emp_id;
  end if;

  insert into public.entity_source_links
    (entity_type, entity_id, source_system, source_id, source_name, match_method, match_confidence)
  values ('employee', v_emp_id, 'jobber', v_gid, 'Jerald Thomas', 'manual', 1);
end
$do$;

-- ============================================================================
-- VERIFY
-- ============================================================================
do $do$
declare v_emp record; v_n int; v_unlinked int;
begin
  select e.* into v_emp
    from public.employees e
    join public.entity_source_links l on l.entity_type='employee' and l.entity_id=e.id and l.source_system='jobber'
   where l.source_id = 'Z2lkOi8vSm9iYmVyL1VzZXIvNDQ0ODI3OA==';
  if v_emp.id is null then raise exception 'Jerald is not linked to Jobber 4448278'; end if;
  if v_emp.status <> 'ACTIVE' or v_emp.access_level <> 'field' or v_emp.role <> 'Technician' then
    raise exception 'employee % has status %, level %, role %', v_emp.id, v_emp.status, v_emp.access_level, v_emp.role;
  end if;

  select count(*) into v_n from public.entity_source_links
   where entity_type='employee' and source_system='jobber' and source_id='Z2lkOi8vSm9iYmVyL1VzZXIvNDQ0ODI3OA==';
  if v_n <> 1 then raise exception 'expected 1 jobber link, found %', v_n; end if;

  -- his colour is unique among ACTIVE people
  select count(*) into v_n from public.employees where status='ACTIVE' and upper(color_hex) = '#2563EB';
  if v_n <> 1 then raise exception '#2563EB is held by % ACTIVE people', v_n; end if;

  -- the standing rule: every ACTIVE employee has a Jobber link
  select count(*) into v_unlinked from public.employees e
   where e.status='ACTIVE'
     and not exists (select 1 from public.entity_source_links l
                      where l.entity_type='employee' and l.entity_id=e.id and l.source_system='jobber');
  if v_unlinked <> 0 then raise exception '% ACTIVE employees have no Jobber link', v_unlinked; end if;

  raise notice 'employee % (%) ACTIVE field Technician, 1 jobber link, every ACTIVE employee linked', v_emp.id, v_emp.full_name;
end
$do$;
