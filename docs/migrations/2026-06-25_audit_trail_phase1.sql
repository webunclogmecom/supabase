-- ============================================================================
-- 2026-06-25 — Activity History / Audit Trail, Phase 1 backend
-- ----------------------------------------------------------------------------
-- Read/render layer on the existing audit.logs (see
-- docs/superpowers/specs/2026-06-25-audit-trail-activity-history-design.md).
-- Adds: (1) txid capture for grouping; (2) a data-driven render config that
-- doubles as the column allowlist; (3) a value renderer (ET dates, FK names,
-- money, bool); (4) the get_record_history SECURITY DEFINER RPC — the ONLY
-- door into audit data (table whitelist + column allowlist + hard exclusion of
-- everything else incl. webhook_tokens, requires p_record_id, keyset paginated,
-- app-level actor labels); (5) a per-record query index.
-- ============================================================================

-- 1. txid capture -----------------------------------------------------------
ALTER TABLE audit.logs ADD COLUMN IF NOT EXISTS txid bigint;
COMMENT ON COLUMN audit.logs.txid IS 'txid_current() of the writing transaction — groups multi-statement saves into one activity entry.';

CREATE OR REPLACE FUNCTION audit.log_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_pk_cols          TEXT[];
  v_pk               JSONB;
  v_old_clean        JSONB;
  v_new_clean        JSONB;
  v_redact           TEXT[];
  v_col              TEXT;
  v_headers          JSONB;
  v_origin           TEXT;
  v_referer          TEXT;
  v_method           TEXT;
  v_path             TEXT;
  v_x_app_source     TEXT;
  v_app_source       TEXT;
  v_request_context  JSONB;
BEGIN
  IF TG_TABLE_SCHEMA = 'audit' THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  SELECT pg_catalog.array_agg(a.attname::TEXT)
    INTO v_pk_cols
    FROM pg_catalog.pg_index i
    JOIN pg_catalog.pg_attribute a
      ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
   WHERE i.indrelid = TG_RELID AND i.indisprimary;

  IF v_pk_cols IS NULL THEN
    v_pk := '{}'::jsonb;
  ELSE
    SELECT pg_catalog.jsonb_object_agg(col, pg_catalog.to_jsonb(COALESCE(NEW, OLD))->col)
      INTO v_pk
      FROM pg_catalog.unnest(v_pk_cols) AS col;
  END IF;

  v_old_clean := CASE WHEN TG_OP IN ('UPDATE','DELETE')
                      THEN pg_catalog.to_jsonb(OLD) - 'updated_at'
                 END;
  v_new_clean := CASE WHEN TG_OP IN ('INSERT','UPDATE')
                      THEN pg_catalog.to_jsonb(NEW) - 'updated_at'
                 END;

  IF TG_OP = 'UPDATE' AND v_old_clean IS NOT DISTINCT FROM v_new_clean THEN
    RETURN NEW;
  END IF;

  SELECT pg_catalog.array_agg(column_name)
    INTO v_redact
    FROM audit.redacted_columns
   WHERE table_name = TG_TABLE_NAME;
  IF v_redact IS NOT NULL THEN
    FOREACH v_col IN ARRAY v_redact LOOP
      v_old_clean := v_old_clean - v_col;
      v_new_clean := v_new_clean - v_col;
    END LOOP;
  END IF;

  BEGIN
    v_headers := NULLIF(pg_catalog.current_setting('request.headers', true), '')::jsonb;
  EXCEPTION WHEN OTHERS THEN
    v_headers := NULL;
  END;

  v_origin       := COALESCE(v_headers->>'origin', '');
  v_referer      := COALESCE(v_headers->>'referer', '');
  v_method       := NULLIF(pg_catalog.current_setting('request.method', true), '');
  v_path         := NULLIF(pg_catalog.current_setting('request.path', true), '');
  v_x_app_source := NULLIF(v_headers->>'x-app-source', '');

  v_app_source := COALESCE(
    v_x_app_source,
    CASE
      WHEN v_origin = '' THEN 'sql'
      WHEN v_origin LIKE '%derm.unclogme.app%'    THEN 'derm-tracker'
      WHEN v_origin LIKE '%fp.unclogme.app%'      THEN 'field-portal'
      WHEN v_origin LIKE '%grease-buddy-dash%'    THEN 'admin-review'
      WHEN v_origin LIKE '%calendar.unclogme.app%' THEN 'visit-calendar'
      WHEN v_origin LIKE '%6533c3ee%'             THEN 'visit-calendar'
      WHEN v_origin LIKE '%lovable.app%'          THEN 'lovable-preview'
      ELSE 'other:' || COALESCE(pg_catalog.substring(v_origin, 'https?://([^/]+)'), v_origin)
    END
  );

  v_request_context := pg_catalog.jsonb_strip_nulls(
    pg_catalog.jsonb_build_object(
      'origin',          NULLIF(v_origin, ''),
      'referer',         NULLIF(v_referer, ''),
      'method',          v_method,
      'path',            v_path,
      'app_source_hint', v_x_app_source
    )
  );

  INSERT INTO audit.logs (
    table_schema, table_name, record_pk, operation,
    old_row, new_row,
    changed_by, db_role, jwt_claims,
    app_source, request_context, txid
  ) VALUES (
    TG_TABLE_SCHEMA,
    TG_TABLE_NAME,
    v_pk,
    TG_OP,
    v_old_clean,
    v_new_clean,
    NULLIF(pg_catalog.current_setting('request.jwt.claim.sub', true), '')::uuid,
    CURRENT_USER::text,
    NULLIF(pg_catalog.current_setting('request.jwt.claims', true), '')::jsonb,
    v_app_source,
    CASE WHEN v_request_context = '{}'::jsonb THEN NULL ELSE v_request_context END,
    pg_catalog.txid_current()
  );

  RETURN COALESCE(NEW, OLD);
