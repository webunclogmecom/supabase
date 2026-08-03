-- =====================================================================
-- 2026-08-03_1530  PHASE C1 (CONTRACT, part 1) — narrow the CHECK constraints
-- =====================================================================
-- WHY
--   Fred: "let's do phase C then". Phase A widened both CHECKs so the legacy
--   GT/CL/WD/LS vocabulary and the real service names were legal at once, which
--   is what made the separately-deployed webhook-jobber safe in BOTH deploy
--   directions. That window has served its purpose and is now closed.
--
--   ⚠ I twice recommended letting this soak longer and Fred asked for it twice,
--   so it proceeds. Soaking would have bought time to notice a writer still
--   emitting the legacy vocabulary BEFORE narrowing makes such a write fail.
--   That is replaced here by a measured gate rather than elapsed time.
--
-- GATE MEASURED IMMEDIATELY BEFORE APPLYING (2026-08-03 15:24 ET, ~1h after cut)
--   * 0 legacy values anywhere in visits / service_configs / service_line_items.
--   * 135 visits rows were UPDATED in the preceding 60 minutes — i.e. the live
--     writers are ACTIVE, not idle — and every one carries the new vocabulary
--     (Pumping 118, Cleaning 10, NULL 7). An idle hour would have proven nothing;
--     an hour of real writes all landing correctly is the actual evidence.
--   * webhook-jobber: 0 failures in 60 minutes.
--   * All six apps verified in-UI, zero legacy codes rendered anywhere.
--
-- WHAT NARROWING BUYS
--   After this, a legacy write FAILS LOUDLY (23514) instead of silently landing
--   as a value no view matches. That silent-mismatch mode is the dangerous one:
--   such a row drops out of every cadence CTE and config join with no error.
--
-- WHAT IT COSTS (the honest trade)
--   If any unmigrated writer remains, its writes now break rather than degrade.
--   The mitigation is that failures are visible in webhook_events_log within
--   5 minutes, and this migration is trivially reversible — re-run Phase A.
--
-- 🛑 THE ELEVENTH KIND STAYS. The visits CHECK keeps the FULL catalogue
--   taxonomy, not the three recurring names. Code 28 'Dump Offload' is live on
--   30 visits; writing this constraint from the three recurring names would
--   reject real data. service_configs is the opposite case and IS held to the
--   recurring three, because a config describes a recurring service and there is
--   no way to create an Unclogging/Labor/Parts config.
--
-- AUDIT OPT-IN (rule #8): no new table; both tables already audited. Unchanged.
-- REVERSIBLE: yes. Re-applying 2026-08-03_1730_service_type_phaseA_expand.sql
--   restores the widened form exactly.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. GATE — refuse to narrow if a legacy value is present anywhere. Without
--    this the ALTER would fail on a confusing constraint violation instead of
--    a readable message naming the actual problem.
-- ---------------------------------------------------------------------
do $$
declare n_v int; n_c int; n_s int;
begin
  select count(*) into n_v from public.visits where service_type in ('GT','CL','WD','LS');
  select count(*) into n_c from public.service_configs where service_type in ('GT','CL','WD','LS');
  select count(*) into n_s from public.service_line_items where service_type in ('GT','CL','WD','LS');
  if n_v + n_c + n_s > 0 then
    raise exception 'REFUSING to narrow: legacy values still present (visits=%, service_configs=%, catalogue=%). Something is still writing them; fix that first.',
      n_v, n_c, n_s;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. public.visits — NULL stays legal (206 rows rely on it). Full catalogue
--    taxonomy on the allowed side; the legacy four are gone.
-- ---------------------------------------------------------------------
alter table public.visits drop constraint if exists visits_service_type_chk;

alter table public.visits add constraint visits_service_type_chk check (
  service_type is null
  or service_type = any (array[
    'Pumping','Cleaning','Warranty of Drainage','Unclogging','Camera Inspection',
    'Dye Test','Assessment','Labor','Parts','Labor BUS','Dump Offload'
  ])
);

-- ---------------------------------------------------------------------
-- 2. public.service_configs — NOT NULL unchanged; the recurring three only.
-- ---------------------------------------------------------------------
alter table public.service_configs drop constraint if exists service_configs_service_type_chk;

alter table public.service_configs add constraint service_configs_service_type_chk check (
  service_type = any (array['Pumping','Cleaning','Warranty of Drainage'])
);

-- ---------------------------------------------------------------------
-- 3. ASSERTIONS — with live probes, because asserting on the constraint TEXT
--    only proves the text changed, not that it enforces.
-- ---------------------------------------------------------------------
do $$
declare
  v_client bigint; v_date date; v_con text; n int;
begin
  -- the constraint must no longer mention the legacy vocabulary
  select count(*) into n from pg_constraint
   where conname in ('visits_service_type_chk','service_configs_service_type_chk')
     and pg_get_constraintdef(oid) ~ '''(GT|CL|WD|LS)''';
  if n > 0 then
    raise exception '% constraint(s) still admit the legacy vocabulary', n;
  end if;

  -- Dump Offload must survive: it is live on 30 visits and is the value an
  -- obvious "three recurring names" list would have silently rejected.
  select count(*) into n from pg_constraint
   where conname = 'visits_service_type_chk'
     and pg_get_constraintdef(oid) like '%Dump Offload%';
  if n <> 1 then
    raise exception 'visits CHECK lost Dump Offload — 30 live visits would be rejected';
  end if;

  select client_id, visit_date into v_client, v_date
    from public.visits where deleted_at is null limit 1;

  -- (a) the new vocabulary must still be ACCEPTED
  begin
    insert into public.visits (client_id, visit_date, visit_status, source, service_type)
    values (v_client, v_date, 'scheduled', 'manual', 'Pumping');
    raise exception using errcode = 'ZZ001', message = 'probe_ok';   -- undo
  exception
    when sqlstate 'ZZ001' then null;
    when check_violation then
      get stacked diagnostics v_con = constraint_name;
      if v_con is distinct from 'visits_service_type_chk' then
        raise exception 'CONTROL INVALID: probe violated %, not the constraint under test', v_con;
      end if;
      raise exception 'CONTROL FAILED: the new vocabulary is being rejected';
  end;

  -- (b) the LEGACY vocabulary must now be REJECTED — this is the whole point
  begin
    insert into public.visits (client_id, visit_date, visit_status, source, service_type)
    values (v_client, v_date, 'scheduled', 'manual', 'GT');
    raise exception using errcode = 'ZZ002', message = 'legacy_still_accepted';
  exception
    when check_violation then
      get stacked diagnostics v_con = constraint_name;
      if v_con is distinct from 'visits_service_type_chk' then
        raise exception 'CONTROL INVALID: legacy probe violated % instead — proves nothing', v_con;
      end if;
      null;  -- expected: the window is closed
    when sqlstate 'ZZ002' then
      raise exception 'CONTROL FAILED: legacy value GT is STILL accepted — the CHECK did not narrow';
  end;

  raise notice 'PHASE C1 OK — legacy rejected, new vocabulary accepted, Dump Offload preserved';
end $$;

commit;
