-- 2026-08-19_1330_line_items_audit_and_job_activity_v2.sql
--
-- WHAT: (1) OPT public.line_items INTO audit.logs (rule 8), and (2) widen client.job_activity into
--       the full per-job trail Fred asked for: "all the changes done to the respective job, and who
--       did it ... Frequency ... Services: Line items added or removed, quantity or prices ...
--       (this includes the fees) ... Start date ... Billing ... Instructions ... etc".
--
-- RULE-8 OPT-IN, stated explicitly ------------------------------------------------------------
--       public.line_items had NO audit trigger and 0 audit rows (measured before this migration).
--       It is billing-adjacent and human-edited (save-client-job adds/reprices/removes service and
--       fee lines), which is squarely the "tables with human-editable fields -> opt-in" default.
--       ⚠ CONSEQUENCE: the services half of the trail is FORWARD-ONLY. No line-item change made
--       before this migration exists anywhere, and the UI says so.
--       ⚠ VOLUME: the trigger captures ALL line_items writes, including visit-scoped churn from
--       webhook-jobber and the 30-min drift reconciler (which expresses a Jobber-side line change
--       as DELETE+INSERT, not UPDATE - the trail renders that truthfully as removed+added). The
--       VIEW filters to job-scoped rows (visit_id IS NULL); the TABLE captures everything, which is
--       what an audit is for.
--
-- THE JOBS ARM gains `notes`, emitted as field 'instructions': Jobber's `instructions` is stored in
--       our jobs.notes (webhook-jobber:575 `notes: j.instructions ?? null`), and the app labels it
--       Instructions - emitting the storage name would read as a different feature.
--
-- SHAPE: both arms emit (id, job_id, changed_at, operation, app_source, actor, kind, label, changes).
--       kind = 'job' | 'line_item'; label = the line item's name (null on job rows). The app renders
--       unknown fields raw, so the line-item arm emits display-ready field names.
--
-- ⚠ THE TRACKED-COLUMN LIST FOR JOBS APPEARS ONCE (the VALUES list); the line-item diff list
--       likewise. Extend them here, never by re-filtering in the app.
--
-- AUDIT (rule 8): line_items OPTED IN by this migration (the point of it). No other table changed.

begin;

-- PART 1: the audit trigger (naming per ADR 010: audit_<table>)
create trigger audit_line_items
  after insert or update or delete on public.line_items
  for each row execute function audit.log_change();

-- PART 2: the widened view.
-- ⚠ DROP-then-CREATE, not OR REPLACE: the new columns (kind, label) sit before `changes`, and
--   CREATE OR REPLACE VIEW cannot reorder/insert columns (42P16). DROP VIEW DISCARDS GRANTS
--   (memory: reference_drop_view_discards_grants) — the explicit re-grant below is load-bearing.
drop view client.job_activity;
create view client.job_activity as
with job_rows as (
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
    'job'::text                             as kind,
    null::text                              as label,
    case when l.operation = 'UPDATE' then
      (select jsonb_agg(jsonb_build_object('field', t.field, 'old', t.o, 'new', t.n) order by t.field)
         from (values
           ('frequency_days',    l.old_row->>'frequency_days',    l.new_row->>'frequency_days'),
           ('job_status',        l.old_row->>'job_status',        l.new_row->>'job_status'),
           ('title',             l.old_row->>'title',             l.new_row->>'title'),
           ('start_at',          l.old_row->>'start_at',          l.new_row->>'start_at'),
           ('end_at',            l.old_row->>'end_at',            l.new_row->>'end_at'),
           ('billing_type',      l.old_row->>'billing_type',      l.new_row->>'billing_type'),
           ('invoice_frequency', l.old_row->>'invoice_frequency', l.new_row->>'invoice_frequency'),
           ('instructions',      l.old_row->>'notes',             l.new_row->>'notes')
         ) as t(field, o, n)
        where t.o is distinct from t.n)
    end                                     as changes
  from audit.logs l
  where l.table_schema = 'public' and l.table_name = 'jobs'
),
line_rows as (
  select
    l.id,
    (coalesce(l.new_row, l.old_row)->>'job_id')::bigint as job_id,
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
    'line_item'::text                       as kind,
    coalesce(l.new_row->>'name', l.old_row->>'name') as label,
    case l.operation
      when 'INSERT' then jsonb_build_array(jsonb_build_object(
        'field', 'Line item added', 'old', null,
        'new', coalesce(l.new_row->>'quantity','1') || ' × $' || coalesce(l.new_row->>'unit_price','0')))
      when 'DELETE' then jsonb_build_array(jsonb_build_object(
        'field', 'Line item removed',
        'old', coalesce(l.old_row->>'quantity','1') || ' × $' || coalesce(l.old_row->>'unit_price','0'),
        'new', null))
      else
        (select jsonb_agg(jsonb_build_object('field', t.field, 'old', t.o, 'new', t.n) order by t.field)
           from (values
             ('Name',        l.old_row->>'name',        l.new_row->>'name'),
             ('Description', l.old_row->>'description', l.new_row->>'description'),
             ('Quantity',    l.old_row->>'quantity',    l.new_row->>'quantity'),
             ('Unit price',  l.old_row->>'unit_price',  l.new_row->>'unit_price')
           ) as t(field, o, n)
          where t.o is distinct from t.n)
    end                                     as changes
  from audit.logs l
  where l.table_schema = 'public' and l.table_name = 'line_items'
    -- job-scoped lines only: the job's services and fees. Visit-scoped items belong to visits.
    and (coalesce(l.new_row, l.old_row)->>'visit_id') is null
    and (coalesce(l.new_row, l.old_row)->>'job_id') is not null
)
select id, job_id, changed_at, operation, app_source, actor, kind, label, changes
from (
  select * from job_rows
  union all
  select * from line_rows
) u
where operation <> 'UPDATE' or changes is not null;

comment on view client.job_activity is
  'Per-job trail for the Client App Activity-history modal. kind=job rows diff 8 tracked job columns (notes is emitted as instructions); kind=line_item rows cover the job-scoped service/fee lines - FORWARD-ONLY from 2026-08-19, when line_items was opted into audit. The reconciler expresses a Jobber-side line change as DELETE+INSERT; the trail shows that truthfully as removed+added.';

revoke all on client.job_activity from public, anon;
grant select on client.job_activity to authenticated, service_role;

-- ---- VERIFY ------------------------------------------------------------------------------------
do $$
declare v_trg int; v_rows int; v_anon boolean; v_auth boolean;
begin
  select count(*) into v_trg
    from pg_trigger t join pg_class c on c.oid=t.tgrelid
    join pg_proc p on p.oid=t.tgfoid join pg_namespace pn on pn.oid=p.pronamespace
   where pn.nspname='audit' and p.proname='log_change' and not t.tgisinternal and c.relname='line_items';
  if v_trg <> 1 then raise exception 'VERIFY: line_items audit trigger count = %', v_trg; end if;

  select count(*) into v_rows from client.job_activity;
  if v_rows < 100 then raise exception 'VERIFY: expected hundreds of rows, got %', v_rows; end if;

  select has_table_privilege('anon','client.job_activity','SELECT'),
         has_table_privilege('authenticated','client.job_activity','SELECT') into v_anon, v_auth;
  if v_anon then raise exception 'VERIFY: anon can read'; end if;
  if not v_auth then raise exception 'VERIFY: authenticated cannot read'; end if;

  raise notice 'VERIFY ok: trigger=1, rows=%, anon=false, authenticated=true', v_rows;
end $$;

commit;
