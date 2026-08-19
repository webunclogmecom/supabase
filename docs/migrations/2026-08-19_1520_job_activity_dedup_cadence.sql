-- 2026-08-19_1520_job_activity_dedup_cadence.sql
--
-- WHAT: dedup rule for the Client App's UNIFIED activity stream (Fred: "Merge the Cadence History
--       with Activity, and just put Activity, and with an sorted order by date ... show it all").
--
-- THE DUPLICATE: an app-made frequency change is recorded TWICE — a rich row in
--       public.job_frequency_changes (reason, proof, changed_by_email) AND a jobs-audit UPDATE row
--       diffing frequency_days. A merged stream would show every cadence event twice.
--
-- THE RULE, and why it is EXISTENCE-based rather than source- or era-based ------------------------
--       Measured before writing this: of 22 client-app frequency audit rows, only 15 have a cadence
--       sibling — job_frequency_changes only exists since 2026-08-07, so earlier app changes are
--       audit-only. Dropping "all client-app frequency diffs" would therefore hide 7 real changes.
--       The exact rule: drop the frequency_days ENTRY from a jobs-audit diff IFF a
--       job_frequency_changes row exists for the same job within ±10 seconds (the RPC and the audit
--       trigger write in the same transaction, sub-second apart; the closest distinct real changes
--       observed are minutes apart). Jobber-side and pre-2026-08-07 frequency changes keep their
--       audit diff — they have no richer record.
--       If the diff array becomes empty after the drop, the existing `changes is not null` filter
--       removes the row entirely (that audit row carried nothing but the deduped field).
--
-- BODY: pg_get_viewdef of the live view was NOT retyped — this file re-states the full definition
--       from 2026-08-19_1330 with ONE added predicate in the jobs-arm diff WHERE. Diffed by eye
--       against the prior migration file; every other byte identical.
--
-- AUDIT (rule 8): view change only, no table touched. Grants re-stated because this is
--       CREATE OR REPLACE (no column changes this time, so OR REPLACE is legal and keeps grants —
--       re-granting anyway costs nothing and protects a future DROP-path edit).

begin;

create or replace view client.job_activity as
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
        where t.o is distinct from t.n
          -- DEDUP vs the cadence record: existence-based, era- and source-independent
          and not (t.field = 'frequency_days' and exists (
                select 1 from public.job_frequency_changes f
                 where f.job_id = (l.record_pk->>'id')::bigint
                   and f.changed_at between l.changed_at - interval '10 seconds'
                                        and l.changed_at + interval '10 seconds')))
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
  'Per-job trail for the Client App unified Activity stream. Frequency diffs are SUPPRESSED when a job_frequency_changes sibling exists within 10s (that row is the richer record: reason, proofs, email) - existence-based dedup, so Jobber-side and pre-2026-08-07 frequency changes keep their diff. line_item rows are forward-only from 2026-08-19.';

revoke all on client.job_activity from public, anon;
grant select on client.job_activity to authenticated, service_role;

-- ---- VERIFY ------------------------------------------------------------------------------------
do $$
declare v_dup int; v_kept int; v_rows int;
begin
  -- 1. job 765 (test client): its app-made cadence flip-flops must have NO frequency diff left
  select count(*) into v_dup from client.job_activity
   where job_id = 765 and kind='job'
     and changes @> '[{"field":"frequency_days"}]'::jsonb
     and exists (select 1 from public.job_frequency_changes f
                  where f.job_id = 765
                    and f.changed_at between client.job_activity.changed_at - interval '10 seconds'
                                         and client.job_activity.changed_at + interval '10 seconds');
  if v_dup > 0 then raise exception 'VERIFY: % duplicated frequency rows survive on job 765', v_dup; end if;

  -- 2. CONTROL: frequency diffs WITHOUT a cadence sibling must still exist somewhere
  --    (the 7 pre-2026-08-07 app changes and any Jobber-side ones) - a zero here means the
  --    dedup over-deleted and the instrument is broken
  select count(*) into v_kept from client.job_activity
   where kind='job' and changes @> '[{"field":"frequency_days"}]'::jsonb;
  if v_kept = 0 then raise exception 'VERIFY: dedup removed ALL frequency diffs - over-broad'; end if;

  select count(*) into v_rows from client.job_activity;
  raise notice 'VERIFY ok: 0 duplicated freq rows on 765, % sibling-less freq diffs kept, % total rows',
    v_kept, v_rows;
end $$;

commit;
