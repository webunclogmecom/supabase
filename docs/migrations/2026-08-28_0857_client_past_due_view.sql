-- 2026-08-28_0857_client_past_due_view.sql
--
-- Adds ops.v_client_past_due so the Visit Calendar can show a past-due badge on the visit card,
-- the hover card and the drawer. Fred asked for past due to be visible next to the client on all
-- three surfaces.
--
-- 🛑 DEFINITION A, CHOSEN BY FRED 2026-08-28, AND THE CHOICE MATTERS THREEFOLD.
-- "Past due" here means `invoice_status = 'past_due'`, which is JOBBER'S OWN determination, not a
-- date comparison we recompute. Measured at the time of writing:
--
--   A  invoice_status = 'past_due' AND outstanding_amount > 0   ->  37 clients,  40 invoices,  $34,795
--   B  outstanding_amount > 0 AND due_date < current_date       -> 107 clients, 147 invoices, $101,155
--
-- B is three times larger and was rejected. The reason A wins is the standing rule that BILLING
-- TRUTH IS JOBBER INVOICES: `invoice_status` is synced from Jobber, so A reports what Jobber
-- itself calls past due, while B is our own re-derivation and would disagree with what the office
-- sees in Jobber. **If anyone ever "improves" this to a date comparison, that is a product change
-- and it needs Fred, not a refactor.**
--
-- ⚠ `outstanding_amount > 0` is NOT redundant next to the status. 1 of the 41 `past_due` invoices
-- has a zero balance, and 6 invoices marked `paid` carry a non-zero outstanding amount. The status
-- and the balance disagree in both directions, so both predicates are required.
--
-- ⚠ WHY A SEPARATE VIEW RATHER THAN COLUMNS ON ops.v_calendar_visit. That view has 72 columns and
-- the entire Calendar reads it; appending to it puts the whole grid at risk for a badge. This view
-- returns ONE ROW PER AFFECTED CLIENT (37 today), so the app fetches it once and joins client-side
-- on client_id. Cheaper than widening every visit row, and it cannot break the main feed.
--
-- ⚠ Deliberately NOT filtered to active clients or recent invoices. A past-due balance does not
-- stop mattering because a client went inactive.

begin;

create or replace view ops.v_client_past_due as
select
  c.id                                            as client_id,
  c.client_code                                   as client_code,
  count(*)::int                                   as past_due_invoice_count,
  round(sum(i.outstanding_amount)::numeric, 2)    as past_due_amount
from public.clients c
join public.invoices i on i.client_id = c.id
where i.invoice_status = 'past_due'
  and i.outstanding_amount > 0
group by c.id, c.client_code;

comment on view ops.v_client_past_due is
  'One row per client carrying a Jobber past_due balance. Definition A (Fred, 2026-08-28): '
  'invoice_status = ''past_due'' AND outstanding_amount > 0. NOT a date comparison; billing truth '
  'is Jobber invoices. Consumed by the Visit Calendar card, hover card and drawer.';

-- match the grant pattern of the sibling ops calendar views exactly
grant select on ops.v_client_past_due to authenticated;
grant select on ops.v_client_past_due to service_role;
grant select on ops.v_client_past_due to yannick_readonly;

-- ─── VERIFY ───────────────────────────────────────────────────────────────────────────────────
do $$
declare
  bad text := '';
  v_clients int; v_invs int; v_amt numeric;
  v_alc_n int; v_alc_amt numeric;
  v_b_clients int;
  v_can_select boolean;
begin
  select count(*), sum(past_due_invoice_count), round(sum(past_due_amount),2)
    into v_clients, v_invs, v_amt from ops.v_client_past_due;

  -- 1. matches the definition-A figures this migration was written against
  if v_clients <> 37 then bad := bad || 'expected 37 clients, got ' || v_clients || '; '; end if;
  if v_invs <> 40 then bad := bad || 'expected 40 invoices, got ' || v_invs || '; '; end if;
  if v_amt <> 34795.02 then bad := bad || 'expected 34795.02, got ' || v_amt || '; '; end if;

  -- 2. a named fixture, so a silent definition drift is visible
  select past_due_invoice_count, past_due_amount into v_alc_n, v_alc_amt
    from ops.v_client_past_due where client_code = '293-ALC';
  if v_alc_n is distinct from 3 or v_alc_amt is distinct from 5508.00 then
    bad := bad || '293-ALC expected 3 invoices / 5508.00, got '
                || coalesce(v_alc_n::text,'null') || ' / ' || coalesce(v_alc_amt::text,'null') || '; ';
  end if;

  -- 3. 🛑 CONTROL: definition B must produce a DIFFERENT number, or the two are
  --    indistinguishable here and this verification proves nothing about which one shipped.
  select count(distinct client_id) into v_b_clients
    from public.invoices where outstanding_amount > 0 and due_date < current_date;
  if v_b_clients = v_clients then
    bad := bad || 'CONTROL FAILED: definition B also yields ' || v_b_clients
                || ' clients, so this check cannot tell A from B; ';
  end if;

  -- 4. a client with NO past due must be absent, never present with a zero
  if exists (select 1 from ops.v_client_past_due where client_code = '154-PV') then
    bad := bad || '154-PV has no past-due invoices but appears in the view; ';
  end if;

  -- 5. the grant the app actually needs
  select has_table_privilege('authenticated', 'ops.v_client_past_due', 'SELECT') into v_can_select;
  if not v_can_select then bad := bad || 'authenticated cannot SELECT the view; '; end if;

  if bad <> '' then raise exception 'v_client_past_due verification FAILED: %', bad; end if;
  raise notice 'verified: % clients, % invoices, $%; 293-ALC fixture ok; definition B differs (% clients); 154-PV absent; authenticated can select',
    v_clients, v_invs, v_amt, v_b_clients;
end $$;

notify pgrst, 'reload schema';

commit;
