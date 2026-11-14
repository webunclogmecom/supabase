-- ROLLBACK of 2026-11-14_0100_derm_manifest_permit_on_read.sql
--
-- Puts derm.gdos and derm.audit_pack back to their bodies before it (verbatim from pg_get_viewdef and
-- pg_get_functiondef: md5 9cc65bade8729ab47eba65bf61b6b63c and 50057524b986a6f33ab2bb07057527bc) and removes the
-- comment on public.derm_manifests.gdo_id (it had none). Guarded: it refuses unless the live bodies are the ones
-- 2026-11-14_0100_derm_manifest_permit_on_read applied (derm.gdos 61979b9b5733e9425d92e0e888e9e31f, derm.audit_pack 85a9574cd400652f04cbd843bfe3c9e6; both compared with carriage returns
-- removed, so it runs from a Windows checkout).
-- What coming back means: derm.gdos.manifest_count counts the stored links again and derm.audit_pack prefers the stored
-- link, so 18 manifests name an INACTIVE permit again. The column itself was never changed, so nothing else returns.
-- Rehearsed before the migration was applied, inside one rolled-back transaction (migration, then this file).

BEGIN;
SET LOCAL lock_timeout = '3s';

do $pin$
begin
  if md5(replace(pg_get_viewdef('derm.gdos'::regclass, false), chr(13), '')) <> '61979b9b5733e9425d92e0e888e9e31f' then
    raise exception 'derm.gdos is not the body 2026-11-14_0100_derm_manifest_permit_on_read applied; refusing to roll back blindly';
  end if;
  if md5(replace(pg_get_functiondef('derm.audit_pack(bigint)'::regprocedure), chr(13), '')) <> '85a9574cd400652f04cbd843bfe3c9e6' then
    raise exception 'derm.audit_pack is not the body 2026-11-14_0100_derm_manifest_permit_on_read applied; refusing to roll back blindly';
  end if;
end
$pin$;

set local search_path = public;

create or replace view derm.gdos as
 SELECT g.id,
    g.client_id,
        CASE
            WHEN ((c.client_code IS NOT NULL) AND (c.name !~~ (c.client_code || '%'::text))) THEN ((c.client_code || ' '::text) || c.name)
            ELSE c.name
        END AS client_name,
    g.gdo_number,
    g.location_label,
    g.property_id,
    (g.permit_expiration)::text AS permit_expiration,
    g.permit_document_path,
    g.status,
    g.notes,
    (g.created_at)::text AS created_at,
    (g.updated_at)::text AS updated_at,
    ( SELECT count(*) AS count
           FROM derm_manifests dm
          WHERE ((dm.gdo_id = g.id) AND (dm.deleted_at IS NULL))) AS manifest_count
   FROM (gdos g
     JOIN clients c ON ((c.id = g.client_id)))
  WHERE (g.permit_type = 'GDO'::text);

CREATE OR REPLACE FUNCTION derm.audit_pack(p_manifest_id bigint)
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
                WHERE g2.client_id = v_m.client_id AND g2.status = 'ACTIVE' AND g2.permit_type = 'GDO'
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
               WHERE g2.client_id = v_m.client_id AND g2.status = 'ACTIVE' AND g2.permit_type = 'GDO'
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
END $function$;

comment on column public.derm_manifests.gdo_id is null;

do $verify$
begin
  if md5(replace(pg_get_viewdef('derm.gdos'::regclass, false), chr(13), '')) <> '9cc65bade8729ab47eba65bf61b6b63c' then
    raise exception 'VERIFY: derm.gdos is not back to its body before 2026-11-14_0100_derm_manifest_permit_on_read';
  end if;
  if md5(replace(pg_get_functiondef('derm.audit_pack(bigint)'::regprocedure), chr(13), '')) <> '50057524b986a6f33ab2bb07057527bc' then
    raise exception 'VERIFY: derm.audit_pack is not back to its body before 2026-11-14_0100_derm_manifest_permit_on_read';
  end if;
  if col_description('public.derm_manifests'::regclass,
       (select attnum from pg_attribute where attrelid = 'public.derm_manifests'::regclass and attname = 'gdo_id')) is not null then
    raise exception 'VERIFY: the comment on derm_manifests.gdo_id is still there';
  end if;
  if (select relacl::text from pg_class where oid = 'derm.gdos'::regclass) is distinct from '{postgres=arwdDxtm/postgres,authenticated=r/postgres,service_role=arwdDxtm/postgres,db_backup_reader=r/postgres}'
     or (select proacl::text from pg_proc where oid = 'derm.audit_pack(bigint)'::regprocedure) is distinct from '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}' then
    raise exception 'VERIFY: rights changed';
  end if;
end
$verify$;

COMMIT;
