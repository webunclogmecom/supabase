-- ============================================================================================
-- 2026-09-07_1610_repoint_dump_consumers.sql
--
-- Point six more consumers at public.non_customer_clients, so MEMBERSHIP has one definition.
--
-- WHY (Fred, 2026-09-07): "yes i want one source of truth good."
--
-- Repointed here, the objects where membership IS the whole predicate:
--   public.dump_manifest_link        client_id IN (365,76)                  -> kind dump_site
--   public.dump_test_cleanup         client_id IN (365,76)                  -> kind dump_site
--   public.dump_route_today          client_code NOT LIKE '000%'            -> NOT dump_site
--   derm.visits                      client_code = ANY('000-DH','000-DP')   -> kind dump_site
--   public.manifest_pickable_visits  same                                   -> kind dump_site
--   public.v_sa_schedule_gaps        ('112-YA','777-YA','000-DH')           -> NOT non_customer
--
-- MEASURED BEFORE WRITING: repointing an id-list or a code-list is 0 lost / 0 gained, so five of
-- the six do not move a single client.
--
-- ⚠ THE ONE REAL BEHAVIOUR CHANGE IS dump_route_today, AND IT IS A BUG FIX.
-- `NULL NOT LIKE '000%'` evaluates to NULL, so the AND drops the row: 175 of 475 clients carry a
-- NULL client_code and are silently excluded from routing today. The membership test keeps them.
-- Measured live impact: 0 visits today and 0 in the next 7 days, against a control of 8 visits
-- scheduled today overall. So it corrects a latent defect without moving a live route.
--
-- 🛑 DELIBERATELY NOT REPOINTED, each for a stated reason:
--   ops.v_calendar_visit          Semantically a pure no-op (a NULL code already falls through the
--                                 CASE to non-dump, exactly as the new predicate would), but it is
--                                 the most-read view in the estate, 14KB, and carries service_kind,
--                                 the column CLAUDE.md warns hardest about. It deserves its own
--                                 migration with performance verification, not a line in a batch.
--   fn_dump_site_accepts          These four encode per-site RULES, not membership: county
--   dump_site_status              acceptance, opening hours and call-ahead behaviour, the handout
--   dump_manifest_handout_list    county gate, and site coordinates. A membership list cannot
--   dump_investigate              carry any of it; they need a dump_sites REGISTRY with attributes.
--   2 CHECK constraints           calendar_day_markers pins display strings, dump_site_hours pins
--                                 a dump_key. Neither is client identity.
-- ⇒ Membership now has one definition. The dump ATTRIBUTES still do not, and that is the other half.
--
-- ⚠ fn_dump_site_accepts is worth a second look when that registry is built: its body is
--   `CASE WHEN p_dump_client_id = 365 THEN <Dade gate> ELSE true END`, and the ELSE is correct for
--   Pompano today but means a THIRD dump site would silently accept everything.
--
-- BODY PROVENANCE: every body pulled with pg_get_functiondef / pg_get_viewdef and patched by
-- explicit substring replacement with a per-object count assertion (scratchpad/patch_six.js).
-- Never retyped.
--
-- RULE 8: no schema change. Three functions and three views replaced.
-- ============================================================================================

BEGIN;

-- Snapshot the three views BEFORE replacing them, so the no-op is proven rather than asserted.
CREATE TEMP TABLE _before ON COMMIT DROP AS
SELECT 'derm.visits' AS obj, count(*) AS n FROM derm.visits
UNION ALL SELECT 'manifest_pickable_visits', count(*) FROM public.manifest_pickable_visits
UNION ALL SELECT 'v_sa_schedule_gaps',       count(*) FROM public.v_sa_schedule_gaps;

