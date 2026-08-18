-- ============================================================================
-- 2026-08-18_1545 - one Michael, one row, both source links
-- ============================================================================
-- Fred: *"why do we have 2 michaels? it should be only one, which is michael escobar
-- https://secure.getjobber.com/manage_team/NDI1NTkxMA== , and all the drivers and team
-- members should have a link to their Jobber reference."*
--
-- WHY THERE WERE TWO, AND IT WAS NOT A PERSON DOUBLE-ENTERING. Two different source
-- systems each produced a row for the same human, an hour apart:
--   emp 40 "Michael"          2026-08-17 14:32 ET  jobber  gid://Jobber/User/4255910
--                              created by 2026-08-17_1210, match_method = manual
--   emp 41 "Michael Escobar"  2026-08-17 15:39 ET  samsara 60524052
--                              match_method = webhook_new, i.e. AUTO-CREATED by the
--                              Samsara driver feed, which does not reconcile against
--                              existing employees before inserting.
--
-- The other drivers show what the correct end state looks like: Grecia, Mark and Anthony
-- each carry a jobber link AND a samsara link on ONE row. Michael was the same person split
-- across two rows. `Mark noltion` (36) and `Anthony Clark` (38) are the residue of this
-- happening before and being cleaned up the same way: INACTIVE, no links left.
--
-- WHAT THIS DOES
--   1. moves the samsara link from 41 to 40, so one row carries both identities
--   2. renames 40 to "Michael Escobar", per Fred naming the surviving record
--   3. retires 41 (status INACTIVE). Rule 6: soft delete, never a hard delete.
-- Employee 41 holds 0 visit_team rows and 0 visits as assigned_driver, so nothing detaches.
-- Employee 40 holds 15 visit_team rows, which is why 40 is the survivor rather than 41.
--
-- BACKUP FIRST: backups/2026-08-18_michael_employee_consolidation.json (outside the repo).
-- public.entity_source_links carries ZERO triggers, so re-pointing a link row leaves no
-- record of any kind, and that file is the only restore path.
--
-- AUDIT (rule 8): public.employees already carries the audit trigger, so the rename and the
-- retirement are captured with old_row/new_row. entity_source_links is a sync bridge and is
-- audit opt-OUT by design, hence the backup above.
--
-- NAMING: this makes Michael the only ACTIVE employee stored under a full name; the other
-- seven are first-name-only. That is Fred choosing the surviving record explicitly, and it
-- matches what Jobber itself displays. Flagged rather than silently generalised: if the
-- convention should become "full name from Jobber" for everyone, that is a separate change.
-- ============================================================================

do $consolidate$
declare
  v_jobber_gid text := 'Z2lkOi8vSm9iYmVyL1VzZXIvNDI1NTkxMA==';   -- gid://Jobber/User/4255910
  v_moved int; v_renamed int; v_retired int;
begin
  -- Preconditions, re-asserted so this cannot fire against a world that has moved.
  if not exists (select 1 from public.entity_source_links
                  where entity_type='employee' and entity_id=40
                    and source_system='jobber' and source_id=v_jobber_gid) then
    raise exception 'employee 40 does not hold the Jobber link for user 4255910; refusing';
  end if;
  if not exists (select 1 from public.entity_source_links
                  where entity_type='employee' and entity_id=41 and source_system='samsara') then
    raise exception 'employee 41 has no samsara link; this is not the situation described';
  end if;
  if exists (select 1 from public.entity_source_links
              where entity_type='employee' and entity_id=40 and source_system='samsara') then
    raise exception 'employee 40 already has a samsara link; moving the other would duplicate it';
  end if;
  if (select count(*) from public.visit_team where employee_id=41) <> 0 then
    raise exception 'employee 41 now has visit_team rows; re-check before retiring it';
  end if;

  update public.entity_source_links
     set entity_id = 40
   where entity_type='employee' and entity_id=41 and source_system='samsara';
  get diagnostics v_moved = row_count;

  -- ORDER MATTERS: employees.full_name is UNIQUE and 41 is holding the name we want.
  -- Retire 41 and free the string FIRST, or the rename below raises 23505. The marker is added
  -- rather than blanking the name so the row stays identifiable in the audit trail.
  update public.employees
     set status = 'INACTIVE',
         full_name = 'Michael Escobar (samsara duplicate, retired 2026-08-18)'
   where id = 41 and status = 'ACTIVE';
  get diagnostics v_retired = row_count;

  update public.employees set full_name = 'Michael Escobar'
   where id = 40 and full_name = 'Michael';
  get diagnostics v_renamed = row_count;

  if v_moved <> 1 or v_renamed <> 1 or v_retired <> 1 then
    raise exception 'expected 1/1/1, got moved=% renamed=% retired=%', v_moved, v_renamed, v_retired;
  end if;
