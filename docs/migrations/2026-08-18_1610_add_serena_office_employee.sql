-- ============================================================================
-- 2026-08-18_1610 - add Serena as an office employee, linked to Jobber
-- ============================================================================
-- Fred: *"create the employee rows for serena. Which is a new employee too, for the office
-- same level as Diego"*.
--
-- She surfaced in the 2026-08-18 Jobber team audit as one of three ACTIVATED Jobber users
-- with no employee row at all (the others were Emilie Avot and Noa, deliberately NOT created
-- here: only Serena was asked for).
--
-- IDENTITY, taken from Jobber rather than guessed, and read with a positive control so a
-- null would have meant something (control: user 4255910 returned "Michael Escobar /
-- ACTIVATED"):
--   Serena Natali   serena@unclogme.com   ACTIVATED   gid://Jobber/User/4215647
--
-- "SAME LEVEL AS DIEGO" is taken literally from Diego's own row (emp 28), which is
-- role='Admin', access_level='dev'. Aaron (26) and Yannick (27) are the same shape. There is
-- no CHECK on either column, so this is a convention, not a constraint: read a peer row
-- rather than inventing a value.
--
-- BOTH HALVES, because one without the other is useless (see the employee-sync section of
-- CLAUDE.md):
--   1. public.employees                 - puts her in the app pickers (ACTIVE only)
--   2. public.entity_source_links       - the Jobber bridge, WITHOUT which every Jobber-side
--      assignment for her is silently dropped by syncVisitTeamFromJobber
-- source_id is the FULL base64 GID, never the numeric id from the manage_team URL. All 18
-- existing employee links store that form.
--
-- NAMING: stored as the full "Serena Natali", matching Jobber. The table is mixed (most
-- staff are first-name-only; Michael Escobar was set to his full name by Fred on 2026-08-18),
-- and there is no enforced convention, so new rows follow Jobber. full_name is UNIQUE, which
-- a full name also protects better than a bare first name.
--
-- Rule 1 (source-agnostic schema): no jobber_* column is added; identity lives in
-- entity_source_links, which is what that table is for.
-- Rule 5 (idempotent): both inserts are guarded, so a re-run is a no-op.
-- Rule 8 (audit): public.employees carries the audit trigger, so the insert is captured.
-- entity_source_links is a sync bridge and is audit opt-OUT by design.
-- ============================================================================

do $add$
declare
  v_gid text := 'Z2lkOi8vSm9iYmVyL1VzZXIvNDIxNTY0Nw==';   -- gid://Jobber/User/4215647
  v_emp_id bigint;
begin
  -- already linked? then there is nothing to do.
  select entity_id into v_emp_id
    from public.entity_source_links
   where entity_type='employee' and source_system='jobber' and source_id = v_gid;
  if v_emp_id is not null then
    raise notice 'Jobber user 4215647 already links to employee %; nothing to do', v_emp_id;
    return;
  end if;

  -- guard against a row created by hand, or by the Samsara feed, in the meantime
  select id into v_emp_id from public.employees
   where lower(full_name) in ('serena', 'serena natali')
      or lower(coalesce(email,'')) = 'serena@unclogme.com'
   limit 1;

  if v_emp_id is null then
    insert into public.employees (full_name, role, status, email, access_level, color_hex)
    values ('Serena Natali', 'Admin', 'ACTIVE', 'serena@unclogme.com', 'dev', '#14B8A6')
    returning id into v_emp_id;
    raise notice 'created employee % (Serena Natali)', v_emp_id;
  else
    raise notice 'reusing existing employee %', v_emp_id;
  end if;

  insert into public.entity_source_links
    (entity_type, entity_id, source_system, source_id, source_name, match_method, match_confidence)
  values ('employee', v_emp_id, 'jobber', v_gid, 'Serena Natali', 'manual', 1);
end
$add$;

-- ============================================================================
-- VERIFY
-- ============================================================================
do $verify$
declare fail text := ''; v_emp record; v_links int; v_unlinked int; v_active int;
begin
  select e.* into v_emp
    from public.employees e
    join public.entity_source_links l
      on l.entity_type='employee' and l.entity_id=e.id and l.source_system='jobber'
   where l.source_id = 'Z2lkOi8vSm9iYmVyL1VzZXIvNDIxNTY0Nw==';

  if v_emp.id is null then fail := fail || 'Serena is not linked to Jobber 4215647; '; end if;
  if v_emp.status <> 'ACTIVE' then
    fail := fail || format('status is %s, must be ACTIVE or the pickers hide her; ', v_emp.status);
  end if;
  if v_emp.role <> 'Admin' or v_emp.access_level <> 'dev' then
    fail := fail || format('role/access is %s/%s, expected Admin/dev to match Diego; ', v_emp.role, v_emp.access_level);
  end if;
  if coalesce(v_emp.email,'') <> 'serena@unclogme.com' then
    fail := fail || 'email not set; ';
  end if;

  -- exactly one jobber link, or findEntityBySourceId becomes ambiguous
  select count(*) into v_links from public.entity_source_links
   where entity_type='employee' and source_system='jobber'
     and source_id='Z2lkOi8vSm9iYmVyL1VzZXIvNDIxNTY0Nw==';
  if v_links <> 1 then fail := fail || format('expected 1 jobber link, found %s; ', v_links); end if;

  -- Fred's standing rule must still hold for the whole table
  select count(*) into v_active from public.employees where status='ACTIVE';
  select count(*) into v_unlinked from public.employees e
   where e.status='ACTIVE'
     and not exists (select 1 from public.entity_source_links l
                      where l.entity_type='employee' and l.entity_id=e.id and l.source_system='jobber');
  if v_unlinked <> 0 then
    fail := fail || format('%s of %s ACTIVE employees have no Jobber link; ', v_unlinked, v_active);
  end if;

  if fail <> '' then raise exception 'VERIFY FAILED: %', fail; end if;
  raise notice 'Serena added and linked; all ACTIVE employees carry a Jobber link';
end
$verify$;

select e.id, e.full_name, e.role, e.access_level, e.status, e.email,
       (select count(*) from public.entity_source_links l
         where l.entity_type='employee' and l.entity_id=e.id and l.source_system='jobber') as jobber_links,
       (select count(*) from public.employees where status='ACTIVE')                        as active_employees,
       (select count(*) from public.employees e2 where e2.status='ACTIVE'
          and not exists (select 1 from public.entity_source_links l2
                           where l2.entity_type='employee' and l2.entity_id=e2.id
                             and l2.source_system='jobber'))                                as active_without_jobber_link
  from public.employees e
 where e.email = 'serena@unclogme.com';
