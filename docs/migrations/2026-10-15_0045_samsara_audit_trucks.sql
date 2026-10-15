-- ============================================================================
-- 2026-10-15_0045 Samsara audit: put the truck Samsara shows on 34 completed visits
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-15, on the multi-agent Samsara audit of 1,374 visits ("we use the Visits data to get the date and
--   the client, with that we cross reference in Samsara"): "Go ahead 1, 2". Decision 1 = the non-DERM visits whose
--   truck the old GPS automation overwrote, plus three more; decision 2 = the same on the DERM-filed visits.
-- WHAT THE AUDIT FOUND (samsara-checks/audit_2026-10-15, outside the repos: it names clients)
--   1,251 of 1,374 trucks are right. Of the 36 wrong ones, 22 were written by automation: the 2026-08-19
--   vehicle-gps-reconcile run and the nightly fn_infer_visit_vehicle before 2026-10-14_1610 picked the truck with the
--   LONGEST stay within 150 m, which is not the truck that did the job. For every visit below, Samsara's own trips
--   show the target truck parked at the client's address in the visit window (visit date -4 h to 10 AM next day ET),
--   and in all but one (3935, no tap inside any stop) that stop holds the completion tap.
--   * 10 non-DERM + 12 DERM-filed: the automation replaced the right truck. The removed value (audit.logs) equals the
--     Samsara truck on 20 of 22; on 5750 and 6990 the automation filled a blank, so the Samsara truck is used.
--   * 3921, 6194, 6498, 6613 (DERM): the truck on the visit never went to the address that day.
--   * 5756 (non-DERM): Moises's stop belongs to its sibling 5744; Cloggy holds 5756's tap.
--   * 5749, 5803 (non-DERM) and 3935, 5088, 5743, 5795, 7016 (DERM): no truck was set.
--   * 5735 was checked first (three 053-PV visits on two trucks): Cloggy's 2026-06-03 afternoon stop is the lift
--     station visit 5734 (tapped 20 min after Cloggy left); Moises's overnight stop ending 2026-06-04 06:53, inside
--     5735's window, is followed by 5735's tap at 06:54. So Moises.
-- WHAT CHANGES
--   public.visits.vehicle_id on 34 completed visits, each guarded on the CURRENT value read before writing (a visit
--   someone changed since is skipped and the migration fails). vehicle_id is not in the Jobber push list, so nothing
--   goes to Jobber. Labelled x-app-source samsara-audit with a reason per visit.
--   Times are NOT changed here: the visits are re-measured from Samsara in a separate migration.
-- NOT CHANGED, on purpose
--   1477 and 1509 keep Cloggy (decision 4). 5732, 5814, 7299, 7319, 3920, 7828, 1419 are flagged for a person, not
--   changed (decisions 5 and 6).
-- CONSEQUENCE
--   derm.v_lwt_monthly_rows reads vehicle_id, so the 21 DERM-filed visits now report the Samsara truck (and its decal).
-- ROLLBACK: audit.logs.old_row for these visits (app_source samsara-audit).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $s$
DECLARE
  v_hdr text := current_setting('request.headers', true);
  r record;
  n int;
  v_total int := 0;
  v_new bigint;
  v_reason text;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      -- id, truck on the visit now (NULL = none), Samsara truck, kind
      (1418, 2, 'David',  'revert'), (1420, 2, 'Moises', 'revert'), (5750, 1, 'Cloggy', 'revert'),
      (5776, 1, 'Cloggy', 'revert'), (6708, 1, 'Cloggy', 'revert'), (6990, 1, 'Cloggy', 'revert'),
      (7058, 1, 'Cloggy', 'revert'), (7065, 1, 'Cloggy', 'revert'), (7300, 3, 'Cloggy', 'revert'),
      (7674, 1, 'Cloggy', 'revert'),
      (1280, 2, 'David',  'revert'), (1373, 2, 'David',  'revert'), (1588, 2, 'Moises', 'revert'),
      (1785, 2, 'Moises', 'revert'), (4787, 2, 'Moises', 'revert'), (4994, 2, 'Moises', 'revert'),
      (5735, 2, 'Moises', 'revert'), (5745, 2, 'Moises', 'revert'), (5840, 2, 'Moises', 'revert'),
      (6222, 3, 'Moises', 'revert'), (6737, 2, 'Moises', 'revert'), (8743, 3, 'Moises', 'revert'),
      (3921, 1, 'Cloggy', 'absent'), (6194, 3, 'Cloggy', 'absent'), (6498, 3, 'Moises', 'absent'),
      (6613, 3, 'Moises', 'absent'),
      (5756, 1, 'Cloggy', 'sibling'),
      (5749, NULL, 'Cloggy', 'blank'), (5803, NULL, 'Cloggy', 'blank'),
      (3935, NULL, 'David',  'blank'), (5088, NULL, 'Moises', 'blank'), (5743, NULL, 'Moises', 'blank'),
      (5795, NULL, 'Cloggy', 'blank'), (7016, NULL, 'Moises', 'blank')
    ) AS t(id, cur, truck, kind)
  LOOP
    SELECT id INTO STRICT v_new FROM public.vehicles WHERE name = r.truck;
    v_reason := 'Samsara audit 2026-10-15 (Fred: "Go ahead 1, 2"): ' || CASE r.kind
      WHEN 'revert'  THEN 'Samsara shows ' || r.truck || ' parked at the address holding the completion; the old GPS automation had replaced it with the truck that stayed longest.'
      WHEN 'absent'  THEN 'the truck on the visit never went to the address that day; Samsara shows ' || r.truck || ' parked there holding the completion.'
      WHEN 'sibling' THEN 'Moises''s stop belongs to the sibling visit 5744; Samsara shows ' || r.truck || ' parked at the address holding this completion.'
      ELSE 'no truck was set; Samsara shows ' || r.truck || ' parked at the address in the visit window.'
    END;
    PERFORM set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
      || jsonb_build_object('x-app-source', 'samsara-audit', 'x-change-reason', v_reason))::text, true);
    UPDATE public.visits
       SET vehicle_id = v_new
     WHERE id = r.id AND visit_status = 'completed' AND deleted_at IS NULL
       AND vehicle_id IS NOT DISTINCT FROM r.cur;
    GET DIAGNOSTICS n = row_count;
    IF n <> 1 THEN RAISE EXCEPTION 'visit % not updated (truck changed since the audit?)', r.id; END IF;
    v_total := v_total + n;
  END LOOP;
  PERFORM set_config('request.headers', coalesce(v_hdr, ''), true);
  IF v_total <> 34 THEN RAISE EXCEPTION 'expected 34 visits, got %', v_total; END IF;
