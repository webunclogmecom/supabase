-- ============================================================================
-- 2026-07-29_1835 — Client App phase-2 WAVE 1: the three write RPCs
-- ============================================================================
-- First migration under the new naming convention (docs/migrations/NAMING.md):
-- YYYY-MM-DD_HHMM in ET, because the letter scheme collided across 266 of 459 files.
--
-- WHAT: three SECURITY DEFINER RPCs in the `client` schema so the Client App can edit
-- the wave-1 field set. Wave 1 is defined as "fields Jobber knows nothing about", so an
-- app edit cannot be silently reverted by the */5 inbound poll.
-- Scoping doc: Building Apps/Client App/docs/2026-07-26_phase2-writes-scoping.md
--
-- AUDIT (ADR 010): OPT-IN, inherited. public.clients, public.properties and public.gdos
-- all already carry audit_<table> triggers, so every write here is captured with
-- app_source='client-app'. ⚠ CORRECTED 2026-07-30 — the MECHANISM matters: that label comes
-- from the app's `X-App-Source` HEADER, not from the Origin CASE. audit.log_change computes
-- COALESCE(header, CASE over Origin), so the header WINS and the clients.unclogme.app pin
-- shipped in 2026-07-29c is only the fallback if the header is ever removed. The app shipped
-- sending 'client-view-pro', which made these writes invisible to an app_source='client-app'
-- check until the header value was corrected. Do not "simplify" by deleting either one.
-- No new table is created, so there is no new opt-in decision to make.
--
-- ---------------------------------------------------------------------------
-- WHY RPCs AND NOT GRANTS — do not "simplify" this later
-- ---------------------------------------------------------------------------
-- 1. The `client.*` views are postgres-owned WITHOUT security_invoker, so they bypass
--    RLS. Granting one INSERT/UPDATE = unrestricted write on all 439 clients. Standing
--    rule: no client.* view is ever granted DML and never gets an INSTEAD OF trigger.
-- 2. DO NOT ADD ANY **NEW** COLUMN-LEVEL UPDATE GRANT ON public.properties.
--    `properties_anon_update_manhole_authn` is FOR UPDATE TO authenticated
--    USING (true) WITH CHECK (true) — unscoped, all 817 rows. RLS is row-level and cannot
--    scope a column, so a column grant is the only limit on which column it covers, and a
--    new one becomes writable on every property of every client. See docs/security.md rule 9.
--
--    ⚠ CORRECTION TO AN EARLIER DRAFT OF THIS HEADER, which said such a grant must NEVER
--    exist and that this RPC would therefore be the sole writer. **That was false, and I
--    had already measured the contradicting data before writing it.** Two such grants are
--    live right now, and BOTH are in this migration's own properties allowlist:
--      public.properties.grease_trap_manhole_count   attacl = {authenticated=w/postgres}
--      public.properties.sample_port_count           attacl = {authenticated=w/postgres}
--    `public` is PostgREST-exposed, so any authenticated staff token can already
--    `PATCH /rest/v1/properties?id=eq.<any>` those two columns across all 817 rows, without
--    going through this function. It is in daily use, not theoretical: enumerating
--    app_source (not filtering to one label) gives admin-review 12 + other:review.unclogme.app
--    5 = 17 writes, last 2026-07-29, method=PATCH path=/properties, plus derm-tracker 1.
--
--    ⇒ THREE CONSEQUENCES A READER MUST NOT BE MISLED ABOUT:
--      (a) For 2 of the 10 allowlisted property fields this RPC is a SECOND writer, not a
--          narrowing, and Client App vs Admin Review is LAST-WRITE-WINS on them.
--      (b) The null-guard and the app_source='client-app' attribution below are therefore
--          BYPASSABLE for those two columns via a direct PATCH.
--      (c) Revoking those grants is NOT a free cleanup — it would break Admin Review. The
--          clean end state (move them onto an RPC, drop the grants, then drop the policy so
--          nothing is left to ride on) has app impact and is its own scoped task.
--
-- ---------------------------------------------------------------------------
-- PREREQUISITE, DONE 2026-07-30 (commit 7812c6a) — the reason this was blocked
-- ---------------------------------------------------------------------------
-- `webhook-airtable` was STILL LIVE and blind-overwrote five of the columns below
-- (properties.access_hours_start/end, access_days, county, grease_trap_manhole_count)
-- plus gdos.permit_expiration. Severed and PROVEN by synthetic event returning
-- status='skipped', not inferred from quiet data.
--
-- ---------------------------------------------------------------------------
-- TWO CORRECTIONS TO THE SCOPING DOC'S WAVE-1 LIST, both measured
-- ---------------------------------------------------------------------------
-- (a) 🛑 GEOFENCE AND LAT/LONG ARE **NOT** IMMUNE AND ARE EXCLUDED HERE.
--     The doc lists "geofence" in wave 1. But webhook-samsara writes geofence_type,
--     geofence_radius_meters, latitude and longitude (handleAddress), and NULLs all four
--     on an address delete. They are Samsara-owned, so an app edit would revert.
--     Do not add them to the allowlist without building the echo-suppression rig.
-- (b) ADDRESS FIELDS STAY OUT, as the doc says: webhook-jobber actively overwrites
--     address/city/state/zip on the CLIENT_UPDATE billing-property path.
--
-- `county` IS included and is safe: webhook-jobber writes it on INSERT only and the
-- UPDATE branch deliberately omits it ("do NOT touch county").
-- `zone_id` IS included: no inbound path writes it (the one that used to was the
-- Airtable enrichment, now severed).
--
-- ---------------------------------------------------------------------------
-- CONTRACT SHARED BY ALL THREE
-- ---------------------------------------------------------------------------
--  * PATCH-shaped. Only keys PRESENT in p_patch are written; an omitted key is left
--    untouched. Never a blanket overwrite (that is how the Airtable handler wiped dump
--    dates: it sent every key including nulls).
--  * Unknown or non-allowlisted keys RAISE 22023 rather than being ignored, so a typo or
--    an attempt at an address field fails loudly instead of silently doing nothing.
--  * `auth.uid() IS NOT NULL` is asserted. The role is not the identity: an
--    `authenticated` token with no `sub` claim is rejected, the same trap that makes
--    storage signing return not_found instead of an auth error.
--  * Returns the updated row as jsonb so the app refreshes from the server's truth
--    rather than from optimistic local state.
--  * search_path is pinned to '' (a SECDEF function without a pinned search_path is the
--    documented footgun), so every reference below is schema-qualified.
-- ============================================================================

