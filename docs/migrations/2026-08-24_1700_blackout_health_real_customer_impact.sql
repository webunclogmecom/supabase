-- 2026-08-24_1700_blackout_health_real_customer_impact.sql
-- ---------------------------------------------------------------------------
-- Make blackout-health report the number it is actually about.
--
-- THE DEFECT. log_blackout_health() counts derm.v_blackout_blocked_sheets, and that
-- view begins FROM derm.address_row_map WHERE stamp_y_pct IS NOT NULL. It is a
-- measure of sheets that are STAMPED BUT UNMEASURED. It is NOT a measure of how many
-- customers cannot see a document, and it has been read as one -- by the alarm's own
-- what_it_means text, and then by me when I repeated it.
--
-- Measured 2026-08-24, the two numbers disagree in BOTH directions:
--
--   OVERCOUNTS. window5-sheet3 is one of the two "blocked" sheets. Its manifest 959
--   (ticket 822919, 009-CN Casa Neos) has ZERO manifest_visits links, so it never
--   reaches customer.work_orders at all. No card is rendered, empty or otherwise.
--   Customer impact: none.
--
--   UNDERCOUNTS, and this is the bigger half. Work orders showing a DERM number with
--   no viewable file:
--       ticket-833049   10   the deliberate hold (2026-08-19_2355 PART 5)
--       ticket-312024    9   0 stamped rows -> INVISIBLE to the blocked-sheets view
--       ticket-833530    3   0 stamped rows -> INVISIBLE to the blocked-sheets view
--                       ---
--                        22   work orders, 22 distinct clients
--   The alarm said 10. Twelve more customers are in the same state and the instrument
--   structurally cannot see them, because an unstamped sheet has no stamp_y_pct.
--
-- ⚠ AND THE PAYLOAD'S PROSE WAS WRONG TOO. It claimed those clients "see an EMPTY
--   DERM FOG eManifest card". They do not. The card renders
--       "DERM FOG eManifest" / "DERM 833049" / DOCUMENTED chip /
--       "On file, not available for online viewing"
--   with no thumbnail and no Download button -- which is exactly what Field Portal
--   rule 8 prescribes when a document NUMBER exists but no viewable file, and it
--   COMPLIES with Yannick's standing rule that the customer app must not show what we
--   do not have. Nothing 404s and no empty PDF is served. Corrected below.
--   An alarm is a claim. A claim nobody reads is also a claim nobody CHECKS.
--
-- THE FIX: add the direct measure alongside the existing one, and say which is which.
--   customer_impact.work_orders_without_file is
--     select count(*) from customer.work_orders
--      where derm_manifest_number is not null and derm_manifest_url is null
--   That is the customer-facing truth. blocked_sheets stays, because it is the right
--   input for the Stamp Studio work queue -- it just is not the same question.
--
-- ⚠ NOT changed: derm.v_blackout_blocked_sheets itself. Widening it to unstamped
--   sheets would change what the Stamp Studio measurement queue means, and that view
--   has callers. Adding a second, clearly-named number is the smaller act.
--
-- Audit (Rule 8): one function body. No table, column or grant on any audited table
-- changes; audit.logs untouched and no audit opt-in list changes.
--
-- @Building Apps. Claimed in WORKING-NOW.md. No Lovable project touched. The Field
-- Portal Lovable project is @Supabase's claim and nothing here goes near it.

BEGIN;

CREATE OR REPLACE FUNCTION public.log_blackout_health()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'derm', 'pg_temp'
AS $fn$
declare
  v_sheets    int := 0;
  v_clients   int := 0;
  v_manifests int := 0;
  v_oldest    interval;
  v_detail    jsonb;
  v_impact    int := 0;
  v_impact_by jsonb;
  v_attn      boolean := false;
