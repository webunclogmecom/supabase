# Assembles docs/migrations/2026-09-15_1100_destroyed_jobs_are_terminal_everywhere.sql from the LIVE
# pg_get_viewdef / pg_get_functiondef bodies of the eleven objects that treated only job_status =
# 'archived' as terminal (dumped seconds before into <dump-dir>/<schema>_<name>.sql). Each body gets
# the same mechanical patch, `<> 'archived'` -> `NOT IN ('archived', 'destroyed')` (the left operand
# is untouched, so NULL semantics are exactly what they were), with the number of sites per object
# asserted; client.recurring_eligibility instead excludes destroyed jobs from its scope, because a
# deleted job is neither open nor reopenable. The md5 of every source body is pinned in the
# migration's PRE block. Nothing is retyped (CLAUDE.md, CREATE OR REPLACE rule).
# USE: python scripts/probes/assemble_destroyed_terminal_migration.py <dump-dir>
import hashlib, os, sys

root = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
mig = os.path.join(root, 'docs', 'migrations', '2026-09-15_1100_destroyed_jobs_are_terminal_everywhere.sql')
if len(sys.argv) < 2:
    sys.exit('usage: assemble_destroyed_terminal_migration.py <dump-dir>')
dump = sys.argv[1]

# (kind, qualified name, regprocedure/regclass identifier for the md5 and acl pins, expected sites)
OBJECTS = [
    ('function', 'client.fn_client_live_sa_jobs',  'client.fn_client_live_sa_jobs(bigint)',                    1),
    ('function', 'client.preview_job_action',      'client.preview_job_action(bigint,bigint,text)',            3),
    ('function', 'client.recurring_eligibility',   'client.recurring_eligibility(bigint)',                     1),
    ('function', 'client.update_client_status',    'client.update_client_status(bigint,text,text)',            1),
    ('function', 'ops.create_visit_request',       'ops.create_visit_request(bigint,bigint,bigint[],bigint,bigint[],text,text,jsonb,jsonb,bigint,bigint[])', 1),
    ('function', 'public.create_calendar_visit',   'public.create_calendar_visit(bigint,bigint,bigint[],date,bigint,bigint[],timestamptz,timestamptz,text,text,bigint,bigint,jsonb,bigint[],jsonb)', 1),
    ('function', 'public.fn_generate_sa_visits',   'public.fn_generate_sa_visits(bigint,integer,boolean)',     4),
    ('view',     'client.v_client_billing',        'client.v_client_billing',                                   1),
    ('view',     'customer.clients',               'customer.clients',                                          1),
    ('view',     'ops.client_jobs',                'ops.client_jobs',                                           1),
    ('view',     'public.v_sa_schedule_gaps',      'public.v_sa_schedule_gaps',                                 1),
]

OLD_T = "<> 'archived'::text"
NEW_T = "NOT IN ('archived'::text, 'destroyed'::text)"
OLD_P = "<> 'archived'"
NEW_P = "NOT IN ('archived', 'destroyed')"
ELIG_ANCHOR = "    from public.jobs j\n    where j.client_id = p_client_id\n  ),"
ELIG_NEW = ("    from public.jobs j\n    where j.client_id = p_client_id\n"
            "      and coalesce(j.job_status, '') <> 'destroyed'   -- 2026-09-15: a deleted job is neither open nor reopenable\n  ),")

HEADER = """-- ============================================================================================
-- 2026-09-15_1100_destroyed_jobs_are_terminal_everywhere.sql
--
-- A job Jobber has DELETED reaches us as job_status = 'destroyed' (JOB_DESTROY, webhook-jobber) and
-- only reads 'archived' once the */5 poll re-reads it, about 20 minutes later (08-21's job 1848).
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
"""

VERIFY = """DO $verify$
DECLARE v_body text; v_cid bigint; v_job bigint := 765; v_before jsonb; v_after jsonb; v_freq_before int; v_freq_after int; v_msg text;
BEGIN
  -- 1. structure: every object carries its destroyed sites and no bare `<> 'archived'` survives
@@STRUCTURAL@@
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
"""

