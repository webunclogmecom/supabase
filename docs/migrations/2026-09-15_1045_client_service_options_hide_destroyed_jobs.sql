-- ============================================================================================
-- 2026-09-15_1045_client_service_options_hide_destroyed_jobs.sql
--
-- The Visit Calendar's New Visit job picker reads ops.client_service_options, and that view hid
-- exactly two things: job_status = 'archived' and a title carrying [OLD]. A job Jobber has DELETED
-- arrives here as job_status = 'destroyed' (JOB_DESTROY, webhook-jobber), which the view did not
-- hide, so a deleted job was OFFERED for a new visit until the poll re-read it as 'archived'.
-- ⚠ CORRECTION (same day, comment only, the SQL below is what ran): the converger is NOT the poll.
--   'archived' comes back when sync-jobber-job-drift's gone-arm (every 30 minutes, :15/:45) asks
--   Jobber for the job by id and gets nothing; the poll pulls by updatedAt and never re-pulled the
--   six. 08-21's "20 minutes" was the 01:45 drift run. The window is up to 30 minutes, longer when
--   a drift run fails (10:45 on 2026-09-15 went partial on three HTTP 401s).
--
-- WHAT IT COST, 2026-09-15 10:33 ET. Fred deleted three 112-YA properties in Jobber (1057, 1091,
-- 1107; Fred: "Delete all the properties except Miami Beach for 112-YA"). Jobber cascades a property
-- delete to its jobs, and the JOB_DESTROY webhooks set SIX jobs to 'destroyed' in the same second:
-- the two open ones (1846, 1849) and FOUR that were already 'archived' (1285, 1305, 1306, 1307).
-- Four of the six carry no [OLD] tag, so the picker went from 2 cards to 6 (Fred: "Now what is
-- this mess?"), offering visits on jobs that no longer exist in Jobber. The 2026-08-21 precedent
-- (job 1848) says the poll converges 'destroyed' to 'archived' about 20 minutes later, so the mess
-- is transient, but a deleted job offered for 20 minutes is still wrong, and it recurs on every
-- property delete: a visit created on one is pushed to a job Jobber no longer has.
--
-- THE FIX. One predicate: job_status <> 'destroyed' alongside the existing <> 'archived'. The body
-- is the LIVE pg_get_viewdef output (md5 pinned in PRE) with that one anchored insert, assembled
-- by scripts/probes/assemble_cso_migration.py; nothing is retyped. CREATE OR REPLACE VIEW keeps the
-- column list, so grants survive (asserted). 'closed' is deliberately NOT added: it is a product
-- question whether a closed Jobber job may take a new visit, and there are 0 closed jobs today.
--
-- RULE 8: no table change. Consumers: the Visit Calendar job picker (the only reader; measured in
-- pg_stat_statements). App-side note: Building Apps/Visit Calendar/docs/08-changelog.md.
-- ============================================================================================
BEGIN;

CREATE TEMP TABLE _cso_pre ON COMMIT DROP AS
  SELECT relacl::text AS acl FROM pg_class WHERE oid = 'ops.client_service_options'::regclass;

DO $pre$
DECLARE v_def text;
BEGIN
  v_def := pg_get_viewdef('ops.client_service_options'::regclass, false);
  IF md5(v_def) <> '3039fc3cdb8ac024395089029fb6cdb8' THEN
    RAISE EXCEPTION 'PRE 1: ops.client_service_options is not the body this file was patched from (md5 %)', md5(v_def);
  END IF;
  IF v_def LIKE '%destroyed%' THEN
    RAISE EXCEPTION 'PRE 2: the view already hides destroyed jobs; this file was applied already';
  END IF;
END
$pre$;

-- --------------------------------------------------------------------------------------------
-- PART 1. The view, spliced from the live definition with one added predicate.
-- --------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW ops.client_service_options AS
 SELECT c.id AS client_id,
    c.client_code,
    c.name AS client_name,
    j.id AS job_id,
    j.job_number,
        CASE
            WHEN (j.title ~~* 'Service Agreement%'::text) THEN 'SA'::text
            ELSE 'SC'::text
        END AS job_kind,
    j.title AS job_title,
    j.frequency_days,
    j.property_id,
    COALESCE(svc.services, '[]'::json) AS services,
    svc.primary_group AS job_service_group
   FROM ((jobs j
     JOIN clients c ON ((c.id = j.client_id)))
     LEFT JOIN LATERAL ( SELECT json_agg(json_build_object('service_line_item_id', sli.id, 'code', sli.code, 'title', sli.title, 'requires_derm', sli.requires_derm, 'service_type', sli.service_type, 'service_group', ops.fn_service_group(sli.reason, sli.service_type, sli.location_target), 'unit_price', li.unit_price) ORDER BY sli.code) AS services,
            (array_agg(ops.fn_service_group(sli.reason, sli.service_type, sli.location_target) ORDER BY sli.code))[1] AS primary_group
           FROM (line_items li
             JOIN service_line_items sli ON ((sli.code = lpad("substring"(btrim(li.name), '^([0-9]+)'::text), 2, '0'::text))))
          WHERE ((li.job_id = j.id) AND (li.visit_id IS NULL) AND (li.quantity > (0)::numeric) AND (sli.schedulable = true))) svc ON (true))
  WHERE ((j.job_status <> 'archived'::text) AND (j.job_status <> 'destroyed'::text) AND ((j.title IS NULL) OR (j.title !~~* '%[OLD]%'::text)));

-- --------------------------------------------------------------------------------------------
-- VERIFY
-- --------------------------------------------------------------------------------------------
DO $verify$
DECLARE v_acl text; v_new int; v_old int; v_gap int; v_fix bigint;
BEGIN
  -- 1. grants unchanged (CREATE OR REPLACE VIEW must not have dropped and recreated)
  SELECT relacl::text INTO v_acl FROM pg_class WHERE oid = 'ops.client_service_options'::regclass;
  IF v_acl IS DISTINCT FROM (SELECT acl FROM _cso_pre) THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: acl moved from % to %', (SELECT acl FROM _cso_pre), v_acl;
  END IF;
  -- 2. no destroyed job is offered
  SELECT count(*) INTO v_new FROM ops.client_service_options o JOIN public.jobs j ON j.id = o.job_id WHERE j.job_status = 'destroyed';
  IF v_new <> 0 THEN RAISE EXCEPTION 'VERIFY 2 FAILED: % destroyed jobs still offered', v_new; END IF;
  -- 3. the destroyed jobs are the ONLY rows removed (one view row per job: the LATERAL is a LEFT JOIN)
  SELECT count(*) INTO v_new FROM ops.client_service_options;
  SELECT count(*) INTO v_old FROM public.jobs j WHERE j.job_status <> 'archived' AND (j.title IS NULL OR j.title !~~* '%[OLD]%');
  SELECT count(*) INTO v_gap FROM public.jobs j WHERE j.job_status = 'destroyed' AND (j.title IS NULL OR j.title !~~* '%[OLD]%');
  IF v_new <> v_old - v_gap THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: view % rows, old predicate % rows, destroyed non-[OLD] jobs %', v_new, v_old, v_gap;
  END IF;
  -- 4. positive control on a job that IS offered: flip it to destroyed, it must leave the view; rolled back
  SELECT min(job_id) INTO v_fix FROM ops.client_service_options;
  IF v_fix IS NULL THEN RAISE EXCEPTION 'VERIFY 4 PRE FAILED: the view offers nothing, the control cannot run'; END IF;
  BEGIN
    UPDATE public.jobs SET job_status = 'destroyed' WHERE id = v_fix;
    IF EXISTS (SELECT 1 FROM ops.client_service_options WHERE job_id = v_fix) THEN
      RAISE EXCEPTION 'VERIFY 4 FAILED: job % is still offered after being destroyed', v_fix;
    END IF;
    RAISE EXCEPTION 'FIXTURE_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'FIXTURE_ROLLBACK' THEN RAISE; END IF;
  END;
  IF NOT EXISTS (SELECT 1 FROM ops.client_service_options WHERE job_id = v_fix) THEN
    RAISE EXCEPTION 'VERIFY 4b FAILED: the control fixture on job % did not roll back', v_fix;
  END IF;
  RAISE NOTICE 'ALL VERIFY PASSED: % rows offered, % destroyed job(s) hidden, grants unchanged, control job % leaves the view when destroyed.', v_new, v_gap, v_fix;
END
$verify$;

COMMIT;