END;
$function$;

-- 2. Render config (also the column allowlist) ------------------------------
CREATE TABLE IF NOT EXISTS audit.entity_render_config (
  table_name   text NOT NULL,
  column_name  text NOT NULL,
  label        text NOT NULL,
  render_type  text NOT NULL DEFAULT 'text',  -- text | date | datetime | money | bool | fk
  fk_table     text,
  fk_label_col text,
  sort_order   int  NOT NULL DEFAULT 100,
  PRIMARY KEY (table_name, column_name)
);
COMMENT ON TABLE audit.entity_render_config IS 'Columns surfaced by get_record_history (this IS the per-entity allowlist) + how to render each. deleted_at is intentionally omitted (it drives the "deleted" event, not a field diff).';

INSERT INTO audit.entity_render_config (table_name, column_name, label, render_type, fk_table, fk_label_col, sort_order) VALUES
  ('visits','visit_date','Date','date',NULL,NULL,10),
  ('visits','start_at','Start time','datetime',NULL,NULL,20),
  ('visits','end_at','End time','datetime',NULL,NULL,30),
  ('visits','title','Title','text',NULL,NULL,40),
  ('visits','notes','Instructions','text',NULL,NULL,50),
  ('visits','service_line_item_id','Primary service','fk','service_line_items','title',60),
  ('visits','service_type','Service type','text',NULL,NULL,70),
  ('visits','visit_status','Status','text',NULL,NULL,80),
  ('visits','assigned_driver_id','Driver','fk','employees','full_name',90),
  ('visits','vehicle_id','Truck','fk','vehicles','name',100),
  ('visits','job_id','Job','fk','jobs','title',110),
  ('visits','completed_at','Completed','datetime',NULL,NULL,120),
  ('visits','derm_required','DERM required','bool',NULL,NULL,130),
  ('visits','manhole_count','Manhole count','text',NULL,NULL,140),
  ('visits','ticket_number','Ticket #','text',NULL,NULL,150),
  ('clients','name','Name','text',NULL,NULL,10),
  ('clients','client_code','Code','text',NULL,NULL,20),
  ('clients','status','Status','text',NULL,NULL,30),
  ('clients','client_class','Class','text',NULL,NULL,40),
  ('clients','balance','Balance','money',NULL,NULL,50),
  ('clients','notes','Notes','text',NULL,NULL,60),
  ('derm_manifests','service_date','Service date','date',NULL,NULL,10),
  ('derm_manifests','dump_ticket_date','Dump date','date',NULL,NULL,20),
  ('derm_manifests','white_manifest_number','White manifest #','text',NULL,NULL,30),
  ('derm_manifests','yellow_ticket_number','Yellow ticket #','text',NULL,NULL,40),
  ('derm_manifests','wwtp_ticket_number','WWTP ticket #','text',NULL,NULL,50),
  ('derm_manifests','sent_to_client','Sent to client','bool',NULL,NULL,60),
  ('derm_manifests','sent_to_city','Sent to city','bool',NULL,NULL,70),
  ('derm_manifests','notes','Notes','text',NULL,NULL,80)
ON CONFLICT (table_name, column_name) DO NOTHING;

