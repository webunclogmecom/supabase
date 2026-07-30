-- 2026-07-29_2300  Name the dispatcher on a verified Calendar save (per-user attribution)
--
-- Fred: "Spec the per-user attribution column" -> then "go ahead and implement it, tell building apps
-- to verify." Spec: docs/specs/2026-07-30-calendar-per-user-attribution.md.
--
-- ⚠ FIRST, THE PREMISE THAT WAS WRONG. @Building Apps and I both said this needed A COLUMN ON
-- `visits`, and I repeated it in 2026-07-29d's header. It does not. `audit.log_change` has captured
-- `x-actor-name` into `request_context.actor_name` since 2026-06-26 (P2b), webhook-jobber already uses
-- that idiom, and 143 rows carry it. **The capture layer was never the gap; the RENDER layer was.**
-- So there is NO schema change here, no new column anywhere, and no ADR-010 opt-in decision.
--
-- WHAT WAS BROKEN. `save-calendar-visit` calls edit_calendar_visit_verified as service_role, so
-- jwt_claims comes from the service_role token: `jwt_claims->>'email'` is NULL and
-- get_record_history could not name the dispatcher. Measured before this change:
--   audit.logs total                                  46,387
--   rows with changed_by NOT NULL                          0   <- dead column, see below
--   rows with jwt_claims->>'email'                     3,013
--   rows with request_context->>'actor_name'             143   (all app_source='jobber')
--   app_source='visit-calendar' visits rows            2,068 -> 2,015 with an email, 53 without
-- The verified path was joining that 53.
--
-- ⚠ AND IT WAS WORSE THAN "UNATTRIBUTED", which neither session noticed until the audit:
-- get_record_history takes `p_hide_system boolean DEFAULT true`, and that filter suppresses
-- `app_source IS NULL OR = 'sql' OR LIKE 'other:%'`. While verified saves landed as 'sql' they were
-- **INVISIBLE in the Activity history**, not merely mislabelled. Commit e58ee34 (x-app-source) fixed
-- that half; this migration names the person.
--
-- 🛑 `changed_by` IS A DEAD COLUMN AND IS NOT THE FIX: 0 of 46,387 rows, ever. It is populated from
-- current_setting('request.jwt.claim.sub'), so making it work would require calling the RPC with the
-- CALLER's JWT -- and edit_calendar_visit_verified is deliberately service_role-only precisely so a
-- caller cannot reach it directly and bypass the Jobber push. Those two requirements are mutually
-- exclusive. Do not "restore" changed_by.
--
-- THE CHANGE, and it is the whole change:
--   1. (edge fn, deployed separately) save-calendar-visit builds a PER-REQUEST write client carrying
--      `x-app-source: visit-calendar` + `x-actor-name: <caller's email>`, read from the same
--      gateway-verified JWT it already decodes for the role gate. Omitted entirely when there is no
--      email, so a service_role caller yields no actor rather than a blank one.
--   2. (here) get_record_history derives `actor_effective` = COALESCE(jwt_claims email,
--      request_context actor_name) and the HUMAN-APP branch uses it instead of actor_email.
--
-- ⚠ WHY A SEPARATE `actor_effective` COLUMN RATHER THAN WIDENING `actor_email`: the 'jobber' branch
-- renders `actor_name_ctx`, which holds a person's NAME (from Jobber createdBy.name.full), not an
-- email. Folding the two together would work today only by luck. actor_email and actor_name_ctx are
-- both left exactly as they were, so the jobber and dump-schedule branches are provably untouched.
--
-- ⚠ THE EMAIL, NOT A DISPLAY NAME, is what the edge fn sends: it keys the existing
-- employees.full_name lookup below, which is how every other human branch renders, and it degrades to
-- a readable value for anyone absent from `employees`.
--
-- 🛑 NEVER USE actor_name FOR AUTHORIZATION. It is a caller-supplied header. We derive it from a
-- verified JWT, but PostgREST accepts the header from anyone who can set one, so it is an attribution
-- HINT. Access control stays on the role, the grants, and the RPC's own checks. (Already true of
-- webhook-jobber's use of the same header.)
--
-- ⚠ HOW THIS FUNCTION BODY WAS PRODUCED: fetched live via pg_get_functiondef and edited by script,
-- with preconditions asserted before writing (anchor present; all 4 `s.actor_email` uses positioned
-- BEFORE the 'jobber' branch, so replacing them cannot touch another branch). The script refused to
-- emit anything on its first run because my anchor string did not match the real whitespace. Every
-- byte except the documented edit is unchanged from what was running.
--
-- ⚠ ops.get_record_history is a THIN WRAPPER over this function (619 chars) and needs NO change.
-- Do not duplicate this logic there.
--
-- RULE 8 (ADR 010): no table or column change, no new audited object. Read-path function only.
-- RULE 1: no source-prefixed columns.
--
-- VERIFICATION. The positive test CANNOT be done from a Supabase session: a service_role curl has no
-- email and correctly produces no actor, so it cannot prove this works. It needs a real logged-in
-- browser save. Handed to @Building Apps. What is checkable here:
--   * regression: the 143 app_source='jobber' rows must still render 'Created/Changed in Jobber by X'
--   * negative control: a service_role save must render 'Edited in Visit Calendar' with no trailing
--     ' by ' fragment and no error
--   * ⚠ when querying audit.logs, match `record_pk->>'id'`, NOT `record_pk = '<id>'` -- record_pk is
--     JSONB ({"id":7318}) and the wrong form returns zero rows, which looks exactly like a broken
--     audit trail. I made that mistake earlier tonight.

