-- ROLLBACK for 2026-11-02_1800 / _1810 / _1820 (permits for every county and city), newest first.
-- Generated from the live bodies read on 2026-11-02 (never retyped). Run as one transaction.
-- It REFUSES, and says so, when a permit other than row 141 has a type other than GDO, or any permit has an effective
-- date: dropping the columns would lose that data. Change or remove those rows first (by hand, with Fred).
-- Each function is restored only if its body is still exactly what the migration wrote (md5 pin).
-- The two views that gained columns (client.gdos, customer.permits) are dropped and re-created with their grants
-- (no other view depends on them, checked 2026-11-02); the other five are replaced in place.

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $refuse$
BEGIN
  IF EXISTS (SELECT 1 FROM public.gdos WHERE permit_type <> 'GDO' AND id <> 141) THEN
    RAISE EXCEPTION 'permits rollback: % permit(s) other than row 141 are not GDO; rolling back would lose their type',
      (SELECT count(*) FROM public.gdos WHERE permit_type <> 'GDO' AND id <> 141);
  END IF;
  IF EXISTS (SELECT 1 FROM public.gdos WHERE permit_effective IS NOT NULL) THEN
    RAISE EXCEPTION 'permits rollback: % permit(s) have an effective date; rolling back would lose it',
      (SELECT count(*) FROM public.gdos WHERE permit_effective IS NOT NULL);
  END IF;
END $refuse$;

-- derm.audit_pack
DO $f0$
BEGIN
  IF md5(pg_get_functiondef('derm.audit_pack(bigint)'::regprocedure)) <> '50057524b986a6f33ab2bb07057527bc' THEN
    RAISE EXCEPTION 'permits rollback: derm.audit_pack is not the body the migration wrote (md5 %)', md5(pg_get_functiondef('derm.audit_pack(bigint)'::regprocedure));
  END IF;
  EXECUTE $old$CREATE OR REPLACE FUNCTION derm.audit_pack(p_manifest_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public', 'audit'
AS $function$
DECLARE
  v_m   public.derm_manifests%ROWTYPE;
  v_out jsonb;
BEGIN
  SELECT * INTO v_m FROM public.derm_manifests WHERE id = p_manifest_id;
  IF v_m.id IS NULL THEN RAISE EXCEPTION 'manifest % not found', p_manifest_id; END IF;

  SELECT jsonb_build_object(
    'generated_at', now(),
    'manifest', jsonb_build_object(
      'id', v_m.id,
      'white_manifest_number', v_m.white_manifest_number,
      'yellow_ticket_number',  v_m.yellow_ticket_number,
      'service_date',          v_m.service_date,
      'dump_ticket_date',      v_m.dump_ticket_date,
      'disposal_facility', (SELECT df.name FROM public.disposal_facilities df
                             WHERE df.id = v_m.disposal_facility_id),
      'deleted', v_m.deleted_at IS NOT NULL),
    'documents', jsonb_strip_nulls(jsonb_build_object(
      'manifest_form_url',  v_m.derm_manifest_url,
      'wwtp_receipt_path',  v_m.wwtp_receipt_document_path,
      'address_sheet_url',  v_m.derm_address_url,
      'address_sheet_extra_urls', to_jsonb(v_m.derm_address_extra_urls),
      'fog_manifest_url',   v_m.fog_manifest_url)),
    'client', (SELECT jsonb_build_object(
        'id', c.id, 'client_code', c.client_code, 'name', c.name, 'status', c.status,
        'address', (SELECT p.address || ', ' || coalesce(p.city,'')
                      FROM public.properties p WHERE p.client_id = c.id ORDER BY p.id LIMIT 1))
      FROM public.clients c WHERE c.id = v_m.client_id),
    'gdo', (SELECT jsonb_build_object(
        'gdo_number', g.gdo_number, 'status', g.status,
        'permit_expiration', g.permit_expiration,
        'max_frequency_days', g.max_frequency_days)
      FROM public.gdos g
      WHERE g.id = coalesce(v_m.gdo_id,
              (SELECT g2.id FROM public.gdos g2
                WHERE g2.client_id = v_m.client_id AND g2.status = 'ACTIVE'
                ORDER BY g2.id LIMIT 1))),
    'linked_visits', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'visit_id', v.id, 'visit_date', v.visit_date,
        'service_type', v.service_type, 'status', v.visit_status,
        'derm_required', v.derm_required,
        'line_items', coalesce((SELECT jsonb_agg(jsonb_build_object(
            'name', li.name, 'quantity', li.quantity))
          FROM public.line_items li WHERE li.visit_id = v.id), '[]'::jsonb))
        ORDER BY v.visit_date)
      FROM public.manifest_visits mv
      JOIN public.visits v ON v.id = mv.visit_id AND v.deleted_at IS NULL
      WHERE mv.manifest_id = v_m.id), '[]'::jsonb),
    'stamped_rows', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'page', r.page, 'row_index', r.row_index,
        'facility_read', r.facility_name_read,
        'stamp_placed', r.stamp_placed_at IS NOT NULL,
        'stamp_x_pct', r.stamp_x_pct, 'stamp_y_pct', r.stamp_y_pct,
        'band_y0_pct', r.band_y0_pct, 'band_y1_pct', r.band_y1_pct,
        'human_verified', r.reviewed_at IS NOT NULL,
        'verified_at', r.reviewed_at)
        ORDER BY r.page, r.row_index)
      FROM derm.address_row_map r
      WHERE r.matched_manifest_id = v_m.id), '[]'::jsonb),
    'sheet_completed', coalesce((SELECT s.completed
      FROM derm.address_row_map r
      JOIN derm.stamp_sheet_status s ON s.dump_folder = r.dump_folder
      WHERE r.matched_manifest_id = v_m.id LIMIT 1), false),
    'frequency_check', (SELECT CASE
        WHEN g.max_frequency_days IS NULL THEN jsonb_build_object('status','no-gdo-max-on-file')
        WHEN prev.visit_date IS NULL       THEN jsonb_build_object('status','no-prior-visit',
                                                 'max_frequency_days', g.max_frequency_days)
        ELSE jsonb_build_object(
          'status', CASE WHEN (v_m.service_date - prev.visit_date) <= g.max_frequency_days
                         THEN 'within-frequency' ELSE 'exceeded' END,
          'days_since_prior_pumping', (v_m.service_date - prev.visit_date),
          'max_frequency_days', g.max_frequency_days,
          'prior_visit_date', prev.visit_date) END
      FROM (SELECT 1) one
      LEFT JOIN public.gdos g ON g.id = coalesce(v_m.gdo_id,
             (SELECT g2.id FROM public.gdos g2
               WHERE g2.client_id = v_m.client_id AND g2.status = 'ACTIVE'
               ORDER BY g2.id LIMIT 1))
      LEFT JOIN LATERAL (SELECT v.visit_date FROM public.visits v
        WHERE v.client_id = v_m.client_id AND v.deleted_at IS NULL
          AND v.visit_status = 'completed' AND v.derm_required IS NOT FALSE
          AND v.visit_date < v_m.service_date
          -- review fix: never treat this manifest's OWN linked visit as "prior"
          AND NOT EXISTS (SELECT 1 FROM public.manifest_visits mv2
                           WHERE mv2.manifest_id = v_m.id AND mv2.visit_id = v.id)
        ORDER BY v.visit_date DESC LIMIT 1) prev ON true),
    'chain_of_custody', coalesce((SELECT jsonb_agg(ev ORDER BY at) FROM (
      SELECT l.changed_at AS at, jsonb_build_object('at', l.changed_at,
               'table', l.table_name, 'operation', l.operation,
               'app_source', l.app_source,
               'actor', l.request_context->>'actor_name') AS ev
      FROM audit.logs l
      WHERE l.table_schema = 'public' AND l.table_name = 'derm_manifests'
        AND l.record_pk->>'id' = v_m.id::text
      UNION ALL
      SELECT l.changed_at, jsonb_build_object('at', l.changed_at,
               'table', l.table_name, 'operation', l.operation,
               'app_source', l.app_source,
               'actor', l.request_context->>'actor_name')
      FROM audit.logs l
      WHERE l.table_schema = 'public' AND l.table_name = 'manifest_visits'
        AND (coalesce(l.new_row, l.old_row))->>'manifest_id' = v_m.id::text
      UNION ALL
      SELECT l.changed_at, jsonb_build_object('at', l.changed_at,
               'table', l.table_name, 'operation', l.operation,
               'app_source', l.app_source,
               'actor', l.request_context->>'actor_name')
      FROM audit.logs l
      WHERE l.table_schema = 'derm' AND l.table_name = 'address_row_map'
        AND (coalesce(l.new_row, l.old_row))->>'matched_manifest_id' = v_m.id::text
      ) evs), '[]'::jsonb)
  ) INTO v_out;
  RETURN v_out;
