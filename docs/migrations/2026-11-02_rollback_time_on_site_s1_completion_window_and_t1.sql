-- ROLLBACK of 2026-11-02_1430_time_on_site_s1_completion_window_and_t1.sql (visit durations re-check, stage S1,
-- Trello vpF5PLQj).
--
-- What it does:
--  - puts back the previous view text, exactly as pg_get_viewdef returned it on 2026-11-02;
--  - reverses the two anchored edits.
--
-- Guards:
--  - md5 of the three objects as S1 left them;
--  - each anchor must match exactly once;
--  - VERIFY: all three md5s equal the values read before S1.
--
-- It writes no visit.
-- REHEARSED 2026-11-02 on top of the migration, in one rolled-back transaction (see the migration's REHEARSED lines).

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pin$
BEGIN
  IF md5(pg_get_viewdef('public.v_visit_stop_reference'::regclass, true)) <> '891a668e7e87d0734f9708b5eac8624b' THEN
    RAISE EXCEPTION 'S1 rollback: public.v_visit_stop_reference is not the S1 text';
  END IF;
  IF md5(pg_get_functiondef('public.fn_time_on_site_checks'::regproc)) <> '11e4b8113c609737ea8edd5798faa833' THEN
    RAISE EXCEPTION 'S1 rollback: public.fn_time_on_site_checks is not the S1 body';
  END IF;
  IF md5(pg_get_functiondef('public.log_jobber_sync_health'::regproc)) <> '27b4f78267817a665c866610d907809c' THEN
    RAISE EXCEPTION 'S1 rollback: public.log_jobber_sync_health is not the S1 body';
  END IF;
END $pin$;

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
  IF (length(d) - length(replace(d, b1, ''))) / length(b1) <> 1 THEN RAISE EXCEPTION 'S1 rollback: T1 comment anchor not found exactly once'; END IF;
  IF (length(d) - length(replace(d, b2, ''))) / length(b2) <> 1 THEN RAISE EXCEPTION 'S1 rollback: T1 date anchor not found exactly once'; END IF;
  n := replace(replace(d, b1, a1), b2, a2);
  EXECUTE n;
END $t1$;

DO $h$
DECLARE
  d text := pg_get_functiondef('public.log_jobber_sync_health'::regproc);
  a3 text := $a$'a visit 3 to 10 days old whose time on site is blank or much shorter than its truck stop'$a$;
  b3 text := $b$'a visit 3 or more days old, not settled in the corrections record, whose time on site is blank or much shorter than its truck stop'$b$;
BEGIN
  IF (length(d) - length(replace(d, b3, ''))) / length(b3) <> 1 THEN RAISE EXCEPTION 'S1 rollback: T1 health sentence not found exactly once'; END IF;
  EXECUTE replace(d, b3, a3);
END $h$;

DO $verify$
BEGIN
  IF md5(pg_get_viewdef('public.v_visit_stop_reference'::regclass, true)) <> 'db06f4572dabdba436fb28f46351dd5a'
     OR md5(pg_get_functiondef('public.fn_time_on_site_checks'::regproc)) <> 'bd9ee5c6a27a21271750d76f3cab3c9c'
     OR md5(pg_get_functiondef('public.log_jobber_sync_health'::regproc)) <> '0cbbda81fc1c85d1c8716ef07923b039' THEN
    RAISE EXCEPTION 'S1 rollback VERIFY: the three objects are not back to their 2026-11-02 bodies';
  END IF;
END $verify$;

COMMIT;
