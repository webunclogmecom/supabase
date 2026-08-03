-- =====================================================================
-- 2026-08-03_1730  PHASE A (EXPAND) — accept BOTH vocabularies
-- =====================================================================
-- WHY
--   Fred: "let's go with 'pumping' 'cleaning' or 'warranty'", "LS is pumping,
--   follow the sheet", and explicit sign-off to delete the 7 empty LS configs.
--   Plan: docs/plans/2026-08-03_service_type_vocabulary_migration_plan.md
--
--   This is the EXPAND step of expand -> migrate -> contract. It changes NO
--   data and NO object logic. It only widens the two CHECK constraints so that
--   the legacy vocabulary (GT/CL/WD/LS) and the real service names are BOTH
--   legal at the same time.
--
-- WHY A WINDOW IS MANDATORY, NOT OPTIONAL
--   public.visits.service_type has three live writers right now:
--     supabase_cron 863 rows · jobber 782 · visit-calendar 97
--   The jobber one is the edge function webhook-jobber, which deploys
--   SEPARATELY from any SQL migration. There is therefore no instant at which
--   both the data and every writer can flip together. Narrowing the CHECK
--   before every writer is cut over would reject live inbound Jobber visits.
--
--   webhook-jobber also FILTERS on service_type (index.ts L794-800) to match
--   the cron-generated placeholder visit it promotes. If the placeholder and
--   the derive disagree on vocabulary that dedupe fails SILENTLY into
--   duplicate visits rather than erroring. Both vocabularies must be legal
--   until the deploy lands.
--
-- THE ELEVENTH KIND
--   The visits CHECK admits the FULL catalogue taxonomy, not the three
--   recurring names. There are 11 kinds live, and code 28 'Dump Offload' is
--   the one an obvious ten-name list omits: it is active, schedulable, and
--   surfaces on 30 live visits. Writing the CHECK from the recurring three
--   would reject real data. service_configs is the opposite case and is
--   deliberately held to the recurring three (see Phase C).
--
-- AUDIT OPT-IN (rule #8): no new table. public.visits and
--   public.service_configs both already carry audit triggers. Unchanged.
--
-- REVERSIBLE: yes, completely. Re-adding the narrow CHECK restores the prior
--   state exactly, provided no new-vocabulary row has been written yet.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. public.visits — NULL stays legal (206 rows rely on it), plus BOTH
--    vocabularies. Full catalogue taxonomy on the new side.
-- ---------------------------------------------------------------------
alter table public.visits drop constraint if exists visits_service_type_chk;

alter table public.visits add constraint visits_service_type_chk check (
  service_type is null
  or service_type = any (array[
    -- legacy, still emitted by webhook-jobber until it is redeployed
    'GT','CL','WD','LS',
    -- the real taxonomy (public.service_line_items.service_kind, 11 values)
    'Pumping','Cleaning','Warranty of Drainage','Unclogging','Camera Inspection',
    'Dye Test','Assessment','Labor','Parts','Labor BUS','Dump Offload'
  ])
);

-- ---------------------------------------------------------------------
-- 2. public.service_configs — NOT NULL is unchanged. Only the three
--    recurring names are added: a config describes a recurring service, and
--    there is no Unclogging/Labor/Parts config nor any way to create one.
--    The 4 legacy values stay legal for this phase only.
-- ---------------------------------------------------------------------
alter table public.service_configs drop constraint if exists service_configs_service_type_chk;

alter table public.service_configs add constraint service_configs_service_type_chk check (
  service_type = any (array[
    'GT','CL','WD','LS',
    'Pumping','Cleaning','Warranty of Drainage'
  ])
);

-- ---------------------------------------------------------------------
-- 3. Assertions — a migration that silently no-ops is the failure mode here.
-- ---------------------------------------------------------------------
do $$
declare
  n_visits int;
  n_cfg    int;
begin
  -- both constraints must exist and must be the widened form
  select count(*) into n_visits from pg_constraint
   where conname = 'visits_service_type_chk'
     and pg_get_constraintdef(oid) like '%Dump Offload%';
  if n_visits <> 1 then
    raise exception 'visits CHECK was not widened (found % matching)', n_visits;
  end if;

  select count(*) into n_cfg from pg_constraint
   where conname = 'service_configs_service_type_chk'
     and pg_get_constraintdef(oid) like '%Warranty of Drainage%';
  if n_cfg <> 1 then
    raise exception 'service_configs CHECK was not widened (found % matching)', n_cfg;
  end if;

  -- POSITIVE CONTROL: prove both vocabularies are actually INSERTABLE, not
  -- merely that the constraint TEXT changed. A text assertion alone is an
  -- untested instrument.
  --
  -- Each probe runs inside its own BEGIN...EXCEPTION block, which establishes
  -- an implicit savepoint; raising out of the block rolls the INSERT back, so
  -- no row is ever committed to public.visits. (Explicit SAVEPOINT / ROLLBACK
  -- TO SAVEPOINT are NOT permitted inside PL/pgSQL and raise
  -- "unsupported transaction command" — the block form is the supported way.)
  --
  -- Rolling back matters beyond tidiness: an INSERT into visits fires
  -- trg_mark_visit_sync_pending (which would enqueue a fake visit that the */3
  -- cron then drains toward Jobber), audit_visits, and trg_gdo_compliance_check.
  -- It also avoids a hard DELETE of visits rows to clean up after ourselves.
  -- ⚠ THE PROBE MUST BE VALID IN EVERY RESPECT EXCEPT THE COLUMN UNDER TEST.
  --   First attempt used source='migration-probe' and failed on
  --   visits_source_chk (legal sources are jobber/supabase_cron/airtable/
  --   manual/odoo/visit-calendar). Because `when check_violation` catches ANY
  --   check constraint, the handler reported "Pumping was rejected" when the
  --   real cause was the SOURCE column. That is a confounded instrument: it
  --   was measuring its own invalidity, not the constraint under test.
  --   Fixed two ways: a legal source, AND every handler now reads
  --   CONSTRAINT_NAME and refuses to interpret a violation it did not target.
  declare
    v_client bigint;
    v_date   date;
    v_con    text;
  begin
    select client_id, visit_date into v_client, v_date
      from public.visits where deleted_at is null limit 1;
    if v_client is null then
      raise exception 'CONTROL FAILED: no live visit to build a probe from';
    end if;

    -- (a) NEW vocabulary must be accepted
    begin
      insert into public.visits (client_id, visit_date, visit_status, source, service_type)
      values (v_client, v_date, 'scheduled', 'manual', 'Pumping');
      raise exception using errcode = 'ZZ001', message = 'probe_ok';  -- undo the insert
    exception
      when sqlstate 'ZZ001' then null;   -- accepted, and rolled back
      when check_violation then
        get stacked diagnostics v_con = constraint_name;
        if v_con is distinct from 'visits_service_type_chk' then
          raise exception 'CONTROL INVALID: probe violated %, not the constraint under test — fix the probe, not the schema', v_con;
        end if;
        raise exception 'CONTROL FAILED: new vocabulary (Pumping) rejected by the widened CHECK';
    end;

    -- (b) LEGACY vocabulary must STILL be accepted — this is the whole point of
    --     Phase A. If it is not, live inbound Jobber visits start failing.
    begin
      insert into public.visits (client_id, visit_date, visit_status, source, service_type)
      values (v_client, v_date, 'scheduled', 'manual', 'GT');
      raise exception using errcode = 'ZZ001', message = 'probe_ok';
    exception
      when sqlstate 'ZZ001' then null;
      when check_violation then
        get stacked diagnostics v_con = constraint_name;
        if v_con is distinct from 'visits_service_type_chk' then
          raise exception 'CONTROL INVALID: probe violated %, not the constraint under test', v_con;
        end if;
        raise exception 'CONTROL FAILED: legacy vocabulary (GT) rejected — live Jobber writes would break';
    end;

    -- (c) NEGATIVE CONTROL: junk must still be rejected, and rejected by the
    --     RIGHT constraint. Without this, (a) and (b) would both pass if the
    --     constraint were simply absent.
    begin
      insert into public.visits (client_id, visit_date, visit_status, source, service_type)
      values (v_client, v_date, 'scheduled', 'manual', 'NOT_A_KIND');
      raise exception using errcode = 'ZZ002', message = 'junk_accepted';
    exception
      when check_violation then
        get stacked diagnostics v_con = constraint_name;
        if v_con is distinct from 'visits_service_type_chk' then
          raise exception 'CONTROL INVALID: junk probe violated % instead — the negative control proves nothing', v_con;
        end if;
        null;  -- expected: the service_type constraint is live and enforcing
      when sqlstate 'ZZ002' then
        raise exception 'CONTROL FAILED: junk service_type accepted — constraint not enforcing';
    end;
  end;

  raise notice 'PHASE A OK: both vocabularies accepted, junk rejected, nothing committed';
end $$;

commit;
