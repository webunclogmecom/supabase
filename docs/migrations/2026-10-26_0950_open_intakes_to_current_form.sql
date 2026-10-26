-- ============================================================================
-- 2026-10-26_0950 ONE-TIME: open site survey forms get the current question list (version 6)
-- ============================================================================
-- THE ASK: Fred (2026-10-26), with a screenshot of a new form: "is how the current form looks like, but the old forms
--   doesn't look like that, let's do a one time off change, to update all the forms that hasn't been submitted yet to look
--   like the new forms."
-- WHAT CHANGES (data only, no function): public.property_intakes.form_snapshot and .requested on the 7 forms still OPEN
--   (not submitted, not cancelled, link not expired) whose list is not the current one: 1062, 1063, 1064, 1065, 1066, 1069
--   (version 3) and 1073 (version 4). 1122 already carries the current list. The 20 cancelled forms are left as sent (their
--   link is dead). The immutability trigger only freezes a SUBMITTED form, so nothing is bypassed.
-- THE REQUESTED RULE: every key the office chose stays, follow-ups it left out on purpose stay out (e.g. a code already on
--   file); the only additions are keys that did not exist on the form's own list, and only when their top-level question was
--   asked (for every form here: grease_trap.size_from, grease_trap.model and the 40 grease_trap.t<N>.* keys, because
--   "How many grease trap systems?" was asked); then public.fn_intake_normalise_requested, as at scheduling.
-- Answers: none are stored on these forms (they stay on the collector's phone until Submit). Photos already attached (1063: 2,
--   1073: 1) keep their question keys, which all stay requested (keys are append-only).
-- BACKUP: workspace backups/2026-10-26_open_intakes_before_form_v6_upgrade.json (and audit.logs old_row, token redacted).
-- ROLLBACK: put each row's form_snapshot and requested back from that file (restore_hint inside it).
-- RULE 8: no table. This is a deliberate one-time upgrade, not a rule: forms sent from now on already carry the current list.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $g$ BEGIN
  IF md5(pg_get_functiondef('public.fn_intake_form_current'::regproc)) IS DISTINCT FROM 'e96833042f96615056c9d20ae2a3f200' THEN
    RAISE EXCEPTION 'fn_intake_form_current changed since this file was written: build again';
  END IF;
END $g$;
-- shared by the dry run and the migration: one row per open form whose question list is not the current one
CREATE TEMP TABLE up_targets ON COMMIT DROP AS
SELECT i.id, i.form_snapshot AS old_s, i.requested AS old_r, public.fn_intake_form_current() AS new_s
  FROM public.property_intakes i
 WHERE i.submitted_at IS NULL AND i.cancelled_at IS NULL AND i.expires_at > now()
   AND i.form_snapshot IS DISTINCT FROM public.fn_intake_form_current();

-- every key of the new list with its top-level ancestor (walk the show_if parents)
CREATE TEMP TABLE up_keys ON COMMIT DROP AS
WITH RECURSIVE k AS (
  SELECT q ->> 'key' AS key FROM jsonb_path_query(public.fn_intake_form_current(), '$.sections[*].questions[*]') q
), walk AS (
  SELECT key, key AS cur, 0 AS depth FROM k
  UNION ALL
  SELECT w.key, public.fn_intake_parent_key(public.fn_intake_form_current(), w.cur), w.depth + 1
    FROM walk w
   WHERE w.depth < 10 AND public.fn_intake_parent_key(public.fn_intake_form_current(), w.cur) IS NOT NULL
)
SELECT DISTINCT ON (key) key, cur AS top FROM walk ORDER BY key, depth DESC;

