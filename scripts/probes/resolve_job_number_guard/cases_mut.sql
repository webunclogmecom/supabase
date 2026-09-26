do $$
declare v_id bigint; v_created boolean; v_ok boolean; v_n int; g text := 'Z2lkOi8vSm9iYmVyL0pvYi85OTk5OTk5MDE=';
begin
  -- C1 CONTROL, old body: shell created, the caller's UPDATE (what handleJob does next) hits 23505, shell + link survive
  begin
    select entity_id, was_created into v_id, v_created from pg_temp.resolve_old(g, '99901068');
    if not v_created then raise exception 'C1: expected a new shell'; end if;
    v_ok := false;
    begin
      update public.jobs set job_status = 'upcoming' where id = v_id;
    exception when unique_violation then v_ok := true;
    end;
    if not v_ok then raise exception 'C1 CONTROL FAILED: the caller UPDATE did not hit 23505'; end if;
    select count(*) into v_n from public.jobs j join public.entity_source_links l
      on l.entity_type = 'job' and l.entity_id = j.id and l.source_id = g where j.job_status is null;
    if v_n <> 1 then raise exception 'C1 CONTROL FAILED: expected 1 stranded linked NULL job, got %', v_n; end if;
    raise exception 'rb1';
  exception when others then if sqlerrm <> 'rb1' then raise; end if;
  end;
  -- C2 new body, live recycled number: refuses INSIDE, nothing left behind
  v_ok := false;
  begin
    perform * from pg_temp.resolve_old(g, '99901068');
  exception when unique_violation then v_ok := true;
  end;
  if not v_ok then raise exception 'C2: new body did not raise 23505'; end if;
  if (select count(*) from public.entity_source_links where source_id = g) <> 0 then raise exception 'C2: link left behind'; end if;
  if (select count(*) from public.jobs where job_number = '99901068') <> 2 then raise exception 'C2: a shell was left behind'; end if;
  -- C2b Jobber-cased status still refuses (lower())
  v_ok := false;
  begin
    perform * from pg_temp.resolve_new(g, '99901068', 'UPCOMING');
  exception when unique_violation then v_ok := true;
  end;
  if not v_ok then raise exception 'C2b: upper-case status did not refuse'; end if;
  -- C3 ARCHIVED import of a recycled number still succeeds
  begin
    select entity_id, was_created into v_id, v_created from pg_temp.resolve_new(g, '99901068', 'archived');
    if not v_created or (select job_status from public.jobs where id = v_id) is distinct from 'archived' then raise exception 'C3: archived import failed'; end if;
    raise exception 'rb3';
  exception when others then if sqlerrm <> 'rb3' then raise; end if;
  end;
  -- C4 NULL status (a caller that does not pass it) keeps the old behaviour
  begin
    select entity_id, was_created into v_id, v_created from pg_temp.resolve_new(g, '99901068');
    if not v_created or (select job_status from public.jobs where id = v_id) is not null then raise exception 'C4: NULL-status behaviour changed'; end if;
    raise exception 'rb4';
  exception when others then if sqlerrm <> 'rb4' then raise; end if;
  end;
  -- C5 fast path unchanged: a linked gid returns its row and writes nothing, whatever status is passed
  select entity_id, was_created into v_id, v_created from pg_temp.resolve_new('Z2lkOi8vSm9iYmVyL0pvYi8xNDY2NTAxNDI=', '11100534', 'upcoming');
  if v_id <> 765 or v_created then raise exception 'C5: fast path changed (%, %)', v_id, v_created; end if;
  -- C6 a fresh number with a live status imports normally
  begin
    select entity_id, was_created into v_id, v_created from pg_temp.resolve_new(g, 'T-RJ-FRESH-0001', 'upcoming');
    if not v_created or (select job_status from public.jobs where id = v_id) is distinct from 'upcoming' then raise exception 'C6: fresh import failed'; end if;
    raise exception 'rb6';
  exception when others then if sqlerrm <> 'rb6' then raise; end if;
  end;
end $$;
