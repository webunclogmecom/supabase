-- 2026-07-07_hide_dump_sites_from_derm.sql
-- ============================================================================
-- WHY: 000-DH (Homestead Dump, client_id 365) and 000-DP (DUMP Pompano,
--      client_id 76) are DISPOSAL DESTINATIONS masquerading as clients — their
--      "visits" are the truck offloading grease AT the dump, not a service that
--      needs a DERM manifest. They cluttered the DERM Tracker app and (via NULL
--      derm_required → COALESCE(...,true)) showed as needing docs.
--      Fred-authorized (2026-07-07). Two effects:
--        1. HIDE them from the DERM app's visit lists.
--        2. Mark all their visits DERM-not-required + locked (never re-promote).
--
-- SCOPE: DERM-app-only. The dump visits stay visible in the Calendar / Admin
--        Review (legit GPS/review context) — this only touches the two views the
--        DERM Tracker reads, plus the derm_required flag on those 20 visits.
--
-- 3NF / integrity: no schema change; a data UPDATE (derm_required flag) + two
--   CREATE OR REPLACE VIEWs that WRAP the prior definition with a client filter.
--   0 of the 20 dump visits were manifest-linked (confirmed) — nothing orphaned.
--   Backup of the prior view defs + per-visit derm_required state:
--   backups/2026-07-07_hide_dump_sites_backup.json.
-- ============================================================================

-- 1) Mark every 000-DH / 000-DP visit DERM-not-required + locked.
--    (5 were NULL → would have shown as "needs manifest"; the lock stops the
--     nightly rederive cron from ever re-promoting a dump visit. The lock
--     trigger does NOT revert this — the rows were unlocked/NULL, verified.)
UPDATE public.visits v
SET derm_required = false, derm_required_locked = true
FROM public.clients c
WHERE c.id = v.client_id
  AND c.client_code IN ('000-DH','000-DP')
  AND (v.derm_required IS DISTINCT FROM false OR v.derm_required_locked IS DISTINCT FROM true);

-- 2) Hide dump sites from the DERM app's visit lists by wrapping the two views
--    the app reads with a client-exclusion filter. Both views expose client_id,
--    so we wrap the *prior* definition (preserved verbatim; CREATE OR REPLACE
--    keeps grants + column order) rather than editing the inner query.
--
--    APPLIED FORM (the "<PRIOR DEF>" is the live pg_get_viewdef at apply time,
--    captured in the backup json above):
--
--    CREATE OR REPLACE VIEW derm.visits AS
--      SELECT * FROM ( <PRIOR derm.visits DEF> ) _dv
--      WHERE _dv.client_id NOT IN
--        (SELECT id FROM public.clients WHERE client_code IN ('000-DH','000-DP'));
--
--    CREATE OR REPLACE VIEW public.manifest_pickable_visits AS
--      SELECT * FROM ( <PRIOR manifest_pickable_visits DEF> ) _pv
--      WHERE _pv.client_id NOT IN
--        (SELECT id FROM public.clients WHERE client_code IN ('000-DH','000-DP'));
--
--    (Subquery-by-code is self-documenting + survives a client_id change; add a
--     new dump-site code to that IN-list to hide it too.)

-- ============================================================================
-- VERIFICATION (rolled-back test + live, 2026-07-07):
--   * All 20 dump visits → derm_required=false + derm_required_locked=true.
--   * derm.visits dump rows 16 → 0 (total 799 → 783; exactly the 16 dump
--     completed visits removed, no collateral — 035-LG unchanged at 10).
--   * public.manifest_pickable_visits dump rows 1 → 0 (total 8 → 7).
--   * DERM app live: home "TOTAL VISITS" 783, no 000-DH/000-DP/Homestead
--     Dump/DUMP Pompano on the list or the /upload matcher; app loads normally.
-- ROLLBACK: restore the two view defs from the backup json (CREATE OR REPLACE)
--   and set the 5 formerly-NULL visits' derm_required back to NULL + unlock.
-- ============================================================================
