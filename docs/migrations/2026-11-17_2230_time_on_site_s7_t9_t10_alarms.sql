-- ============================================================================
-- 2026-11-17_2230_time_on_site_s7_t9_t10_alarms  Re-check S7: alarms T9 (a visit the nightly never closed) and T10 (a
--   visit waiting on a person more than 8 days)
-- ============================================================================
-- THE ASK
--   Trello vpF5PLQj. PLAN 5.4 / 9 (approved 2026-10-27, "Approve the whole plan"), stage S7, due Mon 11-16 and not built.
--   Fred, 2026-11-17: "i want that to be completed". T11 (the monthly person sample) is NOT built: Fred, Q-M, 2026-11-02,
--   no monthly sample.
-- WHAT THE TWO ALARMS ARE
--   T9  a completed client visit dated in 2026, dated 11 or more days ago (past the nightly's last look and its day-10
--       close-out), with no current applied or proposed row in public.visit_time_on_site_corrections. Catches a close-out
--       gap: the nightly stopped, a close-out rolled back, a visit completed after its window. Needs no stop.
--   T10 a current proposed row older than 8 days: a visit the nightly held for a person that nobody answered (the person
--       loop is weekly, so a hold raised on any weekday reaches a Monday first).
--   Both land EMPTY (PLAN 5.4: a check lands when its list is empty): T9 has been 0 since S6 (1,519 visits, measured
--   2026-11-17 21:30 ET), and T10's 15 rows of 2026-11-03 were answered by 2026-11-17_2150 (the person page).
-- THE CHAIN (each body edited from its live text by anchored replacements, each anchor found exactly once, md5-pinned)
--   public.fn_time_on_site_checks   T9 and T10 = the counts, T_detail.T9 / T10 = the visits.
--   public.fn_refresh_stop_facts    (hourly at :35) counts T9 and T10 in the stop_facts_integrity verdict (its key list
--                                   is explicit; a key missing from it never turns the run to error).
--   public.log_jobber_sync_health   (13:13 UTC daily) raises one item per non-zero key already; this adds the two sentences.
-- WHAT DOES NOT CHANGE: T1 to T8 and T12 and every other key of T_detail (VERIFY compares the old body, kept as a pg_temp
--   copy), every other line of the three bodies, their grants, fn_stop_facts_checks (it merges the checks as they are).
-- PIN: fn_time_on_site_checks 03d6d444ec2f782418ab28c575e149b7, fn_refresh_stop_facts b2f9708304e9d93ad7d997c508758977,
--   log_jobber_sync_health b728dbc3144a64097fa2f782a1043e04 (the body of 2026-11-14_0720_payments_copy_schedule, which
--   came after T12's efb5218b: so the T12 rollback's pin of that function is stale since 11-14). VERIFY pins the three new
--   md5s (filled in from the rehearsal).
-- FIXTURES (each inside a subtransaction that is undone): a current applied row of an old visit superseded -> T9 = 1
--   naming that visit, the old body has no T9 (control); a current row turned proposed 9 days old -> T10 = 1, 7 days old ->
--   T10 = 0.
-- PENDING ROLLBACKS that pin fn_time_on_site_checks (S2, S4, the 6428 card, S6, T12): run this file's rollback first.
-- APPLY: clear of :05 to :10, :15 to :20, :30 to :45 (the stop facts refresh runs at :35). lock_timeout 3s.
-- ROLLBACK: docs/migrations/2026-11-17_rollback_time_on_site_s7_t9_t10_alarms.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pin$ BEGIN
  IF md5(pg_get_functiondef('public.fn_time_on_site_checks()'::regprocedure)) <> '03d6d444ec2f782418ab28c575e149b7' THEN
    RAISE EXCEPTION 'S7: public.fn_time_on_site_checks() moved (expected md5 03d6d444ec2f782418ab28c575e149b7)'; END IF;
  IF md5(pg_get_functiondef('public.fn_refresh_stop_facts(bigint,timestamp with time zone)'::regprocedure)) <> 'b2f9708304e9d93ad7d997c508758977' THEN
    RAISE EXCEPTION 'S7: public.fn_refresh_stop_facts moved (expected md5 b2f9708304e9d93ad7d997c508758977)'; END IF;
  IF md5(pg_get_functiondef('public.log_jobber_sync_health()'::regprocedure)) <> 'b728dbc3144a64097fa2f782a1043e04' THEN
    RAISE EXCEPTION 'S7: public.log_jobber_sync_health() moved (expected md5 b728dbc3144a64097fa2f782a1043e04)'; END IF;
