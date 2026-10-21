-- 2026-10-21_0700 ET · Access switch-on, DERM fixes F1a + print at Edit (database half, ships BEFORE the edge code)
--
-- Fred, 2026-10-21: "go ahead with all recommended" (plan Building Apps/HR App/docs/specs/
-- 2026-10-21-access-switch-on-and-invite-plan.md, F1a, D2, D6).
--   * D2: send-derm-email gets an access check (F1b, edge). A preview needs DERM Tracker View, a send needs Edit.
--     'send_derm_email' already exists here; this adds 'preview_derm_email' (view). It MUST ship before the edge
--     code: an unknown action raises 22023, which the edge function turns into a 503 for every preview, even while
--     DERM is still in watch.
--   * D6: 'generate_derm_address_preview' goes from View to Edit. Measured: the pdf-service's preview endpoint
--     records the sheet (derm.record_generated_sheet_preview), i.e. it hands out a permanent printed sheet number,
--     so it is a change, not a read.
-- DERM is still in watch, so neither change refuses anyone today (a View person would only be logged).
-- Body spliced from the live definition, md5 pinned; only the two marked lines change.

BEGIN;

do $splice$
declare v_def text := pg_get_functiondef('hr.check_app_action(text)'::regprocedure); v_new text;
  a1 text := $a$                 ('send_derm_email',              array['derm_tracker'], 'edit'),$a$;
  a2 text := $a$                 ('generate_derm_address_preview',array['derm_tracker'], 'view'),$a$;
begin
  if md5(v_def) <> '0776383f3a6c0e3af29021a69446b3e7' then raise exception 'hr.check_app_action changed; re-splice from the live body'; end if;
  if (length(v_def) - length(replace(v_def, a1, ''))) / length(a1) <> 1 then raise exception 'anchor 1 not found once'; end if;
  if (length(v_def) - length(replace(v_def, a2, ''))) / length(a2) <> 1 then raise exception 'anchor 2 not found once'; end if;
  v_new := replace(v_def, a1, a1 || E'\n                 (''preview_derm_email'',           array[''derm_tracker''], ''view''),   -- 2026-10-21_0700 (D2)');
  v_new := replace(v_new, a2, $b$                 ('generate_derm_address_preview',array['derm_tracker'], 'edit'),   -- 2026-10-21_0700: it assigns a printed sheet number (D6)$b$);
  execute v_new;
end $splice$;

do $verify$
declare v jsonb; v_state text; v_det text;
begin
  -- the new action exists and passes for Fred; an unknown one still refuses with 22023
  perform set_config('request.jwt.claims', '{"sub":"5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b","role":"authenticated","email":"fred@ayache.com"}', true);
  perform set_config('role', 'authenticated', true);
  v := hr.check_app_action('preview_derm_email');
  begin perform hr.check_app_action('no_such_action'); v_state := 'ok'; exception when others then v_state := sqlstate; end;
  perform set_config('role', 'postgres', true);
  if v ->> 'ok' <> 'true' then raise exception 'VERIFY: preview_derm_email not ok for Fred'; end if;
  if v_state <> '22023' then raise exception 'VERIFY: unknown action did not raise 22023 (%)', v_state; end if;
  -- with DERM on (inside a block that always ends in a marker exception, so it leaves no row and no audit line):
  -- jon.v refused both, with DERM's detail; print now needs edit
  begin
  update hr.access_apps set mode = 'on' where app = 'derm_tracker';
  perform set_config('request.jwt.claims', '{"sub":"8bdb9ba7-e917-466d-bdb1-c525dbf90194","role":"authenticated","email":"jon.v@ayache.com"}', true);
  perform set_config('role', 'authenticated', true);
  begin perform hr.check_app_action('preview_derm_email'); v_state := 'ok'; v_det := '';
  exception when others then get stacked diagnostics v_state = returned_sqlstate, v_det = pg_exception_detail; end;
  perform set_config('role', 'postgres', true);
  if not (v_state = '42501' and v_det = 'blocker=no_access app=derm_tracker needs=view') then
    raise exception 'VERIFY: jon.v preview not refused as expected (% %)', v_state, v_det; end if;
  perform set_config('role', 'authenticated', true);
  begin perform hr.check_app_action('generate_derm_address_preview'); v_state := 'ok'; v_det := '';
  exception when others then get stacked diagnostics v_state = returned_sqlstate, v_det = pg_exception_detail; end;
  perform set_config('role', 'postgres', true);
  if not (v_state = '42501' and v_det = 'blocker=no_access app=derm_tracker needs=edit') then
    raise exception 'VERIFY: print not at edit (% %)', v_state, v_det; end if;
  raise exception 'undo_marker_0700';
  exception when others then
    if sqlerrm <> 'undo_marker_0700' then raise; end if;
  end;
  if (select mode from hr.access_apps where app = 'derm_tracker') <> 'watch' then raise exception 'VERIFY: derm setup leaked'; end if;
  raise notice 'VERIFY ok';
end $verify$;

COMMIT;