-- 3. Value renderer ---------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.render_value(p_val jsonb, p_type text, p_fk_table text, p_fk_label_col text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v text; r text;
BEGIN
  IF p_val IS NULL OR p_val = 'null'::jsonb THEN RETURN NULL; END IF;
  v := p_val #>> '{}';
  IF v IS NULL OR v = '' THEN RETURN NULL; END IF;
  CASE p_type
    WHEN 'date'     THEN RETURN pg_catalog.to_char(v::date, 'FMMon DD, YYYY');
    WHEN 'datetime' THEN RETURN pg_catalog.to_char((v::timestamptz) AT TIME ZONE 'America/New_York', 'FMMon DD, YYYY, FMHH12:MI AM') || ' ET';
    WHEN 'money'    THEN RETURN '$' || pg_catalog.to_char(v::numeric, 'FM999G999G990D00');
    WHEN 'bool'     THEN RETURN CASE WHEN v::boolean THEN 'Yes' ELSE 'No' END;
    WHEN 'fk'       THEN
      BEGIN
        EXECUTE pg_catalog.format('SELECT %I::text FROM public.%I WHERE id = $1', p_fk_label_col, p_fk_table)
          INTO r USING v::bigint;
      EXCEPTION WHEN OTHERS THEN r := NULL;
      END;
      RETURN COALESCE(r, v);
    ELSE RETURN v;
  END CASE;
END;
$function$;

-- 4. The read RPC -----------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_record_history(
  p_table       text,
  p_record_id   text,
  p_since       timestamptz DEFAULT NULL,
  p_hide_system boolean     DEFAULT true,
  p_limit       int         DEFAULT 50,
  p_cursor      jsonb       DEFAULT NULL
)
 RETURNS TABLE(entry_id bigint, changed_at timestamptz, txid bigint, actor_label text, actor_type text, app_source text, operation text, changes jsonb)
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
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
    SELECT l.id, l.changed_at, l.txid, l.operation, l.old_row, l.new_row, l.app_source
    FROM audit.logs l
    WHERE l.table_name = p_table
      AND l.record_pk->>'id' = p_record_id
      AND (p_since IS NULL OR l.changed_at >= p_since)
      AND (p_cursor IS NULL
           OR (l.changed_at, l.id) < ((p_cursor->>'changed_at')::timestamptz, (p_cursor->>'id')::bigint))
      AND (NOT p_hide_system
           OR l.app_source IN ('visit-calendar','field-portal','derm-tracker','admin-review'))
      -- drop UPDATEs with no surfaced field change (e.g. line_items_rev-only bumps);
      -- keep INSERT/DELETE and soft-deletes (deleted_at transition)
      AND ( l.operation <> 'UPDATE'
            OR ((l.old_row->>'deleted_at') IS NULL AND (l.new_row->>'deleted_at') IS NOT NULL)
            OR EXISTS (SELECT 1 FROM audit.entity_render_config c
                       WHERE c.table_name = p_table
                         AND (l.old_row->c.column_name) IS DISTINCT FROM (l.new_row->c.column_name)) )
    ORDER BY l.changed_at DESC, l.id DESC
    LIMIT GREATEST(COALESCE(p_limit, 50), 1)
  )
  SELECT
    s.id,
    s.changed_at,
    s.txid,
    CASE
      WHEN s.app_source IN ('visit-calendar','field-portal','derm-tracker','admin-review')
        THEN 'Edited in ' || pg_catalog.initcap(pg_catalog.replace(s.app_source, '-', ' '))
      WHEN s.app_source LIKE 'system:%' OR s.app_source = 'jobber-reconcile'
           OR s.app_source LIKE '%-cron' OR s.app_source = 'service-agreement-cron'
        THEN 'System (Jobber sync)'
      ELSE 'System'
    END AS actor_label,
    CASE WHEN s.app_source IN ('visit-calendar','field-portal','derm-tracker','admin-review')
         THEN 'human' ELSE 'system' END AS actor_type,
    s.app_source,
    CASE
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
      WHERE c.table_name = p_table
        AND ( s.operation = 'INSERT'
              OR s.operation = 'DELETE'
              OR (s.old_row->c.column_name) IS DISTINCT FROM (s.new_row->c.column_name) )
    ), '[]'::jsonb) AS changes
  FROM src s
  ORDER BY s.changed_at DESC, s.id DESC;
END;
$function$;

-- The RPC is the only door into audit data; raw audit.logs stays unreachable.
REVOKE ALL ON FUNCTION public.get_record_history(text, text, timestamptz, boolean, int, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_record_history(text, text, timestamptz, boolean, int, jsonb) TO anon, authenticated, service_role;

-- 5. Per-record query index (parent -> all partitions) ----------------------
CREATE INDEX IF NOT EXISTS logs_table_record_changed_idx
  ON audit.logs (table_name, (record_pk->>'id'), changed_at DESC);

-- 6. ops wrapper (apps call via the ops schema, like create/edit_calendar_visit)
CREATE OR REPLACE FUNCTION ops.get_record_history(
  p_table text, p_record_id text, p_since timestamptz DEFAULT NULL,
  p_hide_system boolean DEFAULT true, p_limit int DEFAULT 50, p_cursor jsonb DEFAULT NULL)
 RETURNS TABLE(entry_id bigint, changed_at timestamptz, txid bigint, actor_label text, actor_type text, app_source text, operation text, changes jsonb)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$ SELECT * FROM public.get_record_history(p_table, p_record_id, p_since, p_hide_system, p_limit, p_cursor); $function$;
REVOKE ALL ON FUNCTION ops.get_record_history(text, text, timestamptz, boolean, int, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.get_record_history(text, text, timestamptz, boolean, int, jsonb) TO anon, authenticated, service_role;
