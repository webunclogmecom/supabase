-- ============================================================================
-- 2026-08-12_1550: backfill public.jobs.property_id on 49 open jobs
-- ============================================================================
-- Found while closing the "duplicate" SC jobs
-- (docs/audits/2026-08-12_sc_job_duplicate_review_and_close.md).
--
-- 🛑 WHY THIS MATTERS MORE THAN 49 NULL COLUMNS: IT IS WHAT MADE REAL JOBS LOOK LIKE
-- DUPLICATES. Fred asked to remove "duplicate" Service Call jobs. Read from OUR database,
-- 275-MLP's three open SC jobs all showed property = (none), which is the signature of a
-- duplicate. Read from the Jobber API, they sit at three DIFFERENT addresses (47 NW 49th,
-- 341 NW 43rd, 160 NW 45th) and are one-per-site for a property manager. A missing column
-- did not just lose data, it manufactured a false finding that came within one instruction
-- of destroying live per-site jobs.
--
-- THE MEASUREMENT (open jobs = not archived/closed/destroyed):
--     all open jobs missing property_id .....  50 / 451   (11%)
--     open Service Call .....................  41 / 271   (15%)
--     open Service Agreement ................   6 / 176   (3%)   <- control
--   by month created:  Apr 0/25 (0%)   Jun 20/382 (5%)   Jul 27/38 (71%)   Aug 3/5 (60%)
-- So it is recent and it is heavily weighted to Service Calls.
--
-- ⚠ MY FIRST DIAGNOSIS WAS WRONG AND THE DATA REFUTED IT. I attributed this to today's
-- property-sweep bug (properties never populating, so the job had nothing to point at).
-- Measured: all 50 jobs DO carry a property in Jobber, and 49 of the 50 have that property
-- ALREADY LINKED on our side. Only job 1838, created 2026-08-12 15:45 ET, is genuinely
-- waiting on its property. The real mechanism is ORDERING: webhook-jobber line 1105 reads
--     if (propertyId) jobRow.property_id = propertyId
-- so when a job is populated before its property exists, the field is SILENTLY SKIPPED
-- rather than erroring, and nothing ever re-populates that job. The sweep bug made that
-- window wide (350 properties were queued this morning), but the silent skip is the defect.
-- ⇒ This migration repairs the data. It does NOT fix the skip; a job populated ahead of its
--   property will still come out NULL. That belongs in handleJob and is not done here.
--
-- WHY A TARGETED UPDATE RATHER THAN RE-RUNNING THE POPULATE.
-- Marking the 49 raw rows needs_populate would re-run handleJob and rewrite EVERY field from
-- whatever raw last pulled, which can revert newer values -- including the three job statuses
-- hand-corrected four hours ago in 2026-08-12_1420. This writes ONE column, so the blast
-- radius is exactly the defect.
--
-- SAFETY, all verified in a rolled-back probe before writing this file:
--     resolvable candidates ......... 49
--     would cross CLIENTS ............ 0   <- would be corruption; refused below anyway
--     would point at a BILLING row ... 0   <- billing rows are not service locations
--     still unresolvable ............. 1   (job 1838; self-heals when the sweep links it)
--
-- AUDIT-TRAIL STANDING CHECK (rule 8): public.jobs carries its audit trigger, so all 49
-- writes land in audit.logs with old_row intact and are individually revertible.
-- ============================================================================

create temp table _pre_jobs on commit drop as
  select id, property_id, client_id from public.jobs;

do $do$
declare v_null int; v_total int; v_audited boolean;
begin
  select count(*) filter (where property_id is null), count(*)
    into v_null, v_total
    from public.jobs j
   where j.job_status not in ('archived','closed','destroyed');
  if v_null <> 50 then
    raise exception 'expected 50 open jobs with NULL property_id, found % -- re-measure', v_null;
  end if;
  if v_total <> 451 then
    raise notice 'open job count is % (was 451 at measurement time); continuing', v_total;
  end if;

  select exists (select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid
                  join pg_proc pr on pr.oid=t.tgfoid join pg_namespace pn on pn.oid=pr.pronamespace
                 where c.relname='jobs' and pn.nspname='audit' and pr.proname='log_change'
                   and not t.tgisinternal) into v_audited;
  if not v_audited then
    raise exception 'public.jobs is NOT audited -- this backfill would leave no trail';
  end if;
end
$do$;

update public.jobs j
   set property_id = src.new_prop
  from (
    select j2.id as job_id,
           (select l.entity_id from public.entity_source_links l
             where l.entity_type='property' and l.source_system='jobber'
               and l.source_id = r.data->'property'->>'id' limit 1) as new_prop
      from public.jobs j2
      join public.entity_source_links jl
        on jl.entity_type='job' and jl.source_system='jobber' and jl.entity_id = j2.id
      join raw.jobber_pull_jobs r on r.data->>'id' = jl.source_id
     where j2.job_status not in ('archived','closed','destroyed')
       and j2.property_id is null
  ) src
  join public.properties p on p.id = src.new_prop
 where j.id = src.job_id
   and src.new_prop is not null
   and p.client_id = j.client_id          -- never attach another client's property
   and coalesce(p.is_billing, false) = false;  -- never attach a billing row as the service site

do $do$
declare v_changed int; v_null_after int; v_lost int; v_cross int; v_audit int; v_ctl_prop int; v_ctl_pre int;
begin
  -- (a) exactly the 49 gained a property
  select count(*) into v_changed
    from public.jobs j join _pre_jobs pre on pre.id = j.id
   where pre.property_id is null and j.property_id is not null;
  if v_changed <> 49 then raise exception '% jobs gained a property, expected 49', v_changed; end if;

  -- (b) NOTHING LOST one. This is the check that a careless join would fail.
  select count(*) into v_lost
    from public.jobs j join _pre_jobs pre on pre.id = j.id
   where pre.property_id is not null and j.property_id is distinct from pre.property_id;
  if v_lost <> 0 then
    raise exception '% jobs had an existing property_id CHANGED or cleared -- aborting', v_lost;
  end if;

  -- (c) one open job remains NULL, and it is the one created minutes ago
  select count(*) into v_null_after from public.jobs
   where job_status not in ('archived','closed','destroyed') and property_id is null;
  if v_null_after <> 1 then
    raise exception '% open jobs still have NULL property_id, expected 1 (job 1838)', v_null_after;
  end if;

  -- (d) no job now points at another client's property, fleet-wide, not just the 49
  select count(*) into v_cross from public.jobs j
    join public.properties p on p.id = j.property_id
   where p.client_id <> j.client_id;
  if v_cross <> 0 then raise exception '% jobs point at another client''s property', v_cross; end if;

  -- (e) POSITIVE CONTROL. Every check above is satisfied by an UPDATE that touched every
  -- row. Job 1280 (275-MLP, 47 NW 49th St) already had a property and is NOT in the
  -- candidate set: assert it still holds the exact value it held before the update.
  select property_id into v_ctl_prop from public.jobs where id = 1280;
  select property_id into v_ctl_pre  from _pre_jobs where id = 1280;
  if v_ctl_prop is null or v_ctl_prop is distinct from v_ctl_pre then
    raise exception 'control job 1280 property_id moved from % to %', v_ctl_pre, v_ctl_prop;
  end if;

  -- (f) recoverable
  select count(*) into v_audit from audit.logs
   where table_name='jobs' and operation='UPDATE' and changed_at > now() - interval '5 minutes';
  if v_audit < 49 then raise exception 'only % audit rows captured for 49 updates', v_audit; end if;

  raise notice '49 jobs linked to their Jobber property; 1 pending (1838); control 1280 intact';
end
$do$;