begin;

-- ============================================================================
-- 1. client.update_client_fields — clients.notes + clients.group_id
-- ============================================================================
-- Verified against webhook-jobber's handleClient payload: it writes only
-- {name, balance, client_class, status, client_code}. Neither `notes` nor `group_id`
-- appears in the file at all, so both are structurally immune to the */5 replay.
--
-- ⚠ clients.status is deliberately NOT here. It is wired to
-- trg_clients_wipe_upcoming_on_inactive, which HARD DELETEs the client's future visits
-- and never tells Jobber. That is wave 3 at the earliest.
create or replace function client.update_client_fields(
  p_client_id bigint,
  p_patch     jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_allowed text[] := array['notes','group_id'];
  v_bad     text[];
  v_row     public.clients;
begin
  -- Identity, then staff domain. The ROLE is not the identity: an `authenticated` token with
  -- no `sub` claim would otherwise pass. The domain check mirrors public.set_visit_status,
  -- which is the closest analogue in this design family, and exists so that a future
  -- mis-grant cannot let a non-staff principal through. All 6 auth.users are staff today, so
  -- this is defense-in-depth rather than a live gate.
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
    raise exception 'unsupported field(s) for clients: %. Wave 1 allows only %',
      v_bad, v_allowed using errcode = '22023';
  end if;

  -- group_id must reference a real group, else the FK error is opaque to the app.
  if p_patch ? 'group_id' and nullif(p_patch->>'group_id','') is not null then
    if not exists (select 1 from public.client_groups g
                   where g.id = (p_patch->>'group_id')::bigint) then
      raise exception 'client_groups id % does not exist', p_patch->>'group_id'
        using errcode = '23503';
    end if;
  end if;

  update public.clients c set
    notes    = case when p_patch ? 'notes'
                    then nullif(p_patch->>'notes','') else c.notes end,
    group_id = case when p_patch ? 'group_id'
                    then nullif(p_patch->>'group_id','')::bigint else c.group_id end
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
-- 2. client.update_property_operational — operational fields on an EXISTING property
-- ============================================================================
-- EXCLUDED ON PURPOSE, all measured: address, city, state, zip, country (webhook-jobber
-- overwrites); latitude, longitude, geofence_type, geofence_radius_meters
-- (webhook-samsara overwrites AND nulls on delete); name, client_id, is_billing,
-- is_primary (identity/structure, not operational).
create or replace function client.update_property_operational(
  p_property_id bigint,
  p_patch       jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_allowed text[] := array[
    'zone_id','county','access_hours_start','access_hours_end','access_days',
    'access_notes','notes','grease_trap_manhole_count','sample_port_count',
    'default_disposal_facility_id'
  ];
  v_bad text[];
  v_row public.properties;
begin
  -- Identity, then staff domain. The ROLE is not the identity: an `authenticated` token with
  -- no `sub` claim would otherwise pass. The domain check mirrors public.set_visit_status,
  -- which is the closest analogue in this design family, and exists so that a future
  -- mis-grant cannot let a non-staff principal through. All 6 auth.users are staff today, so
  -- this is defense-in-depth rather than a live gate.
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

  -- grease_trap_manhole_count is NOT NULL on the table; reject an explicit null so the
  -- app gets a readable error rather than a 23502.
  if p_patch ? 'grease_trap_manhole_count'
     and nullif(p_patch->>'grease_trap_manhole_count','') is null then
    raise exception 'grease_trap_manhole_count cannot be null' using errcode = '22023';
  end if;

  -- ⚠ BLOCKER FIX: a NON-array access_days used to fall through to `else null`, which
  -- SILENTLY WIPED the column and returned success. 201 of 817 rows are populated, and
  -- {"access_days":"Monday"} is a plausible form serialization. Fail loudly instead, which is
  -- what this file's own contract promises. A JSON null is still accepted as "clear it".
  if p_patch ? 'access_days'
     and jsonb_typeof(p_patch->'access_days') not in ('array','null') then
    raise exception 'access_days must be a JSON array of day names (got %)',
      jsonb_typeof(p_patch->'access_days') using errcode = '22023';
  end if;

  update public.properties p set
    zone_id = case when p_patch ? 'zone_id'
                   then nullif(p_patch->>'zone_id','')::bigint else p.zone_id end,
    -- 'None', '' and NULL all mean "no county" (see the DERM Tracker county-pill trap);
    -- normalise the literal string to NULL so it never renders as a county named None.
    county = case when p_patch ? 'county'
                  then nullif(nullif(btrim(p_patch->>'county'),''), 'None')
                  else p.county end,
    access_hours_start = case when p_patch ? 'access_hours_start'
                              then nullif(p_patch->>'access_hours_start','')
                              else p.access_hours_start end,
    access_hours_end = case when p_patch ? 'access_hours_end'
                            then nullif(p_patch->>'access_hours_end','')
                            else p.access_hours_end end,
    -- ⚠ An EMPTY array yields NULL here (array_agg over zero rows), so "no access days" and
    -- "unknown" are the same stored value. That matches the data (0 of 817 rows use '{}') and
    -- is the documented app contract. A NON-array is rejected above, not silently nulled.
    access_days = case when p_patch ? 'access_days'
                       then (select array_agg(x)
                             from jsonb_array_elements_text(p_patch->'access_days') x)
                       else p.access_days end,
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
$$;

revoke execute on function client.update_property_operational(bigint, jsonb) from public;
revoke execute on function client.update_property_operational(bigint, jsonb) from anon;
grant  execute on function client.update_property_operational(bigint, jsonb) to authenticated;

-- ============================================================================
-- 3. client.upsert_gdo_permit — add or edit a GDO permit
-- ============================================================================
-- public.gdos is 100% ours: it is not a Jobber object and webhook-jobber only ever
-- SELECTs client_location_id from it. That is why permits lead wave 1.
--
-- ⚠⚠ THE DEMOTED GUARD CAN MAKE THIS LOOK LIKE A SUCCESSFUL NO-OP.
-- trg_aa_gdos_guard_demoted intercepts an INACTIVE -> ACTIVE flip on a row whose notes
-- match /DEMOTED|DEDUP/ and silently sets NEW.status back to 'INACTIVE'. It RAISEs a
-- **WARNING**, not an exception, so the UPDATE "succeeds" and a naive caller reports
-- success while nothing changed. This function therefore RE-READS the row and returns an
-- explicit `status_change_refused` flag. Do not remove that: never report a write as
-- successful without verifying it landed.
-- To deliberately reactivate such a permit, amend `notes` in the SAME patch.
--
-- Also respected: gdos_client_gdo_unique (client_id, gdo_number),
-- gdos_status_check (ACTIVE|EXPIRED|INACTIVE), gdos_max_frequency_days_positive,
-- and fn_gdos_client_consistency (client_location_id must belong to client_id).
-- NOTE max_frequency_days is the DERM PERMIT CEILING, never jobs.frequency_days.
create or replace function client.upsert_gdo_permit(
  p_gdo_id    bigint,
  p_client_id bigint,
  p_patch     jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_allowed text[] := array[
    'gdo_number','nickname','location_label','permit_expiration','max_frequency_days',
    'permit_document_path','status','notes','property_id','client_location_id'
  ];
  v_bad         text[];
  v_row         public.gdos;
  v_wanted      text;
  v_refused     boolean := false;
  v_out         jsonb;
  v_old_status  text;
  v_old_notes   text;
  v_old_client  bigint;
  v_new_notes   text;
  v_prop        bigint;
  v_scope       bigint;
begin
  -- Identity, then staff domain. The ROLE is not the identity: an `authenticated` token with
  -- no `sub` claim would otherwise pass. The domain check mirrors public.set_visit_status,
  -- which is the closest analogue in this design family, and exists so that a future
  -- mis-grant cannot let a non-staff principal through. All 6 auth.users are staff today, so
  -- this is defense-in-depth rather than a live gate.
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    raise exception 'p_patch must be a non-empty JSON object' using errcode = '22023';
  end if;

  select array_agg(k) into v_bad
  from jsonb_object_keys(p_patch) k
  where k <> all (v_allowed);
  if v_bad is not null then
    raise exception 'unsupported field(s) for gdos: %. Wave 1 allows only %',
      v_bad, v_allowed using errcode = '22023';
  end if;

  v_wanted := nullif(btrim(coalesce(p_patch->>'status','')),'');

  -- ⚠ BLOCKER FIX (NOT NULL columns). Measured: gdos.gdo_number, gdos.property_id and
  -- gdos.status are all NOT NULL. The PATCH idiom `nullif(x,'')` produces NULL for a blank
  -- form field, which used to reach those columns and die on a raw 23502 that the app cannot
  -- explain. Reject present-but-blank explicitly instead.
  if p_patch ? 'gdo_number'
     and nullif(btrim(coalesce(p_patch->>'gdo_number','')),'') is null then
    raise exception 'gdo_number cannot be blank' using errcode = '22023';
  end if;
  if p_patch ? 'status' and v_wanted is null then
    raise exception 'status cannot be blank; expected ACTIVE, EXPIRED or INACTIVE'
      using errcode = '22023';
  end if;
  if v_wanted is not null and v_wanted <> all (array['ACTIVE','EXPIRED','INACTIVE']) then
    raise exception 'status must be one of ACTIVE, EXPIRED, INACTIVE (got %)', v_wanted
      using errcode = '22023';
  end if;
  if p_patch ? 'property_id'
     and nullif(btrim(coalesce(p_patch->>'property_id','')),'') is null then
    raise exception 'property_id cannot be blank; a permit is bound to a location'
      using errcode = '22023';
  end if;

  -- permit_expiration is a DERM compliance date. Require a bare YYYY-MM-DD: an ISO timestamp
  -- from a non-ET browser casts successfully but can land a day early, and this date must
  -- never be timezone-converted.
  if p_patch ? 'permit_expiration'
     and nullif(p_patch->>'permit_expiration','') is not null
     and p_patch->>'permit_expiration' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception 'permit_expiration must be a bare date YYYY-MM-DD, never a timestamp (got %)',
      p_patch->>'permit_expiration' using errcode = '22023';
  end if;

  v_prop := nullif(btrim(coalesce(p_patch->>'property_id','')),'')::bigint;

  if p_gdo_id is null then
    -- ---- ADD ----
    if p_client_id is null then
      raise exception 'p_client_id is required when creating a permit' using errcode = '22023';
    end if;
    if nullif(btrim(coalesce(p_patch->>'gdo_number','')),'') is null then
      raise exception 'gdo_number is required when creating a permit' using errcode = '22023';
    end if;
    -- property_id is NOT NULL on the table, so it is mandatory on create.
    if v_prop is null then
      raise exception 'property_id is required when creating a permit (a GDO is issued to a location, not a business)'
        using errcode = '22023';
    end if;
    -- ⚠ BLOCKER FIX (cross-client integrity). Nothing validated that the property belongs to
    -- the client. customer.permits joins the property to compute over_gdo_max/compliant, so a
    -- mis-pointed property silently corrupts a DERM compliance verdict, and there is no
    -- detector for it. client_location_id gets this check from a trigger; property never did.
    if not exists (select 1 from public.properties pr
                   where pr.id = v_prop and pr.client_id = p_client_id) then
      raise exception 'property % does not belong to client %', v_prop, p_client_id
        using errcode = '23503';
    end if;

    insert into public.gdos (
      client_id, gdo_number, nickname, location_label, permit_expiration,
      max_frequency_days, permit_document_path, status, notes, property_id, client_location_id
    ) values (
      p_client_id,
      btrim(p_patch->>'gdo_number'),
      nullif(p_patch->>'nickname',''),
      nullif(p_patch->>'location_label',''),
      nullif(p_patch->>'permit_expiration','')::date,
      nullif(p_patch->>'max_frequency_days','')::integer,
      nullif(p_patch->>'permit_document_path',''),
      coalesce(v_wanted, 'ACTIVE'),
      nullif(p_patch->>'notes',''),
      nullif(p_patch->>'property_id','')::bigint,
      nullif(p_patch->>'client_location_id','')::bigint
    )
    returning * into v_row;
  else
    -- ---- EDIT ----
    -- Lock and read the current row first: every check below needs the OLD values, and the
    -- demoted decision must not race a concurrent edit.
    select g.status, g.notes, g.client_id
      into v_old_status, v_old_notes, v_old_client
    from public.gdos g where g.id = p_gdo_id for update;
    if not found then
      raise exception 'gdo % not found', p_gdo_id using errcode = 'P0002';
    end if;

    -- p_client_id cannot scope an EDIT (the UPDATE keys on id alone), so rather than let it
    -- look like a scope, require it to agree when supplied.
    if p_client_id is not null and p_client_id <> v_old_client then
      raise exception 'p_client_id % does not match this permit''s client %', p_client_id, v_old_client
        using errcode = '22023';
    end if;

    -- Cross-client property check, same reasoning as the ADD branch, scoped to the row's own client.
    if v_prop is not null and not exists (
         select 1 from public.properties pr where pr.id = v_prop and pr.client_id = v_old_client) then
      raise exception 'property % does not belong to client %', v_prop, v_old_client
        using errcode = '23503';
    end if;

    -- ⚠⚠ BLOCKER FIX — THE DEMOTED GUARD WAS DEFEATED BY THE MOST ORDINARY SAVE.
    -- trg_aa_gdos_guard_demoted only refuses an INACTIVE -> ACTIVE flip while
    -- `NEW.notes IS NOT DISTINCT FROM OLD.notes`. So a full-form save of
    -- {"status":"ACTIVE","notes":""} made notes NULL, which is *distinct* from OLD, so the
    -- trigger never fired: the status flipped, the DEMOTED/DEDUP evidence was ERASED from the
    -- live row, and the re-read below saw no refusal and reported a clean success.
    -- 71 rows are in scope (status='INACTIVE' AND notes ~* '(DEMOTED|DEDUP)'; note the guard
    -- uses ~* so the case-insensitive count is the operative one, not the 50 that ~ gives).
    -- The decision therefore belongs HERE, not in a warn-only trigger.
    if v_wanted = 'ACTIVE'
       and v_old_status = 'INACTIVE'
       and coalesce(v_old_notes,'') ~* '(DEMOTED|DEDUP)' then
      v_new_notes := case when p_patch ? 'notes'
                          then nullif(btrim(coalesce(p_patch->>'notes','')),'') end;
      if v_new_notes is null
         or btrim(coalesce(v_old_notes,'')) = v_new_notes
         or v_new_notes !~* '(DEMOTED|DEDUP)' then
        raise exception 'permit % (%) was demoted with PDF evidence. To reactivate it deliberately, amend the notes in the SAME save: keep the existing DEMOTED/DEDUP text and append your reason. Blanking the notes is refused, because that both bypasses the database guard and destroys the evidence.',
          p_gdo_id, coalesce(v_old_notes,'') using errcode = '22023';
      end if;
    end if;

    update public.gdos g set
      gdo_number = case when p_patch ? 'gdo_number'
                        then btrim(p_patch->>'gdo_number') else g.gdo_number end,
      nickname = case when p_patch ? 'nickname'
                      then nullif(p_patch->>'nickname','') else g.nickname end,
      location_label = case when p_patch ? 'location_label'
                            then nullif(p_patch->>'location_label','') else g.location_label end,
      permit_expiration = case when p_patch ? 'permit_expiration'
                               then nullif(p_patch->>'permit_expiration','')::date
                               else g.permit_expiration end,
      max_frequency_days = case when p_patch ? 'max_frequency_days'
                                then nullif(p_patch->>'max_frequency_days','')::integer
                                else g.max_frequency_days end,
      permit_document_path = case when p_patch ? 'permit_document_path'
                                  then nullif(p_patch->>'permit_document_path','')
                                  else g.permit_document_path end,
      status = case when p_patch ? 'status'
                    then nullif(p_patch->>'status','') else g.status end,
      notes = case when p_patch ? 'notes'
                   then nullif(p_patch->>'notes','') else g.notes end,
      property_id = case when p_patch ? 'property_id'
                         then nullif(p_patch->>'property_id','')::bigint else g.property_id end,
      client_location_id = case when p_patch ? 'client_location_id'
                                then nullif(p_patch->>'client_location_id','')::bigint
                                else g.client_location_id end
    where g.id = p_gdo_id
    returning g.* into v_row;

    if not found then
      raise exception 'gdo % not found', p_gdo_id using errcode = 'P0002';
    end if;

    -- The demoted guard rewrites NEW.status in a BEFORE trigger and only WARNS, so the
    -- RETURNING row already reflects the refusal. Compare against what was asked for.
    if v_wanted is not null and v_row.status <> v_wanted then
      v_refused := true;
    end if;
  end if;

  v_out := to_jsonb(v_row);
  if v_refused then
    v_out := v_out
      || jsonb_build_object(
           'status_change_refused', true,
           'requested_status', v_wanted,
           'message', 'This permit was demoted with PDF evidence, so the status change was refused by a database guard. To reactivate deliberately, edit the notes in the same save.');
  end if;
  return v_out;
end;
$$;

revoke execute on function client.upsert_gdo_permit(bigint, bigint, jsonb) from public;
revoke execute on function client.upsert_gdo_permit(bigint, bigint, jsonb) from anon;
grant  execute on function client.upsert_gdo_permit(bigint, bigint, jsonb) to authenticated;

commit;

-- ============================================================================
-- Rollback
-- ============================================================================
-- drop function if exists client.update_client_fields(bigint, jsonb);
-- drop function if exists client.update_property_operational(bigint, jsonb);
-- drop function if exists client.upsert_gdo_permit(bigint, bigint, jsonb);
