-- ============================================================================
-- 2026-08-11_1305: resolve which GDO permit a posted RPA result covered
-- ============================================================================
-- Companion to 2026-08-11_1240. The queue now serves ONE (ticket, permit) pair per
-- ticket at a time, so when the bot posts a result there is exactly one permit it
-- can have been. This function computes that permit, and `rpa-derm-result` calls it
-- to stamp `derm_portal_submissions.gdo_id`.
--
-- 🛑 WHY THIS LIVES IN THE DATABASE AND NOT IN THE EDGE FUNCTION.
-- The answer must be the SAME rule the queue used to choose the row. Reimplementing
-- "lowest unfiled active permit" in TypeScript creates two definitions of one concept
-- that drift silently, which is the exact shape of the defect this whole change is
-- fixing (a permit set resolved one way in the reporting path and another way
-- everywhere else). Gate 1 of v_derm_portal_queue and the NOT EXISTS below are the
-- same predicate, deliberately.
--
-- Returns NULL when every active permit on that ticket is already filed, or when the
-- client holds no ACTIVE regex-valid permit. NULL is the safe answer: the queue treats
-- a null-permit submission as retiring the WHOLE manifest, so an unresolved filing
-- makes the ticket go quiet and surface in v_gdo_permits_short_filed, rather than
-- leaving every pair queued and re-filing them with Miami-Dade.
--
-- STABLE, not IMMUTABLE: it reads tables. SECURITY INVOKER (the default) on purpose,
-- so it cannot launder access; the only caller is the edge function running as
-- service_role. Per CLAUDE.md, EXECUTE is granted explicitly rather than left to
-- Supabase's default privileges.
--
-- AUDIT-TRAIL STANDING CHECK (rule 8): no table added, renamed or altered.
-- ============================================================================

create or replace function public.fn_resolve_rpa_permit(p_visit_id bigint)
returns bigint
language sql
stable
set search_path = public
as $fn$
  select f.gdo_id
    from public.v_derm_portal_fields f
   where f.visit_id = p_visit_id
     and f.gdo_id is not null
     -- same predicate as gate 1 of v_derm_portal_queue: this pair is not yet filed,
     -- and a null-permit submission counts against every pair on the ticket.
     and not exists (
       select 1
         from public.derm_portal_submissions s
         join public.manifest_visits smv on smv.visit_id = s.visit_id
        where smv.manifest_id = f.manifest_id
          and not s.dry_run
          and (s.gdo_id is null or s.gdo_id is not distinct from f.gdo_id)
          and (s.status = 'SUCCESS' or s.portal_confirmation is not null))
   order by f.gdo_id
   limit 1;
$fn$;

comment on function public.fn_resolve_rpa_permit(bigint) is
  'Which GDO permit the queue would currently serve for this visit''s ticket: the '
  'lowest-id ACTIVE permit with no live filing yet. Called by rpa-derm-result to stamp '
  'derm_portal_submissions.gdo_id. NULL means nothing is outstanding, which the queue '
  'reads as "retire the whole manifest" (under-serve, never double-file).';

revoke all on function public.fn_resolve_rpa_permit(bigint) from public, anon;
grant execute on function public.fn_resolve_rpa_permit(bigint) to service_role, authenticated;

do $do$
declare v_g bigint; v_ok boolean;
begin
  -- (a) THE CASE THIS EXISTS FOR: visit 6617 filed GDO-14117, so GDO-11024 is what a
  -- result posted now would be resolved to. 230 = GDO-11024.
  select public.fn_resolve_rpa_permit(6617) into v_g;
  if v_g is distinct from 230 then
    raise exception 'resolver returned % for visit 6617, expected 230 (GDO-11024)', v_g;
  end if;

  -- (b) POSITIVE CONTROL, a fully-filed single-permit ticket must resolve to NULL:
  -- nothing is outstanding on it. Without this, (a) passing proves only that the
  -- function returns *a* number.
  select public.fn_resolve_rpa_permit(6719) into v_g;
  if v_g is not null then
    raise exception 'resolver returned % for the fully-filed visit 6719, expected NULL', v_g;
  end if;

  -- (c) it agrees with the queue on the one row the queue is actually offering
  select public.fn_resolve_rpa_permit(q.visit_id) = q.gdo_id into v_ok
    from public.v_derm_portal_queue q limit 1;
  if v_ok is distinct from true then
    raise exception 'resolver disagrees with the live queue on the row it is serving';
  end if;

  -- (d) a visit with no GDO reporting at all resolves to NULL rather than erroring
  select public.fn_resolve_rpa_permit(-1) into v_g;
  if v_g is not null then raise exception 'resolver returned % for a nonexistent visit', v_g; end if;

  -- (e) grants: service_role must hold EXECUTE, anon must not
  if not has_function_privilege('service_role','public.fn_resolve_rpa_permit(bigint)','EXECUTE') then
    raise exception 'service_role lacks EXECUTE -- the endpoint could not stamp the permit';
  end if;
  if has_function_privilege('anon','public.fn_resolve_rpa_permit(bigint)','EXECUTE') then
    raise exception 'anon holds EXECUTE -- default privileges leaked';
  end if;

  raise notice 'resolver: 6617 -> GDO-11024, 6719 -> NULL, agrees with the live queue';
end
$do$;
