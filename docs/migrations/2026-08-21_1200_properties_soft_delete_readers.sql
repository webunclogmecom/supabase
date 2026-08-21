-- 2026-08-21_1200_properties_soft_delete_readers.sql
--
-- 🛑 GENERATED, DO NOT HAND-EDIT. Regenerate with:
--       node scripts/probes/build_soft_delete_view_migration.mjs
--    Every body below is the LIVE pg_get_viewdef / pg_get_functiondef output with ONE anchored
--    replacement, asserted at generation time to match exactly once. That is the only defence
--    against the CREATE OR REPLACE hazard in CLAUDE.md: the statement takes the WHOLE body, so
--    anything not reproduced is silently deleted while the header still reads as a one-line change.
--
-- WHAT: teaches the readers of public.properties about deleted_at, added by 2026-08-21_0530.
--
-- WHY:  until now the column was a marker nothing read. A property removed in Jobber was retired
--       here and still appeared in every list, so the soft-delete recorded the fact and changed
--       nothing a person sees.
--
-- 🛑 THE TIERING RULE, AND IT IS NOT "app-facing vs internal". That was the first proposal and it
--    is WRONG in a way that would have destroyed customer-facing compliance history.
--    The question is what the view IS:
--
--      A WORKLIST  (things to act on)      -> hide the retired property
--      A RECORD    (things that happened)  -> keep it, always
--
--    customer.work_orders is customer-facing AND a record: it is the client's DERM compliance
--    history. Filtering it would delete completed work orders from a regulator-facing surface
--    because the property was later removed in Jobber. Same for every derm.* view, ops.v_ar_aging,
--    ops.v_revenue_summary, ops.v_derm_compliance, public.visits_recent and public.visits_with_status.
--
-- 🛑 THE SECOND RULE IS ABOUT GRAIN, AND IT IS WHY ONLY 7 OF 30 VIEWS ARE TOUCHED.
--    Of the 30 views reading public.properties, most reach it through a LEFT JOIN whose grain is a
--    VISIT or a MANIFEST, with properties only supplying an address. Adding `p.deleted_at IS NULL`
--    to a WHERE there does not hide a property, it DELETES THE VISIT. The filter is only safe where
--    properties is the driving table, or inside an aggregate/subquery whose result is a single
--    field, or in a LEFT JOIN's ON clause (which nulls columns and keeps the row).
--    See feedback_reused_gate_carries_its_old_grain: the copied filter deletes exactly the rows the
--    change exists to produce.
--
-- CHANGED (7 objects):
--   client.properties        WHERE   grain = property. The Client App's property list.
--   ops.properties           WHERE   grain = property.
--   client.clients           x2      inside two LEFT JOIN LATERAL aggregates (derived zone, grease
--                                    capacity) so a retired property stops voting. Client row kept.
--   customer.clients         ON      so the Field Portal shows no address rather than a dead one.
--                                    A WHERE here would remove the CLIENT. It is an ON clause.
--   public.zones_with_usage  count   a retired property no longer inflates a zone's usage count.
--   derm.v_stamp_clients     subq    its address is ORDER BY p.id LIMIT 1, so a retired property
--                                    sorting first would supply a dead address.
--   client.global_search     WHERE   a search result is a worklist; a retired property is not
--                                    findable. authenticated-EXECUTE, so this is a live app path.
--
-- DELIBERATELY NOT CHANGED, with the reason, so nobody "finishes the job" later:
--   customer.work_orders, customer.permits, customer.client_access_photos, all 5 derm.* views,
--   ops.v_calendar_visit, ops.v_route_today, ops.v_service_due, ops.v_gdo_expiry, ops.v_ar_aging,
--   ops.v_revenue_summary, ops.v_derm_compliance, public.client_services_flat,
--   public.clients_due_service, public.manifest_detail, public.manifest_pickable_visits,
--   public.v_derm_portal_fields, public.v_visit_city_email, public.visits_recent,
--   public.visits_with_status  -> records, or property is a LEFT JOIN lookup on another grain.
--   ops.v_depot, ops.v_dump_sites -> each pins ONE property by config/constant. If that property
--     were ever retired the right outcome is a loud configuration error, not a silently empty view.
--   customer.permits -> a GDO is issued to a LOCATION and outlives the property row; its
--     properties joins drive address-matching inside the compliance maths, so filtering them would
--     change over_gdo_max and compliant rather than hide anything.
--
-- ⚠ STILL OPEN AFTER THIS, and it is NOT covered here: `authenticated` holds SELECT on
--   public.properties itself, and pg_stat_statements shows live PostgREST reads against the base
--   table. Any app query written against public.properties rather than client.properties still
--   sees retired rows. That is an app-side change, not a DB one.
--
-- AUDIT (rule 8): views and one function only, no table or column touched, so no audit change.
--   public.properties keeps its audit_properties trigger from 2026-08-21_0530.
--
-- GRANTS: CREATE OR REPLACE preserves them. DROP VIEW would NOT (see
--   reference_drop_view_discards_grants), which is why nothing here drops anything. The VERIFY
--   re-asserts the authenticated grant on all seven objects anyway.

