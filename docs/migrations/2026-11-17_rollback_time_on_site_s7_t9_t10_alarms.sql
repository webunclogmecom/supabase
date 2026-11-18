-- ============================================================================
-- 2026-11-17_rollback_time_on_site_s7_t9_t10_alarms  Undo 2026-11-17_2230_time_on_site_s7_t9_t10_alarms
-- ============================================================================
-- Reverses the three anchored edits on the live bodies and proves the result is byte for byte the body before S7:
-- fn_time_on_site_checks 03d6d444ec2f782418ab28c575e149b7, fn_refresh_stop_facts b2f9708304e9d93ad7d997c508758977,
-- log_jobber_sync_health b728dbc3144a64097fa2f782a1043e04. Refuses alone (the S7 md5s are pinned first). Grants are kept
-- by CREATE OR REPLACE and checked. Run it BEFORE any older time-on-site rollback that pins fn_time_on_site_checks.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pin$ BEGIN
  IF md5(pg_get_functiondef('public.fn_time_on_site_checks()'::regprocedure)) <> '76b6d76ce9a0e646708cdff5e508010d' THEN
    RAISE EXCEPTION 'rollback S7: fn_time_on_site_checks is not the S7 body (applied?)'; END IF;
  IF md5(pg_get_functiondef('public.fn_refresh_stop_facts(bigint,timestamp with time zone)'::regprocedure)) <> '3ade76bd16efccd7df3ed44df302ff75' THEN
    RAISE EXCEPTION 'rollback S7: fn_refresh_stop_facts is not the S7 body'; END IF;
  IF md5(pg_get_functiondef('public.log_jobber_sync_health()'::regprocedure)) <> 'd96377d76ed20aa1da1055a60fc0b92a' THEN
    RAISE EXCEPTION 'rollback S7: log_jobber_sync_health is not the S7 body'; END IF;
END $pin$;

CREATE FUNCTION pg_temp.rep1(body text, old text, new text, what text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE n int := (length(body) - length(replace(body, old, ''))) / greatest(length(old), 1);
BEGIN
  IF n <> 1 THEN RAISE EXCEPTION 'rollback S7: anchor % found % times, expected 1', what, n; END IF;
  RETURN replace(body, old, new);
END $f$;

DO $c$ DECLARE b text := pg_get_functiondef('public.fn_time_on_site_checks()'::regprocedure); BEGIN
  b := pg_temp.rep1(b, $a$-- over every settled row, any date.
-- 2026-11-17 (Trello vpF5PLQj, re-check S7; Fred: "i want that to be completed"): T9, a visit the nightly never closed
-- into the ledger; T10, a visit waiting on a person more than 8 days. T11 (a monthly sample) is not built (Fred, Q-M).
$a$, $a$-- over every settled row, any date.
$a$, 'header');
  b := pg_temp.rep1(b, $a$  t7 bigint[]; t8 bigint[]; t12 bigint[]; t9 bigint[]; t10 bigint[];
$a$, $a$  t7 bigint[]; t8 bigint[]; t12 bigint[];
$a$, 'declare');
  b := pg_temp.rep1(b, $a$  -- T9 a completed 2026 client visit dated 11 or more days ago (past the nightly's last look and its day-10 close-out)
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
  RETURN jsonb_build_object('T1', coalesce(cardinality(t1), 0),$a$, $a$  RETURN jsonb_build_object('T1', coalesce(cardinality(t1), 0),$a$, 'return');
  b := pg_temp.rep1(b, $a$'T12', coalesce(cardinality(t12), 0),
    'T9', coalesce(cardinality(t9), 0), 'T10', coalesce(cardinality(t10), 0),$a$, $a$'T12', coalesce(cardinality(t12), 0),$a$, 'counts');
  b := pg_temp.rep1(b, $a$'T8', t8, 'T12', t12, 'T9', t9, 'T10', t10));$a$, $a$'T8', t8, 'T12', t12));$a$, 'detail');
  EXECUTE b;
END $c$;

DO $r$ DECLARE b text := pg_get_functiondef('public.fn_refresh_stop_facts(bigint,timestamp with time zone)'::regprocedure); BEGIN
  b := pg_temp.rep1(b, $a$     -- 2026-11-17 (re-check S7): T9 (a visit never closed into the ledger) and T10 (waiting on a person > 8 days) too
     where x.key in ('Z1','Z2','Z3','Z4','Z7','Z8','Z9','T1','T2','T3','T4','T5','T6','T7','T8','T12','T9','T10') and (x.value)::text::int > 0;$a$,
  $a$     where x.key in ('Z1','Z2','Z3','Z4','Z7','Z8','Z9','T1','T2','T3','T4','T5','T6','T7','T8','T12') and (x.value)::text::int > 0;$a$, 'keys');
  EXECUTE b;
END $r$;

DO $h$ DECLARE b text := pg_get_functiondef('public.log_jobber_sync_health()'::regprocedure); BEGIN
  b := pg_temp.rep1(b, $a$               ('stop_facts_integrity', 'T9', 'a finished client visit 11 or more days old that the nightly time on site check never closed (it has no settled or held row): run the close-out for its date or settle it on the person page'),
               ('stop_facts_integrity', 'T10', 'a time on site the nightly check held for a person more than 8 days ago that nobody has answered: it waits on the person page'),
$a$, '', 'sentences');
  EXECUTE b;
END $h$;

DO $v$ BEGIN
  IF md5(pg_get_functiondef('public.fn_time_on_site_checks()'::regprocedure)) <> '03d6d444ec2f782418ab28c575e149b7' THEN RAISE EXCEPTION 'VERIFY rollback S7: checks body not restored'; END IF;
  IF md5(pg_get_functiondef('public.fn_refresh_stop_facts(bigint,timestamp with time zone)'::regprocedure)) <> 'b2f9708304e9d93ad7d997c508758977' THEN RAISE EXCEPTION 'VERIFY rollback S7: refresh body not restored'; END IF;
  IF md5(pg_get_functiondef('public.log_jobber_sync_health()'::regprocedure)) <> 'b728dbc3144a64097fa2f782a1043e04' THEN RAISE EXCEPTION 'VERIFY rollback S7: health body not restored'; END IF;
  IF (SELECT proacl::text FROM pg_proc WHERE oid = 'public.fn_time_on_site_checks()'::regprocedure) IS DISTINCT FROM '{postgres=X/postgres,service_role=X/postgres}'
     OR (SELECT proacl::text FROM pg_proc WHERE oid = 'public.fn_refresh_stop_facts(bigint,timestamp with time zone)'::regprocedure) IS DISTINCT FROM '{postgres=X/postgres}'
     OR (SELECT proacl::text FROM pg_proc WHERE oid = 'public.log_jobber_sync_health()'::regprocedure) IS DISTINCT FROM '{postgres=X/postgres,service_role=X/postgres}' THEN
    RAISE EXCEPTION 'VERIFY rollback S7: grants moved'; END IF;
END $v$;
COMMIT;