END $function$
$old$;
  IF md5(pg_get_functiondef('derm.audit_pack(bigint)'::regprocedure)) <> '163264a736437fcd7230d8f6338de795' THEN RAISE EXCEPTION 'permits rollback: derm.audit_pack did not round-trip'; END IF;
END $f0$;

-- derm.audit_pack_client
DO $f1$
BEGIN
  IF md5(pg_get_functiondef('derm.audit_pack_client(bigint,date,date)'::regprocedure)) <> '869452f336d32877498815283c422f2f' THEN
    RAISE EXCEPTION 'permits rollback: derm.audit_pack_client is not the body the migration wrote (md5 %)', md5(pg_get_functiondef('derm.audit_pack_client(bigint,date,date)'::regprocedure));
  END IF;
  EXECUTE $old$CREATE OR REPLACE FUNCTION derm.audit_pack_client(p_client_id bigint, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE v_out jsonb;
BEGIN
  SELECT jsonb_build_object(
    'generated_at', now(),
    'period', jsonb_build_object('from', p_from, 'to', p_to),
    'assumptions', jsonb_build_array(
      'frequency analysis merges all client locations (GDOs are location-bound; multi-location clients need per-location scoping)'),
    'client', (SELECT jsonb_build_object('id', c.id, 'client_code', c.client_code,
        'name', c.name, 'status', c.status) FROM public.clients c WHERE c.id = p_client_id),
    'gdo', (SELECT jsonb_build_object('gdo_number', g.gdo_number,
        'permit_expiration', g.permit_expiration, 'max_frequency_days', g.max_frequency_days)
      FROM public.gdos g WHERE g.client_id = p_client_id AND g.status = 'ACTIVE'
      ORDER BY g.id LIMIT 1),
    'manifests', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'manifest_id', m.id,
        'white_manifest_number', m.white_manifest_number,
        'service_date', m.service_date,
        'linked_visits', (SELECT count(*) FROM public.manifest_visits mv WHERE mv.manifest_id = m.id),
        'stamped', EXISTS (SELECT 1 FROM derm.address_row_map r
                            WHERE r.matched_manifest_id = m.id AND r.stamp_placed_at IS NOT NULL),
        'human_verified', EXISTS (SELECT 1 FROM derm.address_row_map r
                            WHERE r.matched_manifest_id = m.id AND r.reviewed_at IS NOT NULL))
        ORDER BY m.service_date)
      FROM public.derm_manifests m
      WHERE m.client_id = p_client_id AND m.deleted_at IS NULL
        AND m.service_date BETWEEN p_from AND p_to), '[]'::jsonb),
    'frequency_violations', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'from_visit', prev_date, 'to_visit', visit_date, 'gap_days', gap,
        'max_frequency_days', maxf) ORDER BY visit_date)
      FROM (SELECT vv.visit_date,
                   lag(vv.visit_date) OVER (ORDER BY vv.visit_date) AS prev_date,
                   vv.visit_date - lag(vv.visit_date) OVER (ORDER BY vv.visit_date) AS gap,
                   (SELECT g.max_frequency_days FROM public.gdos g
                     WHERE g.client_id = p_client_id AND g.status = 'ACTIVE'
                     ORDER BY g.id LIMIT 1) AS maxf
            FROM (
              SELECT v.visit_date FROM public.visits v
              WHERE v.client_id = p_client_id AND v.deleted_at IS NULL
                AND v.visit_status = 'completed' AND v.derm_required IS NOT FALSE
                AND v.visit_date BETWEEN p_from AND p_to
              UNION ALL
              -- review fix: seed lag() with the last pre-window pumping visit so
              -- a violation gap spanning the period start is caught
              (SELECT v.visit_date FROM public.visits v
               WHERE v.client_id = p_client_id AND v.deleted_at IS NULL
                 AND v.visit_status = 'completed' AND v.derm_required IS NOT FALSE
                 AND v.visit_date < p_from
               ORDER BY v.visit_date DESC LIMIT 1)
            ) vv) gaps
      WHERE gaps.visit_date >= p_from
        AND gaps.maxf IS NOT NULL AND gaps.gap > gaps.maxf), '[]'::jsonb)
  ) INTO v_out;
  RETURN v_out;
END $function$
$old$;
  IF md5(pg_get_functiondef('derm.audit_pack_client(bigint,date,date)'::regprocedure)) <> 'fa4f8ce503cfcfa658ccc41e39d8727d' THEN RAISE EXCEPTION 'permits rollback: derm.audit_pack_client did not round-trip'; END IF;
