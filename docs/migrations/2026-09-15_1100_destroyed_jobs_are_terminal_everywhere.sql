-- ============================================================================================
-- 2026-09-15_1100_destroyed_jobs_are_terminal_everywhere.sql
--
-- A job Jobber has DELETED reaches us as job_status = 'destroyed' (JOB_DESTROY, webhook-jobber) and
-- only reads 'archived' once the */5 poll re-reads it, about 20 minutes later (08-21's job 1848).
-- ⚠ CORRECTION (same day, comment only, the SQL below is what ran): the converger is NOT the poll.
--   'archived' comes back when sync-jobber-job-drift's gone-arm (every 30 minutes, :15/:45) asks
--   Jobber for the job by id and gets nothing; the poll pulls by updatedAt and never re-pulled the
--   six. 08-21's "20 minutes" was the 01:45 drift run. The window is up to 30 minutes, longer when
--   a drift run fails (10:45 on 2026-09-15 went partial on three HTTP 401s).
-- Eleven objects treated ONLY 'archived' as terminal, so for that window a deleted job counted as
-- live: offerable for a visit, a live Service Agreement for status transitions and eligibility, a
-- generator input, a billing card, a Field Portal frequency. 2026-09-15_1045 closed the one surface
-- Fred saw (the Calendar picker, after three 112-YA properties were deleted and six jobs, four of
-- them long archived, came back as cards). Fred: "we need to fix that for all the times we delete a
-- property then, so it doesn't happens again when we do so." This file is the rest of the estate.
--
-- THE RULE IT ENCODES: 'destroyed' is terminal wherever 'archived' is. A destroyed job is a deleted
-- job, strictly more final than an archived one, and nothing in this estate needs to tell them apart
-- (public.visits_with_review, sync-jobber-job-drift, archive-client, unarchive-client and the shared
-- service-call-job helper already list archived, closed and destroyed together).
--
-- HOW: every `<> 'archived'` becomes `NOT IN ('archived', 'destroyed')`, left operand untouched, so
-- a NULL job_status is treated exactly as before in each object (coalesce'd where it was, excluded
-- where it was). client.recurring_eligibility is the one deliberate exception: its `is_closed`
-- stays `= 'archived'` (an archived job can be REOPENED through save-client-job, that is what the
-- closed_eligible list is for) and a destroyed job is excluded from its scope instead, because a
-- deleted job is neither open nor reopenable. 'closed' is NOT added anywhere: whether a closed
-- Jobber job may take a visit is a product question, and 0 closed jobs exist today.
--
-- Bodies are the LIVE pg_get_viewdef / pg_get_functiondef output (md5 pinned per object), patched
-- by scripts/probes/assemble_destroyed_terminal_migration.py with the number of sites asserted.
-- CREATE OR REPLACE keeps every column list and signature, so grants survive (asserted).
--
-- RULE 8: no table change. App-facing consumers: Visit Calendar (create_calendar_visit,
-- ops.client_jobs), Client App (preview_job_action, recurring_eligibility, update_client_status,
-- v_client_billing), Field Portal (customer.clients.service_frequency_days), the nightly SA
-- generator, the SA gaps report. App-side notes in each app's docs/08-changelog.md.
-- ============================================================================================
BEGIN;

CREATE TEMP TABLE _dj_pre (obj, acl) ON COMMIT DROP AS
  SELECT 'client.fn_client_live_sa_jobs'::text, (SELECT proacl::text FROM pg_proc WHERE oid = 'client.fn_client_live_sa_jobs(bigint)'::regprocedure)
  UNION ALL
  SELECT 'client.preview_job_action'::text, (SELECT proacl::text FROM pg_proc WHERE oid = 'client.preview_job_action(bigint,bigint,text)'::regprocedure)
  UNION ALL
  SELECT 'client.recurring_eligibility'::text, (SELECT proacl::text FROM pg_proc WHERE oid = 'client.recurring_eligibility(bigint)'::regprocedure)
  UNION ALL
  SELECT 'client.update_client_status'::text, (SELECT proacl::text FROM pg_proc WHERE oid = 'client.update_client_status(bigint,text,text)'::regprocedure)
  UNION ALL
  SELECT 'ops.create_visit_request'::text, (SELECT proacl::text FROM pg_proc WHERE oid = 'ops.create_visit_request(bigint,bigint,bigint[],bigint,bigint[],text,text,jsonb,jsonb,bigint,bigint[])'::regprocedure)
  UNION ALL
  SELECT 'public.create_calendar_visit'::text, (SELECT proacl::text FROM pg_proc WHERE oid = 'public.create_calendar_visit(bigint,bigint,bigint[],date,bigint,bigint[],timestamptz,timestamptz,text,text,bigint,bigint,jsonb,bigint[],jsonb)'::regprocedure)
  UNION ALL
  SELECT 'public.fn_generate_sa_visits'::text, (SELECT proacl::text FROM pg_proc WHERE oid = 'public.fn_generate_sa_visits(bigint,integer,boolean)'::regprocedure)
  UNION ALL
  SELECT 'client.v_client_billing'::text, (SELECT relacl::text FROM pg_class WHERE oid = 'client.v_client_billing'::regclass)
  UNION ALL
  SELECT 'customer.clients'::text, (SELECT relacl::text FROM pg_class WHERE oid = 'customer.clients'::regclass)
  UNION ALL
  SELECT 'ops.client_jobs'::text, (SELECT relacl::text FROM pg_class WHERE oid = 'ops.client_jobs'::regclass)
  UNION ALL
  SELECT 'public.v_sa_schedule_gaps'::text, (SELECT relacl::text FROM pg_class WHERE oid = 'public.v_sa_schedule_gaps'::regclass);

DO $pre$
BEGIN
  IF md5(pg_get_functiondef('client.fn_client_live_sa_jobs(bigint)'::regprocedure)) <> '897bcccc43ff4f64cea3b6bce2264713' THEN RAISE EXCEPTION 'PRE: client.fn_client_live_sa_jobs is not the body this file was patched from'; END IF;
  IF md5(pg_get_functiondef('client.preview_job_action(bigint,bigint,text)'::regprocedure)) <> '3236d0a0634c0bdc026acce12ad4a592' THEN RAISE EXCEPTION 'PRE: client.preview_job_action is not the body this file was patched from'; END IF;
  IF md5(pg_get_functiondef('client.recurring_eligibility(bigint)'::regprocedure)) <> '7df2ebcce198f0262c253d917d2ac0b3' THEN RAISE EXCEPTION 'PRE: client.recurring_eligibility is not the body this file was patched from'; END IF;
  IF md5(pg_get_functiondef('client.update_client_status(bigint,text,text)'::regprocedure)) <> '1f371e14b92f90b6f93d5b04959f9e02' THEN RAISE EXCEPTION 'PRE: client.update_client_status is not the body this file was patched from'; END IF;
  IF md5(pg_get_functiondef('ops.create_visit_request(bigint,bigint,bigint[],bigint,bigint[],text,text,jsonb,jsonb,bigint,bigint[])'::regprocedure)) <> '8486142ce90ede21b8dc9d17e078a4a2' THEN RAISE EXCEPTION 'PRE: ops.create_visit_request is not the body this file was patched from'; END IF;
  IF md5(pg_get_functiondef('public.create_calendar_visit(bigint,bigint,bigint[],date,bigint,bigint[],timestamptz,timestamptz,text,text,bigint,bigint,jsonb,bigint[],jsonb)'::regprocedure)) <> '02e321653a93a41b892838bf801e3434' THEN RAISE EXCEPTION 'PRE: public.create_calendar_visit is not the body this file was patched from'; END IF;
  IF md5(pg_get_functiondef('public.fn_generate_sa_visits(bigint,integer,boolean)'::regprocedure)) <> 'c81c82ce9e2d340b1b1f7c829c7eb0cd' THEN RAISE EXCEPTION 'PRE: public.fn_generate_sa_visits is not the body this file was patched from'; END IF;
  IF md5(pg_get_viewdef('client.v_client_billing'::regclass, false)) <> '3b33eb412df44965304e6fe4801c7a0f' THEN RAISE EXCEPTION 'PRE: client.v_client_billing is not the body this file was patched from'; END IF;
  IF md5(pg_get_viewdef('customer.clients'::regclass, false)) <> 'efdc554ef3cafe5803fc16adc6a2dfba' THEN RAISE EXCEPTION 'PRE: customer.clients is not the body this file was patched from'; END IF;
  IF md5(pg_get_viewdef('ops.client_jobs'::regclass, false)) <> '786c26ff7af3904c7ea1978894976224' THEN RAISE EXCEPTION 'PRE: ops.client_jobs is not the body this file was patched from'; END IF;
  IF md5(pg_get_viewdef('public.v_sa_schedule_gaps'::regclass, false)) <> '8146caffa0f19ced1bba1296b9b59b0c' THEN RAISE EXCEPTION 'PRE: public.v_sa_schedule_gaps is not the body this file was patched from'; END IF;
END
$pre$;

-- --------------------------------------------------------------------------------------------
-- PART 1. The eleven bodies, each spliced from its live definition.
-- --------------------------------------------------------------------------------------------
-- ---- function client.fn_client_live_sa_jobs (1 site) ----
CREATE OR REPLACE FUNCTION client.fn_client_live_sa_jobs(p_client_id bigint)
 RETURNS bigint[]
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select coalesce(array_agg(j.id order by j.id), '{}'::bigint[])
    from public.jobs j
   where j.client_id = p_client_id
     and coalesce(j.job_status, '') NOT IN ('archived', 'destroyed')
     and client.fn_is_current_sa_job(j.id);
$function$;

-- ---- function client.preview_job_action (3 sites) ----
CREATE OR REPLACE FUNCTION client.preview_job_action(p_client_id bigint, p_job_id bigint, p_action text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_status        text;
  v_job           jsonb;
  v_kind          text;
  v_jobs_to_close jsonb := '[]'::jsonb;
  v_upcoming      int   := 0;
  v_other_sa      int   := 0;
  v_from          text;
  v_to            text  := null;
  v_arch          bool  := false;
  v_unarch        bool  := false;
BEGIN
  SELECT status INTO v_status FROM public.clients WHERE id = p_client_id;
  v_from := v_status;

  -- classify the acted job (title-only). p_job_id NULL (the 'create' case) leaves v_job/v_kind NULL.
  SELECT jsonb_build_object(
           'job_number', j.job_number,
           'title', j.title,
           'kind', CASE WHEN j.title ILIKE 'Service Agreement%' THEN 'SA'
                        WHEN lower(btrim(j.title)) = 'service call' THEN 'SC'
                        ELSE 'legacy' END,
           'frequency_days', j.frequency_days,
           'job_status', j.job_status),
         (CASE WHEN j.title ILIKE 'Service Agreement%' THEN 'SA'
               WHEN lower(btrim(j.title)) = 'service call' THEN 'SC'
               ELSE 'legacy' END)
    INTO v_job, v_kind
    FROM public.jobs j
   WHERE j.id = p_job_id;

  IF p_action = 'create' THEN
    IF v_status = 'ACTIVE' THEN v_to := 'RECURRING'; END IF;

  ELSIF p_action = 'reopen' AND v_kind = 'SA' AND v_status = 'ACTIVE' THEN
    v_to := 'RECURRING';

  ELSIF p_action = 'reopen' AND v_kind = 'SC' AND v_status = 'INACTIVE' THEN
    v_to := 'ACTIVE';
    v_unarch := true;

  ELSIF p_action = 'close' AND v_kind = 'SA' THEN
    SELECT count(*) INTO v_other_sa
      FROM public.jobs
     WHERE client_id = p_client_id AND id <> p_job_id
       AND title ILIKE 'Service Agreement%' AND job_status NOT IN ('archived', 'destroyed');
    IF v_other_sa = 0 THEN v_to := 'ACTIVE'; END IF;
    v_jobs_to_close := (SELECT jsonb_agg(x) FROM (SELECT v_job AS x) t);
    SELECT count(*) INTO v_upcoming
      FROM client.v_visits_live
     WHERE job_id = p_job_id AND visit_status = 'scheduled'
       AND deleted_at IS NULL AND start_at >= now();

  ELSIF p_action = 'close' AND v_kind = 'SC' THEN
    v_to := 'INACTIVE';
    v_arch := true;
    SELECT jsonb_agg(jsonb_build_object(
             'job_number', j.job_number,
             'title', j.title,
             'kind', CASE WHEN j.title ILIKE 'Service Agreement%' THEN 'SA'
                          WHEN lower(btrim(j.title)) = 'service call' THEN 'SC'
                          ELSE 'legacy' END,
             'upcoming_visits', (SELECT count(*) FROM client.v_visits_live vv
                                   WHERE vv.job_id = j.id AND vv.visit_status = 'scheduled'
                                     AND vv.deleted_at IS NULL AND vv.start_at >= now())))
      INTO v_jobs_to_close
      FROM public.jobs j
     WHERE j.client_id = p_client_id AND j.job_status NOT IN ('archived', 'destroyed');
    SELECT count(*) INTO v_upcoming
      FROM client.v_visits_live vv
      JOIN public.jobs j ON j.id = vv.job_id
     WHERE j.client_id = p_client_id AND j.job_status NOT IN ('archived', 'destroyed')
       AND vv.visit_status = 'scheduled' AND vv.deleted_at IS NULL AND vv.start_at >= now();
  END IF;

  RETURN jsonb_build_object(
    'job', v_job,
    'action', p_action,
    'status_change', CASE WHEN v_to IS NULL THEN null
                          ELSE jsonb_build_object('from', v_from, 'to', v_to) END,
    'jobs_to_close', COALESCE(v_jobs_to_close, '[]'::jsonb),
    'upcoming_visits_removed', v_upcoming,
    'other_open_sa_count', v_other_sa,
    'will_archive_client', v_arch,
    'will_unarchive_client', v_unarch);
END
$function$;

-- ---- function client.recurring_eligibility (1 site) ----
CREATE OR REPLACE FUNCTION client.recurring_eligibility(p_client_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with scoped as (
    select j.id, j.job_number, j.title, j.job_status, j.frequency_days,
           j.property_id, j.start_at,
           client.fn_is_current_sa_job(j.id) as eligible,
           (j.job_status = 'archived')       as is_closed
    from public.jobs j
    where j.client_id = p_client_id
      and coalesce(j.job_status, '') <> 'destroyed'   -- 2026-09-15: a deleted job is neither open nor reopenable
  ),
  shaped as (
    select s.*,
      (select coalesce(json_agg(distinct client.fn_billing_group(li.name))
                filter (where client.fn_billing_group(li.name) is not null), '[]'::json)
         from public.line_items li
        where li.job_id = s.id and li.visit_id is null and li.invoice_id is null) as groups
    from scoped s
  )
  select jsonb_build_object(
    'client_id',      p_client_id,
    'client_code',    (select c.client_code from public.clients c where c.id = p_client_id),
    'current_status', (select c.status      from public.clients c where c.id = p_client_id),
    -- an eligible OPEN job means RECURRING can be set with no further action
    'open_eligible', coalesce((
       select jsonb_agg(jsonb_build_object(
                'job_id', id, 'job_number', job_number, 'title', title,
                'job_status', job_status, 'frequency_days', frequency_days,
                'property_id', property_id, 'groups', groups)
              order by frequency_days)
       from shaped where eligible and not is_closed), '[]'::jsonb),
    -- an eligible CLOSED job must be reopened via save-client-job FIRST
    'closed_eligible', coalesce((
       select jsonb_agg(jsonb_build_object(
                'job_id', id, 'job_number', job_number, 'title', title,
                'frequency_days', frequency_days, 'property_id', property_id,
                'groups', groups)
              order by frequency_days)
       from shaped where eligible and is_closed), '[]'::jsonb),
    -- shown as context only: these exist but are NOT offerable
    'legacy_closed_count', (select count(*) from shaped where is_closed and not eligible),
    'can_set_recurring_now', exists (select 1 from shaped where eligible and not is_closed),
    'next_generation_note',
      'SA visits are generated by the nightly run at 06:00 ET, not on save.'
  );
$function$;

-- ---- function client.update_client_status (1 site) ----
CREATE OR REPLACE FUNCTION client.update_client_status(p_client_id bigint, p_status text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_old    text;
  v_row    public.clients;
  v_before int;
  v_after  int;
  v_removed int;
  v_email  text;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  v_email := lower(coalesce(auth.jwt() ->> 'email',''));
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  -- PAUSED added 2026-07-31 (Fred). All four states are now settable.
  if p_status is null or p_status not in ('ACTIVE','RECURRING','INACTIVE','PAUSED') then
    raise exception 'status must be ACTIVE, RECURRING, INACTIVE or PAUSED (got %)', p_status
      using errcode = '22023';
  end if;
  -- The proof is the point: no reason, no change.
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'a reason is required when changing a client''s status'
      using errcode = '22023';
  end if;
  if length(btrim(p_reason)) > 500 then
    raise exception 'reason is too long (500 characters max)' using errcode = '22023';
  end if;

  select c.status into v_old from public.clients c where c.id = p_client_id;
  if v_old is null then
    raise exception 'client % not found', p_client_id using errcode = 'P0002';
  end if;
  if v_old = p_status then
    select c.* into v_row from public.clients c where c.id = p_client_id;
    return jsonb_build_object('client', to_jsonb(v_row), 'visits_removed', 0, 'noop', true);
  end if;

  -- ▼▼▼ ADDED 2026-08-01 — THE ONLY CHANGE ▼▼▼
  -- RECURRING requires a current-format SA job that can actually generate
  -- visits. Without one the client sits in RECURRING forever with an empty
  -- schedule and nothing reports it. Checked AFTER the no-op branch so that
  -- re-saving an already-RECURRING client can never be blocked by it.
  if p_status = 'RECURRING' then
    if not exists (
      select 1 from public.jobs j
      where j.client_id = p_client_id
        and j.job_status NOT IN ('archived', 'destroyed')
        and client.fn_is_current_sa_job(j.id)
    ) then
      raise exception
        'cannot set RECURRING: this client has no open Service Agreement job in the current format. Create one, or reopen a closed current-format agreement first.'
        using errcode = '23514';
    end if;
  end if;
  -- ▲▲▲ END OF ADDED BLOCK ▲▲▲

  select count(*) into v_before
    from public.visits v
   where v.client_id = p_client_id and v.deleted_at is null
     and v.visit_status = 'scheduled' and v.visit_date >= current_date;

  update public.clients c set status = p_status, status_source = 'manual'
   where c.id = p_client_id
  returning c.* into v_row;          -- AFTER trigger performs the SA cleanup

  select count(*) into v_after
    from public.visits v
   where v.client_id = p_client_id and v.deleted_at is null
     and v.visit_status = 'scheduled' and v.visit_date >= current_date;
  v_removed := greatest(v_before - v_after, 0);

  insert into public.client_status_changes
    (client_id, old_status, new_status, reason, changed_by, changed_by_email, visits_removed)
  values (p_client_id, v_old, p_status, btrim(p_reason), auth.uid(), v_email, v_removed);

  return jsonb_build_object(
    'client', to_jsonb(v_row),
    'previous_status', v_old,
    'visits_removed', v_removed,
    'note', case when p_status = 'RECURRING'
                 then 'SA visits are generated by the nightly run at 06:00 ET, not on save.'
                 else null end);
end;
$function$;

-- ---- function ops.create_visit_request (1 site) ----
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

  PERFORM 1 FROM jobs WHERE id = p_job_id AND client_id = p_client_id AND job_status NOT IN ('archived', 'destroyed');
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
END $function$;

-- ---- function public.create_calendar_visit (1 site) ----
CREATE OR REPLACE FUNCTION public.create_calendar_visit(p_client_id bigint, p_job_id bigint, p_service_line_item_ids bigint[], p_visit_date date, p_property_id bigint DEFAULT NULL::bigint, p_client_location_ids bigint[] DEFAULT NULL::bigint[], p_start_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_end_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_title text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_vehicle_id bigint DEFAULT NULL::bigint, p_driver_id bigint DEFAULT NULL::bigint, p_line_item_prices jsonb DEFAULT NULL::jsonb, p_team_ids bigint[] DEFAULT NULL::bigint[], p_line_item_descriptions jsonb DEFAULT NULL::jsonb)
 RETURNS visits
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_primary bigint; v_service_type text; v_derm boolean; v_property bigint; v_visit public.visits;
  v_team bigint[]; v_end_at timestamptz; v_clash jsonb; v_eff_vehicle bigint;
BEGIN
  IF p_client_id IS NULL OR p_job_id IS NULL OR p_visit_date IS NULL
     OR p_service_line_item_ids IS NULL OR array_length(p_service_line_item_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'create_calendar_visit: client_id, job_id, visit_date and >=1 service are required';
  END IF;
  PERFORM 1 FROM jobs WHERE id = p_job_id AND client_id = p_client_id AND job_status NOT IN ('archived', 'destroyed');
  IF NOT FOUND THEN
    RAISE EXCEPTION 'create_calendar_visit: job % is not an active job for client %', p_job_id, p_client_id;
  END IF;

  v_team := COALESCE(p_team_ids, CASE WHEN p_driver_id IS NOT NULL THEN ARRAY[p_driver_id] ELSE '{}'::bigint[] END);
  v_primary := COALESCE(p_team_ids[1], p_driver_id);
  SELECT service_type INTO v_service_type FROM service_line_items WHERE id = p_service_line_item_ids[1];
  SELECT bool_or(public.fn_line_item_requires_derm(title)) INTO v_derm FROM service_line_items WHERE id = ANY (p_service_line_item_ids);
  v_property := COALESCE(p_property_id, (SELECT property_id FROM jobs WHERE id = p_job_id),
    (SELECT id FROM properties WHERE client_id = p_client_id AND is_primary ORDER BY id LIMIT 1));

  -- A visit lasts one hour unless the caller says otherwise (Fred, 2026-09-06). The create form can
  -- send a start with no end, and a NULL end made the visit read as untimed downstream.
  v_end_at := COALESCE(p_end_at, CASE WHEN p_start_at IS NOT NULL THEN p_start_at + interval '1 hour' END);

  -- HARD REFUSE a second visit on the same TRUCK inside the hour. One truck cannot be in two places.
  -- The same-DRIVER case is deliberately NOT refused: a driver can ride as a second crew member, so
  -- it is advisory and surfaced by fn_check_visit_clash for the app to warn on. (Fred, 2026-09-06.)
  -- The EFFECTIVE truck is used, not p_vehicle_id: the Calendar shows a truck defaulted from the
  -- job's line items when none is assigned, and the live clash this guard exists for has a NULL
  -- vehicle_id on one side. Reading the stored column would return a confident zero on that case.
  v_eff_vehicle := public.fn_effective_vehicle_for_job(p_vehicle_id, p_job_id);
  IF p_start_at IS NOT NULL AND v_eff_vehicle IS NOT NULL THEN
    v_clash := public.fn_check_visit_clash(p_start_at, v_eff_vehicle, v_team, NULL);
    IF jsonb_array_length(v_clash -> 'truck') > 0
     AND public.fn_visit_clash_guard_enabled() THEN
      RAISE EXCEPTION USING
        ERRCODE = '22023',
        MESSAGE = format('visit_truck_clash: truck %s already has %s at %s',
          COALESCE((SELECT name FROM vehicles WHERE id = v_eff_vehicle), v_eff_vehicle::text),
          v_clash -> 'truck' -> 0 ->> 'client_code',
          v_clash -> 'truck' -> 0 ->> 'start_local'),
        HINT = 'Pick another time or another truck. A visit lasts one hour.';
    END IF;
  END IF;

  INSERT INTO visits (client_id, job_id, property_id, vehicle_id, assigned_driver_id, visit_date, start_at, end_at,
                      title, service_type, service_line_item_id, derm_required, notes, visit_status, source)
  VALUES (p_client_id, p_job_id, v_property, p_vehicle_id, v_primary, p_visit_date, p_start_at, v_end_at,
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
$function$;

-- ---- function public.fn_generate_sa_visits (4 sites) ----
CREATE OR REPLACE FUNCTION public.fn_generate_sa_visits(p_client_id bigint DEFAULT NULL::bigint, p_horizon_months integer DEFAULT 6, p_dry_run boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  c_today       date := (now() at time zone 'America/New_York')::date;
  c_horizon_end date := (date_trunc('month', (now() at time zone 'America/New_York')::date)
                         + make_interval(months => p_horizon_months + 1) - interval '1 day')::date;
  c_tolerance   int  := 7;
  c_max_per_job int  := 24;
  c_max_cleanup int  := 40;
  v_planned     jsonb := '[]'::jsonb;
  v_skipped     jsonb := '[]'::jsonb;
  v_inserted    int := 0;
  v_stale_ids   bigint[];
  v_cleaned     int := 0;
  v_cleanup_note text := null;
  v_scope_note  text := null;
  v_run_started timestamptz := clock_timestamp();
  v_n_jobs      int := 0;
begin
  drop table if exists _sa_jobs;
  drop table if exists _sa_candidates;

  create temp table _sa_jobs on commit drop as
  with jobs_in_scope as (
    select j.id           as job_id,
           j.job_number,
           j.title,
           j.frequency_days,
           j.start_at,
           c.id           as client_id,
           c.client_code,
           c.name         as client_name,
           bool_or(public.fn_line_item_requires_derm(li.name)) as derm_required,
           -- The CANONICAL taxonomy. As of 2026-08-03 service_kind and
           -- service_type hold the same values, so there is nothing to convert.
           (select sli.service_type
              from public.line_items l2
              join public.service_line_items sli
                on sli.code = lpad(substring(btrim(l2.name) from '^([0-9]+)'), 2, '0')
             where l2.job_id = j.id and l2.invoice_id is null and sli.service_type is not null
             order by case sli.service_type
                        when 'Pumping' then 1 when 'Cleaning' then 2
                        when 'Warranty of Drainage' then 3 else 4 end
             limit 1) as service_kind
      from public.jobs j
      join public.clients c on c.id = j.client_id
      left join public.line_items li on li.job_id = j.id and li.invoice_id is null
     where j.frequency_days > 0
       and j.title ilike 'Service Agreement%'
       and j.title not ilike '%[OLD]%'
       and coalesce(j.job_status,'') NOT IN ('archived', 'destroyed')
       -- 2026-09-08: this gate was RECURRING-only. Generation and CLEANUP disagreed about
       -- client scope: the cleanup branch below already accepts ACTIVE as well as RECURRING.
       -- That disagreement WAS the bug -- an ACTIVE client holding a real Service Agreement
       -- had its visits protected from cleanup but never generated, so its schedule silently
       -- ran dry (084-ULT, 117-BH, 201-ALA, Founders Shooting Club). The SA JOB is the
       -- authority on recurrence, not clients.status, which CLAUDE.md says is not authoritative.
       and c.status in ('ACTIVE','RECURRING')
       and c.client_code is not null
       -- Was a hardcoded list; now one source of truth. See public.non_customer_clients.
       and not public.fn_is_non_customer(c.id)
       and exists (
         select 1 from public.line_items lp
          join public.service_line_items slip
            on slip.code = lpad(substring(btrim(lp.name) from '^([0-9]+)'), 2, '0')
          where lp.job_id = j.id and lp.invoice_id is null
            and slip.reason in ('Service Agreement','Service Call') and slip.code <> '08')
       and (p_client_id is null or c.id = p_client_id)
     group by j.id, j.job_number, j.title, j.frequency_days, j.start_at,
              c.id, c.client_code, c.name
  ),
  typed as (
    -- 2026-08-03: the legacy down-conversion (Pumping to GT etc., with an
    -- else-GT fallback that could mislabel) is GONE. The kind IS the type.
    select s.*, s.service_kind as service_type
      from jobs_in_scope s
  )
  select t.*,
         st.max_future,
         st.n_visits,
         lc.last_completed,
         case
           when st.max_future    is not null then st.max_future    + t.frequency_days
           when lc.last_completed is not null then lc.last_completed + t.frequency_days
           when t.start_at       is not null then (t.start_at at time zone 'America/New_York')::date
           else c_today + t.frequency_days
         end as anchor,
         case
           when st.max_future     is not null then 'job_scheduled+freq'
           when lc.last_completed is not null then 'client_completed+freq'
           when t.start_at        is not null then 'job_start_at'
           else 'today+freq'
         end as anchor_src
    from typed t
    left join lateral (
      select max(v.visit_date) filter (
               where v.visit_status = 'scheduled' and v.visit_date >= c_today) as max_future,
             count(*) as n_visits
        from public.visits v
       where v.job_id = t.job_id and v.deleted_at is null
    ) st on true
    left join lateral (
      -- same-service anchor (the 178-LG rule): a completed visit of ANOTHER
      -- service must not set this agreement's cadence. Both sides now speak
      -- the new vocabulary.
      select max(v.visit_date) as last_completed
        from public.visits v
       where v.client_id = t.client_id
         and v.visit_status = 'completed'
         and v.service_type = t.service_type
         and v.deleted_at is null
    ) lc on true;

  select count(*) into v_n_jobs from _sa_jobs;

  if p_client_id is not null and v_n_jobs = 0 then
    select case
             when c.id is null then 'That client does not exist.'
             when public.fn_is_non_customer(c.id)
               then 'This is a test/non-serviceable account and is permanently excluded from automatic visit generation.'
             when c.client_code is null
               then 'This client has no client code, so it is excluded from automatic visit generation.'
             when c.status not in ('ACTIVE','RECURRING')
               then format('Visits are not generated for %s clients. Set the client to Active or Recurring to schedule visits.', c.status)
             when not exists (
                    select 1 from public.jobs j
                     where j.client_id = c.id and j.job_status NOT IN ('archived', 'destroyed')
                       and j.title ilike 'Service Agreement%' and j.title not ilike '%[OLD]%')
               then 'This client has no open Service Agreement job, so there is nothing to generate from.'
             when not exists (
                    select 1 from public.jobs j
                     where j.client_id = c.id and j.job_status NOT IN ('archived', 'destroyed')
                       and j.title ilike 'Service Agreement%' and coalesce(j.frequency_days,0) > 0)
               then 'This client''s Service Agreement has no frequency set, so no cadence can be generated.'
             else 'This client''s only Service Agreement is billing-only (Warranty of Drainage), which never generates recurring visits.'
           end
      into v_scope_note
      from public.clients c where c.id = p_client_id;
    if v_scope_note is null then v_scope_note := 'That client does not exist.'; end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'job_id', job_id, 'job_number', job_number, 'title', title,
           'client_code', client_code,
           'reason', 'no start date and no visits yet — set a start date to begin scheduling')), '[]'::jsonb)
    into v_skipped
    from _sa_jobs
   where start_at is null and n_visits = 0;

  delete from _sa_jobs where start_at is null and n_visits = 0;

  create temp table _sa_candidates on commit drop as
  select j.*, d::date as visit_date
    from _sa_jobs j
    cross join lateral (
      select d, row_number() over (order by d) as rn
        from generate_series(j.anchor::timestamp,
                             c_horizon_end::timestamp,
                             make_interval(days => j.frequency_days)) as g(d)
       where d::date >= c_today
    ) s
   where s.rn <= c_max_per_job
     and not exists (
       select 1 from public.visits v
        where v.job_id = j.job_id
          and v.deleted_at is null
          and abs(v.visit_date - s.d::date) <= c_tolerance
     );

  select coalesce(jsonb_agg(jsonb_build_object(
           'job_id', job_id, 'job_number', job_number, 'client_code', client_code,
           'anchor', anchor, 'anchor_src', anchor_src, 'visit_date', visit_date,
           'service_kind', service_kind)
           order by client_code, job_number, visit_date), '[]'::jsonb)
    into v_planned
    from _sa_candidates;

  if not p_dry_run then
    insert into public.visits
      (client_id, job_id, visit_date, visit_status, source, title, service_type, derm_required, property_id)
    select c.client_id, c.job_id, c.visit_date, 'scheduled', 'supabase_cron',
           c.client_code || ' ' || c.client_name || ' - ' || c.title,
           c.service_type, c.derm_required,
           -- 2026-08-18: carry the job's property so generated visits stop being born with
           -- property_id NULL (677 future rows were; the city email then renders "Address
           -- not on file" in a regulator-facing subject). Scalar subquery on purpose: the
           -- temp tables above are untouched, so this is the smallest possible diff.
           (select j2.property_id from public.jobs j2 where j2.id = c.job_id)
      from _sa_candidates c;
    get diagnostics v_inserted = row_count;
  end if;

  -- CLEANUP — full sweep only, and deliberately still keyed on ACTIVE *or*
  -- RECURRING: it removes visits whose JOB stopped qualifying, never visits
  -- that merely belong to a client who left RECURRING. That transition is the
  -- trigger's job.
  if p_client_id is null then
    select array_agg(v.id) into v_stale_ids
      from public.visits v
     where v.source = 'supabase_cron'
       and v.deleted_at is null
       and v.visit_date >= c_today
       and not exists (
         select 1 from public.jobs j join public.clients c on c.id = j.client_id
          where j.id = v.job_id
            and j.frequency_days > 0
            and j.title ilike 'Service Agreement%'
            and j.title not ilike '%[OLD]%'
            and coalesce(j.job_status,'') NOT IN ('archived', 'destroyed')
            and c.status in ('ACTIVE','RECURRING')
            and c.client_code is not null
            -- Was a hardcoded list; now one source of truth. See public.non_customer_clients.
            and not public.fn_is_non_customer(c.id)
            and exists (
              select 1 from public.line_items lp
               join public.service_line_items slip
                 on slip.code = lpad(substring(btrim(lp.name) from '^([0-9]+)'), 2, '0')
               where lp.job_id = j.id and lp.invoice_id is null
                 and slip.reason in ('Service Agreement','Service Call') and slip.code <> '08'));

    v_cleaned := coalesce(array_length(v_stale_ids, 1), 0);
    if v_cleaned > c_max_cleanup then
      v_cleanup_note := format('ABORTED: %s stale > max %s — likely a bulk data issue, investigate',
                               v_cleaned, c_max_cleanup);
      v_cleaned := 0;
    elsif v_cleaned > 0 and not p_dry_run then
      update public.visits set deleted_at = now() where id = any(v_stale_ids);
    end if;
  end if;

  if not p_dry_run then
    insert into public.sync_log
      (sync_source, started_at, finished_at, rows_inserted, rows_updated,
       rows_errored, duration_seconds, status, details)
    values ('sa-visit-generation',
            v_run_started, clock_timestamp(),
            v_inserted, v_cleaned,
            case when v_cleanup_note is null then 0 else 1 end,
            round(extract(epoch from (clock_timestamp() - v_run_started))::numeric, 3),
            case when v_cleanup_note is null then 'success' else 'warning' end,
            jsonb_build_object(
              'scope',        coalesce(p_client_id::text, 'all'),
              'jobs',         v_n_jobs,
              'generated',    v_inserted,
              'skipped',      jsonb_array_length(v_skipped),
              'cleaned',      v_cleaned,
              'cleanup_note', v_cleanup_note,
              'scope_note',   v_scope_note,
              'horizon_end',  c_horizon_end));
  end if;

  return jsonb_build_object(
    'dry_run',      p_dry_run,
    'scope',        coalesce(p_client_id::text, 'all'),
    'today',        c_today,
    'horizon_end',  c_horizon_end,
    'jobs_considered', v_n_jobs,
    'generated',    case when p_dry_run then jsonb_array_length(v_planned) else v_inserted end,
    'planned',      v_planned,
    'skipped',      v_skipped,
    'scope_note',   v_scope_note,
    'cleaned',      v_cleaned,
    'cleanup_note', v_cleanup_note,
    'ms',           round(extract(epoch from (clock_timestamp() - v_run_started)) * 1000));
end;
$function$;

-- ---- view client.v_client_billing (1 site) ----
CREATE OR REPLACE VIEW client.v_client_billing AS
 WITH cal AS (
         SELECT (date_trunc('year'::text, (now() AT TIME ZONE 'America/New_York'::text)))::date AS y_start,
            (((date_trunc('year'::text, (now() AT TIME ZONE 'America/New_York'::text)) + '1 year'::interval) - '1 day'::interval))::date AS y_end,
            ((now() AT TIME ZONE 'America/New_York'::text))::date AS today
        ), inv AS (
         SELECT i.id,
            i.client_id,
            i.total,
            ((COALESCE(i.sent_at, i.created_at) AT TIME ZONE 'America/New_York'::text))::date AS inv_date
           FROM invoices i
          WHERE ((COALESCE(i.invoice_status, ''::text) <> 'draft'::text) AND (i.client_id IS NOT NULL))
        ), tot AS (
         SELECT inv.client_id,
            COALESCE(sum(inv.total) FILTER (WHERE (inv.inv_date >= cal.y_start)), (0)::numeric) AS ytd_total,
            count(*) FILTER (WHERE (inv.inv_date >= cal.y_start)) AS ytd_invoices,
            COALESCE(sum(inv.total), (0)::numeric) AS life_total,
            count(*) AS life_invoices,
            min(inv.inv_date) AS life_since
           FROM (inv
             CROSS JOIN cal)
          GROUP BY inv.client_id
        ), gl AS (
         SELECT inv.client_id,
            client.fn_billing_group(l.name) AS grp,
            inv.inv_date,
            (l.total_price * COALESCE((inv.total / NULLIF(li.li_sum, (0)::numeric)), (1)::numeric)) AS total_price
           FROM ((line_items l
             JOIN inv ON ((inv.id = l.invoice_id)))
             JOIN LATERAL ( SELECT sum(l2.total_price) AS li_sum
                   FROM line_items l2
                  WHERE (l2.invoice_id = inv.id)) li ON (true))
        ), grp AS (
         SELECT gl.client_id,
            COALESCE(sum(gl.total_price) FILTER (WHERE ((gl.grp = 'pumping'::text) AND (gl.inv_date >= cal.y_start))), (0)::numeric) AS ytd_pumping,
            COALESCE(sum(gl.total_price) FILTER (WHERE ((gl.grp = 'cleaning'::text) AND (gl.inv_date >= cal.y_start))), (0)::numeric) AS ytd_cleaning,
            COALESCE(sum(gl.total_price) FILTER (WHERE ((gl.grp = 'warranty'::text) AND (gl.inv_date >= cal.y_start))), (0)::numeric) AS ytd_warranty,
            COALESCE(sum(gl.total_price) FILTER (WHERE ((gl.grp = 'service_call'::text) AND (gl.inv_date >= cal.y_start))), (0)::numeric) AS ytd_service_call,
            COALESCE(sum(gl.total_price) FILTER (WHERE (gl.grp = 'pumping'::text)), (0)::numeric) AS life_pumping,
            COALESCE(sum(gl.total_price) FILTER (WHERE (gl.grp = 'cleaning'::text)), (0)::numeric) AS life_cleaning,
            COALESCE(sum(gl.total_price) FILTER (WHERE (gl.grp = 'warranty'::text)), (0)::numeric) AS life_warranty,
            COALESCE(sum(gl.total_price) FILTER (WHERE (gl.grp = 'service_call'::text)), (0)::numeric) AS life_service_call,
            COALESCE(sum(gl.total_price) FILTER (WHERE (gl.grp IS NULL)), (0)::numeric) AS life_uncoded_total
           FROM (gl
             CROSS JOIN cal)
          GROUP BY gl.client_id
        ), fut AS (
         SELECT v.client_id,
            count(*) AS proj_visits,
            COALESCE(sum(jv.pumping), (0)::numeric) AS proj_v_pumping,
            COALESCE(sum(jv.cleaning), (0)::numeric) AS proj_v_cleaning,
            COALESCE(sum(jv.service_call), (0)::numeric) AS proj_v_service_call,
            COALESCE(sum(jv.all_lines), (0)::numeric) AS proj_v_total
           FROM ((visits v
             CROSS JOIN cal)
             JOIN LATERAL ( SELECT COALESCE(sum(l.total_price) FILTER (WHERE (client.fn_billing_group(l.name) = 'pumping'::text)), (0)::numeric) AS pumping,
                    COALESCE(sum(l.total_price) FILTER (WHERE (client.fn_billing_group(l.name) = 'cleaning'::text)), (0)::numeric) AS cleaning,
                    COALESCE(sum(l.total_price) FILTER (WHERE (client.fn_billing_group(l.name) = 'service_call'::text)), (0)::numeric) AS service_call,
                    COALESCE(sum(l.total_price), (0)::numeric) AS all_lines
                   FROM line_items l
                  WHERE ((l.job_id = v.job_id) AND (l.invoice_id IS NULL) AND (l.visit_id IS NULL))) jv ON (true))
          WHERE ((v.deleted_at IS NULL) AND (lower(COALESCE(v.visit_status, ''::text)) = 'scheduled'::text) AND (v.visit_date > cal.today) AND (v.visit_date <= cal.y_end))
          GROUP BY v.client_id
        ), wd_jobs AS (
         SELECT j.client_id,
            j.id AS job_id,
            j.invoice_frequency,
            j.invoice_rrule,
            ((j.start_at AT TIME ZONE 'America/New_York'::text))::date AS anchor,
            ( SELECT COALESCE(sum(l.total_price), (0)::numeric) AS "coalesce"
                   FROM line_items l
                  WHERE ((l.job_id = j.id) AND (l.invoice_id IS NULL) AND (l.visit_id IS NULL) AND (client.fn_billing_group(l.name) = 'warranty'::text))) AS charge,
            ( SELECT COALESCE(sum(l.total_price), (0)::numeric) AS "coalesce"
                   FROM line_items l
                  WHERE ((l.job_id = j.id) AND (l.invoice_id IS NULL) AND (l.visit_id IS NULL))) AS charge_all
           FROM jobs j
          WHERE ((lower(COALESCE(j.job_status, ''::text)) NOT IN ('archived'::text, 'destroyed'::text)) AND (EXISTS ( SELECT 1
                   FROM line_items l
                  WHERE ((l.job_id = j.id) AND (l.invoice_id IS NULL) AND (l.visit_id IS NULL) AND (client.fn_billing_group(l.name) = 'warranty'::text)))) AND (NOT (EXISTS ( SELECT 1
                   FROM line_items l
                  WHERE ((l.job_id = j.id) AND (l.invoice_id IS NULL) AND (l.visit_id IS NULL) AND (client.fn_billing_group(l.name) = ANY (ARRAY['pumping'::text, 'cleaning'::text, 'service_call'::text])))))))
        ), wd_cadence AS (
         SELECT g_1.client_id,
            percentile_cont((0.5)::double precision) WITHIN GROUP (ORDER BY ((g_1.gap)::double precision)) AS days
           FROM ( SELECT inv.client_id,
                    (inv.inv_date - lag(inv.inv_date) OVER (PARTITION BY inv.client_id ORDER BY inv.inv_date)) AS gap
                   FROM inv
                  WHERE (EXISTS ( SELECT 1
                           FROM line_items l
                          WHERE ((l.invoice_id = inv.id) AND (client.fn_billing_group(l.name) = 'warranty'::text))))) g_1
          WHERE ((g_1.gap IS NOT NULL) AND (g_1.gap > 0))
          GROUP BY g_1.client_id
        ), wd AS (
         SELECT w_1.client_id,
            (COALESCE(sum((w_1.charge * (n.n_occ)::numeric)), (0)::numeric))::double precision AS proj_recurring,
            (COALESCE(sum((w_1.charge_all * (n.n_occ)::numeric)), (0)::numeric))::double precision AS proj_recurring_all,
            bool_or((n.n_occ IS NULL)) AS any_unknown
           FROM (((wd_jobs w_1
             CROSS JOIN cal)
             LEFT JOIN wd_cadence c ON ((c.client_id = w_1.client_id)))
             JOIN LATERAL ( SELECT COALESCE(
                        CASE
                            WHEN (w_1.invoice_frequency IS NOT NULL) THEN client.fn_rrule_occurrences(w_1.invoice_rrule, w_1.anchor, cal.today, cal.y_end)
                            ELSE NULL::integer
                        END, (floor((((cal.y_end - cal.today))::numeric / (NULLIF(c.days, (0)::double precision))::numeric)))::integer) AS n_occ) n ON (true))
          GROUP BY w_1.client_id
        )
 SELECT cl.id AS client_id,
    COALESCE(t.ytd_total, (0)::numeric) AS ytd_total,
    COALESCE(t.ytd_invoices, (0)::bigint) AS ytd_invoices,
    COALESCE(t.life_total, (0)::numeric) AS life_total,
    COALESCE(t.life_invoices, (0)::bigint) AS life_invoices,
    t.life_since,
    COALESCE(g.ytd_pumping, (0)::numeric) AS ytd_pumping,
    COALESCE(g.ytd_cleaning, (0)::numeric) AS ytd_cleaning,
    COALESCE(g.ytd_warranty, (0)::numeric) AS ytd_warranty,
    COALESCE(g.ytd_service_call, (0)::numeric) AS ytd_service_call,
    COALESCE(g.life_pumping, (0)::numeric) AS life_pumping,
    COALESCE(g.life_cleaning, (0)::numeric) AS life_cleaning,
    COALESCE(g.life_warranty, (0)::numeric) AS life_warranty,
    COALESCE(g.life_service_call, (0)::numeric) AS life_service_call,
    COALESCE(g.life_uncoded_total, (0)::numeric) AS life_uncoded_total,
    (((COALESCE(t.ytd_total, (0)::numeric) + COALESCE(f.proj_v_total, (0)::numeric)))::double precision + COALESCE(w.proj_recurring_all, (0)::double precision)) AS projection_total,
    COALESCE(f.proj_visits, (0)::bigint) AS projection_visits,
    COALESCE(f.proj_v_total, (0)::numeric) AS projection_visit_value,
    COALESCE(w.proj_recurring, (0)::double precision) AS projection_recurring_value,
    COALESCE(w.any_unknown, false) AS projection_recurring_unknown,
    (COALESCE(g.ytd_pumping, (0)::numeric) + COALESCE(f.proj_v_pumping, (0)::numeric)) AS projection_pumping,
    (COALESCE(g.ytd_cleaning, (0)::numeric) + COALESCE(f.proj_v_cleaning, (0)::numeric)) AS projection_cleaning,
    ((COALESCE(g.ytd_warranty, (0)::numeric))::double precision + COALESCE(w.proj_recurring, (0)::double precision)) AS projection_warranty,
    (COALESCE(g.ytd_service_call, (0)::numeric) + COALESCE(f.proj_v_service_call, (0)::numeric)) AS projection_service_call
   FROM ((((clients cl
     LEFT JOIN tot t ON ((t.client_id = cl.id)))
     LEFT JOIN grp g ON ((g.client_id = cl.id)))
     LEFT JOIN fut f ON ((f.client_id = cl.id)))
     LEFT JOIN wd w ON ((w.client_id = cl.id)));

-- ---- view customer.clients (1 site) ----
CREATE OR REPLACE VIEW customer.clients AS
 SELECT customer.uuid_from_bigint(c.id) AS id,
    lower(c.client_code) AS slug,
    c.name,
    c.client_code,
    cg.name AS group_name,
    p.address AS address1,
    NULLIF(TRIM(BOTH ' ,'::text FROM concat_ws(', '::text, NULLIF(p.city, ''::text), NULLIF(concat_ws(' '::text, NULLIF(p.state, ''::text), NULLIF(p.zip, ''::text)), ''::text))), ''::text) AS address2,
        CASE
            WHEN (COALESCE((p.grease_trap_size_gallons)::numeric, (( SELECT ps.grease_trap_size_gallons
               FROM properties ps
              WHERE ((ps.client_id = c.id) AND (ps.grease_trap_size_gallons IS NOT NULL))
              ORDER BY ps.is_primary DESC, ps.id
             LIMIT 1))::numeric, sc_gt.equipment_size_gallons) IS NOT NULL) THEN ((COALESCE((p.grease_trap_size_gallons)::numeric, (( SELECT ps.grease_trap_size_gallons
               FROM properties ps
              WHERE ((ps.client_id = c.id) AND (ps.grease_trap_size_gallons IS NOT NULL))
              ORDER BY ps.is_primary DESC, ps.id
             LIMIT 1))::numeric, sc_gt.equipment_size_gallons))::text || ' gal grease trap'::text)
            ELSE NULL::text
        END AS container_type,
        CASE
            WHEN (COALESCE((p.grease_trap_size_gallons)::numeric, (( SELECT ps.grease_trap_size_gallons
               FROM properties ps
              WHERE ((ps.client_id = c.id) AND (ps.grease_trap_size_gallons IS NOT NULL))
              ORDER BY ps.is_primary DESC, ps.id
             LIMIT 1))::numeric, sc_gt.equipment_size_gallons) IS NOT NULL) THEN ((COALESCE((p.grease_trap_size_gallons)::numeric, (( SELECT ps.grease_trap_size_gallons
               FROM properties ps
              WHERE ((ps.client_id = c.id) AND (ps.grease_trap_size_gallons IS NOT NULL))
              ORDER BY ps.is_primary DESC, ps.id
             LIMIT 1))::numeric, sc_gt.equipment_size_gallons))::text || ' gal'::text)
            ELSE NULL::text
        END AS trap_capacity,
    sc_gt.material_type AS material,
    df.name AS disposal_facility,
    ( SELECT g.permit_document_path
           FROM gdos g
          WHERE ((g.client_id = c.id) AND (g.status = 'ACTIVE'::text))
          ORDER BY g.id
         LIMIT 1) AS gdo_permit_url,
    p.access_notes,
    c.created_at,
    c.status,
    (c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text])) AS is_active,
    ( SELECT max(j.frequency_days) AS max
           FROM jobs j
          WHERE ((j.client_id = c.id) AND (j.title ~~* '%Service Agreement%'::text) AND (j.job_status NOT IN ('archived'::text, 'destroyed'::text)) AND (j.frequency_days > 0))) AS service_frequency_days
   FROM ((((clients c
     LEFT JOIN client_groups cg ON ((cg.id = c.group_id)))
     LEFT JOIN properties p ON (((p.client_id = c.id) AND (p.is_primary = true) AND (p.deleted_at IS NULL))))
     LEFT JOIN service_configs sc_gt ON (((sc_gt.client_id = c.id) AND (sc_gt.service_type = 'Pumping'::text))))
     LEFT JOIN disposal_facilities df ON ((df.id = p.default_disposal_facility_id)));

-- ---- view ops.client_jobs (1 site) ----
CREATE OR REPLACE VIEW ops.client_jobs AS
 SELECT id AS job_id,
    client_id,
    title,
    job_number,
    job_status,
        CASE
            WHEN (lower(btrim(title)) ~~ 'service agreement%'::text) THEN 'Service Agreement'::text
            WHEN (lower(btrim(title)) ~~ 'service call%'::text) THEN 'Service Call'::text
            WHEN (lower(btrim(title)) = 'credit card fee (3.53%)'::text) THEN 'Credit card fee (3.53%)'::text
            WHEN (lower(btrim(title)) = 'ach fee (1%)'::text) THEN 'ACH Fee (1%)'::text
            WHEN (lower(btrim(title)) = 'gdo online reporting'::text) THEN 'GDO Online Reporting'::text
            ELSE NULL::text
        END AS category
   FROM jobs j
  WHERE ((job_status NOT IN ('archived'::text, 'destroyed'::text)) AND ((lower(btrim(title)) ~~ 'service agreement%'::text) OR (lower(btrim(title)) ~~ 'service call%'::text) OR (lower(btrim(title)) = ANY (ARRAY['credit card fee (3.53%)'::text, 'ach fee (1%)'::text, 'gdo online reporting'::text]))));

-- ---- view public.v_sa_schedule_gaps (1 site) ----
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
    round((EXTRACT(epoch FROM (now() - j.created_at)) / 86400.0), 1) AS job_age_days,
    'frequency_unset'::text AS gap_reason
   FROM (jobs j
     JOIN clients c ON ((c.id = j.client_id)))
  WHERE (((j.frequency_days IS NULL) OR (j.frequency_days <= 0)) AND (j.title ~~* 'Service Agreement%'::text) AND (j.title !~~* '%[OLD]%'::text) AND (COALESCE(j.job_status, ''::text) NOT IN ('archived'::text, 'destroyed'::text)) AND (c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text])) AND (c.client_code IS NOT NULL) AND (NOT fn_is_non_customer(c.id)) AND (EXISTS ( SELECT 1
           FROM (line_items lp
             JOIN service_line_items slip ON ((slip.code = lpad("substring"(btrim(lp.name), '^([0-9]+)'::text), 2, '0'::text))))
          WHERE ((lp.job_id = j.id) AND (lp.invoice_id IS NULL) AND (slip.reason = ANY (ARRAY['Service Agreement'::text, 'Service Call'::text])) AND (slip.code <> '08'::text)))) AND (NOT (EXISTS ( SELECT 1
           FROM visits v
          WHERE ((v.job_id = j.id) AND (v.deleted_at IS NULL) AND (v.visit_date >= CURRENT_DATE))))) AND (j.created_at < (now() - '25:00:00'::interval)))
  ORDER BY j.created_at DESC;

-- --------------------------------------------------------------------------------------------
-- VERIFY
-- --------------------------------------------------------------------------------------------
DO $verify$
DECLARE v_body text; v_cid bigint; v_job bigint := 765; v_before jsonb; v_after jsonb; v_freq_before int; v_freq_after int; v_msg text;
BEGIN
  -- 1. structure: every object carries its destroyed sites and no bare `<> 'archived'` survives
  v_body := pg_get_functiondef('client.fn_client_live_sa_jobs(bigint)'::regprocedure);
  IF (length(v_body) - length(replace(v_body, '''destroyed''', ''))) / length('''destroyed''') <> 1 OR v_body LIKE '%<> ''archived''%' THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: client.fn_client_live_sa_jobs does not carry exactly 1 destroyed site(s), or a bare archived predicate survived';
  END IF;
  v_body := pg_get_functiondef('client.preview_job_action(bigint,bigint,text)'::regprocedure);
  IF (length(v_body) - length(replace(v_body, '''destroyed''', ''))) / length('''destroyed''') <> 3 OR v_body LIKE '%<> ''archived''%' THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: client.preview_job_action does not carry exactly 3 destroyed site(s), or a bare archived predicate survived';
  END IF;
  v_body := pg_get_functiondef('client.recurring_eligibility(bigint)'::regprocedure);
  IF (length(v_body) - length(replace(v_body, '''destroyed''', ''))) / length('''destroyed''') <> 1 OR v_body LIKE '%<> ''archived''%' THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: client.recurring_eligibility does not carry exactly 1 destroyed site(s), or a bare archived predicate survived';
  END IF;
  v_body := pg_get_functiondef('client.update_client_status(bigint,text,text)'::regprocedure);
  IF (length(v_body) - length(replace(v_body, '''destroyed''', ''))) / length('''destroyed''') <> 1 OR v_body LIKE '%<> ''archived''%' THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: client.update_client_status does not carry exactly 1 destroyed site(s), or a bare archived predicate survived';
  END IF;
  v_body := pg_get_functiondef('ops.create_visit_request(bigint,bigint,bigint[],bigint,bigint[],text,text,jsonb,jsonb,bigint,bigint[])'::regprocedure);
  IF (length(v_body) - length(replace(v_body, '''destroyed''', ''))) / length('''destroyed''') <> 1 OR v_body LIKE '%<> ''archived''%' THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: ops.create_visit_request does not carry exactly 1 destroyed site(s), or a bare archived predicate survived';
  END IF;
  v_body := pg_get_functiondef('public.create_calendar_visit(bigint,bigint,bigint[],date,bigint,bigint[],timestamptz,timestamptz,text,text,bigint,bigint,jsonb,bigint[],jsonb)'::regprocedure);
  IF (length(v_body) - length(replace(v_body, '''destroyed''', ''))) / length('''destroyed''') <> 1 OR v_body LIKE '%<> ''archived''%' THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: public.create_calendar_visit does not carry exactly 1 destroyed site(s), or a bare archived predicate survived';
  END IF;
  v_body := pg_get_functiondef('public.fn_generate_sa_visits(bigint,integer,boolean)'::regprocedure);
  IF (length(v_body) - length(replace(v_body, '''destroyed''', ''))) / length('''destroyed''') <> 4 OR v_body LIKE '%<> ''archived''%' THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: public.fn_generate_sa_visits does not carry exactly 4 destroyed site(s), or a bare archived predicate survived';
  END IF;
  v_body := pg_get_viewdef('client.v_client_billing'::regclass, false);
  IF (length(v_body) - length(replace(v_body, '''destroyed''', ''))) / length('''destroyed''') <> 1 OR v_body LIKE '%<> ''archived''%' THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: client.v_client_billing does not carry exactly 1 destroyed site(s), or a bare archived predicate survived';
  END IF;
  v_body := pg_get_viewdef('customer.clients'::regclass, false);
  IF (length(v_body) - length(replace(v_body, '''destroyed''', ''))) / length('''destroyed''') <> 1 OR v_body LIKE '%<> ''archived''%' THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: customer.clients does not carry exactly 1 destroyed site(s), or a bare archived predicate survived';
  END IF;
  v_body := pg_get_viewdef('ops.client_jobs'::regclass, false);
  IF (length(v_body) - length(replace(v_body, '''destroyed''', ''))) / length('''destroyed''') <> 1 OR v_body LIKE '%<> ''archived''%' THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: ops.client_jobs does not carry exactly 1 destroyed site(s), or a bare archived predicate survived';
  END IF;
  v_body := pg_get_viewdef('public.v_sa_schedule_gaps'::regclass, false);
  IF (length(v_body) - length(replace(v_body, '''destroyed''', ''))) / length('''destroyed''') <> 1 OR v_body LIKE '%<> ''archived''%' THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: public.v_sa_schedule_gaps does not carry exactly 1 destroyed site(s), or a bare archived predicate survived';
  END IF;
  -- 2. grants unchanged on all eleven (CREATE OR REPLACE must not have dropped and recreated)
  IF EXISTS (
    SELECT 1 FROM _dj_pre p
     WHERE p.acl IS DISTINCT FROM COALESCE(
       (SELECT relacl::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname || '.' || c.relname = p.obj AND c.relkind = 'v'),
       (SELECT proacl::text FROM pg_proc f JOIN pg_namespace n ON n.oid = f.pronamespace
         WHERE n.nspname || '.' || f.proname = p.obj
           AND f.oid = CASE p.obj
                 WHEN 'client.fn_client_live_sa_jobs' THEN 'client.fn_client_live_sa_jobs(bigint)'::regprocedure
                 WHEN 'client.preview_job_action' THEN 'client.preview_job_action(bigint,bigint,text)'::regprocedure
                 WHEN 'client.recurring_eligibility' THEN 'client.recurring_eligibility(bigint)'::regprocedure
                 WHEN 'client.update_client_status' THEN 'client.update_client_status(bigint,text,text)'::regprocedure
                 WHEN 'ops.create_visit_request' THEN 'ops.create_visit_request(bigint,bigint,bigint[],bigint,bigint[],text,text,jsonb,jsonb,bigint,bigint[])'::regprocedure
                 WHEN 'public.create_calendar_visit' THEN 'public.create_calendar_visit(bigint,bigint,bigint[],date,bigint,bigint[],timestamptz,timestamptz,text,text,bigint,bigint,jsonb,bigint[],jsonb)'::regprocedure
                 WHEN 'public.fn_generate_sa_visits' THEN 'public.fn_generate_sa_visits(bigint,integer,boolean)'::regprocedure
               END))
  ) THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: an ACL moved';
  END IF;
  -- 3. behaviour, on the sanctioned test client 112-YA and its live Service Agreement (job 765),
  --    inside a block that is always rolled back. Controls FIRST: the job must be live everywhere
  --    before it is flipped, or a passing check would prove nothing.
  SELECT id INTO v_cid FROM public.clients WHERE client_code = '112-YA';
  IF v_cid IS NULL THEN RAISE EXCEPTION 'VERIFY 3 PRE FAILED: 112-YA is missing'; END IF;
  IF NOT (v_job = ANY (client.fn_client_live_sa_jobs(v_cid))) THEN RAISE EXCEPTION 'VERIFY 3 PRE FAILED: job % is not a live SA of 112-YA (control)', v_job; END IF;
  IF NOT EXISTS (SELECT 1 FROM ops.client_jobs WHERE job_id = v_job) THEN RAISE EXCEPTION 'VERIFY 3 PRE FAILED: job % not in ops.client_jobs (control)', v_job; END IF;
  v_before := client.recurring_eligibility(v_cid);
  IF NOT (v_before->'open_eligible' @> jsonb_build_array(jsonb_build_object('job_id', v_job))) THEN RAISE EXCEPTION 'VERIFY 3 PRE FAILED: job % not open_eligible (control)', v_job; END IF;
  SELECT service_frequency_days INTO v_freq_before FROM customer.clients WHERE client_code = '112-YA';
  IF v_freq_before IS NULL THEN RAISE EXCEPTION 'VERIFY 3 PRE FAILED: customer.clients shows no frequency for 112-YA (control)'; END IF;
  BEGIN
    UPDATE public.jobs SET job_status = 'destroyed' WHERE id = v_job;
    -- 3a. no longer a live SA
    IF v_job = ANY (client.fn_client_live_sa_jobs(v_cid)) THEN RAISE EXCEPTION 'VERIFY 3a FAILED: destroyed job % still a live SA', v_job; END IF;
    -- 3b. gone from the ops job list
    IF EXISTS (SELECT 1 FROM ops.client_jobs WHERE job_id = v_job) THEN RAISE EXCEPTION 'VERIFY 3b FAILED: destroyed job % still in ops.client_jobs', v_job; END IF;
    -- 3c. neither open nor reopenable for the Client App
    v_after := client.recurring_eligibility(v_cid);
    IF (v_after->'open_eligible') @> jsonb_build_array(jsonb_build_object('job_id', v_job))
       OR (v_after->'closed_eligible') @> jsonb_build_array(jsonb_build_object('job_id', v_job)) THEN
      RAISE EXCEPTION 'VERIFY 3c FAILED: destroyed job % still offered by recurring_eligibility: %', v_job, v_after;
    END IF;
    -- 3d. the Field Portal no longer derives a service frequency from it
    SELECT service_frequency_days INTO v_freq_after FROM customer.clients WHERE client_code = '112-YA';
    IF v_freq_after IS NOT NULL THEN RAISE EXCEPTION 'VERIFY 3d FAILED: customer.clients still derives frequency % from destroyed job %', v_freq_after, v_job; END IF;
    -- 3e. the Calendar's create RPC refuses it (the guard fires before anything is written)
    BEGIN
      PERFORM public.create_calendar_visit(v_cid, v_job, ARRAY[1]::bigint[], current_date);
      RAISE EXCEPTION 'VERIFY 3e FAILED: create_calendar_visit accepted destroyed job %', v_job;
    EXCEPTION WHEN OTHERS THEN
      v_msg := SQLERRM;
      IF v_msg NOT LIKE '%is not an active job%' THEN RAISE; END IF;
    END;
    -- 3f. the visit-request RPC refuses it the same way
    BEGIN
      PERFORM ops.create_visit_request(v_cid, v_job, ARRAY[1]::bigint[]);
      RAISE EXCEPTION 'VERIFY 3f FAILED: create_visit_request accepted destroyed job %', v_job;
    EXCEPTION WHEN OTHERS THEN
      v_msg := SQLERRM;
      IF v_msg NOT LIKE '%is not an active job%' THEN RAISE; END IF;
    END;
    RAISE EXCEPTION 'FIXTURE_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'FIXTURE_ROLLBACK' THEN RAISE; END IF;
  END;
  -- 4. the fixture rolled back: the job is live again everywhere
  IF NOT (v_job = ANY (client.fn_client_live_sa_jobs(v_cid))) OR NOT EXISTS (SELECT 1 FROM ops.client_jobs WHERE job_id = v_job) THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: the control fixture on job % did not roll back', v_job;
  END IF;
  RAISE NOTICE 'ALL VERIFY PASSED: eleven objects patched, ACLs unchanged, a destroyed job is terminal for live-SA, ops.client_jobs, recurring_eligibility, customer.clients, create_calendar_visit and create_visit_request; fixture rolled back.';
END
$verify$;

COMMIT;
