-- ============================================================================
-- 2026-07-30_1531 — Client App "New job": DB layer for the two-way Jobber saga
-- ============================================================================
-- ASK (Fred, 2026-07-30): job create/edit/delete from the Client App with 100%
-- two-way Jobber sync, a 30-minute drift check, and the UI waiting on Jobber
-- confirmation. Design doc (READ IT FIRST — the architecture decision lives there):
--   docs/jobber-calendar-job-migration/2026-07-30_client-app-job-two-way-sync-design.md
--
-- The write path is the SYNCHRONOUS VERIFIED saga (edge fn `save-client-job`:
-- push Jobber → re-read to verify → only then write DB). Deliberately NO
-- jobs.sync_state, NO flags table, NO stale-pending cron: jobs are written from
-- exactly one surface, so a DB jobs row is only ever written post-verification —
-- born confirmed. This migration is everything the saga needs from the DB.
--
-- ---------------------------------------------------------------------------
-- AUDIT (ADR 010): public.jobs OPTS IN — a NEW decision, not inherited.
-- ---------------------------------------------------------------------------
-- Measured: public.jobs carries ZERO audit triggers (only trg_jobs_updated_at).
-- It is about to take its first human write path (1,784 rows, all machine-written
-- until today), so per ADR 010 human-editable ⇒ opt-in. `public.line_items` stays
-- OPTED OUT, documented here: the inbound sync (handleJob + the reconciler) wipes
-- and reinserts job-scoped line items wholesale on every touch, so row-level audit
-- there would be pure volume noise; the business change is captured at job level.
--
-- ---------------------------------------------------------------------------
-- ⚠ THE suppress-DOES-NOT-DEQUEUE LESSON, APPLIED (fn_close_job_visits)
-- ---------------------------------------------------------------------------
-- Closing a job destroys its incomplete visits Jobber-side (jobClose DESTROY_ALL).
-- Our matching soft-delete must NOT re-push visitDelete for each row, so it sets
-- app.suppress_jobber_push — but the GUC only short-circuits the synchronous
-- trigger; trg_mark_visit_sync_pending would still set sync_state='pending' and
-- the */3 cron would drain it 3 minutes later (measured 2026-07-29: five
-- suppressed visits reached Jobber anyway). So the soft-delete SETS
-- sync_state='confirmed' IN THE SAME STATEMENT. Both halves, always.
--
-- ---------------------------------------------------------------------------
-- ROLLBACK
-- ---------------------------------------------------------------------------
--   drop trigger if exists audit_jobs on public.jobs;
--   drop function if exists public.fn_close_job_visits(bigint);
--   -- restore fn_request_jobber_sync from scratch/git (remove the 'jobs-drift' arm)
--   select cron.unschedule('jobber-job-drift-reconcile');
--   -- client.properties: re-create without jobber_linked (append-only change)
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Audit opt-in
-- ---------------------------------------------------------------------------
drop trigger if exists audit_jobs on public.jobs;
create trigger audit_jobs
  after insert or update or delete on public.jobs
  for each row execute function audit.log_change();

