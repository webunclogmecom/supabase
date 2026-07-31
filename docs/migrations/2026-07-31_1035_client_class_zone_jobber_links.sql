-- ============================================================================
-- 2026-07-31_1035 — Client App round 4 DB layer: client-level class + zone,
--                   Jobber deep links on client.clients / client.jobs
-- ============================================================================
-- ASK (Fred, 2026-07-31):
--   * "On the clients app when viewing a client i don't see where you show if
--     it's Residential or Commercial, and i don't see where to change it
--     either, and that's an client account data, not by property or subsets.
--     Same with the Zone."
--   * "we need to add a `Open in Jobber` button when on the view of clients …
--     also add this button on the Jobs section next to the Reopen button"
--
-- WHAT THIS SHIPS (3 pieces):
--   1. client.update_client_fields gains 'client_class' (manual-override write).
--   2. client.update_client_zone(client_id, zone_id) — client-LEVEL zone edit
--      that fans out to ALL the client's properties.
--   3. client.clients + client.jobs views gain `jobber_url` (same derivation as
--      the Calendar drawer's Open in Jobber: ESL GID base64-decoded, last path
--      segment — precedent 2026-06-03_calendar_visit_detail_view.sql), and
--      client.clients gains derived client-level `zone_id` / `zone_code`.
--
-- MEASURED FACTS THE DESIGN LEANS ON (probed 2026-07-31):
--   * client_class infrastructure already exists (2026-05-29 + 2026-06-24):
--     jobber-sourced from Client.isCompany, webhook-jobber maintains it live,
--     trg_clients_protect_manual_class shields manual rows from the poll.
--     Reconciled today: 436 linked, 0 drift, 3 intentional manual pins.
--   * ⚠ THE GUARD SWALLOWS RE-EDITS: fn_clients_protect_manual_class reverts a
--     class change when OLD.source='manual' AND NEW.source='manual'. A naive
--     single UPDATE therefore works the FIRST time (old source='jobber') and
--     silently no-ops every edit after. The RPC does a two-step write: flip
--     source to 'jobber' first (class untouched → guard passes), then set
--     class + source='manual'. Two audit rows per edit on a manual row —
--     acceptable, and the trail shows the mechanism.
--   * Zone is client-level in practice: exactly ONE client (045-NU Nu Real
--     Food) has properties in two zones (MID/EDG + SOUTH); 246 of 247 zoned
--     properties agree with their siblings. The view exposes 'MIXED' for
--     045-NU rather than picking a winner; the fan-out RPC is how the app
--     makes a client uniform.
--   * ESL job coverage is total (1796/1796 jobs linked), clients 438 links.
--   * public.properties carries the audit trigger (verified pg_trigger →
--     log_change), so the zone fan-out is fully captured row-by-row.
--
-- 3NF / Rule 1: no new stored columns. class already lives on public.clients;
-- zone stays on public.properties (the client-level value is DERIVED in the
-- view, never stored — storing it would fork truth against 247 property rows).
-- jobber_url is derived from entity_source_links (the sanctioned bridge); no
-- source-prefixed column lands on any base table.
-- Audit (ADR 010): no new tables. clients + properties already audited; RPC
-- writes are captured automatically. No trigger changes.
-- Grants: CREATE OR REPLACE VIEW preserves existing view ACLs. The new
-- function gets the wave-1 shape: revoke PUBLIC/anon, grant authenticated
-- (born-EXECUTE-to-PUBLIC default-privileges trap, see
-- reference_supabase_function_default_privileges).
--
-- ROLLBACK: drop function client.update_client_zone(bigint, bigint);
--   re-create client.update_client_fields + the two views from git (wave-1
--   definitions in 2026-07-29_1835 + docs/schema.md).
-- ============================================================================

begin;