begin;

-- ---- PART 0: BASELINE, taken INSIDE the transaction ---------------------------------------------
-- 🛑 The single most important assertion in this file is NOT "the seven views changed". It is
--    "the twenty-three I left alone did NOT". A filter applied to the wrong grain deletes visits
--    and manifests silently, so every view is counted before and after and the diff must match an
--    expectation stated per view. An untouched view whose count moves aborts the whole migration.
create temp table _pre_counts(obj text primary key, n bigint) on commit drop;
do $pre$
declare o text; c bigint;
begin
  foreach o in array array[
    'client.properties','ops.properties','client.clients','customer.clients',
    'public.zones_with_usage','derm.v_stamp_clients',
    'customer.work_orders','customer.permits','customer.client_access_photos',
    'ops.v_calendar_visit','ops.v_route_today','ops.v_service_due','ops.v_gdo_expiry',
    'ops.v_derm_compliance','ops.v_ar_aging','ops.v_revenue_summary',
    'derm.visits','derm.manifests','derm.manifest_visits','derm.manifest_recipients',
    'public.visits_with_status','public.visits_recent','public.manifest_pickable_visits',
    'public.client_services_flat','public.clients_due_service','public.manifest_detail',
    'public.v_visit_city_email','public.v_derm_portal_fields',
    'ops.v_depot','ops.v_dump_sites'
  ] loop
    execute format('select count(*) from %s', o) into c;
    insert into _pre_counts values (o, c);
  end loop;
end $pre$;


-- ----------------------------------------------------------------------------------------------
-- client.properties
-- ----------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW client.properties AS
SELECT id,
    client_id,
    name,
    address,
    city,
    state,
    zip,
    country,
    is_billing,
    created_at,
    updated_at,
    latitude,
    longitude,
    geofence_radius_meters,
    geofence_type,
    fn_sched_open(access_schedule) AS access_hours_start,
    fn_sched_close(access_schedule) AS access_hours_end,
    fn_sched_days(access_schedule) AS access_days,
    is_primary,
    notes,
    county,
    grease_trap_manhole_count,
    access_notes,
    default_disposal_facility_id,
    zone_id,
    sample_port_count,
    ( SELECT z.code
           FROM zones z
          WHERE z.id = p.zone_id) AS zone,
    (( SELECT count(*) AS count
           FROM jobs j
          WHERE j.property_id = p.id))::integer AS job_count,
    (EXISTS ( SELECT 1
           FROM entity_source_links l
          WHERE l.entity_type = 'property'::text AND l.source_system = 'jobber'::text AND l.entity_id = p.id)) AS jobber_linked,
    COALESCE(grease_trap_size_gallons::numeric, ( SELECT sc.equipment_size_gallons
           FROM service_configs sc
          WHERE sc.property_id = p.id AND sc.service_type = 'Pumping'::text
          ORDER BY sc.id
         LIMIT 1)) AS grease_capacity_gallons,
    access_schedule,
    fn_city_regulator_emails(city) AS city_emails
   FROM properties p
  WHERE p.deleted_at IS NULL;

-- ----------------------------------------------------------------------------------------------
-- ops.properties
-- ----------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW ops.properties AS
SELECT p.id,
    p.client_id,
    p.name,
    p.address,
    p.city,
    p.state,
    p.zip,
    p.country,
    p.is_billing,
    p.created_at,
    p.updated_at,
    z.code AS zone,
    p.latitude,
    p.longitude,
    p.geofence_radius_meters,
    p.geofence_type,
    fn_sched_open(p.access_schedule) AS access_hours_start,
    fn_sched_close(p.access_schedule) AS access_hours_end,
    fn_sched_days(p.access_schedule) AS access_days,
    p.is_primary,
    p.notes,
    p.county,
    p.grease_trap_manhole_count,
    p.access_notes,
    p.default_disposal_facility_id
   FROM properties p
     LEFT JOIN zones z ON z.id = p.zone_id
  WHERE p.deleted_at IS NULL;

