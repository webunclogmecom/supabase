-- 2026-08-19_2015_backfill_job_property_id.sql
--
-- WHAT: set public.jobs.property_id on 44 jobs where it is NULL and Jobber knows the answer.
--
-- WHY:  property_id is a best-effort MIRROR, not the truth. handleJob in webhook-jobber sets it
--       only when the property is already linked at import time, and sync-jobber-poll pages jobs
--       on createdAt, so a job imported BEFORE its property was linked keeps a NULL for ever:
--       nothing re-pulls it and nothing backfills it. Confirmed by timestamps on the live pair:
--       job 1838 landed 2026-08-12 19:45:03 and property 1069 was created and linked at
--       2026-08-12 20:00:06, fifteen minutes later, via the hourly property sweep.
--
-- WHY IT MATTERS: the new _shared/service-call-job.ts asks "does this property already have a
--       Service Call?" by property_id. Jobber has NO jobDelete and NO jobArchive, so a false
--       "no" mints a permanently undeletable duplicate. The helper currently refuses these
--       clients outright (job_lookup_ambiguous), which is safe but blocks legitimate work.
--
-- SOURCE OF THE VALUES: each job was asked of JOBBER individually, job(id) { property { id } },
--       content-type guarded, and the returned property GID mapped back through
--       entity_source_links. Nothing here is inferred from the client, the address or
--       proximity. Script: scripts/probes/resolve_null_property_jobs.js.
--
-- SCOPE, measured: 57 jobs carry a NULL property_id. 44 resolve (2 live, 42 archived).
--       13 do not, and are deliberately left alone: 2 NO_JOBBER_LINK, 11 PROPERTY_NOT_LINKED_HERE.
--       The live ones, the only two with an operational consequence today:
--   job 1838 (#99901056, "Service call", action_required, client 465) -> property 1069
--   job 1840 (#99901058, "Service call", action_required, client 556) -> property 1075
--
-- WARNING: THE PREDICATE IS RE-ASSERTED, not just the primary keys. "and j.property_id is null"
--       means the statement cannot fire if the world changed between the read and the write,
--       and it makes the migration idempotent. Mutation-tested: neutralising that clause moves
--       a control job that already had a property (79 -> 2) and moves nothing else.
--
-- WARNING: NOTHING REACHES JOBBER. public.jobs carries exactly two triggers, audit_jobs and
--       trg_jobs_updated_at, enumerated before writing. There is no push trigger on this table;
--       the Jobber job push goes through save-client-job explicitly. This is a local mirror
--       repair only.
--
-- AUDIT (rule 8): public.jobs IS audited and stays audited. Every row below writes an audit.logs
--       row carrying old_row, so the change is fully recoverable. No trigger change.

begin;

update public.jobs j
   set property_id = v.prop
  from (values
  (1838, 1069),
  (1840, 1075),
  (516, 666),
  (519, 658),
  (554, 661),
  (556, 659),
  (557, 665),
  (558, 663),
  (560, 659),
  (561, 667),
  (562, 655),
  (563, 662),
  (565, 656),
  (566, 659),
  (568, 659),
  (569, 661),
  (570, 660),
  (574, 652),
  (575, 653),
  (581, 654),
  (590, 1015),
  (591, 976),
  (1284, 1055),
  (1285, 1057),
  (1286, 970),
  (1287, 970),
  (1288, 929),
  (1289, 929),
  (1290, 1058),
  (1292, 1018),
  (1293, 1013),
  (1294, 1067),
  (1295, 1012),
  (1296, 994),
  (1297, 1012),
  (1298, 1068),
  (1299, 975),
  (1301, 1060),
  (1305, 1057),
  (1306, 1057),
  (1307, 1057),
  (1738, 1054),
  (1779, 973),
  (1844, 1080)
       ) as v(job, prop)
 where j.id = v.job
   and j.property_id is null;

-- ---- VERIFY ------------------------------------------------------------------------------------
do $$
declare v_live_null int; v_still_null int; v_wrong int;
begin
  select count(*) into v_live_null from public.jobs
   where property_id is null and job_status not in ('archived','closed','destroyed')
     and lower(btrim(title)) = 'service call';
  if v_live_null <> 0 then raise exception 'VERIFY: % live Service Calls still have no property', v_live_null; end if;

  select count(*) into v_wrong from public.jobs j
    join (values
  (1838, 1069),
  (1840, 1075),
  (516, 666),
  (519, 658),
  (554, 661),
  (556, 659),
  (557, 665),
  (558, 663),
  (560, 659),
  (561, 667),
  (562, 655),
  (563, 662),
  (565, 656),
  (566, 659),
  (568, 659),
  (569, 661),
  (570, 660),
  (574, 652),
  (575, 653),
  (581, 654),
  (590, 1015),
  (591, 976),
  (1284, 1055),
  (1285, 1057),
  (1286, 970),
  (1287, 970),
  (1288, 929),
  (1289, 929),
  (1290, 1058),
  (1292, 1018),
  (1293, 1013),
  (1294, 1067),
  (1295, 1012),
  (1296, 994),
  (1297, 1012),
  (1298, 1068),
  (1299, 975),
  (1301, 1060),
  (1305, 1057),
  (1306, 1057),
  (1307, 1057),
  (1738, 1054),
  (1779, 973),
  (1844, 1080)
         ) as v(job, prop) on v.job = j.id
   where j.property_id is distinct from v.prop;
  if v_wrong <> 0 then raise exception 'VERIFY: % rows are not on the property Jobber named', v_wrong; end if;

  select count(*) into v_still_null from public.jobs where property_id is null;
  if v_still_null <> 13 then
    raise exception 'VERIFY: expected 13 unresolvable rows to remain NULL, found %', v_still_null;
  end if;

  raise notice 'VERIFY ok: 0 live Service Calls unplaced, 44 rows on the property Jobber named, % correctly left NULL', v_still_null;
end $$;

commit;