-- ============================================================================
-- 1. client.update_client_fields — allowlist + client_class
-- ============================================================================
create or replace function client.update_client_fields(
  p_client_id bigint,
  p_patch     jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_allowed text[] := array['notes','group_id','client_class'];
  v_bad     text[];
  v_row     public.clients;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_client_id is null then
    raise exception 'p_client_id is required' using errcode = '22023';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    raise exception 'p_patch must be a non-empty JSON object' using errcode = '22023';
  end if;

  select array_agg(k) into v_bad
  from jsonb_object_keys(p_patch) k
  where k <> all (v_allowed);
  if v_bad is not null then
    raise exception 'unsupported field(s) for clients: %. Allowed: %',
      v_bad, v_allowed using errcode = '22023';
  end if;

  if p_patch ? 'group_id' and nullif(p_patch->>'group_id','') is not null then
    if not exists (select 1 from public.client_groups g
                   where g.id = (p_patch->>'group_id')::bigint) then
      raise exception 'client_groups id % does not exist', p_patch->>'group_id'
        using errcode = '23503';
    end if;
  end if;

  -- client_class: a human assertion. Value is strict (no NULL — unclassifying
  -- from the app is not a thing); the write pins the row as manual so the
  -- Jobber poll can never flip it back (trg_clients_protect_manual_class).
  if p_patch ? 'client_class' then
    if coalesce(p_patch->>'client_class','') not in ('commercial','residential') then
      raise exception 'client_class must be ''commercial'' or ''residential'''
        using errcode = '22023';
    end if;
    -- Two-step past the guard: on an already-manual row a single UPDATE that
    -- changes class while keeping source='manual' is SILENTLY reverted by
    -- fn_clients_protect_manual_class. Flip source first (class untouched →
    -- passes), then the main UPDATE sets class + re-pins manual.
    update public.clients
       set client_class_source = 'jobber'
     where id = p_client_id and client_class_source = 'manual';
  end if;

  update public.clients c set
    notes    = case when p_patch ? 'notes'
                    then nullif(p_patch->>'notes','') else c.notes end,
    group_id = case when p_patch ? 'group_id'
                    then nullif(p_patch->>'group_id','')::bigint else c.group_id end,
    client_class = case when p_patch ? 'client_class'
                        then p_patch->>'client_class' else c.client_class end,
    client_class_source = case when p_patch ? 'client_class'
                               then 'manual' else c.client_class_source end
  where c.id = p_client_id
  returning c.* into v_row;

  if not found then
    raise exception 'client % not found', p_client_id using errcode = 'P0002';
  end if;

  return to_jsonb(v_row);
end;
$$;

revoke execute on function client.update_client_fields(bigint, jsonb) from public;
revoke execute on function client.update_client_fields(bigint, jsonb) from anon;
grant  execute on function client.update_client_fields(bigint, jsonb) to authenticated;

-- ============================================================================
-- 2. client.update_client_zone — client-LEVEL zone, fans out to all properties
-- ============================================================================
-- Zone is client account data per Fred (2026-07-31). The stored grain stays
-- properties.zone_id (Visit Calendar zone editor, ops views and the cascade
-- all read it); this RPC is the client-level write: one call, every property
-- of the client, atomic. NULL clears the zone on all of them.
create or replace function client.update_client_zone(
  p_client_id bigint,
  p_zone_id   bigint
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n    integer;
  v_code text;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_client_id is null then
    raise exception 'p_client_id is required' using errcode = '22023';
  end if;
  if not exists (select 1 from public.clients c where c.id = p_client_id) then
    raise exception 'client % not found', p_client_id using errcode = 'P0002';
  end if;
  if p_zone_id is not null then
    select z.code into v_code from public.zones z where z.id = p_zone_id;
    if v_code is null then
      raise exception 'zones id % does not exist', p_zone_id using errcode = '23503';
    end if;
  end if;

  update public.properties p
     set zone_id = p_zone_id
   where p.client_id = p_client_id
     and p.zone_id is distinct from p_zone_id;
  get diagnostics v_n = row_count;

  return jsonb_build_object(
    'client_id', p_client_id,
    'zone_id', p_zone_id,
    'zone_code', v_code,
    'properties_updated', v_n);
end;
$$;

revoke execute on function client.update_client_zone(bigint, bigint) from public;
revoke execute on function client.update_client_zone(bigint, bigint) from anon;
grant  execute on function client.update_client_zone(bigint, bigint) to authenticated;

-- ============================================================================
-- 3. Views: jobber_url deep links + derived client-level zone
-- ============================================================================
-- Same derivation the Calendar drawer has used since 2026-06-03: decode the
-- ESL base64 GID, take the last path segment. CREATE OR REPLACE keeps the
-- existing column list prefix (a view column can only be APPENDED) and
-- preserves the views' ACLs.
-- ⚠ DEFENSIVE DECODE, learned from the test matrix: TWO job ESL rows store the
-- RAW NUMERIC id ("143219084", "143219293"), not a base64 GID. A bare decode()
-- raises 22023 'invalid base64 end sequence' on ANY scan that touches them —
-- the first version of this view broke client.jobs wholesale. So: numeric
-- source_ids pass through as-is; only padded, charset-valid base64 is decoded;
-- anything else yields NULL rather than an error. (The two rows themselves are
-- a data wart worth normalising separately — a jobber-push against a numeric
-- EncodedId would fail.)

create or replace view client.clients as
select c.id, c.client_code, c.name, c.status, c.balance, c.notes,
       c.created_at, c.updated_at, c.group_id, c.client_class, c.client_class_source,
       (select case
            when l.source_id ~ '^[0-9]+$'
              then 'https://secure.getjobber.com/clients/' || l.source_id
            when length(l.source_id) % 4 = 0 and l.source_id ~ '^[A-Za-z0-9+/]+={0,2}$'
              then 'https://secure.getjobber.com/clients/' ||
                   split_part(convert_from(decode(l.source_id, 'base64'), 'UTF8'), '/', -1)
          end
          from public.entity_source_links l
         where l.entity_type = 'client' and l.source_system = 'jobber'
           and l.entity_id = c.id
         limit 1) as jobber_url,
       dz.zone_id, dz.zone_code
from public.clients c
left join lateral (
  select case when count(distinct p.zone_id) = 1 then min(p.zone_id) end as zone_id,
         case when count(distinct p.zone_id) = 1 then min(z.code)
              when count(distinct p.zone_id) > 1 then 'MIXED' end as zone_code
  from public.properties p
  join public.zones z on z.id = p.zone_id
  where p.client_id = c.id and p.zone_id is not null
) dz on true;

create or replace view client.jobs as
select j.id, j.client_id, j.property_id, j.job_number, j.title, j.job_status,
       j.start_at, j.end_at, j.total, j.created_at, j.updated_at, j.quote_id,
       j.notes, j.frequency_days,
       (select case
            when l.source_id ~ '^[0-9]+$'
              then 'https://secure.getjobber.com/work_orders/' || l.source_id
            when length(l.source_id) % 4 = 0 and l.source_id ~ '^[A-Za-z0-9+/]+={0,2}$'
              then 'https://secure.getjobber.com/work_orders/' ||
                   split_part(convert_from(decode(l.source_id, 'base64'), 'UTF8'), '/', -1)
          end
          from public.entity_source_links l
         where l.entity_type = 'job' and l.source_system = 'jobber'
           and l.entity_id = j.id
         limit 1) as jobber_url
from public.jobs j;

commit;
