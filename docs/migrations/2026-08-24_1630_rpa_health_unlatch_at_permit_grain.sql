-- 2026-08-24_1630_rpa_health_unlatch_at_permit_grain.sql
-- ---------------------------------------------------------------------------
-- Let the rpa-derm-health alarm CLEAR when the problem is fixed, without letting it
-- go quiet while a report is still unfiled.
--
-- THE DEFECT. public.v_rpa_derm_health computes:
--     visits_ge3_attempts = count of visits with >= 3 non-dry-run submissions
-- all time, with NO condition that the visit is still unfiled. Once a visit reaches 3
-- attempts this is permanently >= 1, so log_rpa_derm_health() sets status 'attention'
-- forever even after the report is successfully filed. Measured: the value has taken
-- exactly two values ever (0 and 1) across 36 health rows, and has been 1 for the
-- 10 consecutive attention days since 2026-08-15. The payload has been byte-identical
-- for 10 days because it is a latch, not a signal.
--
-- 🛑 AND THE OBVIOUS FIX SILENTLY HIDES A LIVE COMPLIANCE GAP. DO NOT DO IT.
--   "Only count visits with no SUCCESS" looks right and is wrong, because a visit can
--   carry MORE THAN ONE PERMIT and the grain of the fix must match the grain of the
--   work. Measured on the live data before applying:
--       current  (all-time, by visit_id)            -> 1   (latched)
--       unresolved, grouped by visit_id             -> 0   ⚠ FALSE ALL-CLEAR
--       unresolved, grouped by (visit_id, gdo_id)   -> 1   correct
--   Visit 6617 (043-MIL, Mila) has two permits on one manifest:
--       gdo_id 156 / GDO-14117  SUCCESS            2026-08-07 11:52 ET
--       gdo_id 230 / GDO-11024  ERROR_LOGIN_FAILED 2026-08-11, 08-14, 08-18, 08-19 ET
--                               "Either the Password or GDO Permit # is incorrect",
--                               retryable=false on every attempt.
--   Grouping by visit_id sees the 14117 SUCCESS and declares the visit resolved, which
--   would take the alarm to 'ok' while GDO-11024 is still unfiled with the county.
--   A reused gate carries its OLD grain; the filing unit here is (visit, permit).
--
-- THE FIX: group by (visit_id, gdo_id) and require that the pair has NO SUCCESS.
--   * The alarm keeps firing today, because 6617/230 is genuinely unfiled.
--   * It clears the moment that permit is filed, by the bot or by a manual record.
--   * A second permit failing on an already-successful visit is now VISIBLE, where
--     before it was masked by its sibling's success.
--
-- ⚠ NOT CHANGED, on purpose: store_failed_total is also all-time and would latch the
--   same way once it ever became non-zero (it is 0 today). Left alone because "evidence
--   was lost" is arguably a permanent fact rather than a clearing condition, and
--   deciding that needs someone who knows what the evidence is for. Flagged, not fixed.
--
-- ⚠ ALSO NOT FIXED HERE, and it is the bigger gap: THE CHECK CANNOT SEE A DEAD BOT
--   DURING A QUIET PERIOD. The only liveness reason, 'no_recent_attempts', is gated on
--   queue_depth > 0. Measured: queue_depth has been 0 in all 36 health rows ever
--   written, max ever 0, so that branch has never once been exercised. It is not dead
--   code -- if the bot died AND new work arrived, queue_depth would rise and it would
--   fire -- but a death during a quiet spell is invisible until work appears. Worse,
--   rpa-derm-queue writes a lease only when it actually hands out work, so an empty
--   poll leaves no trace anywhere: "polling hourly and finding nothing" and "container
--   dead since 2026-08-19" are IDENTICAL in our data. A heartbeat is the fix and it
--   belongs on the bot side, which is John's. Recorded for Fred as a separate decision.
--
-- WHAT IS ACTUALLY WRONG RIGHT NOW, so this migration is not mistaken for the fix:
--   ONE Miami-Dade DERM report is unfiled. Visit 6617, client 043-MIL (Mila), permit
--   GDO-11024, service date 2026-08-04, dump ticket 832194. The portal rejects the
--   credential for that permit while the SAME client's GDO-14117 authenticates fine,
--   so it is a credential/registration problem on 11024, not a bot fault. It needs a
--   human to file it and John to resolve the credential. See the triage in
--   docs/audits/2026-08-24_health_alarm_triage.md.
--
-- Audit (Rule 8): one view body. No table, column, or grant on any audited table
-- changes; audit.logs untouched and no audit opt-in list changes.
--
-- Grants: CREATE OR REPLACE VIEW preserves existing grants. Verified after applying.
--
-- @Building Apps. Claimed in WORKING-NOW.md. No Lovable project touched.

