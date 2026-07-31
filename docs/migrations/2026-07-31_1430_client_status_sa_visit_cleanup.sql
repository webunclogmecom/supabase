-- ============================================================================
-- 2026-07-31_1430 — Client status editing + SA-scoped upcoming-visit cleanup
-- ============================================================================
-- ASK (Fred, 2026-07-31): "we need to have the functionality if we are changing
-- the status of a client, to recurrent, active, or inactive, on the `Edit client`
-- button. And with that ... if we change a client from recurrent, to active or
-- inactive, we need to delete the scheduled visits, not the completed ones, but
-- the ones that are upcoming on the SA job, only the SA job (we keep the ones
-- from SC job)." Fred also explicitly approved REPLACING the existing trigger.
--
-- ---------------------------------------------------------------------------
-- WHAT WAS THERE BEFORE, AND WHY IT HAD TO BE REPLACED (not extended)
-- ---------------------------------------------------------------------------
-- trg_clients_wipe_upcoming_on_inactive -> trg_wipe_upcoming_on_inactive():
--     IF NEW.status IN ('INACTIVE','PAUSED') AND OLD.status NOT IN (...) THEN
--       DELETE FROM public.visits
--       WHERE client_id = NEW.id AND visit_status='scheduled'
--         AND visit_date >= CURRENT_DATE;
-- Three problems, all of which contradict the new rule:
--   1. It HARD-DELETED. `visits` has the canonical `deleted_at` soft-delete
--      (CLAUDE.md rule 6) and hard rows are unrecoverable + break history joins.
--   2. It took EVERY scheduled future visit, Service Calls included. Fred wants
--      SC visits kept.
--   3. It never told Jobber, so Jobber kept orphan visits for anything already
--      pushed (252 of 687 upcoming visits carry a Jobber link today) -> drift.
--
-- ---------------------------------------------------------------------------
-- HOW JOBBER IS TOLD NOW — REUSING THE SANCTIONED PATH, NOT A NEW ONE
-- ---------------------------------------------------------------------------
-- Measured in fn_push_visit_to_jobber: it computes
--     v_op := CASE WHEN NEW.deleted_at IS NOT NULL OR
--                       NEW.visit_status IN ('cancelled','skipped')
--                  THEN 'delete' ELSE 'upsert' END
-- and trg_push_visit_update fires on `old.deleted_at IS DISTINCT FROM
-- new.deleted_at AND new.deleted_at IS NOT NULL`.
-- ⇒ SOFT-DELETING the visit IS the Jobber-delete trigger. So this function sets
-- deleted_at and the existing machinery queues visitDelete. Nothing new invented.
-- (SA visits carry source='supabase_cron', which is on the allow-list that
-- bypasses the delete path's browser-Origin requirement, so the push fires even
-- when the status change arrives from a server-side writer.)
--
-- ---------------------------------------------------------------------------
-- WHICH TRANSITIONS CLEAN UP
-- ---------------------------------------------------------------------------
--   (a) leaving RECURRING for ACTIVE / INACTIVE / PAUSED   <- Fred's new rule
--   (b) entering INACTIVE / PAUSED from anything else      <- preserves the old
--       safety net (a client archived in Jobber must stop getting trucks)
-- Everything else (ACTIVE->RECURRING, INACTIVE->ACTIVE, no-op writes) does
-- nothing. The visit generator's own predicate already excludes INACTIVE/PAUSED
-- clients, so case (b) is durable.
--
-- 🛑 KNOWN LIMIT OF CASE (a) — SURFACED, NOT SILENTLY PAPERED OVER.
-- generate_service_agreement_visits.js keys on `c.status IN ('ACTIVE','RECURRING')`,
-- so a client moved RECURRING -> ACTIVE still qualifies and the nightly cron will
-- REGENERATE the visits this cleanup removed. Making the generator require
-- RECURRING would fix that, but it would also stop generation for 13 LIVE
-- clients that sit on ACTIVE with a real SA job today (037-LB, 112-YA, 114-CI,
-- 140-TYO, 147-OST, 178-LG, 180-PV, 226-JER, 231-CHE, 232-AC, 233-AH, 241-WYN,
-- 242-WYN) — several are plainly real recurring customers whose status is merely
-- stale, the exact "clients.status is not authoritative" problem CLAUDE.md
-- documents. That is a business call for Fred, NOT a silent migration.
-- Until he rules: RECURRING->ACTIVE clears the schedule now, and it comes back
-- unless the SA job is also closed. The app's confirmation says so in words.
--
-- 3NF/Rule 1: no new columns. Audit (ADR 010): `visits` and `clients` both carry
-- audit triggers, so both halves of the change are captured; the soft-delete is
-- recoverable from audit.logs.old_row AND from deleted_at itself.
-- Grants: the RPCs follow the wave-1 shape (revoke PUBLIC/anon, grant
-- authenticated) — the born-EXECUTE-to-PUBLIC default-privileges trap.
--
-- ROLLBACK:
--   drop trigger trg_clients_cleanup_sa_visits_on_status on public.clients;
--   drop function public.fn_clients_cleanup_sa_visits_on_status();
--   drop function client.update_client_status(bigint, text);
--   drop function client.preview_client_status_change(bigint, text);
--   -- then re-create trg_wipe_upcoming_on_inactive + its trigger from git.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. the replacement trigger function
-- ---------------------------------------------------------------------------
create or replace function public.fn_clients_cleanup_sa_visits_on_status()
returns trigger
language plpgsql
as $$
declare
  v_leaving_recurring boolean;
  v_entering_stopped  boolean;
