-- ============================================================================
-- 2026-07-30_0709 — Add Property (Client App): client.create_property RPC
-- ============================================================================
-- ASK (Fred, 2026-07-30): "make the `Add property` functionality, where i think if
-- you look at the DB + the Clients app view of the property you will know what we
-- need, also when putting the address, can we use like the Google API to make the
-- autocomplete of the address?" Followed by "go ahead with the add property".
--
-- SCOPE DECISION, FLAGGED AND ACCEPTED: properties are Jobber-mastered during the
-- bridge, and a property created here does NOT exist in Jobber (no jobs/visits can
-- attach on the Jobber side until the sunset). Fred was told exactly that and said go.
-- So this creates a LOCAL property: is_billing=false always (billing rows come only
-- from the Jobber sync), no entity_source_links row (there is no Jobber GID).
--
-- The create/edit split is deliberate and mirrors the existing UI contract:
-- the Edit property dialog says "Address, geo-location and billing flags are synced
-- from other systems and can't be edited here" — so CREATE owns identity (address,
-- geo, county, zone, name at birth) and EDIT owns the operational fields. The two
-- allowlists intersect only on zone_id/name-adjacent data by design; do not merge them.
--
-- ---------------------------------------------------------------------------
-- MEASURED FACTS THIS DESIGN ENCODES (survey 2026-07-30, 857 property rows)
-- ---------------------------------------------------------------------------
-- 1. ⚠ `is_primary` DEFAULTS TO TRUE at the column level, AND a partial unique index
--    `uq_properties_one_primary_per_client` — UNIQUE (client_id) WHERE is_primary —
--    enforces ONE primary per client TOTAL, billing rows included (84 clients' primary
--    IS their billing row). So a naive INSERT that omits is_primary does not merely
--    mint a second "primary": it hard-fails 23505 for every client that already has
--    one. The RPC computes it against the INDEX'S EXACT PREDICATE: TRUE only if no
--    property of the client (any kind) is primary.
--    ⚠ This index does NOT appear in pg_constraint — it is a unique INDEX, not a
--    constraint. The first draft of this function surveyed pg_constraint, concluded
--    "no uniqueness beyond the PK", scoped the computation to non-billing rows, and
--    was caught by its own test run (the billing-twin case 23505'd). Survey
--    pg_indexes too, always.
-- 2. 341 same-client duplicate-address groups ALREADY EXIST — the billing/service
--    twin pattern (memory: property_service_billing_dup). So the duplicate guard
--    below blocks only a NON-billing (service) twin. Creating the service sibling of
--    a billing row is the modeled pattern and must stay allowed.
-- 3. County vocabulary in use: 'Dade' 672 · 'Broward' 123 · 'Palm Beach' 6 (plus 13
--    NULL and 3 literal 'None' strings — a known trap, never compare county without
--    normalising). Google Places returns "Miami-Dade County" / "Broward County" /
--    "Palm Beach County"; the UI maps to the short vocabulary before calling this.
--    The RPC accepts free text (the Edit dialog's County field is free text too) but
--    normalises the three known long forms defensively in case a future caller skips
--    the UI mapping.
-- 4. State vocab is messy ('Florida' 792, 'FL' 16, 'fl' 1). The UI sends Google's
--    LONG name ('Florida') to match the dominant form. Not normalised here — that
--    cleanup is a separate task across 17 rows, not a create-path concern.
-- 5. grease_trap_manhole_count is NOT NULL DEFAULT 0 with CHECK 0..50 — omitted
--    here, the default is correct for a new property.
-- 6. public.properties already carries audit_properties (ADR 010) — audit is
--    INHERITED, no new opt-in decision. Verified below by probe, not assumed.
--
-- ---------------------------------------------------------------------------
-- ROLLBACK
-- ---------------------------------------------------------------------------
--   drop function if exists client.create_property(bigint, jsonb);
-- (No table/column/constraint changes to revert — this migration is one function.)
-- ============================================================================

begin;

create or replace function client.create_property(
  p_client_id bigint,
  p_patch     jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_allowed text[] := array['name','address','city','state','zip','county',
                            'zone_id','latitude','longitude'];
  v_bad     text[];
  v_name    text;
  v_addr    text;
  v_city    text;
  v_state   text;
  v_zip     text;
  v_county  text;
  v_zone    bigint;
  v_lat     numeric;
  v_lng     numeric;
  v_primary boolean;
  v_row     public.properties;
begin
  -- Identity, then staff domain. The ROLE is not the identity: an `authenticated`
  -- token with no `sub` claim would otherwise pass. Mirrors the wave-1 RPCs.
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
    raise exception 'unsupported field(s) for a new property: %. Allowed: %',
      v_bad, v_allowed using errcode = '22023';
  end if;

  if not exists (select 1 from public.clients c where c.id = p_client_id) then
    raise exception 'client % does not exist', p_client_id using errcode = '23503';
  end if;

  v_name   := nullif(btrim(coalesce(p_patch->>'name','')),   '');
  v_addr   := nullif(btrim(coalesce(p_patch->>'address','')),'');
  v_city   := nullif(btrim(coalesce(p_patch->>'city','')),   '');
  v_state  := nullif(btrim(coalesce(p_patch->>'state','')),  '');
  v_zip    := nullif(btrim(coalesce(p_patch->>'zip','')),    '');
  v_county := nullif(btrim(coalesce(p_patch->>'county','')), '');

  if v_addr is null then
    raise exception 'A street address is required.' using errcode = '22023';
  end if;

  -- Defensive county normalisation (fact 3). 'None' as INPUT is rejected rather
  -- than stored: the 3 existing 'None' strings are a documented data wart, and the
  -- correct way to say "no county" is to omit the field.
  if v_county is not null then
    case lower(v_county)
      when 'miami-dade county', 'miami-dade', 'dade county', 'dade' then v_county := 'Dade';
      when 'broward county', 'broward'                             then v_county := 'Broward';
      when 'palm beach county', 'palm beach'                       then v_county := 'Palm Beach';
      when 'none' then
        raise exception 'county: omit the field for no county rather than sending ''None''.'
          using errcode = '22023';
      else
        v_county := regexp_replace(v_county, '\s+County$', '', 'i');
    end case;
  end if;

  -- Guarded numeric casts: junk must surface as a readable 22023, not a raw 22P02.
  declare
    v_zone_txt text := nullif(btrim(coalesce(p_patch->>'zone_id','')), '');
    v_lat_txt  text := nullif(btrim(coalesce(p_patch->>'latitude','')), '');
    v_lng_txt  text := nullif(btrim(coalesce(p_patch->>'longitude','')), '');
  begin
    if v_zone_txt is not null then
      if v_zone_txt !~ '^[0-9]+$' then
        raise exception 'zone_id must be a positive integer, got %', v_zone_txt
          using errcode = '22023';
      end if;
      v_zone := v_zone_txt::bigint;
      if not exists (select 1 from public.zones z where z.id = v_zone) then
        raise exception 'zone % does not exist', v_zone using errcode = '23503';
      end if;
    end if;
    if v_lat_txt is not null then
      if v_lat_txt !~ '^-?[0-9]+(\.[0-9]+)?$' then
        raise exception 'latitude must be a number, got %', v_lat_txt using errcode = '22023';
      end if;
      v_lat := v_lat_txt::numeric;
    end if;
    if v_lng_txt is not null then
      if v_lng_txt !~ '^-?[0-9]+(\.[0-9]+)?$' then
        raise exception 'longitude must be a number, got %', v_lng_txt using errcode = '22023';
      end if;
      v_lng := v_lng_txt::numeric;
    end if;
  end;

  -- Coordinates come as a pair from Place Details or not at all. A lone value is a
  -- caller bug, and range errors here are almost always a lat/lng swap.
  if (v_lat is null) <> (v_lng is null) then
    raise exception 'latitude and longitude must be provided together or not at all.'
      using errcode = '22023';
  end if;
  if v_lat is not null and (v_lat < -90 or v_lat > 90) then
    raise exception 'latitude % is out of range (-90..90). Swapped with longitude?', v_lat
      using errcode = '22023';
  end if;
  if v_lng is not null and (v_lng < -180 or v_lng > 180) then
    raise exception 'longitude % is out of range (-180..180).', v_lng
      using errcode = '22023';
  end if;

  -- Duplicate guard, scoped by fact 2: block only a SERVICE twin. The billing twin
  -- with the same address is the modeled pattern and stays allowed.
  if exists (select 1 from public.properties p
             where p.client_id = p_client_id
               and p.is_billing = false
               and lower(btrim(coalesce(p.address,''))) = lower(v_addr)) then
    raise exception 'This client already has a service property at %. Edit that property instead of creating a duplicate.',
      v_addr using errcode = '23505';
  end if;

  -- Fact 1: compute is_primary, never let the column default decide. The predicate
  -- MUST mirror uq_properties_one_primary_per_client — UNIQUE (client_id) WHERE
  -- is_primary — which counts billing rows too. Scoping this to non-billing rows was
  -- the first draft's bug: any client whose primary is its billing row got a 23505.
  v_primary := not exists (select 1 from public.properties p
                           where p.client_id = p_client_id
                             and p.is_primary = true);

  insert into public.properties
    (client_id, name, address, city, state, zip, county,
     zone_id, latitude, longitude, is_billing, is_primary)
  values
    (p_client_id, v_name, v_addr, v_city, coalesce(v_state,'Florida'), v_zip, v_county,
     v_zone, v_lat, v_lng, false, v_primary)
  returning * into v_row;

  return to_jsonb(v_row);
end
$fn$;

-- New functions in `client` are born EXECUTE-to-PUBLIC (Supabase default
-- privileges); revoking PUBLIC alone does not strip anon. Revoke explicitly.
revoke all on function client.create_property(bigint, jsonb) from public;
revoke all on function client.create_property(bigint, jsonb) from anon;
grant execute on function client.create_property(bigint, jsonb) to authenticated;

commit;
