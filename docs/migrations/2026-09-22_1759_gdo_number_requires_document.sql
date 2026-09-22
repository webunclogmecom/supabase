-- 2026-09-22_1759_gdo_number_requires_document.sql
--
-- WHY. Fred, 2026-09-22: "we cannot have a GDO number without having the GDO file."
--
-- WHAT. Two layers, on purpose:
--   1. A CHECK on public.gdos, so EVERY writer is bound (the app RPC, webhook-airtable, scripts, a
--      hand-run migration), not just the one path the app happens to use today.
--   2. A readable refusal in client.upsert_gdo_permit's CREATE branch, because a raw 23514 is not a
--      sentence an operator can act on (Client App: an operator message is plain language).
--
-- 🛑 THE CHECK IS **NOT VALID** ON PURPOSE. 12 existing rows carry a real number with no document and
-- would fail it: 7 ACTIVE (063-TCE GDO-13939, 104-PV GDO-06568, 222-SPE GDO-15268, 223-CHA GDO-08165,
-- 238-PV GDO-13590, 242-WYN GDO-16146, 242-WYN GDO-14760) and 5 INACTIVE (015-FLA, 025-GRO, 027-HER,
-- 045-NU, 087-BB). NOT VALID leaves them alone while binding every future INSERT and UPDATE, which is
-- exactly the ask: stop new ones, chase the existing ones separately. Do NOT run VALIDATE CONSTRAINT
-- until those 12 have a file, or it will fail.
--
-- ⚠ The predicate only bites on a REAL permit number (^GDO-[0-9]+$). A row whose number is not a
-- canonical permit is out of scope here; those were deleted earlier today by
-- 2026-09-22_1653_delete_placeholder_gdo_rows.sql, and the 4 survivors carry real permit data in a
-- bad format and are Fred's to resolve.
--
-- RULE 8 (audit): no new table. public.gdos already carries audit_gdos.
--
-- ⚠ The function below is the LIVE body fetched with pg_get_functiondef and patched by a mechanical
-- string insertion, never retyped. Proven: removing the inserted guard reproduces the fetched body
-- byte for byte.

ALTER TABLE public.gdos
  ADD CONSTRAINT gdos_real_number_requires_document_chk
  CHECK (gdo_number !~ '^GDO-[0-9]+$' OR permit_document_path IS NOT NULL)
  NOT VALID;

