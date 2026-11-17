-- Rollback of 2026-11-17_1330_clients_list_late_line_and_past_due_age.sql: the four views without the new columns, as they were (bodies from pg_get_viewdef before the
-- migration), with the same grants. Run only before any app reads the new columns, or the Clients list shows a load error.
begin;
set local lock_timeout = '3s';
drop view client.client_services_flat;
drop view client.v_client_past_due;
drop view public.client_services_flat;
drop view ops.v_client_past_due;

CREATE VIEW public.client_services_flat AS
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
    max(nve.nve) AS next_visit_expected
   FROM clients c
     LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
     LEFT JOIN v_client_agreement_services s ON s.client_id = c.id
     LEFT JOIN zones p_z ON p_z.id = p.zone_id
     LEFT JOIN ( SELECT v_calendar_visit.client_id,
            min(v_calendar_visit.expected_date) AS nve
           FROM ops.v_calendar_visit
          WHERE v_calendar_visit.visit_status = 'scheduled'::text AND v_calendar_visit.visit_date >= CURRENT_DATE AND v_calendar_visit.expected_date IS NOT NULL
          GROUP BY v_calendar_visit.client_id) nve ON nve.client_id = c.id
  GROUP BY c.id, p.address, p.city, p_z.code;
revoke all on public.client_services_flat from public, anon, authenticated, service_role;
grant all on public.client_services_flat to authenticated;
grant all on public.client_services_flat to service_role;
grant select on public.client_services_flat to yannick_readonly;
grant select on public.client_services_flat to db_backup_reader;

CREATE VIEW ops.v_client_past_due AS
SELECT c.id AS client_id,
    c.client_code,
    count(*)::integer AS past_due_invoice_count,
    round(sum(i.outstanding_amount), 2) AS past_due_amount,
    ( SELECT max(split_part(convert_from(decode(esl.source_id, 'base64'::text), 'UTF8'::name), '/'::text, 5)) AS max
           FROM entity_source_links esl
          WHERE esl.entity_type = 'client'::text AND esl.source_system = 'jobber'::text AND esl.entity_id = c.id) AS jobber_client_id
   FROM clients c
     JOIN invoices i ON i.client_id = c.id
  WHERE i.invoice_status = 'past_due'::text AND i.outstanding_amount > 0::numeric
  GROUP BY c.id, c.client_code;
revoke all on ops.v_client_past_due from public, anon, authenticated, service_role;
grant select on ops.v_client_past_due to authenticated;
grant select on ops.v_client_past_due to service_role;
grant select on ops.v_client_past_due to yannick_readonly;
grant select on ops.v_client_past_due to db_backup_reader;

CREATE VIEW client.client_services_flat AS
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
    next_visit_expected
   FROM client_services_flat;
revoke all on client.client_services_flat from public, anon, authenticated, service_role;
grant select on client.client_services_flat to authenticated;
grant select on client.client_services_flat to service_role;
grant select on client.client_services_flat to db_backup_reader;

CREATE VIEW client.v_client_past_due AS
SELECT client_id,
    client_code,
    past_due_invoice_count,
    past_due_amount,
    jobber_client_id
   FROM ops.v_client_past_due;
revoke all on client.v_client_past_due from public, anon, authenticated, service_role;
grant select on client.v_client_past_due to authenticated;
grant select on client.v_client_past_due to service_role;
grant select on client.v_client_past_due to db_backup_reader;

do $verify$
begin
  if md5(pg_get_viewdef('public.client_services_flat'::regclass, true)) <> 'e2db4059b1cfc313d2420c0c9d1d300c' then raise exception 'ROLLBACK VERIFY: public.client_services_flat is not the old body'; end if;
  if md5(pg_get_viewdef('client.client_services_flat'::regclass, true)) <> 'a55a1270fbb3fdc45383af5eb883a04a' then raise exception 'ROLLBACK VERIFY: client.client_services_flat is not the old body'; end if;
  if md5(pg_get_viewdef('ops.v_client_past_due'::regclass, true)) <> 'e6fe6fc63bcb2f4bcd5b468eadea68ee' then raise exception 'ROLLBACK VERIFY: ops.v_client_past_due is not the old body'; end if;
  if md5(pg_get_viewdef('client.v_client_past_due'::regclass, true)) <> '8783e47aa753a2b65f2c18794cd112df' then raise exception 'ROLLBACK VERIFY: client.v_client_past_due is not the old body'; end if;
  if (select array_agg(x order by x) from unnest((select relacl from pg_class where oid = 'public.client_services_flat'::regclass)::text[]) x) <> (select array_agg(x order by x) from unnest('{postgres=arwdDxtm/postgres,authenticated=arwdDxtm/postgres,service_role=arwdDxtm/postgres,yannick_readonly=r/postgres,db_backup_reader=r/postgres}'::text[]) x) then raise exception 'ROLLBACK VERIFY: grants of public.client_services_flat differ'; end if;
  if (select array_agg(x order by x) from unnest((select relacl from pg_class where oid = 'client.client_services_flat'::regclass)::text[]) x) <> (select array_agg(x order by x) from unnest('{postgres=arwdDxtm/postgres,authenticated=r/postgres,service_role=r/postgres,db_backup_reader=r/postgres}'::text[]) x) then raise exception 'ROLLBACK VERIFY: grants of client.client_services_flat differ'; end if;
  if (select array_agg(x order by x) from unnest((select relacl from pg_class where oid = 'ops.v_client_past_due'::regclass)::text[]) x) <> (select array_agg(x order by x) from unnest('{postgres=arwdDxtm/postgres,authenticated=r/postgres,service_role=r/postgres,yannick_readonly=r/postgres,db_backup_reader=r/postgres}'::text[]) x) then raise exception 'ROLLBACK VERIFY: grants of ops.v_client_past_due differ'; end if;
  if (select array_agg(x order by x) from unnest((select relacl from pg_class where oid = 'client.v_client_past_due'::regclass)::text[]) x) <> (select array_agg(x order by x) from unnest('{postgres=arwdDxtm/postgres,authenticated=r/postgres,service_role=r/postgres,db_backup_reader=r/postgres}'::text[]) x) then raise exception 'ROLLBACK VERIFY: grants of client.v_client_past_due differ'; end if;
end $verify$;
commit;