END $f1$;

-- public.fn_check_gdo_on_visit
DO $f2$
BEGIN
  IF md5(pg_get_functiondef('public.fn_check_gdo_on_visit()'::regprocedure)) <> '72e88e8afab26e95136408fc8c39a66e' THEN
    RAISE EXCEPTION 'permits rollback: public.fn_check_gdo_on_visit is not the body the migration wrote (md5 %)', md5(pg_get_functiondef('public.fn_check_gdo_on_visit()'::regprocedure));
  END IF;
  EXECUTE $old$CREATE OR REPLACE FUNCTION public.fn_check_gdo_on_visit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_county  TEXT;
  v_has_gdo BOOLEAN;
BEGIN
  -- Only care about pumping visits (was GT before the 2026-08-03 rename).
  -- NOTE: `!=` not `IS DISTINCT FROM` — see the migration header. NULL
  -- service_type must keep falling through to the check.
  IF NEW.service_type != 'Pumping' THEN
    RETURN NEW;
  END IF;

  -- Per-visit opt-out (visits.derm_required, 3-state:
  --   NULL  = default-true for pumping
  --   TRUE  = explicit opt-in
  --   FALSE = ops marked "not required" via DERM Tracker)
  IF NEW.derm_required IS FALSE THEN
    RETURN NEW;
  END IF;

  -- Check county (Dade only for v1)
  SELECT p.county INTO v_county
  FROM properties p
  WHERE p.client_id = NEW.client_id
    AND p.is_primary = true
  LIMIT 1;

  IF v_county IS DISTINCT FROM 'Dade' THEN
    RETURN NEW;
  END IF;

  -- Check gdos table (ACTIVE + EXPIRED both count as "has a permit",
  -- since EXPIRED still ties to the physical trap, just needs renewal)
  SELECT EXISTS(
    SELECT 1 FROM gdos g
    WHERE g.client_id = NEW.client_id
      AND g.status IN ('ACTIVE', 'EXPIRED')
  ) INTO v_has_gdo;

  -- Fire alert if no GDO on file
  IF NOT v_has_gdo THEN
    PERFORM pg_notify(
      'gdo_compliance_alert',
      json_build_object(
        'client_id',      NEW.client_id,
        'visit_id',       NEW.id,
        'visit_date',     NEW.visit_date,
        'derm_required',  NEW.derm_required,
        'event',          'gt_visit_no_gdo'
      )::text
    );
  END IF;

  RETURN NEW;
END;
$function$
$old$;
  IF md5(pg_get_functiondef('public.fn_check_gdo_on_visit()'::regprocedure)) <> '68ad97e23f63e40e08b0c0cd842c9da3' THEN RAISE EXCEPTION 'permits rollback: public.fn_check_gdo_on_visit did not round-trip'; END IF;
END $f2$;

