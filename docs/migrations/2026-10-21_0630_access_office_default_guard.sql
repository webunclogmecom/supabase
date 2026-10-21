-- 2026-10-21_0630 ET · Access decision D9: nobody takes an app away from the whole office by mistake
--
-- Fred, 2026-10-21: "go ahead with all recommended" (plan Building Apps/HR App/docs/specs/
-- 2026-10-21-access-switch-on-and-invite-plan.md, D9 "a small DB rule"). Today an admin can set the Office default of
-- an app to "No access" in one save (hr.set_group_access), and once that app is on, every office person without a
-- setting of their own (Aaron, Diego, Serena) is refused it at once.
-- The rule: for an app that is ON, the Office default cannot be lowered to 'none' through hr.set_group_access unless
-- the change item carries "allow_none": true. The HR App never sends that key, so the save refuses with a plain
-- sentence; lowering to View, and any change for one person, still work. Field defaults and the Yes/No switches are
-- unchanged. Body spliced from the live definition, md5 pinned; one block added before the UPDATE.

BEGIN;

do $splice$
declare v_def text := pg_get_functiondef('hr.set_group_access(jsonb,text)'::regprocedure);
  v_old text := '    update hr.access_group_defaults d set level = v_val where d.grp = v_grp and d.app = v_app.app and d.level is distinct from v_val;';
begin
  if md5(v_def) <> 'a1a81c9cc1ede9a8991f8859bdf578ec' then raise exception 'hr.set_group_access changed; re-splice from the live body'; end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then raise exception 'anchor not found once'; end if;
  execute replace(v_def, v_old,
$n$    -- 2026-10-21_0630 (D9): never take an app that is on away from the whole office in one save
    if v_grp = 'office' and v_app.parent is null and v_app.mode = 'on' and v_val = 'none'
       and coalesce(c->>'allow_none', '') <> 'true'
       and exists (select 1 from hr.access_group_defaults d where d.grp = 'office' and d.app = v_app.app and d.level <> 'none') then
      raise exception 'That would take % away from every office person at once. Change people one by one instead. Nothing was saved.', v_app.name
        using errcode = '22023', detail = 'blocker=office_app_to_none app=' || v_app.app;
    end if;
$n$ || v_old);
end $splice$;

do $verify$
declare v_state text; v_det text; v_ver text;
begin
  -- Fred (admin) tries to set the Office default of Stamp Studio (on) to none: refused; to view: allowed (rolled back)
  perform set_config('request.jwt.claims', '{"sub":"5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b","role":"authenticated","email":"fred@ayache.com"}', true);
  v_ver := hr.fn_defaults_version();
  perform set_config('role', 'authenticated', true);
  begin perform hr.set_group_access('[{"group":"office","app":"stamp_studio","level":"none"}]'::jsonb, v_ver); v_state := 'ok'; v_det := '';
  exception when others then get stacked diagnostics v_state = returned_sqlstate, v_det = pg_exception_detail; end;
  perform set_config('role', 'postgres', true);
  if not (v_state = '22023' and v_det = 'blocker=office_app_to_none app=stamp_studio') then
    raise exception 'VERIFY: office to none not refused (% %)', v_state, v_det; end if;
  begin
    perform set_config('role', 'authenticated', true);
    perform hr.set_group_access('[{"group":"office","app":"stamp_studio","level":"view"}]'::jsonb, v_ver);
    perform set_config('role', 'postgres', true);
    if (select level from hr.access_group_defaults where grp = 'office' and app = 'stamp_studio') <> 'view' then
      raise exception 'VERIFY: lowering to view did not save'; end if;
    raise exception 'undo_marker_0630';
  exception when others then
    perform set_config('role', 'postgres', true);
    if sqlerrm <> 'undo_marker_0630' then raise; end if;
  end;
  if (select level from hr.access_group_defaults where grp = 'office' and app = 'stamp_studio') <> 'edit' then
    raise exception 'VERIFY: the test change leaked'; end if;
  raise notice 'VERIFY ok';
end $verify$;

COMMIT;
