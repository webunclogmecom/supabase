-- 2026-09-02_1500_outbound_queue_rpc_wrappers.sql
--
-- PostgREST wrappers for sync.outbound_queue and the shadow, so the drain edge function can reach
-- them. Half two of AUTOMATIC OUTBOUND; the queue and its trigger landed in 2026-09-02_1400.
--
-- WHY THIS EXISTS. The first deploy of jobber-push-custom-field failed at runtime with
-- `Invalid schema: sync`. supabase-js can only address schemas PostgREST is configured to expose,
-- and `sync` deliberately is not one of them - it holds the sync's own bookkeeping and nothing
-- outside the database has any business reading it. has_schema_privilege said service_role=true,
-- which is why this was not obvious: the ROLE has the grant, the API surface simply does not carry
-- the schema. A privilege check is not a reachability check.
--
-- The alternative - adding `sync` to the exposed schema list - would put the whole shadow table on
-- the REST surface for the sake of four calls. These four SECURITY DEFINER wrappers are narrower:
-- they expose exactly the operations the drain needs, and nothing else in sync becomes addressable.
--
-- 🛑 EXECUTE IS service_role ONLY. Supabase grants EXECUTE on new functions to PUBLIC by default,
-- so a bare CREATE FUNCTION here would let `anon` drain the outbound queue and rewrite shadow rows.
-- Every function below is revoked from public/anon/authenticated and granted only to service_role,
-- and the VERIFY block asserts that with has_function_privilege rather than trusting the REVOKE.
--
-- NOTIFY pgrst at the end: without a schema-cache reload PostgREST returns PGRST202 "function not
-- found" for a function that plainly exists, which reads exactly like a deploy failure.

begin;

-- ---------------------------------------------------------------------------
-- 1. Take a batch of pending work.
-- ---------------------------------------------------------------------------
create or replace function public.fn_outbound_queue_take(p_limit integer default 25)
returns table (id bigint, entity_id bigint, field_key text, field_label text,
               desired_value jsonb, attempts integer)
language sql
security definer
set search_path to ''
as $fn$
  select q.id, q.entity_id, q.field_key, q.field_label, q.desired_value, q.attempts
    from sync.outbound_queue q
   where q.status = 'pending'
   order by q.created_at
   limit greatest(1, least(coalesce(p_limit, 25), 200));
$fn$;

-- ---------------------------------------------------------------------------
-- 2. Record the outcome of one row.
-- ---------------------------------------------------------------------------
create or replace function public.fn_outbound_queue_finish(
  p_id bigint, p_status text, p_error text, p_attempts integer)
returns void
language plpgsql
security definer
set search_path to ''
as $fn$
begin
  if p_status not in ('pending','done','failed','skipped') then
    raise exception 'bad status %', p_status using errcode = '22023';
  end if;
  update sync.outbound_queue
     set status       = p_status,
         last_error   = p_error,
         attempts     = coalesce(p_attempts, attempts),
         updated_at   = now(),
         -- a row put back to 'pending' is a RETRY, not a completion: clear the stamp so
         -- v_outbound_queue_health cannot show it as processed while it is still owed.
         processed_at = case when p_status = 'pending' then null else now() end
   where id = p_id;
end
$fn$;

-- ---------------------------------------------------------------------------
-- 3. Read the shadow state for one field. The drain needs source_value (has the SOURCE moved
--    since we last looked?) and conflict_at (is this row frozen?) BEFORE it writes anything.
-- ---------------------------------------------------------------------------
create or replace function public.fn_outbound_shadow_state(
  p_entity_id bigint, p_field_key text)
returns table (shadow_exists boolean, source_value jsonb, our_value jsonb, conflict_at timestamptz)
language sql
security definer
set search_path to ''
as $fn$
  select true, s.source_value, s.our_value, s.conflict_at
    from sync.source_field_shadow s
   where s.entity_id = p_entity_id
     and s.field_key = p_field_key
     and s.entity_type = 'property'
     and s.source_system = 'jobber';
$fn$;

-- ---------------------------------------------------------------------------
-- 4. Re-baseline after a VERIFIED push. Both sides get the same value because, at the moment this
--    is called, both systems genuinely hold it - the drain has already read Jobber back.
--    Passing the value three times is not redundancy: fn_record_shadow takes source, our and
--    adopted_to separately, and they coincide only in this particular case.
-- ---------------------------------------------------------------------------
create or replace function public.fn_outbound_record_shadow(
  p_entity_id bigint, p_field_key text, p_field_label text, p_value jsonb)
returns void
language plpgsql
security definer
set search_path to ''
as $fn$
begin
  perform sync.fn_record_shadow('property', p_entity_id, 'jobber',
                                p_field_key, p_field_label, p_value, p_value, p_value);
end
$fn$;

-- ---------------------------------------------------------------------------
-- 5. Lock the surface down.
-- ---------------------------------------------------------------------------
revoke all on function public.fn_outbound_queue_take(integer)                    from public, anon, authenticated;
revoke all on function public.fn_outbound_queue_finish(bigint, text, text, integer) from public, anon, authenticated;
revoke all on function public.fn_outbound_shadow_state(bigint, text)             from public, anon, authenticated;
revoke all on function public.fn_outbound_record_shadow(bigint, text, text, jsonb) from public, anon, authenticated;

grant execute on function public.fn_outbound_queue_take(integer)                    to service_role;
grant execute on function public.fn_outbound_queue_finish(bigint, text, text, integer) to service_role;
grant execute on function public.fn_outbound_shadow_state(bigint, text)             to service_role;
grant execute on function public.fn_outbound_record_shadow(bigint, text, text, jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
do $verify$
declare
  r record;
  v_bad text := '';
begin
  for r in
    select * from (values
      ('public.fn_outbound_queue_take(integer)'),
      ('public.fn_outbound_queue_finish(bigint, text, text, integer)'),
      ('public.fn_outbound_shadow_state(bigint, text)'),
      ('public.fn_outbound_record_shadow(bigint, text, text, jsonb)')
    ) as t(sig)
  loop
    -- service_role must have it...
    if not has_function_privilege('service_role', r.sig, 'EXECUTE') then
      v_bad := v_bad || ' MISSING service_role:' || r.sig;
    end if;
    -- ...and nobody else may. Checked by NAME, because REVOKE ... FROM PUBLIC does not remove a
    -- grant held directly by a role, and this estate has been bitten by exactly that.
    if has_function_privilege('anon', r.sig, 'EXECUTE') then
      v_bad := v_bad || ' ANON CAN EXECUTE:' || r.sig;
    end if;
    if has_function_privilege('authenticated', r.sig, 'EXECUTE') then
      v_bad := v_bad || ' AUTHENTICATED CAN EXECUTE:' || r.sig;
    end if;
  end loop;
  if v_bad <> '' then
    raise exception 'VERIFY FAILED:%', v_bad;
  end if;
  raise notice 'VERIFY OK: 4 wrappers, service_role only, anon and authenticated refused';
end
$verify$;

notify pgrst, 'reload schema';

commit;
