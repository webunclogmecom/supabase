-- 2026-09-22_1216_seed_only_an_unconfigured_client.sql
--
-- Corrective follow-up to 2026-09-22_1100, same session, found by an adversarial pass over the
-- step-3 claim rather than by anything failing.
--
-- 🛑 THE DEFECT, IN MY OWN DESIGN, AND IT WOULD HAVE WIDENED WHO RECEIVES COMPLIANCE EMAIL.
-- `trg_seed_client_communication` fires AFTER INSERT on the client-record mirror row and seeds
-- invoice + quote_approval + service_report. That is right for a brand-new client and WRONG for a
-- mirror row that is deleted and re-created on a client a human has already configured, because
-- the re-created row gets a NEW id:
--   * the deleted row's prefs cascade away (client_communication_prefs_contact_id_fkey is CASCADE)
--   * the seed then inserts three rows against the NEW contact id
--   * `invoice` is correctly refused - client_comm_one_invoice_per_client is keyed on client_id,
--     so ON CONFLICT DO NOTHING catches it
--   * but `quote_approval` and `service_report` have NO per-client cardinality index BY DESIGN
--     (Fred: several people allowed), and client_comm_no_dup_ours is keyed on contact_id, so a new
--     contact_id conflicts with nothing
--   ⇒ the seed does not reset the set, it ADDS a recipient nobody ticked.
--
-- MEASURED ON PROD, in a rolled-back transaction on 112-YA. A human sets the accounting contact
-- 485 to receive the invoice and the service report, and deliberately ticks NOTHING on the mirror
-- row. The mirror row is then deleted by raw SQL and re-inserted with webhook-jobber's exact
-- six-key payload:
--   BEFORE: invoice->485, service_report->485
--   AFTER : invoice->485, quote_approval->NEW, service_report->NEW, service_report->485
-- The compliance report now goes to two people, one of whom was never chosen, no error is raised
-- anywhere, and the row reads as deliberately configured.
--
-- REACHABILITY. `client.delete_client_contact` raises 42501 on exactly the
-- (property_id IS NULL AND contact_role='primary') shape, but that guard is FUNCTION-LOCAL:
-- nothing on the TABLE stops a service_role or postgres delete. Raw migration SQL is the estate's
-- normal way of changing data, and the standing client-merge recipe deletes the loser's mirror row
-- filtered only on contact_role. `audit.logs` already holds 24 `app_source='sql'` DELETEs on
-- client_contacts. Re-creation then needs no human at all: the */5 poll finds no conflict row and
-- INSERTs within five minutes, which is measured (step 3 clocked a replay at 15 seconds).
--
-- SEVERITY TODAY IS ZERO ROWS, WHICH IS PRECISELY WHY IT IS WORTH FIXING NOW.
-- public.client_communication_prefs holds 0 rows and the seed is AFTER INSERT only, so none of the
-- 429 existing mirror rows has ever been seeded. Nothing is currently damageable. The fix costs
-- one predicate and stops the whole class before the table has a single row in it.
--
-- THE FIX: seed only a client that has NEVER been configured.
--   where not exists (select 1 from public.client_communication_prefs p
--                      where p.client_id = new.client_id)
-- "This client already has communication settings" is exactly the condition under which imposing
-- defaults is wrong, whoever holds them and whichever contact row is being inserted.
--
-- 🛑 WHAT I DELIBERATELY DID NOT DO: promote the delete guard to a BEFORE DELETE trigger on the
-- table. It would fire on the CASCADE from a client hard-delete too, turning a path that works
-- today into a failure, which is the "a table constraint puts a failure on the critical path"
-- trap this repo already documents for contact_role. With this fix the residual is only that a
-- deleted contact loses its own settings, which is what deleting a contact should mean.

begin;

create or replace function public.fn_seed_client_communication()
returns trigger language plpgsql security definer set search_path to '' as $$
begin
  -- 🛑 THE TRIGGER PREDICATE (property_id is null and contact_role = 'primary') decides WHICH ROW
  -- may seed. THIS predicate decides WHETHER TO SEED AT ALL: never impose defaults on a client
  -- somebody has already configured, because the re-created mirror row carries a NEW id and would
  -- otherwise ADD a recipient nobody ticked. See the header for the measured counterexample.
  insert into public.client_communication_prefs (client_id, comm_type, contact_id)
  select new.client_id, t, new.id
    from unnest(array['invoice','quote_approval','service_report']) t
   where not exists (select 1 from public.client_communication_prefs p
                      where p.client_id = new.client_id)
  on conflict do nothing;   -- belt and braces; the predicate above is the real guard
  return null;
end $$;

-- ⚠ Supabase's default privileges hand out grants nobody wrote: this function shipped with
-- `=X/postgres` (EXECUTE to PUBLIC) plus an explicit grant to authenticated. It is INERT - a
-- trigger function returns `trigger`, so PostgREST will not expose it and a direct call raises
-- 0A000 - and 42 of the 43 trigger functions in `public` carry the same default, so this is the
-- house state rather than a hole this migration opened. Revoked anyway, because the standing rule
-- is to check every new object and revoke explicitly rather than to reason about reachability.
revoke all on function public.fn_seed_client_communication() from public, anon, authenticated;

commit;

-- ============================================================================================
-- VERIFY  (run 2026-09-22; rehearsed rolled-back on 112-YA before applying)
--
-- Both halves in ONE rolled-back transaction so before and after are measured on identical state:
--
--   1. THE DEFECT REPRODUCES on the old body            -> AFTER <> BEFORE, else there is nothing
--                                                          to fix and the migration is theatre
--   2. THE FIX HOLDS on the new body                    -> AFTER  = BEFORE, byte for byte
--   3. 🛑 THE CONTROL, so the fix cannot be over-reach: a brand-new client's mirror row must STILL
--      seed exactly 3. A predicate that seeds nothing would satisfy (2) perfectly.
--
-- All three asserted and passed. The probe ends in a deliberate RAISE so it can only roll back.
--
--   4. GRANTS: has_function_privilege('anon'|'authenticated', 'public.fn_seed_client_communication()',
--      'execute') must both be FALSE, with save_contact_settings as the live control that the
--      instrument reads a real grant (anon false / authenticated true).
--   5. The seed still fires at all: insert a throwaway client + mirror row -> exactly 3 prefs.
--      Without this, (4) would pass on a function that had been broken outright.
-- ============================================================================================
