-- 2026-08-13_2320_contact_guard_wording.sql
--
-- WHAT: reword the TWO refusal messages in client.update_client_contact. Behaviour is
--       unchanged: same guards, same errcodes, same rows refused. Only the sentences move.
--
-- WHY (Fred, 2026-08-13): *"why do we have 'A client-level Primary contact is owned by
--      Jobber — pick a property or choose a different role.'?"* Both messages told the user
--      that Jobber owns the client-level primary and that they should go there. That was
--      completely true this morning and is now HALF WRONG, because of a change shipped hours
--      earlier the same day.
--
-- 🛑 THE STALENESS IS SELF-INFLICTED, WHICH IS WHY IT IS WORTH A MIGRATION OF ITS OWN.
--      `save-client-contact` (2026-08-13) made the primary's EMAIL and PHONE editable from the
--      Client App: it pushes clientEdit, re-reads, verifies, then writes our DB, so the poll
--      converges. Telling a user "change it in Jobber and it will appear here" now sends them
--      to do by hand the exact thing the app just did for them.
--
-- WHAT EACH MESSAGE SHOULD HAVE SAID, and now does:
--   line 52 (42501, editing the primary through THIS rpc)
--     was: "…syncs from Jobber — edits here are overwritten within about five minutes.
--           Change it in Jobber and it will appear here automatically."
--     now: names save-client-contact as the sanctioned path. The refusal itself is CORRECT and
--          stays: a direct write here still would be overwritten by the next poll. Only the
--          instruction changed, from "go to Jobber" to "go through the verified saga".
--   line 105 (22023, promoting some OTHER contact TO client-level primary)
--     was: "The client-level main contact is managed in Jobber…"
--     now: "This client already has a client-level main contact and there can only be one…"
--          ⇒ This states the ACTUAL constraint instead of an ownership claim. The rule is not a
--            policy about Jobber, it is a UNIQUE INDEX:
--                client_contacts_client_property_role_key
--                  UNIQUE (client_id, property_id, contact_role) NULLS NOT DISTINCT
--            NULLS NOT DISTINCT is the load-bearing half: (client_id, NULL, 'primary') can
--            exist exactly ONCE, so a second one raises 23505. Measured: 0 clients hold a
--            duplicate today, so the constraint is holding and this guard is what keeps the
--            app from producing a 23505 the user cannot interpret.
--
-- ⚠ THE APP CARRIES ITS OWN COPY OF THE SECOND SENTENCE and it is reworded in the same cycle
--   (Client App, contact dialog: "A client-level Primary contact is owned by Jobber — …").
--   Two copies of one rule WILL drift; they are changed together on purpose.
--
-- BODY: COPIED from the live pg_get_functiondef output and patched by two unique anchors.
--       Diff proven before this file was written: EXACTLY 2 lines differ, 52 and 105.
--       Nothing else moved — that is a measurement, not a claim.
--
-- AUDIT (ADR 010): no schema change; public.client_contacts already carries its audit trigger
--       (verified in pg_trigger, with public.clients as the control). No trigger change.

BEGIN;