CREATE OR REPLACE FUNCTION public.dump_manifest_link(p_driver_id bigint, p_dump_visit_id bigint, p_visit_ids bigint[])
 RETURNS TABLE(visit_id bigint, client_code text, client_name text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
  v_ids bigint[] := COALESCE(p_visit_ids, ARRAY[]::bigint[]);
BEGIN
  -- the target must be a live dump visit; otherwise link nothing
  IF NOT EXISTS (
    SELECT 1 FROM public.visits v
    WHERE v.id = p_dump_visit_id AND public.fn_is_non_customer(v.client_id, ARRAY['dump_site']) AND v.deleted_at IS NULL
  ) THEN
    RETURN;
  END IF;

  -- link each genuinely-outstanding ticked visit to this dump
  INSERT INTO public.dump_manifest_handout (visit_id, dump_visit_id, driver_id, source, handed_at)
  SELECT o.visit_id, p_dump_visit_id, p_driver_id, 'addresses', now()
  FROM public.dump_outstanding_visits o
  WHERE o.visit_id = ANY (v_ids)
  ON CONFLICT (visit_id) DO UPDATE
    SET dump_visit_id = p_dump_visit_id, driver_id = p_driver_id, source = 'addresses', handed_at = now();

  RETURN QUERY
  SELECT o.visit_id, o.client_code, o.client_name
  FROM public.dump_outstanding_visits o
  JOIN public.dump_manifest_handout h ON h.visit_id = o.visit_id AND h.dump_visit_id = p_dump_visit_id
  WHERE o.visit_id = ANY (v_ids)
  ORDER BY o.completed_at DESC NULLS LAST;
END;
$function$;

CREATE OR REPLACE FUNCTION public.dump_test_cleanup()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_ids   bigint[];
  v_count integer;
BEGIN
  SELECT array_agg(id) INTO v_ids
  FROM public.visits
  WHERE public.fn_is_non_customer(client_id, ARRAY['dump_site'])
    AND source = 'manual'
    AND deleted_at IS NULL
    AND notes LIKE '%[TEST]%';

  IF v_ids IS NULL THEN
    RETURN 0;
  END IF;

  DELETE FROM public.dump_manifest_handout WHERE dump_visit_id = ANY (v_ids) OR visit_id = ANY (v_ids);
  DELETE FROM public.dump_activity          WHERE dump_visit_id = ANY (v_ids);
  DELETE FROM public.visit_team             WHERE visit_id      = ANY (v_ids);
  DELETE FROM public.line_items             WHERE visit_id      = ANY (v_ids);

  UPDATE public.visits SET deleted_at = now() WHERE id = ANY (v_ids) AND deleted_at IS NULL;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

CREATE OR REPLACE FUNCTION public.dump_route_today()
 RETURNS TABLE(visit_id bigint, client_code text, client_name text, visit_status text, start_at timestamp with time zone, is_all_day boolean, address text, city text, state text, zip text, county text, gdo_number text, latitude double precision, longitude double precision, truck_name text, driver_name text, service_label text, pickable boolean, on_sheet boolean, marked_by text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'ops'
AS $function$
  SELECT
    v.id AS visit_id,
    v.client_code,
    v.client_name,
    v.visit_status,
    v.start_at,
    v.is_all_day,
    v.address,
    v.city,
    v.state,
    v.zip,
    v.county,
    v.gdo_number,
    v.latitude,
    v.longitude,
    v.truck_name,
    COALESCE(v.driver_name, v.assigned_driver_name) AS driver_name,
    v.service_label,
    (o.visit_id IS NOT NULL)      AS pickable,      -- in dump_outstanding_visits => completed DERM, addable
    COALESCE(o.on_sheet, false)   AS on_sheet,      -- shared dump_manifest_handout mark
    o.marked_by
  FROM ops.v_calendar_visit v
  LEFT JOIN public.dump_outstanding_visits o ON o.visit_id = v.id
  WHERE v.visit_date = (now() AT TIME ZONE 'America/New_York')::date
    AND NOT public.fn_is_non_customer(v.client_id, ARRAY['dump_site'])          -- exclude the dump places (000-DH / 000-DP)
    AND (v.derm_required IS NOT FALSE)         -- DERM manifest reference: drop non-DERM (unclog etc.); keep TRUE + unknown
  ORDER BY v.start_at NULLS LAST, v.client_code
$function$;

CREATE OR REPLACE VIEW derm.visits AS
 SELECT id,
    client_name,
    address,
    county,
    visit_date,
    technician,
    notes,
    created_at,
    client_id,
    service_type,
    has_manifest,
    derm_required,
    needs_manifest,
    line_items,
    line_items_json,
    gdo_number,
    job_number,
    last_emailed_at,
    city_last_emailed_at,
    crew,
    completed_at,
    manifest_id,
    has_pdf,
    has_client_email,
    has_city_email,
    municipality,
    ( SELECT max(es.sent_at) AS max
           FROM manifest_visits mv
             JOIN derm_email_sends es ON es.manifest_id = mv.manifest_id
          WHERE mv.visit_id = w3.id AND es.client_id = w3.client_id AND es.recipient_type = 'client'::text AND es.status = 'sent'::text AND es.is_test = false) AS client_last_emailed_at,
    ( SELECT es.recipient_email
           FROM manifest_visits mv
             JOIN derm_email_sends es ON es.manifest_id = mv.manifest_id
          WHERE mv.visit_id = w3.id AND es.client_id = w3.client_id AND es.recipient_type = 'client'::text AND es.status = 'sent'::text AND es.is_test = false
          ORDER BY es.sent_at DESC
         LIMIT 1) AS client_last_email_to,
    ( SELECT cc.email
           FROM client_contacts cc
          WHERE cc.client_id = w3.client_id AND cc.email IS NOT NULL AND cc.email <> ''::text
          ORDER BY cc.property_id NULLS FIRST, cc.contact_role DESC, cc.id
         LIMIT 1) AS client_email
   FROM ( SELECT w2.id,
            w2.client_name,
            w2.address,
            w2.county,
            w2.visit_date,
            w2.technician,
            w2.notes,
            w2.created_at,
            w2.client_id,
            w2.service_type,
            w2.has_manifest,
            w2.derm_required,
            w2.needs_manifest,
            w2.line_items,
            w2.line_items_json,
            w2.gdo_number,
            w2.job_number,
            w2.last_emailed_at,
            w2.city_last_emailed_at,
            w2.crew,
            w2.completed_at,
            em.manifest_id,
            COALESCE(em.has_pdf, false) AS has_pdf,
            COALESCE(em.has_email, false) AS has_client_email,
            COALESCE(em.has_city_email, false) AS has_city_email,
            em.municipality
           FROM ( SELECT dv.id,
                    dv.client_name,
                    dv.address,
                    dv.county,
                    dv.visit_date,
                    dv.technician,
                    dv.notes,
                    dv.created_at,
                    dv.client_id,
                    dv.service_type,
                    dv.has_manifest,
                    dv.derm_required,
                    dv.needs_manifest,
                    dv.line_items,
                    dv.line_items_json,
                    dv.gdo_number,
                    dv.job_number,
                    dv.last_emailed_at,
                    dv.city_last_emailed_at,
                    ( SELECT string_agg(DISTINCT e.full_name, ', '::text) AS string_agg
                           FROM visit_team vt
                             JOIN employees e ON e.id = vt.employee_id
                          WHERE vt.visit_id = dv.id) AS crew,
                    ( SELECT v.completed_at
                           FROM visits v
                          WHERE v.id = dv.id) AS completed_at
                   FROM ( SELECT _dv.id,
                            _dv.client_name,
                            _dv.address,
                            _dv.county,
                            _dv.visit_date,
                            _dv.technician,
                            _dv.notes,
                            _dv.created_at,
                            _dv.client_id,
                            _dv.service_type,
                            _dv.has_manifest,
                            _dv.derm_required,
                            _dv.needs_manifest,
                            _dv.line_items,
                            _dv.line_items_json,
                            _dv.gdo_number,
                            _dv.job_number,
                            _dv.last_emailed_at,
                            _dv.city_last_emailed_at
                           FROM ( SELECT w.id,
                                    w.client_name,
                                    w.address,
                                    w.county,
                                    w.visit_date,
                                    w.technician,
                                    w.notes,
                                    w.created_at,
                                    w.client_id,
                                    w.service_type,
                                    w.has_manifest,
                                    w.derm_required,
                                    w.needs_manifest,
                                    w.line_items,
                                    w.line_items_json,
                                    w.gdo_number,
                                    w.job_number,
                                    w.last_emailed_at,
                                    ( SELECT max(es.sent_at) AS max
   FROM manifest_visits mv
     JOIN derm_email_sends es ON es.manifest_id = mv.manifest_id
  WHERE mv.visit_id = w.id AND es.client_id = w.client_id AND es.recipient_type = 'city'::text AND es.status = 'sent'::text AND es.is_test = false) AS city_last_emailed_at
                                   FROM ( SELECT sub.id,
    sub.client_name,
    sub.address,
    sub.county,
    sub.visit_date,
    sub.technician,
    sub.notes,
    sub.created_at,
    sub.client_id,
    sub.service_type,
    sub.has_manifest,
    sub.derm_required,
    sub.needs_manifest,
    sub.line_items,
    sub.line_items_json,
    sub.gdo_number,
    sub.job_number,
    ( SELECT max(es.sent_at) AS max
     FROM manifest_visits mv
       JOIN derm_email_sends es ON es.manifest_id = mv.manifest_id
    WHERE mv.visit_id = sub.id AND es.client_id = sub.client_id AND es.status = 'sent'::text AND es.is_test = false) AS last_emailed_at
   FROM ( SELECT v.id,
    CASE
     WHEN c.client_code IS NOT NULL AND c.name !~~ (c.client_code || '%'::text) THEN (c.client_code || ' '::text) || c.name
     ELSE c.name
    END AS client_name,
      COALESCE(p.address, ''::text) AS address,
      COALESCE(p.county, ''::text) AS county,
      v.visit_date::text AS visit_date,
      NULL::text AS technician,
      NULL::text AS notes,
      v.created_at::text AS created_at,
      v.client_id,
      v.service_type,
      (EXISTS ( SELECT 1
       FROM manifest_visits mv
         JOIN derm_manifests dm ON dm.id = mv.manifest_id
      WHERE mv.visit_id = v.id AND dm.deleted_at IS NULL AND (dm.derm_manifest_url IS NOT NULL OR dm.derm_address_url IS NOT NULL))) AS has_manifest,
      v.derm_required,
      COALESCE(v.derm_required, true) AS needs_manifest,
      COALESCE(( SELECT (NULLIF(TRIM(BOTH FROM j.title), ''::text) || ' - '::text) || (( SELECT string_agg(li.name, ', '::text ORDER BY li.id) AS string_agg
         FROM line_items li
        WHERE li.visit_id = v.id AND li.name IS NOT NULL AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text AND li.name ~* '(fee|fees|%)'::text) AND li.name !~* '^\s*tax\s*$'::text))
       FROM jobs j
      WHERE j.id = v.job_id AND j.title IS NOT NULL AND TRIM(BOTH FROM j.title) <> ''::text AND (( SELECT COALESCE(sum(li2.total_price), 0::numeric) AS "coalesce"
         FROM line_items li2
        WHERE li2.visit_id = v.id)) > 0::numeric AND (EXISTS ( SELECT 1
         FROM line_items li
        WHERE li.visit_id = v.id AND li.name IS NOT NULL AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text AND li.name ~* '(fee|fees|%)'::text) AND li.name !~* '^\s*tax\s*$'::text))), ( SELECT string_agg(li.name, ', '::text ORDER BY li.id) AS string_agg
       FROM line_items li
      WHERE li.visit_id = v.id AND (( SELECT COALESCE(sum(li2.total_price), 0::numeric) AS "coalesce"
         FROM line_items li2
        WHERE li2.visit_id = v.id)) > 0::numeric AND li.name IS NOT NULL AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text AND li.name ~* '(fee|fees|%)'::text) AND li.name !~* '^\s*tax\s*$'::text), ( SELECT (NULLIF(TRIM(BOTH FROM j.title), ''::text) || ' - '::text) || (( SELECT string_agg(li.name, ', '::text ORDER BY li.id) AS string_agg
         FROM line_items li
        WHERE li.invoice_id = v.invoice_id AND li.name IS NOT NULL AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text AND li.name ~* '(fee|fees|%)'::text) AND li.name !~* '^\s*tax\s*$'::text))
       FROM jobs j
      WHERE j.id = v.job_id AND j.title IS NOT NULL AND TRIM(BOTH FROM j.title) <> ''::text AND (EXISTS ( SELECT 1
         FROM line_items li
        WHERE li.invoice_id = v.invoice_id AND li.name IS NOT NULL AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text AND li.name ~* '(fee|fees|%)'::text) AND li.name !~* '^\s*tax\s*$'::text))), ( SELECT string_agg(li.name, ', '::text ORDER BY li.id) AS string_agg
       FROM line_items li
      WHERE li.invoice_id = v.invoice_id AND li.name IS NOT NULL AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text AND li.name ~* '(fee|fees|%)'::text) AND li.name !~* '^\s*tax\s*$'::text), ( SELECT (NULLIF(TRIM(BOTH FROM j.title), ''::text) || ' - '::text) || (( SELECT string_agg(li.name, ', '::text ORDER BY li.id) AS string_agg
         FROM line_items li
        WHERE li.job_id = v.job_id AND li.invoice_id IS NULL AND li.name IS NOT NULL AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text AND li.name ~* '(fee|fees|%)'::text) AND li.name !~* '^\s*tax\s*$'::text))
       FROM jobs j
      WHERE j.id = v.job_id AND j.title IS NOT NULL AND TRIM(BOTH FROM j.title) <> ''::text AND (EXISTS ( SELECT 1
         FROM line_items li
        WHERE li.job_id = v.job_id AND li.invoice_id IS NULL AND li.name IS NOT NULL AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text AND li.name ~* '(fee|fees|%)'::text) AND li.name !~* '^\s*tax\s*$'::text))), ( SELECT string_agg(li.name, ', '::text ORDER BY li.id) AS string_agg
       FROM line_items li
      WHERE li.job_id = v.job_id AND li.invoice_id IS NULL AND li.name IS NOT NULL AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text AND li.name ~* '(fee|fees|%)'::text) AND li.name !~* '^\s*tax\s*$'::text), ( SELECT (NULLIF(TRIM(BOTH FROM j.title), ''::text) || ' - '::text) || (( SELECT string_agg(li.name, ', '::text ORDER BY li.id) AS string_agg
         FROM line_items li
        WHERE li.visit_id = v.id AND li.name IS NOT NULL AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text AND li.name ~* '(fee|fees|%)'::text) AND li.name !~* '^\s*tax\s*$'::text))
       FROM jobs j
      WHERE j.id = v.job_id AND j.title IS NOT NULL AND TRIM(BOTH FROM j.title) <> ''::text AND (EXISTS ( SELECT 1
         FROM line_items li
        WHERE li.visit_id = v.id AND li.name IS NOT NULL AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text AND li.name ~* '(fee|fees|%)'::text) AND li.name !~* '^\s*tax\s*$'::text))), ( SELECT string_agg(li.name, ', '::text ORDER BY li.id) AS string_agg
       FROM line_items li
      WHERE li.visit_id = v.id AND li.name IS NOT NULL AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text AND li.name ~* '(fee|fees|%)'::text) AND li.name !~* '^\s*tax\s*$'::text), NULLIF(TRIM(BOTH FROM split_part(v.title, ' - '::text, 2)), ''::text), ( SELECT NULLIF(TRIM(BOTH FROM j.title), ''::text) AS "nullif"
       FROM jobs j
      WHERE j.id = v.job_id)) AS line_items,
      COALESCE(( SELECT NULLIF(jsonb_agg(jsonb_build_object('name', li.name, 'quantity', li.quantity, 'unit_price', li.unit_price, 'total_price', li.total_price) ORDER BY li.id), '[]'::jsonb) AS "nullif"
       FROM line_items li
      WHERE li.visit_id = v.id AND (( SELECT COALESCE(sum(li2.total_price), 0::numeric) AS "coalesce"
         FROM line_items li2
        WHERE li2.visit_id = v.id)) > 0::numeric), ( SELECT NULLIF(jsonb_agg(jsonb_build_object('name', li.name, 'quantity', li.quantity, 'unit_price', li.unit_price, 'total_price', li.total_price) ORDER BY li.id), '[]'::jsonb) AS "nullif"
       FROM line_items li
      WHERE li.invoice_id = v.invoice_id), ( SELECT NULLIF(jsonb_agg(jsonb_build_object('name', li.name, 'quantity', li.quantity, 'unit_price', li.unit_price, 'total_price', li.total_price) ORDER BY li.id), '[]'::jsonb) AS "nullif"
       FROM line_items li
      WHERE li.job_id = v.job_id AND li.invoice_id IS NULL), ( SELECT NULLIF(jsonb_agg(jsonb_build_object('name', li.name, 'quantity', li.quantity, 'unit_price', li.unit_price, 'total_price', li.total_price) ORDER BY li.id), '[]'::jsonb) AS "nullif"
       FROM line_items li
      WHERE li.visit_id = v.id), '[]'::jsonb) AS line_items_json,
      ( SELECT g.gdo_number
       FROM gdos g
      WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text
      ORDER BY g.id
     LIMIT 1) AS gdo_number,
      ( SELECT j.job_number
       FROM jobs j
      WHERE j.id = v.job_id) AS job_number
     FROM visits v
       JOIN clients c ON c.id = v.client_id
       LEFT JOIN LATERAL ( SELECT p2.address,
        p2.county
       FROM properties p2
      WHERE p2.client_id = c.id
      ORDER BY p2.is_primary DESC NULLS LAST, (p2.is_billing IS NOT TRUE) DESC, p2.id
     LIMIT 1) p ON true
    WHERE v.deleted_at IS NULL AND v.visit_status = 'completed'::text) sub) w) _dv
                          WHERE NOT (_dv.client_id IN ( SELECT clients.id
                                   FROM clients
                                  WHERE public.fn_is_non_customer(clients.id, ARRAY['dump_site'::text])))) dv) w2
             LEFT JOIN LATERAL ( SELECT mr.manifest_id,
                    mr.has_pdf,
                    mr.has_email,
                    mr.has_city_email,
                    mr.municipality
                   FROM manifest_visits mv
                     JOIN derm.manifest_recipients mr ON mr.manifest_id = mv.manifest_id AND mr.client_id = w2.client_id
                  WHERE mv.visit_id = w2.id
                  ORDER BY mr.manifest_id DESC
                 LIMIT 1) em ON true) w3;

