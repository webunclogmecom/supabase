-- 2026-11-02_1430 · Visit durations re-check, stage S1 (Trello vpF5PLQj)
--
-- THE ASK. The card (the Oct 13 call with Yan): "find the error patterns, then backfill every affected visit".
-- Fred approved the whole re-check plan on 2026-10-27 ("Approve the whole plan") and gave S1 its go on 2026-11-02
-- ("Go today"). S1 is the stage that makes two of the patterns the re-check found visible, before any time is
-- rewritten. It is RC3 and the T1 part of RC4 in the plan.
--
-- WHAT CHANGES
--  1. public.v_visit_stop_reference (RC3). A completion stop counts only when it ARRIVES inside the visit window.
--     The window runs from 4 h before the visit date (00:00 ET) to 10:00 ET the next day. It is the same test
--     public.fn_time_on_site_samsara_candidates has applied since 2026-10-15_0210.
--     Why: visit 8854 (dated 10-16, completed in the office on 10-19) took a 59-min stop of 10-19 as its completion
--     stop, and 8018 and 8053 each took a stop of a later day.
--     Effect today, predicted and checked below:
--       - exactly those 3 rows leave the view;
--       - 8022 and 8853, which shared those stops, go from sharing 2 to 1;
--       - the dump rows of the view are untouched.
--  2. public.fn_time_on_site_checks, T1 (RC4). Anchored edit of the live body:
--       - no upper age: the alarm stopped looking at a visit after 10 days, so a visit the nightly never fixed
--         simply dropped out of it;
--       - a visit with a current applied or proposed row in public.visit_time_on_site_corrections is exempt,
--         because it is settled (Fred, Q-E, 2026-11-02).
--     The new T1 lists nothing today. It used to list 8854, which the RC3 change removes.
--  3. public.log_jobber_sync_health: the T1 sentence of the health email now says the same. One anchored string.
--
-- WHAT DOES NOT CHANGE
--  - No visit is written.
--  - The view keeps its columns, owner and grants (postgres, service_role and db_backup_reader only).
--  - No view depends on it (pg_depend). Its readers are four time-on-site functions:
--      - fn_time_on_site_checks;
--      - fn_time_on_site_samsara_candidates: already windowed, so its output does not move;
--      - fn_fill_time_on_site_from_stops: fills only a visit whose source is NULL; 0 candidates before and after;
--      - fn_time_on_site_audit.
--  - No edge function or script reads the view. The tank views do not read it.
--  - public.fn_refresh_stop_facts already counts T1, so nothing changes there.
--
-- GUARDS
--  - The md5 of the three live objects matches the value read on 2026-11-02.
--  - Each anchor matches exactly once.
--  - The re-read body equals the edited text.
--  - lock_timeout 3s.
-- VERIFY (inside)
--  - The rows that leave the view and the sharing changes equal the prediction.
--  - The view's ACL is unchanged.
--  - T1 = 0 and T2 = 0 after.
--  - The old T1 sentence is gone and the new one appears once.
-- REHEARSED 2026-11-02, every run rolled back (local runner samsara-checks/.../S1/rehearse.mjs):
--  (a) As written, with COMMIT swapped for ROLLBACK: passes.
--  (b) Fixture: real visit 5886 (12 to 60 days old, applied ledger row) was blanked and its ledger rows superseded
--      inside the transaction.
--        - The new T1 lists [5886].
--        - The OLD T1, kept as a pg_temp copy (the control), lists nothing.
--        - With one ledger row current again, the new T1 lists nothing.
--        - 8854 has 0 completion rows in the view, and the health sentence is the new one.
--  (c) One PIN md5 altered: the file raises "changed since 2026-11-02".
--  Rollback on top of the migration, in one rolled-back transaction: all three md5s return to their 2026-11-02 values.
--  The view text round-trips exactly.
-- ROLLBACK: 2026-11-02_rollback_time_on_site_s1_completion_window_and_t1.sql
--  - restores the previous view text, taken from pg_get_viewdef;
--  - reverses both anchored edits;
--  - is md5-guarded on the new bodies.

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pin$
BEGIN
  IF md5(pg_get_viewdef('public.v_visit_stop_reference'::regclass, true)) <> 'db06f4572dabdba436fb28f46351dd5a' THEN
    RAISE EXCEPTION 'S1: public.v_visit_stop_reference changed since 2026-11-02 (md5 %)', md5(pg_get_viewdef('public.v_visit_stop_reference'::regclass, true));
  END IF;
  IF md5(pg_get_functiondef('public.fn_time_on_site_checks'::regproc)) <> 'bd9ee5c6a27a21271750d76f3cab3c9c' THEN
    RAISE EXCEPTION 'S1: public.fn_time_on_site_checks changed since 2026-11-02';
  END IF;
  IF md5(pg_get_functiondef('public.log_jobber_sync_health'::regproc)) <> '0cbbda81fc1c85d1c8716ef07923b039' THEN
    RAISE EXCEPTION 'S1: public.log_jobber_sync_health changed since 2026-11-02';
  END IF;
