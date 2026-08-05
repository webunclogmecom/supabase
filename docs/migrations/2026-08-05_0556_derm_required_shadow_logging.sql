-- 2026-08-05_0556_derm_required_shadow_logging.sql
--
-- DERM manual-lock remediation, step 3a: OBSERVABILITY ONLY. Strictly additive.
-- Nothing about which writes are accepted changes. No existing object is modified.
--
-- WHY THIS EXISTS
-- ---------------
-- fn_lock_manual_derm_required silently discards an automated writer's change to a locked
-- derm_required value. Measured (@Supabase, rolled back, with a positive control):
--
--     visit 1240 locked, non-derm origin, false -> true : stored stayed FALSE, audit.logs rows 0
--     visit 1241 unlocked, CONTROL                      : stored became TRUE,  audit.logs rows 1
--
-- audit.log_change compares to_jsonb(OLD) - 'updated_at' against to_jsonb(NEW) - 'updated_at'
-- and returns early when they match, so a fully-reverted write produces NO audit row at all.
-- The discard is invisible. That is what this table exists to make visible.
--
-- 🛑 THE SPEC POINT THAT MATTERS MOST (@Supabase, and it is the reason this is not trivial):
-- LOGGING ONLY TODAY'S REJECTIONS WOULD BE STRUCTURALLY BLIND TO THE CLASS STEP 3 CREATES.
-- The trigger is `IF v_is_derm ... ELSIF ...`, i.e. mutually exclusive, so a derm-context
-- write NEVER reaches the reverting leg today. Removing the arm branch in step 3 promotes
-- that leg from "non-derm writers only" to "ALL writers". Measured on a scratch table with a
-- real BEFORE UPDATE OF trigger, current body as the positive control:
--
--     derm-origin direct write, LOCKED row, requesting TRUE
--       CURRENT body     -> value TRUE   (accepted)
--       POST-STEP-3 body -> value FALSE  (SILENTLY REVERTED)
--     derm-origin direct write, UNLOCKED row
--       CURRENT          -> lock armed true
--       POST-STEP-3      -> lock false   (intended)
--     RPC 3-statement pattern, LOCKED row, POST-STEP-3 -> value TRUE (RPC unaffected)
--
-- So a logger that recorded only what is discarded TODAY would sit at zero right up until we
-- opened the window, and its silence would be read as safety. That is the
-- "audit.logs records successes" trap in a new costume (root CLAUDE.md 5.5(b), third trap).
--
-- ⇒ THIS LOGS THE SHADOW: every write that WOULD be discarded under the post-step-3 body,
--   regardless of origin, while the current body is still in force. `is_derm_context` marks
--   which ones are only-later-affected.
--
--     is_derm_context = false -> discarded TODAY (already broken, not a new break)
--     is_derm_context = true  -> ACCEPTED today, WOULD BE DISCARDED after step 3
--
-- ⇒ THE GATE FOR STEP 3 BECOMES EVIDENTIAL RATHER THAN A WAITING PERIOD:
--   remove the arm branch only once the is_derm_context = true count has stayed at ZERO
--   across a representative period of real usage. Non-zero means live traffic exists that
--   step 3 would break, and we learn it BEFORE breaking it.
--
-- DESIGN NOTES
-- ------------
-- 1. SEPARATE TRIGGER, not an edit to fn_lock_manual_derm_required. Additivity is then true
--    by construction rather than by review: this function never assigns to NEW.
-- 2. 🛑 THE TRIGGER NAME IS LOAD-BEARING. Triggers fire in ALPHABETICAL order, and
--    `trg_aa_derm_required_shadow` < `trg_derm_required_lock`, so this observes the CALLER'S
--    INTENT. If it fired after the lock trigger, NEW.derm_required would already equal
--    OLD.derm_required and the condition would never match - it would log ZERO forever and
--    look healthy. Do not rename it to anything sorting after `trg_derm...`.
-- 3. The INSERT is exception-wrapped. A logging failure must NEVER abort the caller's write
--    on a regulated column.
-- 4. NO DUPLICATED app_source CASE. audit.log_change resolves app_source from a 14-branch
--    Origin CASE that this repo has watched go stale twice (Admin Review 2026-07-03..29, and
--    stamp.unclogme.app). Duplicating it here would create a second thing to forget. The raw
--    inputs are stored instead - x_app_source_header, origin, and the full request_context -
--    so resolution happens at read time against whatever the mapping is then.
-- 5. The RPCs correctly produce NO rows here: set_visit(s)_derm_required_manual clear the lock
--    in statement 1, so by statement 2 OLD.derm_required_locked is already false and this
--    condition cannot match. That is the intended signal, not a blind spot - the sanctioned
--    path is not a rejection, and it does not depend on the arm branch (B3 above).
--
-- AUDIT (rule 8): OPT-OUT, deliberate. This is an append-only machine-written observability
-- table with no human-editable fields; putting audit.log_change on it would log the logger.
-- It touches no customer.*, billing, DERM-compliance or webhook-secret data - it records
-- REJECTED write attempts against public.visits, which is itself audited.
--
-- GRANTS: service_role read only. Explicitly revoked from anon/authenticated/PUBLIC because
-- Supabase's ALTER DEFAULT PRIVILEGES hands out grants nobody wrote, and note that
-- audit.logs already carries a SELECT grant to authenticated, so this schema is reachable.
-- request_context can carry request headers, so it does not go to app roles.
--
-- ROLLBACK:
--   DROP TRIGGER IF EXISTS trg_aa_derm_required_shadow ON public.visits;
--   DROP FUNCTION IF EXISTS audit.fn_log_derm_required_shadow();
--   DROP VIEW IF EXISTS audit.v_derm_required_shadow;
--   DROP TABLE IF EXISTS audit.derm_required_write_shadow;

