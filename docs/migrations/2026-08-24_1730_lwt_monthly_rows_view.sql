-- 2026-08-24_1730 — derm.v_lwt_monthly_rows: the LWT monthly report, at ROW grain
-- ============================================================================
-- Feeds the new read-only endpoint `rpa-derm-monthly` for Jonathan's LWT generator.
-- Design + measurements: docs/specs/2026-08-24-lwt-monthly-endpoint-design.md
--
-- ONE ROW PER (ticket, linked visit) = one transportation activity. The Miami-Dade
-- LWT form scopes "all transportation activities where liquid waste was picked up OR
-- offloaded in Miami-Dade County", and an ACTIVITY is a pickup, not a ticket.
--
-- 🛑 WHY ROW GRAIN AND NOT TICKET GRAIN. Both naive builds are wrong, in opposite
-- directions, and both were measured over 2026 before this was written:
--   * "offloaded in Dade" alone DROPS 11 tickets / 83 activities — Broward offloads
--     that carried Miami-Dade pickups. Silently missing rows on a regulator-facing
--     filing is the worst failure available here.
--   * the OR applied at TICKET grain OVER-reports, because 20 tickets mix counties.
--     A Broward pickup offloaded in Broward does not belong on the Miami-Dade form
--     just because a different pickup on the same truckload was in Dade.
-- The asymmetry that makes the row rule work: if the ticket offloaded in Dade then
-- EVERY pickup on it was offloaded in Dade, so all its rows qualify. Only the
-- Broward-offload tickets need row-level filtering.
--
-- 🛑 pickup_date IS visits.visit_date, NEVER derm_manifests.service_date.
-- `service_date` is a misnomer: the DERM Tracker writes the entered dump date into
-- BOTH service_date and dump_ticket_date, so 496 of 532 live manifests have them
-- identical. Serving it would make every pickup equal its own offload, and six
-- filed county pages would disagree with us. The real service date exists only on
-- the linked visit.
--
-- 🛑 TICKET NUMBER IS coalesce(white, yellow) AND THAT IS TOTAL, MEASURED:
--   white 502 / yellow 157 / neither 0 / colliding across the two spaces 0.
--   The 502/157 split matches the disposal-facility split EXACTLY, which is what
--   makes `white => Miami-Dade offload` a fact rather than a convention.
--   wwtp_ticket_number and wwtp_receipt_number are populated 0 times: do not use them.
--
-- ⚠ gallons is deliberately NULL. The filed quantity is the TRUCK CAPACITY, resolved
-- from the decal on the generator side. We store no measured volume per load, so any
-- value here would be a guess dressed as data. truck + truck_capacity_gallons are
-- served so the caller has the input without us asserting the answer.
--
-- ⚠ COUNTY VOCABULARY: public.properties.county stores 'Dade' while
-- public.disposal_facilities.county stores 'Miami-Dade'. Two spellings for one county.
-- This view emits the property's stored value verbatim and exposes booleans, so no
-- caller has to know which spelling won.
--
-- ⚠ A ticket with NO linked visits produces NO rows (inner join). There is exactly 1
-- such ticket today. It offloaded but has no activity to report; whether the form
-- wants an empty line is a question for John, not a default this view should invent.
--
-- AUDIT (rule 8): not applicable, this is a VIEW over already-audited tables.
-- No table is created or altered.
-- ============================================================================

begin;

create or replace view derm.v_lwt_monthly_rows as
select
    coalesce(m.white_manifest_number, m.yellow_ticket_number)                as ticket_number,
    case when m.white_manifest_number is not null then 'white' else 'yellow' end
                                                                            as ticket_kind,
    (m.white_manifest_number is not null)                                   as offload_in_dade,
    m.dump_ticket_date                                                      as offload_date,
    df.name                                                                 as disposal_facility,
    v.visit_date                                                            as pickup_date,
    c.client_code,
    c.name                                                                  as client_name,
    p.address,
    p.city,
    p.state,
    p.zip,
    p.county,
    coalesce(p.county = 'Dade', false)                                      as pickup_in_dade,
    -- the scope predicate, at activity grain
    (coalesce(p.county = 'Dade', false) or m.white_manifest_number is not null)
                                                                            as in_scope,
    ve.name                                                                 as truck,
    ve.grease_tank_capacity_gallons                                         as truck_capacity_gallons,
    null::integer                                                           as gallons,
    m.id                                                                    as manifest_id,
    v.id                                                                    as visit_id
