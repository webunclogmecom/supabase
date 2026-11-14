-- 2026-11-14_0100_derm_manifest_permit_on_read  A manifest's permit is worked out on read: derm.gdos.manifest_count and derm.audit_pack stop reading
-- public.derm_manifests.gdo_id, and the column is marked FROZEN.
--
-- WHY. Fred, 2026-11-14 (about 12:40 AM ET), asked "Should we stop storing the manifest's permit link and work it out
-- when it's read?": "Yes, work it out".
-- derm_manifests.gdo_id ("the one permit this manifest is evidence for") was only ever written by two bulk fills: 607
-- rows on 2026-05-19/20 and 226 on 2026-08-24 (2026-08-24_1600_bind_manifest_gdo_and_permit_title.sql; its rule: the
-- client holds exactly one ACTIVE GDO- permit, else NULL). No INSERT ever carried it, no function takes or sets it, and
-- the DERM Tracker filed 332 manifests from 2026-08-25 to 2026-11-13 with none. Measured 2026-11-13: 172 manifests of
-- one-permit clients have no link (87 clients; 139 with a Miami-Dade number, 33 with a yellow ticket only), and 20 of
-- the 416 links no longer match the rule (18 name a permit made INACTIVE since, 2 name one of 148-MOR's three permits).
-- A trigger on derm_manifests could not see a permit retired or added later in public.gdos, so a stored copy would
-- drift again. Rule 2 (3NF): a value derivable from the client's permits is not stored.
-- No screen reads the link (11 live app bundles, 7 days of API logs to 2026-11-13 21:00 UTC): the Client App receives it
-- in client.derm_manifests (select *) and never uses it; customer.work_orders / work_orders_all read it inside their
-- manifest LATERAL and never output it; nothing reads derm.gdos (0 requests) and nothing calls derm.audit_pack (0 calls;
-- no function, edge function or app names it; fn_stop_facts_checks only reads its source text as a control).
-- A correction to the brief: 2026-08-24_1510 (9911b7fe) guards manifest-to-visit DATES, not this link. The link's two
-- rules (never another client's permit; a client with several permits stays NULL) lived only in 2026-08-24_1600's
-- VERIFY. 0 links point at another client's permit today.
--
-- WHAT. Both bodies copied from the live definitions (derm.gdos md5 9cc65bade8729ab47eba65bf61b6b63c, derm.audit_pack md5
-- 50057524b986a6f33ab2bb07057527bc, pinned below with carriage returns removed), never retyped; each edit is an anchor
-- asserted to match exactly once (scratchpad generator, not kept).
--   1. derm.gdos.manifest_count was "live manifests whose gdo_id is this permit". Now: the client's live manifests when
--      the permit is ACTIVE with a GDO-<digits> number, else 0. One pump-out is evidence for every ACTIVE permit of its
--      client, the rule the DERM sheets print by (one row per ACTIVE permit). No date window: the 08-24 fill had none,
--      and public.gdos holds no start date to window by.
--   2. derm.audit_pack(bigint): its two permit lookups drop "coalesce(v_m.gdo_id, ...)" and keep the lookup by client
--      (the client's first ACTIVE GDO by id). For a client with several permits that is still one of them, as before
--      (flagged by 2026-08-24_1600; not changed here).
--   3. COMMENT ON COLUMN public.derm_manifests.gdo_id: FROZEN, do not read. The column stays, because
--      client.derm_manifests and customer.work_orders / work_orders_all still select it; a drop goes with them.
-- derm.gdos keeps its 13 columns, types, rights and owner-rights (no reloptions); derm.audit_pack keeps SECURITY
-- DEFINER, STABLE, its search_path and EXECUTE rights, and its body still names public.visits. No row is written.
--
-- REACH, measured 2026-11-14 ~01:00 ET with the old and the new expressions side by side:
--   derm.audit_pack names a different permit for 18 manifests, all linked to an INACTIVE permit. 3 now name the
--   client's ACTIVE permit: 045-NU 157 (GDO-07733 -> GDO-11540), 063-TCE 382 and 543 (GDO-08976 -> GDO-13939), 155-PV
--   704 (GDO-10891 -> GDO-12838). 15 name none, the client holding no ACTIVE GDO: 016-FIA 246, 042-MT 227 573 798,
--   083-SHUL 112 293, 084-ULT 288 474 601, 136-BB 269 972, 137-BB 892 918, 198-ARY 184 (their frequency check reads
--   no-gdo-max-on-file). Every other manifest gets the same permit as before, 148-MOR's two included (its first ACTIVE
--   permit by id is the linked GDO-14769).
--   derm.gdos: 192 GDO permits; manifest_count changes on 108. 98 ACTIVE go up and none goes down; 10 INACTIVE go to 0.
--   Total 416 -> 660 (a client with several permits counts its manifests under each one).
-- Locks: CREATE OR REPLACE VIEW holds ACCESS EXCLUSIVE on derm.gdos until COMMIT (nothing reads it; only cheap checks
-- run inside). The COMMENT takes SHARE UPDATE EXCLUSIVE on public.derm_manifests, so its reads and writes go on.
-- Rule 8 (audit): a view, a function and a comment; nothing to audit.
-- CHECK after commit: scripts/checks/derm_manifest_permit_on_read.sql (every row ok; it fails on the old bodies).
-- ROLLBACK: 2026-11-14_rollback_derm_manifest_permit_on_read.sql
-- APPLIED 2026-11-14 00:59 ET (Management API). Rehearsed first, all rolled back: the VERIFY below on the OLD bodies
-- failed exactly its checks 4, 4b, 5, 6, 7, 8 and 10 and passed its controls; the new bodies passed; this migration
-- then the rollback restored both md5s. After commit: the check's 5 rows ok, derm.audit_pack called on all 1,005
-- manifests equals the new rule on every one and differs from the old on the 18 listed above, and of 1,428 views,
-- functions and tables only derm.gdos, derm.audit_pack and the comment on derm_manifests moved.

BEGIN;
SET LOCAL lock_timeout = '3s';

do $pin$
begin
  if md5(replace(pg_get_viewdef('derm.gdos'::regclass, false), chr(13), '')) <> '9cc65bade8729ab47eba65bf61b6b63c' then
    raise exception 'derm.gdos is not the body this migration was generated from; rebuild this migration from the live definition';
  end if;
  if md5(replace(pg_get_functiondef('derm.audit_pack(bigint)'::regprocedure), chr(13), '')) <> '50057524b986a6f33ab2bb07057527bc' then
    raise exception 'derm.audit_pack is not the body this migration was generated from; rebuild this migration from the live definition';
  end if;
end
$pin$;

set local search_path = public;   -- pg_get_viewdef printed the public names unqualified; derm.gdos must read public.gdos

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
          WHERE ((dm.client_id = g.client_id) AND (dm.deleted_at IS NULL) AND (g.status = 'ACTIVE'::text) AND (g.gdo_number ~ '^GDO-[0-9]+$'::text))) AS manifest_count
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
      WHERE g.id = (SELECT g2.id FROM public.gdos g2
                WHERE g2.client_id = v_m.client_id AND g2.status = 'ACTIVE' AND g2.permit_type = 'GDO'
                ORDER BY g2.id LIMIT 1)),
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
      LEFT JOIN public.gdos g ON g.id = (SELECT g2.id FROM public.gdos g2
               WHERE g2.client_id = v_m.client_id AND g2.status = 'ACTIVE' AND g2.permit_type = 'GDO'
               ORDER BY g2.id LIMIT 1)
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

