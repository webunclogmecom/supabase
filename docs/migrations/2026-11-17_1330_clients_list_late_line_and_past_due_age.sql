-- 2026-11-17_1330_clients_list_late_line_and_past_due_age.sql
-- Trello #212 and #213 (Yan's review of the Ops Portal, round A). Fred, 2026-11-17, on the page of picks:
-- "go with all recommended and all defaults" (E1: the Calendar's late line on the Clients list's Next visit; G1: a past due
-- shaded amber up to 60 days and red after, by the client's oldest past-due invoice). Plan and picks:
-- Building Apps/Ops Portal/docs/00-fred-picks-2026-11-17-colours.md.
--
-- What changes: columns APPENDED to four views, nothing else.
--   public.client_services_flat (+ its client wrapper): next_visit_id, next_visit_late_status. The next visit is picked by
--     the Clients list's own rule (scheduled, not deleted, from today in Eastern time, earliest by date then id; the list
--     shows the line only when this id equals the visit it shows), and the late answer is ops.v_calendar_visit.late_status,
--     the Calendar's own, never worked out again.
--   ops.v_client_past_due (+ its client wrapper): oldest_due_date, min(due_date) over the same rows (Jobber's past_due with
--     money owed). The Calendar and Home read this view by name of column, so a new last column changes nothing for them.
-- Every other column is byte for byte the live definition (copied from pg_get_viewdef by gen-migration.mjs, md5-guarded).
-- The old apps (calendar, clients) read the same views and see nothing change: new columns only.
-- Audit (rule 8): views, no data written. RLS: views owned by postgres, unchanged.
-- Grants: CREATE OR REPLACE keeps the ACL; VERIFY checks all four are unchanged and authenticated reads the new columns.
-- Dependents (pg_depend, 2026-11-17): only the two client wrappers, replaced here.
-- Lock: ACCESS EXCLUSIVE on four views read by the apps; lock_timeout 3s, and only cheap checks inside (the heavy ones
-- ran before, in a rolled-back rehearsal, and run after as a read-only check).
-- Rollback: 2026-11-17_1330_clients_list_late_line_and_past_due_age_rollback.sql.

begin;
set local lock_timeout = '3s';

create temp table _csf on commit drop as select id, md5(to_jsonb(t)::text) as h from public.client_services_flat t;
create temp table _pd on commit drop as select client_id, md5(to_jsonb(t)::text) as h from ops.v_client_past_due t;

do $guard$
begin
  if md5(pg_get_viewdef('public.client_services_flat'::regclass, true)) <> 'e2db4059b1cfc313d2420c0c9d1d300c' then
    raise exception 'public.client_services_flat changed since this migration was written; rebuild it from the live body';
  end if;
  if md5(pg_get_viewdef('client.client_services_flat'::regclass, true)) <> 'a55a1270fbb3fdc45383af5eb883a04a' then
    raise exception 'client.client_services_flat changed since this migration was written; rebuild it from the live body';
  end if;
  if md5(pg_get_viewdef('ops.v_client_past_due'::regclass, true)) <> 'e6fe6fc63bcb2f4bcd5b468eadea68ee' then
    raise exception 'ops.v_client_past_due changed since this migration was written; rebuild it from the live body';
  end if;
  if md5(pg_get_viewdef('client.v_client_past_due'::regclass, true)) <> '8783e47aa753a2b65f2c18794cd112df' then
    raise exception 'client.v_client_past_due changed since this migration was written; rebuild it from the live body';
  end if;
end $guard$;