begin
  v_leaving_recurring := (old.status = 'RECURRING' and new.status <> 'RECURRING');
  v_entering_stopped  := (new.status in ('INACTIVE','PAUSED')
                          and old.status not in ('INACTIVE','PAUSED'));

  if not (v_leaving_recurring or v_entering_stopped) then
    return new;
  end if;

  -- SOFT-delete, SA jobs only, upcoming only, never a completed visit.
  -- Setting deleted_at is what makes fn_push_visit_to_jobber queue a Jobber
  -- visitDelete for the rows that were pushed there (see header).
  update public.visits v
     set deleted_at = now()
   where v.client_id = new.id
     and v.deleted_at is null
     and v.visit_status = 'scheduled'          -- never 'completed'
     and v.visit_date >= current_date          -- upcoming only
     and exists (
       select 1 from public.jobs j
        where j.id = v.job_id
          and j.title ilike 'Service Agreement%'   -- SA ONLY; Service Calls stay
     );

  return new;
end;
$$;

comment on function public.fn_clients_cleanup_sa_visits_on_status() is
  'On a client leaving RECURRING, or entering INACTIVE/PAUSED, SOFT-deletes that client''s UPCOMING SCHEDULED visits that belong to a Service Agreement job. Service Call visits and completed visits are deliberately kept (Fred 2026-07-31). The soft-delete is what triggers the Jobber visitDelete push via fn_push_visit_to_jobber. Replaced trg_wipe_upcoming_on_inactive, which hard-deleted ALL future visits and never told Jobber.';

drop trigger if exists trg_clients_wipe_upcoming_on_inactive on public.clients;
drop trigger if exists trg_clients_cleanup_sa_visits_on_status on public.clients;
create trigger trg_clients_cleanup_sa_visits_on_status
  after update of status on public.clients
  for each row
  when (new.status is distinct from old.status)
  execute function public.fn_clients_cleanup_sa_visits_on_status();

-- The superseded function is left in place (unreferenced) rather than dropped:
-- dropping it would make the rollback path above depend on git alone.
comment on function public.trg_wipe_upcoming_on_inactive() is
  'SUPERSEDED 2026-07-31 by fn_clients_cleanup_sa_visits_on_status (SA-scoped, soft-delete, Jobber-aware). No trigger references this any more. Kept only as a rollback reference.';

