-- =====================================================================================
-- 2026-09-09_1520  Two prerequisites for the Calendar/Jobber last-writer-wins rule
--   1. public.fn_request_jobber_push  gains p_changed  (so an LWW push touches ONLY the schedule)
--   2. public.fn_is_office_schedule_write  (new)       (so "our clock" cannot be read off a
--                                                       Jobber-adoption write)
-- =====================================================================================
-- BOTH ARE INERT. The new parameter defaults to today's exact hardcoded value, so every existing
-- two-argument caller produces a byte-identical request body. The classifier is a new function that
-- nothing calls yet. Behaviour changes only when the decision rule ships and starts passing them.
--
-- WHY 1 -- fn_request_jobber_push CANNOT KEEP HARDCODING THE FIELD GROUPS ---------------
-- Its body hardcodes body.changed = '["schedule","title","lineitems"]'. That was written for the
-- HEAL re-assert, where re-pushing the whole safe-idempotent set is harmless. It is NOT harmless for
-- a last-writer-wins push, which is a decision about a START TIME and has no authority over the
-- visit's title or its line items.
--
-- Measured over the 116 visits the drift reconciler touched in 45 days:
--   * 110 carry line_items rows;
--   * 80 carry at least one line with unit_price > 0 or a non-empty description, so the 2026-08-03
--     zero-dollar no-op guard does NOT skip them;
--   * 116 of 116 carry a non-empty title.
-- And syncVisitLineItems mints new SHARED JobLineItem objects on the job, which is the permanent
-- residue that has already been reported on 15 jobs. So the blast radius is real today, at 5 heals
-- in 45 days; it is a correctness fix, not a volume fix, but it must land BEFORE anything increases
-- the number of reconciler-driven pushes.
--
-- ⚠ The DEFAULT deliberately reproduces the current hardcoded value rather than narrowing it. The
--   HEAL path's re-assert semantics are unchanged and out of scope for this migration. Narrowing the
--   default would silently change HEAL behaviour, which is a separate decision with its own incident
--   history (152-DAV, 2026-07-02).
-- ⚠ 'crew' and 'notes' stay OUT of the default, exactly as before: they are empty-clobber-prone and
--   the edge function's strict gate must only ever push them on a deliberate office edit.
--
-- WHY 2 -- "OUR CLOCK" IS CURRENTLY READ OFF WRITES THAT ARE NOT OURS -------------------
-- public.visit_last_schedule_edit answers "when did WE last change this visit's schedule", and it
-- excludes exactly ONE value: app_source = 'jobber'. Everything else counts as an office edit,
-- including three writers that are actually adopting JOBBER's value:
--
--   writer                            schedule writes / visits (45d)   what it really is
--   ---------------------------------------------------------------------------------------------
--   adopt-visit-from-jobber           9 writes / 8 visits              a human clicking "Sync from
--                                     (app_source 'sql', origin NULL)  Jobber". Its own file header
--                                                                      claims app_source='jobber';
--                                                                      it does not send the header.
--   jobber-daily-completion-reconcile 67 writes / 64 visits            adopts Jobber's time at
--                                                                      completion
--   jobber-daily-anomaly-reconcile    8 writes / 6 visits              adopts Jobber's value
--   drift-adopt-diego-2026-07-29      2 writes / 2 visits              a one-off adopt backfill
--
-- Live consequence, visit 6729: a human adopted Jobber's schedule on 2026-09-08 12:48 ET, the write
-- audited as 'sql', visit_last_schedule_edit read it back as an office edit, and the card re-surfaced
-- 33 more times. An adoption being mistaken for an office edit is self-defeating in the most literal
-- way: the act of resolving the conflict is what makes it unresolvable.
--
-- 🛑 DENY-LIST, NOT ALLOW-LIST, AND THE DIRECTION MATTERS.
--   Deny-list: an UNKNOWN writer counts as an office edit -> blocks the auto-adopt -> the card
--     surfaces to a human. Fails SAFE.
--   Allow-list: an unknown or renamed office RPC would look like "we never edited it" -> auto-adopt
--     -> an office edit silently overwritten by Jobber. Fails UNSAFE.
--   So a new writer nobody classifies degrades to today's behaviour, never to data loss.
--
-- 🛑 `sql` IS NOT BLANKET-EXCLUDED. It covers both the manual adopt AND genuine raw-SQL office
--   fixes. The adopt is separated by request_context->>'path', which is the more durable of the
--   three attribution signals: app_source rides on a per-client header that can vanish on a rebuild,
--   and the Origin CASE breaks on a domain move (232 rows once landed as other:review.unclogme.app
--   for 26 days). A raw-SQL office fix has a NULL path and stays counted as ours, which is the safe
--   direction.
--
-- ⚠ THIS MIGRATION DOES NOT REWIRE visit_last_schedule_edit. Doing so would change the LIVE
--   reconciler's behaviour immediately: a visit whose only non-jobber schedule write was an adopt
--   would fall into the never-edited branch and start auto-adopting. That change ships WITH the
--   decision rule, after shadow mode, not ahead of it.
--
-- AUDIT (rule 8): no table changed. Functions only.
-- REVERSIBLE: yes. Drop fn_is_office_schedule_write; restore fn_request_jobber_push's two-argument
--   body (kept verbatim in this header's WHY 1 section and in git).
-- =====================================================================================

begin;

-- ------------------------------------------------------------------------------------
-- 1. fn_request_jobber_push gains p_changed.
--    Body is the live pg_get_functiondef output with the hardcoded jsonb literal lifted into a
--    defaulted parameter. Nothing else is touched.
--
-- 🛑 DROP THEN CREATE, NOT `CREATE OR REPLACE`. Adding a defaulted parameter makes a NEW signature,
--    it does not replace the old one, so both would exist and a two-argument call would become
--    AMBIGUOUS: Postgres raises "function is not unique", and PostgREST (which resolves overloads by
--    the set of named arguments in the JSON body) would fail to choose a candidate. Both live
--    callers use PostgREST with {p_visit_id, p_op}:
--      supabase/functions/push-visit-to-jobber/index.ts:135
--      supabase/functions/sync-jobber-visit-drift/index.ts:310
--    Leaving the overload in place would break the "Keep Calendar's schedule" button and the HEAL
--    path simultaneously.
-- ⚠ DROP DISCARDS GRANTS (same trap as DROP VIEW). Measured before the drop, the ACL is
--   {postgres=X/postgres, service_role=X/postgres}; it is re-granted explicitly below and asserted
--   in VERIFY. The function is service_role-only by design (Phase 3 revoked the lifecycle RPCs from
--   authenticated) and must not come back wider.
-- ------------------------------------------------------------------------------------
drop function if exists public.fn_request_jobber_push(bigint, text);

create or replace function public.fn_request_jobber_push(
  p_visit_id bigint,
  p_op       text  default 'upsert'::text,
  p_changed  jsonb default '["schedule","title","lineitems"]'::jsonb
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE v_key text;
BEGIN
  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'jobber_push_service_key';
  IF v_key IS NULL THEN RAISE WARNING 'jobber_push_service_key vault secret missing; skipping push for visit %', p_visit_id; RETURN; END IF;
  -- p_changed defaults to the SAFE-IDEMPOTENT groups (schedule/title/lineitems), which is what this
  -- function hardcoded before 2026-09-09_1520, so a two-argument call is byte-identical to before.
  -- crew+notes stay excluded: empty-clobber-prone; the edge fn's strict gate must only ever push
  -- them on a deliberate edit.
  -- A last-writer-wins push passes '["schedule"]': it is a decision about a start time and has no
  -- authority over the title or the line items (syncVisitLineItems mints shared JobLineItem objects
  -- on the job, and 80 of the 116 visits the reconciler touched in 45 days carry priced lines).
  PERFORM net.http_post(
    url     := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/jobber-push-visit',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||v_key),
    body    := jsonb_build_object('op', p_op, 'visit_id', p_visit_id, 'changed', coalesce(p_changed, '["schedule","title","lineitems"]'::jsonb)));
END; $function$;

-- Re-grant: the DROP above discarded the old ACL. service_role only, as measured before the drop
-- ({postgres=X/postgres, service_role=X/postgres}).
--
-- 🛑 `REVOKE FROM PUBLIC` IS NOT ENOUGH AND THIS MIGRATION PROVED IT ON ITSELF.
--    public carries TWO default ACLs for FUNCTIONS:
--      {postgres=X/supabase_admin, anon=X/supabase_admin, authenticated=X/supabase_admin, service_role=X/supabase_admin}
--      {postgres=X/postgres,       authenticated=X/postgres,                               service_role=X/postgres}
--    so a bare CREATE FUNCTION here is born with EXECUTE granted to NAMED roles, and revoking from
--    PUBLIC does not touch a named grant. The first run of this migration re-created the push RPC
--    with authenticated=X/postgres, widening a function that had been service_role-only since the
--    Phase 3 lockdown. Its own VERIFY caught it (V3), which is the only reason it is not live.
--    Revoke BY NAME, and assert with has_function_privilege rather than by reading the ACL string.
revoke all on function public.fn_request_jobber_push(bigint, text, jsonb) from public, anon, authenticated;
grant execute on function public.fn_request_jobber_push(bigint, text, jsonb) to service_role;

-- ------------------------------------------------------------------------------------
-- 2. The office-writer classifier. ONE definition, so the rule and its control cannot diverge.
-- ------------------------------------------------------------------------------------
create or replace function public.fn_is_office_schedule_write(p_app_source text, p_path text)
returns boolean
language sql
immutable
as $function$
  -- TRUE  = a write that expresses OUR intent (the office / the Calendar / a raw-SQL fix by us).
  -- FALSE = a write that ADOPTS Jobber's value, and therefore says nothing about when we last
  --         decided anything.
  -- Deny-list on purpose: an unclassified writer returns TRUE and merely blocks an auto-adopt.
  select not (
       coalesce(p_app_source,'') = 'jobber'                 -- inbound sync + reconciler adopts
    or coalesce(p_app_source,'') like 'jobber-%'            -- jobber-daily-completion-reconcile,
                                                            -- jobber-daily-anomaly-reconcile
    or coalesce(p_app_source,'') like 'drift-adopt%'        -- the 2026-07-29 one-off adopt backfill
    or coalesce(p_path,'')      like '/rpc/adopt_visit_schedule_from_jobber%'  -- the manual button,
                                                            -- which audits as 'sql' with a NULL origin
  );
$function$;

comment on function public.fn_is_office_schedule_write(text, text) is
  'TRUE when an audit.logs schedule write expresses OUR intent rather than adopting Jobber''s value. Deny-list by design: an unknown writer returns TRUE, which fails safe (blocks an auto-adopt) rather than unsafe (overwrites an office edit). See migration 2026-09-09_1520.';

-- By name, for the reason spelled out on the push RPC above: public's default ACLs for functions
-- grant EXECUTE to anon/authenticated/service_role, and REVOKE FROM PUBLIC leaves those untouched.
revoke all on function public.fn_is_office_schedule_write(text, text) from public, anon, authenticated;
grant execute on function public.fn_is_office_schedule_write(text, text) to service_role;

commit;
