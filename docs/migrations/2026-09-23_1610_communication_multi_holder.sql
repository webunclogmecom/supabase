-- 2026-09-23 16:10 ET
-- Invoice and City report become MULTI-HOLDER. Drops the two one-per unique indexes AND the
-- take-over in client.save_contact_settings, which is the half that actually enforced it.
--
-- 🛑 WHY THE INVOICE RULE WAS WRONG. It was justified as "one invoice, one payer". That is
-- false, and our own data says so: Jobber's `defaultEmails(emailType: INVOICE_SENT)` is an ARRAY,
-- and of 34 clients read on 2026-09-23, **25 hold one address, 8 hold two, and 1 holds three** -
-- `accounts@stfoan.com` + `admin@stfoan.com`, `gaston@cookunity.com` + `invoices@cookunity.com`,
-- `info@mrspasta.com` + `david@mrspasta.com`, and 030-KGC with three. The office adds recipients in
-- Jobber's Send window and Jobber remembers all of them. (Those 34 are the clients with a distinct
-- accounting contact, NOT a random sample, so treat 9-of-34 as an existence proof and not a rate.)
--
-- 🛑 AND THE OLD RULE DESTROYED INFORMATION. Because invoice was one-per-client, the RPC
-- DELETED the current holder before inserting the new one. For a client whose invoices really do go
-- to two people, the record could not represent it, and the act of trying to record the second
-- erased the first. 394 of 397 invoice rows sit on the client-record PRIMARY card, so that is what
-- was being silently un-ticked.
--
-- 🛑 WHY CITY REPORT WAS WRONG. Its one-per-property index carried no stated business
-- reason - the migration comment beside it only explains why no NULLS clause is needed. Meanwhile
-- `send-derm-email` reads the preference rows into arrays and resolves them into a de-duplicated
-- Set for a CC list: the consumer was built for many all along. And its sibling Service report,
-- tagged the same "SENT BY US", explicitly allows several ("More than one person can be on this").
-- Same category, opposite rule, no argument for the difference.
--
-- ⚠ DROPPING THE INDEXES ALONE WOULD LOOK FIXED AND STILL OVERWRITE. The take-over DELETEs in
-- the RPC are the enforcement; the indexes are the backstop. Both go, in one migration.
--
-- ⚠ NO DATA MIGRATION. Dropping a unique index never invalidates an existing row: the 397
-- single invoice holders stay exactly as they are, and there are 0 city_report rows. Nothing is
-- created or moved here.
--
-- Body spliced from the live definition (md5 c09055ec708890bbd89fb8f0c4020886), never retyped;
-- the ONLY change is the removal of the twelve-line take-over block.
--
-- ⚠ STILL TO DO, deliberately not in this migration: the app copy still says "One contact per
-- location." and "Only one contact per client can be marked as the invoice contact.", and the drift
-- banner still compares against a single holder. Those are Client App changes.

begin;

-- ── PART 1: the backstops ───────────────────────────────────
drop index if exists public.client_comm_one_invoice_per_client;
drop index if exists public.client_comm_one_city_report_per_property;