-- public.fn_gdo_permit_label_targets
DO $f3$
BEGIN
  IF md5(pg_get_functiondef('public.fn_gdo_permit_label_targets(integer,bigint[])'::regprocedure)) <> '25e98e0d754de836542f0762e6fbf615' THEN
    RAISE EXCEPTION 'permits rollback: public.fn_gdo_permit_label_targets is not the body the migration wrote (md5 %)', md5(pg_get_functiondef('public.fn_gdo_permit_label_targets(integer,bigint[])'::regprocedure));
  END IF;
  EXECUTE $old$CREATE OR REPLACE FUNCTION public.fn_gdo_permit_label_targets(p_limit integer DEFAULT 3, p_gdo_ids bigint[] DEFAULT NULL::bigint[])
 RETURNS TABLE(gdo_id bigint, storage_path text, etag text, current_label text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'storage'
AS $function$
  select g.id, g.permit_document_path, o.metadata->>'eTag', g.location_label
    from public.gdos g
    join storage.objects o on o.bucket_id = 'gdo-permits' and o.name = g.permit_document_path
    left join lateral (select r.outcome from public.gdo_permit_label_reads r
                        where r.gdo_id = g.id and r.etag = o.metadata->>'eTag'
                        order by r.read_at desc, r.id desc limit 1) last on true
   where o.metadata->>'eTag' is not null
     and (
       (p_gdo_ids is not null and g.id = any (p_gdo_ids))
       or (p_gdo_ids is null
           and (last.outcome is null
                or (last.outcome = 'error'
                    and (select count(*) from public.gdo_permit_label_reads r
                          where r.gdo_id = g.id and r.etag = o.metadata->>'eTag' and r.outcome = 'error'
                            and r.read_at > now() - interval '24 hours') < 3)))
     )
   order by g.id
   limit greatest(coalesce(p_limit, 3), 0)
$function$
$old$;
  IF md5(pg_get_functiondef('public.fn_gdo_permit_label_targets(integer,bigint[])'::regprocedure)) <> 'f3bd261bf17d7f1929caca4c59a63762' THEN RAISE EXCEPTION 'permits rollback: public.fn_gdo_permit_label_targets did not round-trip'; END IF;
END $f3$;

-- client.upsert_gdo_permit
DO $f4$
BEGIN
  IF md5(pg_get_functiondef('client.upsert_gdo_permit(bigint,bigint,jsonb)'::regprocedure)) <> '34d9241e27d87c3c935fd868303eedfe' THEN
    RAISE EXCEPTION 'permits rollback: client.upsert_gdo_permit is not the body the migration wrote (md5 %)', md5(pg_get_functiondef('client.upsert_gdo_permit(bigint,bigint,jsonb)'::regprocedure));
  END IF;
  EXECUTE $old$CREATE OR REPLACE FUNCTION client.upsert_gdo_permit(p_gdo_id bigint, p_client_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_allowed text[] := array[
    'gdo_number','nickname','location_label','permit_expiration','max_frequency_days',
    'permit_document_path','status','notes','property_id','client_location_id'
  ];
  v_bad         text[];
  v_row         public.gdos;
  v_wanted      text;
  v_out         jsonb;
  v_old_status  text;
  v_old_notes   text;
  v_old_client  bigint;
  v_new_notes   text;
  v_marked      boolean;
  v_prop        bigint;
  v_freq        integer;
begin
  perform hr.fn_check_app('client_app', 'edit', 'save a GDO permit');   -- 2026-10-21_0900 access phase 5
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if not public.fn_is_staff_email(lower(coalesce(auth.jwt() ->> 'email','')))
      then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    raise exception 'p_patch must be a non-empty JSON object' using errcode = '22023';
  end if;

  select array_agg(k) into v_bad
  from jsonb_object_keys(p_patch) k
  where k <> all (v_allowed);
  if v_bad is not null then
    raise exception 'unsupported field(s) for gdos: %. Wave 1 allows only %',
      v_bad, v_allowed using errcode = '22023';
  end if;

  v_wanted := nullif(btrim(coalesce(p_patch->>'status','')),'');

  if p_patch ? 'gdo_number'
     and nullif(btrim(coalesce(p_patch->>'gdo_number','')),'') is null then
    raise exception 'gdo_number cannot be blank' using errcode = '22023';
  end if;
  if p_patch ? 'status' and v_wanted is null then
    raise exception 'status cannot be blank; expected ACTIVE, EXPIRED or INACTIVE'
      using errcode = '22023';
  end if;
  if v_wanted is not null and v_wanted <> all (array['ACTIVE','EXPIRED','INACTIVE']) then
    raise exception 'status must be one of ACTIVE, EXPIRED, INACTIVE (got %)', v_wanted
      using errcode = '22023';
  end if;
  if p_patch ? 'property_id'
     and nullif(btrim(coalesce(p_patch->>'property_id','')),'') is null then
    raise exception 'property_id cannot be blank; a permit is bound to a location'
      using errcode = '22023';
  end if;
  if p_patch ? 'permit_expiration'
     and nullif(p_patch->>'permit_expiration','') is not null
     and p_patch->>'permit_expiration' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception 'permit_expiration must be a bare date YYYY-MM-DD, never a timestamp (got %)',
      p_patch->>'permit_expiration' using errcode = '22023';
  end if;

  -- ⚠ BUG 3 FIX. Upper bound. This column drives customer.permits.over_gdo_max
  -- and `compliant`, which the Field Portal shows to the CLIENT, so an inflated
  -- ceiling silently reports a non-compliant site as compliant. Real values are
  -- 30/60/90; 365 is a generous ceiling that still catches 900-for-90.
  if p_patch ? 'max_frequency_days' then
    v_freq := nullif(btrim(coalesce(p_patch->>'max_frequency_days','')),'')::integer;
    if v_freq is not null and (v_freq < 1 or v_freq > 365) then
      raise exception 'max_frequency_days must be between 1 and 365 days (got %). This is the DERM permit ceiling; typical values are 30, 60 or 90.',
        v_freq using errcode = '22023';
    end if;
  end if;

  v_prop := nullif(btrim(coalesce(p_patch->>'property_id','')),'')::bigint;

  if p_gdo_id is null then
    -- ---- ADD ----
    if p_client_id is null then
      raise exception 'p_client_id is required when creating a permit' using errcode = '22023';
    end if;
    if nullif(btrim(coalesce(p_patch->>'gdo_number','')),'') is null then
      raise exception 'gdo_number is required when creating a permit' using errcode = '22023';
    end if;
    if v_prop is null then
      raise exception 'property_id is required when creating a permit (a GDO is issued to a location, not a business)'
        using errcode = '22023';
    end if;
    -- 2026-09-22, Fred: "we cannot have a GDO number without having the GDO file."
    if nullif(btrim(coalesce(p_patch->>'permit_document_path','')),'') is null then
      raise exception 'Attach the permit document before saving. A GDO number cannot be recorded without its permit file.'
        using errcode = '22023';
    end if;
    if not exists (select 1 from public.properties pr
                   where pr.id = v_prop and pr.client_id = p_client_id) then
      raise exception 'property % does not belong to client %', v_prop, p_client_id
        using errcode = '23503';
    end if;
    -- Readable duplicate message. The bare 23505 from gdos_client_gdo_unique was
    -- being rendered verbatim to the user, and it is highly reachable in the
    -- PDF-first flow because re-uploading a permit the client already holds hits it.
    if exists (select 1 from public.gdos g
               where g.client_id = p_client_id
                 and g.gdo_number = btrim(p_patch->>'gdo_number')) then
      raise exception 'This client already has permit %. Edit the existing permit instead of adding it again.',
        btrim(p_patch->>'gdo_number') using errcode = '23505';
    end if;

    insert into public.gdos (
      client_id, gdo_number, nickname, location_label, permit_expiration,
      max_frequency_days, permit_document_path, status, notes, property_id, client_location_id
    ) values (
      p_client_id,
      btrim(p_patch->>'gdo_number'),
      nullif(p_patch->>'nickname',''),
      nullif(p_patch->>'location_label',''),
      nullif(p_patch->>'permit_expiration','')::date,
      v_freq,
      nullif(p_patch->>'permit_document_path',''),
      coalesce(v_wanted, 'ACTIVE'),
      nullif(p_patch->>'notes',''),
      v_prop,
      nullif(p_patch->>'client_location_id','')::bigint
    )
    returning * into v_row;
  else
    -- ---- EDIT ----
    select g.status, g.notes, g.client_id
      into v_old_status, v_old_notes, v_old_client
    from public.gdos g where g.id = p_gdo_id for update;
    if not found then
      raise exception 'gdo % not found', p_gdo_id using errcode = 'P0002';
    end if;
    if p_client_id is not null and p_client_id <> v_old_client then
      raise exception 'p_client_id % does not match this permit''s client %', p_client_id, v_old_client
        using errcode = '22023';
    end if;
    if v_prop is not null and not exists (
         select 1 from public.properties pr where pr.id = v_prop and pr.client_id = v_old_client) then
      raise exception 'property % does not belong to client %', v_prop, v_old_client
        using errcode = '23503';
    end if;
    if p_patch ? 'gdo_number' and exists (
         select 1 from public.gdos g
         where g.client_id = v_old_client
           and g.gdo_number = btrim(p_patch->>'gdo_number')
           and g.id <> p_gdo_id) then
      raise exception 'This client already has permit %. Two permits for one client cannot share a number.',
        btrim(p_patch->>'gdo_number') using errcode = '23505';
    end if;

    -- ⚠⚠ BUG 2 FIX — ONE RULE THAT CLOSES ALL THREE BYPASSES.
    -- On a row whose notes carry DEMOTED/DEDUP evidence:
    --   (i)  notes are APPEND-ONLY  -> closes route B (notes-only disarm) and
    --        route C (5-char "DEDUP" replacing 431 chars of evidence), because
    --        containment of the old text is what the error message already promises;
    --   (ii) any transition TO ACTIVE needs a real append, REGARDLESS of the
    --        current status -> closes route A (INACTIVE->EXPIRED->ACTIVE), which
    --        mattered most because parse-gdo-permit derives EXPIRED for a lapsed
    --        permit and so performed hop 1 automatically.
    v_marked := coalesce(v_old_notes,'') ~* '(DEMOTED|DEDUP)';
    if v_marked then
      v_new_notes := case when p_patch ? 'notes'
                          then nullif(btrim(coalesce(p_patch->>'notes','')),'') end;

      if p_patch ? 'notes' and position(btrim(coalesce(v_old_notes,'')) in coalesce(v_new_notes,'')) = 0 then
        raise exception 'This permit was demoted with recorded evidence, so its notes are append-only. Keep the existing text and add your reason at the end. (The evidence is what stops a wrong permit being silently reactivated.)'
          using errcode = '22023';
      end if;

      if v_wanted = 'ACTIVE' then
        if v_new_notes is null or btrim(coalesce(v_old_notes,'')) = v_new_notes then
          raise exception 'Permit % was demoted with recorded evidence. To reactivate it deliberately, keep the existing notes and append your reason in the same save.',
            p_gdo_id using errcode = '22023';
        end if;
      end if;
    end if;

    update public.gdos g set
      gdo_number = case when p_patch ? 'gdo_number'
                        then btrim(p_patch->>'gdo_number') else g.gdo_number end,
      nickname = case when p_patch ? 'nickname'
                      then nullif(p_patch->>'nickname','') else g.nickname end,
      location_label = case when p_patch ? 'location_label'
                            then nullif(p_patch->>'location_label','') else g.location_label end,
      permit_expiration = case when p_patch ? 'permit_expiration'
                               then nullif(p_patch->>'permit_expiration','')::date
                               else g.permit_expiration end,
      max_frequency_days = case when p_patch ? 'max_frequency_days'
                                then v_freq else g.max_frequency_days end,
      permit_document_path = case when p_patch ? 'permit_document_path'
                                  then nullif(p_patch->>'permit_document_path','')
                                  else g.permit_document_path end,
      status = case when p_patch ? 'status'
                    then v_wanted else g.status end,
      notes = case when p_patch ? 'notes'
                   then nullif(p_patch->>'notes','') else g.notes end,
      property_id = case when p_patch ? 'property_id'
                         then v_prop else g.property_id end,
      client_location_id = case when p_patch ? 'client_location_id'
                                then nullif(p_patch->>'client_location_id','')::bigint
                                else g.client_location_id end
    where g.id = p_gdo_id
    returning g.* into v_row;

    -- The warn-only DB trigger can still rewrite NEW.status; report that honestly
    -- rather than claiming a success the row does not reflect.
    if v_wanted is not null and v_row.status <> v_wanted then
      v_out := to_jsonb(v_row) || jsonb_build_object(
        'status_change_refused', true,
        'requested_status', v_wanted,
        'message', 'A database guard refused this status change because the permit was demoted with recorded evidence.');
      return v_out;
    end if;
  end if;

  return to_jsonb(v_row);
end;
$function$
$old$;
  IF md5(pg_get_functiondef('client.upsert_gdo_permit(bigint,bigint,jsonb)'::regprocedure)) <> 'af1cca9b28b89453e2705d4da81f133b' THEN RAISE EXCEPTION 'permits rollback: client.upsert_gdo_permit did not round-trip'; END IF;
END $f4$;

-- derm.gdos
DO $v0$
BEGIN
  IF position('permit_type' in pg_get_viewdef('derm.gdos'::regclass, true)) = 0 THEN
    RAISE EXCEPTION 'permits rollback: derm.gdos does not carry the migration''s edit';
  END IF;
  EXECUTE 'CREATE OR REPLACE VIEW derm.gdos AS ' || $old$ SELECT g.id,
    g.client_id,
        CASE
            WHEN c.client_code IS NOT NULL AND c.name !~~ (c.client_code || '%'::text) THEN (c.client_code || ' '::text) || c.name
            ELSE c.name
        END AS client_name,
    g.gdo_number,
    g.location_label,
    g.property_id,
    g.permit_expiration::text AS permit_expiration,
    g.permit_document_path,
    g.status,
    g.notes,
    g.created_at::text AS created_at,
    g.updated_at::text AS updated_at,
    ( SELECT count(*) AS count
           FROM derm_manifests dm
          WHERE dm.gdo_id = g.id AND dm.deleted_at IS NULL) AS manifest_count
   FROM gdos g
     JOIN clients c ON c.id = g.client_id;$old$;
  IF md5(pg_get_viewdef('derm.gdos'::regclass, true)) <> 'f822c3e8d8df714423e20e9e179418d2' THEN RAISE EXCEPTION 'permits rollback: derm.gdos did not round-trip'; END IF;
END $v0$;

-- ops.v_derm_compliance
DO $v1$
BEGIN
  IF position('permit_type' in pg_get_viewdef('ops.v_derm_compliance'::regclass, true)) = 0 THEN
    RAISE EXCEPTION 'permits rollback: ops.v_derm_compliance does not carry the migration''s edit';
  END IF;
  EXECUTE 'CREATE OR REPLACE VIEW ops.v_derm_compliance AS ' || $old$ WITH last_manifest AS (
         SELECT derm_manifests.client_id,
            max(derm_manifests.service_date) AS last_manifest_date,
            count(*) AS total_manifests
           FROM derm_manifests
          GROUP BY derm_manifests.client_id
        ), unmatched_visits AS (
         SELECT v.client_id,
            count(*) AS missing_manifests
           FROM visits v
          WHERE (v.derm_required IS NULL OR v.derm_required = true) AND v.visit_status = 'completed'::text AND v.deleted_at IS NULL AND v.visit_date >= (CURRENT_DATE - '120 days'::interval) AND NOT (EXISTS ( SELECT 1
                   FROM derm_manifests dm
                  WHERE dm.client_id = v.client_id AND dm.service_date = v.visit_date))
          GROUP BY v.client_id
        )
 SELECT c.id,
    c.client_code,
    c.name AS client_name,
    c.status AS client_status,
    p_z.code AS zone,
    p.address,
    p.city,
    p.county,
    cc.name AS contact_name,
    cc.email,
    cc.phone,
    ( SELECT g.gdo_number
           FROM gdos g
          WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text
          ORDER BY g.id
         LIMIT 1) AS permit_number,
    ( SELECT g.permit_expiration
           FROM gdos g
          WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text
          ORDER BY g.id
         LIMIT 1) AS permit_expiration,
    COALESCE(p.grease_trap_size_gallons::numeric, (( SELECT ps.grease_trap_size_gallons
           FROM properties ps
          WHERE ps.client_id = c.id AND ps.grease_trap_size_gallons IS NOT NULL
          ORDER BY ps.is_primary DESC, ps.id
         LIMIT 1))::numeric, sc.equipment_size_gallons) AS equipment_size_gallons,
    sc.frequency_days,
    lm.last_manifest_date,
    lm.total_manifests,
    COALESCE(uv.missing_manifests, 0::bigint) AS missing_manifest_count,
        CASE
            WHEN COALESCE(uv.missing_manifests, 0::bigint) > 0 THEN true
            ELSE false
        END AS has_missing_manifests,
    CURRENT_DATE - lm.last_manifest_date AS days_since_last_manifest,
        CASE
            WHEN lm.last_manifest_date IS NULL THEN 'no_service_record'::text
            WHEN (CURRENT_DATE - lm.last_manifest_date) > 90 THEN 'derm_violation'::text
            WHEN (CURRENT_DATE - lm.last_manifest_date) > COALESCE(sc.frequency_days, 90) THEN 'overdue'::text
            WHEN (CURRENT_DATE - lm.last_manifest_date) > (COALESCE(sc.frequency_days, 90) - 14) THEN 'due_soon'::text
            ELSE 'compliant'::text
        END AS compliance_status
   FROM clients c
     JOIN v_client_agreement_services sc ON sc.client_id = c.id AND sc.service_type = 'Pumping'::text
     LEFT JOIN client_contacts cc ON cc.client_id = c.id AND cc.contact_role = 'primary'::text AND cc.property_id IS NULL
     LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
     LEFT JOIN last_manifest lm ON lm.client_id = c.id
     LEFT JOIN unmatched_visits uv ON uv.client_id = c.id
     LEFT JOIN zones p_z ON p_z.id = p.zone_id
  WHERE c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text])
  ORDER BY (
        CASE
            WHEN (CURRENT_DATE - lm.last_manifest_date) > 90 THEN 1
            WHEN lm.last_manifest_date IS NULL THEN 2
            WHEN (CURRENT_DATE - lm.last_manifest_date) > COALESCE(sc.frequency_days, 90) THEN 3
            WHEN (CURRENT_DATE - lm.last_manifest_date) > (COALESCE(sc.frequency_days, 90) - 14) THEN 4
            ELSE 5
        END), (COALESCE(uv.missing_manifests, 0::bigint)) DESC, (CURRENT_DATE - lm.last_manifest_date) DESC NULLS LAST;$old$;
  IF md5(pg_get_viewdef('ops.v_derm_compliance'::regclass, true)) <> 'ad5c40c7ed0abcdc9635f1b7a7acb64a' THEN RAISE EXCEPTION 'permits rollback: ops.v_derm_compliance did not round-trip'; END IF;
