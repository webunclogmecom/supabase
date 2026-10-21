-- 2026-10-21_0215 ET · Access phase 6 (part 1, follow-up): a live negative probe for the read gate
--
-- After 2026-10-21_0145 the hook was enabled and every role passed (correct: six apps are still in watch). A browser
-- cannot read the `x-access-gate` response header (CORS does not expose it), so nothing proved the gate actually runs
-- for `authenticated` through PostgREST. This adds one more value of the rehearsal header:
--   x-access-rehearsal: refuse-me   -> the gate refuses THIS request exactly as it refuses a person with no access.
-- It can only make the caller's own request fail, never pass something, so it is safe to leave in. It is the live
-- negative control: a signed-in request with it must get 403 / 42501 and the plain sentence; without it, 200.
-- Body spliced from the live definition (md5 pinned); only the two marked lines change.

BEGIN;

do $splice$
declare v_def text := pg_get_functiondef('public.fn_request_gate()'::regprocedure); v_new text;
  v_anchor text := '  v_all_on := coalesce((nullif(current_setting(''request.headers'', true), '''')::jsonb)->>''x-access-rehearsal'', '''') = ''all-on'';';
begin
  if md5(v_def) <> 'f44f202bc785be9648989fa37c8614dc' then raise exception 'public.fn_request_gate changed since 2026-10-21_0145; re-splice from the live body.'; end if;
  if (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor) <> 1 then
    raise exception 'anchor not found exactly once in public.fn_request_gate';
  end if;
  v_new := replace(v_def, v_anchor,
    '  v_all_on := coalesce((nullif(current_setting(''request.headers'', true), '''')::jsonb)->>''x-access-rehearsal'', '''') in (''all-on'', ''refuse-me'');' || E'\n' ||
    '  if (nullif(current_setting(''request.headers'', true), '''')::jsonb)->>''x-access-rehearsal'' = ''refuse-me'' then v_all_on := null; end if;  -- 2026-10-21_0215 live negative probe');
  v_new := replace(v_new, '  if hr.fn_any_app_open(v_all_on) then return; end if;',
    '  if v_all_on is not null and hr.fn_any_app_open(v_all_on) then return; end if;');
  execute v_new;
end $splice$;

do $verify$
declare v_res text;
begin
  -- fred, refuse-me -> refuse ; fred, plain -> pass ; jon.v plain -> pass (watch) ; anon refuse-me -> pass (anon exits first)
  perform set_config('request.jwt.claims', '{"sub":"5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b","role":"authenticated"}', true);
  perform set_config('request.path', '/zones', true);
  perform set_config('request.headers', '{"x-access-rehearsal":"refuse-me"}', true);
  perform set_config('role', 'authenticated', true);
  begin perform public.fn_request_gate(); v_res := 'pass'; exception when insufficient_privilege then v_res := 'refuse'; end;
  perform set_config('role', 'postgres', true);
  if v_res <> 'refuse' then raise exception 'VERIFY: refuse-me did not refuse (%).', v_res; end if;

  perform set_config('request.headers', '{}', true);
  perform set_config('role', 'authenticated', true);
  perform public.fn_request_gate();
  perform set_config('request.headers', '{"x-access-rehearsal":"all-on"}', true);
  perform public.fn_request_gate();                                   -- fred is admin: passes all-on
  perform set_config('request.jwt.claims', '{"sub":"8bdb9ba7-e917-466d-bdb1-c525dbf90194","role":"authenticated"}', true);
  perform set_config('request.headers', '{}', true);
  perform public.fn_request_gate();                                   -- jon.v passes while apps are in watch
  begin
    perform set_config('request.headers', '{"x-access-rehearsal":"all-on"}', true);
    perform public.fn_request_gate(); v_res := 'pass';
  exception when insufficient_privilege then v_res := 'refuse'; end;
  perform set_config('role', 'postgres', true);
  if v_res <> 'refuse' then raise exception 'VERIFY: jon.v all-on should refuse (%).', v_res; end if;

  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config('request.headers', '{"x-access-rehearsal":"refuse-me"}', true);
  perform set_config('role', 'anon', true);
  perform public.fn_request_gate();                                   -- anon is never gated
  perform set_config('role', 'postgres', true);
  raise notice 'VERIFY ok';
end $verify$;

COMMIT;
