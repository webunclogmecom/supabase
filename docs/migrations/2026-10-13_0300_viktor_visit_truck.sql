-- 2026-10-13_0300_viktor_visit_truck.sql
--
-- Viktor (the AI coworker in Slack) may set the TRUCK on a COMPLETED visit when a person asks him, and the visit's
-- Activity History shows who asked and why.
-- Fred, 2026-10-12: "can you train Viktor to make it so if like Diego says something like '@Viktor add Moises to the
-- visit' he can do it?" then "if the visit isn't complete then don't, also let's train foolproof with Viktor, to make
-- sure he also respects that, but let him make changes to the visits, and only visits, and when he does to have a way
-- to know why he did it, like who was it who ordered him to do it. and for that to be saved in the Activity History
-- of that visit."
--
-- 1. audit.log_change: request_context gains 'change_reason' (header x-change-reason, 500 characters), beside the
--    existing 'actor_name' (x-actor-name). Every other byte is unchanged (spliced, md5-pinned).
-- 2. public.get_record_history: a change with app_source 'viktor' reads
--    'Viktor, asked by <name>: "<reason>"' (the Visit Calendar's Activity tab prints actor_label as delivered).
-- 3. public.viktor_set_visit_truck(visit, truck, requested_by, reason, dry_run): THE ONLY write Viktor has.
--    - Refuses, in a plain sentence (ok=false), anything but a live COMPLETED visit, an ACTIVE truck by name, a named
--      requester and a reason. It changes visits.vehicle_id and nothing else (vehicle_id is not in the Jobber push
--      trigger's column list, so nothing reaches Jobber; the driver is left alone because the Jobber sync owns the crew).
--    - Attribution is set INSIDE the function (request.headers for this transaction: x-app-source 'viktor',
--      x-actor-name = the requester, x-change-reason = the reason), so it cannot be forgotten or faked by a caller,
--      and is put back before the time-on-site recompute so those measured writes are not labelled as Viktor's.
--    - Then measures time on site for that visit's date (fn_compute_time_on_site + fn_fill_blank_time_on_site, the
--      nightly steps; they never clear a value) and says the result.
--    SECURITY DEFINER, search_path '', EXECUTE for service_role only. Called by the edge function viktor-visit-update,
--    which Viktor reaches with his own key (VIKTOR_API_KEY).
-- Rule 8: no table change (public.visits is audited; the trail is the audit row).

begin;
set local lock_timeout = '3s';

-- 1. audit.log_change: capture x-change-reason ----------------------------------------------------------------------
do $mig$
declare
  v_def text := pg_get_functiondef('audit.log_change()'::regprocedure);
  v_old text := $o$'actor_name',      pg_catalog.left(NULLIF(v_headers->>'x-actor-name', ''), 120)$o$;
  v_new text := $n$'actor_name',      pg_catalog.left(NULLIF(v_headers->>'x-actor-name', ''), 120),
      'change_reason',   pg_catalog.left(NULLIF(v_headers->>'x-change-reason', ''), 500)$n$;
begin
  if md5(v_def) <> 'a532e3ea39c61c9eab70aea7f0f5f1de' then
    raise exception 'audit.log_change changed since this migration was written (md5 %)', md5(v_def);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'audit.log_change anchor not found exactly once';
  end if;
  execute replace(v_def, v_old, v_new);
end
$mig$;

-- 2. get_record_history: the Viktor label ---------------------------------------------------------------------------
do $mig$
declare
  v_def text := pg_get_functiondef('public.get_record_history(text,text,timestamptz,boolean,integer,jsonb)'::regprocedure);
  a_old text := $o$(l.request_context->>'actor_name') AS actor_name_ctx$o$;
  a_new text := $n$(l.request_context->>'actor_name') AS actor_name_ctx,
           (l.request_context->>'change_reason') AS change_reason_ctx$n$;
  b_old text := $o$      -- Raw inbound Jobber webhook / poll sync
      WHEN s.app_source = 'jobber' THEN$o$;
  b_new text := $n$      -- Viktor, the AI coworker, acting on a person's request in Slack (2026-10-13_0300). Who asked and
      -- why come from public.viktor_set_visit_truck, which sets them itself.
      WHEN s.app_source = 'viktor'
        THEN 'Viktor, asked by ' || COALESCE(NULLIF(pg_catalog.left(s.actor_name_ctx, 120), ''), 'someone not recorded')
          || COALESCE(': "' || NULLIF(pg_catalog.left(s.change_reason_ctx, 300), '') || '"', '')
      -- Raw inbound Jobber webhook / poll sync
      WHEN s.app_source = 'jobber' THEN$n$;
begin
  if md5(v_def) <> '945668a62e9e499ac064136fc073605f' then
    raise exception 'get_record_history changed since this migration was written (md5 %)', md5(v_def);
  end if;
  if (length(v_def) - length(replace(v_def, a_old, ''))) / length(a_old) <> 1 then
    raise exception 'get_record_history anchor A not found exactly once';
  end if;
  if (length(v_def) - length(replace(v_def, b_old, ''))) / length(b_old) <> 1 then
    raise exception 'get_record_history anchor B not found exactly once';
  end if;
  execute replace(replace(v_def, a_old, a_new), b_old, b_new);
end
$mig$;

-- 3. the one write Viktor has ---------------------------------------------------------------------------------------
create or replace function public.viktor_set_visit_truck(
  p_visit_id bigint, p_truck text, p_requested_by text, p_reason text, p_dry_run boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v record; t record; v_hdr text; v_who text := pg_catalog.btrim(coalesce(p_requested_by, ''));
  v_why text := pg_catalog.btrim(coalesce(p_reason, '')); v_label text; v_trucks text; v_after record;
begin
  select string_agg(name, ', ' order by name) into v_trucks from public.vehicles where status = 'ACTIVE';
  if length(v_who) < 2 then
    return jsonb_build_object('ok', false, 'message', 'I need the name of the person who asked for this change.');
  end if;
  if length(v_why) < 3 then
    return jsonb_build_object('ok', false, 'message', 'I need the reason for this change (the request as it was written).');
  end if;

  select vi.id, vi.visit_status, vi.visit_date, vi.vehicle_id, vi.deleted_at, c.client_code, c.name as client_name,
         (select name from public.vehicles where id = vi.vehicle_id) as old_truck
    into v from public.visits vi join public.clients c on c.id = vi.client_id where vi.id = p_visit_id;
  if v.id is null or v.deleted_at is not null then
    return jsonb_build_object('ok', false, 'message', format('I can''t find visit %s.', p_visit_id));
  end if;
  v_label := format('visit %s (%s %s, %s)', v.id, coalesce(v.client_code, ''), coalesce(v.client_name, ''),
                    to_char(v.visit_date, 'Dy, Mon FMDD'));
  -- Fred, 2026-10-12: "if the visit isn't complete then don't"
  if v.visit_status <> 'completed' then
    return jsonb_build_object('ok', false, 'visit_id', v.id, 'message',
      format('I didn''t change %s: it is %s, not completed, and I only change completed visits.', v_label, v.visit_status));
  end if;

  select id, name into t from public.vehicles
   where status = 'ACTIVE' and pg_catalog.lower(name) = pg_catalog.lower(pg_catalog.btrim(coalesce(p_truck, '')));
  if t.id is null then
    return jsonb_build_object('ok', false, 'visit_id', v.id, 'message',
      format('There is no truck called "%s". The trucks are %s.', pg_catalog.btrim(coalesce(p_truck, '')), v_trucks));
  end if;
  if v.vehicle_id = t.id then
    return jsonb_build_object('ok', true, 'changed', false, 'visit_id', v.id,
      'message', format('%s already has %s as its truck. Nothing changed.', pg_catalog.initcap(v_label), t.name));
  end if;
  if p_dry_run then
    return jsonb_build_object('ok', true, 'changed', false, 'dry_run', true, 'visit_id', v.id,
      'message', format('I would set %s as the truck on %s (now: %s).', t.name, v_label, coalesce(v.old_truck, 'no truck')));
  end if;

  -- attribution for the audit row, set here so no caller can leave it out; put back right after the write
  v_hdr := pg_catalog.current_setting('request.headers', true);
  perform pg_catalog.set_config('request.headers',
    (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
       || jsonb_build_object('x-app-source', 'viktor', 'x-actor-name', pg_catalog.left(v_who, 120),
                             'x-change-reason', pg_catalog.left(v_why, 500)))::text, true);
  update public.visits set vehicle_id = t.id where id = v.id and visit_status = 'completed' and deleted_at is null;
  perform pg_catalog.set_config('request.headers', coalesce(v_hdr, ''), true);

  -- measure it now, the same way the nightly job does (never clears a value)
  perform public.fn_compute_time_on_site(v.visit_date, v.visit_date + 1, true);
  perform public.fn_fill_blank_time_on_site(v.visit_date, v.visit_date + 1, true);
  select actual_arrival_at, actual_departure_at, duration_minutes into v_after from public.visits where id = v.id;

  return jsonb_build_object('ok', true, 'changed', true, 'visit_id', v.id, 'truck', t.name,
    'previous_truck', v.old_truck, 'duration_minutes', v_after.duration_minutes,
    'message', format('%s is now the truck on %s%s. ', t.name, v_label,
                      case when v.old_truck is null then '' else ' (it was ' || v.old_truck || ')' end)
      || case when v_after.duration_minutes is not null
              then format('Time on site: %s min (%s to %s).', v_after.duration_minutes,
                          to_char(v_after.actual_arrival_at at time zone 'America/New_York', 'FMHH12:MI AM'),
                          to_char(v_after.actual_departure_at at time zone 'America/New_York', 'FMHH12:MI AM'))
              else format('Time on site is still empty: %s''s GPS did not stop within 150 m of the property that day.', t.name) end);
end
$function$;

revoke all on function public.viktor_set_visit_truck(bigint, text, text, text, boolean) from public, anon, authenticated;
grant execute on function public.viktor_set_visit_truck(bigint, text, text, text, boolean) to service_role;
comment on function public.viktor_set_visit_truck(bigint, text, text, text, boolean) is
  'The only write Viktor has: set the truck on a COMPLETED visit, recording who asked and why in the visit''s '
  'Activity History. Called by edge fn viktor-visit-update. 2026-10-13_0300.';

-- VERIFY (the write tests run in a block that is rolled back by its own exception) --------------------------------
do $v$
declare r jsonb; lbl text; ctx jsonb; before bigint;
begin
  if has_function_privilege('authenticated', 'public.viktor_set_visit_truck(bigint,text,text,text,boolean)', 'EXECUTE')
     or has_function_privilege('anon', 'public.viktor_set_visit_truck(bigint,text,text,text,boolean)', 'EXECUTE') then
    raise exception 'VERIFY 1: anon or authenticated can execute viktor_set_visit_truck';
  end if;
  -- refusals change nothing
  r := public.viktor_set_visit_truck(8079, 'Moises', 'Test', 'test: cancelled visit');      -- 112-YA, cancelled
  if (r->>'ok')::boolean or position('not completed' in r->>'message') = 0 then raise exception 'VERIFY 2: %', r; end if;
  r := public.viktor_set_visit_truck(8742, 'Goliath', 'Test', 'test: inactive truck');      -- Goliath is INACTIVE
  if (r->>'ok')::boolean then raise exception 'VERIFY 3: an inactive truck was accepted: %', r; end if;
  r := public.viktor_set_visit_truck(8742, 'Moises', '', 'test: no requester');
  if (r->>'ok')::boolean then raise exception 'VERIFY 4: a change without a requester was accepted'; end if;
  r := public.viktor_set_visit_truck(8742, 'Moises', 'Test', 'go', true);
  if (r->>'ok')::boolean then raise exception 'VERIFY 5: a reason under 3 characters was accepted'; end if;
  if (select vehicle_id from public.visits where id = 8742) is not null then raise exception 'VERIFY 6: a refusal wrote'; end if;

  -- a real change on a completed 112-YA test visit, then thrown away
  begin
    select max(id) into before from audit.logs;
    r := public.viktor_set_visit_truck(8742, 'moises', 'Test Person', '[TEST] add Moises to the visit');
    if not (r->>'changed')::boolean or (select vehicle_id from public.visits where id = 8742) <> 1 then
      raise exception 'VERIFY 7: the truck was not set: %', r;
    end if;
    select request_context into ctx from audit.logs
     where id > before and table_name = 'visits' and record_pk->>'id' = '8742' and app_source = 'viktor'
     order by id limit 1;
    if ctx->>'actor_name' <> 'Test Person' or ctx->>'change_reason' <> '[TEST] add Moises to the visit' then
      raise exception 'VERIFY 8: the audit row does not carry who and why: %', ctx;
    end if;
    select actor_label into lbl from public.get_record_history('visits', '8742', now() - interval '1 minute', true, 5, null)
     where app_source = 'viktor' limit 1;
    if lbl is distinct from 'Viktor, asked by Test Person: "[TEST] add Moises to the visit"' then
      raise exception 'VERIFY 9: Activity History reads %', lbl;
    end if;
    -- the headers were put back: a later write in the same transaction is not labelled as Viktor's
    if coalesce(current_setting('request.headers', true), '') like '%viktor%' then
      raise exception 'VERIFY 10: the Viktor headers leaked past the write';
    end if;
    raise exception 'ROLLBACK_TEST_OK';
  exception when others then
    if sqlerrm <> 'ROLLBACK_TEST_OK' then raise; end if;
  end;
  if (select vehicle_id from public.visits where id = 8742) is not null then raise exception 'VERIFY 11: the test write survived'; end if;

  -- an unchanged history label for an ordinary app write (control: the splice did not break the other branches)
  if not exists (select 1 from public.get_record_history('visits', '8742', null, true, 50, null)) then
    raise exception 'VERIFY 12: history for visit 8742 is empty';
  end if;
end
$v$;

commit;