-- ---------------------------------------------------------------------------
-- 2. preview — so the dialog can state the blast radius BEFORE the write
-- ---------------------------------------------------------------------------
create or replace function client.preview_client_status_change(
  p_client_id bigint,
  p_status    text
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_old text;
  v_will boolean;
  v_n int := 0;
  v_sc int := 0;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;

  select c.status into v_old from public.clients c where c.id = p_client_id;
  if v_old is null then
    raise exception 'client % not found', p_client_id using errcode = 'P0002';
  end if;

  v_will := (v_old = 'RECURRING' and p_status <> 'RECURRING')
         or (p_status in ('INACTIVE','PAUSED') and v_old not in ('INACTIVE','PAUSED'));

  if v_will then
    select count(*) into v_n
      from public.visits v
     where v.client_id = p_client_id and v.deleted_at is null
       and v.visit_status = 'scheduled' and v.visit_date >= current_date
       and exists (select 1 from public.jobs j
                    where j.id = v.job_id and j.title ilike 'Service Agreement%');
    select count(*) into v_sc
      from public.visits v
     where v.client_id = p_client_id and v.deleted_at is null
       and v.visit_status = 'scheduled' and v.visit_date >= current_date
       and not exists (select 1 from public.jobs j
                    where j.id = v.job_id and j.title ilike 'Service Agreement%');
  end if;

  return jsonb_build_object(
    'current_status', v_old,
    'new_status', p_status,
    'will_clean_up', v_will,
    'sa_visits_to_remove', v_n,
    'service_call_visits_kept', v_sc,
    -- honest note: see the migration header's KNOWN LIMIT
    'reschedules_unless_job_closed', (v_will and p_status = 'ACTIVE'));
end;
$$;

revoke execute on function client.preview_client_status_change(bigint, text) from public;
revoke execute on function client.preview_client_status_change(bigint, text) from anon;
grant  execute on function client.preview_client_status_change(bigint, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. the write
-- ---------------------------------------------------------------------------
create or replace function client.update_client_status(
  p_client_id bigint,
  p_status    text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old  text;
  v_row  public.clients;
  v_before int;
  v_after  int;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  -- PAUSED is intentionally NOT offered to the app: Fred named three states
  -- ("recurrent, active, or inactive"). PAUSED still exists in the data and the
  -- trigger still honours it; it is simply not settable from here.
  if p_status is null or p_status not in ('ACTIVE','RECURRING','INACTIVE') then
    raise exception 'status must be ACTIVE, RECURRING or INACTIVE (got %)', p_status
      using errcode = '22023';
  end if;

  select c.status into v_old from public.clients c where c.id = p_client_id;
  if v_old is null then
    raise exception 'client % not found', p_client_id using errcode = 'P0002';
  end if;
  if v_old = p_status then
    select c.* into v_row from public.clients c where c.id = p_client_id;
    return jsonb_build_object('client', to_jsonb(v_row), 'visits_removed', 0, 'noop', true);
  end if;

  select count(*) into v_before
    from public.visits v
   where v.client_id = p_client_id and v.deleted_at is null
     and v.visit_status = 'scheduled' and v.visit_date >= current_date;

  update public.clients c set status = p_status
   where c.id = p_client_id
  returning c.* into v_row;          -- the AFTER trigger does the cleanup

  select count(*) into v_after
    from public.visits v
   where v.client_id = p_client_id and v.deleted_at is null
     and v.visit_status = 'scheduled' and v.visit_date >= current_date;

  return jsonb_build_object(
    'client', to_jsonb(v_row),
    'previous_status', v_old,
    'visits_removed', greatest(v_before - v_after, 0));
end;
$$;

revoke execute on function client.update_client_status(bigint, text) from public;
revoke execute on function client.update_client_status(bigint, text) from anon;
grant  execute on function client.update_client_status(bigint, text) to authenticated;

commit;