END $pin$;

CREATE TEMP TABLE s1_before ON COMMIT DROP AS
  SELECT visit_id, stop_id, vehicle_id, arrival, departure, basis, sharing, split_ok FROM public.v_visit_stop_reference;
CREATE TEMP TABLE s1_acl ON COMMIT DROP AS
  SELECT relacl::text AS acl FROM pg_class WHERE oid = 'public.v_visit_stop_reference'::regclass;

-- 1. RC3: the completion stop must arrive inside the visit window (the two lines marked S1 are the only change)
CREATE OR REPLACE VIEW public.v_visit_stop_reference AS
 WITH a AS (
         SELECT l.visit_id,
            s.id AS stop_id,
            s.vehicle_id,
            s.arrived_at,
            s.departed_at,
            v.completed_at,
            ( SELECT min(s2.arrived_at) AS min
                   FROM visit_vehicle_stops l2
                     JOIN vehicle_stops s2 ON s2.id = l2.vehicle_stop_id AND s2.superseded_at IS NULL
                  WHERE l2.visit_id = l.visit_id AND l2.deleted_at IS NULL AND l2.match_basis = 'completion_chain'::text) AS chain_arrived
           FROM visit_vehicle_stops l
             JOIN vehicle_stops s ON s.id = l.vehicle_stop_id AND s.superseded_at IS NULL
             JOIN visits v ON v.id = l.visit_id
          WHERE l.deleted_at IS NULL AND l.match_basis = 'completion'::text
            AND s.arrived_at >= ((v.visit_date::timestamp without time zone AT TIME ZONE 'America/New_York'::text) - '04:00:00'::interval)   -- S1
            AND s.arrived_at < (((v.visit_date + 1) + '10:00:00'::time without time zone) AT TIME ZONE 'America/New_York'::text)          -- S1
        )
 SELECT a.visit_id,
    a.stop_id,
    a.vehicle_id,
    LEAST(a.arrived_at, COALESCE(a.chain_arrived, a.arrived_at)) AS arrival,
    a.departed_at AS departure,
    'completion'::text AS basis,
    count(*) OVER (PARTITION BY a.stop_id)::integer AS sharing,
    true AS split_ok
   FROM a
UNION ALL
 SELECT l.visit_id,
    min(l.vehicle_stop_id) AS stop_id,
    min(s.vehicle_id) AS vehicle_id,
    min(s.arrived_at) AS arrival,
    max(s.departed_at) AS departure,
    min(l.match_basis) AS basis,
    1 AS sharing,
    true AS split_ok
   FROM visit_vehicle_stops l
     JOIN vehicle_stops s ON s.id = l.vehicle_stop_id AND s.superseded_at IS NULL
  WHERE l.deleted_at IS NULL
  GROUP BY l.visit_id
 HAVING count(*) = 1 AND bool_and(l.match_basis = ANY (ARRAY['dump_completion'::text, 'dump_window'::text]));

-- 2. RC4: T1 has no upper age and skips a settled visit (anchored edit of the live body)
DO $t1$
DECLARE
  d text := pg_get_functiondef('public.fn_time_on_site_checks'::regproc);
  n text;
  a1 text := $a$  -- T1 a client visit from 3 to 10 days ago (the nightly fill has run) whose truck stop holds the completion, but its
  --    time is blank or under 70% of the stop and at least 5 min shorter