END $v1$;

-- customer.clients
DO $v2$
BEGIN
  IF position('permit_type' in pg_get_viewdef('customer.clients'::regclass, true)) = 0 THEN
    RAISE EXCEPTION 'permits rollback: customer.clients does not carry the migration''s edit';
  END IF;
  EXECUTE 'CREATE OR REPLACE VIEW customer.clients AS ' || $old$ SELECT customer.uuid_from_bigint(c.id) AS id,
    lower(c.client_code) AS slug,
    c.name,
    c.client_code,
    cg.name AS group_name,
    p.address AS address1,
    NULLIF(TRIM(BOTH ' ,'::text FROM concat_ws(', '::text, NULLIF(p.city, ''::text), NULLIF(concat_ws(' '::text, NULLIF(p.state, ''::text), NULLIF(p.zip, ''::text)), ''::text))), ''::text) AS address2,
        CASE
            WHEN COALESCE(NULLIF(p.grease_trap_size_gallons, 0)::numeric, (( SELECT ps.grease_trap_size_gallons
               FROM properties ps
              WHERE ps.client_id = c.id AND ps.grease_trap_size_gallons > 0
              ORDER BY ps.is_primary DESC, ps.id
             LIMIT 1))::numeric, NULLIF(sc_gt.equipment_size_gallons, 0::numeric)) IS NOT NULL THEN COALESCE(NULLIF(p.grease_trap_size_gallons, 0)::numeric, (( SELECT ps.grease_trap_size_gallons
               FROM properties ps
              WHERE ps.client_id = c.id AND ps.grease_trap_size_gallons > 0
              ORDER BY ps.is_primary DESC, ps.id
             LIMIT 1))::numeric, NULLIF(sc_gt.equipment_size_gallons, 0::numeric))::text || ' gal grease trap'::text
            ELSE NULL::text
        END AS container_type,
        CASE
            WHEN COALESCE(NULLIF(p.grease_trap_size_gallons, 0)::numeric, (( SELECT ps.grease_trap_size_gallons
               FROM properties ps
              WHERE ps.client_id = c.id AND ps.grease_trap_size_gallons > 0
              ORDER BY ps.is_primary DESC, ps.id
             LIMIT 1))::numeric, NULLIF(sc_gt.equipment_size_gallons, 0::numeric)) IS NOT NULL THEN COALESCE(NULLIF(p.grease_trap_size_gallons, 0)::numeric, (( SELECT ps.grease_trap_size_gallons
               FROM properties ps
              WHERE ps.client_id = c.id AND ps.grease_trap_size_gallons > 0
              ORDER BY ps.is_primary DESC, ps.id
             LIMIT 1))::numeric, NULLIF(sc_gt.equipment_size_gallons, 0::numeric))::text || ' gal'::text
            ELSE NULL::text
        END AS trap_capacity,
    sc_gt.material_type AS material,
    df.name AS disposal_facility,
    ( SELECT g.permit_document_path
           FROM gdos g
          WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text
          ORDER BY g.id
         LIMIT 1) AS gdo_permit_url,
    p.access_notes,
    c.created_at,
    c.status,
    c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text]) AS is_active,
    ( SELECT max(j.frequency_days) AS max
           FROM jobs j
          WHERE j.client_id = c.id AND j.title ~~* '%Service Agreement%'::text AND (j.job_status <> ALL (ARRAY['archived'::text, 'destroyed'::text])) AND j.frequency_days > 0) AS service_frequency_days
   FROM clients c
     LEFT JOIN client_groups cg ON cg.id = c.group_id
     LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true AND p.deleted_at IS NULL
     LEFT JOIN v_client_agreement_services sc_gt ON sc_gt.client_id = c.id AND sc_gt.service_type = 'Pumping'::text
     LEFT JOIN disposal_facilities df ON df.id = p.default_disposal_facility_id;$old$;
  IF md5(pg_get_viewdef('customer.clients'::regclass, true)) <> 'f4ee12e3066b18398f16ccb0bca65a2f' THEN RAISE EXCEPTION 'permits rollback: customer.clients did not round-trip'; END IF;
