-- ============================================================================
-- 2026-08-12_1420: re-sync three job statuses from Jobber
-- ============================================================================
-- Fred, 2026-08-12: "fix the 3 job statuses and remove the duplicate SC jobs."
--
-- ⚠ ONLY THE FIRST HALF IS DONE HERE. There are no duplicate SC jobs to remove, and
-- the evidence is at the bottom of this file. Read it before re-attempting that.
--
-- WHAT THIS FIXES.
-- Fred: "I found a client recently which showed closed job in our db but it was opened
-- in jobber." Measured across ALL 1,797 Jobber jobs against our 1,804:
--     ours closed / Jobber open ... 3   <- these
--     ours open / Jobber closed ... 0
--     any other status difference   0
-- So the drift is real, one-directional, and tiny. Jobber owns job lifecycle (rule 4),
-- so Jobber's value wins in all three.
--
--   job 349   "Pumping"                    archived -> action_required
--   job 576   "Quaterly Hydrojet cleaning" archived -> requires_invoicing   (110-CLA)
--   job 1074  "Service Call"               archived -> action_required
--
-- ⚠ A CORRECTION TO MY OWN EARLIER REPORT: I said two of these had a NULL client. They
-- do not. jobs.client_id is 83, 372 and 100; what is null is those clients' client_code.
-- Different problem, not fixed here, and not a reason to leave the status wrong.
--
-- 🛑 WHY THEY DRIFTED, because the row fix does not address it.
-- sync-jobber-job-drift builds its candidate set with
--   .not("job_status","in","(archived,closed,destroyed)")
-- plus a 14-day arm for jobs that went terminal on our side but are still open in Jobber.
-- A job archived with us more than 14 days ago and reopened in Jobber falls outside both
-- arms and can never be reconciled. That is exactly this shape. Widening the sweep is NOT
-- done here: Fred settled on 2026-08-03 that the reconciler ignores archived jobs on
-- purpose, and that decision was about cost on every 30-minute run. Three rows a quarter
-- is cheaper to correct by hand than to re-open that trade. If this recurs at volume,
-- the 14-day arm is the thing to lengthen, not the exclusion to drop.
--
-- AUDIT-TRAIL STANDING CHECK (rule 8): public.jobs carries its audit trigger, so all
-- three writes land in audit.logs with old_row and are individually revertible.
-- ============================================================================

do $do$
declare v_n int;
begin
  -- pre-state: all three must still be archived on our side, or the world moved
  select count(*) into v_n from public.jobs where id in (349, 576, 1074) and job_status = 'archived';
  if v_n <> 3 then
    raise exception 'expected 3 archived jobs (349,576,1074), found % -- re-measure against Jobber', v_n;
  end if;
  -- and all three must still be Jobber-linked, since Jobber is the authority being copied
  select count(*) into v_n from public.entity_source_links
   where entity_type='job' and source_system='jobber' and entity_id in (349, 576, 1074);
  if v_n <> 3 then raise exception 'only % of the 3 jobs are Jobber-linked', v_n; end if;
end
$do$;

update public.jobs j
   set job_status = v.status
  from (values (349, 'action_required'), (576, 'requires_invoicing'), (1074, 'action_required'))
       as v(id, status)
 where j.id = v.id
   and j.job_status is distinct from v.status;

do $do$
declare v_n int; v_control text; v_audit int;
begin
  -- (a) all three now carry Jobber's value
  select count(*) into v_n from public.jobs j
    join (values (349,'action_required'),(576,'requires_invoicing'),(1074,'action_required')) v(id,status)
      on v.id=j.id and j.job_status = v.status;
  if v_n <> 3 then raise exception 'only % of 3 jobs took the new status', v_n; end if;

  -- (b) POSITIVE CONTROL. Every check above passes on a table where every job was set to
  -- something. Assert a job that must NOT have moved: 228 is 045-NU's archived
  -- "Grease trap pumping", archived in both systems and not in the update list.
  select job_status into v_control from public.jobs where id = 228;
  if v_control <> 'archived' then
    raise exception 'control job 228 now reads % -- the update hit rows it should not have', v_control;
  end if;

  -- (c) recoverable
  select count(*) into v_audit from audit.logs
   where table_name='jobs' and operation='UPDATE' and changed_at > now() - interval '5 minutes';
  if v_audit < 3 then raise exception 'only % audit rows captured for 3 updates', v_audit; end if;

  raise notice '3 job statuses re-synced from Jobber; control job 228 untouched';
end
$do$;

-- ============================================================================
-- 🛑 THE SC "DUPLICATES" ARE NOT DUPLICATES. NOTHING IS DELETED.
-- ============================================================================
-- Three clients appeared to hold more than one open Service Call job:
--     275-MLP  jobs 1280, 1790 ("Service call - 341"), 1836
--     128-MF   jobs 1683, 1791
--     112-YA   jobs 766, 1807
--
-- Checked against Jobber before touching anything. Jobber holds every one of them, OPEN:
--     275-MLP  3 open SC jobs in Jobber (#99901055, #99901034 "- 341", #10001049)
--     128-MF   2 open in Jobber (#99901035, #99900936), plus one archived
--     112-YA   2 open in Jobber (#99901049, #99900535), plus eight archived
--
-- Our rows mirror Jobber exactly, in both count and status. There is no duplication on
-- our side to remove. Deleting them would contradict rule 4 (Jobber owns job lifecycle),
-- be re-created by the next poll, and hard-delete business data that carries visits
-- (job 1280 has 1 visit, 1836 has 1, 1791 has 1, 766 has 6) against rule 6.
--
-- ⚠ AND AT LEAST ONE IS DEFINITELY NOT A DUPLICATE ANYWAY. 275-MLP is a property manager
-- with three sites; job 1790 is literally titled "Service call - 341" and 341 is the NAME
-- of one of its properties (id 993, "341 Northwest 43rd Avenue"). A Service Call per site
-- is the correct shape, not an accident.
--
-- 🛑 THIS IS THE THIRD TIME TODAY THE SAME CHECK REVERSED A "DUPLICATE" FINDING, and it is
-- worth stating as a rule rather than three anecdotes:
--     242-WYN  six same-address properties -> six real units, distinguished by NAME
--     262-JM   "401 93rd St" vs "401 93rd Street" -> Jobber holds BOTH; the duplicate is upstream
--     these    three open SC jobs -> Jobber holds all three open
-- ⇒ Before deleting anything as a duplicate, ask Jobber. If Jobber has it, we are mirroring
--   correctly and the fix belongs in Jobber, not here.
--
-- If these genuinely should be one job per client, they must be closed in JOBBER; the poll
-- will carry that across within the hour.
-- ============================================================================
