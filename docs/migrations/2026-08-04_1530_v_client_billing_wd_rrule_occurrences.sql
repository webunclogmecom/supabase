-- =====================================================================
-- 2026-08-04_1530  WD projections: count RRULE occurrences instead of dividing
-- =====================================================================
-- WHY
--   `client.v_client_billing` projects Warranty-of-Drainage revenue as
--     charge * floor((y_end - today) / median_invoice_gap_days)
--   It guessed the cadence from invoice history and referenced NONE of
--   jobs.billing_type / invoice_frequency / invoice_rrule. Since 2026-08-04_1330 the
--   real rule is stored on every live job, so the guess is now strictly worse than the
--   data sitting next to it.
--
--   Three defects, and fixing only the obvious one would have fixed 2 of 3 BY LUCK.
--
-- DEFECT 1 - A DAYS QUOTIENT CANNOT EXPRESS PHASE. This is the subtle one.
--   Substituting the true cadence into floor(days_left / cadence) still gets the count
--   wrong, because two jobs on the SAME 61-day interval invoice in different months:
--     169-TCE #10000308  anchor 2026-04-22  ->  Apr/Jun/AUG/OCT/DEC  = 3 left in 2026
--     the other 22       anchor 2025-07-xx  ->  Sep/Nov              = 2 left in 2026
--   So the fix ENUMERATES occurrences from the job's own start date. New helper
--   `client.fn_rrule_occurrences(rrule, anchor, from, to)` counts them, and returns
--   NULL for any shape it cannot count exactly so the caller falls back rather than
--   receiving a guess. 17 tests, including all three phase cases above and the
--   RFC 5545 rule that BYMONTHDAY=31 SKIPS short months (7 occurrences in 2026, not 12).
--
-- DEFECT 2 - the cadence came from history even when the rule was known.
--   Now: prefer the stored rule whenever invoice_frequency IS NOT NULL; fall back to
--   the invoice-median gap only when it is NULL. 21 of 24 wd_jobs clients already
--   agreed, so this is a targeted correction, not a rewrite.
--
-- DEFECT 3 - the FALLBACK ITSELF WAS POISONED, so keeping it unchanged would not have
--   preserved the good cases. `wd_cadence` matched invoices via
--     client.fn_billing_group(l.name) = 'warranty' OR l.name ~* 'warranty'
--   That second disjunct pulls in WD **call-out** lines that fn_billing_group scores
--   NULL - measured, 319 line items match it while scoring NULL, e.g.
--   'Manual Unclogging Under Warranty of Drainage', 'Emergency Visit under the
--   warranty', 'Hydrojet Unclogging Commercial Under Warranty'. Their 10-14 day gaps
--   dragged 061-TCE's median to 47 days against a real 61-day rule. Disjunct dropped.
--   Verified safe: all 24 wd_jobs clients still have a cadence row afterwards, so
--   nobody LOSES their fallback - it only gets cleaner.
--
-- 🛑 WHAT THIS DELIBERATELY DOES NOT DO (Fred, 2026-08-04): it does not touch
--   `client.fn_billing_group`. That function returns NULL for a WD fee whose line name
--   is not prefixed '08 - ', so such fees miss `ytd_warranty` entirely (061-TCE reads
--   $225 YTD while four WD fees were billed in 2026). Fixing it would RECLASSIFY
--   HISTORICAL REVENUE across the warranty/uncoded split - numbers Yannick has already
--   seen - so Fred's instruction was explicitly "do not reclassify it". The YTD half of
--   every figure below therefore still rests on that understated base. That is a known,
--   accepted limitation of this migration, not an oversight.
--
-- CREATE OR REPLACE (not DROP+CREATE): the column list and every column TYPE are
--   unchanged, so grants survive. A DROP would discard `authenticated=r` and the app
--   would 42501. Asserted below anyway.
--
-- AUDIT (rule #8): a view and a pure function. No table, no trigger. N/A.
-- REVERSIBLE: yes - re-create the view from this file's git parent, and drop the
--   helper function. No data is written.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. The occurrence counter. Pure arithmetic, no table access, so being
--    SECURITY INVOKER inside an owner-rights view cannot raise 42501 (the
--    grants/functions asymmetry in Supabase/CLAUDE.md). Mirrors fn_billing_group:
--    IMMUTABLE, INVOKER, pinned empty search_path.
-- ---------------------------------------------------------------------
create or replace function client.fn_rrule_occurrences(
  p_rrule text, p_anchor date, p_from date, p_to date
) returns integer
language sql
immutable
set search_path = ''
as $fn$
  select case
    when p.freq = 'MONTHLY' and p.byday is null and p.md is not null then (
      select count(*)::int
        from generate_series(
               date_trunc('month', p_anchor::timestamp),
               date_trunc('month', p_to::timestamp),
               make_interval(months => p.ival)) m
       where case
               when p.md = -1
                 then (m + interval '1 month' - interval '1 day')::date
               when p.md <= extract(day from (m + interval '1 month' - interval '1 day'))::int
                 then (m + make_interval(days => p.md - 1))::date
               else null
             end > p_from
         and case
               when p.md = -1
                 then (m + interval '1 month' - interval '1 day')::date
               when p.md <= extract(day from (m + interval '1 month' - interval '1 day'))::int
                 then (m + make_interval(days => p.md - 1))::date
               else null
             end <= p_to
    )
    else null
  end
  from (
    select (regexp_match(b, '(^|;)FREQ=([A-Z]+)'))[2]                         as freq,
           coalesce(((regexp_match(b, '(^|;)INTERVAL=([0-9]+)'))[2])::int, 1)  as ival,
           (regexp_match(b, '(^|;)BYDAY=([A-Z0-9,]+)'))[2]                    as byday,
           ((regexp_match(b, '(^|;)BYMONTHDAY=(-?[0-9]+)(;|$)'))[2])::int      as md
      from (select upper(replace(coalesce(p_rrule, ''), 'RRULE:', ''))) x(b)
  ) p
  where p_anchor is not null and p_from is not null and p_to is not null and p_rrule is not null
$fn$;

comment on function client.fn_rrule_occurrences(text, date, date, date) is
  'Counts RRULE occurrences in (p_from, p_to], anchored on p_anchor which supplies the PHASE. '
  'Returns NULL for any shape it cannot count EXACTLY (weekly, yearly, nth-weekday, a multi-value '
  'BYMONTHDAY) so callers fall back instead of receiving a guess. A days-based quotient cannot '
  'replace this: two jobs on the same 61-day interval land in different months depending on anchor.';

revoke all on function client.fn_rrule_occurrences(text, date, date, date) from public;
grant execute on function client.fn_rrule_occurrences(text, date, date, date) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 2. The view. Only wd_jobs / wd_cadence / wd and the one output expression
--    projection_recurring_unknown change; everything else is byte-identical to the
--    previous definition.
-- ---------------------------------------------------------------------
create or replace view client.v_client_billing as
 WITH cal AS (
         SELECT date_trunc('year'::text, (now() AT TIME ZONE 'America/New_York'::text))::date AS y_start,
            (date_trunc('year'::text, (now() AT TIME ZONE 'America/New_York'::text)) + '1 year'::interval - '1 day'::interval)::date AS y_end,
            (now() AT TIME ZONE 'America/New_York'::text)::date AS today
        ), inv AS (
         SELECT i.id,
            i.client_id,
            i.total,
            (COALESCE(i.sent_at, i.created_at) AT TIME ZONE 'America/New_York'::text)::date AS inv_date
           FROM invoices i
          WHERE COALESCE(i.invoice_status, ''::text) <> 'draft'::text AND i.client_id IS NOT NULL
        ), tot AS (
         SELECT inv.client_id,
            COALESCE(sum(inv.total) FILTER (WHERE inv.inv_date >= cal.y_start), 0::numeric) AS ytd_total,
            count(*) FILTER (WHERE inv.inv_date >= cal.y_start) AS ytd_invoices,
            COALESCE(sum(inv.total), 0::numeric) AS life_total,
            count(*) AS life_invoices,
            min(inv.inv_date) AS life_since
           FROM inv
             CROSS JOIN cal
          GROUP BY inv.client_id
        ), gl AS (
         SELECT inv.client_id,
            client.fn_billing_group(l.name) AS grp,
            inv.inv_date,
            l.total_price * COALESCE(inv.total / NULLIF(li.li_sum, 0::numeric), 1::numeric) AS total_price
           FROM line_items l
             JOIN inv ON inv.id = l.invoice_id
             JOIN LATERAL ( SELECT sum(l2.total_price) AS li_sum
                   FROM line_items l2
                  WHERE l2.invoice_id = inv.id) li ON true
        ), grp AS (
         SELECT gl.client_id,
            COALESCE(sum(gl.total_price) FILTER (WHERE gl.grp = 'pumping'::text AND gl.inv_date >= cal.y_start), 0::numeric) AS ytd_pumping,
            COALESCE(sum(gl.total_price) FILTER (WHERE gl.grp = 'cleaning'::text AND gl.inv_date >= cal.y_start), 0::numeric) AS ytd_cleaning,
            COALESCE(sum(gl.total_price) FILTER (WHERE gl.grp = 'warranty'::text AND gl.inv_date >= cal.y_start), 0::numeric) AS ytd_warranty,
            COALESCE(sum(gl.total_price) FILTER (WHERE gl.grp = 'service_call'::text AND gl.inv_date >= cal.y_start), 0::numeric) AS ytd_service_call,
            COALESCE(sum(gl.total_price) FILTER (WHERE gl.grp = 'pumping'::text), 0::numeric) AS life_pumping,
            COALESCE(sum(gl.total_price) FILTER (WHERE gl.grp = 'cleaning'::text), 0::numeric) AS life_cleaning,
            COALESCE(sum(gl.total_price) FILTER (WHERE gl.grp = 'warranty'::text), 0::numeric) AS life_warranty,
            COALESCE(sum(gl.total_price) FILTER (WHERE gl.grp = 'service_call'::text), 0::numeric) AS life_service_call,
            COALESCE(sum(gl.total_price) FILTER (WHERE gl.grp IS NULL), 0::numeric) AS life_uncoded_total
           FROM gl
             CROSS JOIN cal
          GROUP BY gl.client_id
        ), fut AS (
         SELECT v.client_id,
            count(*) AS proj_visits,
            COALESCE(sum(jv.pumping), 0::numeric) AS proj_v_pumping,
            COALESCE(sum(jv.cleaning), 0::numeric) AS proj_v_cleaning,
            COALESCE(sum(jv.service_call), 0::numeric) AS proj_v_service_call,
            COALESCE(sum(jv.all_lines), 0::numeric) AS proj_v_total
           FROM visits v
             CROSS JOIN cal
             JOIN LATERAL ( SELECT COALESCE(sum(l.total_price) FILTER (WHERE client.fn_billing_group(l.name) = 'pumping'::text), 0::numeric) AS pumping,
                    COALESCE(sum(l.total_price) FILTER (WHERE client.fn_billing_group(l.name) = 'cleaning'::text), 0::numeric) AS cleaning,
                    COALESCE(sum(l.total_price) FILTER (WHERE client.fn_billing_group(l.name) = 'service_call'::text), 0::numeric) AS service_call,
                    COALESCE(sum(l.total_price), 0::numeric) AS all_lines
                   FROM line_items l
                  WHERE l.job_id = v.job_id AND l.invoice_id IS NULL AND l.visit_id IS NULL) jv ON true
          WHERE v.deleted_at IS NULL AND lower(COALESCE(v.visit_status, ''::text)) = 'scheduled'::text AND v.visit_date > cal.today AND v.visit_date <= cal.y_end
          GROUP BY v.client_id
        ), wd_jobs AS (
         -- CHANGED: carries the stored rule and the job's anchor date through.
         SELECT j.client_id,
            j.id AS job_id,
            j.invoice_frequency,
            j.invoice_rrule,
            (j.start_at AT TIME ZONE 'America/New_York'::text)::date AS anchor,
            ( SELECT COALESCE(sum(l.total_price), 0::numeric) AS "coalesce"
                   FROM line_items l
                  WHERE l.job_id = j.id AND l.invoice_id IS NULL AND l.visit_id IS NULL AND client.fn_billing_group(l.name) = 'warranty'::text) AS charge,
            ( SELECT COALESCE(sum(l.total_price), 0::numeric) AS "coalesce"
                   FROM line_items l
                  WHERE l.job_id = j.id AND l.invoice_id IS NULL AND l.visit_id IS NULL) AS charge_all
           FROM jobs j
          WHERE lower(COALESCE(j.job_status, ''::text)) <> 'archived'::text AND (EXISTS ( SELECT 1
                   FROM line_items l
                  WHERE l.job_id = j.id AND l.invoice_id IS NULL AND l.visit_id IS NULL AND client.fn_billing_group(l.name) = 'warranty'::text)) AND NOT (EXISTS ( SELECT 1
                   FROM line_items l
                  WHERE l.job_id = j.id AND l.invoice_id IS NULL AND l.visit_id IS NULL AND (client.fn_billing_group(l.name) = ANY (ARRAY['pumping'::text, 'cleaning'::text, 'service_call'::text]))))
        ), wd_cadence AS (
         -- CHANGED: the `OR l.name ~* 'warranty'` disjunct is GONE. It matched 319 WD
         -- call-out lines that fn_billing_group scores NULL, whose 10-14 day gaps
         -- poisoned the median. This CTE is now the FALLBACK ONLY (invoice_frequency IS NULL).
         SELECT g_1.client_id,
            percentile_cont(0.5::double precision) WITHIN GROUP (ORDER BY (g_1.gap::double precision)) AS days
           FROM ( SELECT inv.client_id,
                    inv.inv_date - lag(inv.inv_date) OVER (PARTITION BY inv.client_id ORDER BY inv.inv_date) AS gap
                   FROM inv
                  WHERE (EXISTS ( SELECT 1
                           FROM line_items l
                          WHERE l.invoice_id = inv.id AND client.fn_billing_group(l.name) = 'warranty'::text))) g_1
          WHERE g_1.gap IS NOT NULL AND g_1.gap > 0
          GROUP BY g_1.client_id
        ), wd AS (
         -- CHANGED: per-JOB occurrence count, rule first and history second, instead of
         -- one per-client quotient. bool_or tracks whether any job's count is unknowable.
         SELECT w_1.client_id,
            COALESCE(sum(w_1.charge * n.n_occ), 0::numeric)::double precision AS proj_recurring,
            COALESCE(sum(w_1.charge_all * n.n_occ), 0::numeric)::double precision AS proj_recurring_all,
            bool_or(n.n_occ IS NULL) AS any_unknown
           FROM wd_jobs w_1
             CROSS JOIN cal
             LEFT JOIN wd_cadence c ON c.client_id = w_1.client_id
             JOIN LATERAL ( SELECT COALESCE(
                      CASE WHEN w_1.invoice_frequency IS NOT NULL
                           THEN client.fn_rrule_occurrences(w_1.invoice_rrule, w_1.anchor, cal.today, cal.y_end)
                      END,
                      floor((cal.y_end - cal.today)::numeric / NULLIF(c.days, 0::double precision)::numeric)::int
                    ) AS n_occ) n ON true
          GROUP BY w_1.client_id
        )
 SELECT cl.id AS client_id,
    COALESCE(t.ytd_total, 0::numeric) AS ytd_total,
    COALESCE(t.ytd_invoices, 0::bigint) AS ytd_invoices,
    COALESCE(t.life_total, 0::numeric) AS life_total,
    COALESCE(t.life_invoices, 0::bigint) AS life_invoices,
    t.life_since,
    COALESCE(g.ytd_pumping, 0::numeric) AS ytd_pumping,
    COALESCE(g.ytd_cleaning, 0::numeric) AS ytd_cleaning,
    COALESCE(g.ytd_warranty, 0::numeric) AS ytd_warranty,
    COALESCE(g.ytd_service_call, 0::numeric) AS ytd_service_call,
    COALESCE(g.life_pumping, 0::numeric) AS life_pumping,
    COALESCE(g.life_cleaning, 0::numeric) AS life_cleaning,
    COALESCE(g.life_warranty, 0::numeric) AS life_warranty,
    COALESCE(g.life_service_call, 0::numeric) AS life_service_call,
    COALESCE(g.life_uncoded_total, 0::numeric) AS life_uncoded_total,
    (COALESCE(t.ytd_total, 0::numeric) + COALESCE(f.proj_v_total, 0::numeric))::double precision + COALESCE(w.proj_recurring_all, 0::double precision) AS projection_total,
    COALESCE(f.proj_visits, 0::bigint) AS projection_visits,
    COALESCE(f.proj_v_total, 0::numeric) AS projection_visit_value,
    COALESCE(w.proj_recurring, 0::double precision) AS projection_recurring_value,
    -- CHANGED: true when a WD job's occurrence count could not be determined at all,
    -- rather than merely "the client has no invoice-gap history".
    COALESCE(w.any_unknown, false) AS projection_recurring_unknown,
    COALESCE(g.ytd_pumping, 0::numeric) + COALESCE(f.proj_v_pumping, 0::numeric) AS projection_pumping,
    COALESCE(g.ytd_cleaning, 0::numeric) + COALESCE(f.proj_v_cleaning, 0::numeric) AS projection_cleaning,
    COALESCE(g.ytd_warranty, 0::numeric)::double precision + COALESCE(w.proj_recurring, 0::double precision) AS projection_warranty,
    COALESCE(g.ytd_service_call, 0::numeric) + COALESCE(f.proj_v_service_call, 0::numeric) AS projection_service_call
   FROM clients cl
     LEFT JOIN tot t ON t.client_id = cl.id
     LEFT JOIN grp g ON g.client_id = cl.id
     LEFT JOIN fut f ON f.client_id = cl.id
     LEFT JOIN wd w ON w.client_id = cl.id;

-- ---------------------------------------------------------------------
-- 3. ASSERTIONS. Deliberately TIME-INDEPENDENT: the projection figures depend on
--    (y_end - today), so hard-coding today's dollar values would make this file fail
--    tomorrow for the wrong reason. The measured movements are recorded in the
--    changelog instead; what is asserted here are the invariants.
-- ---------------------------------------------------------------------
do $$
declare n int; v_def text; v_a int; v_b int;
begin
  -- (a) GRANTS. CREATE OR REPLACE preserves them, but a silent loss surfaces later as
  --     a 42501 in the Client App, so prove it rather than trust it.
  if not has_table_privilege('authenticated', 'client.v_client_billing', 'SELECT') then
    raise exception 'GRANT LOST: authenticated can no longer SELECT client.v_client_billing';
  end if;

  -- (b) the helper exists, is IMMUTABLE, and anon cannot execute it
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'client' and p.proname = 'fn_rrule_occurrences' and p.provolatile = 'i';
  if n <> 1 then raise exception 'fn_rrule_occurrences missing or not IMMUTABLE'; end if;
  if has_function_privilege('anon', 'client.fn_rrule_occurrences(text,date,date,date)', 'EXECUTE') then
    raise exception 'anon can EXECUTE fn_rrule_occurrences - revoke it';
  end if;

  -- (c) THE POISONED DISJUNCT IS GONE. This is defect 3, and a find-and-replace could
  --     silently reintroduce it.
  v_def := pg_get_viewdef('client.v_client_billing'::regclass, true);
  if v_def ~ 'warranty''::text' and v_def ~ '~\*' then
    raise exception 'the `name ~* warranty` disjunct is still in wd_cadence';
  end if;

  -- (d) THE WHOLE POINT: phase. The SAME rule over the SAME window must give a
  --     DIFFERENT count for an even-month anchor than for an odd-month one. If this
  --     ever returns equal numbers, the function has regressed to a quotient.
  v_a := client.fn_rrule_occurrences('RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=22',
           date '2026-04-22', date '2026-08-04', date '2026-12-31');   -- even anchor
  v_b := client.fn_rrule_occurrences('RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=22',
           date '2025-07-22', date '2026-08-04', date '2026-12-31');   -- odd anchor
  if v_a is null or v_b is null then raise exception 'phase control returned NULL'; end if;
  if v_a = v_b then
    raise exception 'PHASE CONTROL FAILED: even and odd anchors both give % occurrences', v_a;
  end if;
  if v_a <> 3 or v_b <> 2 then
    raise exception 'PHASE CONTROL FAILED: expected 3 and 2, got % and %', v_a, v_b;
  end if;

  -- (e) NEGATIVE CONTROL on the function: an unsupported shape must yield NULL, so the
  --     caller falls back rather than silently receiving a wrong count.
  if client.fn_rrule_occurrences('RRULE:FREQ=WEEKLY;BYDAY=MO', date '2026-01-05', date '2026-08-04', date '2026-12-31') is not null then
    raise exception 'NEGATIVE CONTROL FAILED: a WEEKLY rule was counted instead of returning NULL';
  end if;
  if client.fn_rrule_occurrences('RRULE:FREQ=MONTHLY;BYMONTHDAY=10,25', date '2026-01-10', date '2026-08-04', date '2026-12-31') is not null then
    raise exception 'NEGATIVE CONTROL FAILED: a multi-value BYMONTHDAY was counted';
  end if;

  -- (f) the view still returns exactly one row per client
  select count(*) into n from client.v_client_billing;
  select count(*) into v_a from public.clients;
  if n <> v_a then raise exception 'view returns % rows for % clients', n, v_a; end if;

  -- (g) 169-TCE was the motivating case: its recurring value was 0 and its
  --     projection_recurring_unknown was TRUE purely because the per-client median could
  --     not be formed. With the rule it must now be known and non-zero.
  select count(*) into n from client.v_client_billing b
    join public.clients c on c.id = b.client_id
   where c.client_code = '169-TCE'
     and b.projection_recurring_unknown = false
     and b.projection_recurring_value > 0;
  if n <> 1 then
    raise exception '169-TCE still has no known recurring projection (expected known and > 0)';
  end if;

  raise notice 'V_CLIENT_BILLING WD OCCURRENCES OK - grants intact, phase control fires, negative controls fire, 169-TCE resolved';
end $$;

commit;