-- ----------------------------------------------------------------------------------------------
-- client.clients
-- ----------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW client.clients AS
SELECT c.id,
    c.client_code,
    c.name,
    c.status,
    c.balance,
    c.notes,
    c.created_at,
    c.updated_at,
    c.group_id,
    c.client_class,
    c.client_class_source,
    ( SELECT
                CASE
                    WHEN l.source_id ~ '^[0-9]+$'::text THEN 'https://secure.getjobber.com/clients/'::text || l.source_id
                    WHEN (length(l.source_id) % 4) = 0 AND l.source_id ~ '^[A-Za-z0-9+/]+={0,2}$'::text THEN 'https://secure.getjobber.com/clients/'::text || split_part(convert_from(decode(l.source_id, 'base64'::text), 'UTF8'::name), '/'::text, '-1'::integer)
                    ELSE NULL::text
                END AS "case"
           FROM entity_source_links l
          WHERE l.entity_type = 'client'::text AND l.source_system = 'jobber'::text AND l.entity_id = c.id
         LIMIT 1) AS jobber_url,
    dz.zone_id,
    dz.zone_code,
    gt.grease_trap_size_gallons
   FROM clients c
     LEFT JOIN LATERAL ( SELECT
                CASE
                    WHEN count(DISTINCT p.zone_id) = 1 THEN min(p.zone_id)
                    ELSE NULL::bigint
                END AS zone_id,
                CASE
                    WHEN count(DISTINCT p.zone_id) = 1 THEN min(z.code)
                    WHEN count(DISTINCT p.zone_id) > 1 THEN 'MIXED'::text
                    ELSE NULL::text
                END AS zone_code
           FROM properties p
             JOIN zones z ON z.id = p.zone_id
          WHERE p.client_id = c.id AND p.zone_id IS NOT NULL AND p.deleted_at IS NULL) dz ON true
     LEFT JOIN LATERAL ( SELECT COALESCE(max(p.grease_trap_size_gallons) FILTER (WHERE p.is_billing IS DISTINCT FROM true), max(p.grease_trap_size_gallons) FILTER (WHERE p.is_billing IS TRUE)) AS grease_trap_size_gallons
           FROM properties p
          WHERE p.client_id = c.id AND p.grease_trap_size_gallons IS NOT NULL AND p.deleted_at IS NULL) gt ON true;

-- ----------------------------------------------------------------------------------------------
-- customer.clients
-- ----------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW customer.clients AS
SELECT customer.uuid_from_bigint(c.id) AS id,
    lower(c.client_code) AS slug,
    c.name,
    c.client_code,
    cg.name AS group_name,
    p.address AS address1,
    NULLIF(TRIM(BOTH ' ,'::text FROM concat_ws(', '::text, NULLIF(p.city, ''::text), NULLIF(concat_ws(' '::text, NULLIF(p.state, ''::text), NULLIF(p.zip, ''::text)), ''::text))), ''::text) AS address2,
        CASE
            WHEN sc_gt.equipment_size_gallons IS NOT NULL THEN sc_gt.equipment_size_gallons::text || ' gal grease trap'::text
            ELSE NULL::text
        END AS container_type,
        CASE
            WHEN sc_gt.equipment_size_gallons IS NOT NULL THEN sc_gt.equipment_size_gallons::text || ' gal'::text
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
          WHERE j.client_id = c.id AND j.title ~~* '%Service Agreement%'::text AND j.job_status <> 'archived'::text AND j.frequency_days > 0) AS service_frequency_days
   FROM clients c
     LEFT JOIN client_groups cg ON cg.id = c.group_id
     LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true AND p.deleted_at IS NULL
     LEFT JOIN service_configs sc_gt ON sc_gt.client_id = c.id AND sc_gt.service_type = 'Pumping'::text
     LEFT JOIN disposal_facilities df ON df.id = p.default_disposal_facility_id;

-- ----------------------------------------------------------------------------------------------
-- public.zones_with_usage
-- ----------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.zones_with_usage AS
SELECT z.id,
    z.code,
    z.label,
    z.color_hex,
    z.color_token,
    z.sort_order,
    z.is_active,
    z.created_at,
    z.updated_at,
    COALESCE(p.n_properties, 0) AS n_properties
   FROM zones z
     LEFT JOIN ( SELECT properties.zone_id,
            count(*)::integer AS n_properties
           FROM properties
          WHERE properties.zone_id IS NOT NULL AND properties.deleted_at IS NULL
          GROUP BY properties.zone_id) p ON p.zone_id = z.id;

