-- ============================================================================
-- 2026-07-30_2148 — Edit contact: client.update_client_contact
-- ============================================================================
-- ASK (Fred, 2026-07-30): "We need to be able to edit specific sections, like
-- the Contacts."
--
-- ---------------------------------------------------------------------------
-- ⚠ THE OWNERSHIP BOUNDARY, MEASURED FIRST (this is the whole design)
-- ---------------------------------------------------------------------------
-- public.client_contacts holds 573 rows in two populations:
--
--   395  client-level primary (property_id IS NULL, contact_role='primary')
--          -> WRITTEN BY JOBBER. webhook-jobber handleClient upserts
--             {name, email, phone} on EVERY CLIENT_CREATE/CLIENT_UPDATE, and the
--             */5 poll replays ~400 synthetic CLIENT_UPDATEs a day. An app edit
--             to these fields is silently reverted within ~5 minutes, and the
--             audit trail then blames app_source='jobber'. This is exactly the
--             wave-2 rule in the phase-2 scoping doc: a Jobber-owned field only
--             becomes writable once the client-side sync rig exists.
--   178  client-level accounting/city (156 + 22)
--          -> OURS. webhook-jobber ONLY ever writes contact_role='primary'
--             (index.ts, the contactRow literal), so nothing upstream touches
--             these. Freely editable.
--     0  per-property (property_id NOT NULL) -> OURS, created by the app's
--          Add contact (2026-07-30). Freely editable.
--
-- ⇒ THIS RPC REFUSES name/email/phone edits ON THE JOBBER-SYNCED PRIMARY with a
--   readable message telling the user to edit it in Jobber. It does NOT silently
--   accept a write that the next poll will erase. Role/property moves on that row
--   are ALSO refused, because changing either would re-key it and the next sync
--   would simply recreate the original primary alongside it (a duplicate).
--   Everything else is fully editable.
--
-- If Fred later wants the primary editable here, the mechanism is the same
-- verified saga the jobs feature uses (push clientEdit -> re-read -> then write),
-- NOT a relaxation of this guard.
--
-- AUDIT: public.client_contacts already carries audit_client_contacts
-- (opted in 2026-07-30_0539). Inherited, no new decision.
--
-- ROLLBACK: drop function client.update_client_contact(bigint, jsonb);
-- ============================================================================

begin;

create or replace function client.update_client_contact(
  p_contact_id bigint,
  p_patch      jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
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
    raise exception 'This is the client''s main contact and it syncs from Jobber — edits here are overwritten within about five minutes. Change it in Jobber and it will appear here automatically.'
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
    raise exception 'The client-level main contact is managed in Jobber. Pick a property, or use the accounting or city role.'
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
$fn$;

revoke all on function client.update_client_contact(bigint, jsonb) from public;
revoke all on function client.update_client_contact(bigint, jsonb) from anon;
grant execute on function client.update_client_contact(bigint, jsonb) to authenticated;

commit;
