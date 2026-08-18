-- ============================================================================
-- 2026-08-18_1640 - make employee role/access match the actual org
-- ============================================================================
-- Fred, 2026-08-18, stating the org outright:
--   *"So Yannick is the owner/ceo / Diego is the administration staff / Serena is also
--    administration staff / Aaron is like an administration staff too but is most of the
--    time on the field, like a driver talking with the customers / and the rest are drivers"*
--
-- Two rows disagreed with that. Both are corrected here; everything else already matched.
--
-- 1. GRECIA (emp 1) was `Office` / `office`. She is a DRIVER, and not a marginal one:
--    **134 visits as assigned_driver and 81 visit_team rows**, the highest of anyone, plus a
--    Samsara driver link. Now `Technician` / `field`.
-- 2. MARK (emp 35) was `Technician` with access_level NULL. He is a driver by the same
--    measures (127 as driver, 44 crews, Samsara link). Now `field`, so the column is not
--    silently missing on one of the three drivers.
--
-- LEFT ALONE, DELIBERATELY:
--  - Aaron (26) stays `Admin` / `dev`. Fred describes him as administration staff who is
--    mostly in the field, and the data agrees exactly: Admin duties plus 40 visits as
--    assigned driver. His access tier is an app permission, not a description of where he
--    spends his day, so it should not be downgraded to `field`.
--  - Fred (2) stays `Office` / `office`. He was not part of the sentence being applied here,
--    has no Samsara link, and his 4 driver rows are incidental.
--  - Yannick `Owner`, Diego and Serena `Admin`: already correct.
--
-- WHY THIS IS SAFE, MEASURED RATHER THAN ASSUMED. Nothing in the database gates on either
-- column. A full sweep of every view and function found exactly two objects referencing
-- them: `client.employees` (a plain projection) and `ops.v_driver_kpi` (selects `e.role`,
-- does not filter on it, confirmed by testing the WHERE clause). `ops.v_calendar_driver`,
-- which feeds the Calendar crew picker, selects ALL ACTIVE employees regardless of role, so
-- nobody appears or disappears from a picker because of this change.
-- ⚠ A first pass reported `ops.v_route_today` as filtering on role. It does not: the match was
-- `cc.contact_role = 'primary'`, a CLIENT CONTACT column. Check which `role` you matched.
--
-- Rule 8 (audit): public.employees carries the audit trigger, so both updates are captured
-- with old_row/new_row. No trigger work needed.
-- Rule 5 (idempotent): each update is pinned to the exact prior value, so a re-run is a no-op.
-- ============================================================================

do $fix$
declare v_grecia int; v_mark int;
begin
  update public.employees
     set role = 'Technician', access_level = 'field'
   where id = 1 and full_name = 'Grecia' and role = 'Office';
  get diagnostics v_grecia = row_count;

  update public.employees
     set access_level = 'field'
   where id = 35 and full_name = 'Mark' and role = 'Technician' and access_level is null;
  get diagnostics v_mark = row_count;

  raise notice 'grecia updated=% mark updated=% (0 on a re-run is correct)', v_grecia, v_mark;
end
$fix$;

-- ============================================================================
-- VERIFY
-- ============================================================================
do $verify$
declare fail text := ''; r record;
begin
  for r in select id, full_name, role, access_level from public.employees where id in (1, 35) loop
    if r.id = 1 and (r.role <> 'Technician' or r.access_level <> 'field') then
      fail := fail || format('Grecia is %s/%s, expected Technician/field; ', r.role, r.access_level);
    end if;
    if r.id = 35 and (r.role <> 'Technician' or r.access_level <> 'field') then
      fail := fail || format('Mark is %s/%s, expected Technician/field; ', r.role, r.access_level);
    end if;
  end loop;

  -- the org, as stated, must now hold for every ACTIVE row
  if exists (select 1 from public.employees where id=27 and role <> 'Owner') then
    fail := fail || 'Yannick is not Owner; '; end if;
  if exists (select 1 from public.employees where id in (26,28,42) and role <> 'Admin') then
    fail := fail || 'Aaron/Diego/Serena are not all Admin; '; end if;
  if exists (select 1 from public.employees where id in (1,35,37,40) and role <> 'Technician') then
    fail := fail || 'not all four drivers are Technician; '; end if;

  -- no ACTIVE employee should be left without an access level
  if exists (select 1 from public.employees where status='ACTIVE' and access_level is null) then
    fail := fail || 'an ACTIVE employee still has a NULL access_level; '; end if;

  if fail <> '' then raise exception 'VERIFY FAILED: %', fail; end if;
  raise notice 'roles and access levels match the stated org';
end
$verify$;

select id, full_name, role, access_level, status,
       (select count(*) from public.visits v where v.assigned_driver_id = e.id and v.deleted_at is null) as visits_as_driver
  from public.employees e
 where status = 'ACTIVE'
 order by case role when 'Owner' then 1 when 'Admin' then 2 when 'Office' then 3 else 4 end, id;