END $v2$;

-- ops.v_route_today
DO $v3$
BEGIN
  IF position('permit_type' in pg_get_viewdef('ops.v_route_today'::regclass, true)) = 0 THEN
    RAISE EXCEPTION 'permits rollback: ops.v_route_today does not carry the migration''s edit';
  END IF;
  EXECUTE 'CREATE OR REPLACE VIEW ops.v_route_today AS ' || $old$ SELECT v.id AS visit_id,
    v.visit_date,
    v.start_at,
    v.end_at,
    v.visit_status,
    v.service_type,
    v.visit_status = 'completed'::text AS is_complete,
    v.is_gps_confirmed,
    c.id AS client_id,
    c.client_code,
    c.name AS client_name,
    COALESCE(vp_z.code, pp_z.code) AS zone,
    COALESCE(vp.address, pp.address) AS address,
    COALESCE(vp.city, pp.city) AS city,
    COALESCE(vp.county, pp.county) AS county,
    COALESCE(vp.latitude, pp.latitude) AS latitude,
    COALESCE(vp.longitude, pp.longitude) AS longitude,
    COALESCE(fn_sched_open(vp.access_schedule), fn_sched_open(pp.access_schedule)) AS access_hours_start,
    COALESCE(fn_sched_close(vp.access_schedule), fn_sched_close(pp.access_schedule)) AS access_hours_end,
    cc.name AS contact_name,
    cc.phone AS contact_phone,
    COALESCE(vp.grease_trap_size_gallons::numeric, pp.grease_trap_size_gallons::numeric, sc.equipment_size_gallons) AS equipment_size_gallons,
    COALESCE(( SELECT g.gdo_number
           FROM gdos g
          WHERE g.property_id = v.property_id AND g.status = 'ACTIVE'::text
          ORDER BY g.id
         LIMIT 1), ( SELECT g.gdo_number
           FROM gdos g
          WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text
          ORDER BY g.id
         LIMIT 1)) AS permit_number,
    veh.name AS truck,
    veh.grease_tank_capacity_gallons,
    string_agg(e.full_name, ', '::text ORDER BY e.full_name) AS crew,
    v.duration_minutes
   FROM v_visits_live v
     JOIN clients c ON c.id = v.client_id
     LEFT JOIN properties vp ON vp.id = v.property_id
     LEFT JOIN properties pp ON pp.client_id = c.id AND pp.is_primary = true
     LEFT JOIN client_contacts cc ON cc.client_id = c.id AND cc.contact_role = 'primary'::text AND cc.property_id IS NULL
     LEFT JOIN v_client_agreement_services sc ON sc.client_id = c.id AND sc.service_type = v.service_type
     LEFT JOIN vehicles veh ON veh.id = v.vehicle_id
     LEFT JOIN visit_assignments va ON va.visit_id = v.id
     LEFT JOIN employees e ON e.id = va.employee_id
     LEFT JOIN zones vp_z ON vp_z.id = vp.zone_id
     LEFT JOIN zones pp_z ON pp_z.id = pp.zone_id
  WHERE v.visit_date = CURRENT_DATE AND (v.visit_status = ANY (ARRAY['UPCOMING'::text, 'LATE'::text, 'completed'::text]))
  GROUP BY v.id, v.visit_date, v.start_at, v.end_at, v.visit_status, v.service_type, v.is_gps_confirmed, c.id, c.client_code, c.name, vp_z.code, vp.address, vp.city, vp.county, vp.latitude, vp.longitude, vp.access_schedule, pp_z.code, pp.address, pp.city, pp.county, pp.latitude, pp.longitude, pp.access_schedule, cc.name, cc.phone, vp.grease_trap_size_gallons, pp.grease_trap_size_gallons, sc.equipment_size_gallons, v.property_id, veh.name, veh.grease_tank_capacity_gallons, v.duration_minutes
  ORDER BY v.start_at, (COALESCE(vp_z.code, pp_z.code)), c.name;$old$;
  IF md5(pg_get_viewdef('ops.v_route_today'::regclass, true)) <> '085778cc7214585e15d77277ad2a79d3' THEN RAISE EXCEPTION 'permits rollback: ops.v_route_today did not round-trip'; END IF;
