-- ROLLBACK of the 2026-11-19 Trello #227 six-digit migration: back to 5-digit GDO numbers, the old pattern, the old
-- trigger sentence, the old exact-text duplicate checks and the full unique constraint. Rows 144, 307, 309, 310, 311 held 6
-- digits before and keep them; rows added after the migration (id > 313) are left as they are. Run the bot's
-- previous commit first only if the bot was rolled back too (the zero-blind bot reads both forms).

begin;

do $guard$
begin
  if (select number_pattern from public.permit_types where code = 'GDO') <> '^GDO-[0-9]{6}$' then
    raise exception 'GUARD: the six-digit migration is not in place';
  end if;
end
$guard$;

update public.permit_types set number_pattern = '^GDO-[0-9]+$' where code = 'GDO';

CREATE OR REPLACE FUNCTION public.fn_permit_number_matches_type()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_pattern text;
  v_name    text;
  v_type_status text;   -- 2026-11-02_2030
begin
  -- 2026-11-02 (permits one table). An INACTIVE row is history and keeps whatever it holds (rows 29, 157, 164).
  if new.status = 'INACTIVE' then
    return new;
  end if;
  -- The DERM readers that test gdo_number ~ '^GDO-[0-9]+$' rely on this: only a GDO permit may carry a GDO number.
  if new.permit_type <> 'GDO' and new.gdo_number ~* '^[[:space:]]*GDO' then
    raise exception 'A number starting with GDO is a Miami-Dade GDO permit. Choose the GDO type, or change the number.'
      using errcode = '22023', detail = 'blocker=gdo_number_needs_gdo_type in public.fn_permit_number_matches_type';
  end if;
  select t.number_pattern, t.name, t.status into v_pattern, v_name, v_type_status from public.permit_types t where t.code = new.permit_type;
  -- 2026-11-02_2030 (Fred: "we don't have a PSO miami remove it"): a retired type stays only on INACTIVE rows.
  if v_type_status is not null and v_type_status <> 'ACTIVE' then
    raise exception 'We no longer use % permits. Pick another permit type, or mark this permit inactive.', v_name
      using errcode = '22023', detail = 'blocker=permit_type_retired in public.fn_permit_number_matches_type';
  end if;
  if v_pattern is not null and new.gdo_number !~ v_pattern then
    if new.permit_type = 'GDO' then
      raise exception 'A GDO permit number looks like GDO-12345: GDO, a dash, then digits.'
        using errcode = '22023', detail = 'blocker=number_pattern in public.fn_permit_number_matches_type';
    end if;
    raise exception 'The number % is not in the % format.', new.gdo_number, v_name
      using errcode = '22023', detail = 'blocker=number_pattern in public.fn_permit_number_matches_type';
  end if;
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION client.upsert_gdo_permit(p_gdo_id bigint, p_client_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_allowed text[] := array[
    'gdo_number','nickname','location_label','permit_expiration','max_frequency_days',
    'permit_document_path','status','notes','property_id','client_location_id',
    'permit_type','permit_effective'   -- 2026-11-02, permits for every county
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
  perform hr.fn_check_app('client_app', 'edit', 'save a GDO permit');   -- 2026-10-21_0900 access phase 5
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if not public.fn_is_staff_email(lower(coalesce(auth.jwt() ->> 'email','')))
      then
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

  -- 2026-11-02 (permits one table): the type must be a live permit type; the effective date is a bare date.
  -- Whether the number fits the type is checked for every writer by trg_aa_permit_number_matches_type.
  if p_patch ? 'permit_type' and not exists (
       select 1 from public.permit_types t
        where t.code = btrim(coalesce(p_patch->>'permit_type','')) and t.status = 'ACTIVE') then
    raise exception 'Unknown permit type %. Pick one from the list.', coalesce(nullif(btrim(p_patch->>'permit_type'),''), '(blank)')
      using errcode = '22023';
  end if;
  if p_patch ? 'permit_effective'
     and nullif(p_patch->>'permit_effective','') is not null
     and p_patch->>'permit_effective' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception 'permit_effective must be a bare date YYYY-MM-DD (got %)',
      p_patch->>'permit_effective' using errcode = '22023';
  end if;

  -- ⚠ BUG 3 FIX. Upper bound. This column drives customer.permits.over_gdo_max
  -- and `compliant`, which the Field Portal shows to the CLIENT, so an inflated
  -- ceiling silently reports a non-compliant site as compliant. Real values are
  -- 30/60/90; 365 is a generous ceiling that still catches 900-for-90.
  if p_patch ? 'max_frequency_days' then
    v_freq := nullif(btrim(coalesce(p_patch->>'max_frequency_days','')),'')::integer;
    if v_freq is not null and (v_freq < 1 or v_freq > 365) then
      raise exception 'max_frequency_days must be between 1 and 365 days (got %). This is the permit''s cleaning ceiling; typical values are 30, 60 or 90.',
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
      raise exception 'property_id is required when creating a permit (a permit is issued to a location, not a business)'
        using errcode = '22023';
    end if;
    -- 2026-11-02, Fred: "the PDF is optional" for every permit type, GDO included. This replaces the 2026-09-22
    -- rule "we cannot have a GDO number without having the GDO file" (and its CHECK, dropped in 2026-11-02_1800).
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
      max_frequency_days, permit_document_path, status, notes, property_id, client_location_id,
      permit_type, permit_effective
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
      nullif(p_patch->>'client_location_id','')::bigint,
      coalesce(nullif(btrim(p_patch->>'permit_type'),''), 'GDO'),
      nullif(p_patch->>'permit_effective','')::date
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
                                else g.client_location_id end,
      permit_type = case when p_patch ? 'permit_type'
                         then btrim(p_patch->>'permit_type') else g.permit_type end,
      permit_effective = case when p_patch ? 'permit_effective'
                              then nullif(p_patch->>'permit_effective','')::date
                              else g.permit_effective end
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
$function$;

update public.gdos
   set gdo_number = 'GDO-' || lpad(substring(gdo_number from 5)::bigint::text, 5, '0')
 where permit_type = 'GDO' and gdo_number ~ '^GDO-[0-9]{6}$'
   and id <= 313 and id not in (144, 307, 309, 310, 311);

drop index public.gdos_client_gdo_unique;
alter table public.gdos add constraint gdos_client_gdo_unique unique (client_id, gdo_number);

do $verify$
begin
  if md5(pg_get_functiondef('public.fn_permit_number_matches_type()'::regprocedure)) <> 'e923d5cb3f1e3b09e8d4e8d89973e2be'
     or md5(pg_get_functiondef('client.upsert_gdo_permit(bigint,bigint,jsonb)'::regprocedure)) <> '34d9241e27d87c3c935fd868303eedfe' then
    raise exception 'VERIFY: a function body is not the pre-migration one';
  end if;
end
$verify$;

commit;
