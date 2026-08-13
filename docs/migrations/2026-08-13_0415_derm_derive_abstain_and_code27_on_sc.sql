-- ============================================================================
-- 2026-08-13_0415: let the derm derive ABSTAIN, and offer code 27 on Service Calls
-- ============================================================================
-- Fred, 2026-08-13: "B-VISIT, go ahead."  His ask: "The line 27, for GDO Report Online
-- should also be selectable for the SC Jobs, because a one time off visit could need a GDO
-- Report too."  Planned jointly with @Building Apps, who found STEP 0 and asked me to check it.
--
-- TWO CHANGES. Step 0 is a correctness fix and is required BEFORE 27 becomes offerable;
-- shipping the offer without it would manufacture invisible visits.
--
-- ── STEP 0: stop writing a hard FALSE where the catalogue cannot say "I don't know" ──
--
-- `service_line_items.requires_derm` is NOT NULL, so it cannot abstain. Three catalogue lines
-- genuinely have no DERM opinion (25 credit-card fee, 26 ACH fee, 27 GDO Online Reporting) and
-- the canonical helper says so:
--     fn_line_item_requires_derm('27 - GDO Online Reporting') -> NULL
--     controls, same statement: '01 - ...Pumping' -> true,  '05 - ...Cleaning' -> false
-- The RPCs derived from the COLUMN and then wrote COALESCE(v_derm, false), so a visit whose
-- lines all abstain was written derm_required = HARD FALSE.
--
-- 🛑 WHY THAT IS NOT COSMETIC. `rederive_visits_derm_required` fills only NULLs, so a hard false
-- is never repaired; and `customer.work_orders` filters COALESCE(derm_required,true)=true, so the
-- visit's ENTIRE service record vanishes from the client's Field Portal, not just a DERM chip.
-- @Building Apps hit exactly this from the other end on 2026-08-13: Diego classified 11 photos on
-- visit 7674 (306-16, a Cleaning, derm_required=false) and they were invisible because the whole
-- visit is filtered out.
--
-- 🛑 IT WAS THREE SITES, NOT TWO — AND ONE ALREADY CALLED THE HELPER AND WAS STILL BROKEN.
--     create_calendar_visit  L23 bool_or(requires_derm)                   L30  COALESCE(v_derm,false)
--     edit_calendar_visit    L83 bool_or(requires_derm)                   L85  COALESCE(v_derm,false)
--     edit_calendar_visit    L128 bool_or(fn_line_item_requires_derm(..)) L133 COALESCE(v_derm,false)
-- The third path already used the helper and threw the abstention away one line later.
-- ⇒ **The COALESCE was the defect, not the column.** "Switch to the helper" alone fixes nothing
--   at that site. All three now write v_derm directly; visits.derm_required is nullable.
-- The catalogue column stays NOT NULL — docs/reference/derm_required_by_line_item.md rejects
-- making it nullable, and this change does not need it.
--
-- ✅ ZERO IMPACT ON EXISTING DATA, measured before writing this:
--     active catalogue lines where the helper abstains ......  3  (25, 26, 27)
--     active lines where helper and column DISAGREE .........  0  of 28
--     alive visits whose line items ALL abstain .............  0  of 1,771
-- So no row changes today. This is purely forward-looking.
--
-- ── THE B-VISIT CHANGE: offer 27 on a Service Call ──
--
-- `ops.create_visit_request` and `ops.update_visit_request` rejected anything that was not
-- (reason='Service Call' AND schedulable AND active), so the To Be Scheduled card would have
-- refused a 27 the Calendar picker offered. Both now also accept an active code 27.
--
-- 🛑 DELIBERATELY NOT DONE, and each would cause real damage:
--   * `service_line_items.schedulable` for 27 stays FALSE. save-client-job relies on 25/26/27
--     being non-schedulable; flipping it would let 27 onto job settings.
--   * `reason` for 27 stays 'other'. Flipping it to 'Service Call' would make 27 count as a
--     physical service in fn_generate_sa_visits, and 7 SA jobs already carry a 27 line, so a
--     GDO-only SA job would start minting recurring visits.
--   * save-client-job is untouched (SA-only under B-VISIT).
--   * The Calendar picker predicate is @Building Apps' change, in the bundle. Not mine.
--
-- 🛑 A CORRECTION TO THE PLAN THIS IMPLEMENTS, because it changes what we are doing.
-- @Building Apps wrote that 27 is "already live on ~30 SC visits" and that
-- fn_visit_is_gdo_reporting returns true for "84 visits (55 SA + 29 SC)". Measured:
--     the 84, by ops.v_calendar_visit.service_kind ....  SA 84,  SC 0
--     the 84, by job title .. 55 Service Agreement · 12 Grease Trap Pumping · 10 [OLD] · 7 & Warranty
--     visits with a 27 line on a SERVICE CALL job ....  0
--     SERVICE CALL jobs carrying a 27 line ...........  0
--     visits carrying a 27 line ......................  33 (not ~30), all service_kind='SA'
-- The "29 SC" are legacy SA-shaped jobs. **Code 27 has never appeared on an SC at either scope.**
-- ⇒ This is NEW behaviour, not the formalisation of something already happening. The reading that
--   the bot queue / customer.gdo_reports / derm.gdo_report_status are SA/SC-agnostic is a CODE
--   reading and may well be right, but it is UNEXERCISED on SC, not proven by those 29.
--   Exercise a real SC visit end-to-end before trusting it.
--
-- ── HOW THIS WAS VERIFIED (rolled-back probe, run before applying) ──
-- Bodies were COPIED from pg_get_functiondef and edited in place, never retyped; the diff is
-- exactly 6 lines across 4 functions and nothing else moved. PL/pgSQL is not parsed at creation,
-- so the functions were then EXERCISED end-to-end in a transaction that ended in RAISE:
--     A  control: old expr -> false, new expr -> NULL   (proves the assertions discriminate)
--     B  27-only visit          -> NULL     (was a hard false)
--     C  pumping-only           -> true     (guards against over-correcting to NULL)
--     D  cleaning-only          -> false
--     E  pumping + 27           -> true     (bool_or ignores the abstention, is not poisoned)
--     F  cleaning + 27          -> false
--     G  ops.create_visit_request(27)  -> accepted
--     H  NEGATIVE control: ops.create_visit_request(25 fee) -> still rejected
-- All eight passed. `app.suppress_jobber_push` was set so the probe could not create real Jobber
-- visits (trg_push_visit_insert fires on INSERT).
--
-- AUDIT-TRAIL STANDING CHECK (rule 8): no table changes. public.visits keeps its audit trigger;
-- derm_required writes continue to land in audit.logs with old_row intact.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.create_calendar_visit(p_client_id bigint, p_job_id bigint, p_service_line_item_ids bigint[], p_visit_date date, p_property_id bigint DEFAULT NULL::bigint, p_client_location_ids bigint[] DEFAULT NULL::bigint[], p_start_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_end_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_title text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_vehicle_id bigint DEFAULT NULL::bigint, p_driver_id bigint DEFAULT NULL::bigint, p_line_item_prices jsonb DEFAULT NULL::jsonb, p_team_ids bigint[] DEFAULT NULL::bigint[], p_line_item_descriptions jsonb DEFAULT NULL::jsonb)
 RETURNS visits
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_primary bigint; v_service_type text; v_derm boolean; v_property bigint; v_visit public.visits;
  v_team bigint[];