END $v3$;

-- ops.v_service_due
DO $v4$
BEGIN
  IF position('permit_type' in pg_get_viewdef('ops.v_service_due'::regclass, true)) = 0 THEN
    RAISE EXCEPTION 'permits rollback: ops.v_service_due does not carry the migration''s edit';
  END IF;
  EXECUTE 'CREATE OR REPLACE VIEW ops.v_service_due AS ' || $old$ WITH actual_last_visit AS (
         SELECT visits.client_id,
            max(visits.visit_date) AS last_visit_actual
           FROM v_visits_live visits
          WHERE visits.visit_status = 'completed'::text
          GROUP BY visits.client_id
        )
 SELECT c.id,
    c.client_code,
    c.name AS client_name,
    c.status AS client_status,
    p_z.code AS zone,
    p.address,
    p.city,
    p.county,
    fn_sched_open(p.access_schedule) AS access_hours_start,
    fn_sched_close(p.access_schedule) AS access_hours_end,
    cc.name AS contact_name,
    cc.email,
    cc.phone,
    sc.service_type,
    sc.frequency_days,
    COALESCE(p.grease_trap_size_gallons::numeric, (( SELECT ps.grease_trap_size_gallons
           FROM properties ps
          WHERE ps.client_id = c.id AND ps.grease_trap_size_gallons IS NOT NULL
          ORDER BY ps.is_primary DESC, ps.id
         LIMIT 1))::numeric, sc.equipment_size_gallons) AS equipment_size_gallons,
    ( SELECT g.gdo_number
           FROM gdos g
          WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text
          ORDER BY g.id
         LIMIT 1) AS permit_number,
    sc.price_per_visit,
    COALESCE(sc.last_visit, alv.last_visit_actual) AS last_service_date,
    (COALESCE(sc.last_visit, alv.last_visit_actual) + ((sc.frequency_days || ' days'::text)::interval))::date AS scheduled_next_visit,
    CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual) AS days_since_service,
        CASE
            WHEN COALESCE(sc.last_visit, alv.last_visit_actual) IS NULL THEN 'never_serviced'::text
            WHEN (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) > 90 THEN 'derm_violation'::text
            WHEN (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) >= sc.frequency_days THEN 'overdue'::text
            WHEN (COALESCE(sc.last_visit, alv.last_visit_actual) + sc.frequency_days - CURRENT_DATE) <= 14 THEN 'due_soon'::text
            ELSE 'on_schedule'::text
        END AS service_status
   FROM clients c
     JOIN v_client_agreement_services sc ON sc.client_id = c.id AND (sc.service_type = ANY (ARRAY['Pumping'::text, 'Cleaning'::text]))
     LEFT JOIN client_contacts cc ON cc.client_id = c.id AND cc.contact_role = 'primary'::text AND cc.property_id IS NULL
     LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
     LEFT JOIN actual_last_visit alv ON alv.client_id = c.id
     LEFT JOIN zones p_z ON p_z.id = p.zone_id
  WHERE (c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text])) AND (COALESCE(sc.last_visit, alv.last_visit_actual) IS NULL OR (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) >= (COALESCE(sc.frequency_days, 90) - 14))
  ORDER BY (
        CASE
            WHEN (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) > 90 THEN 1
            ELSE 2
        END), p_z.code, (
        CASE
            WHEN COALESCE(sc.last_visit, alv.last_visit_actual) IS NULL THEN 1
            WHEN (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) >= sc.frequency_days THEN 2
            ELSE 3
        END), (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) DESC NULLS LAST;$old$;
  IF md5(pg_get_viewdef('ops.v_service_due'::regclass, true)) <> '1b2ed2386d1f4f0022a941cf5de2904b' THEN RAISE EXCEPTION 'permits rollback: ops.v_service_due did not round-trip'; END IF;