CREATE TABLE IF NOT EXISTS audit.derm_required_write_shadow (
  id                     bigserial PRIMARY KEY,
  occurred_at            timestamptz NOT NULL DEFAULT now(),
  visit_id               bigint      NOT NULL,
  attempted_value        boolean,                -- what the caller asked for
  stored_value           boolean,                -- what is on the row (OLD)
  old_lock               boolean,                -- OLD.derm_required_locked
  is_derm_context        boolean     NOT NULL,   -- true => accepted today, discarded after step 3
  x_app_source_header    text,
  origin                 text,
  request_context        jsonb,
  db_role                text,                   -- current_user at write time
  session_role           text,                   -- session_user at write time
  txid                   bigint
);

COMMENT ON TABLE audit.derm_required_write_shadow IS
  'Step 3a observability for the DERM manual lock. One row per write to public.visits.derm_required '
  'that IS (is_derm_context=false) or WOULD BE (is_derm_context=true) discarded by '
  'fn_lock_manual_derm_required. Written by trg_aa_derm_required_shadow, which must keep sorting '
  'BEFORE trg_derm_required_lock. Gate for step 3: is_derm_context=true count stays 0 across real '
  'usage. See 2026-08-05_0556_derm_required_shadow_logging.sql.';

CREATE INDEX IF NOT EXISTS derm_required_write_shadow_derm_ctx_idx
  ON audit.derm_required_write_shadow (is_derm_context, occurred_at DESC);

CREATE OR REPLACE FUNCTION audit.fn_log_derm_required_shadow()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = audit, public, pg_temp
AS $fn$
DECLARE
  v_headers jsonb;
  v_is_derm boolean;
BEGIN
  -- Only the writes the lock mechanism does (or will) discard.
  IF OLD.derm_required_locked IS TRUE
     AND NEW.derm_required IS DISTINCT FROM OLD.derm_required THEN
    BEGIN
      -- same defensive read as fn_lock_manual_derm_required, so a malformed GUC cannot abort
      BEGIN
        v_headers := NULLIF(current_setting('request.headers', true), '')::jsonb;
      EXCEPTION WHEN others THEN
        v_headers := NULL;
      END;

      -- same predicate as fn_lock_manual_derm_required, kept verbatim on purpose
      v_is_derm := (
            NULLIF(v_headers ->> 'x-app-source', '') = 'derm-tracker'
         OR (v_headers ->> 'origin') ILIKE '%derm.unclogme.app%'
      );

      INSERT INTO audit.derm_required_write_shadow (
        visit_id, attempted_value, stored_value, old_lock, is_derm_context,
        x_app_source_header, origin, request_context, db_role, session_role, txid
      ) VALUES (
        OLD.id, NEW.derm_required, OLD.derm_required, OLD.derm_required_locked,
        COALESCE(v_is_derm, false),
        NULLIF(v_headers ->> 'x-app-source', ''), v_headers ->> 'origin', v_headers,
        current_user, session_user, txid_current()
      );
    EXCEPTION WHEN OTHERS THEN
      -- 🛑 Logging must NEVER abort the caller's write. Swallow everything.
      NULL;
    END;
  END IF;

  -- 🛑 NEW is returned untouched. This function must stay strictly additive.
  RETURN NEW;
END
$fn$;

DROP TRIGGER IF EXISTS trg_aa_derm_required_shadow ON public.visits;
CREATE TRIGGER trg_aa_derm_required_shadow
  BEFORE UPDATE OF derm_required ON public.visits
  FOR EACH ROW EXECUTE FUNCTION audit.fn_log_derm_required_shadow();

-- Read surface. The interpretation lives here rather than in a stored column, so it can be
-- restated after step 3 ships without rewriting history (rule 2/3: do not store what derives).
CREATE OR REPLACE VIEW audit.v_derm_required_shadow AS
SELECT s.*,
       s.is_derm_context       AS would_break_after_step3,
       NOT s.is_derm_context   AS discarded_today
  FROM audit.derm_required_write_shadow s;

REVOKE ALL ON audit.derm_required_write_shadow FROM PUBLIC, anon, authenticated;
REVOKE ALL ON audit.v_derm_required_shadow     FROM PUBLIC, anon, authenticated;
GRANT SELECT ON audit.derm_required_write_shadow TO service_role;
GRANT SELECT ON audit.v_derm_required_shadow     TO service_role;
REVOKE ALL ON FUNCTION audit.fn_log_derm_required_shadow() FROM PUBLIC, anon, authenticated;