CREATE OR REPLACE VIEW public.client_services_flat AS
SELECT c.id,
    c.name,
    c.client_code,
    p.address,
    p.city,
    p_z.code AS zone,
    c.status,
    max(
        CASE
            WHEN true THEN COALESCE(p.grease_trap_size_gallons::numeric, (( SELECT ps.grease_trap_size_gallons
               FROM properties ps
              WHERE ps.client_id = c.id AND ps.grease_trap_size_gallons IS NOT NULL
              ORDER BY ps.is_primary DESC, ps.id
             LIMIT 1))::numeric, s.equipment_size_gallons)
            ELSE NULL::numeric
        END) AS gt_size_gallons,
    max(
        CASE
            WHEN s.service_type = 'Pumping'::text THEN s.frequency_days
            ELSE NULL::integer
        END) AS gt_frequency_days,
    max(
        CASE
            WHEN s.service_type = 'Pumping'::text THEN s.price_per_visit
            ELSE NULL::numeric
        END) AS gt_price_per_visit,
    max(
        CASE
            WHEN s.service_type = 'Pumping'::text THEN s.last_visit
            ELSE NULL::date
        END) AS gt_last_visit,
    max(
        CASE
            WHEN s.service_type = 'Pumping'::text THEN (s.last_visit + ((s.frequency_days || ' days'::text)::interval))::date
            ELSE NULL::date
        END) AS gt_next_visit,
    max(
        CASE
            WHEN s.service_type = 'Pumping'::text THEN
            CASE
                WHEN s.last_visit IS NULL OR s.frequency_days IS NULL THEN 'UNKNOWN'::text
                WHEN (s.last_visit + ((s.frequency_days || ' days'::text)::interval))::date < CURRENT_DATE THEN 'OVERDUE'::text
                WHEN (s.last_visit + ((s.frequency_days || ' days'::text)::interval))::date <= (CURRENT_DATE + 14) THEN 'DUE_SOON'::text
                ELSE 'OK'::text
            END
            ELSE NULL::text
        END) AS gt_status,
    max(
        CASE
            WHEN s.service_type = 'Cleaning'::text THEN s.frequency_days
            ELSE NULL::integer
        END) AS cl_frequency_days,
    max(
        CASE
            WHEN s.service_type = 'Cleaning'::text THEN s.price_per_visit
            ELSE NULL::numeric
        END) AS cl_price_per_visit,
    max(
        CASE
            WHEN s.service_type = 'Cleaning'::text THEN s.last_visit
            ELSE NULL::date
        END) AS cl_last_visit,
    max(
        CASE
            WHEN s.service_type = 'Cleaning'::text THEN (s.last_visit + ((s.frequency_days || ' days'::text)::interval))::date
            ELSE NULL::date
        END) AS cl_next_visit,
    max(
        CASE
            WHEN s.service_type = 'Cleaning'::text THEN
            CASE
                WHEN s.last_visit IS NULL OR s.frequency_days IS NULL THEN 'UNKNOWN'::text
                WHEN (s.last_visit + ((s.frequency_days || ' days'::text)::interval))::date < CURRENT_DATE THEN 'OVERDUE'::text
                WHEN (s.last_visit + ((s.frequency_days || ' days'::text)::interval))::date <= (CURRENT_DATE + 14) THEN 'DUE_SOON'::text
                ELSE 'OK'::text
            END
            ELSE NULL::text
        END) AS cl_status,
    max(
        CASE
            WHEN s.service_type = 'Warranty of Drainage'::text THEN s.frequency_days
            ELSE NULL::integer
        END) AS wd_frequency_days,
    max(
        CASE
            WHEN s.service_type = 'Warranty of Drainage'::text THEN s.price_per_visit
            ELSE NULL::numeric
        END) AS wd_price_per_visit,
    max(
        CASE
            WHEN s.service_type = 'Warranty of Drainage'::text THEN s.last_visit
            ELSE NULL::date
        END) AS wd_last_visit,
    max(
        CASE
            WHEN s.service_type = 'Warranty of Drainage'::text THEN (s.last_visit + ((s.frequency_days || ' days'::text)::interval))::date
            ELSE NULL::date
        END) AS wd_next_visit,
    max(
        CASE
            WHEN s.service_type = 'Warranty of Drainage'::text THEN
            CASE
                WHEN s.last_visit IS NULL OR s.frequency_days IS NULL THEN 'UNKNOWN'::text
                WHEN (s.last_visit + ((s.frequency_days || ' days'::text)::interval))::date < CURRENT_DATE THEN 'OVERDUE'::text
                WHEN (s.last_visit + ((s.frequency_days || ' days'::text)::interval))::date <= (CURRENT_DATE + 14) THEN 'DUE_SOON'::text
                ELSE 'OK'::text
            END
            ELSE NULL::text
        END) AS wd_status,
    max(nve.nve) AS next_visit_expected,
    max(nv.id) AS next_visit_id,
    max(nv.late_status) AS next_visit_late_status
   FROM clients c
     LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
     LEFT JOIN v_client_agreement_services s ON s.client_id = c.id
     LEFT JOIN zones p_z ON p_z.id = p.zone_id
     LEFT JOIN ( SELECT v_calendar_visit.client_id,
            min(v_calendar_visit.expected_date) AS nve
           FROM ops.v_calendar_visit
          WHERE v_calendar_visit.visit_status = 'scheduled'::text AND v_calendar_visit.visit_date >= CURRENT_DATE AND v_calendar_visit.expected_date IS NOT NULL
          GROUP BY v_calendar_visit.client_id) nve ON nve.client_id = c.id
     LEFT JOIN ( SELECT DISTINCT ON (v.client_id) v.client_id,
            v.id,
            cv.late_status
           FROM v_visits_live v
             LEFT JOIN ops.v_calendar_visit cv ON cv.id = v.id
          WHERE v.visit_status = 'scheduled'::text AND v.visit_date >= (now() AT TIME ZONE 'America/New_York'::text)::date
          ORDER BY v.client_id, v.visit_date, v.id) nv ON nv.client_id = c.id
  GROUP BY c.id, p.address, p.city, p_z.code;

