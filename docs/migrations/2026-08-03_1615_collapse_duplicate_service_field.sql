-- =====================================================================
-- 2026-08-03_1615  Collapse the duplicate service field from the app payloads
-- =====================================================================
-- WHY
--   Fred: "now collapse those two fields in the job editor payload."
--   Phase C2 dropped service_line_items.service_kind from the BASE TABLE but
--   deliberately kept the app-facing name, so `service_type` and `service_kind`
--   still arrived as two identical fields. This removes the duplicate.
--
-- 🛑 WHAT THE EVIDENCE ACTUALLY SHOWED — the premise was half wrong
--   "The job editor payload" is ops.client_service_options.services[]. Measured
--   via pg_stat_statements (PostgREST names every column explicitly, so it is an
--   exact record of what apps request):
--     * The two PostgREST queries against ops.client_service_options are frozen
--       at 329 and 227 calls with stats_since 2026-06-23. Opening the Client App
--       job editor live did NOT increment either counter.
--       ⇒ ops.client_service_options IS NO LONGER READ BY ANY APP. The Client
--         App reads service_line_items, jobs and line_items directly.
--     * `service_kind` appears ZERO times in the Client App's bundle (all 11
--       chunks actually fetched, controls passing: supabase present, 5,875
--       string literals).
--     * EVERY live app query that selects a service_kind column selects
--       ops.v_calendar_visit.service_kind — which is the SA/SC classifier, a
--       DIFFERENT concept that must stay. 16 such statements, up to 4,186 calls.
--     * NO app query selects service_kind from service_line_items. The 12 live
--       queries request code/id/title/reason/schedulable/active/requires_derm/
--       unit_price only.
--   ⇒ Removing the duplicate is safe, and no app republish is required.
--
-- ⚠ A BUNDLE SCAN NEARLY GAVE THE WRONG ANSWER, TWICE
--   The Client App's real chunks are referenced by <link rel="modulepreload">,
--   NOT by <script src>. Seeding from script tags found ONE 21 KB file
--   (~flock.js) and both positive controls failed — a confident zero from a
--   broken instrument. Even after fixing the seed, the bundle said
--   "client_service_options: absent" while pg_stat_statements showed 556 calls.
--   The database was right and the bundle was right too: the calls were
--   HISTORICAL. Neither source alone was sufficient; the deciding test was
--   exercising the editor and watching the counter not move.
--
-- WHAT CHANGES
--   ops.client_service_options.services[] loses its 'service_kind' key.
--   client.service_line_items and ops.service_line_items lose the service_kind
--   column. Every other column, and every other view, is untouched.
--
-- ⚠ ops.v_calendar_visit.service_kind IS NOT TOUCHED. It is the SA/SC
--   classifier the Visit Calendar equality-filters on, it has nothing to do with
--   the service taxonomy, and 4,186+ live calls read it.
--
-- ⚠ DROP + CREATE, NOT CREATE OR REPLACE, for the two passthrough views:
--   Postgres cannot drop a column from a view in place. Nothing depends on
--   either (verified via pg_depend). DROP DISCARDS GRANTS, so both are
--   re-granted explicitly below — including ops.service_line_items'
--   yannick_readonly grant, which a careless rewrite would silently drop.
--
-- AUDIT OPT-IN (rule #8): no new table, no base-table change.
-- REVERSIBLE: yes — re-add the key/columns as `service_type AS service_kind`.
-- =====================================================================

begin;

set local search_path = public;

-- GUARD: refuse if anything has started reading these since the survey.
do $$
declare n int;
begin
  -- schema-qualified: this migration sets search_path=public, and the extension
  -- lives in `extensions`. Unqualified it raises 42P01 and the guard never runs.
  select count(*) into n from extensions.pg_stat_statements
   where query like 'WITH pgrst_source%'
     and query like '%"service_line_items"."service_kind"%';
  if n > 0 then
    raise exception 'REFUSING: % app query(ies) now select service_line_items.service_kind. Re-survey before removing it.', n;
  end if;
end $$;

-- 1. ops.client_service_options — drop the duplicate JSON key (column list unchanged,
--    so CREATE OR REPLACE is enough here).
create or replace view ops.client_service_options as
SELECT c.id AS client_id,
    c.client_code,
    c.name AS client_name,
    j.id AS job_id,
    j.job_number,
        CASE
            WHEN (j.title ~~* 'Service Agreement%'::text) THEN 'SA'::text
            ELSE 'SC'::text
        END AS job_kind,
    j.title AS job_title,
    j.frequency_days,
    j.property_id,
    COALESCE(svc.services, '[]'::json) AS services,
    svc.primary_group AS job_service_group
   FROM ((jobs j
     JOIN clients c ON ((c.id = j.client_id)))
     LEFT JOIN LATERAL ( SELECT json_agg(json_build_object('service_line_item_id', sli.id, 'code', sli.code, 'title', sli.title, 'requires_derm', sli.requires_derm, 'service_type', sli.service_type, 'service_group', ops.fn_service_group(sli.reason, sli.service_type, sli.location_target), 'unit_price', li.unit_price) ORDER BY sli.code) AS services,
            (array_agg(ops.fn_service_group(sli.reason, sli.service_type, sli.location_target) ORDER BY sli.code))[1] AS primary_group
           FROM (line_items li
             JOIN service_line_items sli ON ((sli.code = lpad("substring"(btrim(li.name), '^([0-9]+)'::text), 2, '0'::text))))
          WHERE ((li.job_id = j.id) AND (li.visit_id IS NULL) AND (li.quantity > (0)::numeric) AND (sli.schedulable = true))) svc ON (true))
  WHERE ((j.job_status <> 'archived'::text) AND ((j.title IS NULL) OR (j.title !~~* '%[OLD]%'::text)));

-- 2/3. The two passthrough catalogue views. Postgres cannot DROP a column via
--      CREATE OR REPLACE VIEW, so these are DROP + CREATE. Nothing depends on
--      either (verified), but DROP DISCARDS GRANTS, so they are re-granted below
--      — including ops.service_line_items's yannick_readonly grant, which is easy
--      to lose silently.
drop view client.service_line_items;
create view client.service_line_items as
SELECT id,
    code,
    title,
    requires_derm,
    reason,
    location_target,
    method,
    service_type,
    schedulable,
    active,
    created_at,
    updated_at,
    unit_price,
    default_vehicle_id
   FROM service_line_items;
grant select on client.service_line_items to authenticated, service_role;

drop view ops.service_line_items;
create view ops.service_line_items as
SELECT id,
    code,
    title,
    requires_derm,
    reason,
    location_target,
    method,
    service_type,
    schedulable,
    active,
    created_at,
    updated_at,
    unit_price
   FROM service_line_items;
grant select on ops.service_line_items to authenticated, service_role, yannick_readonly;

-- ---------------------------------------------------------------------
-- ASSERTIONS
-- ---------------------------------------------------------------------
do $$
declare n int; v_keys text; v_grp text;
begin
  -- the duplicate is gone from both passthrough views
  select count(*) into n from information_schema.columns
   where (table_schema,table_name) in (('client','service_line_items'),('ops','service_line_items'))
     and column_name = 'service_kind';
  if n > 0 then
    raise exception 'service_kind still present on % passthrough view column(s)', n;
  end if;

  -- and gone from the job-editor JSON payload
  select string_agg(distinct k, ',') into v_keys
    from ops.client_service_options,
         lateral json_array_elements(services) s,
         lateral json_object_keys(s) k;
  if v_keys like '%service_kind%' then
    raise exception 'services[] still carries a service_kind key: %', v_keys;
  end if;
  if v_keys not like '%service_type%' then
    raise exception 'services[] LOST service_type — the wrong key was removed: %', v_keys;
  end if;

  -- 🛑 THE ONE THAT MUST SURVIVE: v_calendar_visit.service_kind is SA/SC and is
  -- read by 4,186+ live app calls. It is a different concept entirely.
  select count(*) into n from ops.v_calendar_visit where service_kind in ('SA','SC');
  if n = 0 then
    raise exception 'ops.v_calendar_visit.service_kind (SA/SC) is empty — the wrong service_kind was removed';
  end if;

  -- the views must still return data, and the columns apps DO read must survive
  select count(*) into n from ops.service_line_items
   where code is not null and title is not null and schedulable is not null;
  if n = 0 then raise exception 'ops.service_line_items is blank'; end if;
  select count(*) into n from client.service_line_items where code is not null;
  if n = 0 then raise exception 'client.service_line_items is blank'; end if;
  select count(*) into n from ops.client_service_options where json_array_length(services) > 0;
  if n = 0 then raise exception 'client_service_options.services is blank'; end if;

  -- chips still work (service_group is built from the same rows)
  select ops.fn_service_group('Service Agreement','Pumping','Grease Trap & Tank Cleaning') into v_grp;
  if v_grp is distinct from 'PUMPING_GT' then
    raise exception 'fn_service_group broke (got %)', v_grp;
  end if;

  -- ⚠ GRANTS: DROP+CREATE discards them. Verify each role can still read, or the
  -- apps get 42501 and the failure looks like an app bug, not a migration one.
  if not has_table_privilege('authenticated','ops.service_line_items','SELECT') then
    raise exception 'GRANT LOST: authenticated cannot read ops.service_line_items';
  end if;
  if not has_table_privilege('service_role','ops.service_line_items','SELECT') then
    raise exception 'GRANT LOST: service_role cannot read ops.service_line_items';
  end if;
  if not has_table_privilege('yannick_readonly','ops.service_line_items','SELECT') then
    raise exception 'GRANT LOST: yannick_readonly cannot read ops.service_line_items';
  end if;
  if not has_table_privilege('authenticated','client.service_line_items','SELECT') then
    raise exception 'GRANT LOST: authenticated cannot read client.service_line_items';
  end if;
  if not has_table_privilege('service_role','client.service_line_items','SELECT') then
    raise exception 'GRANT LOST: service_role cannot read client.service_line_items';
  end if;

  raise notice 'COLLAPSE OK - duplicate key and columns removed, SA/SC intact, grants preserved';
end $$;

commit;