END $v4$;

DROP VIEW client.permit_types;

-- client.gdos (gained columns, so drop and re-create)
DROP VIEW client.gdos;
CREATE VIEW client.gdos AS
 SELECT id,
    client_id,
    gdo_number,
    location_label,
    property_id,
    permit_expiration,
    permit_document_path,
    status,
    notes,
    created_at,
    updated_at,
    max_frequency_days,
    client_location_id,
    permit_thumbnail_path,
    gdo_number !~ '^GDO-[0-9]+$'::text AS is_placeholder,
    nickname,
    COALESCE(nickname, gdo_number) AS display_label
   FROM gdos;
REVOKE ALL ON client.gdos FROM PUBLIC, anon;
GRANT SELECT ON client.gdos TO authenticated, service_role, db_backup_reader;

-- customer.permits (gained columns, so drop and re-create)
DROP VIEW customer.permits;
CREATE VIEW customer.permits AS
 SELECT customer.uuid_from_bigint(g.id) AS id,
    customer.uuid_from_bigint(g.client_id) AS client_id,
    g.gdo_number AS permit_number,
    'Grease Trap'::text AS area,
        CASE
            WHEN g.max_frequency_days IS NULL THEN NULL::text
            WHEN g.max_frequency_days <= 35 THEN 'Monthly'::text
            WHEN g.max_frequency_days <= 95 THEN 'Quarterly'::text
            WHEN g.max_frequency_days <= 185 THEN 'Semi-annually'::text
            WHEN g.max_frequency_days <= 380 THEN 'Annually'::text
            ELSE ('Every '::text || g.max_frequency_days) || ' days'::text
        END AS frequency,
    g.permit_document_path AS permit_url,
    (row_number() OVER (PARTITION BY g.client_id ORDER BY g.property_id, g.gdo_number) - 1)::integer AS "position",
    customer.uuid_from_bigint(g.property_id) AS property_id,
    g.location_label,
    g.permit_expiration,
    g.max_frequency_days,
        CASE
            WHEN g.max_frequency_days IS NULL THEN NULL::boolean
            ELSE COALESCE((CURRENT_DATE - (( SELECT max(v.visit_date) AS max
               FROM visits v
                 JOIN properties vp ON vp.id = v.property_id
              WHERE v.client_id = g.client_id AND v.visit_status = 'completed'::text AND v.deleted_at IS NULL AND (v.property_id = g.property_id OR lower(btrim(vp.address)) = lower(btrim(gp.address)))))) > g.max_frequency_days, true)
        END AS over_gdo_max,
    COALESCE(jf.freq, g.max_frequency_days) AS our_frequency_days,
        CASE
            WHEN jf.freq IS NULL OR g.max_frequency_days IS NULL THEN NULL::boolean
            ELSE jf.freq <= g.max_frequency_days
        END AS compliant,
        CASE
            WHEN jf.freq IS NOT NULL THEN 'job'::text
            WHEN g.max_frequency_days IS NOT NULL THEN 'gdo_permit'::text
            ELSE NULL::text
        END AS frequency_source
   FROM gdos g
     JOIN clients c ON c.id = g.client_id
     LEFT JOIN properties gp ON gp.id = g.property_id
     LEFT JOIN LATERAL ( SELECT j.frequency_days AS freq
           FROM jobs j
          WHERE j.client_id = g.client_id AND j.frequency_days > 0 AND (j.job_status <> ALL (ARRAY['archived'::text, 'destroyed'::text])) AND (EXISTS ( SELECT 1
                   FROM line_items li
                  WHERE li.job_id = j.id AND li.name IS NOT NULL AND fn_line_item_requires_derm(li.name) IS TRUE))
          ORDER BY (j.property_id = g.property_id) DESC NULLS LAST, j.id DESC
         LIMIT 1) jf ON true
  WHERE g.status = 'ACTIVE'::text AND (c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text]));
REVOKE ALL ON customer.permits FROM PUBLIC, anon;
GRANT SELECT ON customer.permits TO authenticated, service_role, db_backup_reader;

-- the table
DROP TRIGGER trg_aa_permit_number_matches_type ON public.gdos;
DROP FUNCTION public.fn_permit_number_matches_type();
ALTER TABLE public.gdos ADD CONSTRAINT gdos_real_number_requires_document_chk
  CHECK (((gdo_number !~ '^GDO-[0-9]+$'::text) OR (permit_document_path IS NOT NULL))) NOT VALID;
ALTER TABLE public.gdos DROP COLUMN permit_type, DROP COLUMN permit_effective;
DROP TABLE public.permit_types;

DO $verify$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.gdos'::regclass AND attname IN ('permit_type', 'permit_effective') AND NOT attisdropped)
     OR to_regclass('public.permit_types') IS NOT NULL OR to_regclass('client.permit_types') IS NOT NULL THEN
    RAISE EXCEPTION 'permits rollback VERIFY: something of the migration is still there';
  END IF;
  IF has_table_privilege('anon', 'client.gdos', 'SELECT') OR NOT has_table_privilege('authenticated', 'client.gdos', 'SELECT')
     OR has_table_privilege('anon', 'customer.permits', 'SELECT') OR NOT has_table_privilege('authenticated', 'customer.permits', 'SELECT') THEN
    RAISE EXCEPTION 'permits rollback VERIFY: re-created view grants are wrong';
  END IF;
  IF md5(pg_get_viewdef('client.gdos'::regclass, true)) <> 'c4199ae0e9a42b193620bf6f9853952b'
     OR md5(pg_get_viewdef('customer.permits'::regclass, true)) <> '297d4872ec473a729112724270541b89' THEN
    RAISE EXCEPTION 'permits rollback VERIFY: a re-created view does not match its 2026-11-02 text';
  END IF;
END $verify$;

COMMIT;