$a$;
  b1 text := $b$  -- T1 a client visit 3 or more days old (the nightly fill has run) whose truck stop holds the completion, but its
  --    time is blank or under 70% of the stop and at least 5 min shorter. 2026-11-02_1430 (re-check S1, RC4): no upper
  --    age (a visit the nightly never fixed used to drop out after 10 days), and a visit with a current applied or
  --    proposed row in public.visit_time_on_site_corrections is exempt (settled; Fred's Q-E)
$b$;
  a2 text := $a$     AND v.visit_date BETWEEN v_today - 10 AND v_today - 3
$a$;
  b2 text := $b$     AND v.visit_date <= v_today - 3
     AND NOT EXISTS (SELECT 1 FROM public.visit_time_on_site_corrections c
                      WHERE c.visit_id = v.id AND c.superseded_at IS NULL AND c.status IN ('applied', 'proposed'))
$b$;
BEGIN
  IF (length(d) - length(replace(d, a1, ''))) / length(a1) <> 1 THEN RAISE EXCEPTION 'S1: T1 comment anchor not found exactly once'; END IF;
  IF (length(d) - length(replace(d, a2, ''))) / length(a2) <> 1 THEN RAISE EXCEPTION 'S1: T1 date anchor not found exactly once'; END IF;
  n := replace(replace(d, a1, b1), a2, b2);
  EXECUTE n;
  IF pg_get_functiondef('public.fn_time_on_site_checks'::regproc) <> n THEN RAISE EXCEPTION 'S1: fn_time_on_site_checks re-read differs from the edited text'; END IF;
END $t1$;

-- 3. The T1 sentence of the health email (anchored edit of the live body)
DO $h$
DECLARE
  d text := pg_get_functiondef('public.log_jobber_sync_health'::regproc);
  n text;
  a3 text := $a$'a visit 3 to 10 days old whose time on site is blank or much shorter than its truck stop'$a$;
  b3 text := $b$'a visit 3 or more days old, not settled in the corrections record, whose time on site is blank or much shorter than its truck stop'$b$;
BEGIN
  IF (length(d) - length(replace(d, a3, ''))) / length(a3) <> 1 THEN RAISE EXCEPTION 'S1: T1 health sentence not found exactly once'; END IF;
  n := replace(d, a3, b3);
  EXECUTE n;
  IF pg_get_functiondef('public.log_jobber_sync_health'::regproc) <> n THEN RAISE EXCEPTION 'S1: log_jobber_sync_health re-read differs from the edited text'; END IF;
END $h$;

-- VERIFY
DO $verify$
DECLARE
  v_gone text; v_new text; c jsonb;
BEGIN
  SELECT string_agg(format('%s/%s/%s', visit_id, stop_id, sharing), ' ' ORDER BY visit_id) INTO v_gone
    FROM (SELECT visit_id, stop_id, vehicle_id, arrival, departure, basis, sharing, split_ok FROM s1_before
          EXCEPT SELECT visit_id, stop_id, vehicle_id, arrival, departure, basis, sharing, split_ok FROM public.v_visit_stop_reference) x;
  SELECT string_agg(format('%s/%s/%s', visit_id, stop_id, sharing), ' ' ORDER BY visit_id) INTO v_new
    FROM (SELECT visit_id, stop_id, vehicle_id, arrival, departure, basis, sharing, split_ok FROM public.v_visit_stop_reference
          EXCEPT SELECT visit_id, stop_id, vehicle_id, arrival, departure, basis, sharing, split_ok FROM s1_before) x;
  IF v_gone IS DISTINCT FROM '8018/1004/2 8022/1004/2 8053/1406/1 8853/1833/2 8854/1833/2' THEN
    RAISE EXCEPTION 'S1 VERIFY: rows that left the view = %, predicted 8018/1004/2 8022/1004/2 8053/1406/1 8853/1833/2 8854/1833/2', v_gone;
  END IF;
  IF v_new IS DISTINCT FROM '8022/1004/1 8853/1833/1' THEN
    RAISE EXCEPTION 'S1 VERIFY: rows that changed in the view = %, predicted 8022/1004/1 8853/1833/1', v_new;
  END IF;
  IF (SELECT relacl::text FROM pg_class WHERE oid = 'public.v_visit_stop_reference'::regclass) IS DISTINCT FROM (SELECT acl FROM s1_acl) THEN
    RAISE EXCEPTION 'S1 VERIFY: the view''s grants changed';
  END IF;
  c := public.fn_time_on_site_checks();
  IF (c->>'T1')::int <> 0 OR (c->>'T2')::int <> 0 THEN RAISE EXCEPTION 'S1 VERIFY: T1 = %, T2 = % (both predicted 0)', c->>'T1', c->>'T2'; END IF;
  IF position('3 to 10 days old' in pg_get_functiondef('public.log_jobber_sync_health'::regproc)) > 0
     OR position('not settled in the corrections record' in pg_get_functiondef('public.log_jobber_sync_health'::regproc)) = 0 THEN
    RAISE EXCEPTION 'S1 VERIFY: the T1 health sentence is not the new one';
  END IF;
END $verify$;

COMMIT;