END $pin$;

-- replace exactly one occurrence, or raise
CREATE FUNCTION pg_temp.rep1(body text, old text, new text, what text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE n int := (length(body) - length(replace(body, old, ''))) / greatest(length(old), 1);
BEGIN
  IF n <> 1 THEN RAISE EXCEPTION 'S7: anchor % found % times, expected 1', what, n; END IF;
  RETURN replace(body, old, new);
END $f$;

-- the old checks body, kept for this transaction as the control
DO $old$ BEGIN
  EXECUTE pg_temp.rep1(pg_get_functiondef('public.fn_time_on_site_checks()'::regprocedure),
    'CREATE OR REPLACE FUNCTION public.fn_time_on_site_checks()', 'CREATE FUNCTION pg_temp.fn_old_time_on_site_checks()', 'control name');
END $old$;

-- 1. fn_time_on_site_checks: T9 and T10
DO $c$ DECLARE b text := pg_get_functiondef('public.fn_time_on_site_checks()'::regprocedure); BEGIN
  b := pg_temp.rep1(b, $a$-- over every settled row, any date.
$a$, $a$-- over every settled row, any date.
-- 2026-11-17 (Trello vpF5PLQj, re-check S7; Fred: "i want that to be completed"): T9, a visit the nightly never closed
-- into the ledger; T10, a visit waiting on a person more than 8 days. T11 (a monthly sample) is not built (Fred, Q-M).
$a$, 'header');
  b := pg_temp.rep1(b, $a$  t7 bigint[]; t8 bigint[]; t12 bigint[];
$a$, $a$  t7 bigint[]; t8 bigint[]; t12 bigint[]; t9 bigint[]; t10 bigint[];
$a$, 'declare');
  b := pg_temp.rep1(b, $a$  RETURN jsonb_build_object('T1', coalesce(cardinality(t1), 0),$a$, $a$  -- T9 a completed 2026 client visit dated 11 or more days ago (past the nightly's last look and its day-10 close-out)
  --    with no current applied or proposed row in public.visit_time_on_site_corrections: a close-out gap (the nightly
  --    stopped, a close-out rolled back, a visit completed after its window). Needs no stop. A person runs the close-out
  --    for its date or settles it on the person page.
  SELECT array_agg(v.id ORDER BY v.id) INTO t9 FROM public.visits v
   WHERE v.visit_status = 'completed' AND v.deleted_at IS NULL AND NOT public.fn_is_non_customer(v.client_id)
     AND v.visit_date >= date '2026-01-01' AND v.visit_date <= v_today - 11
     AND NOT EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections c
                      WHERE c.visit_id = v.id AND c.superseded_at IS NULL AND c.status IN ('applied', 'proposed'));
  -- T10 a visit waiting on a person: a current proposed row older than 8 days (the person loop is weekly). A person
  --     answers it on the person page and a migration supersedes the row.
  SELECT array_agg(l.visit_id ORDER BY l.visit_id) INTO t10 FROM public.visit_time_on_site_corrections l
   WHERE l.superseded_at IS NULL AND l.status = 'proposed' AND l.created_at < now() - interval '8 days';
  RETURN jsonb_build_object('T1', coalesce(cardinality(t1), 0),$a$, 'return');
  b := pg_temp.rep1(b, $a$'T12', coalesce(cardinality(t12), 0),$a$, $a$'T12', coalesce(cardinality(t12), 0),
    'T9', coalesce(cardinality(t9), 0), 'T10', coalesce(cardinality(t10), 0),$a$, 'counts');
  b := pg_temp.rep1(b, $a$'T8', t8, 'T12', t12));$a$, $a$'T8', t8, 'T12', t12, 'T9', t9, 'T10', t10));$a$, 'detail');
  EXECUTE b;
