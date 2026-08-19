-- 2026-08-19_1200_client_job_activity_view.sql
--
-- WHAT: client.job_activity — the per-job activity trail for the Client App's new "Activity
--       history" modal (Fred, 2026-08-19: move the Cadence history out of the Edit-job dialog into
--       a 3-dot menu item that opens "a modal of the cadence history, and activity trail for that
--       specific job"). The cadence half already exists (client.job_frequency_changes); THIS view
--       is the activity-trail half, read from audit.logs.
--
-- WHY A FILTERED DIFF AND NOT RAW audit.logs ------------------------------------------------------
--       public.jobs is audited (rule-8 query: 1 trigger) with 1,253 rows, but the Jobber poll
--       re-writes job rows, so raw UPDATE rows include sync churn where nothing a user cares about
--       changed. Measured before writing this: 1,226 UPDATEs, of which 1,170 change at least one of
--       the seven columns the job card presents. The view therefore:
--         * keeps INSERT and DELETE rows always (27 of them — a job appearing or vanishing is
--           always signal), and
--         * keeps an UPDATE only when one of the TRACKED columns actually changed, emitting a
--           compact jsonb array of {field, old, new} for exactly those columns.
--       Tracked: frequency_days, job_status, title, start_at, end_at, billing_type,
--       invoice_frequency. Adding a column later = extend BOTH the lateral VALUES list and the
--       WHERE arm — they must stay identical twins.
--
-- ACTOR: COALESCE(jwt_claims->>'email', 'Changed in Jobber' for app_source='jobber', the app_source
--       otherwise, 'System'). ⚠ audit.logs.changed_by is NULL on every row ever written (the
--       trigger reads the singular request.jwt.claim.sub, which PostgREST never sets — documented
--       in Supabase/CLAUDE.md) — jwt_claims->>'email' is the only per-human attribution.
--       "Changed in Jobber" matches the Activity-tab wording precedent (2026-06-26b).
--
-- SECURITY: owner-rights view in the client schema (postgres-owned, NOT security_invoker), the same
--       laundering pattern as every client.* view — that is what lets authenticated read a filtered
--       slice of audit.logs without any grant on the audit schema. Granted to authenticated +
--       service_role only; anon gets nothing. Sibling control: client.status_changes.
--
-- AUDIT (rule 8): no table changed; this is a read-only view over audit.logs. Nothing to opt in.

begin;

create or replace view client.job_activity as
with tracked as (
  select
    l.id,
    (l.record_pk->>'id')::bigint            as job_id,
    l.changed_at,
    l.operation,
    l.app_source,
    coalesce(
      l.jwt_claims->>'email',
      case l.app_source
        when 'jobber' then 'Changed in Jobber'
        when 'sql'    then 'System'
        else nullif(l.app_source, '')
      end,
      'System')                             as actor,
    case when l.operation = 'UPDATE' then
      (select jsonb_agg(jsonb_build_object('field', t.field, 'old', t.o, 'new', t.n) order by t.field)
         from (values
           ('frequency_days',    l.old_row->>'frequency_days',    l.new_row->>'frequency_days'),
           ('job_status',        l.old_row->>'job_status',        l.new_row->>'job_status'),
           ('title',             l.old_row->>'title',             l.new_row->>'title'),
           ('start_at',          l.old_row->>'start_at',          l.new_row->>'start_at'),
           ('end_at',            l.old_row->>'end_at',            l.new_row->>'end_at'),
           ('billing_type',      l.old_row->>'billing_type',      l.new_row->>'billing_type'),
           ('invoice_frequency', l.old_row->>'invoice_frequency', l.new_row->>'invoice_frequency')
         ) as t(field, o, n)
        where t.o is distinct from t.n)
    end                                     as changes
  from audit.logs l
  where l.table_schema = 'public' and l.table_name = 'jobs'
)
select id, job_id, changed_at, operation, app_source, actor, changes
from tracked
where operation <> 'UPDATE' or changes is not null;

comment on view client.job_activity is
  'Per-job activity trail for the Client App Activity-history modal. UPDATEs are kept only when a tracked column really changed (the Jobber poll re-writes rows, so raw audit rows include sync churn). The tracked-column list appears TWICE in the body (VALUES + implicit via changes filter) - extend both together.';

-- client-schema grant pattern: authenticated + service_role, never anon
revoke all on client.job_activity from public, anon;
grant select on client.job_activity to authenticated, service_role;

-- ---- VERIFY ------------------------------------------------------------------------------------
do $$
declare
  v_sibling  aclitem[];
  v_mine     aclitem[];
  v_rows     int;
  v_meaning  int;
  v_anon     boolean;
  v_auth     boolean;
begin
  -- 1. the view returns rows, and every UPDATE row carries a non-empty changes array
  select count(*), count(*) filter (where operation='UPDATE' and jsonb_array_length(changes) >= 1)
    into v_rows, v_meaning from client.job_activity;
  if v_rows < 100 then raise exception 'VERIFY: expected hundreds of rows, got %', v_rows; end if;
  if v_meaning = 0 then raise exception 'VERIFY: no UPDATE row carries a change diff'; end if;

  -- 2. anon must have nothing; authenticated must have SELECT (the control proving the check works)
  select has_table_privilege('anon', 'client.job_activity', 'SELECT'),
         has_table_privilege('authenticated', 'client.job_activity', 'SELECT')
    into v_anon, v_auth;
  if v_anon then raise exception 'VERIFY: anon can read client.job_activity'; end if;
  if not v_auth then raise exception 'VERIFY: authenticated CANNOT read client.job_activity'; end if;

  raise notice 'VERIFY ok: % rows, % meaningful updates, anon=%, authenticated=%',
    v_rows, v_meaning, v_anon, v_auth;
end $$;

commit;