CREATE OR REPLACE VIEW public.manifest_pickable_visits AS
 SELECT visit_id,
    visit_date,
    start_at,
    completed_at,
    service_type,
    title,
    client_id,
    client_code,
    client_name,
    address,
    city,
    county,
    fn_dump_county_bucket(county) AS county_bucket
   FROM ( SELECT v.id AS visit_id,
            v.visit_date,
            v.start_at,
            v.completed_at,
            v.service_type,
            v.title,
            c.id AS client_id,
            c.client_code,
            c.name AS client_name,
            COALESCE(p.address, primary_p.address) AS address,
            COALESCE(p.city, primary_p.city) AS city,
            COALESCE(p.county, primary_p.county) AS county
           FROM visits v
             JOIN clients c ON c.id = v.client_id
             LEFT JOIN properties p ON p.id = v.property_id
             LEFT JOIN properties primary_p ON primary_p.client_id = v.client_id AND primary_p.is_primary = true
          WHERE v.visit_status = 'completed'::text AND (v.derm_required IS NULL OR v.derm_required = true) AND v.deleted_at IS NULL AND NOT (EXISTS ( SELECT 1
                   FROM manifest_visits mv
                     JOIN derm_manifests dm ON dm.id = mv.manifest_id
                  WHERE mv.visit_id = v.id AND dm.deleted_at IS NULL))) _pv
  WHERE NOT (client_id IN ( SELECT clients.id
           FROM clients
          WHERE public.fn_is_non_customer(clients.id, ARRAY['dump_site'::text])));

