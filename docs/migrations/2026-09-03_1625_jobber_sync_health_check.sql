-- 2026-09-03_1625_jobber_sync_health_check.sql
--
-- WHAT: public.log_jobber_sync_health(), registered as the health check 'jobber-sync-health',
--       plus a daily cron. It reports three things about the ONLY genuinely two-way sync we have
--       (the property Grease Trap size and Lock Box key):
--         shadow_conflict        both sides changed and the sync correctly refused to guess
--         outbound_stuck         a push to Jobber failed, or has sat unprocessed
--         outbound_skipped_clear someone emptied a field here and Jobber still holds the old value
--
-- WHY:  Fred, 2026-09-03: *"we need for them to be Two-way"*, after an audit found only 2 of ~36
--       app/Jobber field groups are. The first defect is not in the 34: it is that the 2 that DO
--       work fail in silence at the last step.
--
--       Measured before writing this: NO view anywhere reads sync.source_field_shadow (only three
--       functions touch it, all writers), and the only view reading sync.outbound_queue is
--       sync.v_outbound_queue_health, which nothing reads either. A conflict HAS fired once
--       (conflict_count > 0 on one row) and nobody was told. So the mechanism detects a collision
--       correctly and then goes quiet, which satisfies "detected" and fails Fred's own
--       "no silent loser" test at the final step.
--
-- 🛑 WHY THIS IS FIRST, AND WHY IT WRITES NOTHING. This is a pure detector: no business table is
--    touched, no Jobber call is made, no app changes. It is also the template every later drift
--    check will copy, so it should be honest before it is copied. Increments 2+ (drift over the
--    already-staged raw.jobber_pull_* payloads, then widening the poll for job billing settings
--    and users) add ITEM KINDS to this same check and need no re-registration.
--
-- 🛑 A NEW CHECK MUST BE REGISTERED AT FIVE LITERAL SITES OR IT CONTRIBUTES NOTHING WHILE LOOKING
--    ALIVE. Read off the live definitions, not from memory:
--      ops.v_health_items   (1) the sync_source = ANY (ARRAY[...]) in the `latest` CTE
--                           (2) the CASE la.sync_source that picks the details key
--      ops.v_health_status  (3) the CASE l.sync_source ... AS raw_items in `runs`
--                           (4) the sync_source = ANY (ARRAY[...]) in `runs`
--                           (5) the sync_source = ANY (ARRAY[...]) in the `streak` subquery
--    Both views are replaced below with their EXACT current bodies (from pg_get_viewdef) plus the
--    new arm. Column lists are unchanged, so this is a true CREATE OR REPLACE and grants survive.
--
-- ⚠ ITEM SHAPE. ops.v_health_items derives item_key as
--   COALESCE(item->>'visit_id', item->>'dump_folder', item->>'kind', item->>'client_code', item::text).
--   These items have no visit or folder, so `kind` is the key, and it therefore has to be UNIQUE
--   PER ITEM, not a category label: two conflicting properties must not collapse to one alert.
--   Hence 'shadow_conflict:property:32:Grease Trap size'. health_alert_state keys on
--   (check_name, item_key), so a non-unique kind would silently dedup two real problems into one.
--   The human sentence goes in `reason`, which health-escalate renders inline (verified in that
--   function: it does add(it.client); add(it.client_code); add(it.issue); add(it.reason)).
--
-- RULE 8 (audit): no table or column changes. A function, two view replacements, one cron.
-- RULE 2/3: nothing stored or copied. Every item is derived on read from sync.* .
-- RULE 6: no deletes.

BEGIN;

-- ---------------------------------------------------------------------------------------------
-- PART 1. The check
-- ---------------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.log_jobber_sync_health()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'sync', 'pg_temp'
AS $function$
declare
  v_items    jsonb := '[]'::jsonb;
  v_conflict int := 0;
  v_stuck    int := 0;
  v_skipped  int := 0;
  v_total    int := 0;
