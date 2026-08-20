-- 2026-08-20_0020_gdo_report_activity_and_actor_marker_check.sql
--
-- WHAT: (1) a CHECK that makes "the bot filed it" and "a person filed it" mutually exclusive at the
--       DATABASE level instead of by convention, and (2) derm.gdo_report_activity, an event-grained
--       activity trail over audit.logs saying WHO touched each GDO report and WHEN.
--
-- WHY:  Fred, 2026-08-19: "this is for an activity trail later on, where it was done by the Report
--       bot of Jon, or by a person on the DERM App" -> "yes build it, with the check constraint too".
--
-- ============================ WHAT THE AUDIT FOUND FIRST ============================
-- 1. THE ROW CANNOT BE THE TRAIL. public.derm_portal_submissions.filed_by_email is written at INSERT
--    and never updated, so it answers "who FILED this" and nothing else. Four human corrections
--    already exist (fred@ayache.com x3 to 2026-08-06, contact@unclogme.com x1 on 2026-08-13, all via
--    app_source='derm-tracker') and those rows STILL read as pure bot filings if you only look at the
--    table. The people are visible only in audit.logs. Hence a view over audit.logs, not over the row.
--
-- 2. 🛑 A TWO-WAY BOT/PERSON SPLIT WOULD BE WRONG. There is a THIRD writer. Measured over all 670
--    audit rows for this table:
--        gdo-report-bot   544 INSERT
--        derm-tracker       4 UPDATE   (the two humans above)
--        sql              122          (23 INSERT + 67 UPDATE + 32 DELETE)
--    The `sql` bucket is our own backend work, and its 67 UPDATEs touch portal_confirmation,
--    failure_reason, attempted_at and screenshot_path -- THE SAME FIELDS a human correction touches.
--    A view with only two buckets would either mislabel those 122 events as a person or drop them.
--    ⚠ `sql` is the FALLBACK label (no app header, no matching Origin), so the view says
--      "backend maintenance" and never invents a name for it.
--
-- 3. THERE IS A FOURTH BUCKET ON PURPOSE, AND IT IS EMPTY TODAY. `unattributed` catches a row that is
--    neither the bot, nor a named person, nor `sql`. It is 0 right now. It exists because app_source
--    is derived from a header hint with an Origin CASE as backup, and BOTH can go stale silently (a
--    rebuild drops the header, a domain move breaks the CASE -- see CLAUDE.md, the 232-row
--    `other:review.unclogme.app` incident). Bucketing an unknown as `system` would hide exactly that.
--
-- ============================ THE CHECK, AND WHY IT IS AN IMPOSSIBILITY NOW ============================
-- Before this migration the bot/person distinction held because of how the two write paths are built,
-- NOT because the database forbade the alternative:
--   * rpa-derm-result/index.ts picks body fields off an explicit allow-list that does not contain
--     filed_by_email, so the bot cannot forge a human filing.
--   * fn_record_manual_gdo_report RAISEs unless filed_by_email is non-blank AND
--     run_id ~ '^manual-[A-Za-z0-9_.-]{1,90}$'.
-- That is a convention. It would stop holding SILENTLY the day someone adds filed_by_email to that
-- allow-list. For a record of who touched a compliance filing, the two markers must be unable to
-- disagree, so the pairing is now a constraint.
--
-- ✅ MUTATION-TESTED BEFORE SHIPPING, four arms, rolled back, all against a REAL visit id so a FK
--    abort could not make a rejection look like a pass:
--        A  no email + 'probe-bot-a'      -> PASSED    (bot shape)
--        B  email    + 'manual-probe-b'   -> PASSED    (person shape)
--        C  email    + 'probe-bot-c'      -> REJECTED 23514   (forged person)
--        D  no email + 'manual-probe-d'   -> REJECTED 23514   (anonymous manual)
--    A/C and B/D are DIFFERENTIAL PAIRS whose only difference is filed_by_email, which is what proves
--    this constraint fired and not one of the six pre-existing CHECKs on the table.
-- ✅ 0 of 535 existing rows violate it, so the ALTER validates without touching data.
--
-- AUDIT (rule 8): derm_portal_submissions IS audited (audit_derm_portal_submissions) and stays so.
--    No column added, no data rewritten: one CHECK and one view.

begin;