END $s$;

DO $v$
DECLARE r jsonb; n int;
BEGIN
  -- every visit now carries its Samsara truck
  SELECT count(*) INTO n
    FROM (VALUES (1418,'David'),(1420,'Moises'),(5750,'Cloggy'),(5776,'Cloggy'),(6708,'Cloggy'),(6990,'Cloggy'),
                 (7058,'Cloggy'),(7065,'Cloggy'),(7300,'Cloggy'),(7674,'Cloggy'),(1280,'David'),(1373,'David'),
                 (1588,'Moises'),(1785,'Moises'),(4787,'Moises'),(4994,'Moises'),(5735,'Moises'),(5745,'Moises'),
                 (5840,'Moises'),(6222,'Moises'),(6737,'Moises'),(8743,'Moises'),(3921,'Cloggy'),(6194,'Cloggy'),
                 (6498,'Moises'),(6613,'Moises'),(5756,'Cloggy'),(5749,'Cloggy'),(5803,'Cloggy'),(3935,'David'),
                 (5088,'Moises'),(5743,'Moises'),(5795,'Cloggy'),(7016,'Moises')) t(id, truck)
    JOIN public.visits v ON v.id = t.id
    JOIN public.vehicles ve ON ve.id = v.vehicle_id AND ve.name = t.truck;
  IF n <> 34 THEN RAISE EXCEPTION 'VERIFY: % of 34 visits carry their Samsara truck', n; END IF;
  -- each write is labelled
  SELECT count(DISTINCT (record_pk->>'id')) INTO n FROM audit.logs
   WHERE table_name = 'visits' AND app_source = 'samsara-audit' AND changed_at >= now() - interval '5 minutes'
     AND request_context->>'change_reason' IS NOT NULL;
  IF n <> 34 THEN RAISE EXCEPTION 'VERIFY: % of 34 audit rows labelled', n; END IF;
  -- the untouched decisions stay untouched
  IF (SELECT count(*) FROM public.visits WHERE id IN (1477, 1509) AND vehicle_id = 2) <> 2 THEN
    RAISE EXCEPTION 'VERIFY: 1477/1509 lost Cloggy'; END IF;
  r := public.fn_time_on_site_checks();
  IF (r->>'T1')::int + (r->>'T3')::int + (r->>'T4')::int + (r->>'T6')::int <> 0 THEN RAISE EXCEPTION 'VERIFY: checks %', r; END IF;
END $v$;

COMMIT;