BEGIN
  IF p_client_id IS NULL OR p_job_id IS NULL OR p_visit_date IS NULL
     OR p_service_line_item_ids IS NULL OR array_length(p_service_line_item_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'create_calendar_visit: client_id, job_id, visit_date and >=1 service are required';
  END IF;
  PERFORM 1 FROM jobs WHERE id = p_job_id AND client_id = p_client_id AND job_status <> 'archived';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'create_calendar_visit: job % is not an active job for client %', p_job_id, p_client_id;
  END IF;

  v_team := COALESCE(p_team_ids, CASE WHEN p_driver_id IS NOT NULL THEN ARRAY[p_driver_id] ELSE '{}'::bigint[] END);
  v_primary := COALESCE(p_team_ids[1], p_driver_id);
  SELECT service_type INTO v_service_type FROM service_line_items WHERE id = p_service_line_item_ids[1];
  SELECT bool_or(public.fn_line_item_requires_derm(title)) INTO v_derm FROM service_line_items WHERE id = ANY (p_service_line_item_ids);
  v_property := COALESCE(p_property_id, (SELECT property_id FROM jobs WHERE id = p_job_id),
    (SELECT id FROM properties WHERE client_id = p_client_id AND is_primary ORDER BY id LIMIT 1));

  INSERT INTO visits (client_id, job_id, property_id, vehicle_id, assigned_driver_id, visit_date, start_at, end_at,
                      title, service_type, service_line_item_id, derm_required, notes, visit_status, source)
  VALUES (p_client_id, p_job_id, v_property, p_vehicle_id, v_primary, p_visit_date, p_start_at, p_end_at,
          p_title, v_service_type, p_service_line_item_ids[1], v_derm, p_notes, 'scheduled', 'visit-calendar')
  RETURNING * INTO v_visit;

  INSERT INTO visit_team (visit_id, employee_id)
  SELECT v_visit.id, e FROM unnest(v_team) AS e WHERE e IS NOT NULL ON CONFLICT DO NOTHING;

  -- Per-line-item description/note (like Jobber's line-item description). p_line_item_descriptions
  -- is a jsonb map { "<service_line_item_id>": "note text" }; absent/blank -> '' (Fred 2026-07-02).
  INSERT INTO line_items (visit_id, name, description, quantity, unit_price, total_price, taxable)
  SELECT v_visit.id, s.title,
    COALESCE(NULLIF(btrim(p_line_item_descriptions ->> s.id::text), ''), ''),
    COALESCE((p_line_item_prices -> s.id::text ->> 'quantity')::numeric, 1),
    COALESCE((p_line_item_prices -> s.id::text ->> 'unit_price')::numeric, s.unit_price, 0),
    COALESCE((p_line_item_prices -> s.id::text ->> 'unit_price')::numeric, s.unit_price, 0)
      * COALESCE((p_line_item_prices -> s.id::text ->> 'quantity')::numeric, 1), false
  FROM service_line_items s WHERE s.id = ANY (p_service_line_item_ids);

  DELETE FROM visit_locations WHERE visit_id = v_visit.id;
  IF p_client_location_ids IS NOT NULL AND array_length(p_client_location_ids, 1) >= 1 THEN
    INSERT INTO visit_locations (visit_id, client_location_id)
    SELECT v_visit.id, x FROM unnest(p_client_location_ids) AS x ON CONFLICT DO NOTHING;
  ELSE
    INSERT INTO visit_locations (visit_id, client_location_id)
    SELECT v_visit.id, cl.id FROM client_locations cl
    WHERE cl.client_id = p_client_id AND cl.status = 'active'
    ORDER BY (cl.name = 'Main') DESC, cl.id LIMIT 1 ON CONFLICT DO NOTHING;
  END IF;
  RETURN v_visit;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.edit_calendar_visit(p_visit_id bigint, p_patch jsonb)
 RETURNS visits
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_visit visits; v_ids bigint[]; v_primary bigint; v_stype text; v_derm boolean;
BEGIN
  SELECT * INTO v_visit FROM visits WHERE id = p_visit_id AND deleted_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'edit_calendar_visit: visit % not found or deleted', p_visit_id; END IF;
  -- A skipped visit is removed from Jobber and holds its cadence slot — editing it would silently move
  -- that slot. Un-skip first (parity with ripple_reschedule_visit's guard). Added 2026-07-03.
  IF v_visit.visit_status = 'skipped' THEN
    RAISE EXCEPTION 'edit_calendar_visit: visit % is skipped — un-skip it first (unskip_visit)', p_visit_id;
  END IF;
  IF p_patch IS NULL OR p_patch = '{}'::jsonb THEN RETURN v_visit; END IF;

  UPDATE visits SET
    notes              = CASE WHEN p_patch ? 'notes'      THEN NULLIF(p_patch->>'notes','')        ELSE notes END,
    start_at           = CASE WHEN p_patch ? 'start_at'   THEN (p_patch->>'start_at')::timestamptz ELSE start_at END,
    end_at             = CASE WHEN p_patch ? 'end_at'     THEN (p_patch->>'end_at')::timestamptz   ELSE end_at END,
    visit_date         = CASE WHEN p_patch ? 'visit_date' THEN (p_patch->>'visit_date')::date      ELSE visit_date END,
    title              = CASE WHEN p_patch ? 'title'      THEN NULLIF(p_patch->>'title','')        ELSE title END,
    vehicle_id         = CASE WHEN p_patch ? 'vehicle_id' THEN (p_patch->>'vehicle_id')::bigint    ELSE vehicle_id END,
    assigned_driver_id = CASE WHEN p_patch ? 'driver_id'  THEN (p_patch->>'driver_id')::bigint     ELSE assigned_driver_id END
  WHERE id = p_visit_id;

  -- Team: replace + bump team_rev ONLY when the set actually changes (on-purpose signal).
  IF p_patch ? 'team_ids' THEN
    DECLARE v_incoming bigint[]; v_current bigint[];
    BEGIN
      SELECT COALESCE(array_agg(DISTINCT x::bigint ORDER BY x::bigint), '{}')
        INTO v_incoming FROM jsonb_array_elements_text(p_patch->'team_ids') AS x WHERE NULLIF(x,'') IS NOT NULL;
      SELECT COALESCE(array_agg(DISTINCT employee_id ORDER BY employee_id), '{}')
        INTO v_current FROM visit_team WHERE visit_id = p_visit_id;
      IF v_incoming IS DISTINCT FROM v_current THEN
        DELETE FROM visit_team WHERE visit_id = p_visit_id;
        INSERT INTO visit_team (visit_id, employee_id) SELECT p_visit_id, unnest(v_incoming) ON CONFLICT DO NOTHING;
        UPDATE visits SET assigned_driver_id = NULLIF(p_patch->'team_ids'->>0, '')::bigint, team_rev = team_rev + 1 WHERE id = p_visit_id;
      END IF;
    END;
  END IF;

  -- Catalog path: services chosen from the catalog. Replace + bump ONLY on a real change.
  IF p_patch ? 'service_line_item_ids' THEN
    SELECT array_agg(x::bigint) INTO v_ids FROM jsonb_array_elements_text(p_patch->'service_line_item_ids') AS x;
    IF v_ids IS NULL OR array_length(v_ids, 1) IS NULL THEN
      RAISE EXCEPTION 'edit_calendar_visit: at least one service is required';
    END IF;
    DECLARE v_inc text[]; v_cur text[]; v_prev_desc jsonb;
    BEGIN
      -- snapshot existing descriptions (name -> note) BEFORE any delete, to carry forward notes the
      -- patch does not explicitly provide (preserves descriptions on a qty/price-only edit).
      SELECT COALESCE(jsonb_object_agg(name, description), '{}'::jsonb) INTO v_prev_desc
        FROM (SELECT DISTINCT ON (name) name, description FROM line_items
              WHERE visit_id = p_visit_id AND NULLIF(btrim(description),'') IS NOT NULL
              ORDER BY name, id) d;
      SELECT array_agg(sig ORDER BY sig) INTO v_inc FROM (
        SELECT s.title || '|' || round(COALESCE((p_patch->'line_item_prices'->s.id::text->>'quantity')::numeric, 1), 3)::text
               || '|' || round(COALESCE((p_patch->'line_item_prices'->s.id::text->>'unit_price')::numeric, s.unit_price, 0), 2)::text
               || '|' || COALESCE(CASE WHEN (p_patch->'line_item_descriptions') ? s.id::text
                                       THEN NULLIF(btrim(p_patch->'line_item_descriptions'->>s.id::text), '')
                                       ELSE NULLIF(btrim(v_prev_desc->>s.title), '') END, '') AS sig
        FROM service_line_items s WHERE s.id = ANY (v_ids)) z;
      SELECT array_agg(sig ORDER BY sig) INTO v_cur FROM (
        SELECT name || '|' || round(quantity,3)::text || '|' || round(unit_price,2)::text
               || '|' || COALESCE(NULLIF(btrim(description),''),'') AS sig
        FROM line_items WHERE visit_id = p_visit_id) z;
      IF v_inc IS DISTINCT FROM v_cur THEN
        DELETE FROM line_items WHERE visit_id = p_visit_id;
        INSERT INTO line_items (visit_id, name, description, quantity, unit_price, total_price, taxable)
        SELECT p_visit_id, s.title,
          COALESCE(CASE WHEN (p_patch->'line_item_descriptions') ? s.id::text
                        THEN NULLIF(btrim(p_patch->'line_item_descriptions'->>s.id::text), '')
                        ELSE NULLIF(btrim(v_prev_desc->>s.title), '') END, ''),
          COALESCE((p_patch->'line_item_prices' -> s.id::text ->> 'quantity')::numeric, 1),
          COALESCE((p_patch->'line_item_prices' -> s.id::text ->> 'unit_price')::numeric, s.unit_price, 0),
          COALESCE((p_patch->'line_item_prices' -> s.id::text ->> 'unit_price')::numeric, s.unit_price, 0)
            * COALESCE((p_patch->'line_item_prices' -> s.id::text ->> 'quantity')::numeric, 1), false
        FROM service_line_items s WHERE s.id = ANY (v_ids);
        v_primary := v_ids[1];
        SELECT service_type INTO v_stype FROM service_line_items WHERE id = v_primary;
        SELECT bool_or(public.fn_line_item_requires_derm(title)) INTO v_derm FROM service_line_items WHERE id = ANY (v_ids);
        UPDATE visits SET service_line_item_id = v_primary, service_type = v_stype,
          derm_required = v_derm, line_items_rev = line_items_rev + 1 WHERE id = p_visit_id;
      END IF;
    END;
  END IF;

  -- Arbitrary path: full line list. Replace + bump ONLY on a real change.
  IF p_patch ? 'line_items' THEN
    IF jsonb_typeof(p_patch->'line_items') <> 'array' OR jsonb_array_length(p_patch->'line_items') = 0 THEN
      RAISE EXCEPTION 'edit_calendar_visit: line_items must be a non-empty array';
    END IF;
    DECLARE v_inc text[]; v_cur text[]; v_prev_desc jsonb;
    BEGIN
      SELECT COALESCE(jsonb_object_agg(name, description), '{}'::jsonb) INTO v_prev_desc
        FROM (SELECT DISTINCT ON (name) name, description FROM line_items
              WHERE visit_id = p_visit_id AND NULLIF(btrim(description),'') IS NOT NULL
              ORDER BY name, id) d;
      SELECT array_agg(sig ORDER BY sig) INTO v_inc FROM (
        SELECT (li->>'name') || '|' || round(COALESCE((li->>'quantity')::numeric,1),3)::text
               || '|' || round(COALESCE((li->>'unit_price')::numeric,0),2)::text
               || '|' || COALESCE(CASE WHEN li ? 'description'
                                       THEN NULLIF(btrim(li->>'description'), '')
                                       ELSE NULLIF(btrim(v_prev_desc->>(li->>'name')), '') END, '') AS sig
        FROM jsonb_array_elements(p_patch->'line_items') AS li WHERE COALESCE(li->>'name','') <> '') z;
      SELECT array_agg(sig ORDER BY sig) INTO v_cur FROM (
        SELECT name || '|' || round(quantity,3)::text || '|' || round(unit_price,2)::text
               || '|' || COALESCE(NULLIF(btrim(description),''),'') AS sig
        FROM line_items WHERE visit_id = p_visit_id) z;
      IF v_inc IS DISTINCT FROM v_cur THEN
        DELETE FROM line_items WHERE visit_id = p_visit_id;
        INSERT INTO line_items (visit_id, name, description, quantity, unit_price, total_price, taxable)
        SELECT p_visit_id, li->>'name',
          COALESCE(CASE WHEN li ? 'description'
                        THEN NULLIF(btrim(li->>'description'), '')
                        ELSE NULLIF(btrim(v_prev_desc->>(li->>'name')), '') END, ''),
          COALESCE((li->>'quantity')::numeric, 1),
          COALESCE((li->>'unit_price')::numeric, 0),
          COALESCE((li->>'unit_price')::numeric, 0) * COALESCE((li->>'quantity')::numeric, 1),
          COALESCE((li->>'taxable')::boolean, false)
        FROM jsonb_array_elements(p_patch->'line_items') AS li WHERE COALESCE(li->>'name','') <> '';
        SELECT s.id, s.service_type INTO v_primary, v_stype
        FROM jsonb_array_elements(p_patch->'line_items') WITH ORDINALITY AS t(li, ord)
        JOIN service_line_items s ON s.code = split_part(t.li->>'name', ' - ', 1)
        ORDER BY t.ord LIMIT 1;
        SELECT bool_or(public.fn_line_item_requires_derm(li->>'name')) INTO v_derm
        FROM jsonb_array_elements(p_patch->'line_items') AS li;
        UPDATE visits SET
          service_line_item_id = COALESCE(v_primary, service_line_item_id),
          service_type = COALESCE(v_stype, service_type),
          derm_required = v_derm,
          line_items_rev = line_items_rev + 1 WHERE id = p_visit_id;
      END IF;
    END;
  END IF;

  SELECT * INTO v_visit FROM visits WHERE id = p_visit_id;
  RETURN v_visit;
END;
$function$
;

CREATE OR REPLACE FUNCTION ops.create_visit_request(p_client_id bigint, p_job_id bigint, p_service_line_item_ids bigint[], p_property_id bigint DEFAULT NULL::bigint, p_client_location_ids bigint[] DEFAULT NULL::bigint[], p_title text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_line_item_prices jsonb DEFAULT NULL::jsonb, p_line_item_descriptions jsonb DEFAULT NULL::jsonb, p_vehicle_id bigint DEFAULT NULL::bigint, p_team_ids bigint[] DEFAULT NULL::bigint[])
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_id bigint; v_bad int;
BEGIN
  IF p_client_id IS NULL OR p_job_id IS NULL
     OR p_service_line_item_ids IS NULL OR array_length(p_service_line_item_ids,1) IS NULL THEN
    RAISE EXCEPTION 'create_visit_request: client_id, job_id and >=1 service are required';
  END IF;

  PERFORM 1 FROM jobs WHERE id = p_job_id AND client_id = p_client_id AND job_status <> 'archived';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'create_visit_request: job % is not an active job for client %', p_job_id, p_client_id;
  END IF;

  SELECT count(*) INTO v_bad FROM unnest(p_service_line_item_ids) x
   WHERE NOT EXISTS (SELECT 1 FROM service_line_items s
                      WHERE s.id = x AND s.active AND ((s.reason = 'Service Call' AND s.schedulable) OR s.code = '27'));
  IF v_bad > 0 THEN
    RAISE EXCEPTION 'create_visit_request: % non Service-Call service(s) supplied', v_bad;
  END IF;

  INSERT INTO ops.visit_requests (client_id, job_id, property_id, title, notes, vehicle_id)
  VALUES (p_client_id, p_job_id, p_property_id, p_title, p_notes, p_vehicle_id)
  RETURNING id INTO v_id;

  INSERT INTO ops.visit_request_services (request_id, service_line_item_id, seq_no, quantity, unit_price, description)
  SELECT v_id, x.id, x.ord::smallint,
         (p_line_item_prices -> x.id::text ->> 'quantity')::numeric,
         (p_line_item_prices -> x.id::text ->> 'unit_price')::numeric,
         nullif(btrim(p_line_item_descriptions ->> x.id::text), '')
    FROM unnest(p_service_line_item_ids) WITH ORDINALITY AS x(id, ord);

  IF p_client_location_ids IS NOT NULL AND array_length(p_client_location_ids,1) IS NOT NULL THEN
    INSERT INTO ops.visit_request_locations (request_id, client_location_id)
    SELECT v_id, l FROM unnest(p_client_location_ids) l ON CONFLICT DO NOTHING;
  END IF;

  IF p_team_ids IS NOT NULL AND array_length(p_team_ids,1) IS NOT NULL THEN
    INSERT INTO ops.visit_request_team (request_id, employee_id, seq_no)
    SELECT v_id, x.id, x.ord::smallint
      FROM unnest(p_team_ids) WITH ORDINALITY AS x(id, ord)
    ON CONFLICT DO NOTHING;
  END IF;

  RETURN v_id;
END $function$
;

CREATE OR REPLACE FUNCTION ops.update_visit_request(p_request_id bigint, p_patch jsonb)
 RETURNS ops.visit_requests
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE r ops.visit_requests; v_ids bigint[]; v_bad int; v_locs bigint[]; v_team bigint[];
BEGIN
  SELECT * INTO r FROM ops.visit_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND OR r.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'update_visit_request: request % not found', p_request_id;
  END IF;
  IF r.status <> 'open' THEN
    RAISE EXCEPTION 'update_visit_request: request % is % and can no longer be edited', p_request_id, r.status;
  END IF;
  IF p_patch IS NULL OR p_patch = '{}'::jsonb THEN RETURN r; END IF;

  -- Refuse loudly rather than silently ignoring a key the caller believed would apply.
  IF p_patch ?| ARRAY['client_id','job_id','status','converted_visit_id','converted_at','deleted_at','cancel_reason'] THEN
    RAISE EXCEPTION 'update_visit_request: client_id, job_id and lifecycle fields are not editable; remove and recreate instead';
  END IF;

  -- Scalars. Key presence decides; an absent key leaves the column untouched.
  UPDATE ops.visit_requests SET
    title       = CASE WHEN p_patch ? 'title'       THEN NULLIF(p_patch->>'title','')      ELSE title END,
    notes       = CASE WHEN p_patch ? 'notes'       THEN NULLIF(p_patch->>'notes','')      ELSE notes END,
    property_id = CASE WHEN p_patch ? 'property_id' THEN (p_patch->>'property_id')::bigint ELSE property_id END,
    vehicle_id  = CASE WHEN p_patch ? 'vehicle_id'  THEN (p_patch->>'vehicle_id')::bigint  ELSE vehicle_id END
  WHERE id = p_request_id;

  -- Services: replace on presence. Validated exactly like create_visit_request.
  IF p_patch ? 'service_line_item_ids' THEN
    SELECT array_agg(x::bigint) INTO v_ids
      FROM jsonb_array_elements_text(p_patch->'service_line_item_ids') AS x;
    IF v_ids IS NULL OR array_length(v_ids,1) IS NULL THEN
      RAISE EXCEPTION 'update_visit_request: at least one service is required';
    END IF;
    SELECT count(*) INTO v_bad FROM unnest(v_ids) x
     WHERE NOT EXISTS (SELECT 1 FROM service_line_items s
                        WHERE s.id = x AND s.active AND ((s.reason = 'Service Call' AND s.schedulable) OR s.code = '27'));
    IF v_bad > 0 THEN
      RAISE EXCEPTION 'update_visit_request: % non Service-Call service(s) supplied', v_bad;
    END IF;

    DELETE FROM ops.visit_request_services WHERE request_id = p_request_id;
    INSERT INTO ops.visit_request_services (request_id, service_line_item_id, seq_no, quantity, unit_price, description)
    SELECT p_request_id, x.id, x.ord::smallint,
           (p_patch -> 'line_item_prices' -> x.id::text ->> 'quantity')::numeric,
           (p_patch -> 'line_item_prices' -> x.id::text ->> 'unit_price')::numeric,
           nullif(btrim(p_patch -> 'line_item_descriptions' ->> x.id::text), '')
      FROM unnest(v_ids) WITH ORDINALITY AS x(id, ord);
  END IF;

  IF p_patch ? 'client_location_ids' THEN
    SELECT array_agg(x::bigint) INTO v_locs
      FROM jsonb_array_elements_text(p_patch->'client_location_ids') AS x;
    DELETE FROM ops.visit_request_locations WHERE request_id = p_request_id;
    IF v_locs IS NOT NULL AND array_length(v_locs,1) IS NOT NULL THEN
      INSERT INTO ops.visit_request_locations (request_id, client_location_id)
      SELECT p_request_id, l FROM unnest(v_locs) l ON CONFLICT DO NOTHING;
    END IF;
  END IF;

  IF p_patch ? 'team_ids' THEN
    SELECT array_agg(x::bigint) INTO v_team
      FROM jsonb_array_elements_text(p_patch->'team_ids') AS x WHERE NULLIF(x,'') IS NOT NULL;
    DELETE FROM ops.visit_request_team WHERE request_id = p_request_id;
    IF v_team IS NOT NULL AND array_length(v_team,1) IS NOT NULL THEN
      INSERT INTO ops.visit_request_team (request_id, employee_id, seq_no)
      SELECT p_request_id, x.id, x.ord::smallint
        FROM unnest(v_team) WITH ORDINALITY AS x(id, ord)
      ON CONFLICT DO NOTHING;
    END IF;
  END IF;

  SELECT * INTO r FROM ops.visit_requests WHERE id = p_request_id;
  RETURN r;
END $function$
;


DO $verify$
DECLARE
  d_ccv text; d_ecv text; d_opc text; d_opu text;
  v_ctl text; v_27 record; v_abstain int; v_disagree int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d_ccv FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE p.proname='create_calendar_visit' AND n.nspname='public';
  SELECT pg_get_functiondef(p.oid) INTO d_ecv FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE p.proname='edit_calendar_visit' AND n.nspname='public';
  SELECT pg_get_functiondef(p.oid) INTO d_opc FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE p.proname='create_visit_request' AND n.nspname='ops';
  SELECT pg_get_functiondef(p.oid) INTO d_opu FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE p.proname='update_visit_request' AND n.nspname='ops';

  -- (a) the abstention can now survive: NO COALESCE(v_derm,...) anywhere
  IF d_ccv ILIKE '%COALESCE(v_derm%' THEN RAISE EXCEPTION 'create_calendar_visit still coalesces v_derm'; END IF;
  IF d_ecv ILIKE '%COALESCE(v_derm%' THEN RAISE EXCEPTION 'edit_calendar_visit still coalesces v_derm'; END IF;

  -- (b) and both derive through the canonical helper
  IF d_ccv NOT ILIKE '%fn_line_item_requires_derm%' THEN RAISE EXCEPTION 'create_calendar_visit does not call the helper'; END IF;
  IF d_ecv NOT ILIKE '%fn_line_item_requires_derm%' THEN RAISE EXCEPTION 'edit_calendar_visit does not call the helper'; END IF;

  -- (c) neither still reads the catalogue column for the derive
  IF d_ccv ILIKE '%bool_or(requires_derm)%' THEN RAISE EXCEPTION 'create_calendar_visit still derives off the column'; END IF;
  IF d_ecv ILIKE '%bool_or(requires_derm)%' THEN RAISE EXCEPTION 'edit_calendar_visit still derives off the column'; END IF;

  -- (d) the request RPCs accept 27 and are still scoped (the OR arm names code 27 explicitly)
  IF d_opc NOT LIKE '%OR s.code = ''27''%' THEN RAISE EXCEPTION 'ops.create_visit_request was not widened'; END IF;
  IF d_opu NOT LIKE '%OR s.code = ''27''%' THEN RAISE EXCEPTION 'ops.update_visit_request was not widened'; END IF;
  IF d_opc NOT LIKE '%s.schedulable%' THEN RAISE EXCEPTION 'ops.create_visit_request lost its schedulable guard'; END IF;
  IF d_opu NOT LIKE '%s.schedulable%' THEN RAISE EXCEPTION 'ops.update_visit_request lost its schedulable guard'; END IF;

  -- (e) 🛑 THE CATALOGUE MUST BE UNTOUCHED. Flipping either of these is the damaging move.
  SELECT code, schedulable, reason, active, requires_derm INTO v_27
    FROM public.service_line_items WHERE code='27';
  IF v_27.schedulable IS NOT FALSE THEN RAISE EXCEPTION 'code 27 schedulable is now % — must stay false', v_27.schedulable; END IF;
  IF v_27.reason <> 'other'         THEN RAISE EXCEPTION 'code 27 reason is now % — must stay other', v_27.reason; END IF;
  IF v_27.active IS NOT TRUE        THEN RAISE EXCEPTION 'code 27 is no longer active'; END IF;
  IF v_27.requires_derm IS NOT FALSE THEN RAISE EXCEPTION 'code 27 requires_derm moved — the column was not meant to change'; END IF;

  -- (f) the helper still abstains on exactly 3 lines and disagrees with the column nowhere.
  -- If this drifts, the blast-radius claim in the header is no longer true.
  SELECT count(*) INTO v_abstain FROM public.service_line_items
   WHERE active AND public.fn_line_item_requires_derm(title) IS NULL;
  IF v_abstain <> 3 THEN RAISE EXCEPTION 'helper now abstains on % active lines, expected 3 (25/26/27)', v_abstain; END IF;
  SELECT count(*) INTO v_disagree FROM public.service_line_items
   WHERE active AND public.fn_line_item_requires_derm(title) IS NOT NULL
     AND public.fn_line_item_requires_derm(title) <> requires_derm;
  IF v_disagree <> 0 THEN RAISE EXCEPTION 'helper and column disagree on % active lines', v_disagree; END IF;

  -- (g) POSITIVE CONTROL. Every check above passes if I simply replaced all four functions with
  -- anything. Assert an UNTOUCHED sibling still has its original shape: ops.create_visit_request
  -- and ops.update_visit_request were edited, so use fn_generate_sa_visits, which must still
  -- exclude code 08 — the guard that stops warranty-only jobs minting recurring visits.
  SELECT pg_get_functiondef(p.oid) INTO v_ctl FROM pg_proc p WHERE p.proname='fn_generate_sa_visits' LIMIT 1;
  IF v_ctl IS NULL OR v_ctl NOT LIKE '%08%' THEN
    RAISE EXCEPTION 'control fn_generate_sa_visits missing or no longer references code 08';
  END IF;

  RAISE NOTICE 'derm derive can now abstain (3 sites); ops request RPCs accept code 27; catalogue untouched';
END
$verify$;