from public.derm_manifests m
join public.manifest_visits mv on mv.manifest_id = m.id
join public.visits     v  on v.id = mv.visit_id and v.deleted_at is null
join public.clients    c  on c.id = m.client_id
left join public.properties           p  on p.id  = v.property_id
left join public.vehicles             ve on ve.id = v.vehicle_id
left join public.disposal_facilities  df on df.id = m.disposal_facility_id
where m.deleted_at is null;

comment on view derm.v_lwt_monthly_rows is
  'One row per (dump ticket, linked visit) = one LWT transportation activity. Feeds '
  'rpa-derm-monthly. in_scope implements the Miami-Dade form rule at ACTIVITY grain: '
  'pickup county = Dade OR the ticket offloaded in Miami-Dade. pickup_date is the '
  'VISIT date, never derm_manifests.service_date (which holds the dump date). gallons '
  'is always NULL by design: the filed quantity is truck capacity, resolved from the '
  'decal by the caller. Spec: docs/specs/2026-08-24-lwt-monthly-endpoint-design.md';

-- Least privilege, matching derm.v_sheet_printed_rows (the most recent sibling).
-- Supabase's ALTER DEFAULT PRIVILEGES hands out grants nobody wrote, so revoke first
-- and assert the result below rather than trusting the GRANT statements.
revoke all on derm.v_lwt_monthly_rows from public;
revoke all on derm.v_lwt_monthly_rows from anon;
revoke all on derm.v_lwt_monthly_rows from authenticated;
grant select on derm.v_lwt_monthly_rows to service_role;

-- ============================ VERIFY ========================================
do $$
declare
  v_acl            text;
  v_anon           boolean;
  v_authn          boolean;
  v_widen_tickets  int;
  v_excluded       int;
  v_all_same_date  boolean;
  v_mixed          int;
begin
  -- 1. grants are exactly what was intended, read back AFTER the fact
  select c.relacl::text into v_acl from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname='derm' and c.relname='v_lwt_monthly_rows';
  v_anon  := has_table_privilege('anon','derm.v_lwt_monthly_rows','SELECT');
  v_authn := has_table_privilege('authenticated','derm.v_lwt_monthly_rows','SELECT');
  if v_anon or v_authn then
    raise exception 'VERIFY 1 FAILED: anon=% authenticated=% must both be false. acl=%',
      v_anon, v_authn, v_acl;
  end if;

  -- 2. POSITIVE CONTROL that must fire: the 11 Broward-offload tickets carrying Dade
  --    pickups are present and in scope. A build that returns nothing passes every
  --    "no bad rows" check and is useless, so this control is the one that matters.
  select count(distinct ticket_number) into v_widen_tickets
    from derm.v_lwt_monthly_rows
   where offload_in_dade = false and pickup_in_dade = true and in_scope = true
     and offload_date >= date '2026-01-01';
  if v_widen_tickets < 5 then
    raise exception 'VERIFY 2 FAILED: expected the Broward-offload-with-Dade-pickup set to be non-trivial, got % tickets', v_widen_tickets;
  end if;

  -- 3. NEGATIVE CONTROL: Broward offload + non-Dade pickup must be out of scope.
  select count(*) into v_excluded
    from derm.v_lwt_monthly_rows
   where offload_in_dade = false and pickup_in_dade = false and in_scope = true;
  if v_excluded <> 0 then
    raise exception 'VERIFY 3 FAILED: % rows are in_scope with neither a Dade pickup nor a Dade offload', v_excluded;
  end if;

  -- 4. THE service_date TELL. If pickup_date ever equals offload_date on EVERY row,
  --    the dump date has crept back in. Assert the two genuinely differ somewhere.
  select bool_and(pickup_date = offload_date) into v_all_same_date
    from derm.v_lwt_monthly_rows where offload_date >= date '2026-01-01';
  if v_all_same_date then
    raise exception 'VERIFY 4 FAILED: pickup_date equals offload_date on every row - service_date has crept back in';
  end if;

  -- 5. the mixed-county tickets exist, which is why row grain is required at all
  select count(*) into v_mixed from (
    select ticket_number from derm.v_lwt_monthly_rows
     where offload_date >= date '2026-01-01' and county is not null
     group by ticket_number having count(distinct county) > 1) x;
  if v_mixed = 0 then
    raise exception 'VERIFY 5 FAILED: no mixed-county tickets found, the row-grain premise is untested';
  end if;

  raise notice 'VERIFY OK: acl=%, widen=% tickets, excluded=0, mixed-county=% tickets',
    v_acl, v_widen_tickets, v_mixed;
end $$;

commit;
