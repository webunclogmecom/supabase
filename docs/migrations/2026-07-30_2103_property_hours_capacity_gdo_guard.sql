-- ============================================================================
-- 2026-07-30_2103 — Properties round 3: per-day access hours, grease capacity
--                   editing, cross-address GDO-number guard
-- ============================================================================
-- ASK (Fred, 2026-07-30): (1) access hours per selected day (UI renders 12h
-- AM/PM); (2) grease capacity: "they go by property, and each client has their
-- Gallons capacity ... the GDO also have the GT size but they're wrong ... we're
-- filling that info ourselves. This needs to be shown up and be able to be
-- edited" — audited first, see below; (3) "No property should've the same GDO.
-- We can check this with the GDO #."
--
-- ---------------------------------------------------------------------------
-- AUDIT RESULT — WHERE CAPACITY LIVES TODAY (measured 2026-07-30)
-- ---------------------------------------------------------------------------
-- The gallons figure the app already shows ("Grease trap 750 gal") is
-- public.service_configs.equipment_size_gallons — grain (client_id,
-- service_type, property_id): 175 properties carry configs (122 one, 48 two,
-- 5 three rows). It fans out to client.client_services_flat.gt_size_gallons
-- (the list), customer.clients.trap_capacity (Field Portal), and five ops.*
-- views incl. v_derm_compliance. The gdos table has NO size column (the
-- permit's "GT size" is a Jobber custom field + PDF field, and Fred says those
-- are wrong). => Editing therefore goes to service_configs.equipment_size_gallons
-- IN PLACE via a new RPC — adding a parallel properties column would fork the
-- truth against six live readers (3NF rule 3). service_configs already carries
-- an audit trigger, so these first human edits are captured.
--
-- ---------------------------------------------------------------------------
-- PER-DAY HOURS — SHAPE DECISION
-- ---------------------------------------------------------------------------
-- Today: ONE window for all days (access_hours_start/end text, e.g. 43 rows
-- "21:00"-"06:00") + access_days text[]. New column access_schedule jsonb:
--   {"mon":{"open":"21:00","close":"06:00"}, "tue":{...}, ...}
-- Keys within mon..sun; times stored 24h "HH:MM" (the UI renders 12h AM/PM);
-- overnight windows (open > close) are VALID — they mean "into the next
-- morning" exactly as today's single window does.
-- ⚠ LEGACY COLUMNS STAY AND ARE KEPT COHERENT: Field Portal + ops read
-- access_hours_start/end as "the allowed-arrival window". When a schedule is
-- written, the RPC derives legacy start/end as the MODE (most common) open and
-- close across the scheduled days — the "typical window". Consumers keep
-- working; per-day detail lives in the new column. Do not drop the legacy pair.
--
-- ---------------------------------------------------------------------------
-- GDO GUARD — CROSS-ADDRESS, NOT CROSS-PROPERTY-ROW (the audit's key finding)
-- ---------------------------------------------------------------------------
-- All 4 existing same-number pairs (GDO-07147/08422/08912/16146) are the SAME
-- physical address under two client rows (successor businesses / billing-service
-- twins). A GDO is issued to the LOCATION, so same number at same address is
-- CORRECT (matches the 2026-05-25 location-bound rule). The real invariant: one
-- ACTIVE GDO number must not sit on two DIFFERENT addresses. Enforced by a
-- BEFORE trigger on gdos (catches EVERY writer: RPC, sync, SQL) for real
-- numbers (^GDO-) comparing whitespace-normalised addresses; junk placeholders
-- ("Not available", "BW", "Needs review" — 33 rows) are not guarded (data
-- warts, not permits). Zero violations exist today, so the guard starts clean.
--
-- The update_property_operational body below is the LIVE definition pulled
-- from pg_proc 2026-07-30 (live-is-ahead-of-docs rule) + ONLY the
-- access_schedule additions. Wave-1 semantics preserved verbatim: explicit
-- manhole-null 22023, county 'None'->NULL mapping, empty-day-array->NULL,
-- not-found-after-update P0002.
--
-- ROLLBACK: drop function client.update_property_capacity(bigint, integer);
--   drop trigger trg_gdo_number_one_address on public.gdos;
--   drop function public.fn_gdo_number_one_address();
--   re-create update_property_operational + client.properties from git;
--   alter table public.properties drop column access_schedule;
-- ============================================================================

begin;

-- 1. the per-day schedule column
alter table public.properties add column if not exists access_schedule jsonb;
comment on column public.properties.access_schedule is
  'Per-day access windows {"mon":{"open":"HH:MM","close":"HH:MM"},...} (24h, ET). Overnight (open>close) = into next morning. Legacy access_hours_start/end stay derived as the modal window; Field Portal reads the legacy pair.';

-- 2. update_property_operational: live body + access_schedule (see header)

CREATE OR REPLACE FUNCTION client.update_property_operational(p_property_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_allowed text[] := array[
    'zone_id','county','access_hours_start','access_hours_end','access_days',
    'access_notes','notes','grease_trap_manhole_count','sample_port_count',
    'default_disposal_facility_id',
    'access_schedule'  -- NEW 2026-07-30_2103: per-day windows
  ];
  -- The ONLY vocabulary public.properties.access_days uses (verified: 201 rows,
  -- 0 non-conforming). Long names are accepted as ALIASES and normalised down,
  -- so a stale client cannot introduce a second vocabulary.
  v_days     text[] := array['mon','tue','wed','thu','fri','sat','sun'];
  v_bad      text[];
  v_row      public.properties;
  v_in       text[];
  v_norm     text[];
  v_d        text;
  v_sched    jsonb;
  v_k        text;
  v_open     text;
  v_close    text;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_property_id is null then
    raise exception 'p_property_id is required' using errcode = '22023';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    raise exception 'p_patch must be a non-empty JSON object' using errcode = '22023';
  end if;

  select array_agg(k) into v_bad
  from jsonb_object_keys(p_patch) k
  where k <> all (v_allowed);
  if v_bad is not null then
    raise exception 'unsupported field(s) for properties: %. Wave 1 allows only %. Address fields are Jobber-owned and geofence/lat/long are Samsara-owned; both would be reverted by the inbound sync.',
      v_bad, v_allowed using errcode = '22023';
  end if;

  if p_patch ? 'grease_trap_manhole_count'
     and nullif(p_patch->>'grease_trap_manhole_count','') is null then
    raise exception 'grease_trap_manhole_count cannot be null' using errcode = '22023';
  end if;

  -- ⚠ BUG 1 FIX. Type check first, then VALUE check. The old version stopped at
  -- the type check, which is how ["Monday","Tuesday"] was accepted.
  if p_patch ? 'access_days' then
    if jsonb_typeof(p_patch->'access_days') not in ('array','null') then
      raise exception 'access_days must be a JSON array of day codes (got %)',
        jsonb_typeof(p_patch->'access_days') using errcode = '22023';
    end if;
    if jsonb_typeof(p_patch->'access_days') = 'array' then
      select array_agg(x) into v_in from jsonb_array_elements_text(p_patch->'access_days') x;
      v_norm := array[]::text[];
      foreach v_d in array coalesce(v_in, array[]::text[]) loop
        -- ⚠ A JSON null becomes SQL NULL here, and `NULL <> all(v_days)` evaluates
        -- to NULL rather than true, so the check below would NOT fire and the NULL
        -- would land in the text[]. Caught by the fix's own test run. Reject first.
        if v_d is null then
          raise exception 'access_days cannot contain a null entry' using errcode = '22023';
        end if;
        v_d := lower(btrim(v_d));
        -- accept the long form as an alias, store the canonical short code
        v_d := case v_d
                 when 'monday' then 'mon' when 'tuesday'   then 'tue'
                 when 'wednesday' then 'wed' when 'thursday' then 'thu'
                 when 'friday' then 'fri' when 'saturday'  then 'sat'
                 when 'sunday' then 'sun' else v_d end;
        if v_d <> all (v_days) then
          raise exception 'access_days: % is not a valid day. Use %', v_d, v_days
            using errcode = '22023';
        end if;
        if v_d <> all (v_norm) then v_norm := v_norm || v_d; end if;  -- de-dup
      end loop;
    end if;
  end if;


  -- NEW: access_schedule validation. Object; keys in mon..sun; values
  -- {open:"HH:MM", close:"HH:MM"} 24h. Overnight open>close is legal (into the
  -- next morning), exactly like the legacy single window.
  if p_patch ? 'access_schedule' then
    if jsonb_typeof(p_patch->'access_schedule') = 'null' then
      v_sched := null;
    elsif jsonb_typeof(p_patch->'access_schedule') <> 'object' then
      raise exception 'access_schedule must be an object keyed by day (mon..sun)'
        using errcode = '22023';
    else
      v_sched := p_patch->'access_schedule';
      for v_k in select jsonb_object_keys(v_sched) loop
        if v_k <> all (v_days) then
          raise exception 'access_schedule: % is not a valid day key. Use %', v_k, v_days
            using errcode = '22023';
        end if;
        v_open  := v_sched->v_k->>'open';
        v_close := v_sched->v_k->>'close';
        if v_open is null or v_close is null
           or v_open  !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
           or v_close !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
          raise exception 'access_schedule.%: open/close must be 24h "HH:MM" strings', v_k
            using errcode = '22023';
        end if;
      end loop;
    end if;
  end if;

  update public.properties p set
    zone_id = case when p_patch ? 'zone_id'
                   then nullif(p_patch->>'zone_id','')::bigint else p.zone_id end,
    county = case when p_patch ? 'county'
                  then nullif(nullif(btrim(p_patch->>'county'),''), 'None')
                  else p.county end,
    access_hours_start = case
        -- NEW: a written schedule derives the legacy start as the MODAL open
        -- (Field Portal + ops keep reading the legacy pair as the typical window)
        when p_patch ? 'access_schedule' and v_sched is not null then
          (select v_sched->d->>'open' from jsonb_object_keys(v_sched) d
            group by v_sched->d->>'open' order by count(*) desc, 1 limit 1)
        when p_patch ? 'access_schedule' then null
        when p_patch ? 'access_hours_start' then nullif(p_patch->>'access_hours_start','')
        else p.access_hours_start end,
    access_hours_end = case
        when p_patch ? 'access_schedule' and v_sched is not null then
          (select v_sched->d->>'close' from jsonb_object_keys(v_sched) d
            group by v_sched->d->>'close' order by count(*) desc, 1 limit 1)
        when p_patch ? 'access_schedule' then null
        when p_patch ? 'access_hours_end' then nullif(p_patch->>'access_hours_end','')
        else p.access_hours_end end,
    -- normalised, de-duplicated, validated. An empty array still stores NULL
    -- (0 of 817 rows use '{}'), which is the documented app contract.
    access_days = case when p_patch ? 'access_days'
                       then nullif(v_norm, array[]::text[])
                       else p.access_days end,
    access_schedule = case when p_patch ? 'access_schedule' then v_sched
                           else p.access_schedule end,
    access_notes = case when p_patch ? 'access_notes'
                        then nullif(p_patch->>'access_notes','') else p.access_notes end,
    notes = case when p_patch ? 'notes'
                 then nullif(p_patch->>'notes','') else p.notes end,
    grease_trap_manhole_count = case when p_patch ? 'grease_trap_manhole_count'
                                     then (p_patch->>'grease_trap_manhole_count')::integer
                                     else p.grease_trap_manhole_count end,
    sample_port_count = case when p_patch ? 'sample_port_count'
                             then nullif(p_patch->>'sample_port_count','')::integer
                             else p.sample_port_count end,
    default_disposal_facility_id = case when p_patch ? 'default_disposal_facility_id'
                                        then nullif(p_patch->>'default_disposal_facility_id','')::bigint
                                        else p.default_disposal_facility_id end
  where p.id = p_property_id
  returning p.* into v_row;

  if not found then
    raise exception 'property % not found', p_property_id using errcode = 'P0002';
  end if;
  return to_jsonb(v_row);
end;
$function$;

revoke all on function client.update_property_operational(bigint, jsonb) from public;
revoke all on function client.update_property_operational(bigint, jsonb) from anon;
grant execute on function client.update_property_operational(bigint, jsonb) to authenticated;

-- 3. capacity editing — writes service_configs.equipment_size_gallons in place
create or replace function client.update_property_capacity(
  p_property_id bigint,
  p_gallons     integer
) returns jsonb
language plpgsql security definer set search_path = ''
as $fn$
declare
  v_client bigint;
  v_id     bigint;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_gallons is not null and (p_gallons < 0 or p_gallons > 20000) then
    raise exception 'Capacity must be between 0 and 20,000 gallons.' using errcode = '22023';
  end if;
  select client_id into v_client from public.properties where id = p_property_id;
  if v_client is null then
    raise exception 'property % not found', p_property_id using errcode = 'P0002';
  end if;

  -- Prefer the property-scoped GT config; update in place. If none exists,
  -- create a minimal GT row (frequency NULL — inert to the legacy due-service
  -- logic, which keys on frequency). service_configs is audited, so the edit
  -- is captured with app_source.
  select id into v_id from public.service_configs
   where property_id = p_property_id and service_type = 'GT'
   order by id limit 1;
  if v_id is not null then
    update public.service_configs set equipment_size_gallons = p_gallons where id = v_id;
  else
    insert into public.service_configs (client_id, service_type, property_id, equipment_size_gallons)
    values (v_client, 'GT', p_property_id, p_gallons)
    returning id into v_id;
  end if;
  return jsonb_build_object('service_config_id', v_id, 'gallons', p_gallons);
end
$fn$;

revoke all on function client.update_property_capacity(bigint, integer) from public;
revoke all on function client.update_property_capacity(bigint, integer) from anon;
grant execute on function client.update_property_capacity(bigint, integer) to authenticated;

-- 4. expose capacity + schedule on client.properties (APPENDED last — legal)
create or replace view client.properties as
  select p.id, p.client_id, p.name, p.address, p.city, p.state, p.zip, p.country,
         p.is_billing, p.created_at, p.updated_at, p.latitude, p.longitude,
         p.geofence_radius_meters, p.geofence_type, p.access_hours_start,
         p.access_hours_end, p.access_days, p.is_primary, p.notes, p.county,
         p.grease_trap_manhole_count, p.access_notes, p.default_disposal_facility_id,
         p.zone_id, p.sample_port_count,
         (select z.code from public.zones z where z.id = p.zone_id) as zone,
         (select count(*) from public.jobs j where j.property_id = p.id)::integer as job_count,
         exists (select 1 from public.entity_source_links l
                 where l.entity_type='property' and l.source_system='jobber'
                   and l.entity_id=p.id) as jobber_linked,
         (select sc.equipment_size_gallons from public.service_configs sc
           where sc.property_id = p.id and sc.service_type = 'GT'
           order by sc.id limit 1) as grease_capacity_gallons,
         p.access_schedule
  from public.properties p;
alter view client.properties owner to postgres;
revoke all on client.properties from anon;
grant select on client.properties to authenticated;
grant select on client.properties to service_role;

-- 5. cross-ADDRESS GDO-number guard (BEFORE trigger: catches EVERY writer)
create or replace function public.fn_gdo_number_one_address()
returns trigger language plpgsql as $tg$
declare
  v_addr  text;
  v_other text;
begin
  if new.gdo_number is null or new.gdo_number !~* '^GDO-'
     or new.status <> 'ACTIVE' or new.property_id is null then
    return new;
  end if;
  select lower(regexp_replace(coalesce(p.address,''), '\s+', ' ', 'g')) into v_addr
    from public.properties p where p.id = new.property_id;
  select p2.address into v_other
    from public.gdos g2 join public.properties p2 on p2.id = g2.property_id
   where upper(btrim(g2.gdo_number)) = upper(btrim(new.gdo_number))
     and g2.status = 'ACTIVE' and g2.id <> coalesce(new.id, -1)
     and lower(regexp_replace(coalesce(p2.address,''), '\s+', ' ', 'g'))
         is distinct from v_addr
   limit 1;
  if v_other is not null then
    raise exception '% is already an ACTIVE permit at a different address (%). A GDO belongs to one location — check the number.',
      new.gdo_number, v_other using errcode = '23505';
  end if;
  return new;
end
$tg$;

drop trigger if exists trg_gdo_number_one_address on public.gdos;
create trigger trg_gdo_number_one_address
  before insert or update of gdo_number, property_id, status on public.gdos
  for each row execute function public.fn_gdo_number_one_address();

commit;