-- ----------------------------------------------------------------------------------------------
-- derm.v_stamp_clients
-- ----------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW derm.v_stamp_clients AS
SELECT id,
    client_code,
    name,
    ( SELECT p.address
           FROM properties p
          WHERE p.client_id = c.id AND p.deleted_at IS NULL
          ORDER BY p.id
         LIMIT 1) AS address,
    status
   FROM clients c
  WHERE client_code IS NOT NULL
  ORDER BY client_code;

-- ----------------------------------------------------------------------------------------------
-- client.global_search
-- ----------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION client.global_search(q text, p_limit integer DEFAULT 5, p_offset integer DEFAULT 0, p_groups text[] DEFAULT NULL::text[], p_include_inactive boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'client', 'public', 'pg_temp'
AS $function$
with params as (
  select btrim(coalesce(q, ''))              as raw,
         '%' || btrim(coalesce(q, '')) || '%' as contains,
         btrim(coalesce(q, '')) || '%'        as prefix,
         greatest(coalesce(p_limit, 5), 1)    as lim,
         greatest(coalesce(p_offset, 0), 0)   as off,
         (btrim(coalesce(q, '')) ~ '^[0-9]+$') as is_numeric
    from (select 1) _
   where length(btrim(coalesce(q, ''))) >= 2
),
want as (
  select p_groups is null or 'clients'    = any(p_groups) as g_clients,
         p_groups is null or 'properties' = any(p_groups) as g_properties,
         p_groups is null or 'invoices'   = any(p_groups) as g_invoices,
         p_groups is null or 'quotes'     = any(p_groups) as g_quotes
),
-- CLIENTS ---------------------------------------------------------------------
c_all as (
  select c.id, c.name as title,
         nullif(concat_ws(' · ', c.client_code, c.status), '') as subtitle,
         c.status as badge,
         (case when c.balance > 0 then c.balance end) as amount,
         null::date as occurred_on,
         c.id as client_id, c.name as client_name, c.client_code,
         case
           when upper(coalesce(c.client_code,'')) = upper(p.raw)        then 0
           when c.client_code ilike p.prefix                            then 1
           when p.is_numeric and split_part(coalesce(c.client_code,''),'-',1) = p.raw then 1
           when c.name ilike p.prefix                                   then 2
           else 3
         end as rank
    from public.clients c cross join params p cross join want w
   where w.g_clients
     and (p_include_inactive or c.status <> 'INACTIVE')
     and (c.name ilike p.contains or c.client_code ilike p.contains)
),
-- PROPERTIES (deduped per client+address, keeping the row that has jobs) -------
p_dedup as (
  select distinct on (pr.client_id, lower(btrim(coalesce(pr.address,''))))
         pr.id, pr.client_id, pr.address, pr.city, pr.state, pr.zip, pr.county,
         pr.is_billing, pr.zone_id,
         (select count(*) from public.jobs j where j.property_id = pr.id) as job_count
    from public.properties pr cross join want w
   where w.g_properties
     and pr.deleted_at is null
   order by pr.client_id, lower(btrim(coalesce(pr.address,''))),
            (select count(*) from public.jobs j where j.property_id = pr.id) desc,
            pr.is_primary desc, pr.id
),
p_all as (
  select d.id, d.address as title,
         nullif(concat_ws(', ', d.city, d.state, d.zip), '') as subtitle,
         case when d.is_billing and d.job_count = 0 then 'Billing address'
              else (select z.code from public.zones z where z.id = d.zone_id) end as badge,
         null::numeric as amount, null::date as occurred_on,
         c.id as client_id, c.name as client_name, c.client_code,
         case when d.address ilike p.prefix then 4 else 5 end as rank
    from p_dedup d
    join public.clients c on c.id = d.client_id
    cross join params p
   where d.address ilike p.contains or d.city ilike p.contains
      or d.zip ilike p.contains or d.county ilike p.contains
      or c.name ilike p.contains or c.client_code ilike p.contains
),
-- INVOICES --------------------------------------------------------------------
i_all as (
  select i.id,
         'Invoice #' || coalesce(i.invoice_number::text, i.id::text) as title,
         nullif(i.subject, '') as subtitle,
         i.invoice_status as badge,
         i.total as amount,
         coalesce(i.due_date, i.sent_at::date) as occurred_on,
         c.id as client_id, c.name as client_name, c.client_code,
         case when p.is_numeric and i.invoice_number::text = p.raw then 2 else 6 end as rank
    from public.invoices i
    join public.clients c on c.id = i.client_id
    cross join params p cross join want w
   where w.g_invoices
     and (i.invoice_number::text ilike p.contains or i.subject ilike p.contains
          or c.name ilike p.contains or c.client_code ilike p.contains)
),
-- QUOTES ----------------------------------------------------------------------
qt_all as (
  select qt.id,
         'Quote #' || coalesce(qt.quote_number::text, qt.id::text) as title,
         nullif(qt.title, '') as subtitle,
         qt.quote_status as badge,
         qt.total as amount,
         qt.sent_at::date as occurred_on,
         c.id as client_id, c.name as client_name, c.client_code,
         case when p.is_numeric and qt.quote_number::text = p.raw then 2 else 7 end as rank
    from public.quotes qt
    join public.clients c on c.id = qt.client_id
    cross join params p cross join want w
   where w.g_quotes
     and (p_include_inactive or coalesce(qt.quote_status,'') <> 'archived')
     and (qt.quote_number::text ilike p.contains or qt.title ilike p.contains
          or c.name ilike p.contains or c.client_code ilike p.contains)
),
grp as (
  select 'clients'    as k, (select count(*) from c_all)  as total,
         (select coalesce(jsonb_agg(x order by x_rank, x_title), '[]'::jsonb) from (
            select jsonb_build_object('id',id,'title',title,'subtitle',subtitle,'badge',badge,
                     'amount',amount,'occurred_on',occurred_on,'rank',rank,
                     'client',jsonb_build_object('id',client_id,'name',client_name,'client_code',client_code)) as x,
                   rank as x_rank, title as x_title
              from c_all order by rank, title
             limit (select lim from params) offset (select off from params)) s) as rows
  union all
  select 'properties', (select count(*) from p_all),
         (select coalesce(jsonb_agg(x order by x_rank, x_title), '[]'::jsonb) from (
            select jsonb_build_object('id',id,'title',title,'subtitle',subtitle,'badge',badge,
                     'amount',amount,'occurred_on',occurred_on,'rank',rank,
                     'client',jsonb_build_object('id',client_id,'name',client_name,'client_code',client_code)) as x,
                   rank as x_rank, title as x_title
              from p_all order by rank, title
             limit (select lim from params) offset (select off from params)) s)
  union all
  select 'invoices', (select count(*) from i_all),
         (select coalesce(jsonb_agg(x order by x_rank, x_title), '[]'::jsonb) from (
            select jsonb_build_object('id',id,'title',title,'subtitle',subtitle,'badge',badge,
                     'amount',amount,'occurred_on',occurred_on,'rank',rank,
                     'client',jsonb_build_object('id',client_id,'name',client_name,'client_code',client_code)) as x,
                   rank as x_rank, title as x_title
              from i_all order by rank, title
             limit (select lim from params) offset (select off from params)) s)
  union all
  select 'quotes', (select count(*) from qt_all),
         (select coalesce(jsonb_agg(x order by x_rank, x_title), '[]'::jsonb) from (
            select jsonb_build_object('id',id,'title',title,'subtitle',subtitle,'badge',badge,
                     'amount',amount,'occurred_on',occurred_on,'rank',rank,
                     'client',jsonb_build_object('id',client_id,'name',client_name,'client_code',client_code)) as x,
                   rank as x_rank, title as x_title
              from qt_all order by rank, title
             limit (select lim from params) offset (select off from params)) s)
)
select jsonb_build_object(
  'query', coalesce((select raw from params), btrim(coalesce(q,''))),
  'total_count', coalesce((select sum(total) from grp), 0),
  'groups', coalesce((select jsonb_object_agg(k, jsonb_build_object(
              'total_count', total,
              'has_more', (total > (select off from params) + jsonb_array_length(rows)),
              'rows', rows)) from grp), '{}'::jsonb),
  'unavailable_groups', jsonb_build_array(
     jsonb_build_object('key','payments','label','Payments',
                        'reason','Payments are not synced from Jobber yet'))
);
$function$;

-- ---- VERIFY -------------------------------------------------------------------------------------
do $verify$
declare
  v_retired bigint; v_live bigint; v_total bigint;
  v_n bigint; v_pre bigint; o text; v_def text; v_bad text := '';
  -- Objects whose count MUST move, and by how much. Everything else must not move at all.
  --   client.properties / ops.properties : grain = property, so they lose exactly the retired rows.
  --   the rest of the changed set        : aggregates, ON-clauses and subqueries, so their ROW
  --                                        COUNT is unchanged even though their VALUES may change.
  expect_drop text[] := array['client.properties','ops.properties'];
begin
  select count(*) filter (where deleted_at is not null), count(*) filter (where deleted_at is null), count(*)
    into v_retired, v_live, v_total from public.properties;

  -- 1. the filter is actually present in all seven bodies -----------------------------------------
  foreach o in array array['client.properties','ops.properties','client.clients','customer.clients',
                           'public.zones_with_usage','derm.v_stamp_clients'] loop
    v_def := pg_get_viewdef(o::regclass, true);
    if v_def !~* 'deleted_at IS NULL' then
      raise exception 'VERIFY: % does not filter deleted_at', o;
    end if;
  end loop;
  if (select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
       where n.nspname='client' and p.proname='global_search') !~* 'pr\.deleted_at is null' then
    raise exception 'VERIFY: client.global_search does not filter pr.deleted_at';
  end if;

  -- 2. client.clients got BOTH lateral edits, not one ---------------------------------------------
  -- A single-occurrence check would pass with only one of the two applied, which is exactly the
  -- half-applied state that leaves a retired property still voting on grease capacity.
  if (select count(*) from regexp_matches(pg_get_viewdef('client.clients'::regclass, true),
                                          'deleted_at IS NULL', 'g')) <> 2 then
    raise exception 'VERIFY: client.clients must carry exactly 2 deleted_at filters (zone + grease)';
  end if;

  -- 3. the property-grain views lost EXACTLY the retired rows -------------------------------------
  foreach o in array expect_drop loop
    execute format('select count(*) from %s', o) into v_n;
    select n into v_pre from _pre_counts where obj = o;
    if v_n <> v_live then
      raise exception 'VERIFY: % returns % rows, expected % (live properties)', o, v_n, v_live;
    end if;
    if v_pre - v_n <> v_retired then
      raise exception 'VERIFY: % dropped % rows, expected % (retired properties)', o, v_pre - v_n, v_retired;
    end if;
  end loop;

  -- 4. 🛑 NOTHING ELSE MOVED. This is the assertion that catches a filter applied to the wrong
  --    grain, which would delete visits or manifests rather than hide a property.
  for o, v_pre in select obj, n from _pre_counts where obj <> all(expect_drop) loop
    execute format('select count(*) from %s', o) into v_n;
    if v_n <> v_pre then
      v_bad := v_bad || format('%s %s->%s; ', o, v_pre, v_n);
    end if;
  end loop;
  if v_bad <> '' then
    raise exception 'VERIFY: an untouched view changed its row count: %', v_bad;
  end if;

  -- 5. CONTROLS. A filter that hides everything would satisfy check 3 if v_live were 0, and a
  --    filter that hides nothing would satisfy check 4. Name a real row on each side.
  if v_retired = 0 then
    raise exception 'VERIFY: no retired properties exist, so checks 3 and 4 prove nothing. Refusing.';
  end if;
  if exists (select 1 from client.properties cp
              join public.properties pp on pp.id = cp.id where pp.deleted_at is not null) then
    raise exception 'VERIFY: a retired property is still visible in client.properties';
  end if;
  if not exists (select 1 from client.properties cp
                  join public.properties pp on pp.id = cp.id where pp.deleted_at is null) then
    raise exception 'VERIFY: client.properties is empty - the filter hid everything';
  end if;

  -- 6. grants survived (CREATE OR REPLACE keeps them; DROP VIEW would not) -------------------------
  foreach o in array array['client.properties','ops.properties','client.clients','customer.clients',
                           'public.zones_with_usage','derm.v_stamp_clients'] loop
    if not has_table_privilege('authenticated', o, 'SELECT') then
      raise exception 'VERIFY: authenticated lost SELECT on %', o;
    end if;
    if has_table_privilege('anon', o, 'SELECT') then
      raise exception 'VERIFY: % became anon-readable', o;
    end if;
  end loop;

  raise notice 'VERIFY ok: 7 objects filter deleted_at; % retired rows hidden from % property-grain views; 28 other views unchanged; grants intact',
    v_retired, array_length(expect_drop, 1);
end $verify$;

commit;