CREATE OR REPLACE FUNCTION client.update_client_contact(p_contact_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_allowed  text[] := array['first_name','last_name','email','phone','contact_role','property_id'];
  v_roles    text[] := array['primary','accounting','city'];
  v_bad      text[];
  v_row      public.client_contacts;
  v_first    text;
  v_last     text;
  v_email    text;
  v_phone    text;
  v_role     text;
  v_prop     bigint;
  v_prop_txt text;
  v_jobber   boolean;
  v_name     text;
  v_out      public.client_contacts;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_contact_id is null then
    raise exception 'p_contact_id is required' using errcode = '22023';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    raise exception 'p_patch must be a non-empty JSON object' using errcode = '22023';
  end if;

  select array_agg(k) into v_bad
  from jsonb_object_keys(p_patch) k where k <> all (v_allowed);
  if v_bad is not null then
    raise exception 'unsupported field(s) for a contact: %. Allowed: %', v_bad, v_allowed
      using errcode = '22023';
  end if;

  select * into v_row from public.client_contacts where id = p_contact_id;
  if not found then
    raise exception 'contact % not found', p_contact_id using errcode = 'P0002';
  end if;

  -- The ownership boundary (see header).
  v_jobber := v_row.property_id is null and v_row.contact_role = 'primary';
  if v_jobber then
    raise exception 'This is the client''s main contact. Its email and phone are saved through the save-client-contact edge function, which pushes to Jobber first and verifies — a direct write here would be overwritten by the next Jobber poll.'
      using errcode = '42501';
  end if;

  v_first := case when p_patch ? 'first_name'
                  then nullif(btrim(coalesce(p_patch->>'first_name','')),'') else v_row.first_name end;
  v_last  := case when p_patch ? 'last_name'
                  then nullif(btrim(coalesce(p_patch->>'last_name','')),'')  else v_row.last_name end;
  v_email := case when p_patch ? 'email'
                  then nullif(btrim(coalesce(p_patch->>'email','')),'')      else v_row.email end;
  v_phone := case when p_patch ? 'phone'
                  then nullif(btrim(coalesce(p_patch->>'phone','')),'')      else v_row.phone end;
  v_role  := case when p_patch ? 'contact_role'
                  then lower(nullif(btrim(coalesce(p_patch->>'contact_role','')),''))
                  else v_row.contact_role end;

  if p_patch ? 'property_id' then
    v_prop_txt := nullif(btrim(coalesce(p_patch->>'property_id','')), '');
    if v_prop_txt is null then
      v_prop := null;
    else
      if v_prop_txt !~ '^[0-9]+$' then
        raise exception 'property_id must be a positive integer, got %', v_prop_txt
          using errcode = '22023';
      end if;
      v_prop := v_prop_txt::bigint;
      if not exists (select 1 from public.properties p
                     where p.id = v_prop and p.client_id = v_row.client_id) then
        raise exception 'Property % does not belong to this client.', v_prop
          using errcode = '22023';
      end if;
    end if;
  else
    v_prop := v_row.property_id;
  end if;

  -- Same required set as create: a name, and at least one contact method.
  if v_first is null then
    raise exception 'First name is required.' using errcode = '22023';
  end if;
  if v_email is null and v_phone is null then
    raise exception 'Enter at least a phone number or an email address.' using errcode = '22023';
  end if;
  if v_role is null or v_role <> all (v_roles) then
    raise exception 'contact_role must be one of %', v_roles using errcode = '22023';
  end if;
  if v_email is not null and v_email not like '%_@_%.__%' then
    raise exception '% is not a valid email address.', v_email using errcode = '22023';
  end if;

  -- ⚠ Moving a contact TO client-level primary would collide with the
  -- Jobber-synced row (UNIQUE NULLS NOT DISTINCT) or, worse, become one.
  if v_prop is null and v_role = 'primary' then
    raise exception 'This client already has a client-level main contact and there can only be one. Pick a property, or use the accounting or city role.'
      using errcode = '22023';
  end if;

  v_name := btrim(concat_ws(' ', v_first, v_last));

  begin
    update public.client_contacts set
      first_name   = v_first,
      last_name    = v_last,
      email        = v_email,
      phone        = v_phone,
      contact_role = v_role,
      property_id  = v_prop,
      -- keep the display value coherent; `name` is what existing readers use
      name         = case when v_name = '' then name else v_name end
    where id = p_contact_id
    returning * into v_out;
  exception when unique_violation then
    raise exception 'That property already has a % contact. Edit that one instead.', v_role
      using errcode = '23505';
  end;

  return to_jsonb(v_out);
end
$function$;


REVOKE ALL ON FUNCTION client.update_client_contact(bigint, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION client.update_client_contact(bigint, jsonb) FROM anon;
GRANT EXECUTE ON FUNCTION client.update_client_contact(bigint, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION client.update_client_contact(bigint, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- assertions. EXERCISE both guards as the REAL role, and prove the rest of the
-- function still works — a wording change that silently broke a code path would
-- otherwise look identical to a clean one.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_primary bigint; v_acct bigint; v_client bigint; v_msg text; v_state text; n int;
BEGIN
  -- pick a client that has BOTH, or the fixtures below cannot exercise anything
  SELECT cc.client_id INTO v_client
    FROM public.client_contacts cc
   WHERE cc.property_id IS NULL AND cc.contact_role = 'primary'
     AND EXISTS (SELECT 1 FROM public.client_contacts a
                  WHERE a.client_id = cc.client_id AND a.contact_role = 'accounting')
   ORDER BY cc.client_id LIMIT 1;
  SELECT cc.id INTO v_primary FROM public.client_contacts cc
   WHERE cc.client_id = v_client AND cc.property_id IS NULL AND cc.contact_role = 'primary'
   ORDER BY cc.id LIMIT 1;
  SELECT cc.id INTO v_acct FROM public.client_contacts cc
   WHERE cc.client_id = v_client AND cc.contact_role = 'accounting'
   ORDER BY cc.id LIMIT 1;

  IF v_primary IS NULL OR v_acct IS NULL THEN
    RAISE EXCEPTION 'CONTROL FAILED: no client with BOTH a client-level primary and an accounting contact, so neither guard below can be exercised';
  END IF;

  -- (A) the 42501 edit guard still fires, and now names the saga rather than Jobber
  BEGIN
    PERFORM set_config('request.jwt.claims',
      json_build_object('email','fred@ayache.com','sub','00000000-0000-0000-0000-000000000000')::text, true);
    SET LOCAL ROLE authenticated;
    PERFORM client.update_client_contact(v_primary, '{"email":"probe@ayache.com"}'::jsonb);
    RESET ROLE;
    RAISE EXCEPTION 'GUARD FAILED: the rpc accepted an edit to the client-level primary';
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
    IF v_msg LIKE 'GUARD FAILED%' THEN RAISE; END IF;
    IF v_state <> '42501' THEN
      RAISE EXCEPTION 'the edit guard changed errcode: got % (%)', v_state, left(v_msg,90);
    END IF;
    IF v_msg NOT LIKE '%save-client-contact%' THEN
      RAISE EXCEPTION 'the 42501 message does not name save-client-contact: %', left(v_msg,140);
    END IF;
    IF v_msg LIKE '%Change it in Jobber%' THEN
      RAISE EXCEPTION 'the STALE sentence survived the patch: %', left(v_msg,140);
    END IF;
  END;

  -- (B) the 22023 promotion guard still fires, and now states the real constraint
  BEGIN
    PERFORM set_config('request.jwt.claims',
      json_build_object('email','fred@ayache.com','sub','00000000-0000-0000-0000-000000000000')::text, true);
    SET LOCAL ROLE authenticated;
    PERFORM client.update_client_contact(v_acct, '{"contact_role":"primary","first_name":"Probe"}'::jsonb);
    RESET ROLE;
    RAISE EXCEPTION 'GUARD FAILED: the rpc allowed a SECOND client-level primary';
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
    IF v_msg LIKE 'GUARD FAILED%' THEN RAISE; END IF;
    IF v_state <> '22023' THEN
      RAISE EXCEPTION 'the promotion guard changed errcode: got % (%)', v_state, left(v_msg,90);
    END IF;
    IF v_msg NOT LIKE '%there can only be one%' THEN
      RAISE EXCEPTION 'the 22023 message was not reworded: %', left(v_msg,140);
    END IF;
    IF v_msg LIKE '%managed in Jobber%' THEN
      RAISE EXCEPTION 'the STALE sentence survived the patch: %', left(v_msg,140);
    END IF;
  END;

  -- (C) 🛑 THE CONTROL THAT MAKES (A) AND (B) MEAN ANYTHING. A wording change that broke the
  --     function outright would make every call raise, and both tests above only assert THAT
  --     a raise happened. So prove a LEGITIMATE edit still succeeds. Rolled back below.
  PERFORM set_config('request.jwt.claims',
    json_build_object('email','fred@ayache.com','sub','00000000-0000-0000-0000-000000000000')::text, true);
  SET LOCAL ROLE authenticated;
  PERFORM client.update_client_contact(v_acct, '{"phone":"3055551234","first_name":"Probe"}'::jsonb);
  RESET ROLE;
  SELECT count(*) INTO n FROM public.client_contacts WHERE id = v_acct AND phone = '3055551234';
  IF n <> 1 THEN RAISE EXCEPTION 'CONTROL FAILED: a legitimate accounting edit did not land'; END IF;

  -- (D) and the unsupported-field guard is untouched
  BEGIN
    PERFORM set_config('request.jwt.claims',
      json_build_object('email','fred@ayache.com','sub','00000000-0000-0000-0000-000000000000')::text, true);
    SET LOCAL ROLE authenticated;
    PERFORM client.update_client_contact(v_acct, '{"nonsense":"x"}'::jsonb);
    RESET ROLE;
    RAISE EXCEPTION 'GUARD FAILED: the rpc accepted an unsupported field';
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg LIKE 'GUARD FAILED%' THEN RAISE; END IF;
  END;

  RAISE NOTICE 'OK: both guards fire with the new wording, the stale sentences are gone, and a legitimate edit still lands';
END $$;

-- 🛑 assertion (C) really wrote a phone. Roll the whole probe back, then re-apply the DDL.
ROLLBACK;

BEGIN;

CREATE OR REPLACE FUNCTION client.update_client_contact(p_contact_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_allowed  text[] := array['first_name','last_name','email','phone','contact_role','property_id'];
  v_roles    text[] := array['primary','accounting','city'];
  v_bad      text[];
  v_row      public.client_contacts;
  v_first    text;
  v_last     text;
  v_email    text;
  v_phone    text;
  v_role     text;
  v_prop     bigint;
  v_prop_txt text;
  v_jobber   boolean;
  v_name     text;
  v_out      public.client_contacts;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_contact_id is null then
    raise exception 'p_contact_id is required' using errcode = '22023';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    raise exception 'p_patch must be a non-empty JSON object' using errcode = '22023';
  end if;

  select array_agg(k) into v_bad
  from jsonb_object_keys(p_patch) k where k <> all (v_allowed);
  if v_bad is not null then
    raise exception 'unsupported field(s) for a contact: %. Allowed: %', v_bad, v_allowed
      using errcode = '22023';
  end if;

  select * into v_row from public.client_contacts where id = p_contact_id;
  if not found then
    raise exception 'contact % not found', p_contact_id using errcode = 'P0002';
  end if;

  -- The ownership boundary (see header).
  v_jobber := v_row.property_id is null and v_row.contact_role = 'primary';
  if v_jobber then
    raise exception 'This is the client''s main contact. Its email and phone are saved through the save-client-contact edge function, which pushes to Jobber first and verifies — a direct write here would be overwritten by the next Jobber poll.'
      using errcode = '42501';
  end if;

  v_first := case when p_patch ? 'first_name'
                  then nullif(btrim(coalesce(p_patch->>'first_name','')),'') else v_row.first_name end;
  v_last  := case when p_patch ? 'last_name'
                  then nullif(btrim(coalesce(p_patch->>'last_name','')),'')  else v_row.last_name end;
  v_email := case when p_patch ? 'email'
                  then nullif(btrim(coalesce(p_patch->>'email','')),'')      else v_row.email end;
  v_phone := case when p_patch ? 'phone'
                  then nullif(btrim(coalesce(p_patch->>'phone','')),'')      else v_row.phone end;
  v_role  := case when p_patch ? 'contact_role'
                  then lower(nullif(btrim(coalesce(p_patch->>'contact_role','')),''))
                  else v_row.contact_role end;

  if p_patch ? 'property_id' then
    v_prop_txt := nullif(btrim(coalesce(p_patch->>'property_id','')), '');
    if v_prop_txt is null then
      v_prop := null;
    else
      if v_prop_txt !~ '^[0-9]+$' then
        raise exception 'property_id must be a positive integer, got %', v_prop_txt
          using errcode = '22023';
      end if;
      v_prop := v_prop_txt::bigint;
      if not exists (select 1 from public.properties p
                     where p.id = v_prop and p.client_id = v_row.client_id) then
        raise exception 'Property % does not belong to this client.', v_prop
          using errcode = '22023';
      end if;
    end if;
  else
    v_prop := v_row.property_id;
  end if;

  -- Same required set as create: a name, and at least one contact method.
  if v_first is null then
    raise exception 'First name is required.' using errcode = '22023';
  end if;
  if v_email is null and v_phone is null then
    raise exception 'Enter at least a phone number or an email address.' using errcode = '22023';
  end if;
  if v_role is null or v_role <> all (v_roles) then
    raise exception 'contact_role must be one of %', v_roles using errcode = '22023';
  end if;
  if v_email is not null and v_email not like '%_@_%.__%' then
    raise exception '% is not a valid email address.', v_email using errcode = '22023';
  end if;

  -- ⚠ Moving a contact TO client-level primary would collide with the
  -- Jobber-synced row (UNIQUE NULLS NOT DISTINCT) or, worse, become one.
  if v_prop is null and v_role = 'primary' then
    raise exception 'This client already has a client-level main contact and there can only be one. Pick a property, or use the accounting or city role.'
      using errcode = '22023';
  end if;

  v_name := btrim(concat_ws(' ', v_first, v_last));

  begin
    update public.client_contacts set
      first_name   = v_first,
      last_name    = v_last,
      email        = v_email,
      phone        = v_phone,
      contact_role = v_role,
      property_id  = v_prop,
      -- keep the display value coherent; `name` is what existing readers use
      name         = case when v_name = '' then name else v_name end
    where id = p_contact_id
    returning * into v_out;
  exception when unique_violation then
    raise exception 'That property already has a % contact. Edit that one instead.', v_role
      using errcode = '23505';
  end;

  return to_jsonb(v_out);
end
$function$;

REVOKE ALL ON FUNCTION client.update_client_contact(bigint, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION client.update_client_contact(bigint, jsonb) FROM anon;
GRANT EXECUTE ON FUNCTION client.update_client_contact(bigint, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION client.update_client_contact(bigint, jsonb) TO service_role;

-- final check: the new wording is live and the stale sentences are gone from the body
DO $$
DECLARE d text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname='client' AND p.proname='update_client_contact';
  IF d LIKE '%Change it in Jobber%' OR d LIKE '%managed in Jobber%' THEN
    RAISE EXCEPTION 'a stale sentence is still in the live body';
  END IF;
  IF d NOT LIKE '%save-client-contact%' OR d NOT LIKE '%there can only be one%' THEN
    RAISE EXCEPTION 'the new wording did not land in the live body';
  END IF;
  RAISE NOTICE 'OK: live body carries the new wording';
END $$;

COMMIT;