comment on column public.derm_manifests.gdo_id is 'FROZEN, do not read it as the manifest''s permit (2026-11-14). Only two one-time fills ever wrote it (2026-05-19/20 and 2026-08-24_1600) and nothing keeps it up: no filing sets it, so manifests filed since 2026-08-24 have none, and a link can name a permit made INACTIVE since. A manifest is evidence for every ACTIVE GDO permit of its client; derm.gdos.manifest_count works that out on read. Kept only because client.derm_manifests (select * in the Client App) and customer.work_orders / work_orders_all still select it: drop it together with them. Decision and readers: docs/migrations/2026-11-14_0100_derm_manifest_permit_on_read.sql';

do $verify$
declare
  v_fail text[] := '{}';
  v_t text;
  v_n int;
  v_m int;
  v_j jsonb;
  v_gdo_id int := (select attnum from pg_attribute where attrelid = 'public.derm_manifests'::regclass and attname = 'gdo_id');
  v_client_id int := (select attnum from pg_attribute where attrelid = 'public.derm_manifests'::regclass and attname = 'client_id');
  v_deleted_at int := (select attnum from pg_attribute where attrelid = 'public.derm_manifests'::regclass and attname = 'deleted_at');
begin
  -- 1-3 derm.gdos keeps its 13 columns, its rights, and stays owner-rights
  select string_agg(attname || ':' || format_type(atttypid, atttypmod), ', ' order by attnum) into v_t
    from pg_attribute where attrelid = 'derm.gdos'::regclass and attnum > 0 and not attisdropped;
  if v_t is distinct from 'id:bigint, client_id:bigint, client_name:text, gdo_number:text, location_label:text, property_id:bigint, permit_expiration:text, permit_document_path:text, status:text, notes:text, created_at:text, updated_at:text, manifest_count:bigint' then v_fail := array_append(v_fail, '1 columns ' || coalesce(v_t, 'none')); end if;
  if (select reloptions from pg_class where oid = 'derm.gdos'::regclass) is not null then
    v_fail := array_append(v_fail, '2 reloptions set'); end if;
  select relacl::text into v_t from pg_class where oid = 'derm.gdos'::regclass;
  if v_t is distinct from '{postgres=arwdDxtm/postgres,authenticated=r/postgres,service_role=arwdDxtm/postgres,db_backup_reader=r/postgres}' then v_fail := array_append(v_fail, '3 acl ' || coalesce(v_t, 'none')); end if;
  -- 4 derm.gdos reads derm_manifests.client_id and no longer gdo_id; 4c: the instrument sees deleted_at (old and new)
  select count(*) filter (where d.refobjsubid = v_gdo_id), count(*) filter (where d.refobjsubid = v_client_id)
    into v_n, v_m
    from pg_depend d join pg_rewrite r on r.oid = d.objid
   where r.ev_class = 'derm.gdos'::regclass and d.refobjid = 'public.derm_manifests'::regclass;
  if v_n <> 0 then v_fail := array_append(v_fail, '4 derm.gdos still reads derm_manifests.gdo_id'); end if;
  if v_m = 0 then v_fail := array_append(v_fail, '4b derm.gdos does not read derm_manifests.client_id'); end if;
  select count(*) into v_n from pg_depend d join pg_rewrite r on r.oid = d.objid
   where r.ev_class = 'derm.gdos'::regclass and d.refobjid = 'public.derm_manifests'::regclass and d.refobjsubid = v_deleted_at;
  if v_n = 0 then v_fail := array_append(v_fail, '4c control: no dependency on derm_manifests.deleted_at seen'); end if;
  -- 5 the rule on every GDO permit; 5c: not a comparison of zeros
  select count(*) into v_n from derm.gdos d join public.gdos g on g.id = d.id
   where d.manifest_count is distinct from (case when g.status = 'ACTIVE' and g.gdo_number ~ '^GDO-[0-9]+$'
           then (select count(*) from public.derm_manifests m where m.client_id = g.client_id and m.deleted_at is null)
           else 0 end);
  if v_n <> 0 then v_fail := array_append(v_fail, '5 manifest_count disagrees with the rule on ' || v_n || ' permits'); end if;
  select count(*) into v_n from derm.gdos where manifest_count > 0;
  if v_n < 50 then v_fail := array_append(v_fail, '5c control: only ' || v_n || ' permits count a manifest'); end if;
  -- 6 derm.audit_pack: no stored link; the lookup by client (twice), public.visits (fn_stop_facts_checks Z8 control),
  --   SECURITY DEFINER, STABLE, search_path and EXECUTE rights unchanged
  if exists (select 1 from pg_proc where oid = 'derm.audit_pack(bigint)'::regprocedure and prosrc ~ 'v_m[.]gdo_id') then
    v_fail := array_append(v_fail, '6 derm.audit_pack still reads v_m.gdo_id'); end if;
  select count(*) into v_n from pg_proc p
   where p.oid = 'derm.audit_pack(bigint)'::regprocedure
     and (select count(*) from regexp_matches(p.prosrc, 'g2[.]client_id = v_m[.]client_id', 'g')) = 2
     and p.prosrc ~ '[[:<:]]visits[[:>:]]' and p.prosecdef and p.provolatile = 's'
     and array_to_string(p.proconfig, ',') = 'search_path=derm, public, audit'
     and p.proacl::text = '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}';
  if v_n <> 1 then v_fail := array_append(v_fail, '6c derm.audit_pack lost its lookup by client, the visits control or a setting'); end if;
  -- 7-9 exercise it (PL/pgSQL is parsed at its first call)
  v_j := derm.audit_pack(157);   -- 045-NU, linked to GDO-07733 (INACTIVE); its ACTIVE permit is GDO-11540
  if v_j->'gdo'->>'gdo_number' is distinct from 'GDO-11540' then
    v_fail := array_append(v_fail, '7 manifest 157 names ' || coalesce(v_j->'gdo'->>'gdo_number', 'none')); end if;
  v_j := derm.audit_pack(112);   -- 083-SHUL, linked to GDO-12490 (INACTIVE); it holds no ACTIVE GDO
  if jsonb_typeof(v_j->'gdo') is distinct from 'null' then
    v_fail := array_append(v_fail, '8 manifest 112 names ' || coalesce(v_j->>'gdo', 'missing')); end if;
  v_j := derm.audit_pack(1779);  -- 045-NU, no link: GDO-11540 before and after (control)
  if v_j->'gdo'->>'gdo_number' is distinct from 'GDO-11540' then
    v_fail := array_append(v_fail, '9 control: manifest 1779 names ' || coalesce(v_j->'gdo'->>'gdo_number', 'none')); end if;
  -- 10 the column says it is frozen
  if coalesce(col_description('public.derm_manifests'::regclass, v_gdo_id), '') not like 'FROZEN%' then
    v_fail := array_append(v_fail, '10 derm_manifests.gdo_id is not marked FROZEN'); end if;
  if cardinality(v_fail) > 0 then raise exception 'VERIFY failed: %', array_to_string(v_fail, ' | '); end if;
end
$verify$;

COMMIT;