-- ---------------------------------------------------------------------------
-- 2. client.properties gains jobber_linked (APPENDED last — legal for
--    CREATE OR REPLACE; a mid-list insert is not, see 2026-07-30_0539's lesson)
-- ---------------------------------------------------------------------------
-- The New-job property picker needs it: jobCreate takes propertyId (the client is
-- implied), so a property with no Jobber GID (12 of 817 today, including any
-- born from the app's own Add Property) cannot host a Jobber job.
create or replace view client.properties as
  select p.id,
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
         p.latitude,
         p.longitude,
         p.geofence_radius_meters,
         p.geofence_type,
         p.access_hours_start,
         p.access_hours_end,
         p.access_days,
         p.is_primary,
         p.notes,
         p.county,
         p.grease_trap_manhole_count,
         p.access_notes,
         p.default_disposal_facility_id,
         p.zone_id,
         p.sample_port_count,
         (select z.code from public.zones z where z.id = p.zone_id) as zone,
         (select count(*) from public.jobs j where j.property_id = p.id)::integer as job_count,
         exists (select 1 from public.entity_source_links l
                 where l.entity_type = 'property'
                   and l.source_system = 'jobber'
                   and l.entity_id = p.id) as jobber_linked
  from public.properties p;

-- ---------------------------------------------------------------------------
-- 3. fn_close_job_visits — the DB half of the close saga
-- ---------------------------------------------------------------------------
create or replace function public.fn_close_job_visits(p_job_id bigint)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_count integer;
begin
  -- SET LOCAL semantics (3rd arg true): a session-level SET would leak across
  -- PostgREST pooled connections and silently kill ALL outbound visit pushes.
  perform set_config('app.suppress_jobber_push', 'on', true);

  -- Only still-scheduled, live visits. NEVER completed ones (standing rule), and
  -- skipped/cancelled are already settled states.
  update public.visits v
     set deleted_at = now(),
         sync_state = 'confirmed'   -- close the queue in the same statement (§ header)
   where v.job_id = p_job_id
     and v.deleted_at is null
     and v.visit_status = 'scheduled';
  get diagnostics v_count = row_count;
  return v_count;
end
$fn$;

revoke all on function public.fn_close_job_visits(bigint) from public;
revoke all on function public.fn_close_job_visits(bigint) from anon;
revoke all on function public.fn_close_job_visits(bigint) from authenticated;
grant execute on function public.fn_close_job_visits(bigint) to service_role;

-- ---------------------------------------------------------------------------
-- 4. fn_request_jobber_sync: add the 'jobs-drift' target (verbatim body
--    otherwise — taken from the LIVE definition, not the migration file, per
--    the live-DB-is-ahead-of-docs trap)
-- ---------------------------------------------------------------------------
create or replace function public.fn_request_jobber_sync(p_target text)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
DECLARE
  v_url    text;
  v_bearer text;
  v_sync   text;
BEGIN
  -- Whitelist. p_target is never caller-supplied in practice (cron only), but the function is
  -- SECDEF, so it does not get to trust its input.
  v_url := CASE p_target
    WHEN 'poll'       THEN 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/sync-jobber-poll'
    WHEN 'upcoming'   THEN 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/sync-jobber-upcoming-visits'
    WHEN 'drift'      THEN 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/sync-jobber-visit-drift'
    WHEN 'jobs-drift' THEN 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/sync-jobber-job-drift'
    ELSE NULL
  END;

  IF v_url IS NULL THEN
    RAISE EXCEPTION 'fn_request_jobber_sync: unknown target %', p_target;
  END IF;

  SELECT decrypted_secret INTO v_bearer
    FROM vault.decrypted_secrets WHERE name = 'edge_invoke_service_key';

  IF v_bearer IS NULL THEN
    RAISE EXCEPTION
      'fn_request_jobber_sync: edge_invoke_service_key missing from vault; % NOT sent', p_target;
  END IF;

  -- May be NULL after the cleanup step. stripped below when it is.
  SELECT decrypted_secret INTO v_sync
    FROM vault.decrypted_secrets WHERE name = 'sync_trigger_key';

  PERFORM net.http_post(
    url     := v_url,
    headers := jsonb_strip_nulls(jsonb_build_object(
                 'Content-Type',  'application/json',
                 'Authorization', 'Bearer ' || v_bearer,
                 'x-sync-key',    v_sync)),
    body    := '{}'::jsonb);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 5. The 30-minute reconcile cron (Fred's explicit cadence). Offset by 15 min
--    from jobid 8 (the */30 visit drift) so the two Jobber sweeps do not share
--    a rate-limit bucket at the same instant.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from cron.job where jobname = 'jobber-job-drift-reconcile') then
    perform cron.schedule(
      'jobber-job-drift-reconcile',
      '15,45 * * * *',
      $cron$select public.fn_request_jobber_sync('jobs-drift')$cron$);
  end if;
end $$;

commit;