end
$consolidate$;

-- ============================================================================
-- VERIFY
-- ============================================================================
do $verify$
declare fail text := ''; v_j int; v_s int; v_active int; v_unlinked int;
begin
  if (select full_name from public.employees where id=40) <> 'Michael Escobar'
     then fail := fail || 'emp 40 not renamed; '; end if;
  if (select status from public.employees where id=41) <> 'INACTIVE'
     then fail := fail || 'emp 41 not retired; '; end if;
  if (select full_name from public.employees where id=41) not like '%retired 2026-08-18%'
     then fail := fail || 'emp 41 name not marked as the retired duplicate; '; end if;
  if (select status from public.employees where id=40) <> 'ACTIVE'
     then fail := fail || 'emp 40 is not ACTIVE; '; end if;

  select count(*) into v_j from public.entity_source_links
   where entity_type='employee' and entity_id=40 and source_system='jobber';
  select count(*) into v_s from public.entity_source_links
   where entity_type='employee' and entity_id=40 and source_system='samsara';
  if v_j <> 1 or v_s <> 1 then
    fail := fail || format('emp 40 links jobber=%s samsara=%s, expected 1/1; ', v_j, v_s);
  end if;
  if exists (select 1 from public.entity_source_links where entity_type='employee' and entity_id=41)
     then fail := fail || 'emp 41 still holds a link; '; end if;

  -- his work must still be attached
  if (select count(*) from public.visit_team where employee_id=40) < 15
     then fail := fail || 'emp 40 lost visit_team rows; '; end if;

  -- THE POINT OF THE EXERCISE: every ACTIVE employee carries a Jobber link.
  select count(*) into v_active from public.employees where status='ACTIVE';
  select count(*) into v_unlinked from public.employees e
   where e.status='ACTIVE'
     and not exists (select 1 from public.entity_source_links l
                      where l.entity_type='employee' and l.entity_id=e.id and l.source_system='jobber');
  if v_unlinked <> 0 then
    fail := fail || format('%s of %s ACTIVE employees still have no Jobber link; ', v_unlinked, v_active);
  end if;

  if fail <> '' then raise exception 'VERIFY FAILED: %', fail; end if;
  raise notice 'one Michael (emp 40, both links), and all ACTIVE employees carry a Jobber link';
end
$verify$;

select (select full_name from public.employees where id=40)                            as emp40_name,
       (select status from public.employees where id=40)                                as emp40_status,
       (select status from public.employees where id=41)                                as emp41_status,
       (select count(*) from public.entity_source_links
         where entity_type='employee' and entity_id=40)                                 as emp40_links,
       (select count(*) from public.visit_team where employee_id=40)                    as emp40_visits,
       (select count(*) from public.employees where status='ACTIVE')                    as active_employees,
       (select count(*) from public.employees e where e.status='ACTIVE'
          and not exists (select 1 from public.entity_source_links l
                           where l.entity_type='employee' and l.entity_id=e.id
                             and l.source_system='jobber'))                             as active_without_jobber_link;