CREATE OR REPLACE VIEW client.client_services_flat AS
SELECT id,
    name,
    client_code,
    address,
    city,
    zone,
    status,
    gt_size_gallons,
    gt_frequency_days,
    gt_price_per_visit,
    gt_last_visit,
    gt_next_visit,
    gt_status,
    cl_frequency_days,
    cl_price_per_visit,
    cl_last_visit,
    cl_next_visit,
    cl_status,
    wd_frequency_days,
    wd_price_per_visit,
    wd_last_visit,
    wd_next_visit,
    wd_status,
    next_visit_expected,
    next_visit_id,
    next_visit_late_status
   FROM client_services_flat;

CREATE OR REPLACE VIEW ops.v_client_past_due AS
SELECT c.id AS client_id,
    c.client_code,
    count(*)::integer AS past_due_invoice_count,
    round(sum(i.outstanding_amount), 2) AS past_due_amount,
    ( SELECT max(split_part(convert_from(decode(esl.source_id, 'base64'::text), 'UTF8'::name), '/'::text, 5)) AS max
           FROM entity_source_links esl
          WHERE esl.entity_type = 'client'::text AND esl.source_system = 'jobber'::text AND esl.entity_id = c.id) AS jobber_client_id,
    min(i.due_date) AS oldest_due_date
   FROM clients c
     JOIN invoices i ON i.client_id = c.id
  WHERE i.invoice_status = 'past_due'::text AND i.outstanding_amount > 0::numeric
  GROUP BY c.id, c.client_code;

CREATE OR REPLACE VIEW client.v_client_past_due AS
SELECT client_id,
    client_code,
    past_due_invoice_count,
    past_due_amount,
    jobber_client_id,
    oldest_due_date
   FROM ops.v_client_past_due;

do $verify$
declare n int; d int; l int; o int;
begin
  select count(*) into n from public.client_services_flat;
  if n <> (select count(*) from _csf) then raise exception 'VERIFY: client_services_flat rows % -> %', (select count(*) from _csf), n; end if;
  select count(*) into d from _csf b join public.client_services_flat t on t.id = b.id
   where md5((to_jsonb(t) - 'next_visit_id' - 'next_visit_late_status')::text) <> b.h;
  if d <> 0 then raise exception 'VERIFY: % client_services_flat rows changed outside the new columns', d; end if;
  select count(*) into l from public.client_services_flat where next_visit_id is not null;
  if l < 100 then raise exception 'VERIFY: only % clients have a next visit', l; end if;
  select count(*) into n from ops.v_client_past_due;
  if n <> (select count(*) from _pd) then raise exception 'VERIFY: past due rows % -> %', (select count(*) from _pd), n; end if;
  select count(*) into d from _pd b join ops.v_client_past_due t on t.client_id = b.client_id
   where md5((to_jsonb(t) - 'oldest_due_date')::text) <> b.h;
  if d <> 0 then raise exception 'VERIFY: % past due rows changed outside oldest_due_date', d; end if;
  select count(*) into o from ops.v_client_past_due where oldest_due_date is null;
  if o <> 0 then raise exception 'VERIFY: % past-due clients have no oldest due date', o; end if;
  if (select relacl::text from pg_class where oid = 'public.client_services_flat'::regclass) <> '{postgres=arwdDxtm/postgres,authenticated=arwdDxtm/postgres,service_role=arwdDxtm/postgres,yannick_readonly=r/postgres,db_backup_reader=r/postgres}' then raise exception 'VERIFY: grants of public.client_services_flat changed'; end if;
  if (select relacl::text from pg_class where oid = 'client.client_services_flat'::regclass) <> '{postgres=arwdDxtm/postgres,authenticated=r/postgres,service_role=r/postgres,db_backup_reader=r/postgres}' then raise exception 'VERIFY: grants of client.client_services_flat changed'; end if;
  if (select relacl::text from pg_class where oid = 'ops.v_client_past_due'::regclass) <> '{postgres=arwdDxtm/postgres,authenticated=r/postgres,service_role=r/postgres,yannick_readonly=r/postgres,db_backup_reader=r/postgres}' then raise exception 'VERIFY: grants of ops.v_client_past_due changed'; end if;
  if (select relacl::text from pg_class where oid = 'client.v_client_past_due'::regclass) <> '{postgres=arwdDxtm/postgres,authenticated=r/postgres,service_role=r/postgres,db_backup_reader=r/postgres}' then raise exception 'VERIFY: grants of client.v_client_past_due changed'; end if;
  if not has_column_privilege('authenticated', 'client.client_services_flat', 'next_visit_late_status', 'SELECT')
     or not has_column_privilege('authenticated', 'client.v_client_past_due', 'oldest_due_date', 'SELECT')
     or has_table_privilege('anon', 'client.client_services_flat', 'SELECT')
     or has_table_privilege('anon', 'client.v_client_past_due', 'SELECT') then
    raise exception 'VERIFY: wrong read rights on the new columns';
  end if;
  perform set_config('verify.summary', format('clients %s with next visit %s, past due %s', (select count(*) from public.client_services_flat), l, n), true);
end $verify$;

commit;