-- ── PART 2: the enforcement ─────────────────────────────────
CREATE OR REPLACE FUNCTION client.save_contact_settings(p_source text, p_contact_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_allowed text[] := array['person_role','person_role_other','communication'];
  v_types   text[] := array['invoice','quote_approval','service_report','city_report'];
  v_bad text[]; v_client bigint; v_email text; v_label text; v_deleted timestamptz;
  v_role text; v_other text; v_comm jsonb; v_item jsonb; v_t text;
  v_prop bigint; v_prop_txt text; v_holder text; v_out jsonb;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_source is null or p_source <> all (array['ours','jobber']) then
    raise exception 'p_source must be ''ours'' or ''jobber''.' using errcode = '22023';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    raise exception 'p_patch must be a non-empty JSON object.' using errcode = '22023';
  end if;
  select array_agg(k) into v_bad from jsonb_object_keys(p_patch) k where k <> all (v_allowed);
  if v_bad is not null then
    raise exception 'unsupported field(s): %. Allowed: %', v_bad, v_allowed using errcode = '22023';
  end if;

  if p_source = 'ours' then
    select cc.client_id, cc.email,
           coalesce(nullif(btrim(concat_ws(' ', cc.first_name, cc.last_name)),''), cc.name, 'This contact'),
           cc.person_role, cc.person_role_other
      into v_client, v_email, v_label, v_role, v_other
      from public.client_contacts cc where cc.id = p_contact_id;
  else
    select jc.client_id, jc.email,
           coalesce(nullif(btrim(jc.name),''),
                    nullif(btrim(concat_ws(' ', jc.first_name, jc.last_name)),''), 'This contact'),
           jc.person_role, jc.person_role_other, jc.deleted_at
      into v_client, v_email, v_label, v_role, v_other, v_deleted
      from public.client_jobber_contacts jc where jc.id = p_contact_id;
  end if;
  if v_client is null then
    raise exception 'That contact no longer exists.'
      using errcode = 'P0002', detail = 'blocker=contact_not_found id=' || p_contact_id;
  end if;
  if v_deleted is not null then
    raise exception '% has been removed in Jobber, so its settings cannot be changed here.', v_label
      using errcode = '22023', detail = 'blocker=jobber_contact_removed id=' || p_contact_id;
  end if;

  ---- role ------------------------------------------------------------------------------
  if p_patch ? 'person_role' then
    v_role := lower(nullif(btrim(coalesce(p_patch->>'person_role','')),''));
  end if;
  if p_patch ? 'person_role_other' then
    v_other := nullif(btrim(coalesce(p_patch->>'person_role_other','')),'');
  end if;
  if v_role is not null and v_role <> all (array['store_manager','accounting','owner','other']) then
    raise exception 'Unknown role "%".', v_role
      using errcode = '22023', detail = 'blocker=person_role_unknown value=' || coalesce(v_role,'(null)');
  end if;
  if v_role = 'other' and v_other is null then
    raise exception 'Say what the role is, or pick one from the list.'
      using errcode = '22023', detail = 'blocker=person_role_other_blank';
  end if;
  if v_role is distinct from 'other' then v_other := null; end if;   -- never keep stale free text

  if p_patch ? 'person_role' or p_patch ? 'person_role_other' then
    if p_source = 'ours' then
      update public.client_contacts
         set person_role = v_role, person_role_other = v_other where id = p_contact_id;
    else
      update public.client_jobber_contacts
         set person_role = v_role, person_role_other = v_other where id = p_contact_id;
    end if;
  end if;

  ---- communication ---------------------------------------------------------------------
  if p_patch ? 'communication' then
    v_comm := p_patch->'communication';
    if jsonb_typeof(v_comm) <> 'array' then
      raise exception 'communication must be a list.' using errcode = '22023';
    end if;

    -- replace-the-set: unticking is a delete that leaves no row behind
    delete from public.client_communication_prefs
     where (p_source = 'ours'   and contact_id        = p_contact_id)
        or (p_source = 'jobber' and jobber_contact_id = p_contact_id);

    -- 🛑 AN EMPTY EMAIL CLEARS THE SET, IT DOES NOT RAISE. The modal lets you remove an address
    -- from a contact that holds boxes, and warns that the boxes go with it. If this raised, that
    -- save would be impossible and the warning would be a lie. So the guard sits AFTER the
    -- delete and only fires when something is being TICKED.
    if coalesce(btrim(v_email),'') = '' and jsonb_array_length(v_comm) > 0 then
      raise exception '% has no email address, so it cannot be set to receive anything. Add an email first.', v_label
        using errcode = '22023', detail = 'blocker=contact_has_no_email id=' || p_contact_id;
    end if;

    for v_item in select * from jsonb_array_elements(v_comm) loop
      v_t := lower(nullif(btrim(coalesce(v_item->>'type','')),''));
      if v_t is null or v_t <> all (v_types) then
        raise exception 'Unknown communication type "%".', coalesce(v_t,'')
          using errcode = '22023', detail = 'blocker=communication_type_unknown value=' || coalesce(v_t,'(null)');
      end if;
      -- 🛑 the comma-bag guard, in the DATABASE and not only in the UI. Rows holding several
      -- addresses in one field exist; Resend would send to a single malformed address and
      -- report success.
      if v_email like '%,%' then
        raise exception '% holds several addresses in one field ("%"). Split them into separate contacts before ticking anything.', v_label, v_email
          using errcode = '22023', detail = 'blocker=contact_email_is_a_list id=' || p_contact_id;
      end if;

      v_prop_txt := nullif(btrim(coalesce(v_item->>'property_id','')),'');
      if v_prop_txt is not null then
        if v_prop_txt !~ '^[0-9]+$' then   -- a bare ::bigint on junk raises an unreadable 22P02
          raise exception 'property_id must be a positive integer, got %', v_prop_txt using errcode = '22023';
        end if;
        v_prop := v_prop_txt::bigint;
      else
        v_prop := null;
      end if;

      if v_t = 'city_report' then
        if v_prop is null then
          raise exception 'City report is set per location. Pick which location % is told about.', v_label
            using errcode = '22023', detail = 'blocker=city_report_needs_location';
        end if;
        if not exists (select 1 from public.properties p
                        where p.id = v_prop and p.client_id = v_client and p.deleted_at is null) then
          raise exception 'That location does not belong to this client.'
            using errcode = '22023', detail = 'blocker=location_not_on_this_client property_id=' || v_prop;
        end if;
      elsif v_prop is not null then
        raise exception 'That communication covers the whole client, not one location.'
          using errcode = '22023', detail = 'blocker=communication_is_client_wide type=' || coalesce(v_t,'(null)');
      end if;

      -- ✅ TAKE-OVER RETIRED 2026-09-23. All four communications are now MULTI-HOLDER, so
      -- ticking one on a second person no longer deletes it from the first. The two DELETEs that
      -- used to sit here (invoice client-wide, city_report per property) were the real enforcement;
      -- the two partial unique indexes dropped in this migration were only the backstop, and
      -- dropping those ALONE would have looked fixed while still silently overwriting.
      -- Why: Jobber's defaultEmails(INVOICE_SENT) is an ARRAY and already holds more than one
      -- address on real clients (measured: of 34 read, 25 hold one, 8 hold two, 1 holds three -
      -- accounts@ + admin@, gaston@ + invoices@, and so on). An invoice genuinely goes to several
      -- people, so a record that can name only one could not express the truth, and the take-over
      -- destroyed the first name while trying. City report is a CC on an email WE send, and
      -- send-derm-email already resolves it into a de-duplicated Set - it was built for many all
      -- along. service_report and quote_approval were already multi-holder and are unchanged.

      begin
        insert into public.client_communication_prefs
          (client_id, comm_type, contact_id, jobber_contact_id, property_id)
        values (v_client, v_t,
                case when p_source = 'ours'   then p_contact_id end,
                case when p_source = 'jobber' then p_contact_id end,
                v_prop);
      exception when unique_violation then
        -- 🛑 name the holder. A raw 23505 in front of a person is the error this catch exists
        -- to stop, and the sentence is the operator-message rule: plain language in MESSAGE.
        select coalesce(
          (select coalesce(nullif(btrim(concat_ws(' ', c2.first_name, c2.last_name)),''), c2.name)
             from public.client_communication_prefs q
             join public.client_contacts c2 on c2.id = q.contact_id
            where q.client_id = v_client and q.comm_type = v_t
              and (v_t <> 'city_report' or q.property_id = v_prop)),
          (select coalesce(nullif(btrim(j2.name),''),
                           nullif(btrim(concat_ws(' ', j2.first_name, j2.last_name)),''))
             from public.client_communication_prefs q
             join public.client_jobber_contacts j2 on j2.id = q.jobber_contact_id
            where q.client_id = v_client and q.comm_type = v_t
              and (v_t <> 'city_report' or q.property_id = v_prop)),
          'Another contact') into v_holder;
        if v_t = 'invoice' then
          -- 🛑 OUR RULE, NOT JOBBER'S. Never "receives", never "only one person can receive".
          raise exception 'Only one contact can be marked as the invoice contact, and % already is. Untick it there first.', v_holder
            using errcode = '23505', detail = 'blocker=invoice_already_held';
        elsif v_t = 'city_report' then
          raise exception 'Only one contact is told per location when we email the city, and % already is for this location. Untick it there first.', v_holder
            using errcode = '23505', detail = 'blocker=city_report_already_held';
        else
          raise exception '% already has that ticked.', v_holder
          using errcode = '23505', detail = 'blocker=duplicate_in_one_submission type=' || coalesce(v_t,'(null)');
        end if;
      end;
    end loop;
  end if;

  if p_source = 'ours' then
    select to_jsonb(v) into v_out from client.client_contacts v where v.id = p_contact_id;
  else
    select to_jsonb(v) into v_out from client.jobber_contacts  v where v.id = p_contact_id;
  end if;
  return v_out;
end $function$;

-- ── VERIFY ─────────────────────────────────────────────
do $v$
declare
  n_idx int; n_inv int; n_city int; n_prefs int; n_takeover int;
  v_c bigint; v_a bigint; v_b bigint; n_after int;
begin
  select count(*) into n_idx from pg_indexes
   where tablename = 'client_communication_prefs'
     and indexname in ('client_comm_one_invoice_per_client','client_comm_one_city_report_per_property');
  select count(*) into n_inv  from public.client_communication_prefs where comm_type = 'invoice';
  select count(*) into n_city from public.client_communication_prefs where comm_type = 'city_report';
  select count(*) into n_prefs from public.client_communication_prefs;

  -- the take-over must be GONE from the live body, not merely absent from this file
  select count(*) into n_takeover
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'client' and p.proname = 'save_contact_settings'
     and pg_get_functiondef(p.oid) ~ 'q\.comm_type = ''(invoice|city_report)''';

  if n_idx <> 0 then raise exception 'expected both one-per indexes dropped, % remain', n_idx; end if;
  if n_takeover <> 0 then raise exception 'a take-over DELETE survives in the live function body'; end if;
  if n_inv  <> 397 then raise exception 'invoice rows moved: expected 397, found % - nothing should have been created or deleted', n_inv; end if;
  if n_city <> 0   then raise exception 'city_report rows moved: expected 0, found %', n_city; end if;
  if n_prefs <> 1191 then raise exception 'total pref rows moved: expected 1191, found %', n_prefs; end if;

  -- 🛑 THE ONE THAT MATTERS: two contacts of the SAME client can now BOTH hold invoice.
  -- Proven on a throwaway client inside a savepoint, then rolled back. Without this the migration
  -- only asserts that things are ABSENT, which a no-op would also satisfy.
  begin
    insert into public.clients (name, status) values ('[TEST] multi-holder probe', 'ACTIVE') returning id into v_c;
    insert into public.client_contacts (client_id, property_id, contact_role, name, email)
      values (v_c, null, 'primary', '[TEST] A', 'a@example.com') returning id into v_a;
    insert into public.client_contacts (client_id, property_id, contact_role, name, email)
      values (v_c, null, 'accounting', '[TEST] B', 'b@example.com') returning id into v_b;
    -- the seed trigger may have given A its three rows; clear and set the case explicitly
    delete from public.client_communication_prefs where client_id = v_c;
    insert into public.client_communication_prefs (client_id, comm_type, contact_id) values (v_c, 'invoice', v_a);
    insert into public.client_communication_prefs (client_id, comm_type, contact_id) values (v_c, 'invoice', v_b);
    select count(*) into n_after from public.client_communication_prefs where client_id = v_c and comm_type = 'invoice';
    if n_after <> 2 then raise exception 'two invoice holders on one client were refused (got %)', n_after; end if;
    raise exception 'ROLLBACK_PROBE';
  exception
    when others then
      if sqlerrm <> 'ROLLBACK_PROBE' then raise; end if;
  end;

  raise notice 'indexes dropped, take-over gone, two invoice holders accepted; invoice=% city=% total=%',
    n_inv, n_city, n_prefs;
end $v$;

commit;
