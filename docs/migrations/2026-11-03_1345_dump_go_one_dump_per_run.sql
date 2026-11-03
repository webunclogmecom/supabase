-- 2026-11-03_1345 · dump_go: one dump visit per dump run (DUMP Schedule app, GO button)
--
-- Fred, 2026-11-03 (Trello sfD4mhwm, training video prep), on the open bug "GO creates a second dump next to one the office
-- already scheduled" (found 2026-10-07): "think the best course of action for this, but think of the case of multiple
-- drivers at the same time using the app". His picks (AskUserQuestion, both the recommended option):
--   Case 1, office dump: "Use the office's dump". If this driver already has a dump at the SAME site on the schedule,
--     within 6 hours of now and not done yet, GO takes that one: its time moves to now and the app's note is added.
--     Another driver's dump is never taken.
--   Case 2, same truck: "Second joins the first, only when sure". When the app knows both drivers are in the same truck
--     (dump_resolve_truck gave a truck), same dump site, within 90 minutes, the second driver gets the first one's visit
--     (ALREADY ON THE SCHEDULE with the first driver's name). Truck unknown = each gets his own, as before. Different
--     trucks never share, as before.
--
-- WHAT THIS CHANGES: the dump-visit-create edge function's `create` used to run its own duplicate check (same driver,
-- same site, scheduled, started in the last 90 min) and then call create_dump_visit, as two separate requests. It now
-- calls public.dump_go once, which does all of it in ONE transaction under ONE lock per dump site:
--   1. own      : this driver's own app dump at this site, scheduled, started in the last 90 min -> return it (as before).
--   2. claimed  : (real dumps only) an office dump at this site, scheduled, live, this driver assigned or on its team,
--                 starting within 6 h of now, nearest first -> move it to now through edit_calendar_visit (the
--                 Calendar's own edit path, so Jobber is updated by the usual trigger) and add the app's note.
--   3. joined   : (real dumps only, truck known) a dump at this site on the SAME truck, scheduled, live, starting within
--                 90 min of now -> return it as it is; the reply names its own driver.
--   4. created  : otherwise create_dump_visit, exactly as before.
-- "App dump" = the visit has a dump_activity row create/claim OR its notes carry "(via truck QR)" (two markers, so a lost
-- activity row or a note edited in Jobber alone cannot make an app dump look like an office one).
--
-- WHY A LOCK PER SITE: two drivers tapping GO in the same second (Michael and Jerald share Moises most nights) each
-- used to miss the other's not-yet-committed visit. pg_advisory_xact_lock on the site serialises GOs at that site only;
-- the other site is never blocked. The lock is held for one create (well under a second).
--
-- 🛑 Rules that must not be regressed:
--   - Step 2 never takes another driver's dump: the driver must be its assigned driver or on its visit_team.
--   - Step 2 never takes an app dump (that would merge two loads of one driver: Michael logged 02:58 and 06:43 on 10-03).
--   - A [TEST] GO only ever matches [TEST] dumps (step 1) and never claims or joins: test mode must never touch real visits.
--   - A claim that edit_calendar_visit refuses (a truck clash, a skipped visit) falls through to a new visit: GO never fails
--     because of the office's visit.
--   - Step 3 needs a truck from dump_resolve_truck (accurate-or-silent). Never fill the truck from anything weaker here.
--
-- Audit: no table change. dump_go writes public.visits only through edit_calendar_visit / create_dump_visit (visits is
-- audited) and public.dump_activity (the trail itself, append only, as before).
-- Grants: service_role only (the edge function). Revoked from PUBLIC, anon, authenticated by name.

begin;
set local lock_timeout = '3s';

create or replace function public.dump_go(
  p_client_id      bigint,
  p_job_id         bigint,
  p_property_id    bigint,
  p_line_item_id   bigint,
  p_driver_id      bigint,
  p_vehicle_id     bigint,
  p_notes          text,
  p_test           boolean,
  p_push_to_jobber boolean
) returns table (kind text, visit_id bigint, public_id text, start_at timestamptz, driver_id bigint, driver_name text)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_now   timestamptz := now();
  v_id    bigint;
  v_start timestamptz;
  v_end   timestamptz;
  v_notes text;
  v_refused bigint;            -- an office dump edit_calendar_visit refused: never returned by step 3 either
  v       public.visits;
begin
  if p_client_id is null or p_driver_id is null then
    raise exception 'dump_go: site and driver are required';
  end if;

  -- One GO at a time per dump site (see header).
  perform pg_advisory_xact_lock(hashtext('dump_go'), p_client_id::int);

  -- 1. own: this driver's own app dump here, started in the last 90 minutes (the old idempotency check).
  select x.id into v_id
    from public.visits x
   where x.client_id = p_client_id
     and x.assigned_driver_id = p_driver_id
     and x.visit_status = 'scheduled'
     and x.deleted_at is null
     and x.start_at >= v_now - interval '90 minutes'
     and x.start_at <= v_now + interval '5 minutes'
     and (case when p_test then coalesce(x.notes, '') ilike '%[TEST]%'
               else coalesce(x.notes, '') not ilike '%[TEST]%' end)
     and (coalesce(x.notes, '') ilike '%(via truck QR)%'
          or exists (select 1 from public.dump_activity a
                      where a.dump_visit_id = x.id and a.action in ('create', 'claim')))
   order by x.start_at desc
   limit 1;
  if v_id is not null then
    return query select 'own'::text, x.id, x.public_id, x.start_at, x.assigned_driver_id, e.full_name
                   from public.visits x left join public.employees e on e.id = x.assigned_driver_id
                  where x.id = v_id;
    return;
  end if;

  if not p_test then
    -- 2. claimed: an office dump for this driver here, within 6 hours of now, nearest first.
    select x.id, x.start_at, x.end_at, x.notes into v_id, v_start, v_end, v_notes
      from public.visits x
     where x.client_id = p_client_id
       and x.visit_status = 'scheduled'
       and x.deleted_at is null
       and x.start_at between v_now - interval '6 hours' and v_now + interval '6 hours'
       and coalesce(x.notes, '') not ilike '%[TEST]%'
       and coalesce(x.notes, '') not ilike '%(via truck QR)%'
       and not exists (select 1 from public.dump_activity a
                        where a.dump_visit_id = x.id and a.action in ('create', 'claim'))
       and (x.assigned_driver_id = p_driver_id
            or exists (select 1 from public.visit_team t where t.visit_id = x.id and t.employee_id = p_driver_id))
     order by abs(extract(epoch from (x.start_at - v_now))), x.id
     limit 1
     for update;
    if v_id is not null then
      begin
        perform public.edit_calendar_visit(v_id, jsonb_build_object(
          'start_at', v_now,
          'end_at',   v_now + coalesce(nullif(v_end - v_start, interval '0'), interval '60 minutes'),
          'notes',    trim(coalesce(v_notes || ' ', '') || coalesce(p_notes, ''))));
        insert into public.dump_activity (action, driver_id, dump_visit_id, detail)
        values ('claim', p_driver_id, v_id, jsonb_build_object('office_start_at', v_start, 'moved_to', v_now));
        return query select 'claimed'::text, x.id, x.public_id, x.start_at, x.assigned_driver_id, e.full_name
                       from public.visits x left join public.employees e on e.id = x.assigned_driver_id
                      where x.id = v_id;
        return;
      exception when others then
        -- A refused claim (truck clash, skipped visit) must not stop the driver: make his own visit instead.
        raise notice 'dump_go: could not take office dump % (%), making a new one', v_id, sqlerrm;
        v_refused := v_id;
        v_id := null;
      end;
    end if;

    -- 3. joined: a dump here on the same (known) truck, within 90 minutes of now.
    if p_vehicle_id is not null then
      select x.id into v_id
        from public.visits x
       where x.client_id = p_client_id
         and x.vehicle_id = p_vehicle_id
         and x.visit_status = 'scheduled'
         and x.deleted_at is null
         and x.start_at between v_now - interval '90 minutes' and v_now + interval '90 minutes'
         and coalesce(x.notes, '') not ilike '%[TEST]%'
         and x.id is distinct from v_refused
       order by abs(extract(epoch from (x.start_at - v_now))), x.id
       limit 1;
      if v_id is not null then
        insert into public.dump_activity (action, driver_id, dump_visit_id, detail)
        values ('join', p_driver_id, v_id, jsonb_build_object('vehicle_id', p_vehicle_id));
        return query select 'joined'::text, x.id, x.public_id, x.start_at, x.assigned_driver_id, e.full_name
                       from public.visits x left join public.employees e on e.id = x.assigned_driver_id
                      where x.id = v_id;
        return;
      end if;
    end if;
  end if;

  -- 4. created: a new dump visit, exactly as before.
  v := public.create_dump_visit(
         p_client_id, p_job_id, array[p_line_item_id], (v_now at time zone 'America/New_York')::date,
         p_property_id, v_now, v_now + interval '60 minutes', 'Dump', p_notes,
         p_driver_id, array[p_driver_id], p_push_to_jobber, p_vehicle_id);
  return query select 'created'::text, v.id, v.public_id, v.start_at, v.assigned_driver_id, e.full_name
                 from public.employees e where e.id = v.assigned_driver_id;
  if not found then
    return query select 'created'::text, v.id, v.public_id, v.start_at, v.assigned_driver_id, null::text;
  end if;
end
$function$;

revoke all on function public.dump_go(bigint, bigint, bigint, bigint, bigint, bigint, text, boolean, boolean) from public, anon, authenticated;
grant execute on function public.dump_go(bigint, bigint, bigint, bigint, bigint, bigint, text, boolean, boolean) to service_role;

comment on function public.dump_go(bigint, bigint, bigint, bigint, bigint, bigint, text, boolean, boolean) is
  'DUMP app GO (2026-11-03_1345): one dump visit per dump run. Under a lock per site: own app dump (90 min) / office dump for this driver (6 h, moved to now) / same known truck (90 min) / create. service_role only.';

-- VERIFY: the grants are exactly as intended (CREATE handed out defaults; check what is actually there).
do $verify$
begin
  if has_function_privilege('anon', 'public.dump_go(bigint,bigint,bigint,bigint,bigint,bigint,text,boolean,boolean)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.dump_go(bigint,bigint,bigint,bigint,bigint,bigint,text,boolean,boolean)', 'EXECUTE') then
    raise exception 'VERIFY: dump_go must not be executable by anon or authenticated';
  end if;
  if not has_function_privilege('service_role', 'public.dump_go(bigint,bigint,bigint,bigint,bigint,bigint,text,boolean,boolean)', 'EXECUTE') then
    raise exception 'VERIFY: service_role must execute dump_go';
  end if;
end
$verify$;

commit;
