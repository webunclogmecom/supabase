-- 2026-08-20_0300_create_property_refuse.sql
--
-- WHAT: client.create_property now REFUSES, directing callers to the save-client-property edge
--       function.
--
-- WHY:  a property created only in our DB can never carry a Jobber job -- jobCreate needs a real
--       Jobber propertyId -- and every property is now required to have a Service Call job
--       (Fred, 2026-08-19: "when creating a property it should always, doesn't matter if it's at the
--       Clients App or the Calendar App, it should always create a SC Job for that property").
--       The DB-only path was an accepted trade-off during the Jobber bridge (2026-07-30_0709); this
--       reverses it.
--
-- 🛑 THE PLAN'S OWN VERSION OF THIS MIGRATION WOULD HAVE FAILED SILENTLY, AND THE FAILURE MODE IS
--    THE ONE IT WARNED ABOUT. It wrote the signature as
--        (p_client_id bigint, p_address text, p_city text, p_zip text)
--    The LIVE signature, read from pg_proc before writing a line of this file, is
--        (p_client_id bigint, p_patch jsonb)          RETURNS jsonb, SECURITY DEFINER, search_path=''
--    CREATE OR REPLACE keys on the argument TYPES. A different type list does not replace anything:
--    it creates a SECOND overload and leaves the original reachable and callable. The migration would
--    have applied cleanly, its VERIFY would have passed against the new stub, and the real function
--    would have gone on working. A green apply over an unchanged system.
--    ⇒ Always read pg_get_function_identity_arguments before CREATE OR REPLACE. Never copy a
--      signature out of a plan.
--
-- ⚠ SAFE TO DO, measured not assumed:
--    * client.create_property has been invoked in production exactly ONCE in its lifetime, a smoke
--      test on 2026-07-31 whose row was deleted 79 seconds later.
--    * audit.logs INSERTs on public.properties over the last 2 days: 13, ALL app_source='sql'
--      (the webhook-jobber handleProperty path), ZERO from 'client-app'.
--    * The only caller was the Clients App Add Property dialog, repointed to save-client-property
--      and verified live today: property 1091 via the real UI, one Service Call job (#99901067),
--      and the app's own toast read "Property added / Service Call job created."
--
-- ⚠ ORDER MATTERS AND IT IS NOT COSMETIC. The UI shipped FIRST. A server that refuses more than the
--    UI sends breaks every save from the currently-served bundle, and browsers hold old bundles.
--
-- ROLLBACK: restore the body from docs/migrations/2026-07-30_0709_client_create_property_rpc.sql.
--
-- AUDIT (rule 8): no table changed, no trigger changed. One function body.

begin;

-- Signature, SECURITY DEFINER and search_path all copied from the LIVE definition so this REPLACES
-- rather than overloads. search_path='' is deliberate: it is what the original carries.
create or replace function client.create_property(p_client_id bigint, p_patch jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception using
    errcode = '22023',
    message = 'Properties must be created through the save-client-property edge function so they exist in Jobber and can carry a Service Call job.',
    hint    = 'POST to /functions/v1/save-client-property with {client_id, street, city, postal_code}.';
end $$;

-- ---- VERIFY ------------------------------------------------------------------------------------
do $verify$
declare
  v_raised  boolean := false;
  v_msg     text;
  v_count   int;
begin
  -- (a) EXACTLY ONE overload must exist. If the signature had drifted we would now have two, the
  --     original still reachable, and every other check below would pass against the wrong one.
  select count(*) into v_count
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'client' and p.proname = 'create_property';
  if v_count <> 1 then
    raise exception 'VERIFY: expected exactly 1 client.create_property, found % - CREATE OR REPLACE overloaded instead of replacing', v_count;
  end if;

  -- (b) it must actually REFUSE. Creating the function is not evidence it raises.
  begin
    perform client.create_property(1, '{"address":"x","city":"y","zip":"z"}'::jsonb);
  exception when others then
    v_raised := true;
    v_msg := sqlerrm;
  end;
  if not v_raised then
    raise exception 'VERIFY: create_property did not refuse';
  end if;

  -- (c) and the refusal must NAME the replacement, or a caller cannot act on it
  if position('save-client-property' in coalesce(v_msg, '')) = 0 then
    raise exception 'VERIFY: it refused but the message does not name save-client-property: %', v_msg;
  end if;

  raise notice 'VERIFY ok: exactly 1 overload, refuses, and the message names the replacement';
end $verify$;

commit;