END $c$;

-- 2. fn_refresh_stop_facts: count T9 and T10
DO $r$ DECLARE b text := pg_get_functiondef('public.fn_refresh_stop_facts(bigint,timestamp with time zone)'::regprocedure); BEGIN
  b := pg_temp.rep1(b, $a$     -- 2026-11-12: T12 (a settled time with another visit's completion inside its stay) counted too
     where x.key in ('Z1','Z2','Z3','Z4','Z7','Z8','Z9','T1','T2','T3','T4','T5','T6','T7','T8','T12') and (x.value)::text::int > 0;$a$,
  $a$     -- 2026-11-12: T12 (a settled time with another visit's completion inside its stay) counted too
     -- 2026-11-17 (re-check S7): T9 (a visit never closed into the ledger) and T10 (waiting on a person > 8 days) too
     where x.key in ('Z1','Z2','Z3','Z4','Z7','Z8','Z9','T1','T2','T3','T4','T5','T6','T7','T8','T12','T9','T10') and (x.value)::text::int > 0;$a$, 'keys');
  EXECUTE b;
END $r$;

-- 3. log_jobber_sync_health: the two sentences
DO $h$ DECLARE b text := pg_get_functiondef('public.log_jobber_sync_health()'::regprocedure); BEGIN
  b := pg_temp.rep1(b, $a$a person should check which visit the stay belongs to'),
$a$, $a$a person should check which visit the stay belongs to'),
               ('stop_facts_integrity', 'T9', 'a finished client visit 11 or more days old that the nightly time on site check never closed (it has no settled or held row): run the close-out for its date or settle it on the person page'),
               ('stop_facts_integrity', 'T10', 'a time on site the nightly check held for a person more than 8 days ago that nobody has answered: it waits on the person page'),
$a$, 'sentences');
  EXECUTE b;
END $h$;

-- 4. VERIFY
DO $v$
DECLARE n jsonb; o jsonb; fx jsonb; ofx jsonb; vid bigint; lid bigint; t10a int; t10b int;
BEGIN
  IF md5(pg_get_functiondef('public.fn_time_on_site_checks()'::regprocedure)) <> '76b6d76ce9a0e646708cdff5e508010d' THEN RAISE EXCEPTION 'VERIFY S7: checks body md5 %', md5(pg_get_functiondef('public.fn_time_on_site_checks()'::regprocedure)); END IF;
  IF md5(pg_get_functiondef('public.fn_refresh_stop_facts(bigint,timestamp with time zone)'::regprocedure)) <> '3ade76bd16efccd7df3ed44df302ff75' THEN RAISE EXCEPTION 'VERIFY S7: refresh body md5 %', md5(pg_get_functiondef('public.fn_refresh_stop_facts(bigint,timestamp with time zone)'::regprocedure)); END IF;
  IF md5(pg_get_functiondef('public.log_jobber_sync_health()'::regprocedure)) <> 'd96377d76ed20aa1da1055a60fc0b92a' THEN RAISE EXCEPTION 'VERIFY S7: health body md5 %', md5(pg_get_functiondef('public.log_jobber_sync_health()'::regprocedure)); END IF;
  IF (SELECT proacl::text FROM pg_proc WHERE oid = 'public.fn_time_on_site_checks()'::regprocedure) IS DISTINCT FROM '{postgres=X/postgres,service_role=X/postgres}' THEN RAISE EXCEPTION 'VERIFY S7: checks grants moved'; END IF;
  IF (SELECT proacl::text FROM pg_proc WHERE oid = 'public.fn_refresh_stop_facts(bigint,timestamp with time zone)'::regprocedure) IS DISTINCT FROM '{postgres=X/postgres}' THEN RAISE EXCEPTION 'VERIFY S7: refresh grants moved'; END IF;
  IF (SELECT proacl::text FROM pg_proc WHERE oid = 'public.log_jobber_sync_health()'::regprocedure) IS DISTINCT FROM '{postgres=X/postgres,service_role=X/postgres}' THEN RAISE EXCEPTION 'VERIFY S7: health grants moved'; END IF;
  -- the old keys are equal; T9 and T10 land empty
  n := public.fn_time_on_site_checks(); o := pg_temp.fn_old_time_on_site_checks();
  IF (n - 'T9' - 'T10' - 'T_detail') IS DISTINCT FROM (o - 'T_detail') OR ((n->'T_detail') - 'T9' - 'T10') IS DISTINCT FROM (o->'T_detail') THEN
    RAISE EXCEPTION 'VERIFY S7: the old keys differ: new %, old %', n - 'T_detail', o - 'T_detail'; END IF;
  IF (n->>'T9')::int <> 0 OR (n->>'T10')::int <> 0 THEN RAISE EXCEPTION 'VERIFY S7: T9 % T10 % today, expected 0: %', n->>'T9', n->>'T10', n->'T_detail'; END IF;
  -- fixture T9: supersede the current row of the oldest 2026 client visit with one; must name it; the control has no T9
  SELECT l.visit_id, l.id INTO vid, lid FROM public.visit_time_on_site_corrections l JOIN public.visits v ON v.id = l.visit_id
   WHERE l.superseded_at IS NULL AND l.status = 'applied' AND v.visit_date >= date '2026-01-01' AND v.visit_status = 'completed' AND v.deleted_at IS NULL
     AND NOT public.fn_is_non_customer(v.client_id) ORDER BY v.visit_date, v.id LIMIT 1;
  BEGIN
    UPDATE public.visit_time_on_site_corrections SET superseded_at = now() WHERE id = lid;
    fx := public.fn_time_on_site_checks(); ofx := pg_temp.fn_old_time_on_site_checks();
    -- fixture T10: a current row turned proposed, 9 days old, then 7 days old
    UPDATE public.visit_time_on_site_corrections SET superseded_at = NULL, status = 'proposed', created_at = now() - interval '9 days' WHERE id = lid;
    t10a := (public.fn_time_on_site_checks()->>'T10')::int;
    UPDATE public.visit_time_on_site_corrections SET created_at = now() - interval '7 days' WHERE id = lid;
    t10b := (public.fn_time_on_site_checks()->>'T10')::int;
    RAISE EXCEPTION 'S7 fixture undone';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'S7 fixture undone' THEN RAISE; END IF;
  END;
  IF (fx->>'T9')::int <> 1 OR fx->'T_detail'->'T9' IS DISTINCT FROM jsonb_build_array(vid) THEN RAISE EXCEPTION 'VERIFY S7: the T9 fixture gave %, %, expected 1, [%]', fx->>'T9', fx->'T_detail'->'T9', vid; END IF;
  IF ofx ? 'T9' OR ofx ? 'T10' THEN RAISE EXCEPTION 'VERIFY S7: the control (old body) has T9 or T10'; END IF;
  IF t10a <> 1 OR t10b <> 0 THEN RAISE EXCEPTION 'VERIFY S7: the T10 fixture gave % (9 days) and % (7 days), expected 1 and 0', t10a, t10b; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections WHERE id = lid AND superseded_at IS NULL AND status = 'applied') THEN
    RAISE EXCEPTION 'VERIFY S7: the fixture was not undone'; END IF;
  IF position($q$'T12','T9','T10')$q$ in pg_get_functiondef('public.fn_refresh_stop_facts(bigint,timestamp with time zone)'::regprocedure)) = 0 THEN RAISE EXCEPTION 'VERIFY S7: the refresh does not count T9, T10'; END IF;
  IF position($q$('stop_facts_integrity', 'T10',$q$ in pg_get_functiondef('public.log_jobber_sync_health()'::regprocedure)) = 0 THEN RAISE EXCEPTION 'VERIFY S7: the logger does not name T10'; END IF;
  RAISE NOTICE 'S7: T9 and T10 in place, both 0; fixtures T9 [%], T10 1 then 0; old keys equal: %', vid, n - 'T_detail';
END $v$;

COMMIT;
