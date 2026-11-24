-- 2026-11-24_1215_note_photo_sync_reads.sql  (Trello #247 ZkN6Rzho)
--
-- WHY. Fred, 2026-11-24: "they should've been in our system 4~6 hours after they were posted", then "go ahead with the
-- plan" (docs/specs/2026-11-24-note-photo-sync-railway-plan.md, option C). The Jobber note-photo sync moves from GitHub
-- (which skipped it for 10 hours on 11-24) to Railway, and from the Supabase admin API (account-wide token, rate-limited:
-- every one of its failures is a 429) to the normal API with the timed-jobs server key Railway already holds.
-- The normal API cannot run the script's three joined reads, so they live here, COPIED from
-- scripts/sync/sync_jobber_note_photos.js as of 2026-11-24 (lines 109-116, 128-135, 235-237, 299): same joins, same
-- filters, same columns. Every other statement of the script goes to its table directly.
--
-- WHAT. Three read-only functions, SECURITY INVOKER (they run as the caller; the only caller allowed is service_role,
-- which already reads these tables), EXECUTE for service_role only. No table, no grant on a table, nothing written.
-- Rule 8 (audit): no table created or changed, nothing to opt in or out.
--
-- ROLLBACK: drop the three functions (2026-11-24_1215_note_photo_sync_reads_rollback.sql). The GitHub workflow keeps
-- the old script path until the script change ships, so dropping them before that changes nothing.

begin;

-- 1. The visits to check: completed, alive, linked to Jobber, in the window (or one visit).
create or replace function public.note_photo_sync_targets(p_days integer, p_visit bigint default null)
returns table (visit_id bigint, client_id bigint, visit_date date, completed_at timestamptz, visit_gid text, client_code text)
language sql stable security invoker set search_path = public as $$
  select v.id, v.client_id, v.visit_date, v.completed_at, esl.source_id, c.client_code
    from visits v
    join entity_source_links esl on esl.entity_type = 'visit' and esl.entity_id = v.id and esl.source_system = 'jobber'
    join clients c on c.id = v.client_id
   where v.visit_status = 'completed' and v.deleted_at is null
     and case when p_visit is not null then v.id = p_visit else v.visit_date >= (current_date - p_days) end
   order by v.id
$$;

-- 2. A visit's Jobber-sourced photos (att gid + the Jobber note it came from), and its completed sibling visits
--    on the same job (the nearest-visit tie-break).
create or replace function public.note_photo_sync_visit(p_visit bigint)
returns jsonb
language sql stable security invoker set search_path = public as $$
  select jsonb_build_object(
    'ours', coalesce((
      select jsonb_agg(jsonb_build_object('photo_id', ph.id, 'storage_path', ph.storage_path, 'att_gid', esl.source_id,
        'note_gid', (select nesl.source_id from photo_links pn
                       join entity_source_links nesl on nesl.entity_type = 'note' and nesl.entity_id = pn.entity_id and nesl.source_system = 'jobber'
                      where pn.photo_id = ph.id and pn.entity_type = 'note' limit 1)))
        from photo_links pl join photos ph on ph.id = pl.photo_id
        join entity_source_links esl on esl.entity_type = 'photo' and esl.entity_id = ph.id and esl.source_system = 'jobber'
       where pl.entity_type = 'visit' and pl.entity_id = p_visit
         and ph.source in ('jobber_migration', 'jobber_late_recovery', 'jobber_note_sync')), '[]'::jsonb),
    'sibs', coalesce((
      select jsonb_agg(jsonb_build_object('id', v2.id, 'visit_date', v2.visit_date, 'completed_at', v2.completed_at))
        from visits v2
       where v2.job_id = (select job_id from visits where id = p_visit)
         and v2.id <> p_visit and v2.deleted_at is null and v2.visit_status = 'completed'), '[]'::jsonb))
$$;

-- 3. The photo already stored for a Jobber attachment, only when the photo row still exists (~4k stale photo links
--    point at photos a historical cleanup deleted).
create or replace function public.note_photo_sync_photo_id(p_att_gid text)
returns bigint
language sql stable security invoker set search_path = public as $$
  select esl.entity_id from entity_source_links esl join photos ph on ph.id = esl.entity_id
   where esl.entity_type = 'photo' and esl.source_system = 'jobber' and esl.source_id = p_att_gid
   limit 1
$$;

revoke all on function public.note_photo_sync_targets(integer, bigint) from public, anon, authenticated;
revoke all on function public.note_photo_sync_visit(bigint) from public, anon, authenticated;
revoke all on function public.note_photo_sync_photo_id(text) from public, anon, authenticated;
grant execute on function public.note_photo_sync_targets(integer, bigint) to service_role;
grant execute on function public.note_photo_sync_visit(bigint) to service_role;
grant execute on function public.note_photo_sync_photo_id(text) to service_role;

-- VERIFY: who may run them, and each function equals the script's own SQL on live data.
do $verify$
declare n_old bigint; n_new bigint; bad int; f text;
begin
  foreach f in array array['note_photo_sync_targets(integer,bigint)', 'note_photo_sync_visit(bigint)', 'note_photo_sync_photo_id(text)'] loop
    if has_function_privilege('anon', 'public.' || f, 'EXECUTE') or has_function_privilege('authenticated', 'public.' || f, 'EXECUTE')
       or not has_function_privilege('service_role', 'public.' || f, 'EXECUTE') then
      raise exception 'VERIFY: wrong EXECUTE on %', f;
    end if;
  end loop;

  -- targets, 14 days: same visit ids as the script's query
  select count(*) into bad from (
    (select v.id from visits v
       join entity_source_links esl on esl.entity_type='visit' and esl.entity_id=v.id and esl.source_system='jobber'
       join clients c on c.id=v.client_id
      where v.visit_status='completed' and v.deleted_at is null and v.visit_date >= (current_date - 14)
     except select visit_id from public.note_photo_sync_targets(14))
    union all
    (select visit_id from public.note_photo_sync_targets(14)
     except select v.id from visits v
       join entity_source_links esl on esl.entity_type='visit' and esl.entity_id=v.id and esl.source_system='jobber'
      where v.visit_status='completed' and v.deleted_at is null and v.visit_date >= (current_date - 14))) d;
  if bad <> 0 then raise exception 'VERIFY: targets differ from the script query by % rows', bad; end if;
  select count(*) into n_new from public.note_photo_sync_targets(14);
  if n_new = 0 then raise exception 'VERIFY: no target visits in 14 days (control)'; end if;

  -- one visit: ours count equals the script's query, summed over the 14-day targets
  select count(*) into n_old from photo_links pl join photos ph on ph.id=pl.photo_id
    join entity_source_links esl on esl.entity_type='photo' and esl.entity_id=ph.id and esl.source_system='jobber'
   where pl.entity_type='visit' and pl.entity_id in (select visit_id from public.note_photo_sync_targets(14))
     and ph.source in ('jobber_migration','jobber_late_recovery','jobber_note_sync');
  select coalesce(sum(jsonb_array_length(public.note_photo_sync_visit(t.visit_id)->'ours')), 0) into n_new
    from public.note_photo_sync_targets(14) t;
  if n_old <> n_new or n_new = 0 then raise exception 'VERIFY: ours % vs script % (or 0)', n_new, n_old; end if;

  -- single-visit form returns that visit only
  select count(*) into bad from public.note_photo_sync_targets(0, (select min(visit_id) from public.note_photo_sync_targets(14)));
  if bad <> 1 then raise exception 'VERIFY: p_visit form returned % rows', bad; end if;

  -- photo by gid: a live one resolves, a made-up one does not
  if public.note_photo_sync_photo_id((select esl.source_id from entity_source_links esl join photos ph on ph.id=esl.entity_id
        where esl.entity_type='photo' and esl.source_system='jobber' order by esl.id desc limit 1)) is null then
    raise exception 'VERIFY: photo_id does not resolve a live photo';
  end if;
  if public.note_photo_sync_photo_id('no-such-gid') is not null then raise exception 'VERIFY: photo_id resolved nonsense'; end if;
end $verify$;

commit;