CREATE OR REPLACE FUNCTION client.upsert_gdo_permit(p_gdo_id bigint, p_client_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_allowed text[] := array[
    'gdo_number','nickname','location_label','permit_expiration','max_frequency_days',
    'permit_document_path','status','notes','property_id','client_location_id'
  ];
  v_bad         text[];
  v_row         public.gdos;
  v_wanted      text;
  v_out         jsonb;
  v_old_status  text;
  v_old_notes   text;
  v_old_client  bigint;
  v_new_notes   text;
  v_marked      boolean;
  v_prop        bigint;
  v_freq        integer;
begin
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
  if p_patch ? 'permit_expiration'
     and nullif(p_patch->>'permit_expiration','') is not null
     and p_patch->>'permit_expiration' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception 'permit_expiration must be a bare date YYYY-MM-DD, never a timestamp (got %)',
      p_patch->>'permit_expiration' using errcode = '22023';
  end if;

  -- ⚠ BUG 3 FIX. Upper bound. This column drives customer.permits.over_gdo_max
  -- and `compliant`, which the Field Portal shows to the CLIENT, so an inflated
  -- ceiling silently reports a non-compliant site as compliant. Real values are
  -- 30/60/90; 365 is a generous ceiling that still catches 900-for-90.
  if p_patch ? 'max_frequency_days' then
    v_freq := nullif(btrim(coalesce(p_patch->>'max_frequency_days','')),'')::integer;
    if v_freq is not null and (v_freq < 1 or v_freq > 365) then
      raise exception 'max_frequency_days must be between 1 and 365 days (got %). This is the DERM permit ceiling; typical values are 30, 60 or 90.',
        v_freq using errcode = '22023';
    end if;
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
    if v_prop is null then
      raise exception 'property_id is required when creating a permit (a GDO is issued to a location, not a business)'
        using errcode = '22023';
    end if;
    -- 2026-09-22, Fred: "we cannot have a GDO number without having the GDO file."
    if nullif(btrim(coalesce(p_patch->>'permit_document_path','')),'') is null then
      raise exception 'Attach the permit document before saving. A GDO number cannot be recorded without its permit file.'
        using errcode = '22023';
    end if;
    if not exists (select 1 from public.properties pr
                   where pr.id = v_prop and pr.client_id = p_client_id) then
      raise exception 'property % does not belong to client %', v_prop, p_client_id
        using errcode = '23503';
    end if;
    -- Readable duplicate message. The bare 23505 from gdos_client_gdo_unique was
    -- being rendered verbatim to the user, and it is highly reachable in the
    -- PDF-first flow because re-uploading a permit the client already holds hits it.
    if exists (select 1 from public.gdos g
               where g.client_id = p_client_id
                 and g.gdo_number = btrim(p_patch->>'gdo_number')) then
      raise exception 'This client already has permit %. Edit the existing permit instead of adding it again.',
        btrim(p_patch->>'gdo_number') using errcode = '23505';
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
      v_freq,
      nullif(p_patch->>'permit_document_path',''),
      coalesce(v_wanted, 'ACTIVE'),
      nullif(p_patch->>'notes',''),
      v_prop,
      nullif(p_patch->>'client_location_id','')::bigint
    )
    returning * into v_row;
  else
    -- ---- EDIT ----
    select g.status, g.notes, g.client_id
      into v_old_status, v_old_notes, v_old_client
    from public.gdos g where g.id = p_gdo_id for update;
    if not found then
      raise exception 'gdo % not found', p_gdo_id using errcode = 'P0002';
    end if;
    if p_client_id is not null and p_client_id <> v_old_client then
      raise exception 'p_client_id % does not match this permit''s client %', p_client_id, v_old_client
        using errcode = '22023';
    end if;
    if v_prop is not null and not exists (
         select 1 from public.properties pr where pr.id = v_prop and pr.client_id = v_old_client) then
      raise exception 'property % does not belong to client %', v_prop, v_old_client
        using errcode = '23503';
    end if;
    if p_patch ? 'gdo_number' and exists (
         select 1 from public.gdos g
         where g.client_id = v_old_client
           and g.gdo_number = btrim(p_patch->>'gdo_number')
           and g.id <> p_gdo_id) then
      raise exception 'This client already has permit %. Two permits for one client cannot share a number.',
        btrim(p_patch->>'gdo_number') using errcode = '23505';
    end if;

    -- ⚠⚠ BUG 2 FIX — ONE RULE THAT CLOSES ALL THREE BYPASSES.
    -- On a row whose notes carry DEMOTED/DEDUP evidence:
    --   (i)  notes are APPEND-ONLY  -> closes route B (notes-only disarm) and
    --        route C (5-char "DEDUP" replacing 431 chars of evidence), because
    --        containment of the old text is what the error message already promises;
    --   (ii) any transition TO ACTIVE needs a real append, REGARDLESS of the
    --        current status -> closes route A (INACTIVE->EXPIRED->ACTIVE), which
    --        mattered most because parse-gdo-permit derives EXPIRED for a lapsed
    --        permit and so performed hop 1 automatically.
    v_marked := coalesce(v_old_notes,'') ~* '(DEMOTED|DEDUP)';
    if v_marked then
      v_new_notes := case when p_patch ? 'notes'
                          then nullif(btrim(coalesce(p_patch->>'notes','')),'') end;

      if p_patch ? 'notes' and position(btrim(coalesce(v_old_notes,'')) in coalesce(v_new_notes,'')) = 0 then
        raise exception 'This permit was demoted with recorded evidence, so its notes are append-only. Keep the existing text and add your reason at the end. (The evidence is what stops a wrong permit being silently reactivated.)'
          using errcode = '22023';
      end if;

      if v_wanted = 'ACTIVE' then
        if v_new_notes is null or btrim(coalesce(v_old_notes,'')) = v_new_notes then
          raise exception 'Permit % was demoted with recorded evidence. To reactivate it deliberately, keep the existing notes and append your reason in the same save.',
            p_gdo_id using errcode = '22023';
        end if;
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
                                then v_freq else g.max_frequency_days end,
      permit_document_path = case when p_patch ? 'permit_document_path'
                                  then nullif(p_patch->>'permit_document_path','')
                                  else g.permit_document_path end,
      status = case when p_patch ? 'status'
                    then v_wanted else g.status end,
      notes = case when p_patch ? 'notes'
                   then nullif(p_patch->>'notes','') else g.notes end,
      property_id = case when p_patch ? 'property_id'
                         then v_prop else g.property_id end,
      client_location_id = case when p_patch ? 'client_location_id'
                                then nullif(p_patch->>'client_location_id','')::bigint
                                else g.client_location_id end
    where g.id = p_gdo_id
    returning g.* into v_row;

    -- The warn-only DB trigger can still rewrite NEW.status; report that honestly
    -- rather than claiming a success the row does not reflect.
    if v_wanted is not null and v_row.status <> v_wanted then
      v_out := to_jsonb(v_row) || jsonb_build_object(
        'status_change_refused', true,
        'requested_status', v_wanted,
        'message', 'A database guard refused this status change because the permit was demoted with recorded evidence.');
      return v_out;
    end if;
  end if;

  return to_jsonb(v_row);
end;
$function$

