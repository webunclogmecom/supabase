-- ============================================================================
-- 2026-09-08_0200_document_sa_gate_ignores_job_status.sql
--
-- COMMENT ONLY. No behaviour changes. Nothing in this file alters a predicate.
--
-- Fred, 2026-09-08: "fix the archived job gate too", after I reported that
-- client.fn_is_current_sa_job never checks job_status and claimed a client could
-- therefore be set RECURRING on an archived Service Agreement.
--
-- 🛑 THAT REPORT WAS WRONG, AND THE FIX WOULD HAVE BROKEN A REAL FEATURE.
--    I measured the gate in isolation and inferred a system hole without checking
--    its callers. Every caller applies the job_status filter itself:
--
--      client.update_client_status(bigint,text,text)
--        the WRITE path. Its RECURRING guard is
--          exists (select 1 from public.jobs j
--                   where j.client_id = p_client_id
--                     and j.job_status <> 'archived'          <-- already there
--                     and client.fn_is_current_sa_job(j.id))
--        and it raises 23514 otherwise.
--
--      client.recurring_eligibility(bigint)
--        DELIBERATELY calls the gate WITHOUT a status filter, then splits the result:
--          open_eligible         = eligible and not is_closed   -> settable now
--          closed_eligible       = eligible and     is_closed   -> must be REOPENED first
--          legacy_closed_count   = is_closed and not eligible   -> context only
--          can_set_recurring_now = exists(eligible and not is_closed)
--        Filtering archived INSIDE the gate would empty closed_eligible, and the
--        documented two-step for reusing a closed agreement (reopen via the
--        save-client-job edge fn, verify, then set the status) would have no way to
--        offer the job. See Building Apps/Client App/CLAUDE.md section 2e.
--
--      client.fn_client_live_sa_jobs(bigint)
--        added 2026-09-08_0100; filters archived itself, on purpose.
--
--    Measured proof, 2026-09-08:
--      117-BH  write_path_allows_recurring = FALSE, can_set_recurring_now = FALSE,
--              open_eligible = 0, closed_eligible = 1   (its only passing job, 1864,
--              is archived -- so it is offered for REOPENING, never set directly)
--      241-WYN write_path_allows_recurring = TRUE,  can_set_recurring_now = TRUE,
--              open_eligible = 1, closed_eligible = 0   (positive control)
--
-- ⇒ THE CONTRACT IS: fn_is_current_sa_job answers "is this job's SHAPE a current-format
--   Service Agreement?" -- frequency, title and a coded pumping/cleaning line. It says
--   NOTHING about whether the job is open, and it MUST NOT, because one caller needs the
--   closed ones. Callers decide open vs closed.
--
--   This migration writes that contract into the function comment so the next reader does
--   not repeat my mistake. 10 archived jobs currently pass the gate; that is correct.
--
-- Audit: N/A (comment only).
-- ============================================================================

begin;

comment on function client.fn_is_current_sa_job(bigint) is
  'Is this job SHAPED like a current-format Service Agreement? Tests frequency_days > 0, '
  'title Service Agreement% and not [OLD]/TEST, and at least one unbilled, unassigned line '
  'item in the pumping or cleaning billing group (so warranty-only code 08 never qualifies). '
  'INTENTIONALLY IGNORES job_status: client.recurring_eligibility needs the ARCHIVED matches '
  'to populate closed_eligible, which drives the documented reopen-then-set-status flow. '
  'CALLERS MUST APPLY THEIR OWN job_status FILTER. client.update_client_status and '
  'client.fn_client_live_sa_jobs both add job_status <> archived. Do not add a status test '
  'here: it would empty closed_eligible and make a closed agreement impossible to reuse. '
  '(2026-09-08: a report that this was a security hole was wrong; see migration _0200.)';

commit;

-- ---------------------------------------------------------------------------
-- VERIFY. Asserts the comment landed AND that the behaviour is untouched, with a
-- control that must differ from the subject.
-- ---------------------------------------------------------------------------
do $verify$
declare
  v_117 bigint; v_241 bigint; v_comment text; v_archived_passing int;
begin
  select id into v_117 from public.clients where client_code = '117-BH';
  select id into v_241 from public.clients where client_code = '241-WYN';
  if v_117 is null or v_241 is null then
    raise exception 'VERIFY 0 FAILED: fixture client missing';
  end if;

  -- 1. the comment is present and names the contract
  select obj_description('client.fn_is_current_sa_job(bigint)'::regprocedure, 'pg_proc')
    into v_comment;
  if v_comment is null or v_comment !~ 'CALLERS MUST APPLY THEIR OWN' then
    raise exception 'VERIFY 1 FAILED: contract comment missing from fn_is_current_sa_job';
  end if;

  -- 2. BEHAVIOUR UNCHANGED: archived jobs must STILL pass the shape gate, or the reopen
  --    flow is broken. This asserts the thing I was asked to "fix" stays as it is.
  select count(*) into v_archived_passing
    from public.jobs j
   where coalesce(j.job_status,'') = 'archived' and client.fn_is_current_sa_job(j.id);
  if v_archived_passing = 0 then
    raise exception 'VERIFY 2 FAILED: no archived job passes the gate; closed_eligible is now dead';
  end if;

  -- 3. the write path still REFUSES 117-BH (archived-only agreement)
  if exists (select 1 from public.jobs j
              where j.client_id = v_117 and j.job_status <> 'archived'
                and client.fn_is_current_sa_job(j.id)) then
    raise exception 'VERIFY 3 FAILED: 117-BH would be allowed to go RECURRING';
  end if;

  -- 4. CONTROL on the same expression: 241-WYN must still be ALLOWED. Without this,
  --    assertion 3 passes just as well if the gate returns false for everyone.
  if not exists (select 1 from public.jobs j
                  where j.client_id = v_241 and j.job_status <> 'archived'
                    and client.fn_is_current_sa_job(j.id)) then
    raise exception 'VERIFY 4 FAILED (control): 241-WYN should be allowed to go RECURRING';
  end if;

  -- 5. the app-facing split still behaves: 117-BH offered as CLOSED, not settable now
  if (client.recurring_eligibility(v_117)->>'can_set_recurring_now')::boolean then
    raise exception 'VERIFY 5a FAILED: app says 117-BH can be set RECURRING now';
  end if;
  if jsonb_array_length(client.recurring_eligibility(v_117)->'closed_eligible') = 0 then
    raise exception 'VERIFY 5b FAILED: 117-BH lost its closed_eligible offer';
  end if;

  raise notice 'VERIFY ok: contract documented; % archived jobs still pass the shape gate; 117-BH refused and offered as closed; 241-WYN allowed',
    v_archived_passing;
end
$verify$;
