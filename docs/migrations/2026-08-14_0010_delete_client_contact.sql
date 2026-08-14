-- 2026-08-14_0010_delete_client_contact.sql
--
-- WHAT: client.delete_client_contact(p_contact_id) — removes an ACCOUNTING or CITY contact
--       (and any per-property contact). Refuses the client-level primary.
--
-- WHY (Fred, 2026-08-13): *"what if the contact changed but we don't have it yet, so we need to
--      delete it"* then *"add delete for accounting and city"*. There was no delete for ANY contact
--      in the app: no RPC, and no Remove/Delete control anywhere in the published bundle. Not a
--      restriction anyone chose — it was simply never built.
--
-- 🛑 THE CLIENT-LEVEL PRIMARY IS REFUSED, AND NOT OUT OF CAUTION — DELETING IT DOES NOT WORK.
--      webhook-jobber.handleClient upserts that row from Jobber on every CLIENT_CREATE/UPDATE
--      (onConflict client_id,property_id,contact_role), and the */5 poll replays ~400 synthetic
--      CLIENT_UPDATEs a day. Delete it and it is back, byte-identical, within about five minutes.
--      Offering the button would be offering an action that silently undoes itself.
--      ⇒ To retire a primary's details, CLEAR or REPLACE them via the save-client-contact edge fn,
--        which writes Jobber first so there is nothing stale left for the poll to restore.
--      The predicate is deliberately IDENTICAL to update_client_contact's ownership boundary
--      (property_id IS NULL AND contact_role = 'primary'), so the two functions cannot drift into
--      disagreeing about which rows are Jobber's.
--
-- 🛑 THIS IS A HARD DELETE, WHICH RULE #6 FORBIDS BY DEFAULT. Here is the measured case for the
--      exception, and Fred's explicit ask is the sign-off that rule requires:
--        - inbound FOREIGN KEYS to public.client_contacts ............ 0
--        - entity_source_links rows referencing a contact ............ 0
--          ⇒ rule #6's OWN stated rationale ("hard deletes break entity_source_links and
--            historical joins") does not apply to this table.
--        - audit trigger present .................................... yes (control: public.clients)
--        - DELETEs already captured in audit.logs ................... 3, and all 3 carry old_row
--          ⇒ recoverability is DEMONSTRATED here, not merely argued. A mistaken delete is
--            restorable from audit.logs.old_row.
--      Precedent: public.zones_hard_delete is sanctioned admin tooling on exactly this basis
--      (audited ⇒ reversible, returns its blast radius, narrow and deliberate).
--
-- ⚠ SOFT-DELETE WAS THE FIRST CHOICE AND WAS REJECTED ON A MECHANISM, NOT A PREFERENCE.
--      public.client_contacts has no deleted_at. Adding one is not enough: the live constraint is
--          client_contacts_client_property_role_key
--            UNIQUE (client_id, property_id, contact_role) NULLS NOT DISTINCT
--      so a soft-deleted row KEEPS OCCUPYING its (client, property, role) slot and the user could
--      never add a replacement accounting contact — the very thing this feature exists for. Making
--      the index PARTIAL (WHERE deleted_at IS NULL) fixes that but breaks something worse:
--      webhook-jobber upserts with onConflict 'client_id,property_id,contact_role', and Postgres
--      cannot INFER a partial index without repeating its WHERE clause, which supabase-js cannot
--      emit. That would break the primary-contact upsert on every poll. ⇒ hard delete.
--      If soft-delete is ever wanted, it is a three-part change (column + partial index + rewriting
--      handleClient's upsert as an explicit lookup), not a one-line addition.
--
-- AUDIT (ADR 010): no schema change. public.client_contacts already carries its audit trigger, so
--      the DELETE is captured with old_row automatically. Assertion (C) proves that rather than
--      assuming it, because the whole hard-delete argument rests on it.

BEGIN;

CREATE OR REPLACE FUNCTION client.delete_client_contact(p_contact_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_row public.client_contacts;
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

  select * into v_row from public.client_contacts where id = p_contact_id;
  if not found then
    raise exception 'contact % not found', p_contact_id using errcode = 'P0002';
  end if;

  -- Same ownership boundary as update_client_contact. See the header: deleting this row does not
  -- stick, because the Jobber poll re-creates it within about five minutes.
  if v_row.property_id is null and v_row.contact_role = 'primary' then
    raise exception 'This is the client''s main contact and it comes from Jobber, so deleting it here would not stick — the next sync re-creates it within about five minutes. Clear its email and phone instead, which updates Jobber too.'
      using errcode = '42501';
  end if;

  delete from public.client_contacts where id = p_contact_id;

  return jsonb_build_object(
    'deleted_id',   v_row.id,
    'client_id',    v_row.client_id,
    'contact_role', v_row.contact_role,
    'property_id',  v_row.property_id,
    'email',        v_row.email,
    'phone',        v_row.phone
  );
end;
$function$;

COMMENT ON FUNCTION client.delete_client_contact(bigint) IS
  'Deletes an accounting/city (or per-property) contact. Refuses the client-level primary, which the '
  'Jobber poll re-creates within ~5 minutes — clear its email/phone via save-client-contact instead. '
  'Hard delete is safe here: no inbound FKs, no entity_source_links, and the audit trigger preserves '
  'old_row so a mistake is restorable.';

REVOKE ALL ON FUNCTION client.delete_client_contact(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION client.delete_client_contact(bigint) FROM anon;
GRANT EXECUTE ON FUNCTION client.delete_client_contact(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION client.delete_client_contact(bigint) TO service_role;

-- ---------------------------------------------------------------------------
-- assertions. EXERCISE the function as `authenticated`; do not restate it.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_client bigint; v_primary bigint; v_acct bigint; v_new bigint;
  v_msg text; v_state text; n int; v_res jsonb;
BEGIN
  -- a client that has BOTH, or neither branch below is reachable
  SELECT cc.client_id INTO v_client
    FROM public.client_contacts cc
   WHERE cc.property_id IS NULL AND cc.contact_role = 'primary'
     AND EXISTS (SELECT 1 FROM public.client_contacts a
                  WHERE a.client_id = cc.client_id AND a.contact_role = 'accounting')
   ORDER BY cc.client_id LIMIT 1;
  SELECT cc.id INTO v_primary FROM public.client_contacts cc
   WHERE cc.client_id = v_client AND cc.property_id IS NULL AND cc.contact_role = 'primary' LIMIT 1;
  IF v_client IS NULL OR v_primary IS NULL THEN
    RAISE EXCEPTION 'CONTROL FAILED: no client with both a client-level primary and an accounting contact';
  END IF;

  PERFORM set_config('request.jwt.claims',
    json_build_object('email','fred@ayache.com','sub','00000000-0000-0000-0000-000000000000')::text, true);

  -- (A) 🛑 the primary is REFUSED
  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM client.delete_client_contact(v_primary);
    RESET ROLE;
    RAISE EXCEPTION 'GUARD FAILED: the rpc deleted the client-level primary';
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
    IF v_msg LIKE 'GUARD FAILED%' THEN RAISE; END IF;
    IF v_state <> '42501' THEN RAISE EXCEPTION 'primary delete gave % not 42501: %', v_state, left(v_msg,90); END IF;
    IF v_msg NOT LIKE '%would not stick%' THEN
      RAISE EXCEPTION 'the refusal does not explain WHY: %', left(v_msg,140);
    END IF;
  END;
  -- and it is still there
  SELECT count(*) INTO n FROM public.client_contacts WHERE id = v_primary;
  IF n <> 1 THEN RAISE EXCEPTION 'the primary was deleted despite the raise'; END IF;

  -- (B) a NEW accounting-style row is deleted successfully. Insert our own subject so no real
  --     contact is destroyed even inside this rolled-back block.
  INSERT INTO public.client_contacts (client_id, property_id, contact_role, first_name, email)
  VALUES (v_client, NULL, 'city', 'ProbeOnly', 'probe-delete@ayache.com')
  ON CONFLICT (client_id, property_id, contact_role) DO UPDATE SET email = excluded.email
  RETURNING id INTO v_new;

  SET LOCAL ROLE authenticated;
  SELECT client.delete_client_contact(v_new) INTO v_res;
  RESET ROLE;
  IF (v_res->>'deleted_id')::bigint <> v_new THEN RAISE EXCEPTION 'the rpc returned the wrong deleted_id'; END IF;
  SELECT count(*) INTO n FROM public.client_contacts WHERE id = v_new;
  IF n <> 0 THEN RAISE EXCEPTION 'the row survived the delete'; END IF;

  -- (C) 🛑 THE ASSERTION THE WHOLE HARD-DELETE ARGUMENT RESTS ON: the delete is RECOVERABLE.
  --     If old_row were not captured, hard delete would be unjustifiable and this must fail loudly.
  SELECT count(*) INTO n FROM audit.logs
   WHERE table_name = 'client_contacts' AND operation = 'DELETE'
     AND old_row->>'id' = v_new::text AND old_row->>'email' = 'probe-delete@ayache.com';
  IF n < 1 THEN
    RAISE EXCEPTION 'CONTROL FAILED: the DELETE was not captured in audit.logs with old_row — hard delete is NOT recoverable and this migration must not ship';
  END IF;

  -- (D) a missing id is a clean P0002, not a silent success
  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM client.delete_client_contact(999999999);
    RESET ROLE;
    RAISE EXCEPTION 'GUARD FAILED: deleting a non-existent contact succeeded';
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
    IF v_msg LIKE 'GUARD FAILED%' THEN RAISE; END IF;
    IF v_state <> 'P0002' THEN RAISE EXCEPTION 'missing id gave % not P0002', v_state; END IF;
  END;

  -- (E) anon must not be able to call it at all
  IF has_function_privilege('anon', 'client.delete_client_contact(bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon can EXECUTE the delete';
  END IF;
  IF NOT has_function_privilege('authenticated', 'client.delete_client_contact(bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated CANNOT execute the delete';
  END IF;

  RAISE NOTICE 'OK: primary refused with a reason, a real delete lands, audit.logs captured old_row, missing id is P0002, grants correct';
END $$;

-- the assertions inserted and deleted a probe row; roll it all back, then re-apply the DDL.
ROLLBACK;

BEGIN;

CREATE OR REPLACE FUNCTION client.delete_client_contact(p_contact_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_row public.client_contacts;
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

  select * into v_row from public.client_contacts where id = p_contact_id;
  if not found then
    raise exception 'contact % not found', p_contact_id using errcode = 'P0002';
  end if;

  if v_row.property_id is null and v_row.contact_role = 'primary' then
    raise exception 'This is the client''s main contact and it comes from Jobber, so deleting it here would not stick — the next sync re-creates it within about five minutes. Clear its email and phone instead, which updates Jobber too.'
      using errcode = '42501';
  end if;

  delete from public.client_contacts where id = p_contact_id;

  return jsonb_build_object(
    'deleted_id',   v_row.id,
    'client_id',    v_row.client_id,
    'contact_role', v_row.contact_role,
    'property_id',  v_row.property_id,
    'email',        v_row.email,
    'phone',        v_row.phone
  );
end;
$function$;

COMMENT ON FUNCTION client.delete_client_contact(bigint) IS
  'Deletes an accounting/city (or per-property) contact. Refuses the client-level primary, which the '
  'Jobber poll re-creates within ~5 minutes — clear its email/phone via save-client-contact instead. '
  'Hard delete is safe here: no inbound FKs, no entity_source_links, and the audit trigger preserves '
  'old_row so a mistake is restorable.';

REVOKE ALL ON FUNCTION client.delete_client_contact(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION client.delete_client_contact(bigint) FROM anon;
GRANT EXECUTE ON FUNCTION client.delete_client_contact(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION client.delete_client_contact(bigint) TO service_role;

DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM public.client_contacts;
  IF n <> 578 THEN
    RAISE EXCEPTION 'client_contacts holds % rows, expected the original 578 — a probe row survived', n;
  END IF;
  IF NOT has_function_privilege('authenticated', 'client.delete_client_contact(bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'the function did not land with the right grant';
  END IF;
  RAISE NOTICE 'OK: delete_client_contact live, contact table untouched at % rows', n;
END $$;

COMMIT;