BEGIN;

CREATE OR REPLACE VIEW public.v_rpa_derm_health AS
SELECT
  (SELECT count(*) FROM public.v_derm_portal_queue)                       AS queue_depth,
  (SELECT max(s.created_at) FROM public.derm_portal_submissions s
    WHERE NOT s.dry_run)                                                  AS last_real_attempt,
  (SELECT count(*) FROM public.derm_portal_submissions s
    WHERE NOT s.dry_run AND s.status = 'SUCCESS'
      AND s.created_at > now() - interval '24 hours')                     AS success_24h,
  -- all-time on purpose: lost evidence does not un-lose itself. See the header note.
  (SELECT count(*) FROM public.derm_portal_submissions s
    WHERE NOT s.dry_run AND s.screenshot_missing_reason = 'STORE_FAILED') AS store_failed_total,
  -- 🛑 GRAIN IS (visit_id, gdo_id), NOT visit_id. A visit can carry several permits and
  --    one succeeding does not file the others. Grouping by visit_id alone returns 0
  --    today while GDO-11024 on visit 6617 is still unfiled. Verified before shipping.
  (SELECT count(*) FROM (
      SELECT s.visit_id, s.gdo_id
      FROM public.derm_portal_submissions s
      WHERE NOT s.dry_run
      GROUP BY s.visit_id, s.gdo_id
      HAVING count(*) >= 3
         AND count(*) FILTER (WHERE s.status = 'SUCCESS') = 0
   ) q)                                                                   AS visits_ge3_attempts,
  (SELECT count(*) FROM public.v_gdo_reporting_derm_mismatch)             AS gdo_not_derm_required;

COMMENT ON VIEW public.v_rpa_derm_health IS
  'Health inputs for log_rpa_derm_health(). visits_ge3_attempts is grouped by (visit_id, gdo_id) and requires NO SUCCESS on that pair, so the alarm CLEARS when the report is filed. ⚠ Grouping by visit_id alone produces a FALSE ALL-CLEAR: visit 6617 has GDO-14117 filed and GDO-11024 unfiled, and the visit-grain version returns 0. ⚠ queue_depth has been 0 in all 36 health rows ever, so the no_recent_attempts liveness branch has never been exercised; a bot death during a quiet period is invisible until new work arrives. Updated 2026-08-24.';

COMMIT;

-- VERIFY (run after applying; every assertion must hold)
--
-- 1. THE ALARM STILL FIRES, because the problem is real and unfixed.
--    select visits_ge3_attempts from public.v_rpa_derm_health;
--    -- expect 1  (visit 6617 / gdo_id 230, GDO-11024)
--    ⚠ If this is 0, the grain regressed to visit_id and a live compliance gap just
--      went silent. That is the failure this migration exists to prevent.
--
-- 2. MUTATION TEST, and it is the whole point. The two grains must DISAGREE on the
--    current data, or the test proves nothing about which one shipped:
--    select
--      (select count(*) from (select visit_id from public.derm_portal_submissions
--         where not dry_run group by visit_id
--         having count(*)>=3 and count(*) filter (where status='SUCCESS')=0) a) as by_visit,
--      (select count(*) from (select visit_id, gdo_id from public.derm_portal_submissions
--         where not dry_run group by visit_id, gdo_id
--         having count(*)>=3 and count(*) filter (where status='SUCCESS')=0) b) as by_permit;
--    -- expect by_visit = 0, by_permit = 1. If they are equal, this control is blind
--    -- and cannot tell a correct view from a regressed one - find another case first.
--
-- 3. the alarm can still reach 'ok' (it is not latched any more). Prove it by the
--    definition rather than by waiting: the pair clears when a SUCCESS lands.
--    select s.visit_id, s.gdo_id, count(*) attempts,
--           count(*) filter (where s.status='SUCCESS') successes
--      from public.derm_portal_submissions s where not s.dry_run
--     group by 1,2 having count(*) >= 3 order by 1,2;
--    -- expect exactly one row, (6617, 230), with successes = 0
--
-- 4. grants survived CREATE OR REPLACE
--    select grantee, privilege_type from information_schema.role_table_grants
--     where table_schema='public' and table_name='v_rpa_derm_health' order by 1;
--    -- expect whatever it had before; specifically NOT anon
--
-- 5. the health function still runs and now reports the same single reason
--    select public.log_rpa_derm_health();
--    select status, details->'reasons' from public.sync_log
--     where sync_source='rpa-derm-health' order by started_at desc limit 1;
--    -- expect 'attention' and [{"kind":"retry_loop_visits","count":1}]
