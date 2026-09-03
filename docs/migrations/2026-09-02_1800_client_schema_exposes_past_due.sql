-- 2026-09-02_1800_client_schema_exposes_past_due.sql
--
-- Expose the canonical past-due view to the Client App.
--
-- Fred, 2026-09-02, with a mockup of a PAST DUE NOTIFICATION panel on the client detail page:
-- "the Calendar App already does that at their Drawer of the visits details, it post the
-- information about that. See it, process it, design it and build it."
--
-- ============================================================================
-- A PURE PASSTHROUGH, ON PURPOSE. THE DEFINITION IS THE FEATURE.
-- ============================================================================
-- `ops.v_client_past_due` already encodes the rule Fred settled on 2026-08-28:
--     invoice_status = 'past_due' AND outstanding_amount > 0
-- which is JOBBER'S OWN determination, never a date comparison. The Visit Calendar reads that view
-- for its red client code, hover badge and drawer line.
--
-- The Client App cannot address it: its supabase client is pinned to the `client` schema, and
-- although `authenticated` does hold USAGE on `ops` and SELECT on the view, PostgREST only serves
-- the schemas it is configured to expose. (A privilege check is not a reachability check - the same
-- trap that broke the outbound drain earlier today with `Invalid schema: sync`.)
--
-- So this is `select *` and nothing else. It is NOT a second copy of the predicate. Re-deriving
-- past due here, or in app code from the already-exposed `client.invoices`, would create a second
-- implementation of a business rule whose entire point is that it is canonical - and only one of the
-- two would ever be tested. The measured gap between the right rule and the obvious wrong one is
-- 35 clients versus 107, so a drifted copy is not a cosmetic problem.
--
-- ⚠ WHAT THE CONSUMER MUST DO, because the view cannot enforce it:
--   * KEY ON client_id, NEVER client_code. Six of the affected clients have a NULL code.
--   * A client with NO ROW is not past due. Absence is the negative case; there is no
--     past_due=false row to find.
--   * jobber_client_id is ALREADY DECODED here, so the app never constructs a Jobber URL from a
--     displayed number. Do not build one from client_code or from an invoice number.
--
-- ⚠ The row count MOVES, because it is live Jobber state. It was 37 when the rule was written on
-- 2026-08-28 and is 35 today, and the documented fixture 293-ALC has gone from 3 invoices/$5,508 to
-- 2/$735.00. Any test that hardcodes a total will rot; assert on a named client's row EXISTING or
-- NOT, not on an estate-wide number.

begin;

create or replace view client.v_client_past_due as
  select * from ops.v_client_past_due;

comment on view client.v_client_past_due is
  'Passthrough of ops.v_client_past_due for the Client App, which is pinned to the client schema. '
  'Past due = Jobber invoice_status past_due AND outstanding_amount > 0. Do NOT re-derive. '
  'A client with no row is not past due. Key on client_id, never client_code.';

revoke all on client.v_client_past_due from public, anon;
grant select on client.v_client_past_due to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
do $verify$
declare
  v_ops   integer;
  v_cli   integer;
  v_defB  integer;
  v_alc   integer;
  v_pv    integer;
  v_t4a   integer;
begin
  select count(*) into v_ops from ops.v_client_past_due;
  select count(*) into v_cli from client.v_client_past_due;
  if v_ops <> v_cli then
    raise exception 'VERIFY FAILED: passthrough returns % rows against the ops view''s % - it is not a passthrough', v_cli, v_ops;
  end if;

  -- 🛑 THE CONTROL THAT ACTUALLY DISCRIMINATES. "The view returns N rows" is satisfied by the right
  -- definition AND by several wrong ones, so it proves nothing on its own. Definition B - the
  -- rejected date comparison - must give a DIFFERENT answer, or this check cannot tell them apart.
  select count(distinct client_id) into v_defB
    from public.invoices
   where outstanding_amount > 0 and due_date < current_date;
  if v_defB = v_cli then
    raise exception 'CONTROL FAILED: the rejected date-comparison definition returns the same % clients, '
                    'so this check cannot distinguish it from Jobber''s own status', v_cli;
  end if;

  -- Named fixtures, asserted as PRESENT / ABSENT rather than on an amount, because the amounts are
  -- live Jobber state and move. 293-ALC's documented figures already have.
  select count(*) into v_alc from client.v_client_past_due where client_id = 503;  -- 293-ALC
  select count(*) into v_pv  from client.v_client_past_due where client_id = 204;  -- 154-PV
  select count(*) into v_t4a from client.v_client_past_due where client_id = 376;  -- 270-T4A
  if v_alc <> 1 then raise exception 'VERIFY FAILED: 293-ALC (503) should be past due, got % rows', v_alc; end if;
  if v_pv  <> 0 then raise exception 'VERIFY FAILED: 154-PV (204) is the NEGATIVE control and must be absent, got % rows', v_pv; end if;
  -- 270-T4A is the client in Fred's mockup and is NOT past due. Asserted so nobody later "fixes"
  -- the panel to match the mockup's placeholder figures on a client that owes nothing.
  if v_t4a <> 0 then raise exception 'VERIFY FAILED: 270-T4A (376) was not past due when this shipped, got % rows', v_t4a; end if;

  -- the app role can read it and anon cannot
  if not has_table_privilege('authenticated', 'client.v_client_past_due', 'SELECT') then
    raise exception 'VERIFY FAILED: authenticated cannot SELECT the view the app needs';
  end if;
  if has_table_privilege('anon', 'client.v_client_past_due', 'SELECT') then
    raise exception 'VERIFY FAILED: anon can read client billing state';
  end if;

  raise notice 'VERIFY OK: passthrough % rows = ops % rows; definition B would say % (different); '
               '293-ALC present, 154-PV absent, 270-T4A absent; authenticated yes, anon no',
               v_cli, v_ops, v_defB;
end
$verify$;

notify pgrst, 'reload schema';

commit;