-- ---- 1. the constraint --------------------------------------------------------------------------
-- run_id is NOT NULL today; the coalesce is deliberate belt-and-braces, because if the column were
-- ever made nullable then `run_id LIKE 'manual-%'` would evaluate to NULL, the comparison would be
-- NULL, and a CHECK is satisfied by NULL. That is the classic fail-open shape and it would silently
-- retire this guard.
alter table public.derm_portal_submissions
  add constraint derm_portal_submissions_actor_markers_agree
  check ((filed_by_email is not null) = (coalesce(run_id, '') like 'manual-%'));

comment on constraint derm_portal_submissions_actor_markers_agree on public.derm_portal_submissions is
  'A filing is the bot''s or a person''s, never ambiguous: filed_by_email is set if and only if run_id starts with manual-. Was a convention held by two write paths until 2026-08-20; it is now an impossibility.';

-- ---- 2. the activity trail ----------------------------------------------------------------------
-- EVENT-grained, not report-grained. One GDO report's real history is several rows by several actors
-- ("filed by the bot on Aug 7, corrected by Fred on Aug 6"), and a view showing only the latest state
-- loses every line but the last.
create or replace view derm.gdo_report_activity as
select
  coalesce(l.new_row->>'visit_id',    l.old_row->>'visit_id')::bigint     as visit_id,
  coalesce(l.new_row->>'manifest_id', l.old_row->>'manifest_id')::bigint  as manifest_id,
  c.client_code,
  l.changed_at                                                            as occurred_at,

  -- WHO. Order matters: the bot is identified by app_source, a person by a real identity from EITHER
  -- attribution channel (jwt_claims.email for browser-direct writes, request_context.actor_name for
  -- the x-actor-name header). Checking only one channel under-reports; the estate uses both.
  case
    when l.app_source = 'gdo-report-bot'                                             then 'bot'
    when coalesce(l.jwt_claims->>'email', l.request_context->>'actor_name') is not null then 'person'
    when l.app_source = 'sql'                                                        then 'system'
    else 'unattributed'
  end                                                                     as actor_type,
  case
    when l.app_source = 'gdo-report-bot'                                             then 'GDO Report Bot'
    when coalesce(l.jwt_claims->>'email', l.request_context->>'actor_name') is not null
         then coalesce(l.jwt_claims->>'email', l.request_context->>'actor_name')
    when l.app_source = 'sql'                                                        then 'backend maintenance'
    else 'unattributed'
  end                                                                     as actor,

  -- WHAT. A dry run is called a TEST_RUN so it can never be read as a filing to the county.
  case
    when l.operation = 'INSERT' and coalesce((l.new_row->>'dry_run')::boolean, false) then 'TEST_RUN'
    when l.operation = 'INSERT' and l.new_row->>'status' = 'SUCCESS'                  then 'FILED'
    when l.operation = 'INSERT'                                                       then 'ATTEMPT_FAILED'
    when l.operation = 'UPDATE'                                                       then 'CORRECTED'
    when l.operation = 'DELETE'                                                       then 'REMOVED'
    else l.operation
  end                                                                     as event,

  coalesce(l.new_row->>'status',              l.old_row->>'status')              as status,
  coalesce(l.new_row->>'portal_confirmation', l.old_row->>'portal_confirmation') as portal_confirmation,
  coalesce(l.new_row->>'failure_reason',      l.old_row->>'failure_reason')      as failure_reason,

  -- On a correction, WHICH fields moved. Without this a CORRECTED row says someone changed something
  -- and not what, which is useless on a compliance record.
  case when l.operation = 'UPDATE' then (
    select string_agg(e.key, ', ' order by e.key)
      from jsonb_each_text(coalesce(l.new_row, '{}'::jsonb)) e
     where coalesce(l.old_row->>e.key, '~~absent~~') is distinct from e.value)
  end                                                                     as fields_changed,

  coalesce((l.new_row->>'dry_run')::boolean, (l.old_row->>'dry_run')::boolean, false) as dry_run,
  l.app_source,
  l.id                                                                    as audit_id
from audit.logs l
-- LEFT JOINs on purpose: a DELETE event, or a soft-deleted visit, must still appear in the trail.
-- An INNER JOIN here would silently drop exactly the events most worth keeping.
left join public.visits  v on v.id = coalesce(l.new_row->>'visit_id', l.old_row->>'visit_id')::bigint
left join public.clients c on c.id = v.client_id
where l.table_schema = 'public'
  and l.table_name   = 'derm_portal_submissions';