CREATE OR REPLACE VIEW public.v_sa_schedule_gaps AS
 SELECT j.id AS job_id,
    j.job_number,
    j.title,
    j.frequency_days,
    j.job_status,
    c.id AS client_id,
    c.client_code,
    c.name AS client_name,
    c.status AS client_status,
    j.created_at AS job_created_at,
    round(EXTRACT(epoch FROM now() - j.created_at) / 86400.0, 1) AS job_age_days,
    'frequency_unset'::text AS gap_reason
   FROM jobs j
     JOIN clients c ON c.id = j.client_id
  WHERE (j.frequency_days IS NULL OR j.frequency_days <= 0) AND j.title ~~* 'Service Agreement%'::text AND j.title !~~* '%[OLD]%'::text AND COALESCE(j.job_status, ''::text) <> 'archived'::text AND (c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text])) AND c.client_code IS NOT NULL AND (NOT public.fn_is_non_customer(c.id)) AND (EXISTS ( SELECT 1
           FROM line_items lp
             JOIN service_line_items slip ON slip.code = lpad("substring"(btrim(lp.name), '^([0-9]+)'::text), 2, '0'::text)
          WHERE lp.job_id = j.id AND lp.invoice_id IS NULL AND (slip.reason = ANY (ARRAY['Service Agreement'::text, 'Service Call'::text])) AND slip.code <> '08'::text)) AND NOT (EXISTS ( SELECT 1
           FROM visits v
          WHERE v.job_id = j.id AND v.deleted_at IS NULL AND v.visit_date >= CURRENT_DATE)) AND j.created_at < (now() - '25:00:00'::interval)
  ORDER BY j.created_at DESC;

