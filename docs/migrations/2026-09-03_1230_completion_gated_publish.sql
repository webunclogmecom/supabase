-- 2026-09-03_1230_completion_gated_publish.sql
--
-- WHY
-- ---
-- Fred, 2026-09-03: "the idea is that if it's marked as complete then after 5 min it needs a
-- blackout. period, if not then it can't be marked as complete."
--
-- This builds steps 2 and 3 of `Building Apps/DERM Stamp Studio/docs/11-completion-gated-publish-spec.md`
-- (written 2026-08-27 from Fred's own statement of the same goal). Step 1, the editable rectangle +
-- derm.save_page_geometry, shipped 2026-08-27. Until now "Complete" said NOTHING about the geometry:
-- a sheet could be 10/10 stamped and marked Complete with no derm.page_block_extents row at all, so
-- derm.fn_blackout_targets' "measured pages only" HARD GATE excluded it and the client saw a
-- placeholder for ever. That is exactly how ticket-834287 / ticket-830714 / ticket-312500 sat blocked
-- (6 clients), cleared by hand earlier today in 2026-09-02_1240 / _1245 / _1300.
--
-- WHAT THIS CHANGES
--   1. derm.fn_sheet_publishable(dump_folder) - ONE place that answers "can this sheet be blacked
--      out?", reusing the estate's own derm.v_blackout_blocked_sheets detector plus the extent check.
--   2. Completion is GATED on it, on BOTH write paths:
--        * HUMAN (derm.set_sheet_completed, the Studio RPC) RAISES with the reason and how to fix it.
--        * AUTOMATIC (trg_zy_generated_sheet_complete, the resolver) is made a NO-OP instead, by a
--          BEFORE trigger. It must NOT raise: the automatic callers do other work in the same
--          transaction and there is no human there to read an error.
--   3. DIRTY tracking: adding or removing a card, moving a stamp, or changing a band on a COMPLETED
--      sheet clears `completed`. The existing derm.fn_stamp_sheet_reopen_pin then stamps
--      reopened_at/by for free, and THAT is what stops a machine re-completing it.
--   4. trg_generated_sheet_complete now respects reopened_at. 🛑 It did NOT, and that is a real hole
--      the spec predicted: its ON CONFLICT WHERE was only "NOT completed", so the very next card
--      change would have silently re-completed a sheet a person had deliberately reopened, undoing
--      dirty tracking with nothing to show for it.
--   5. Completing a sheet KICKS the blackout sweep immediately instead of waiting up to 5 minutes.
--      The kick is wrapped so a net/vault failure can never fail the sign-off; the */5 cron stays the
--      backstop. ⚠ fn_request_blackout_sweep posts limit:1, so a multi-client folder still drains
--      over subsequent cron cycles rather than all at once.
--   6. derm.v_blackout_completed_unpublished - the watchdog for Fred's rule stated literally:
--      completed more than 20 minutes ago and still not published. EMPTY IS HEALTHY.
--   7. ticket-830714 is signed off. It was the ONE folder at completed=false (a person reopened it
--      2026-08-31 14:42 and never signed it back off); its geometry was measured and its three
--      served documents were opened and verified earlier today, so it is genuinely publishable.
--
-- BLAST RADIUS, measured before applying: 135 folders, 134 completed, and only FOUR completed
-- folders fail the new predicate - ticket-833049 (frozen by a CHECK constraint, by design),
-- window4-sheet1 (cards_withheld), window5-sheet3 (no_stamp_timestamp) and window13-sheet8 (no
-- stamps at all). The gate fires ONLY on the false->true TRANSITION, so none of them is touched:
-- they simply cannot be re-completed until the underlying problem is fixed, which is the point.
--
-- 🛑 NOT DONE HERE, DELIBERATELY: gating derm.fn_blackout_targets on `completed` (the other half of
-- the spec's step 3). That is the riskiest edit in this area (CREATE OR REPLACE on a large function)
-- and it changes publish semantics rather than fixing Fred's complaint, so it gets its own migration.
--
-- RULE 8 (audit): derm.stamp_sheet_status and derm.address_row_map are BOTH already audited, so every
-- completion, every dirty flip and every band change stays in audit.logs. No new tables.
--
-- ⚠ The two REPLACED function bodies below were copied byte-for-byte from pg_get_functiondef and
-- patched programmatically (scratchpad/patch.js), then diffed to prove only the added lines changed.
-- They were NOT retyped - see the CREATE OR REPLACE rule in Supabase/CLAUDE.md.

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 1. ONE definition of "can this sheet be blacked out?"
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.fn_sheet_publishable(p_dump_folder text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $fn$
  -- NULL means publishable. Any other value is the REASON it is not, and is shown to the operator.
  SELECT COALESCE(
    -- 1. the estate's own detector. It already knows every way a sheet can be unpublishable
    --    (needs_extent, needs_snap_then_extent, cards_withheld, no_stamp_timestamp,
    --    held_by_constraint, frozen_closed_world) and carries the what_to_do text beside it.
    (SELECT b.blocker FROM derm.v_blackout_blocked_sheets b
      WHERE b.dump_folder = p_dump_folder LIMIT 1),
    CASE
      -- 2. nothing placed: there is no document to produce, so "complete" would be meaningless.
      WHEN NOT EXISTS (SELECT 1 FROM derm.address_row_map r
                        WHERE r.dump_folder = p_dump_folder AND r.stamp_y_pct IS NOT NULL)
        THEN 'no_stamps'
      -- 3. a stamped page with no measured extent. This is the exact hard gate in
      --    fn_blackout_targets' geo CTE, restated so completion cannot outrun the measurement.
      WHEN EXISTS (
        SELECT 1
          FROM (SELECT DISTINCT COALESCE(r.stamp_page, r.page) AS pg
                  FROM derm.address_row_map r
                 WHERE r.dump_folder = p_dump_folder AND r.stamp_y_pct IS NOT NULL) sp
         WHERE NOT EXISTS (SELECT 1 FROM derm.page_block_extents e
                            WHERE e.dump_folder = p_dump_folder AND e.effective_page = sp.pg))
        THEN 'needs_extent'
      ELSE NULL
    END);
$fn$;

REVOKE ALL ON FUNCTION derm.fn_sheet_publishable(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION derm.fn_sheet_publishable(text) FROM anon;
GRANT EXECUTE ON FUNCTION derm.fn_sheet_publishable(text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- PART 2. The HUMAN path refuses LOUDLY. Body copied from pg_get_functiondef, guard inserted.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.set_sheet_completed(p_dump_folder text, p_completed boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE v_block text;
BEGIN
  PERFORM derm._require_stamp_key();

  -- 🛑 COMPLETION IS A STATEMENT ABOUT THE GEOMETRY. A sheet that cannot be blacked out must not
  -- be markable complete (Fred, 2026-09-03: "if it's marked as complete then after 5 min it needs a
  -- blackout. period, if not then it can't be marked as complete").
  IF p_completed THEN
    v_block := derm.fn_sheet_publishable(p_dump_folder);
    IF v_block IS NOT NULL THEN
      RAISE EXCEPTION 'cannot mark % complete: %', p_dump_folder, v_block
        USING HINT = 'Measure the page first: drag the boundary to the first and last printed rule and snap every band, then mark complete.';
    END IF;
  END IF;
  INSERT INTO derm.stamp_sheet_status (dump_folder, completed, completed_at, completed_by, updated_at)
  VALUES (p_dump_folder, p_completed,
          CASE WHEN p_completed THEN now() END,
          CASE WHEN p_completed THEN coalesce(nullif(current_setting('request.jwt.claim.email', true), ''), 'stamp-studio') END,
          now())
  ON CONFLICT (dump_folder) DO UPDATE SET
    completed    = EXCLUDED.completed,
    completed_at = CASE WHEN EXCLUDED.completed THEN now() ELSE NULL END,
    completed_by = CASE WHEN EXCLUDED.completed THEN EXCLUDED.completed_by ELSE NULL END,
    updated_at   = now();
END $function$;

-- ---------------------------------------------------------------------------
-- PART 3. The AUTOMATIC path is made a NO-OP, never an abort.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.fn_completion_requires_geometry()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $fn$
DECLARE v_was boolean; v_block text;
BEGIN
  IF TG_OP = 'INSERT' THEN v_was := false; ELSE v_was := COALESCE(OLD.completed, false); END IF;

  -- Only the false->true TRANSITION is gated. An unrelated UPDATE on an already-complete sheet
  -- (an updated_at bump, a re-save) must never be re-litigated, or a legacy folder that predates
  -- this rule would silently flip to incomplete and stop regenerating.
  IF NEW.completed IS TRUE AND NOT v_was THEN
    v_block := derm.fn_sheet_publishable(NEW.dump_folder);
    IF v_block IS NOT NULL THEN
      NEW.completed    := false;
      NEW.completed_at := NULL;
      NEW.completed_by := NULL;
      RAISE WARNING 'sheet % was NOT marked complete: %', NEW.dump_folder, v_block;
    END IF;
  END IF;
  RETURN NEW;
END $fn$;

-- trg_a0_ sorts BEFORE trg_aa_reopen_pin ON PURPOSE, so the pin sees the FINAL value of completed.
DROP TRIGGER IF EXISTS trg_a0_completion_requires_geometry ON derm.stamp_sheet_status;
CREATE TRIGGER trg_a0_completion_requires_geometry
  BEFORE INSERT OR UPDATE ON derm.stamp_sheet_status
  FOR EACH ROW EXECUTE FUNCTION derm.fn_completion_requires_geometry();

-- ---------------------------------------------------------------------------
-- PART 4. Auto-complete must respect the reopen pin. Body copied, ONE clause added.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.trg_generated_sheet_complete()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  INSERT INTO derm.stamp_sheet_status (dump_folder, completed, completed_at, completed_by, updated_at)
  VALUES (NEW.dump_folder, true, now(), 'stamp-studio-ai', now())
  ON CONFLICT (dump_folder) DO UPDATE
    SET completed = true,
        completed_at = COALESCE(derm.stamp_sheet_status.completed_at, now()),
        completed_by = COALESCE(derm.stamp_sheet_status.completed_by, 'stamp-studio-ai'),
        updated_at = now()
    WHERE NOT derm.stamp_sheet_status.completed
      -- 🛑 NEVER re-complete what was reopened. Without this the dirty state is undone silently by
      -- the next card change, which is the hazard 11-completion-gated-publish-spec.md predicted.
      AND derm.stamp_sheet_status.reopened_at IS NULL;
  RETURN NULL;
END $function$;

-- ---------------------------------------------------------------------------
-- PART 5. DIRTY tracking.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.fn_dirty_on_card_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $fn$
DECLARE v_folder text;
BEGIN
  v_folder := COALESCE(NEW.dump_folder, OLD.dump_folder);
  IF v_folder IS NULL THEN RETURN NULL; END IF;

  -- Clearing `completed` is enough: derm.fn_stamp_sheet_reopen_pin (trg_aa_reopen_pin) stamps
  -- reopened_at/by on the true->false flip, and that pin is what stops a machine re-completing it.
  UPDATE derm.stamp_sheet_status s
     SET completed = false, completed_at = NULL, completed_by = NULL, updated_at = now()
   WHERE s.dump_folder = v_folder AND s.completed;

  RETURN NULL;
END $fn$;

-- trg_zz_ sorts AFTER trg_zy_generated_sheet_complete, so on a card INSERT the auto-complete runs
-- first and this then marks the sheet dirty. Reversed, the auto-complete would win the transaction.
DROP TRIGGER IF EXISTS trg_zz_dirty_on_card_change ON derm.address_row_map;
CREATE TRIGGER trg_zz_dirty_on_card_change
  AFTER INSERT OR DELETE OR UPDATE OF
        stamp_x_pct, stamp_y_pct, stamp_page, stamp_placed_at,
        band_y0_pct, band_y1_pct, matched_client_id, matched_manifest_id, gdo_id
  ON derm.address_row_map
  FOR EACH ROW EXECUTE FUNCTION derm.fn_dirty_on_card_change();

-- ---------------------------------------------------------------------------
-- PART 6. Completing a sheet kicks the sweep immediately.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.fn_publish_on_complete()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $fn$
DECLARE v_was boolean;
BEGIN
  IF TG_OP = 'INSERT' THEN v_was := false; ELSE v_was := COALESCE(OLD.completed, false); END IF;
  IF NEW.completed IS TRUE AND NOT v_was THEN
    BEGIN
      PERFORM public.fn_request_blackout_sweep();
    EXCEPTION WHEN OTHERS THEN
      -- A sign-off must NEVER fail because the sweep could not be kicked. The */5 cron is the backstop.
      RAISE WARNING 'blackout sweep kick failed for %: %', NEW.dump_folder, SQLERRM;
    END;
  END IF;
  RETURN NULL;
END $fn$;

DROP TRIGGER IF EXISTS trg_zz_publish_on_complete ON derm.stamp_sheet_status;
CREATE TRIGGER trg_zz_publish_on_complete
  AFTER INSERT OR UPDATE ON derm.stamp_sheet_status
  FOR EACH ROW EXECUTE FUNCTION derm.fn_publish_on_complete();

-- ---------------------------------------------------------------------------
-- PART 7. The watchdog, Fred's rule stated literally. EMPTY IS HEALTHY.
-- ---------------------------------------------------------------------------
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

REVOKE ALL ON derm.v_blackout_completed_unpublished FROM PUBLIC;
REVOKE ALL ON derm.v_blackout_completed_unpublished FROM anon;
GRANT SELECT ON derm.v_blackout_completed_unpublished TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- PART 8. Sign off ticket-830714, which is now genuinely publishable.
-- ---------------------------------------------------------------------------
UPDATE derm.stamp_sheet_status
   SET completed = true, completed_at = now(), completed_by = 'claude-completion-gate-2026-09-03'
 WHERE dump_folder = 'ticket-830714' AND NOT completed;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_n integer; v_txt text; v_stored boolean;
BEGIN
  -- 1. POSITIVE CONTROL for the predicate. A known-bad folder must NAME its blocker, or every
  --    clean answer below is an untested instrument.
  v_txt := derm.fn_sheet_publishable('ticket-833049');
  IF v_txt IS DISTINCT FROM 'held_by_constraint' THEN
    RAISE EXCEPTION 'VERIFY 1: control failed, 833049 returned % (want held_by_constraint)', coalesce(v_txt, 'NULL');
  END IF;
  v_txt := derm.fn_sheet_publishable('ticket-834287');
  IF v_txt IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY 1: 834287 should be publishable, got %', v_txt;
  END IF;

  -- 2. THE GATE ACTUALLY BITES. Self-contained sentinel: an unpublishable folder asking to be
  --    completed must come back NOT complete.
  INSERT INTO derm.stamp_sheet_status (dump_folder, completed, completed_at, completed_by, updated_at)
  VALUES ('__gate_probe__', true, now(), 'probe', now());
  SELECT completed INTO v_stored FROM derm.stamp_sheet_status WHERE dump_folder = '__gate_probe__';
  IF v_stored IS NOT FALSE THEN
    RAISE EXCEPTION 'VERIFY 2: the gate did not bite, sentinel stored completed=%', v_stored;
  END IF;
  DELETE FROM derm.stamp_sheet_status WHERE dump_folder = '__gate_probe__';
  IF EXISTS (SELECT 1 FROM derm.stamp_sheet_status WHERE dump_folder = '__gate_probe__') THEN
    RAISE EXCEPTION 'VERIFY 2: sentinel not cleaned up';
  END IF;

  -- 3. A PUBLISHABLE sheet is still allowed through: 830714, signed off in PART 8, and its reopen
  --    pin cleared by the existing trg_aa_reopen_pin.
  SELECT completed INTO v_stored FROM derm.stamp_sheet_status WHERE dump_folder = 'ticket-830714';
  IF v_stored IS NOT TRUE THEN
    RAISE EXCEPTION 'VERIFY 3: ticket-830714 did not complete (gate too strict?)';
  END IF;
  SELECT count(*) INTO v_n FROM derm.stamp_sheet_status
   WHERE dump_folder = 'ticket-830714' AND reopened_at IS NULL;
  IF v_n <> 1 THEN RAISE EXCEPTION 'VERIFY 3: 830714 reopen pin was not cleared by completion'; END IF;

  -- 4. Auto-complete now respects the pin: the hole this migration closes.
  SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'derm' AND p.proname = 'trg_generated_sheet_complete'
     AND pg_get_functiondef(p.oid) LIKE '%reopened_at IS NULL%';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'VERIFY 4: trg_generated_sheet_complete does not check reopened_at';
  END IF;

  -- 5. Trigger ORDER is load-bearing and alphabetical, and both triggers exist.
  IF NOT ('trg_a0_completion_requires_geometry' < 'trg_aa_reopen_pin') THEN
    RAISE EXCEPTION 'VERIFY 5: the gate must sort before the reopen pin';
  END IF;
  IF NOT ('trg_zy_generated_sheet_complete' < 'trg_zz_dirty_on_card_change') THEN
    RAISE EXCEPTION 'VERIFY 5: the dirty trigger must sort after auto-complete';
  END IF;
  SELECT count(*) INTO v_n FROM pg_trigger
   WHERE tgrelid = 'derm.stamp_sheet_status'::regclass AND NOT tgisinternal
     AND tgname IN ('trg_a0_completion_requires_geometry', 'trg_zz_publish_on_complete');
  IF v_n <> 2 THEN RAISE EXCEPTION 'VERIFY 5: expected 2 stamp_sheet_status triggers, found %', v_n; END IF;
  SELECT count(*) INTO v_n FROM pg_trigger
   WHERE tgrelid = 'derm.address_row_map'::regclass AND NOT tgisinternal
     AND tgname = 'trg_zz_dirty_on_card_change';
  IF v_n <> 1 THEN RAISE EXCEPTION 'VERIFY 5: dirty trigger missing'; END IF;

  -- 6. DIRTY TRACKING ACTUALLY FIRES, proven by mutation and then restored. ticket-834287 is a
  --    single-client folder that is publishable, so it can be dirtied and signed off again with a
  --    net-zero end state.
  UPDATE derm.address_row_map SET stamp_placed_at = stamp_placed_at
   WHERE dump_folder = 'ticket-834287';
  SELECT completed INTO v_stored FROM derm.stamp_sheet_status WHERE dump_folder = 'ticket-834287';
  IF v_stored IS NOT FALSE THEN
    RAISE EXCEPTION 'VERIFY 6: a card change did NOT mark the sheet dirty (completed=%)', v_stored;
  END IF;
  SELECT count(*) INTO v_n FROM derm.stamp_sheet_status
   WHERE dump_folder = 'ticket-834287' AND reopened_at IS NOT NULL;
  IF v_n <> 1 THEN RAISE EXCEPTION 'VERIFY 6: dirty did not set the reopen pin'; END IF;
  -- restore
  UPDATE derm.stamp_sheet_status
     SET completed = true, completed_at = now(), completed_by = 'claude-completion-gate-2026-09-03'
   WHERE dump_folder = 'ticket-834287';
  SELECT completed INTO v_stored FROM derm.stamp_sheet_status WHERE dump_folder = 'ticket-834287';
  IF v_stored IS NOT TRUE THEN RAISE EXCEPTION 'VERIFY 6: could not re-complete 834287'; END IF;

  -- 7. Nothing was left incomplete in bulk.
  SELECT count(*) INTO v_n FROM derm.stamp_sheet_status WHERE NOT completed;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 7: % folder(s) left incomplete, expected 0', v_n;
  END IF;

  RAISE NOTICE 'VERIFY ok: predicate controls pass, the gate refuses an unpublishable sheet and admits a publishable one, dirty tracking fires and sets the pin, auto-complete respects the pin, trigger order correct.';
END $do$;

COMMIT;