parts, pre_lines, verify_struct, acl_rows = [], [], [], []
for kind, name, ident, sites in OBJECTS:
    path = os.path.join(dump, name.replace('.', '_') + '.sql')
    body = open(path, encoding='utf-8').read()
    md5 = hashlib.md5(body.encode('utf-8')).hexdigest()
    if 'destroyed' in body:
        sys.exit(f'{name}: source body already mentions destroyed')
    if name == 'client.recurring_eligibility':
        if body.count(ELIG_ANCHOR) != 1:
            sys.exit(f'{name}: scope anchor occurs {body.count(ELIG_ANCHOR)} times')
        patched = body.replace(ELIG_ANCHOR, ELIG_NEW)
    else:
        n_t = body.count(OLD_T)
        n_p = body.count(OLD_P) - n_t
        if n_t + n_p != sites:
            sys.exit(f'{name}: found {n_t}+{n_p} archived predicates, expected {sites}')
        patched = body.replace(OLD_T, NEW_T).replace(OLD_P, NEW_P)
    if patched.count("'destroyed'") != sites:
        sys.exit(f'{name}: patched body carries {patched.count(chr(39) + "destroyed" + chr(39))} destroyed sites, expected {sites}')
    if kind == 'view':
        stmt = f"CREATE OR REPLACE VIEW {name} AS\n{patched.rstrip().rstrip(';')};"
        getdef = f"pg_get_viewdef('{ident}'::regclass, false)"
        aclsel = f"(SELECT relacl::text FROM pg_class WHERE oid = '{ident}'::regclass)"
    else:
        stmt = patched.rstrip().rstrip(';') + ';'
        getdef = f"pg_get_functiondef('{ident}'::regprocedure)"
        aclsel = f"(SELECT proacl::text FROM pg_proc WHERE oid = '{ident}'::regprocedure)"
    parts.append(f"-- ---- {kind} {name} ({sites} site{'s' if sites != 1 else ''}) ----\n{stmt}\n")
    pre_lines.append(f"  IF md5({getdef}) <> '{md5}' THEN RAISE EXCEPTION 'PRE: {name} is not the body this file was patched from'; END IF;")
    verify_struct.append(
        f"  v_body := {getdef};\n"
        f"  IF (length(v_body) - length(replace(v_body, '''destroyed''', ''))) / length('''destroyed''') <> {sites}"
        f" OR v_body LIKE '%<> ''archived''%' THEN\n"
        f"    RAISE EXCEPTION 'VERIFY 1 FAILED: {name} does not carry exactly {sites} destroyed site(s), or a bare archived predicate survived';\n  END IF;")
    acl_rows.append(f"  SELECT '{name}'::text, {aclsel}")

sql = HEADER + "BEGIN;\n\n"
sql += "CREATE TEMP TABLE _dj_pre (obj, acl) ON COMMIT DROP AS\n" + "\n  UNION ALL\n".join(acl_rows) + ";\n\n"
sql += "DO $pre$\nBEGIN\n" + "\n".join(pre_lines) + "\nEND\n$pre$;\n\n"
sql += ("-- --------------------------------------------------------------------------------------------\n"
        "-- PART 1. The eleven bodies, each spliced from its live definition.\n"
        "-- --------------------------------------------------------------------------------------------\n")
sql += "\n".join(parts)
sql += ("\n-- --------------------------------------------------------------------------------------------\n"
        "-- VERIFY\n"
        "-- --------------------------------------------------------------------------------------------\n")
sql += VERIFY.replace('@@STRUCTURAL@@', "\n".join(verify_struct))
sql += "\nCOMMIT;\n"
open(mig, 'w', encoding='utf-8', newline='\n').write(sql)
print('assembled', mig, f'({len(OBJECTS)} objects, {sum(o[3] for o in OBJECTS)} sites)')