-- the new requested set per form: the office's own choices kept exactly, plus the keys that did not exist on the
-- form's list whose top-level question was asked; then the usual normalisation (prune / add a kept optional's alternative)
CREATE TEMP TABLE up_plan ON COMMIT DROP AS
SELECT t.id, t.old_s, t.old_r, t.new_s,
       ARRAY(SELECT x FROM jsonb_array_elements_text(t.old_r) x) AS old_keys,
       ARRAY(SELECT k.key FROM up_keys k
              WHERE NOT EXISTS (SELECT 1 FROM jsonb_path_query(t.old_s, '$.sections[*].questions[*].key') ok WHERE ok #>> '{}' = k.key)
                AND t.old_r ? k.top) AS added
  FROM up_targets t;

CREATE TEMP TABLE up_final ON COMMIT DROP AS
SELECT p.*, public.fn_intake_normalise_requested(p.new_s, p.old_keys || p.added) AS new_keys FROM up_plan p;

DO $t$ BEGIN
  IF (SELECT array_agg(id ORDER BY id) FROM up_final) IS DISTINCT FROM ARRAY[1062,1063,1064,1065,1066,1069,1073]::bigint[] THEN
    RAISE EXCEPTION 'the open forms changed since the dry run: %', (SELECT array_agg(id ORDER BY id) FROM up_final);
  END IF;
END $t$;
CREATE TEMP TABLE up_before ON COMMIT DROP AS SELECT id, updated_at FROM public.property_intakes;

UPDATE public.property_intakes i
   SET form_snapshot = f.new_s, requested = to_jsonb(f.new_keys)
  FROM up_final f
 WHERE i.id = f.id AND i.submitted_at IS NULL AND i.cancelled_at IS NULL;

DO $v$
DECLARE n int;
BEGIN
  -- V1 exactly the 7 forms moved, nothing else
  SELECT count(*) INTO n FROM public.property_intakes i JOIN up_before b ON b.id = i.id WHERE i.updated_at IS DISTINCT FROM b.updated_at;
  IF n <> 7 THEN RAISE EXCEPTION 'V1: % rows changed, expected 7', n; END IF;
  -- V2 each now carries the current list, is still open, and holds the planned requested set
  IF EXISTS (SELECT 1 FROM up_final f JOIN public.property_intakes i ON i.id = f.id
              WHERE i.form_snapshot IS DISTINCT FROM public.fn_intake_form_current() OR i.submitted_at IS NOT NULL
                 OR i.requested IS DISTINCT FROM to_jsonb(f.new_keys)) THEN RAISE EXCEPTION 'V2: a form is not as planned'; END IF;
  -- V3 nothing the office chose was dropped; every addition is a key the old list did not have
  IF EXISTS (SELECT 1 FROM up_final f, unnest(f.old_keys) k WHERE NOT k = ANY (f.new_keys)) THEN RAISE EXCEPTION 'V3: an office choice was dropped'; END IF;
  IF EXISTS (SELECT 1 FROM up_final f, unnest(f.new_keys) k WHERE NOT k = ANY (f.old_keys)
              AND EXISTS (SELECT 1 FROM jsonb_path_query(f.old_s, '$.sections[*].questions[*].key') ok WHERE ok #>> '{}' = k)) THEN
    RAISE EXCEPTION 'V3: an old key the office left out was added';
  END IF;
  -- V4 every live photo still belongs to a requested question
  IF EXISTS (SELECT 1 FROM public.photo_links pl JOIN public.property_intakes i ON i.id = pl.entity_id
              WHERE pl.entity_type = 'property_intake' AND pl.deleted_at IS NULL AND i.id IN (SELECT id FROM up_final)
                AND NOT i.requested ? pl.role) THEN RAISE EXCEPTION 'V4: a photo lost its question'; END IF;
  -- V5 the requested set normalises to itself (what scheduling would store)
  IF EXISTS (SELECT 1 FROM public.property_intakes i WHERE i.id IN (SELECT id FROM up_final)
              AND cardinality(public.fn_intake_normalise_requested(i.form_snapshot, ARRAY(SELECT x FROM jsonb_array_elements_text(i.requested) x)))
                  <> jsonb_array_length(i.requested)) THEN RAISE EXCEPTION 'V5: requested does not normalise to itself'; END IF;
END $v$;

COMMIT;
