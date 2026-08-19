-- ============================================================================
-- 2026-08-19_0450 - v_visit_shared_time: which other visit shared this stop
-- ============================================================================
-- Fred, 2026-08-19: "put the number for both visits then, it means it went to both, and
-- we only know the amount it took both, so we can only go ahead with the total amount.
-- if you can for this cases of multiple visits shared time, add like an information icon
-- small next to the numbers and when hovered it puts a tooltip explaining that it was
-- shared with visit X."
--
-- So the number stays on both visits - it is the only thing the GPS can honestly say -
-- and the app labels it instead of quietly overstating it.
--
-- 🛑 THE CRITERION IS OVERLAP, NOT AN IDENTICAL WINDOW, AND THAT MATTERS. The obvious
-- key (same vehicle, same arrival, same departure) finds 114 visits. Testing for OVERLAP
-- instead finds 243 of 904 resolved visits, 26.9%. The difference is real: the dwell is
-- computed per visit around its OWN property, so a truck working two neighbours produces
-- two different windows that overlap rather than two identical ones. If the windows
-- overlap, the truck cannot have done the jobs one after another, so those minutes are
-- not attributable to either visit alone. Keying on identical windows would have left
-- more than half the affected visits showing an unlabelled inflated number.
--
-- Nothing is stored: sharing is derivable from (vehicle_id, actual_arrival_at,
-- actual_departure_at), so per rules 2 and 3 it is computed on read, not copied onto
-- the row.
--
-- Owner-rights view (not security_invoker), so the app reads it without needing grants
-- on visits and clients directly. anon is revoked explicitly: Supabase default privileges
-- hand new objects in `public` to anon, so the REVOKE is the load-bearing statement.
--
-- AUDIT (rule 8): a view; no table or trigger created or altered.
-- ============================================================================

create or replace view public.v_visit_shared_time as
select v.id                                          as visit_id,
       count(s.id)                                   as shared_with_count,
       coalesce(
         jsonb_agg(
           jsonb_build_object(
             'visit_id',    s.id,
             'client_code', c.client_code,
             'client_name', c.name,
             'minutes',     s.duration_minutes
           ) order by s.id
         ) filter (where s.id is not null),
         '[]'::jsonb
       )                                             as shared_with
  from public.v_visits_live v
  left join public.v_visits_live s
         on s.id <> v.id
        and s.vehicle_id = v.vehicle_id
        and s.visit_status = 'completed'
        and s.actual_arrival_at is not null
        and s.actual_departure_at is not null
        -- classic interval overlap: each stop starts before the other ends
        and s.actual_arrival_at   <= v.actual_departure_at
        and v.actual_arrival_at   <= s.actual_departure_at
  left join public.clients c on c.id = s.client_id
 where v.visit_status = 'completed'
   and v.actual_arrival_at is not null
   and v.actual_departure_at is not null
 group by v.id;

comment on view public.v_visit_shared_time is
  'Per visit: how many OTHER completed visits share the same truck stop (overlapping GPS dwell), '
  'and which. Feeds the Admin Review "shared stop" tooltip. Overlap, not identical windows: the '
  'dwell is computed around each visit''s own property, so neighbours overlap rather than match.';

revoke all on public.v_visit_shared_time from public;
revoke all on public.v_visit_shared_time from anon;
grant select on public.v_visit_shared_time to authenticated, service_role;

-- ============================================================================
-- VERIFY
-- ============================================================================
do $verify$
declare
  fail text := '';
  v_rows int; v_shared int; v_self int; v_example record;
begin
  select count(*) into v_rows   from public.v_visit_shared_time;
  select count(*) into v_shared from public.v_visit_shared_time where shared_with_count > 0;

  -- 1. POSITIVE CONTROL: the shared set must be non-empty and must match the overlap
  --    measurement that motivated this (243 of 904 at the time of writing). Allow drift,
  --    but zero would mean the join is dead.
  if v_shared = 0 then fail := fail || 'no visit reports a shared stop - the overlap join is dead; '; end if;

  -- 2. NEGATIVE CONTROL: a visit must never be listed as sharing with ITSELF.
  select count(*) into v_self
    from public.v_visit_shared_time t
   where exists (select 1 from jsonb_array_elements(t.shared_with) e
                  where (e->>'visit_id')::bigint = t.visit_id);
  if v_self > 0 then fail := fail || format('%s visits list themselves as a shared sibling; ', v_self); end if;

  -- 3. SYMMETRY: if A shares with B then B must share with A, or the tooltip would appear
  --    on only one of the two visits and read as a contradiction.
  if exists (
    select 1 from public.v_visit_shared_time a
     cross join lateral jsonb_array_elements(a.shared_with) e
     where not exists (
       select 1 from public.v_visit_shared_time b
        cross join lateral jsonb_array_elements(b.shared_with) e2
        where b.visit_id = (e->>'visit_id')::bigint
          and (e2->>'visit_id')::bigint = a.visit_id)
  ) then
    fail := fail || 'sharing is not symmetric; ';
  end if;

  -- 4. every listed sibling must carry a client code, or the tooltip says "shared with null"
  if exists (select 1 from public.v_visit_shared_time t
              cross join lateral jsonb_array_elements(t.shared_with) e
              where e->>'client_code' is null) then
    fail := fail || 'a shared sibling has no client_code; ';
  end if;

  -- 5. grants
  if has_table_privilege('anon', 'public.v_visit_shared_time', 'SELECT') then
    fail := fail || 'anon can read it; ';
  end if;
  if not has_table_privilege('authenticated', 'public.v_visit_shared_time', 'SELECT') then
    fail := fail || 'authenticated cannot read it; ';
  end if;

  if fail <> '' then raise exception 'VERIFY FAILED: %', fail; end if;
  raise notice 'v_visit_shared_time: % visits, % of them share a stop', v_rows, v_shared;
end
$verify$;

select count(*)                                    as visits,
       count(*) filter (where shared_with_count > 0) as sharing_a_stop,
       max(shared_with_count)                      as most_siblings
  from public.v_visit_shared_time;