begin
  select count(*),
         coalesce(sum(clients_blocked), 0),
         coalesce(sum(manifests_blocked), 0),
         max(blocked_for)
    into v_sheets, v_clients, v_manifests, v_oldest
    from derm.v_blackout_blocked_sheets;

  -- THE CUSTOMER-FACING NUMBER. Independent of stamping, so it sees the sheets the
  -- blocked-sheets view is blind to.
  select count(*) into v_impact
    from customer.work_orders w
   where w.derm_manifest_number is not null
     and w.derm_manifest_url is null;

  select coalesce(jsonb_agg(jsonb_build_object('ticket', t, 'work_orders', n) order by n desc), '[]'::jsonb)
    into v_impact_by
    from (select w.derm_manifest_number t, count(*) n
            from customer.work_orders w
           where w.derm_manifest_number is not null and w.derm_manifest_url is null
           group by 1) s;

  -- attention if EITHER measure is non-zero. A customer without a viewable document
  -- matters whether or not the sheet behind it happens to be stamped.
  v_attn := (v_sheets > 0) or (v_impact > 0);

  select coalesce(jsonb_agg(jsonb_build_object(
           'dump_folder',       b.dump_folder,
           'blocker',           b.blocker,
           'what_to_do',        b.what_to_do,
           'stamped_rows',      b.stamped_rows,
           'stamped_pages',     b.stamped_pages,
           'rows_ready',        b.rows_ready,
           'rows_no_stamp_ts',  b.rows_no_stamp_ts,
           'clients_blocked',   b.clients_blocked,
           'manifests_blocked', b.manifests_blocked,
           'blocked_for',       b.blocked_for::text) order by b.last_stamp_at), '[]'::jsonb)
    into v_detail
    from derm.v_blackout_blocked_sheets b;

  insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
  values ('blackout-health', now(), now(), greatest(v_sheets, v_impact),
          case when v_attn then 'attention' else 'ok' end,
          jsonb_build_object(
            'blocked_sheets',    v_sheets,
            'clients_blocked',   v_clients,
            'manifests_blocked', v_manifests,
            'oldest_blocked_for', v_oldest::text,
            'sheets',            v_detail,
            'customer_impact',   jsonb_build_object(
                                   'work_orders_without_file', v_impact,
                                   'by_ticket',                v_impact_by),
            'what_it_means',     case when v_attn
              then 'TWO DIFFERENT NUMBERS, do not conflate them. customer_impact.work_orders_without_file is how many customer work orders show a DERM number with no viewable file - the customer-facing truth, independent of stamping. blocked_sheets counts sheets that are STAMPED BUT UNMEASURED, which is the Stamp Studio work queue and is BLIND to unstamped sheets. On 2026-08-24 they were 22 and 2. Read the per-sheet blocker and what_to_do for the remedy: it is NOT always a measurement pass. blocker=held_by_constraint means DELIBERATELY frozen and measuring it would re-open a cross-client leak; blocker=no_stamp_timestamp needs a re-stamp in the Studio. NOTE the customer card is not blank - it renders "On file, not available for online viewing", per Field Portal rule 8.'
              else 'Every stamped address-sheet page has a measured extent, and every customer work order with a DERM number has a viewable file.' end));

  return greatest(v_sheets, v_impact);
end $fn$;

COMMENT ON FUNCTION public.log_blackout_health() IS
  'Daily blackout health verdict into public.sync_log. Reports TWO numbers because they answer different questions: customer_impact.work_orders_without_file (customer.work_orders with a DERM number and no file - the customer-facing truth, 22 on 2026-08-24) and blocked_sheets (derm.v_blackout_blocked_sheets, stamped-but-unmeasured, 2 on the same day, and structurally blind to UNSTAMPED sheets because that view filters stamp_y_pct IS NOT NULL). Also carries the per-sheet blocker and what_to_do, because the remedy differs by sheet and the old static text ("run a measurement pass") would have re-opened a cross-client leak on ticket-833049.';

COMMIT;

-- VERIFY (run after applying)
--
-- 1. the two measures disagree, which is the entire point
--    select public.log_blackout_health();
--    select details->'customer_impact'->>'work_orders_without_file' as customers,
--           details->>'blocked_sheets' as sheets
--      from public.sync_log where sync_source='blackout-health'
--     order by started_at desc limit 1;
--    -- expect customers = 22, sheets = 2 on 2026-08-24
--    ⚠ If they are EQUAL, do not assume agreement means correctness - check whether
--      the customer_impact query actually ran, because a failed subquery and a genuine
--      match look the same in the payload.
--
-- 2. POSITIVE CONTROL that the customer-impact query can see the other side
--    select count(*) from customer.work_orders
--     where derm_manifest_number is not null and derm_manifest_url is not null;
--    -- expect a large number (647 on 2026-08-24). A 0 here means the join or the
--    -- column is wrong and the 22 is meaningless.
--
-- 3. the per-ticket breakdown names the tickets the old instrument could not see
--    select jsonb_pretty(details->'customer_impact'->'by_ticket')
--      from public.sync_log where sync_source='blackout-health'
--     order by started_at desc limit 1;
--    -- expect 833049 (10), 312024 (9), 833530 (3). The last two have ZERO stamped
--    -- rows and do not appear in derm.v_blackout_blocked_sheets at all.
--
-- 4. the sheets array still carries the per-sheet remedy
--    -- expect every element to have BOTH 'blocker' and 'what_to_do'
