-- ============================================================================
-- 2026-07-31_1130 — fn_record_client_identity: the DB half of the Client App's
--                   verified client name / client_code saga
-- ============================================================================
-- ASK (Fred, 2026-07-31): "we must have a way to edit a client key data, like
-- client name, client code, type, zone, etc" — one Edit-client dialog. Type and
-- Zone are DB-owned and already have RPCs (2026-07-31_1035). Name and code are
-- JOBBER-MASTERED during the bridge, so they ship as a verified saga in the new
-- `save-client-fields` edge fn (same spine as save-client-job): validate →
-- clientEdit in Jobber (companyName per the convention doc
-- docs/reference/jobber-client-code-convention.md, person-name halves for
-- isCompany=false, `Client Code` custom field) → RE-READ and verify → only then
-- this function records our side, atomically.
--
-- WHY THE POLL CANNOT REVERT THESE EDITS (no echo-suppression rig needed,
-- unlike other Jobber-owned fields): webhook-jobber's parser derives
-- client_code from the `Client Code` CUSTOM FIELD and clients.name by
-- STRIPPING the ` - CODE` suffix (commit 5549b03). The saga writes Jobber
-- first, so the next CLIENT_UPDATE replay re-derives EXACTLY the values this
-- function already stored — the loop converges instead of fighting.
--
-- SECURITY: service_role-only (the edge fn authenticates the staff user itself
-- via auth.getUser + @ayache.com/@unclogme.com). Born-EXECUTE-to-PUBLIC
-- default-privileges trap → explicit revokes, incl. authenticated: the app
-- must NOT be able to skip the Jobber push by calling this directly.
--
-- AUDIT (ADR 010): public.clients carries audit_clients — captured
-- automatically. The edge fn's supabase client sends X-App-Source: client-app.
--
-- 3NF/Rule 1: no schema change; writes the two existing canonical columns.
-- clients.name stays the BARE name (no code suffix) — the suffix lives only in
-- Jobber's display fields, per the convention doc.
--
-- ROLLBACK: drop function public.fn_record_client_identity(bigint, text, text);
-- ============================================================================

begin;

create or replace function public.fn_record_client_identity(
  p_client_id   bigint,
  p_name        text,
  p_client_code text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.clients;
begin
  if p_client_id is null then
    raise exception 'p_client_id is required' using errcode = '22023';
  end if;
  if p_name is null or btrim(p_name) = '' then
    raise exception 'p_name must be a non-empty client name' using errcode = '22023';
  end if;
  -- The bare-name rule: the DB name NEVER carries a client code (prefix,
  -- suffix or parenthetical). The edge fn validates this too; this is the
  -- defense-in-depth copy so no future caller can regress the convention.
  if p_name ~ '[0-9]{2,3}[[:space:]]*-[[:space:]]*[A-Za-z0-9&]+' then
    raise exception 'p_name must not contain a client code (bare name only): %', p_name
      using errcode = '22023';
  end if;
  if p_client_code is not null and p_client_code !~ '^[0-9]{2,3}-[A-Z0-9&]+$' then
    raise exception 'p_client_code must look like NNN-XX (got %)', p_client_code
      using errcode = '22023';
  end if;
  -- Code uniqueness across ALL rows incl. INACTIVE (the 239-COM duplicate-pair
  -- lesson: two rows sharing a code is a live confusion, not a theoretical one).
  -- ⚠ Scoped to code CHANGES only (adversarial review, 2026-07-31): two live
  -- duplicate pairs exist TODAY (050-PV on ids 41/469, 239-COM on 247/493), so
  -- an unscoped check would 23505 a NAME-only edit of those clients while
  -- RE-ASSERTING their own unchanged code — after Jobber was already mutated.
  -- Re-asserting the code a row already owns is never a violation.
  if p_client_code is not null
     and p_client_code is distinct from
         (select c2.client_code from public.clients c2 where c2.id = p_client_id)
     and exists (
      select 1 from public.clients c
      where c.client_code = p_client_code and c.id <> p_client_id) then
    raise exception 'client_code % already belongs to another client', p_client_code
      using errcode = '23505';
  end if;

  update public.clients c set
    name        = btrim(p_name),
    client_code = coalesce(p_client_code, c.client_code)
  where c.id = p_client_id
  returning c.* into v_row;

  if not found then
    raise exception 'client % not found', p_client_id using errcode = 'P0002';
  end if;

  return to_jsonb(v_row);
end;
$$;

revoke execute on function public.fn_record_client_identity(bigint, text, text) from public;
revoke execute on function public.fn_record_client_identity(bigint, text, text) from anon;
revoke execute on function public.fn_record_client_identity(bigint, text, text) from authenticated;
grant  execute on function public.fn_record_client_identity(bigint, text, text) to service_role;

commit;
