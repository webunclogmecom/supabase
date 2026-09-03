-- 2026-09-03_1400_watchdog_mirror_reachability.sql
--
-- WHY
-- ---
-- `derm.v_blackout_completed_unpublished` (shipped hours earlier in 2026-09-03_1230) OVER-REPORTED.
-- On its first run it named three folders; two of them - `derm/1194` (242-WYN) and
-- `window12-sheet11` (041-MB) - are NOT a customer problem at all:
--
--   manifest 1205 and manifest 913 each have ZERO public.manifest_visits links (all_links = 0),
--   therefore 0 completed visits and **0 rows in customer.work_orders**. Measured, not inferred.
--
-- `derm.fn_blackout_targets` excludes them CORRECTLY: its `live` CTE requires
-- `EXISTS (manifest_visits -> visits WHERE deleted_at IS NULL)`. With no visit there is no work
-- order, so there is no document for a client to be missing. The sheets are measured and banded and
-- would publish the moment somebody links a visit.
--
-- 🛑 THE DEFECT WAS IN MY WATCHDOG, NOT IN THE PIPELINE, AND IT IS THE FAILURE MODE THAT MATTERS
-- MOST FOR A WATCHDOG. The view asked "is a stamped pair unpublished?" while the thing it exists to
-- detect is "is a CLIENT missing a document?". A paraphrase of the rule manufactures false
-- positives, and two permanent false positives would have destroyed the one property that makes this
-- view usable - EMPTY IS HEALTHY. It would have become wallpaper within a week, which is exactly how
-- public.sync_log became unreadable.
--
-- ⇒ The `pairs` CTE now mirrors fn_blackout_targets' own reachability predicate. An assertion must
-- mirror the rule it tests.
--
-- EXPECTED POPULATION AFTER THIS CHANGE: exactly ONE folder, `ticket-833049` (10 clients), and it is
-- a TRUE positive - all 10 of its manifests carry a live link AND a customer.work_orders row, so
-- those 10 clients really do see a placeholder. It is frozen by a CHECK constraint on purpose (read
-- 2026-08-19_2355 PART 5 before touching it), so it will sit in this view permanently.
-- ⚠ THAT IS A PROBLEM FOR THE ESCALATION, NOT FOR THIS VIEW: a permanently-open item becomes the new
-- wallpaper. If it is escalated, it wants a TIME-BOXED public.fn_health_ack, which by design cannot
-- be permanent - see the health-watchdog section of Supabase/CLAUDE.md.
--
-- RULE 8 (audit): view only, no table or column change; nothing to opt in or out.
-- ⚠ CREATE OR REPLACE VIEW keeps the column list identical (dump_folder, completed_at,
-- completed_for, pairs_unpublished, clients_affected, blocker), so grants are preserved. A DROP +
-- CREATE here would silently discard the authenticated/service_role SELECT granted at install.

BEGIN;

CREATE OR REPLACE VIEW derm.v_blackout_completed_unpublished AS
WITH pairs AS (
  SELECT r.dump_folder,
         r.matched_manifest_id AS manifest_id,
         r.matched_client_id   AS client_id,
         COALESCE(r.stamp_page, r.page) AS effective_page
    FROM derm.address_row_map r
   WHERE r.matched_manifest_id IS NOT NULL
     AND r.matched_client_id IS NOT NULL
     AND r.stamp_placed_at IS NOT NULL
     -- 🛑 MIRROR derm.fn_blackout_targets' `live` CTE. Without this the view reports a sheet that the
     -- target function excludes for a GOOD reason (no linked visit => no work order => the client is
     -- not missing anything), and two such folders were permanent false positives on day one.
     AND EXISTS (SELECT 1 FROM public.manifest_visits mv
                   JOIN public.visits v ON v.id = mv.visit_id AND v.deleted_at IS NULL
                  WHERE mv.manifest_id = r.matched_manifest_id)
   GROUP BY 1,2,3,4
)
SELECT s.dump_folder,
       s.completed_at,
       now() - s.completed_at                    AS completed_for,
       count(*)                                  AS pairs_unpublished,
       count(DISTINCT p.client_id)               AS clients_affected,
       derm.fn_sheet_publishable(s.dump_folder)  AS blocker
  FROM derm.stamp_sheet_status s
  JOIN pairs p ON p.dump_folder = s.dump_folder
 WHERE s.completed
   AND s.completed_at < now() - interval '20 minutes'
   AND NOT EXISTS (SELECT 1 FROM derm.redacted_manifest_docs d
                    WHERE d.manifest_id = p.manifest_id
                      AND d.effective_page = p.effective_page)
 GROUP BY 1,2,3;

-- VERIFY
DO $do$
DECLARE v_n integer; v_folders text;
BEGIN
  -- 1. The two false positives are gone, and for the RIGHT reason: they still have no visit link.
  SELECT count(*) INTO v_n FROM derm.v_blackout_completed_unpublished
   WHERE dump_folder IN ('derm/1194', 'window12-sheet11');
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 1: % false positive(s) still reported', v_n;
  END IF;
  SELECT count(*) INTO v_n FROM public.manifest_visits mv WHERE mv.manifest_id IN (1205, 913);
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 1: manifests 1205/913 now HAVE % link(s); the premise of this change moved, re-measure', v_n;
  END IF;

  -- 2. POSITIVE CONTROL. The view must still report the one TRUE positive, or it has been narrowed
  --    into uselessness and every future clean read would be meaningless.
  SELECT count(*) INTO v_n FROM derm.v_blackout_completed_unpublished WHERE dump_folder = 'ticket-833049';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'VERIFY 2: control failed, ticket-833049 is no longer reported (rows=%)', v_n;
  END IF;
  SELECT clients_affected INTO v_n FROM derm.v_blackout_completed_unpublished WHERE dump_folder = 'ticket-833049';
  IF v_n <> 10 THEN RAISE EXCEPTION 'VERIFY 2: 833049 reports % clients, expected 10', v_n; END IF;

  -- 3. And nothing else crept in.
  SELECT count(*), coalesce(string_agg(dump_folder, ', ' ORDER BY dump_folder), '')
    INTO v_n, v_folders FROM derm.v_blackout_completed_unpublished;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'VERIFY 3: expected exactly 1 folder (ticket-833049), got %: %', v_n, v_folders;
  END IF;

  -- 4. Grants survived the replace (a DROP+CREATE would have silently discarded them).
  IF NOT has_table_privilege('authenticated', 'derm.v_blackout_completed_unpublished', 'SELECT') THEN
    RAISE EXCEPTION 'VERIFY 4: authenticated lost SELECT on the watchdog view';
  END IF;
  IF has_table_privilege('anon', 'derm.v_blackout_completed_unpublished', 'SELECT') THEN
    RAISE EXCEPTION 'VERIFY 4: anon can read the watchdog view';
  END IF;

  RAISE NOTICE 'VERIFY ok: watchdog now mirrors fn_blackout_targets reachability - 2 false positives dropped, the 833049 control still fires with 10 clients, grants intact.';
END $do$;

COMMIT;