begin
  -- 1. A conflict the sync recorded and nobody has decided. This is the whole point of the
  --    mechanism: both sides moved, so it refused to guess. Refusing to guess is correct;
  --    refusing to guess in silence is the defect.
  with c as (
    select jsonb_build_object(
             'kind',   'shadow_conflict:' || s.entity_type || ':' || s.entity_id::text || ':' || coalesce(s.field_label, s.field_key),
             'issue',  'shadow_conflict',
             'reason', 'Both we and Jobber changed ' || coalesce(s.field_label, s.field_key) ||
                       ' on ' || s.entity_type || ' ' || s.entity_id::text ||
                       ' since the last sync, so neither value was copied. Ours reads ' ||
                       coalesce(s.conflict_our_value #>> '{}', 'null') || ', Jobber reads ' ||
                       coalesce(s.conflict_source_value #>> '{}', 'null') ||
                       '. Nothing is blocked and the app still works; the two systems will simply stay '
                       'different until someone makes them agree, which releases it automatically.',
             'entity_type',   s.entity_type,
             'entity_id',     s.entity_id,
             'field',         coalesce(s.field_label, s.field_key),
             'our_value',     s.conflict_our_value,
             'jobber_value',  s.conflict_source_value,
             'conflict_at',   s.conflict_at,
             'conflict_count', s.conflict_count) as item
      from sync.source_field_shadow s
     where s.conflict_at is not null
  )
  select coalesce(jsonb_agg(item), '[]'::jsonb), count(*) into v_items, v_conflict from c;

  -- 2. A push to Jobber that did not land. Deliberately NOT keyed on one status string: the only
  --    status this table has ever held is 'done', so hard-coding a failure name would be guessing
  --    at a value that has never occurred. Anything that is neither done nor a deliberate skip and
  --    is older than 30 minutes has missed 15 cycles of a */2 cron, and anything carrying an error
  --    or 3+ attempts is reported whatever its status says.
  with q as (
    select jsonb_build_object(
             'kind',   'outbound_stuck:' || o.id::text,
             'issue',  'outbound_stuck',
             'reason', 'A ' || coalesce(o.field_label, o.field_key) || ' change for ' || o.entity_type ||
                       ' ' || o.entity_id::text || ' has not reached Jobber. Status ' || o.status ||
                       ', ' || o.attempts::text || ' attempt(s), queued ' ||
                       round(extract(epoch from (now() - o.created_at)) / 60.0)::text || ' minutes ago' ||
                       case when o.last_error is not null then '. Last error: ' || left(o.last_error, 200) else '' end ||
                       '. Jobber still holds the old value.',
             'queue_id',    o.id,
             'entity_type', o.entity_type,
             'entity_id',   o.entity_id,
             'field',       coalesce(o.field_label, o.field_key),
             'status',      o.status,
             'attempts',    o.attempts,
             'last_error',  o.last_error,
             'queued_minutes', round(extract(epoch from (now() - o.created_at)) / 60.0)) as item
      from sync.outbound_queue o
     where o.status not in ('done', 'skipped')
       and ( o.created_at < now() - interval '30 minutes'
             or o.last_error is not null
             or coalesce(o.attempts, 0) >= 3 )
  )
  select v_items || coalesce(jsonb_agg(item), '[]'::jsonb), count(*) into v_items, v_stuck from q;

  -- 3. A deliberate skip that a person still needs to know about. Clearing a lock box here does
  --    NOT blank it in Jobber (blanking a field from an unattended process is the most destructive
  --    write this path can make), so the driver keeps seeing a code that no longer applies. The
  --    row is recorded as skipped rather than dropped precisely so it can be surfaced here.
  with s as (
    select jsonb_build_object(
             'kind',   'outbound_skipped_clear:' || o.id::text,
             'issue',  'outbound_skipped_clear',
             'reason', coalesce(o.field_label, o.field_key) || ' was CLEARED here for ' || o.entity_type ||
                       ' ' || o.entity_id::text || ', and a clear is deliberately never pushed, so '
                       'Jobber still shows the old value to a driver. Clear it in Jobber too, or put '
                       'the value back here.',
             'queue_id',    o.id,
             'entity_type', o.entity_type,
             'entity_id',   o.entity_id,
             'field',       coalesce(o.field_label, o.field_key),
             'skipped_at',  o.processed_at) as item
      from sync.outbound_queue o
     where o.status = 'skipped'
  )
  select v_items || coalesce(jsonb_agg(item), '[]'::jsonb), count(*) into v_items, v_skipped from s;

  v_total := v_conflict + v_stuck + v_skipped;

  -- 🛑 clock_timestamp(), NOT now(). now() is the TRANSACTION timestamp, so two runs inside one
  --    transaction get identical started_at values and ops.v_health_items' DISTINCT ON ... ORDER BY
  --    started_at DESC ties between them, silently returning the wrong run. That is not theoretical:
  --    this migration's own positive control hit it and reported "the conflict did not reach
  --    ops.v_health_items", which reads exactly like a missed registration site. The siblings use
  --    now() only because cron calls them once per transaction. The ordering key has to be able to
  --    tell two runs apart.
  insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
  values ('jobber-sync-health', clock_timestamp(), clock_timestamp(), v_total,
          case when v_total > 0 then 'attention' else 'ok' end,
          jsonb_build_object(
            'shadow_conflicts',       v_conflict,
            'outbound_stuck',         v_stuck,
            'outbound_skipped_clear', v_skipped,
            'items',                  v_items,
            -- Coverage is stated on every run so a clean verdict can never be read as
            -- "the whole Jobber sync is healthy". It is not: it is two fields.
            'covers', 'ONLY the two genuinely two-way fields (property Grease Trap size, Lock Box key). '
                      'It says NOTHING about the ~34 other app/Jobber field groups, which have no '
                      'conflict detection at all - see docs/audits/2026-09-03_jobber_two_way_authority_audit.md.',
            'what_it_means', case when v_total > 0
              then 'Something in the two-way sync needs a person. A shadow_conflict means both sides '
                   'changed and neither value was copied - nothing is blocked, the app works, the two '
                   'systems just stay different until someone makes them agree. An outbound_stuck '
                   'means a change made here never reached Jobber. An outbound_skipped_clear means a '
                   'field was emptied here and Jobber still shows the old value.'
              else 'No unresolved conflicts, no stuck pushes, no skipped clears on the two two-way fields.' end));

  return v_total;
end $function$;

COMMENT ON FUNCTION public.log_jobber_sync_health() IS
  'Health check for the property custom-field two-way sync: unresolved shadow conflicts, pushes that never reached Jobber, and deliberate clears Jobber never received. Read-only. Registered as check_name jobber-sync-health at five sites across ops.v_health_items and ops.v_health_status. Covers ONLY the two two-way fields, which is stated in every run under details.covers.';

REVOKE ALL ON FUNCTION public.log_jobber_sync_health() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.log_jobber_sync_health() TO service_role;

-- ---------------------------------------------------------------------------------------------
-- PART 2. Registration, sites 1 and 2. Body is the exact pg_get_viewdef output plus the new arm.
-- ---------------------------------------------------------------------------------------------

CREATE OR REPLACE VIEW ops.v_health_items AS
 WITH latest AS (
         SELECT DISTINCT ON (l.sync_source) l.sync_source,
            l.status,
            l.started_at,
            l.details
           FROM sync_log l
          WHERE l.sync_source = ANY (ARRAY['calendar-push-health'::text, 'blackout-health'::text, 'rpa-derm-health'::text, 'sa-schedule-gap-check'::text, 'jobber-sync-health'::text])
          ORDER BY l.sync_source, l.started_at DESC
        )
 SELECT la.sync_source AS check_name,
    la.status,
    la.started_at AS last_run_at,
    COALESCE(i.value ->> 'visit_id'::text, i.value ->> 'dump_folder'::text, i.value ->> 'kind'::text, i.value ->> 'client_code'::text, i.value::text) AS item_key,
    i.value AS item
   FROM latest la
     CROSS JOIN LATERAL jsonb_array_elements(
        CASE la.sync_source
            WHEN 'calendar-push-health'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            WHEN 'blackout-health'::text THEN COALESCE(la.details -> 'sheets'::text, '[]'::jsonb)
            WHEN 'rpa-derm-health'::text THEN COALESCE(la.details -> 'reasons'::text, '[]'::jsonb)
            WHEN 'sa-schedule-gap-check'::text THEN COALESCE(la.details -> 'sample'::text, '[]'::jsonb)
            WHEN 'jobber-sync-health'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            ELSE '[]'::jsonb
        END) i(value);

-- ---------------------------------------------------------------------------------------------
-- PART 3. Registration, sites 3, 4 and 5.
-- ---------------------------------------------------------------------------------------------

CREATE OR REPLACE VIEW ops.v_health_status AS
 WITH runs AS (
         SELECT l.id,
            l.sync_source,
            l.status,
            l.started_at,
            l.rows_errored,
            l.details,
            row_number() OVER (PARTITION BY l.sync_source ORDER BY l.started_at DESC) AS rn,
                CASE l.sync_source
                    WHEN 'calendar-push-health'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    WHEN 'blackout-health'::text THEN COALESCE(l.details -> 'sheets'::text, '[]'::jsonb)
                    WHEN 'rpa-derm-health'::text THEN COALESCE(l.details -> 'reasons'::text, '[]'::jsonb)
                    WHEN 'sa-schedule-gap-check'::text THEN COALESCE(l.details -> 'sample'::text, '[]'::jsonb)
                    WHEN 'jobber-sync-health'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    ELSE '[]'::jsonb
                END AS raw_items
           FROM sync_log l
          WHERE l.sync_source = ANY (ARRAY['calendar-push-health'::text, 'blackout-health'::text, 'rpa-derm-health'::text, 'sa-schedule-gap-check'::text, 'jobber-sync-health'::text])
        ), keyed AS (
         SELECT r.id,
            r.sync_source,
            r.status,
            r.started_at,
            r.rows_errored,
            r.details,
            r.rn,
            r.raw_items,
            COALESCE(( SELECT jsonb_agg(DISTINCT COALESCE(i.value ->> 'visit_id'::text, i.value ->> 'dump_folder'::text, i.value ->> 'kind'::text, i.value ->> 'client_code'::text, i.value::text)) AS jsonb_agg
                   FROM jsonb_array_elements(r.raw_items) i(value)), '[]'::jsonb) AS item_keys
           FROM runs r
          WHERE r.rn <= 2
        ), streak AS (
         SELECT g.sync_source,
            g.status,
            count(*) AS runs_in_streak,
            min(g.started_at) AS streak_started_at
           FROM ( SELECT l.sync_source,
                    l.status,
                    l.started_at,
                    row_number() OVER (PARTITION BY l.sync_source ORDER BY l.started_at DESC) - row_number() OVER (PARTITION BY l.sync_source, l.status ORDER BY l.started_at DESC) AS grp
                   FROM sync_log l
                  WHERE l.sync_source = ANY (ARRAY['calendar-push-health'::text, 'blackout-health'::text, 'rpa-derm-health'::text, 'sa-schedule-gap-check'::text, 'jobber-sync-health'::text])) g
          GROUP BY g.sync_source, g.status, g.grp
         HAVING max(g.started_at) = (( SELECT max(l2.started_at) AS max
                   FROM sync_log l2
                  WHERE l2.sync_source = g.sync_source))
        ), cur AS (
         SELECT keyed.id,
            keyed.sync_source,
            keyed.status,
            keyed.started_at,
            keyed.rows_errored,
            keyed.details,
            keyed.rn,
            keyed.raw_items,
            keyed.item_keys
           FROM keyed
          WHERE keyed.rn = 1
        ), prev AS (
         SELECT keyed.id,
            keyed.sync_source,
            keyed.status,
            keyed.started_at,
            keyed.rows_errored,
            keyed.details,
            keyed.rn,
            keyed.raw_items,
            keyed.item_keys
           FROM keyed
          WHERE keyed.rn = 2
        )
 SELECT c.sync_source AS check_name,
    c.status,
    c.started_at AS last_run_at,
    jsonb_array_length(c.item_keys) AS item_count,
    COALESCE(jsonb_array_length(p.item_keys), 0) AS item_count_previous_run,
    c.rows_errored AS rows_errored_raw,
    ( SELECT COALESCE(jsonb_agg(k.value), '[]'::jsonb) AS "coalesce"
           FROM jsonb_array_elements(c.item_keys) k(value)
          WHERE NOT COALESCE(p.item_keys, '[]'::jsonb) @> jsonb_build_array(k.value)) AS new_items,
    ( SELECT COALESCE(jsonb_agg(k.value), '[]'::jsonb) AS "coalesce"
           FROM jsonb_array_elements(COALESCE(p.item_keys, '[]'::jsonb)) k(value)
          WHERE NOT c.item_keys @> jsonb_build_array(k.value)) AS resolved_items,
    c.item_keys = COALESCE(p.item_keys, '[]'::jsonb) AS unchanged_since_last_run,
    s.runs_in_streak AS consecutive_runs_same_status,
    s.streak_started_at AS status_since,
    c.details
   FROM cur c
     LEFT JOIN prev p ON p.sync_source = c.sync_source
     LEFT JOIN streak s ON s.sync_source = c.sync_source AND s.status = c.status;

-- ---------------------------------------------------------------------------------------------
-- PART 4. VERIFY
--
-- 🛑 THE POSITIVE CONTROL IS THE POINT OF THIS BLOCK. A check that reports zero on a clean estate
--    is indistinguishable from a check wired to nothing, and this estate has shipped that defect
--    repeatedly. So the control MANUFACTURES a conflict and a stuck push, asserts both surface
--    through BOTH views, and then rolls that away inside a subtransaction so no fake alert and no
--    fake sync_log row survives.
-- ---------------------------------------------------------------------------------------------

DO $$
DECLARE
  v_n int; v_status text; v_items int; v_key text; v_probe_id bigint;
BEGIN
  -- 1. A clean run happens and reports nothing. This is the NEGATIVE control.
  v_n := public.log_jobber_sync_health();
  SELECT status, jsonb_array_length(details -> 'items')
    INTO v_status, v_items
    FROM public.sync_log WHERE sync_source = 'jobber-sync-health'
   ORDER BY started_at DESC LIMIT 1;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: the check wrote no sync_log row';
  END IF;
  RAISE NOTICE 'VERIFY 1 ok: clean run -> % item(s), status %', v_items, v_status;

  -- 2. It is visible in BOTH views. Registration at all five sites is what this proves.
  IF NOT EXISTS (SELECT 1 FROM ops.v_health_status WHERE check_name = 'jobber-sync-health') THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: jobber-sync-health missing from ops.v_health_status - a registration site was missed';
  END IF;

  -- 3. THE POSITIVE CONTROL, in a subtransaction that is always rolled back.
  BEGIN
    -- manufacture one conflict on a real shadow row
    UPDATE sync.source_field_shadow
       SET conflict_at = now(),
           conflict_our_value = '"PROBE-OURS"'::jsonb,
           conflict_source_value = '"PROBE-THEIRS"'::jsonb
     WHERE ctid = (SELECT ctid FROM sync.source_field_shadow ORDER BY entity_id LIMIT 1);
    IF NOT FOUND THEN RAISE EXCEPTION 'CONTROL SETUP FAILED: no shadow row to probe'; END IF;

    -- manufacture one stuck push
    INSERT INTO sync.outbound_queue
      (entity_type, entity_id, source_system, field_key, field_label, desired_value, status, attempts, created_at, updated_at)
    VALUES ('property', -1, 'jobber', 'probe', 'PROBE FIELD', '"x"'::jsonb, 'pending', 0,
            now() - interval '90 minutes', now())
    RETURNING id INTO v_probe_id;

    v_n := public.log_jobber_sync_health();
    IF v_n < 2 THEN
      RAISE EXCEPTION 'CONTROL FAILED: manufactured 1 conflict + 1 stuck push, the check reported % item(s)', v_n;
    END IF;

    -- it must reach ops.v_health_items, which proves sites 1 and 2
    SELECT item_key INTO v_key FROM ops.v_health_items
     WHERE check_name = 'jobber-sync-health' AND item ->> 'issue' = 'shadow_conflict' LIMIT 1;
    IF v_key IS NULL THEN
      RAISE EXCEPTION 'CONTROL FAILED: the conflict did not reach ops.v_health_items (site 1 or 2 missed)';
    END IF;

    -- and ops.v_health_status must count it, which proves sites 3, 4 and 5
    SELECT item_count, status INTO v_items, v_status FROM ops.v_health_status
     WHERE check_name = 'jobber-sync-health';
    IF coalesce(v_items, 0) < 2 OR v_status <> 'attention' THEN
      RAISE EXCEPTION 'CONTROL FAILED: ops.v_health_status shows % item(s), status % (sites 3-5)', v_items, v_status;
    END IF;

    -- item_key must be UNIQUE per item, or two real problems dedup into one alert
    IF (SELECT count(DISTINCT item_key) FROM ops.v_health_items WHERE check_name = 'jobber-sync-health')
       <> (SELECT count(*) FROM ops.v_health_items WHERE check_name = 'jobber-sync-health') THEN
      RAISE EXCEPTION 'CONTROL FAILED: item_key is not unique per item';
    END IF;

    RAISE NOTICE 'VERIFY 3 ok: control fired - % items surfaced through both views, sample key %', v_items, v_key;
    RAISE EXCEPTION 'ROLLBACK_CONTROL';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM <> 'ROLLBACK_CONTROL' THEN RAISE; END IF;
  END;

  -- 4. The probe is gone: no fake conflict, no fake queue row, no fake alert.
  IF EXISTS (SELECT 1 FROM sync.source_field_shadow WHERE conflict_our_value = '"PROBE-OURS"'::jsonb)
     OR EXISTS (SELECT 1 FROM sync.outbound_queue WHERE field_key = 'probe') THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: the control did not roll back';
  END IF;

  -- 5. Leave a genuine, clean baseline row as the last word.
  v_n := public.log_jobber_sync_health();
  IF v_n <> 0 THEN
    RAISE WARNING 'jobber-sync-health reports % real item(s) right now - that is a finding, not a failure', v_n;
  END IF;

  RAISE NOTICE 'OK: jobber-sync-health registered at all five sites, control proven to fire and to roll back.';
END $$;

-- ---------------------------------------------------------------------------------------------
-- PART 5. Cron. INSIDE the transaction: cron.schedule writes an ordinary row in cron.job, so it
-- rolls back with everything else and the migration stays atomic. 13:13 UTC = 09:13 ET, ahead of
-- the 13:30 UTC health escalation so that reads a fresh verdict, and on an odd minute so it does
-- not undo the 2026-09-03 re-phasing that pulled the per-minute cron peak down.
-- ---------------------------------------------------------------------------------------------

SELECT cron.schedule('jobber-sync-health', '13 13 * * *', $cron$SELECT public.log_jobber_sync_health()$cron$);

DO $$
DECLARE v_sched text;
BEGIN
  SELECT schedule INTO v_sched FROM cron.job WHERE jobname = 'jobber-sync-health';
  IF v_sched IS DISTINCT FROM '13 13 * * *' THEN
    RAISE EXCEPTION 'VERIFY 6 FAILED: cron jobber-sync-health reads %, expected 13 13 * * *', coalesce(v_sched, '(absent)');
  END IF;
  RAISE NOTICE 'VERIFY 6 ok: cron jobber-sync-health scheduled 13 13 * * * (09:13 ET).';
END $$;

COMMIT;
