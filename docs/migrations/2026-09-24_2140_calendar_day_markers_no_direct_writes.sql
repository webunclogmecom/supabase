-- =====================================================================================================
-- 2026-09-24_2140  The Calendar no longer writes day markers directly: save-day-marker is the only door
-- =====================================================================================================
-- Follows 2026-09-24_2100_jobber_first_day_markers (Fred: "that it first confirms the data was changed in
-- jobber being reflected in the app/db"). Since the Visit Calendar publish of 2026-09-24 ~21:35 ET (live
-- entry chunk index-DZ8NGn5w) every marker create, change and remove goes through the edge fn
-- save-day-marker (Jobber first). Walked to closure, that bundle touches ops.calendar_day_markers in exactly
-- two places: the select that loads the markers, and .update({dump_visit_id}) right after create_dump_visit.
--
-- So `authenticated` keeps SELECT and UPDATE of dump_visit_id only. INSERT, DELETE and every other UPDATE
-- column are revoked: a write that skips Jobber is no longer possible from a browser, the same structural
-- guarantee ops.calendar_tasks has had since 2026-08-26 (no write grant, one door).
-- ⚠ A Calendar tab opened before that publish and never reloaded still runs the old bundle: its marker
--   writes now fail with a permission error (the app says "Couldn't save the marker..."), and a reload fixes it.
-- The RLS policy calendar_day_markers_rw stays: it still covers the SELECT and the dump_visit_id UPDATE.
-- service_role (SELECT) and yannick_readonly (SELECT) are unchanged; the edge fns write through the
-- SECURITY DEFINER ops.save_day_marker. trg_push_marker_to_jobber stays, as the net for SQL writers.
-- Rule 8: no new table; the table stays audit opt-out.
-- ROLLBACK: grant insert, update, delete on ops.calendar_day_markers to authenticated; (and the column grant
-- becomes redundant). Only needed together with a rollback of the Calendar publish.
-- =====================================================================================================

begin;

do $$
begin
  if (select relacl::text from pg_class where oid = 'ops.calendar_day_markers'::regclass)
     <> '{postgres=arwdDxtm/postgres,authenticated=arwd/postgres,service_role=r/postgres,yannick_readonly=r/postgres}' then
    raise exception 'ops.calendar_day_markers grants changed since this migration was written';
  end if;
end $$;

revoke insert, update, delete on ops.calendar_day_markers from authenticated;
grant update (dump_visit_id) on ops.calendar_day_markers to authenticated;

-- =====================================================================================================
-- VERIFY: by privilege, and by what a real authenticated write does (rolled back through VERIFY_OK)
-- =====================================================================================================
do $verify$
declare
  v_id  bigint;
  v_err text;
begin
  if has_table_privilege('authenticated', 'ops.calendar_day_markers', 'INSERT')
     or has_table_privilege('authenticated', 'ops.calendar_day_markers', 'DELETE')
     or has_column_privilege('authenticated', 'ops.calendar_day_markers', 'minutes', 'UPDATE')
     or has_column_privilege('authenticated', 'ops.calendar_day_markers', 'marker_date', 'UPDATE')
     or has_column_privilege('authenticated', 'ops.calendar_day_markers', 'employee_id', 'UPDATE')
     or not has_table_privilege('authenticated', 'ops.calendar_day_markers', 'SELECT')
     or not has_column_privilege('authenticated', 'ops.calendar_day_markers', 'dump_visit_id', 'UPDATE')
     or not has_table_privilege('service_role', 'ops.calendar_day_markers', 'SELECT')
     or has_table_privilege('anon', 'ops.calendar_day_markers', 'SELECT') then
    raise exception 'V1 privileges are not what this migration intends';
  end if;

  -- a fixture as the owner (push suppressed: no Jobber call), then act on it as authenticated
  perform set_config('app.suppress_marker_push', 'on', true);
  insert into ops.calendar_day_markers (marker_type, marker_date, minutes, employee_id)
  values ('end', date '2031-01-15', 600, 2) returning id into v_id;

  set local role authenticated;
  -- the one write the Calendar still makes
  update ops.calendar_day_markers set dump_visit_id = null where id = v_id;
  -- and the ones it must no longer be able to make
  begin
    update ops.calendar_day_markers set minutes = 610 where id = v_id;
    raise exception 'V2 authenticated could still change minutes';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into ops.calendar_day_markers (marker_type, marker_date, minutes, employee_id) values ('end', date '2031-01-16', 600, 2);
    raise exception 'V3 authenticated could still insert';
  exception when insufficient_privilege then null;
  end;
  begin
    delete from ops.calendar_day_markers where id = v_id;
    raise exception 'V4 authenticated could still delete';
  exception when insufficient_privilege then null;
  end;
  if not exists (select 1 from ops.calendar_day_markers where id = v_id) then
    raise exception 'V5 the authenticated read no longer sees the marker';
  end if;
  reset role;

  raise exception 'VERIFY_OK';
exception when raise_exception then
  if sqlerrm <> 'VERIFY_OK' then raise; end if;
end
$verify$;

commit;
