-- 2026-08-27_0347_harden_band_write_path.sql
--
-- WHY
-- ---
-- Fred, 2026-08-26: "The stamp app right now puts a chip for you to put it on the paper, make the
-- chip be like a rectangle that it's the boundaries of the client." That makes derm.set_row_band a
-- HUMAN-FACING write path for the first time. Measured the same day: it has never been called by
-- the Studio at all -- all 1,183 historical band changes carry app_source='sql' and not one row in
-- the table carries band_source='manual', the only value that function can write. So every defect
-- below has been latent, and the UI change is what makes them reachable.
--
-- This migration hardens the write path and puts the invariants on the table. It ships BEFORE the
-- UI change on purpose: the constraints must exist before a person can drive the RPC.
--
-- 🛑 NOTHING HERE CHANGES ANY BAND, ANY EXTENT, OR ANY PUBLISHED DOCUMENT. It is guards only. The
-- two blocked folders (ticket-833530, ticket-833813) are deliberately untouched.
--
-- RULE 8 (audit trail)
-- --------------------
-- * derm.address_row_map -- already audited (trigger audit_address_row_map). Adding CHECK
--   constraints needs no action.
-- * derm.page_block_extents -- OPT-IN, NEW, and overdue. It carried ZERO triggers and audit.logs
--   held 0 rows for it against a control of 4,818 for derm.address_row_map. CLAUDE.md's own rule
--   ("check whether the table is audited FIRST -- that is what decides if it is recoverable") says
--   an unaudited table has no restore path at all. This table is the single input to the FP
--   blackout that has no detector, and it is about to acquire an automated writer, so it gets the
--   trigger now, while it still has only 162 rows.
--
-- WHAT WAS WRONG, each verified against the live objects on 2026-08-26/27
-- ----------------------------------------------------------------------
-- 1. derm.set_row_band ACCEPTS NULLS AND SILENTLY REVERTS A BAND.
--    Its guard is `IF p_y0 < 0 OR p_y1 > 100 OR p_y0 >= p_y1 THEN RAISE`. On NULL input every
--    comparison is NULL, the OR is NULL, and `IF NULL` does not fire. So set_row_band(id,NULL,NULL)
--    clears both band columns back to the DERIVED stamp-midpoint heuristic while stamping
--    band_source='manual'. Measured as a pure predicate, with controls:
--        (NULL,NULL) IS TRUE -> false   (would NOT raise)
--        (60,40)     IS TRUE -> true    (would raise)
--    Its sibling derm.set_stamp_position rejects NULLs explicitly; this one never did.
--
-- 2. A BAND ON A ROW WITH NO STAMP POINT FREEZES EVERY DOCUMENT IN THE FOLDER.
--    derm.fn_blackout_targets applies a whole-folder closed-world gate against
--    derm.v_stamp_row_bands, and that view is `... WHERE stamp_y_pct IS NOT NULL`. A row carrying a
--    band but no stamp is therefore missing from the view, the folder fails the gate, and NOTHING
--    in it can regenerate. Two folders are already in that state -- ticket-828604 (4 rows) and
--    ticket-830714 (3 rows) -- holding 7 permanently unregenerable customer documents.
--    🛑 AND NEITHER HEALTH VIEW CAN SEE IT: derm.v_blackout_blocked_sheets filters
--    `stamp_y_pct IS NOT NULL`, so both folders return zero rows from it. A detector for this is
--    the next migration; this one stops NEW instances being created.
--
-- 3. derm.clear_stamp_position IS THE THING THAT CREATES STATE 2.
--    It nulls the five stamp_* columns and deliberately leaves band_y0_pct/band_y1_pct behind. That
--    is exactly the shape above. It now clears the band with the stamp.
--
-- 4. band_set_by / stamp_placed_by HAVE NEVER RECORDED A HUMAN.
--    Both read `current_setting('request.jwt.claim.email')` -- SINGULAR `claim`. PostgREST sets
--    `request.jwt.claims` (PLURAL, a JSON object), so the singular key is never set and the
--    coalesce always falls through to the literal 'stamp-studio'. This is the identical defect
--    CLAUDE.md documents for audit.logs.changed_by, which has been NULL on all 54,756 rows for the
--    same reason. Measured: of 641 banded rows, band_set_by holds 111 NULLs and 9 machine labels,
--    and NOT ONE email.
--    ⇒ Fixed in ONE place, derm._actor(), not copied into three functions. Two copies of a rule is
--      how the base64 encoder nearly drifted, and that one at least had a test asserting they matched.
--
-- WHAT IS DELIBERATELY *NOT* DONE HERE
-- ------------------------------------
-- * No signature change to set_row_band. Adding `p_source text DEFAULT NULL` would create a second
--   overload, and then a 3-argument call matches BOTH and fails as ambiguous. band_source='manual'
--   already identifies this RPC uniquely (0 existing rows carry it), so provenance is available
--   without touching the signature that a cached Lovable bundle calls.
-- * No folder-level "all rows must be banded" gate. That belongs on the EXTENT write, not here:
--   partial banding is a legitimate intermediate state while a person works down a sheet. The gate
--   ships with the extent writer.
-- * The 7 legacy band-without-stamp rows are NOT repaired and NOT deleted. They are the evidence
--   for the detector in the next migration, and repairing them would republish 7 customer
--   documents as a side effect of a guards-only change.

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 1. ONE implementation of "who is doing this".
-- ---------------------------------------------------------------------------
-- Reads the PLURAL claims object PostgREST actually sets, falling back to the singular key (so a
-- caller that somehow sets it still works) and then to a supplied default.
--
-- 🛑 FAIL-SAFE BY CONSTRUCTION. If request.jwt.claims holds anything that is not valid JSON the
-- cast would raise, and this function is called from inside the save path -- a raise here would
-- turn "we could not identify you" into "your rectangle was not saved". The inner block swallows
-- it and falls through to the default instead. Losing an attribution is acceptable; losing the
-- write is not.
CREATE OR REPLACE FUNCTION derm._actor(p_default text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE
  v_email text;
BEGIN
  BEGIN
    v_email := nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email';
  EXCEPTION WHEN others THEN
    v_email := NULL;
  END;
  RETURN coalesce(
    nullif(v_email, ''),
    nullif(current_setting('request.jwt.claim.email', true), ''),
    p_default);
END $function$;

-- Same privilege shape as derm._require_stamp_key: reachable only from inside the SECURITY DEFINER
-- wrappers, which run as postgres. Supabase's ALTER DEFAULT PRIVILEGES hands out grants nobody
-- wrote, so anon/authenticated/service_role are revoked EXPLICITLY rather than assumed absent.
REVOKE ALL ON FUNCTION derm._actor(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION derm._actor(text) FROM anon;
REVOKE ALL ON FUNCTION derm._actor(text) FROM authenticated;
REVOKE ALL ON FUNCTION derm._actor(text) FROM service_role;

COMMENT ON FUNCTION derm._actor(text) IS
  'Resolve the acting user from the PostgREST JWT. Reads request.jwt.claims (PLURAL) - the singular '
  'request.jwt.claim.email is never set by PostgREST and is why band_set_by/stamp_placed_by have '
  'never held an email. Fail-safe: any parse problem returns the default rather than raising, '
  'because callers are save paths. See 2026-08-27_0347.';

-- ---------------------------------------------------------------------------
-- PART 2. derm.set_row_band -- the rectangle write path.
-- ---------------------------------------------------------------------------
-- Body COPIED from the live pg_get_functiondef output and edited in place, never retyped
-- (CLAUDE.md: "CREATE OR REPLACE: COPY THE WHOLE BODY, NEVER RETYPE IT"). Changes, and only these:
--   + an explicit NULL guard, which is defect 1
--   + a stamp-point requirement, which is defect 2
--   + band_set_by now goes through derm._actor, which is defect 4
-- Everything else -- the _require_stamp_key call, the range guard, the round(...,3), the
-- band_source literal, the NOT FOUND raise -- is byte-for-byte what was there.
CREATE OR REPLACE FUNCTION derm.set_row_band(p_row_id bigint, p_y0 numeric, p_y1 numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE
  v_has_stamp boolean;
BEGIN
  PERFORM derm._require_stamp_key();

  -- Defect 1. MUST come before the range guard: on NULL input the range guard evaluates to NULL,
  -- IF NULL does not fire, and the UPDATE silently reverts the band to the derived heuristic while
  -- labelling it 'manual'.
  IF p_row_id IS NULL OR p_y0 IS NULL OR p_y1 IS NULL THEN
    RAISE EXCEPTION 'band arguments must not be null (row=%, y0=%, y1=%)', p_row_id, p_y0, p_y1;
  END IF;

  IF p_y0 < 0 OR p_y1 > 100 OR p_y0 >= p_y1 THEN
    RAISE EXCEPTION 'invalid band (y0=%, y1=%)', p_y0, p_y1;
  END IF;

  -- Defect 2. A band on a row with no stamp point removes that row from derm.v_stamp_row_bands,
  -- which fails fn_blackout_targets' whole-folder closed-world gate and freezes EVERY document in
  -- the folder. Refuse rather than create another ticket-828604.
  SELECT (stamp_y_pct IS NOT NULL) INTO v_has_stamp
    FROM derm.address_row_map WHERE id = p_row_id;
  IF v_has_stamp IS NULL THEN
    RAISE EXCEPTION 'address_row_map id % not found', p_row_id;
  END IF;
  IF NOT v_has_stamp THEN
    RAISE EXCEPTION 'row % has no stamp point; place the stamp before setting its band '
                    '(a band without a stamp freezes every document in the folder)', p_row_id;
  END IF;

  UPDATE derm.address_row_map
     SET band_y0_pct = round(p_y0, 3), band_y1_pct = round(p_y1, 3),
         band_source = 'manual', band_set_at = now(),
         band_set_by = derm._actor('stamp-studio')
   WHERE id = p_row_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'row % not found', p_row_id; END IF;
END $function$;

-- ---------------------------------------------------------------------------
-- PART 3. derm.clear_stamp_position -- stop it manufacturing the frozen state.
-- ---------------------------------------------------------------------------
-- Body copied from live. The ONLY change is that the band columns are cleared alongside the stamp.
-- Leaving a band behind is defect 3, and it is how ticket-828604 and ticket-830714 came to hold 7
-- documents that can never regenerate.
CREATE OR REPLACE FUNCTION derm.clear_stamp_position(p_row_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
BEGIN
  PERFORM derm._require_stamp_key();
  UPDATE derm.address_row_map
     SET stamp_x_pct = NULL, stamp_y_pct = NULL, stamp_page = NULL,
         stamp_placed_at = NULL, stamp_placed_by = NULL,
         -- clearing the point must clear the rectangle: a band with no stamp is invisible to
         -- derm.v_stamp_row_bands and fails the folder's closed-world gate
         band_y0_pct = NULL, band_y1_pct = NULL,
         band_source = NULL, band_set_at = NULL, band_set_by = NULL
   WHERE id = p_row_id;
END $function$;

-- ---------------------------------------------------------------------------
-- PART 4. derm.set_stamp_position -- same attribution defect, same one-line fix.
-- ---------------------------------------------------------------------------
-- Body copied from live. The ONLY change is stamp_placed_by going through derm._actor. Every guard
-- it already had is unchanged.
CREATE OR REPLACE FUNCTION derm.set_stamp_position(p_row_id bigint, p_page integer, p_x_pct numeric, p_y_pct numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
BEGIN
  PERFORM derm._require_stamp_key();
  IF p_row_id IS NULL OR p_page IS NULL OR p_x_pct IS NULL OR p_y_pct IS NULL THEN
    RAISE EXCEPTION 'stamp arguments must not be null (row=%, page=%, x=%, y=%)', p_row_id, p_page, p_x_pct, p_y_pct;
  END IF;
  IF p_page < 1 THEN RAISE EXCEPTION 'stamp page must be >= 1 (got %)', p_page; END IF;
  IF p_x_pct < 0 OR p_x_pct > 100 OR p_y_pct < 0 OR p_y_pct > 100 THEN
    RAISE EXCEPTION 'stamp percent out of range (x=%, y=%)', p_x_pct, p_y_pct;
  END IF;
  UPDATE derm.address_row_map
     SET stamp_x_pct = round(p_x_pct, 3),
         stamp_y_pct = round(p_y_pct, 3),
         stamp_page  = p_page,
         stamp_placed_at = now(),
         stamp_placed_by = derm._actor('stamp-studio')
   WHERE id = p_row_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'address_row_map id % not found', p_row_id; END IF;
END $function$;

-- ---------------------------------------------------------------------------
-- PART 5. Put the band invariants on the TABLE, not only in the function.
-- ---------------------------------------------------------------------------
-- The RPC is not the only way in. CLAUDE.md records that app_source='sql' was the single largest
-- writer in audit.logs over a 12-hour window, and all 1,183 historical band writes came that way --
-- six different bulk snap migrations. A seventh, written the way the previous six were, would
-- overwrite human rectangles with machine values with nothing to stop it. These constraints bind
-- every writer including a migration.

-- Measured 2026-08-26: 641 rows carry both band columns, 0 carry exactly one, 0 violate the range.
-- So this is VALIDATED, not NOT VALID.
ALTER TABLE derm.address_row_map
  ADD CONSTRAINT address_row_map_band_range_chk
  CHECK (
    (band_y0_pct IS NULL AND band_y1_pct IS NULL)
    OR (band_y0_pct IS NOT NULL AND band_y1_pct IS NOT NULL
        AND band_y0_pct >= 0 AND band_y1_pct <= 100
        AND band_y0_pct < band_y1_pct)
  );

-- 🛑 NOT VALID ON PURPOSE, AND IT MUST STAY THAT WAY UNTIL THE 7 LEGACY ROWS ARE DEALT WITH.
-- ticket-828604 (4 rows) and ticket-830714 (3 rows) carry a band with no stamp point today, so
-- VALIDATE CONSTRAINT fails BY DESIGN -- exactly like derm_manifests_dump_fields_present_chk.
-- Do NOT delete or blank those rows to make it pass: they hold 7 published customer documents and
-- they are the evidence for the detector that ships next.
-- NOT VALID still binds every INSERT and every UPDATE, which is the point: no NEW instance.
ALTER TABLE derm.address_row_map
  ADD CONSTRAINT address_row_map_band_needs_stamp_chk
  CHECK (band_y0_pct IS NULL OR stamp_y_pct IS NOT NULL) NOT VALID;

COMMENT ON CONSTRAINT address_row_map_band_needs_stamp_chk ON derm.address_row_map IS
  'A band with no stamp point is missing from derm.v_stamp_row_bands, which fails '
  'derm.fn_blackout_targets whole-folder closed-world gate and freezes every document in the '
  'folder. NOT VALID because 7 legacy rows (ticket-828604, ticket-830714) are already in that '
  'state and hold published documents. See 2026-08-27_0347.';

-- ---------------------------------------------------------------------------
-- PART 6. derm.page_block_extents -- a range check and an audit trail.
-- ---------------------------------------------------------------------------
-- Before this, its ONLY constraint was the ticket-833049 freeze. There was no 0..100 and no
-- top<bottom, and redact-manifest-sheet CLAMPS out-of-range values silently
-- (Math.max(0,...) / Math.min(H-1,...)), so a bogus value blacks the whole page with no error.
-- Measured 2026-08-26: 0 of 162 rows violate the range, so VALIDATED.
ALTER TABLE derm.page_block_extents
  ADD CONSTRAINT page_block_extents_range_chk
  CHECK (top_pct >= 0 AND bottom_pct <= 100 AND top_pct < bottom_pct);

-- Rule 8 opt-in. This is the only input to the FP blackout with no detector, it is about to get an
-- automated writer, and an overwrite currently leaves no old_row and no restore path.
CREATE TRIGGER audit_page_block_extents
  AFTER INSERT OR UPDATE OR DELETE ON derm.page_block_extents
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
-- 🛑 EVERY DESTRUCTIVE PROBE RUNS INSIDE A SUBTRANSACTION THAT IS ROLLED BACK. A PL/pgSQL
-- BEGIN...EXCEPTION block is a subtransaction, so raising a sentinel at the end of it undoes the
-- write while letting the migration continue.
--
-- 🛑 AND THE OLD BODY IS RE-CREATED AS A POSITIVE CONTROL. A matrix reporting 0 failures is an
-- untested instrument: the assertions below only mean something if they demonstrably FAIL against
-- the previous implementation. That is the whole reason PART 0 of 2026-08-06_1655 exists.
DO $do$
DECLARE
  v_row      bigint;
  v_nostamp  bigint;
  v_y0       numeric;
  v_y1       numeric;
  v_raised   boolean;
  v_old_ok   boolean;
  v_n        integer;
  v_actor    text;
BEGIN
  -- A row that is safe to probe: it has a stamp AND a band today, so every guard is exercised.
  SELECT id, band_y0_pct, band_y1_pct INTO v_row, v_y0, v_y1
    FROM derm.address_row_map
   WHERE stamp_y_pct IS NOT NULL AND band_y0_pct IS NOT NULL
   ORDER BY id LIMIT 1;
  IF v_row IS NULL THEN
    RAISE EXCEPTION 'VERIFY setup failed: no stamped+banded row to probe';
  END IF;

  -- One of the 7 legacy band-without-stamp rows, used to prove the NOT VALID constraint is real.
  SELECT id INTO v_nostamp
    FROM derm.address_row_map
   WHERE band_y0_pct IS NOT NULL AND stamp_y_pct IS NULL
   ORDER BY id LIMIT 1;
  IF v_nostamp IS NULL THEN
    RAISE EXCEPTION 'VERIFY setup failed: expected at least one legacy band-without-stamp row';
  END IF;

  -- 1. NULL arguments must now RAISE.
  v_raised := false;
  BEGIN
    PERFORM derm.set_row_band(v_row, NULL, NULL);
  EXCEPTION WHEN others THEN v_raised := true;
  END;
  IF NOT v_raised THEN
    RAISE EXCEPTION 'VERIFY 1 failed: set_row_band still accepts NULL arguments';
  END IF;

  -- 2. An inverted band must still RAISE (the guard that already worked must not have been lost).
  v_raised := false;
  BEGIN
    PERFORM derm.set_row_band(v_row, 60, 40);
  EXCEPTION WHEN others THEN v_raised := true;
  END;
  IF NOT v_raised THEN
    RAISE EXCEPTION 'VERIFY 2 failed: set_row_band accepts an inverted band';
  END IF;

  -- 3. A band on a row with no stamp point must RAISE.
  v_raised := false;
  BEGIN
    PERFORM derm.set_row_band(v_nostamp, 30, 36);
  EXCEPTION WHEN others THEN v_raised := true;
  END;
  IF NOT v_raised THEN
    RAISE EXCEPTION 'VERIFY 3 failed: set_row_band accepted a band on a stampless row (id %)', v_nostamp;
  END IF;

  -- 4. POSITIVE CONTROL: the valid path must still work. Without this, 1-3 would also pass on a
  --    function that rejects everything.
  BEGIN
    PERFORM derm.set_row_band(v_row, 30.5, 36.25);
    SELECT band_y0_pct, band_source INTO v_y0, v_actor
      FROM derm.address_row_map WHERE id = v_row;
    IF v_y0 <> 30.5 THEN
      RAISE EXCEPTION 'VERIFY 4 failed: valid band not written (got %)', v_y0;
    END IF;
    IF v_actor <> 'manual' THEN
      RAISE EXCEPTION 'VERIFY 4 failed: band_source is % not manual', v_actor;
    END IF;
    RAISE EXCEPTION 'rollback_probe_4';
  EXCEPTION WHEN others THEN
    IF SQLERRM <> 'rollback_probe_4' THEN RAISE; END IF;
  END;

  -- 5. clear_stamp_position must now clear the band too.
  BEGIN
    PERFORM derm.clear_stamp_position(v_row);
    SELECT count(*) INTO v_n FROM derm.address_row_map
      WHERE id = v_row AND (band_y0_pct IS NOT NULL OR band_y1_pct IS NOT NULL
                            OR band_source IS NOT NULL OR band_set_by IS NOT NULL);
    IF v_n <> 0 THEN
      RAISE EXCEPTION 'VERIFY 5 failed: clear_stamp_position left band data behind';
    END IF;
    RAISE EXCEPTION 'rollback_probe_5';
  EXCEPTION WHEN others THEN
    IF SQLERRM <> 'rollback_probe_5' THEN RAISE; END IF;
  END;

  -- 6. THE CONTROL THAT MAKES 1 AND 3 MEAN ANYTHING: re-create the PREVIOUS body under a temp name
  --    and confirm it does NOT raise on NULL input, i.e. the defect was real and the test detects
  --    the difference.
  CREATE FUNCTION derm._tmp_old_set_row_band(p_row_id bigint, p_y0 numeric, p_y1 numeric)
   RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'derm','public'
  AS $old$
  BEGIN
    IF p_y0 < 0 OR p_y1 > 100 OR p_y0 >= p_y1 THEN
      RAISE EXCEPTION 'invalid band (y0=%, y1=%)', p_y0, p_y1;
    END IF;
    UPDATE derm.address_row_map
       SET band_y0_pct = round(p_y0, 3), band_y1_pct = round(p_y1, 3),
           band_source = 'manual', band_set_at = now(), band_set_by = 'stamp-studio'
     WHERE id = p_row_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'row % not found', p_row_id; END IF;
  END $old$;

  v_old_ok := false;
  BEGIN
    PERFORM derm._tmp_old_set_row_band(v_row, NULL, NULL);
    v_old_ok := true;                     -- the old body accepted NULLs: the defect was real
    RAISE EXCEPTION 'rollback_probe_6';
  EXCEPTION WHEN others THEN
    IF SQLERRM <> 'rollback_probe_6' THEN
      v_old_ok := false;
    END IF;
  END;
  DROP FUNCTION derm._tmp_old_set_row_band(bigint, numeric, numeric);
  IF NOT v_old_ok THEN
    RAISE EXCEPTION 'VERIFY 6 failed: the OLD body did not accept NULLs, so VERIFY 1 proves nothing';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'derm' AND p.proname = '_tmp_old_set_row_band') THEN
    RAISE EXCEPTION 'VERIFY 6 failed: the temporary control function was not dropped';
  END IF;

  -- 7. Constraints exist, with the intended validity.
  SELECT count(*) INTO v_n FROM pg_constraint
   WHERE conrelid = 'derm.address_row_map'::regclass
     AND conname = 'address_row_map_band_range_chk' AND convalidated;
  IF v_n <> 1 THEN RAISE EXCEPTION 'VERIFY 7 failed: band range check missing or not validated'; END IF;

  SELECT count(*) INTO v_n FROM pg_constraint
   WHERE conrelid = 'derm.address_row_map'::regclass
     AND conname = 'address_row_map_band_needs_stamp_chk' AND NOT convalidated;
  IF v_n <> 1 THEN RAISE EXCEPTION 'VERIFY 7 failed: band-needs-stamp check missing or unexpectedly validated'; END IF;

  SELECT count(*) INTO v_n FROM pg_constraint
   WHERE conrelid = 'derm.page_block_extents'::regclass
     AND conname = 'page_block_extents_range_chk' AND convalidated;
  IF v_n <> 1 THEN RAISE EXCEPTION 'VERIFY 7 failed: extent range check missing or not validated'; END IF;

  -- The ticket-833049 freeze must still be there. This migration must not have disturbed it.
  SELECT count(*) INTO v_n FROM pg_constraint
   WHERE conrelid = 'derm.page_block_extents'::regclass
     AND conname = 'page_block_extents_no_ticket_833049';
  IF v_n <> 1 THEN RAISE EXCEPTION 'VERIFY 7 failed: the ticket-833049 freeze is gone'; END IF;

  -- 8. The audit trigger is attached and actually fires.
  SELECT count(*) INTO v_n FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'derm' AND c.relname = 'page_block_extents'
     AND t.tgname = 'audit_page_block_extents' AND NOT t.tgisinternal;
  IF v_n <> 1 THEN RAISE EXCEPTION 'VERIFY 8 failed: audit trigger not attached'; END IF;

  -- 🛑 THE PROBE MUST MAKE A REAL CHANGE. audit.log_change opens with
  --      IF TG_OP = 'UPDATE' AND v_old_clean IS NOT DISTINCT FROM v_new_clean THEN RETURN NEW;
  --    comparing to_jsonb(OLD) - 'updated_at' against to_jsonb(NEW) - 'updated_at'. So a no-op
  --    `SET top_pct = top_pct` correctly writes NOTHING, and an earlier draft of this VERIFY read
  --    that as a broken trigger. Testing an audit trigger with an unchanged value asserts nothing.
  BEGIN
    UPDATE derm.page_block_extents SET top_pct = top_pct + 0.001
     WHERE dump_folder = (SELECT dump_folder FROM derm.page_block_extents ORDER BY dump_folder LIMIT 1);
    SELECT count(*) INTO v_n FROM audit.logs
     WHERE table_schema = 'derm' AND table_name = 'page_block_extents'
       AND changed_at > now() - interval '1 minute';
    IF v_n < 1 THEN
      RAISE EXCEPTION 'VERIFY 8 failed: audit trigger attached but wrote no row for a real change';
    END IF;
    RAISE EXCEPTION 'rollback_probe_8';
  EXCEPTION WHEN others THEN
    IF SQLERRM <> 'rollback_probe_8' THEN RAISE; END IF;
  END;

  -- 8b. CONTROL for 8: a NO-OP update must write NOTHING, which proves the count above came from
  --     our change and not from unrelated traffic landing inside the one-minute window.
  BEGIN
    SELECT count(*) INTO v_n FROM audit.logs
     WHERE table_schema = 'derm' AND table_name = 'page_block_extents';
    UPDATE derm.page_block_extents SET top_pct = top_pct
     WHERE dump_folder = (SELECT dump_folder FROM derm.page_block_extents ORDER BY dump_folder LIMIT 1);
    IF (SELECT count(*) FROM audit.logs
         WHERE table_schema = 'derm' AND table_name = 'page_block_extents') <> v_n THEN
      RAISE EXCEPTION 'VERIFY 8b failed: a no-op update wrote an audit row';
    END IF;
    RAISE EXCEPTION 'rollback_probe_8b';
  EXCEPTION WHEN others THEN
    IF SQLERRM <> 'rollback_probe_8b' THEN RAISE; END IF;
  END;

  -- 9. The range check on extents actually bites.
  v_raised := false;
  BEGIN
    UPDATE derm.page_block_extents SET bottom_pct = top_pct - 1
     WHERE dump_folder = (SELECT dump_folder FROM derm.page_block_extents ORDER BY dump_folder LIMIT 1);
  EXCEPTION WHEN others THEN v_raised := true;
  END;
  IF NOT v_raised THEN
    RAISE EXCEPTION 'VERIFY 9 failed: extent range check does not bite';
  END IF;

  -- 10. derm._actor returns the default when there is no PostgREST context (which is how the
  --     Management API and every script call it).
  v_actor := derm._actor('sentinel-default');
  IF v_actor <> 'sentinel-default' THEN
    RAISE EXCEPTION 'VERIFY 10 failed: _actor returned % with no JWT context', v_actor;
  END IF;

  -- 11. NOTHING MOVED. This migration is guards-only, so the band and extent estates must be
  --     byte-identical to the pre-flight census taken at 2026-08-26 18:xx ET.
  SELECT count(*) INTO v_n FROM derm.address_row_map WHERE band_y0_pct IS NOT NULL;
  IF v_n <> 641 THEN RAISE EXCEPTION 'VERIFY 11 failed: banded rows moved from 641 to %', v_n; END IF;
  SELECT count(*) INTO v_n FROM derm.page_block_extents;
  IF v_n <> 162 THEN RAISE EXCEPTION 'VERIFY 11 failed: extent rows moved from 162 to %', v_n; END IF;
  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE band_y0_pct IS NOT NULL AND stamp_y_pct IS NULL;
  IF v_n <> 7 THEN RAISE EXCEPTION 'VERIFY 11 failed: legacy band-without-stamp rows moved from 7 to %', v_n; END IF;

  RAISE NOTICE 'VERIFY ok: 12 checks passed, including the old-body control and the no-op audit control. Nothing moved: 641 banded rows, 162 extents, 7 legacy band-without-stamp rows.';
END $do$;

COMMIT;
