-- ============================================================================
-- 2026-07-31_1620 — Real revenue for the Client App billing block
-- ============================================================================
-- ASK (Fred, 2026-07-31) + his answers to the audit's open questions:
--   Q1 "Life Time yes it just means since we starting invoicing them, keep the
--       name 'Life Time' but you know what it really means"
--   Q3 "start since into use 2026 with the Line Items. So since we migrated all
--       the jobs to start using the Line Items with codes. Don't take into mind
--       previous data."
--   Q4 "when we have a WD line item inside of a SA job with other line items
--       (01, 02, 04 ...) then we need to separate the prices... CL (05 to 07)
--       go to `SA - Cleaning`, GT Pumping (01 to 04) to `SA - Pumping` and
--       Line Item 08 Warranty of Drainage to `SA - Warranty of Drainage`."
--
-- WHAT THE BLOCK DID BEFORE (audit: docs/2026-07-31_billing-revenue-audit.md):
--   * it NEVER read invoices — it computed 365/frequency_days * price_per_visit
--     from service_configs, i.e. an annual contract run-rate, not money billed;
--   * the three tabs were decorative — the active tab was never used in any
--     arithmetic, so "YTD" relabelled a projection as "Actual";
--   * the Service Call card was hard-coded null and added a literal +0.
--   Measured error on real clients: 063-TCE -51%, 168-AVA -44%.
--
-- ---------------------------------------------------------------------------
-- THE MODEL
-- ---------------------------------------------------------------------------
-- TOTALS come from public.invoices.total — the only trustworthy revenue source
-- (2,333 rows, 99.96% client-linked), per the standing rule that billing truth
-- is Jobber invoices, not our line items. ⚠ invoices.subtotal is partly
-- unpopulated (2024 sums to $0.00) — never use it.
--
-- PER-SERVICE-GROUP amounts come from INVOICE-SCOPED line items, split by the
-- catalogue code at the head of the name, per Fred's Q4 mapping:
--       01-04 -> pumping      05-07 -> cleaning
--       08    -> warranty     09-24 -> service_call      25-28 -> (not a card)
-- ⚠ line_items has THREE DISJOINT SCOPES (job / visit / invoice) which are
-- stages of the SAME service. Summing all three overstates revenue by +56%
-- ($1.99M vs $1.27M). Every actuals query below pins invoice_id IS NOT NULL.
--
-- ⚠ DRAFT invoices are excluded from actuals (11 rows, $3,186.96): they have
-- not been sent, so they are not billed. bad_debt IS included — it was billed,
-- just never collected. paid / awaiting_payment / past_due all count.
--
-- ⚠ PER-GROUP FIGURES ARE 2026-FORWARD BY NATURE, and that is Fred's Q3 call.
-- The numbered catalogue only came into use in 2026: just 1.7% of 2025 invoiced
-- dollars carry a code, versus 37.6% in 2026. So the CARDS necessarily describe
-- the coded era while the TOTAL covers all time. The view exposes
-- life_uncoded_total so the UI can say so out loud instead of quietly implying
-- the cards add up to the total.
--
-- PROJECTION = actual YTD + the value of visits already SCHEDULED between
-- tomorrow and 31 Dec + billing-only recurring charges (code 08 jobs that
-- produce no visit). Counting real scheduled rows beats
-- floor(days_remaining/frequency): 141 of 152 live recurring jobs already have
-- visits booked into December, and the naive formula predicted 484 where 540
-- exist. It is slightly conservative for ~11 jobs, which is the safe direction.
--
-- 3NF / Rule 1: a pure read-model. No new columns, nothing stored, nothing
-- copied — every number is derived at read time from invoices / line_items /
-- visits. Audit (ADR 010): no tables touched, so no trigger changes.
-- Grants: authenticated SELECT only (the app never writes revenue).
--
-- ROLLBACK: drop view client.v_client_billing;
--           drop function client.fn_billing_group(text);
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. the code -> service-group map (Fred's Q4 rule, in one place)
-- ---------------------------------------------------------------------------
create or replace function client.fn_billing_group(p_name text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
           when c between 1 and 4  then 'pumping'
           when c between 5 and 7  then 'cleaning'
           when c = 8              then 'warranty'
           when c between 9 and 24 then 'service_call'
           else null                      -- 25/26 fees, 27 GDO, 28 disposal, uncoded
         end
  from (
    -- the catalogue code is the leading integer of the line-item name
    -- ("01 - Service Agreement - ..."). POSIX class, no backslash escapes:
    -- a doubled \\d is what silently returns zero rows (CLAUDE.md regex rule).
    select nullif(substring(btrim(coalesce(p_name,'')) from '^([0-9]+)'), '')::int as c
  ) t;
$$;

comment on function client.fn_billing_group(text) is
  'Maps a line-item name to a billing card: 01-04 pumping, 05-07 cleaning, 08 warranty, 09-24 service_call, else NULL (fees 25/26, GDO 27, disposal 28, uncoded). Fred 2026-07-31: a Warranty line INSIDE an SA job must bill to the Warranty card, not to Pumping.';

-- ---------------------------------------------------------------------------
-- 2. the read model — one row per client
-- ---------------------------------------------------------------------------
create or replace view client.v_client_billing as
with cal as (
  select date_trunc('year', (now() at time zone 'America/New_York'))::date              as y_start,
         (date_trunc('year', (now() at time zone 'America/New_York'))
            + interval '1 year' - interval '1 day')::date                               as y_end,
         (now() at time zone 'America/New_York')::date                                  as today
),
inv as (   -- billed invoices only; draft is not billed
  select i.id, i.client_id, i.total,
         (coalesce(i.sent_at, i.created_at) at time zone 'America/New_York')::date as inv_date
  from public.invoices i
  where coalesce(i.invoice_status, '') <> 'draft'
    and i.client_id is not null
),
tot as (
  select inv.client_id,
         coalesce(sum(inv.total) filter (where inv.inv_date >= cal.y_start), 0) as ytd_total,
         count(*)      filter (where inv.inv_date >= cal.y_start)               as ytd_invoices,
         coalesce(sum(inv.total), 0)                                           as life_total,
         count(*)                                                              as life_invoices,
         min(inv.inv_date)                                                     as life_since
  from inv cross join cal
  group by inv.client_id
),
-- actual per-group, from INVOICE-scoped line items only
gl as (
  -- ⚠ PRO-RATA, not the raw line price. An invoice's lines do NOT always sum to
  -- its total: discounts and comped invoices make the lines LARGER than the money
  -- actually billed. Measured on live data — 283-PIK invoice 2859 bills $2,371
  -- against $2,670 of lines ($299 discount); 208-HUB has two invoices with
  -- total = $0.00 still carrying a $399 line. Summing raw line prices made the
  -- cards EXCEED the client's real revenue for 3 clients, which is exactly the
  -- overstatement this rebuild exists to remove.
  -- Allocating each line its share of the invoice total spreads the discount
  -- across the services that earned it and restores the invariant
  -- cards + uncoded <= total.
  select inv.client_id,
         client.fn_billing_group(l.name) as grp,
         inv.inv_date,
         l.total_price * coalesce(inv.total / nullif(li.li_sum, 0), 1) as total_price
  from public.line_items l
  join inv on inv.id = l.invoice_id
  join lateral (
    select sum(l2.total_price) as li_sum
    from public.line_items l2 where l2.invoice_id = inv.id
  ) li on true
),
grp as (
  select gl.client_id,
    coalesce(sum(gl.total_price) filter (where gl.grp='pumping'      and gl.inv_date >= cal.y_start),0) ytd_pumping,
    coalesce(sum(gl.total_price) filter (where gl.grp='cleaning'     and gl.inv_date >= cal.y_start),0) ytd_cleaning,
    coalesce(sum(gl.total_price) filter (where gl.grp='warranty'     and gl.inv_date >= cal.y_start),0) ytd_warranty,
    coalesce(sum(gl.total_price) filter (where gl.grp='service_call' and gl.inv_date >= cal.y_start),0) ytd_service_call,
    coalesce(sum(gl.total_price) filter (where gl.grp='pumping'),0)      life_pumping,
    coalesce(sum(gl.total_price) filter (where gl.grp='cleaning'),0)     life_cleaning,
    coalesce(sum(gl.total_price) filter (where gl.grp='warranty'),0)     life_warranty,
    coalesce(sum(gl.total_price) filter (where gl.grp='service_call'),0) life_service_call,
    -- everything invoiced that no card can claim (uncoded free text + fees).
    -- Exposed on purpose: the cards will NOT sum to the total, and the UI must
    -- be able to say why rather than leave a silent gap.
    coalesce(sum(gl.total_price) filter (where gl.grp is null),0)        life_uncoded_total
  from gl cross join cal
  group by gl.client_id
),
-- pipeline: visits already scheduled from tomorrow to 31 Dec, priced from
-- their job's SERVICE line items (job-scoped; fees excluded by fn_billing_group)
fut as (
  select v.client_id,
         count(*) as proj_visits,
         coalesce(sum(jv.pumping),0)      proj_v_pumping,
         coalesce(sum(jv.cleaning),0)     proj_v_cleaning,
         coalesce(sum(jv.service_call),0) proj_v_service_call,
         -- ⚠ the TOTAL uses every line on the job, fees included, because the
         -- fee is real invoiced money; the per-group CARDS stay service-only
         -- because a card is a service, not a payment surcharge. Same asymmetry
         -- as the actuals (ytd_total is invoices.total; the cards are a subset).
         coalesce(sum(jv.all_lines),0)    proj_v_total
  from public.visits v
  cross join cal
  join lateral (
    select
      coalesce(sum(l.total_price) filter (where client.fn_billing_group(l.name)='pumping'),0)      pumping,
      coalesce(sum(l.total_price) filter (where client.fn_billing_group(l.name)='cleaning'),0)     cleaning,
      coalesce(sum(l.total_price) filter (where client.fn_billing_group(l.name)='service_call'),0) service_call,
      coalesce(sum(l.total_price),0)                                                               all_lines
    from public.line_items l
    where l.job_id = v.job_id and l.invoice_id is null and l.visit_id is null
  ) jv on true
  where v.deleted_at is null
    and lower(coalesce(v.visit_status,'')) = 'scheduled'
    and v.visit_date >  cal.today
    and v.visit_date <= cal.y_end
  group by v.client_id
),
-- billing-only recurring: a live job carrying an 08 line and NO visit-producing
-- service line. Cadence is inferred from that client's own 08 invoice history
-- (jobs has no billing-cadence column — the invoice_frequency the app sends to
-- Jobber is not persisted back), so a client with fewer than 2 such invoices
-- contributes 0 rather than a guess.
wd_jobs as (
  select j.client_id, j.id as job_id,
         -- warranty-only value drives the WARRANTY CARD ...
         (select coalesce(sum(l.total_price),0) from public.line_items l
           where l.job_id = j.id and l.invoice_id is null and l.visit_id is null
             and client.fn_billing_group(l.name) = 'warranty') as charge,
         -- ... while the whole job (warranty + its ACH/card fee) drives the TOTAL
         (select coalesce(sum(l.total_price),0) from public.line_items l
           where l.job_id = j.id and l.invoice_id is null and l.visit_id is null) as charge_all
  from public.jobs j
  where lower(coalesce(j.job_status,'')) <> 'archived'
    and exists (select 1 from public.line_items l where l.job_id = j.id
                  and l.invoice_id is null and l.visit_id is null
                  and client.fn_billing_group(l.name) = 'warranty')
    and not exists (select 1 from public.line_items l where l.job_id = j.id
                  and l.invoice_id is null and l.visit_id is null
                  and client.fn_billing_group(l.name) in ('pumping','cleaning','service_call'))
),
wd_cadence as (
  -- Median gap between that client's warranty-bearing invoices.
  -- ⚠ TIMING USES ALL HISTORY, INCLUDING PRE-CODE FREE TEXT ("Warranty of
  -- Drainage" with no NN- prefix). Fred's "don't take previous data into mind"
  -- governs how DOLLARS are attributed to a card — using older invoice DATES to
  -- learn a cadence attributes nothing and misstates nothing. Without this the
  -- coded era holds a single 08 invoice per client (the 2026-07-23 batch), one
  -- data point yields no gap, and every warranty projection silently collapses
  -- to $0 — which is how 063-TCE came out $454.50 light on the first run.
  select g.client_id,
         percentile_cont(0.5) within group (order by g.gap) as days
  from (
    select inv.client_id,
           (inv.inv_date - lag(inv.inv_date) over (partition by inv.client_id order by inv.inv_date)) as gap
    from inv
    where exists (select 1 from public.line_items l
                   where l.invoice_id = inv.id
                     and (client.fn_billing_group(l.name) = 'warranty'
                          or l.name ~* 'warranty'))
  ) g
  where g.gap is not null and g.gap > 0
  group by g.client_id
),
wd as (
  select w.client_id,
         coalesce(sum(w.charge * floor(((select y_end from cal) - (select today from cal))::numeric
                                       / nullif(c.days,0))), 0)     as proj_recurring,
         coalesce(sum(w.charge_all * floor(((select y_end from cal) - (select today from cal))::numeric
                                       / nullif(c.days,0))), 0)     as proj_recurring_all
  from wd_jobs w
  left join wd_cadence c on c.client_id = w.client_id
  group by w.client_id
)
select
  cl.id as client_id,
  -- actuals
  coalesce(t.ytd_total,0)        as ytd_total,
  coalesce(t.ytd_invoices,0)     as ytd_invoices,
  coalesce(t.life_total,0)       as life_total,
  coalesce(t.life_invoices,0)    as life_invoices,
  t.life_since,
  -- per-group actuals
  coalesce(g.ytd_pumping,0)      as ytd_pumping,
  coalesce(g.ytd_cleaning,0)     as ytd_cleaning,
  coalesce(g.ytd_warranty,0)     as ytd_warranty,
  coalesce(g.ytd_service_call,0) as ytd_service_call,
  coalesce(g.life_pumping,0)     as life_pumping,
  coalesce(g.life_cleaning,0)    as life_cleaning,
  coalesce(g.life_warranty,0)    as life_warranty,
  coalesce(g.life_service_call,0) as life_service_call,
  coalesce(g.life_uncoded_total,0) as life_uncoded_total,
  -- projection to 31 Dec = actual YTD + scheduled pipeline + billing-only cycles
  coalesce(t.ytd_total,0) + coalesce(f.proj_v_total,0) + coalesce(w.proj_recurring_all,0) as projection_total,
  coalesce(f.proj_visits,0)      as projection_visits,
  coalesce(f.proj_v_total,0)     as projection_visit_value,
  coalesce(w.proj_recurring,0)   as projection_recurring_value,
  -- true when the client has a billing-only warranty job whose cadence could
  -- NOT be inferred, so its charges are missing from the projection. The UI must
  -- say so; a silently-low number is the defect this whole migration replaces.
  exists (select 1 from wd_jobs wj
           where wj.client_id = cl.id
             and not exists (select 1 from wd_cadence wc where wc.client_id = cl.id)
         )                        as projection_recurring_unknown,
  coalesce(g.ytd_pumping,0)      + coalesce(f.proj_v_pumping,0)      as projection_pumping,
  coalesce(g.ytd_cleaning,0)     + coalesce(f.proj_v_cleaning,0)     as projection_cleaning,
  coalesce(g.ytd_warranty,0)     + coalesce(w.proj_recurring,0)      as projection_warranty,
  coalesce(g.ytd_service_call,0) + coalesce(f.proj_v_service_call,0) as projection_service_call
from public.clients cl
left join tot t on t.client_id = cl.id
left join grp g on g.client_id = cl.id
left join fut f on f.client_id = cl.id
left join wd  w on w.client_id = cl.id;

comment on view client.v_client_billing is
  'Client App billing block, one row per client. Totals from public.invoices.total (draft excluded, bad_debt included). Per-group splits from INVOICE-scoped line items via client.fn_billing_group — necessarily 2026-forward because the numbered catalogue only came into use then (Fred 2026-07-31). projection_* = actual YTD + already-scheduled visits to 31 Dec priced from their job line items + billing-only warranty cycles. life_uncoded_total is the invoiced money no card can claim; show it rather than let the cards silently fail to sum.';

revoke all on client.v_client_billing from public;
revoke all on client.v_client_billing from anon;
grant select on client.v_client_billing to authenticated;

commit;