comment on view derm.gdo_report_activity is
  'Who touched each GDO portal report and when, one row per EVENT. actor_type is bot | person | system | unattributed. Built on audit.logs because derm_portal_submissions.filed_by_email records only who FILED: later human corrections do not appear in the row at all. Dry runs are present and labelled TEST_RUN; filter dry_run = false for the real-filing trail.';

revoke all on derm.gdo_report_activity from public, anon;
grant select on derm.gdo_report_activity to authenticated, service_role;

-- PostgREST caches the schema; without this the new view 404s for the app.
notify pgrst, 'reload schema';

-- ---- VERIFY -------------------------------------------------------------------------------------
do $verify$
declare
  v_bot int; v_person int; v_system int; v_unattr int; v_total int; v_audit_total int;
  v_emails text; v_corrected int; v_rejected boolean := false;
begin
  -- (a) THE CONSTRAINT MUST ACTUALLY REJECT. Creating it is not evidence it fires. Only the
  --     MUST-FAIL shape is attempted: a shape that passes would persist on COMMIT.
  begin
    insert into public.derm_portal_submissions
      (visit_id, run_id, status, retryable, dry_run, screenshot_missing_reason, attempted_at, filed_by_email)
    values (6298, 'verify-forged-person', 'TEST_PROBE', false, false, 'verify', now(), 'forged@ayache.com');
  exception when check_violation then
    v_rejected := true;
  end;
  if not v_rejected then
    raise exception 'VERIFY: a forged person row (email + bot-style run_id) was ACCEPTED - the constraint does not fire';
  end if;

  -- (b) the buckets must ACCOUNT FOR EVERY AUDIT ROW. This is the real control: if any CASE arm
  --     misclassifies, the four buckets stop summing to the audit total.
  select count(*) into v_audit_total from audit.logs
   where table_schema='public' and table_name='derm_portal_submissions';

  select count(*) filter (where actor_type='bot'),
         count(*) filter (where actor_type='person'),
         count(*) filter (where actor_type='system'),
         count(*) filter (where actor_type='unattributed'),
         count(*)
    into v_bot, v_person, v_system, v_unattr, v_total
    from derm.gdo_report_activity;

  if v_total <> v_audit_total then
    raise exception 'VERIFY: view returns % rows but audit.logs holds % - the view is dropping events', v_total, v_audit_total;
  end if;
  if v_bot + v_person + v_system + v_unattr <> v_total then
    raise exception 'VERIFY: buckets sum to % but the view has % rows', v_bot+v_person+v_system+v_unattr, v_total;
  end if;

  -- (c) the measured facts this was built from must be reproduced, or the CASE arms are wrong
  if v_bot <> 544 then raise exception 'VERIFY: expected 544 bot events, got %', v_bot; end if;
  if v_person <> 4 then raise exception 'VERIFY: expected 4 person events, got %', v_person; end if;
  if v_system <> 122 then raise exception 'VERIFY: expected 122 system events, got %', v_system; end if;
  if v_unattr <> 0 then raise exception 'VERIFY: % events are unattributed - attribution has a hole', v_unattr; end if;

  -- (d) the two humans must be NAMED, not lumped. This is the whole point of the view.
  select string_agg(distinct actor, ', ' order by actor) into v_emails
    from derm.gdo_report_activity where actor_type = 'person';
  if v_emails is null or v_emails not like '%fred@ayache.com%' then
    raise exception 'VERIFY: the known human corrections are not named (got %)', coalesce(v_emails,'NULL');
  end if;

  -- (e) a CORRECTED event must say WHICH fields moved, else it is an empty claim
  select count(*) into v_corrected from derm.gdo_report_activity
   where event='CORRECTED' and actor_type='person' and fields_changed is not null;
  if v_corrected < 1 then
    raise exception 'VERIFY: no person CORRECTED event reports fields_changed';
  end if;

  -- (f) anon must NOT read staff emails
  if has_table_privilege('anon', 'derm.gdo_report_activity', 'SELECT') then
    raise exception 'VERIFY: anon can read the activity trail, which exposes staff emails';
  end if;
  if not has_table_privilege('authenticated', 'derm.gdo_report_activity', 'SELECT') then
    raise exception 'VERIFY: authenticated cannot read the view, so the app cannot use it';
  end if;

  raise notice 'VERIFY ok: constraint rejects forged rows; % events = % bot + % person (%) + % system + % unattributed',
    v_total, v_bot, v_person, v_emails, v_system, v_unattr;
end $verify$;

commit;