-- ============================================================================================
-- VERIFY
-- ============================================================================================
DO $verify$
DECLARE r record; v_now int; v_hard int; v_ref int;
BEGIN
  -- 1. The three views return EXACTLY what they returned before the replacement.
  FOR r IN SELECT * FROM _before LOOP
    EXECUTE format('SELECT count(*) FROM %s',
      CASE r.obj WHEN 'derm.visits' THEN 'derm.visits'
                 WHEN 'manifest_pickable_visits' THEN 'public.manifest_pickable_visits'
                 ELSE 'public.v_sa_schedule_gaps' END) INTO v_now;
    IF v_now <> r.n THEN
      RAISE EXCEPTION 'VERIFY 1 FAILED: % moved from % to % rows. This was meant to be a no-op.',
        r.obj, r.n, v_now;
    END IF;
  END LOOP;
  IF (SELECT count(*) FROM _before) <> 3 THEN
    RAISE EXCEPTION 'VERIFY 1 CONTROL FAILED: the snapshot is not 3 rows, so the loop proves nothing.';
  END IF;

  -- 2. No hardcoded dump predicate survives in any of the six. Comments may still mention the
  --    codes, which is documentation; these patterns are the executable shapes that were replaced.
  SELECT count(*) INTO v_hard FROM (
    SELECT prosrc AS src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('dump_manifest_link','dump_test_cleanup','dump_route_today')
    UNION ALL SELECT pg_get_viewdef('derm.visits'::regclass, true)
    UNION ALL SELECT pg_get_viewdef('public.manifest_pickable_visits'::regclass, true)
    UNION ALL SELECT pg_get_viewdef('public.v_sa_schedule_gaps'::regclass, true)
  ) t
  WHERE t.src LIKE '%client_id IN (365, 76)%'
     OR t.src LIKE '%NOT LIKE ''000%'
     OR t.src LIKE '%''000-DH''::text, ''000-DP''::text%'
     OR t.src LIKE '%''112-YA''::text, ''777-YA''::text%';
  IF v_hard <> 0 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: % object(s) still carry a hardcoded dump predicate.', v_hard;
  END IF;

  -- 3. All six now reference the single definition. CONTROL: it must be 6, not merely non-zero.
  SELECT count(*) INTO v_ref FROM (
    SELECT prosrc AS src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('dump_manifest_link','dump_test_cleanup','dump_route_today')
    UNION ALL SELECT pg_get_viewdef('derm.visits'::regclass, true)
    UNION ALL SELECT pg_get_viewdef('public.manifest_pickable_visits'::regclass, true)
    UNION ALL SELECT pg_get_viewdef('public.v_sa_schedule_gaps'::regclass, true)
  ) t WHERE t.src LIKE '%fn_is_non_customer%';
  IF v_ref <> 6 THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: only % of 6 objects reference fn_is_non_customer.', v_ref;
  END IF;

  RAISE NOTICE 'ALL VERIFY PASSED (3 views unchanged, 6 objects on one definition)';
END
$verify$;

COMMIT;