CREATE OR REPLACE FUNCTION public.get_record_history(p_table text, p_record_id text, p_since timestamp with time zone DEFAULT NULL::timestamp with time zone, p_hide_system boolean DEFAULT true, p_limit integer DEFAULT 50, p_cursor jsonb DEFAULT NULL::jsonb)
 RETURNS TABLE(entry_id bigint, changed_at timestamp with time zone, txid bigint, actor_label text, actor_type text, app_source text, operation text, changes jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
  IF p_table NOT IN ('visits','clients','derm_manifests') THEN
    RAISE EXCEPTION 'get_record_history: table % is not allowed', p_table;
  END IF;
  IF p_record_id IS NULL OR p_record_id = '' THEN
    RAISE EXCEPTION 'get_record_history: p_record_id is required';
  END IF;

  RETURN QUERY
  WITH src AS (
    SELECT l.id, l.table_name, l.changed_at, l.txid, l.operation, l.old_row, l.new_row, l.app_source,
           (l.jwt_claims->>'email')        AS actor_email,
           -- actor_effective: browser writes carry the email in jwt_claims; headless writers
           -- (save-calendar-visit) carry it in request_context.actor_name via the x-actor-name
           -- header. Prefer the JWT, fall back to the header. Kept as a SEPARATE column so the
           -- 'jobber' branch's use of actor_name_ctx (a person NAME, not an email) is untouched.
           COALESCE(NULLIF(l.jwt_claims->>'email',''),
                    NULLIF(l.request_context->>'actor_name','')) AS actor_effective,
           (l.request_context->>'actor_name') AS actor_name_ctx
    FROM audit.logs l
    WHERE (
            (l.table_name = p_table AND l.record_pk->>'id' = p_record_id)
            -- same-visit child-table changes (already-audited M:N tables)
            OR ( p_table = 'visits'
                 AND l.table_name IN ('visit_team','visit_locations')
                 AND COALESCE(l.new_row, l.old_row)->>'visit_id' = p_record_id )
          )
      AND (p_since IS NULL OR l.changed_at >= p_since)
      AND (p_cursor IS NULL
           OR (l.changed_at, l.id) < ((p_cursor->>'changed_at')::timestamptz, (p_cursor->>'id')::bigint))
      -- p_hide_system suppresses ONLY raw 'sql'/'other'/null noise. Everything with a
      -- meaningful app_source (human apps + every Jobber/cron/backfill source) is ALWAYS
      -- shown (aligns with the documented intent + auto-includes new X-App-Source names).
      AND (NOT p_hide_system
           OR NOT ( l.app_source IS NULL
                    OR l.app_source = 'sql'
                    OR l.app_source LIKE 'other:%' ))
      AND ( l.operation <> 'UPDATE'
            OR ((l.old_row->>'deleted_at') IS NULL AND (l.new_row->>'deleted_at') IS NOT NULL)
            OR EXISTS (SELECT 1 FROM audit.entity_render_config c
                       WHERE c.table_name = l.table_name
                         AND (l.old_row->c.column_name) IS DISTINCT FROM (l.new_row->c.column_name)) )
      -- drop delete-all-reinsert churn on the child M:N tables (no-op within a txid)
      AND NOT (
            l.table_name IN ('visit_team','visit_locations')
            AND l.operation IN ('INSERT','DELETE')
            AND EXISTS (
              SELECT 1 FROM audit.logs l2
              WHERE l2.table_name = l.table_name
                AND l2.txid = l.txid
                AND l2.operation IN ('INSERT','DELETE')
                AND l2.operation <> l.operation
                AND (COALESCE(l2.new_row, l2.old_row) - 'created_at')
                  = (COALESCE(l.new_row,  l.old_row)  - 'created_at')
            )
          )
    ORDER BY l.changed_at DESC, l.id DESC
    LIMIT GREATEST(COALESCE(p_limit, 50), 1)
  )
  SELECT
    s.id,
    s.changed_at,
    s.txid,
    CASE
      -- Human edits in one of our apps
      WHEN s.app_source IN ('visit-calendar','field-portal','derm-tracker','admin-review')
        THEN 'Edited in ' || pg_catalog.initcap(pg_catalog.replace(s.app_source, '-', ' '))
          || COALESCE(
               ' by ' || (SELECT e.full_name FROM public.employees e
                          WHERE pg_catalog.lower(e.email) = pg_catalog.lower(s.actor_effective)
                            AND COALESCE(e.email,'') <> ''
                          ORDER BY e.id LIMIT 1),
               CASE WHEN COALESCE(s.actor_effective,'') <> ''
                         AND s.actor_effective <> 'unclogme@unclogme.com'
                    THEN ' by ' || s.actor_effective ELSE '' END
             )
      -- Raw inbound Jobber webhook / poll sync
      WHEN s.app_source = 'jobber' THEN
        CASE
          WHEN s.operation = 'INSERT'
            THEN 'Created in Jobber' || COALESCE(' by ' || pg_catalog.left(s.actor_name_ctx, 120), '')
          WHEN (s.old_row->>'visit_status') IS DISTINCT FROM (s.new_row->>'visit_status')
               AND (s.new_row->>'visit_status') = 'completed'
            THEN 'Completed in Jobber' || COALESCE(' by ' || pg_catalog.btrim(pg_catalog.left(s.new_row->>'completed_by', 120)), '')
          ELSE 'Changed in Jobber' || COALESCE(' by ' || pg_catalog.left(s.actor_name_ctx, 120), '')
        END
      -- Automated nightly reconcile / drift-heal that pulls our DB into line with Jobber
      WHEN s.app_source LIKE '%reconcile%' OR s.app_source LIKE '%drift%'
           OR s.app_source LIKE 'jobber-daily%' OR s.app_source = 'jobber-reconcile'
        THEN 'System · Synced to match Jobber'
      -- Automated recurring / service-agreement visit generation
      WHEN s.app_source = 'service-agreement-cron' OR s.app_source LIKE 'sa-%'
           OR s.app_source LIKE '%recurring%'
        THEN 'System · Recurring-visit generator'
      -- Automated data corrections / backfills / repairs
      WHEN s.app_source LIKE '%backfill%' OR s.app_source LIKE '%correction%'
           OR s.app_source LIKE '%-fix' OR s.app_source LIKE '%-repair'
        THEN 'System · Data correction'
      -- Other scheduled/system jobs
      WHEN s.app_source LIKE '%-cron' OR s.app_source LIKE 'system:%'
        THEN 'System · Scheduled job'
      -- DUMP Schedule: the truck-QR driver tool. The DRIVER is the actor, but he has no auth
      -- identity (no login by design), so the actor is read off the visit's own assigned driver
      -- rather than actor_email. Reads as "Anthony · DUMP app created this visit".
      WHEN s.app_source = 'dump-schedule' THEN
        COALESCE(
          (SELECT e.full_name FROM public.employees e
            WHERE e.id = NULLIF(s.new_row->>'assigned_driver_id', '')::bigint
            LIMIT 1) || ' · DUMP app',
          'DUMP app')
      -- Generic backend script (Management API / psql / uncategorized)
      ELSE 'System'
    END AS actor_label,
    CASE WHEN s.app_source IN ('visit-calendar','field-portal','derm-tracker','admin-review','dump-schedule')
         THEN 'human' ELSE 'system' END AS actor_type,
    s.app_source,
    CASE
      WHEN s.table_name <> p_table
        THEN CASE s.operation WHEN 'INSERT' THEN 'added' WHEN 'DELETE' THEN 'removed' ELSE 'updated' END
      WHEN s.operation = 'INSERT' THEN 'created'
      WHEN s.operation = 'DELETE' THEN 'deleted'
      WHEN (s.old_row->>'deleted_at') IS NULL AND (s.new_row->>'deleted_at') IS NOT NULL THEN 'deleted'
      ELSE 'updated'
    END AS operation,
    COALESCE((
      SELECT pg_catalog.jsonb_agg(
               pg_catalog.jsonb_build_object(
                 'field', c.column_name,
                 'label', c.label,
                 'old',   audit.render_value(s.old_row->c.column_name, c.render_type, c.fk_table, c.fk_label_col),
                 'new',   audit.render_value(s.new_row->c.column_name, c.render_type, c.fk_table, c.fk_label_col)
               ) ORDER BY c.sort_order, c.column_name)
      FROM audit.entity_render_config c
      WHERE c.table_name = s.table_name
        AND ( s.operation = 'INSERT'
              OR s.operation = 'DELETE'
              OR (s.old_row->c.column_name) IS DISTINCT FROM (s.new_row->c.column_name) )
    ), '[]'::jsonb) AS changes
  FROM src s
  ORDER BY s.changed_at DESC, s.id DESC;
END;
$function$

