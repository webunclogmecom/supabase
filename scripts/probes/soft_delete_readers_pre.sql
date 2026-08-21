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
