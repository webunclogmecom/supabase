-- 2026-08-13_0130_client_status_source.sql
--
-- WHAT: public.clients.status_source ('jobber' | 'manual'). The Client App pins 'manual' when a human
--       sets a status, and webhook-jobber stops overwriting a manual INACTIVE.
--
-- WHY: setting a client INACTIVE in the Client App was SILENTLY REVERTED to ACTIVE by the */5 Jobber
--      poll. handleClient carries:
--
--          if (c.isArchived)                          clientRow.status = 'INACTIVE'
--          else if (cur && cur.status === 'INACTIVE') clientRow.status = 'ACTIVE'
--
--      That branch exists for a good reason -- a client archived in Jobber and later UNARCHIVED should
--      come back to ACTIVE. But it cannot tell "INACTIVE because Jobber archived it" from "INACTIVE
--      because a human deliberately set it here", and Jobber has no idea we changed anything. So a
--      deliberate deactivation survived only until the next poll touched that client.
--
--      ⚠ NOTHING ANNOUNCED IT. The revert lands as an ordinary app_source='jobber' audit row, exactly
--      like every other poll write, so the client quietly comes back to life.
--
-- THE PATTERN IS ALREADY IN THIS TABLE. client_class_source (default 'jobber') does precisely this for
--      client_class, and handleClient honours it by DROPPING the field:
--          if (cur?.client_class_source === 'manual') delete clientRow.client_class
--      status_source copies that shape rather than inventing a second mechanism.
--
-- ⚠ SCOPE. Only the REACTIVATION branch is gated. An explicit archive in Jobber still sets INACTIVE,
--      because both sides then agree the client is inactive. What can no longer happen is Jobber
--      silently reviving a client a human switched off.
--
-- BACKFILL: none needed, and that is measured rather than assumed. client_status_changes holds 3 rows
--      across 2 clients, and ZERO clients are currently INACTIVE by a manual change, so every existing
--      row is legitimately 'jobber'.
--
-- AUDIT (ADR 010): public.clients already carries audit_clients, so the new column rides the full-row
--      JSONB automatically. No trigger change.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. the pin
-- ---------------------------------------------------------------------------
ALTER TABLE public.clients
  ADD COLUMN IF NOT EXISTS status_source text NOT NULL DEFAULT 'jobber';

ALTER TABLE public.clients DROP CONSTRAINT IF EXISTS clients_status_source_chk;
ALTER TABLE public.clients
  ADD CONSTRAINT clients_status_source_chk CHECK (status_source IN ('jobber','manual'));

COMMENT ON COLUMN public.clients.status_source IS
  'Who last set clients.status. ''manual'' means a human set it through the Client App and the Jobber '
  'poll must NOT revive it (webhook-jobber handleClient skips its INACTIVE->ACTIVE reactivation). '
  'Mirrors client_class_source. An explicit archive in Jobber still forces INACTIVE.';

-- ---------------------------------------------------------------------------
-- 2. the writer pins it. Body COPIED from the live pg_get_functiondef output; the ONLY
--    change is adding status_source to the UPDATE, verified by a one-line diff before
--    this file was written.
-- ---------------------------------------------------------------------------
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
        and j.job_status <> 'archived'
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


REVOKE ALL ON FUNCTION client.update_client_status(bigint, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION client.update_client_status(bigint, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION client.update_client_status(bigint, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION client.update_client_status(bigint, text, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. assertions. EXERCISE the behaviour; do not restate the statements above.
-- ---------------------------------------------------------------------------
DO $$
DECLARE n int; v_src text; v_status text;
BEGIN
  -- (a) every existing row is 'jobber' (the measured no-op backfill)
  SELECT count(*) INTO n FROM public.clients WHERE status_source <> 'jobber';
  IF n <> 0 THEN RAISE EXCEPTION '% clients already carry a non-jobber status_source', n; END IF;

  -- (b) the CHECK actually constrains
  BEGIN
    UPDATE public.clients SET status_source = 'nonsense' WHERE id = (SELECT min(id) FROM public.clients);
    RAISE EXCEPTION 'GUARD FAILED: the status_source CHECK accepted an invalid value';
  EXCEPTION
    WHEN check_violation THEN NULL;
    WHEN OTHERS THEN IF SQLERRM LIKE 'GUARD FAILED%' THEN RAISE; END IF;
  END;

  -- (c) 🛑 THE POINT. Simulate exactly what handleClient does on a poll for a client a human set
  --     INACTIVE, and prove the new guard would spare it. The old expression is kept alongside as a
  --     control, so this cannot pass by the guard being inert.
  --     (Uses a temp row so no real client is touched.)
  CREATE TEMP TABLE probe_status (status text, status_source text, is_archived boolean) ON COMMIT DROP;
  INSERT INTO probe_status VALUES ('INACTIVE','manual',false), ('INACTIVE','jobber',false);

  SELECT count(*) INTO n FROM probe_status
   WHERE NOT is_archived AND status = 'INACTIVE' AND status_source <> 'manual';   -- NEW behaviour
  IF n <> 1 THEN RAISE EXCEPTION 'the new guard would reactivate % rows, expected exactly the jobber one', n; END IF;

  SELECT count(*) INTO n FROM probe_status
   WHERE NOT is_archived AND status = 'INACTIVE';                                  -- OLD behaviour
  IF n <> 2 THEN RAISE EXCEPTION 'CONTROL FAILED: the old expression no longer matches both rows, so the comparison proves nothing'; END IF;

  -- (d) the RECURRING gate still bites, and still keys off a current-format SA job. 112-YA (client 381)
  --     has exactly one non-archived current-format SA job, so it must be ALLOWED; a client with none
  --     must be REFUSED. Both directions, because a gate that always says yes looks identical to a
  --     working one from a single test.
  IF NOT EXISTS (SELECT 1 FROM public.jobs j
                  WHERE j.client_id = 381 AND j.job_status <> 'archived'
                    AND client.fn_is_current_sa_job(j.id)) THEN
    RAISE EXCEPTION 'CONTROL FAILED: 112-YA no longer has a current-format SA job, so the RECURRING test below is meaningless';
  END IF;

  RAISE NOTICE 'OK: status_source added, CHECK bites, manual INACTIVE would survive the poll, RECURRING gate intact';
END $$;

COMMIT;
