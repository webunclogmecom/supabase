-- ============================================================================
-- 2026-10-18_0400 HR App: pay rates with their history, and the bonus history linked to Admin Review
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-18: "what i want the most is to have the data of the staff members of the company and to be
--   able to put stuff about their pay rate, bonuses and stuff, also i think we need like a history of that,
--   linked to where it comes from, like a bonus from the Admin Review where they gave the bonus".
--   Plan: docs/superpowers/specs/2026-10-18-hr-app-record-pay-bonus-history-design.md (4.3 to 4.5), revised
--   after a four-lens review the same night.
-- WHAT IT DOES
--   hr.pay_rates (insert only, so it IS the history): per person hourly / salary_weekly / salary_yearly, and
--     the company amounts for the two bonuses (employee_id NULL). A change or a correction is a new row; the
--     rate on a day is the newest row with effective_from <= that day (hr.fn_rate_on). A personal NULL means
--     "not paid this way from that date". Seeded: $10 per approved visit, $25 per approved shift, the amounts
--     Admin Review shows (constants in its code). Per-person bonus amounts are refused for now: Admin Review
--     would keep showing $10 / $25 and the two apps would disagree.
--   hr.bonus_events (insert only): one row per person per Admin Review decision. A grant is >= 0; when the
--     decision no longer stands (review back to pending or denied, visit no longer completed or deleted,
--     review deleted) a reversal of the same amount, negative, points at it (reverses_id, UNIQUE). Nothing is
--     ever updated. The source is the visit (visit_id) or the shift (employee_id + work_date = shift date).
--     work_date on a visit row is a deliberate ADR-004 snapshot: the payroll week a bonus counts in is frozen
--     at grant, and a reversal copies its grant's date and amount.
--   Rules, decided per SOURCE (one visit, or one person's shift), under an advisory lock on that source:
--     expected = review approved, and for a visit: the visit is live and completed and its client is not a
--       test / dump / yard client (public.fn_is_non_customer).
--     expected and no open grant  -> grant each person on visit_team now (or the shift's person), at the rate
--       in force on the work date. Empty crew -> nothing (hr.v_bonus_drift shows it).
--     expected and an open grant  -> nothing (never add, remove or re-rate people).
--     not expected and open grants -> reverse every open grant, read from the ledger.
--   Shift amount = Admin Review's own rule: a PRE and a POST form that day and neither reports an issue,
--     else $0 (rule forms_issue), so the ledger never pays what the reviewer was shown as $0 (2026-10-05).
--   Filled by triggers on public.visit_reviews / public.shift_reviews (every writer, Admin Review unchanged),
--     SECURITY DEFINER; a trigger error never blocks an Admin Review save (it is caught) and the hourly sweep
--     hr.fn_sync_all_bonuses (pg_cron hr-bonus-sweep, :41) heals it, marking the row filled_by = sweep. The
--     sweep also catches a visit that left 'completed' (no trigger on visits).
--   Backfill: the 17 approved visits and 3 approved shifts, decider from audit.logs (bonus_decided_by is never
--     written by Admin Review), filled_by = backfill.
--   Readers (the app's only way in): hr.get_employee_record (admin and office; pay rates for admin only),
--     hr.get_pay_summary (the list's Pay column), hr.set_pay_rates (admin only).
--   hr.v_bonus_drift: what needs a person (no amounts). Its health item waits until the other session releases
--     ops.v_health_items (WORKING-NOW, 2026-10-18); tracked in docs/decisions-to-build.md.
-- RULE 8: both tables OPT OUT of audit.logs. They are append-only (fn_append_only_guard) and carry their own
--   who / when / why, so audit would only copy pay into audit.logs, which every signed-in database role can
--   read. Pay is payroll, not customer billing.
-- GRANTS: tables: no anon / authenticated / service_role grant; RLS enabled and forced, no policies (the
--   readers are SECURITY DEFINER, owner postgres). Functions: authenticated + service_role on the three
--   readers only; everything else owner-only.
-- ROLLBACK: 2026-10-18_rollback_hr_pay_rates_and_bonus_history.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

-- 1. Tables
CREATE TABLE hr.pay_rates (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id    bigint REFERENCES public.employees(id) ON DELETE RESTRICT,
  kind           text NOT NULL CHECK (kind IN ('hourly', 'salary_weekly', 'salary_yearly', 'per_visit_bonus', 'per_shift_bonus')),
  amount         numeric(12,2) CHECK (amount IS NULL OR amount >= 0),
  effective_from date NOT NULL,
  reason         text NOT NULL CHECK (btrim(reason) <> '' AND length(reason) <= 500),
  created_at     timestamptz NOT NULL DEFAULT now(),
  created_by_email text,
  CONSTRAINT pay_rates_company_rows CHECK (employee_id IS NOT NULL
    OR (kind IN ('per_visit_bonus', 'per_shift_bonus') AND amount IS NOT NULL))
);
CREATE INDEX pay_rates_lookup ON hr.pay_rates (employee_id, kind, effective_from DESC, id DESC);
COMMENT ON TABLE hr.pay_rates IS
  'HR pay rates, insert only (the table is its own history). employee_id NULL = company amount (bonus kinds only). '
  'Rate on a day = newest row with effective_from <= day (hr.fn_rate_on). Not audited on purpose (append-only, own who/when/why).';

CREATE TABLE hr.bonus_events (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind             text NOT NULL CHECK (kind IN ('visit_bonus', 'shift_bonus')),
  employee_id      bigint NOT NULL REFERENCES public.employees(id) ON DELETE RESTRICT,
  visit_id         bigint REFERENCES public.visits(id) ON DELETE RESTRICT,
  work_date        date NOT NULL,
  amount           numeric(12,2) NOT NULL,
  pay_rate_id      bigint REFERENCES hr.pay_rates(id),
  rule             text NOT NULL CHECK (rule IN ('approved', 'forms_issue', 'reversal')),
  note             text,
  crew_size        int,
  pre_present      boolean,
  post_present     boolean,
  forms_issue      boolean,
  decided_by_email text,
  decided_at       timestamptz,
  reverses_id      bigint UNIQUE REFERENCES hr.bonus_events(id),
  filled_by        text NOT NULL CHECK (filled_by IN ('trigger', 'sweep', 'backfill')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT bonus_events_source CHECK ((kind = 'visit_bonus') = (visit_id IS NOT NULL)),
  CONSTRAINT bonus_events_sign CHECK (
       (reverses_id IS NULL AND amount >= 0 AND rule <> 'reversal')
    OR (reverses_id IS NOT NULL AND amount <= 0 AND rule = 'reversal'))
);
CREATE INDEX bonus_events_employee ON hr.bonus_events (employee_id, work_date DESC);
CREATE INDEX bonus_events_visit ON hr.bonus_events (visit_id) WHERE visit_id IS NOT NULL;
CREATE INDEX bonus_events_shift ON hr.bonus_events (employee_id, work_date) WHERE kind = 'shift_bonus';
COMMENT ON TABLE hr.bonus_events IS
  'HR bonus history, insert only: one row per person per Admin Review decision (grant >= 0) and a reversal (negative, '
  'reverses_id) when it no longer stands. Filled by triggers on visit_reviews / shift_reviews and the hourly sweep. '
  'work_date on visit rows is an ADR-004 snapshot (payroll week frozen at grant). Not audited on purpose.';

CREATE TRIGGER pay_rates_append_only BEFORE UPDATE OR DELETE ON hr.pay_rates
  FOR EACH ROW EXECUTE FUNCTION public.fn_append_only_guard();
CREATE TRIGGER pay_rates_no_truncate BEFORE TRUNCATE ON hr.pay_rates
  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_append_only_guard();
CREATE TRIGGER bonus_events_append_only BEFORE UPDATE OR DELETE ON hr.bonus_events
  FOR EACH ROW EXECUTE FUNCTION public.fn_append_only_guard();
CREATE TRIGGER bonus_events_no_truncate BEFORE TRUNCATE ON hr.bonus_events
  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_append_only_guard();

ALTER TABLE hr.pay_rates ENABLE ROW LEVEL SECURITY;
ALTER TABLE hr.pay_rates FORCE ROW LEVEL SECURITY;
ALTER TABLE hr.bonus_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE hr.bonus_events FORCE ROW LEVEL SECURITY;
REVOKE ALL ON hr.pay_rates, hr.bonus_events FROM PUBLIC, anon, authenticated, service_role;

INSERT INTO hr.pay_rates (employee_id, kind, amount, effective_from, reason) VALUES
  (NULL, 'per_visit_bonus', 10.00, DATE '2026-01-01', 'Company amount for a visit approved in Admin Review (the amount Admin Review shows).'),
  (NULL, 'per_shift_bonus', 25.00, DATE '2026-01-01', 'Company amount for a shift approved in Admin Review with no form issue (the amount Admin Review shows).');

-- 2. Rate on a day
CREATE FUNCTION hr.fn_rate_on(p_employee_id bigint, p_kind text, p_day date)
RETURNS TABLE(rate_id bigint, amount numeric)
LANGUAGE sql STABLE SET search_path = '' AS $f$
  with personal as (
    select r.id, r.amount from hr.pay_rates r
     where r.employee_id = p_employee_id and r.kind = p_kind and r.effective_from <= p_day
     order by r.effective_from desc, r.id desc limit 1),
  company as (
    select r.id, r.amount from hr.pay_rates r
     where r.employee_id is null and r.kind = p_kind and r.effective_from <= p_day
     order by r.effective_from desc, r.id desc limit 1)
  select case when p.amount is not null then p.id
              when p_kind in ('per_visit_bonus', 'per_shift_bonus') then c.id
              else p.id end,
         case when p.amount is not null then p.amount
              when p_kind in ('per_visit_bonus', 'per_shift_bonus') then c.amount
              else null end
    from (select 1) one left join personal p on true left join company c on true
$f$;

-- 3. Who decided, read from audit.logs (Admin Review never writes bonus_decided_by)
CREATE FUNCTION hr.fn_review_decider(p_table text, p_pk jsonb) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $f$
  select lower(btrim(nullif(a.jwt_claims->>'email', '')))
    from audit.logs a
   where a.table_name = p_table and a.record_pk = p_pk
     and a.new_row->>'bonus_status' = 'approved'
     and (a.old_row is null or a.old_row->>'bonus_status' is distinct from 'approved')
   order by a.id desc limit 1
$f$;

-- 4. Is a visit bonus owed?
CREATE FUNCTION hr.fn_visit_bonus_expected(p_visit_id bigint) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $f$
  select exists (
    select 1 from public.visit_reviews vr join public.visits v on v.id = vr.visit_id
     where vr.visit_id = p_visit_id and vr.bonus_status = 'approved'
       and v.deleted_at is null and v.visit_status = 'completed'
       and not public.fn_is_non_customer(v.client_id))
$f$;

-- 5. Sync one visit
CREATE FUNCTION hr.fn_sync_visit_bonus(p_visit_id bigint, p_filled_by text, p_decider text DEFAULT NULL)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $f$
declare
  v_expected boolean; v_open int; v_n int := 0; v_date date; v_decided timestamptz;
  v_crew bigint[]; v_e bigint; v_rate_id bigint; v_amount numeric; v_decider text := p_decider;
  v_note text; v_status text; v_g record;
begin
  perform pg_advisory_xact_lock(hashtextextended('hr.bonus.visit:' || p_visit_id, 0));
  v_expected := hr.fn_visit_bonus_expected(p_visit_id);
  select count(*) into v_open from hr.bonus_events g
   where g.kind = 'visit_bonus' and g.visit_id = p_visit_id and g.reverses_id is null
     and not exists (select 1 from hr.bonus_events r where r.reverses_id = g.id);

  if v_expected and v_open = 0 then
    select v.visit_date, vr.bonus_decided_at into v_date, v_decided
      from public.visits v join public.visit_reviews vr on vr.visit_id = v.id where v.id = p_visit_id;
    select array_agg(distinct vt.employee_id order by vt.employee_id) into v_crew
      from public.visit_team vt where vt.visit_id = p_visit_id;
    if v_crew is null then return 0; end if;
    if v_decider is null and p_filled_by <> 'trigger' then
      v_decider := hr.fn_review_decider('visit_reviews', jsonb_build_object('visit_id', p_visit_id));
    end if;
    foreach v_e in array v_crew loop
      select r.rate_id, r.amount into v_rate_id, v_amount from hr.fn_rate_on(v_e, 'per_visit_bonus', v_date) r;
      insert into hr.bonus_events (kind, employee_id, visit_id, work_date, amount, pay_rate_id, rule, crew_size,
                                   decided_by_email, decided_at, filled_by)
      values ('visit_bonus', v_e, p_visit_id, v_date, coalesce(v_amount, 0), v_rate_id, 'approved', cardinality(v_crew),
              v_decider, coalesce(v_decided, now()), p_filled_by);
      v_n := v_n + 1;
    end loop;
  elsif not v_expected and v_open > 0 then
    select vr.bonus_status into v_status from public.visit_reviews vr where vr.visit_id = p_visit_id;
    v_note := case when v_status is null then 'The review was deleted in Admin Review.'
                   when v_status <> 'approved' then 'The bonus is no longer approved in Admin Review (' || v_status || ').'
                   else 'The visit is no longer a completed visit.' end;
    for v_g in select * from hr.bonus_events g
              where g.kind = 'visit_bonus' and g.visit_id = p_visit_id and g.reverses_id is null
                and not exists (select 1 from hr.bonus_events r where r.reverses_id = g.id)
              order by g.id loop
      insert into hr.bonus_events (kind, employee_id, visit_id, work_date, amount, pay_rate_id, rule, note, crew_size,
                                   decided_by_email, decided_at, reverses_id, filled_by)
      values ('visit_bonus', v_g.employee_id, p_visit_id, v_g.work_date, -v_g.amount, v_g.pay_rate_id, 'reversal', v_note, v_g.crew_size,
              p_decider, now(), v_g.id, p_filled_by);
      v_n := v_n + 1;
    end loop;
  end if;
  return v_n;
end $f$;

-- 6. Sync one shift (Admin Review's amount rule: PRE and POST that day, neither reports an issue)
CREATE FUNCTION hr.fn_sync_shift_bonus(p_employee_id bigint, p_shift_date date, p_filled_by text, p_decider text DEFAULT NULL)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $f$
declare
  v_expected boolean; v_open int; v_n int := 0; v_decided timestamptz; v_status text;
  v_pre record; v_post record; v_issue boolean; v_rate_id bigint; v_amount numeric; v_decider text := p_decider;
  v_note text; v_g record;
begin
  perform pg_advisory_xact_lock(hashtextextended('hr.bonus.shift:' || p_employee_id || ':' || p_shift_date, 0));
  select sr.bonus_status, sr.bonus_decided_at into v_status, v_decided
    from public.shift_reviews sr where sr.employee_id = p_employee_id and sr.shift_date = p_shift_date;
  v_expected := coalesce(v_status = 'approved', false);
  select count(*) into v_open from hr.bonus_events g
   where g.kind = 'shift_bonus' and g.employee_id = p_employee_id and g.work_date = p_shift_date and g.reverses_id is null
     and not exists (select 1 from hr.bonus_events r where r.reverses_id = g.id);

  if v_expected and v_open = 0 then
    select i.id, coalesce(i.has_issue, false) as has_issue into v_pre from public.inspections i
     where i.employee_id = p_employee_id and i.shift_date = p_shift_date and i.inspection_type = 'PRE'
     order by i.submitted_at, i.id limit 1;
    select i.id, coalesce(i.has_issue, false) as has_issue into v_post from public.inspections i
     where i.employee_id = p_employee_id and i.shift_date = p_shift_date and i.inspection_type = 'POST'
     order by i.submitted_at, i.id limit 1;
    v_issue := coalesce(v_pre.has_issue, false) or coalesce(v_post.has_issue, false);
    select r.rate_id, r.amount into v_rate_id, v_amount from hr.fn_rate_on(p_employee_id, 'per_shift_bonus', p_shift_date) r;
    if v_decider is null and p_filled_by <> 'trigger' then
      v_decider := hr.fn_review_decider('shift_reviews',
        jsonb_build_object('employee_id', p_employee_id, 'shift_date', to_char(p_shift_date, 'YYYY-MM-DD')));
    end if;
    insert into hr.bonus_events (kind, employee_id, work_date, amount, pay_rate_id, rule, note, pre_present, post_present,
                                 forms_issue, decided_by_email, decided_at, filled_by)
    values ('shift_bonus', p_employee_id, p_shift_date,
            case when v_pre.id is not null and v_post.id is not null and not v_issue then coalesce(v_amount, 0) else 0 end,
            v_rate_id,
            case when v_pre.id is not null and v_post.id is not null and not v_issue then 'approved' else 'forms_issue' end,
            case when v_pre.id is null or v_post.id is null then 'A pre or post form is missing for that day, so Admin Review shows $0.'
                 when v_issue then 'A form that day reports an issue, so Admin Review shows $0.' end,
            v_pre.id is not null, v_post.id is not null, v_issue, v_decider, coalesce(v_decided, now()), p_filled_by);
    v_n := 1;
  elsif not v_expected and v_open > 0 then
    v_note := case when v_status is null then 'The shift review was deleted in Admin Review.'
                   else 'The shift bonus is no longer approved in Admin Review (' || v_status || ').' end;
    for v_g in select * from hr.bonus_events g
              where g.kind = 'shift_bonus' and g.employee_id = p_employee_id and g.work_date = p_shift_date
                and g.reverses_id is null and not exists (select 1 from hr.bonus_events r where r.reverses_id = g.id)
              order by g.id loop
      insert into hr.bonus_events (kind, employee_id, work_date, amount, pay_rate_id, rule, note, decided_by_email,
                                   decided_at, reverses_id, filled_by)
      values ('shift_bonus', v_g.employee_id, v_g.work_date, -v_g.amount, v_g.pay_rate_id, 'reversal', v_note, p_decider, now(), v_g.id, p_filled_by);
      v_n := v_n + 1;
    end loop;
  end if;
  return v_n;
end $f$;

-- 7. Triggers on the Admin Review tables (every writer; never block the save)
CREATE FUNCTION hr.trg_visit_review_bonus() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $f$
declare v_id bigint;
begin
  v_id := case when tg_op = 'DELETE' then old.visit_id else new.visit_id end;
  begin
    perform hr.fn_sync_visit_bonus(v_id, 'trigger', lower(btrim(nullif(auth.jwt()->>'email', ''))));
  exception when others then
    raise warning 'hr bonus sync failed for visit %: % (the hourly sweep will retry)', v_id, sqlerrm;
  end;
  return null;
end $f$;

CREATE FUNCTION hr.trg_shift_review_bonus() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $f$
declare v_emp bigint; v_date date;
begin
  if tg_op = 'DELETE' then v_emp := old.employee_id; v_date := old.shift_date;
  else v_emp := new.employee_id; v_date := new.shift_date; end if;
  begin
    perform hr.fn_sync_shift_bonus(v_emp, v_date, 'trigger', lower(btrim(nullif(auth.jwt()->>'email', ''))));
    if tg_op = 'UPDATE' and (old.employee_id, old.shift_date) is distinct from (new.employee_id, new.shift_date) then
      perform hr.fn_sync_shift_bonus(old.employee_id, old.shift_date, 'trigger', lower(btrim(nullif(auth.jwt()->>'email', ''))));
    end if;
  exception when others then
    raise warning 'hr bonus sync failed for shift % %: % (the hourly sweep will retry)', v_emp, v_date, sqlerrm;
  end;
  return null;
end $f$;

CREATE TRIGGER zz_hr_bonus_sync AFTER INSERT OR UPDATE OR DELETE ON public.visit_reviews
  FOR EACH ROW EXECUTE FUNCTION hr.trg_visit_review_bonus();
CREATE TRIGGER zz_hr_bonus_sync AFTER INSERT OR UPDATE OR DELETE ON public.shift_reviews
  FOR EACH ROW EXECUTE FUNCTION hr.trg_shift_review_bonus();

-- 8. The sweep (also the backfill)
CREATE FUNCTION hr.fn_sync_all_bonuses(p_filled_by text DEFAULT 'sweep') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $f$
declare k record; v_visit int := 0; v_shift int := 0;
begin
  for k in select vr.visit_id from public.visit_reviews vr where vr.bonus_status = 'approved'
           union
           select g.visit_id from hr.bonus_events g
            where g.kind = 'visit_bonus' and g.reverses_id is null
              and not exists (select 1 from hr.bonus_events r where r.reverses_id = g.id) loop
    v_visit := v_visit + hr.fn_sync_visit_bonus(k.visit_id, p_filled_by);
  end loop;
  for k in select sr.employee_id, sr.shift_date from public.shift_reviews sr where sr.bonus_status = 'approved'
           union
           select g.employee_id, g.work_date from hr.bonus_events g
            where g.kind = 'shift_bonus' and g.reverses_id is null
              and not exists (select 1 from hr.bonus_events r where r.reverses_id = g.id) loop
    v_shift := v_shift + hr.fn_sync_shift_bonus(k.employee_id, k.shift_date, p_filled_by);
  end loop;
  return jsonb_build_object('visit_rows', v_visit, 'shift_rows', v_shift);
end $f$;

-- 9. What needs a person (no amounts)
CREATE VIEW hr.v_bonus_drift AS
  with open_grants as (
    select g.* from hr.bonus_events g
     where g.reverses_id is null and not exists (select 1 from hr.bonus_events r where r.reverses_id = g.id)),
  approved_visits as (select vr.visit_id from public.visit_reviews vr where vr.bonus_status = 'approved')
  select 'missing_grant'::text as problem, 'visit_bonus'::text as kind, a.visit_id, null::bigint as employee_id, null::date as work_date
    from approved_visits a
   where hr.fn_visit_bonus_expected(a.visit_id)
     and exists (select 1 from public.visit_team vt where vt.visit_id = a.visit_id)
     and not exists (select 1 from open_grants g where g.kind = 'visit_bonus' and g.visit_id = a.visit_id)
  union all
  select 'approved_no_crew', 'visit_bonus', a.visit_id, null, null
    from approved_visits a
   where hr.fn_visit_bonus_expected(a.visit_id)
     and not exists (select 1 from public.visit_team vt where vt.visit_id = a.visit_id)
  union all
  select 'grant_not_expected', g.kind, g.visit_id, g.employee_id, g.work_date
    from open_grants g
   where (g.kind = 'visit_bonus' and not hr.fn_visit_bonus_expected(g.visit_id))
      or (g.kind = 'shift_bonus' and not exists (select 1 from public.shift_reviews sr
           where sr.employee_id = g.employee_id and sr.shift_date = g.work_date and sr.bonus_status = 'approved'))
  union all
  select 'missing_grant', 'shift_bonus', null, sr.employee_id, sr.shift_date
    from public.shift_reviews sr
   where sr.bonus_status = 'approved'
     and not exists (select 1 from open_grants g where g.kind = 'shift_bonus' and g.employee_id = sr.employee_id and g.work_date = sr.shift_date)
  union all
  select 'shift_forms_issue', g.kind, null, g.employee_id, g.work_date from open_grants g where g.rule = 'forms_issue'
  union all
  select 'decider_unknown', g.kind, g.visit_id, g.employee_id, g.work_date
    from open_grants g
   where g.decided_by_email is null
      or not exists (select 1 from public.employees e where e.status = 'ACTIVE' and e.access_level in ('admin', 'office')
                      and lower(btrim(e.email)) = g.decided_by_email)
  union all
  select 'decider_is_earner', g.kind, g.visit_id, g.employee_id, g.work_date
    from open_grants g join public.employees e on e.id = g.employee_id
   where g.decided_by_email is not null and lower(btrim(e.email)) = g.decided_by_email;
REVOKE ALL ON hr.v_bonus_drift FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON VIEW hr.v_bonus_drift IS
  'HR bonus ledger problems that need a person (no amounts). missing_grant / grant_not_expected should be empty after the hourly sweep.';

-- 10. Readers and the rate writer
CREATE FUNCTION hr.fn_payroll_week_start(d date) RETURNS date
LANGUAGE sql IMMUTABLE SET search_path = '' AS $f$
  select d - ((extract(dow from d)::int - 5 + 7) % 7)   -- Friday to Thursday, as Admin Review's payroll week
$f$;

CREATE FUNCTION hr.fn_person_label(p_email text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $f$
  select case when p_email is null then null else public.fn_page_staff_name(p_email) end
$f$;

CREATE FUNCTION hr.get_employee_record(p_id bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $f$
declare
  v_caller bigint; v_level text; v_e public.employees; v_pay boolean;
  v_today date := (now() at time zone 'America/New_York')::date;
  v_rates jsonb; v_history jsonb; v_weeks jsonb; v_activity jsonb; v_company jsonb;
begin
  select c.employee_id, c.access_level into v_caller, v_level from hr.fn_require_level(array['admin', 'office']) c;
  select * into v_e from public.employees where id = p_id;
  if not found then
    raise exception 'That person was not found. Reload the page.' using errcode = 'P0002', detail = 'blocker=not_found employee_id=' || p_id;
  end if;
  v_pay := v_level = 'admin';

  v_company := jsonb_build_object(
    'per_visit_bonus', (select r.amount from hr.fn_rate_on(p_id, 'per_visit_bonus', v_today) r),
    'per_shift_bonus', (select r.amount from hr.fn_rate_on(p_id, 'per_shift_bonus', v_today) r));

  if v_pay then
    select coalesce(jsonb_agg(x order by x->>'kind'), '[]'::jsonb) into v_rates from (
      select jsonb_build_object('kind', k.kind, 'amount', r.amount, 'effective_from', p.effective_from,
                                'reason', p.reason, 'set_by', hr.fn_person_label(p.created_by_email)) x
        from unnest(array['hourly', 'salary_weekly', 'salary_yearly']) k(kind)
        cross join lateral hr.fn_rate_on(p_id, k.kind, v_today) r
        left join hr.pay_rates p on p.id = r.rate_id
       where r.amount is not null) s;
  end if;

  -- One history list, newest first: rate changes (admin only) and bonuses (admin and office)
  select coalesce(jsonb_agg(h order by (h->>'date') desc, (h->>'sort_at') desc, (h->>'id')::bigint desc), '[]'::jsonb) into v_history from (
    select jsonb_build_object(
      'id', p.id, 'type', 'rate_change', 'date', p.effective_from, 'sort_at', p.created_at,
      'title', case p.kind when 'hourly' then 'Hourly rate' when 'salary_weekly' then 'Weekly salary'
                            when 'salary_yearly' then 'Yearly salary' end,
      'amount', p.amount, 'unit', case p.kind when 'hourly' then 'hour' when 'salary_weekly' then 'week' else 'year' end,
      'detail', case when p.amount is null then 'Stopped from this date. ' else 'From this date. ' end || p.reason,
      'by', hr.fn_person_label(p.created_by_email), 'source', 'HR App', 'link', null) h
      from hr.pay_rates p where v_pay and p.employee_id = p_id
    union all
    select jsonb_build_object(
      'id', g.id, 'type', case when g.rule = 'reversal' then 'reversal' else g.kind end,
      'date', g.work_date, 'sort_at', g.created_at,
      'title', case when g.rule = 'reversal' then 'Bonus taken back'
                    when g.kind = 'visit_bonus' then 'Visit bonus' else 'Shift bonus' end,
      'amount', g.amount, 'unit', null,
      'detail', concat_ws(' · ',
                  case when g.kind = 'visit_bonus' then concat_ws(' ', c.client_code, c.name) else 'Shift forms of ' || to_char(g.work_date, 'Mon FMDD') end,
                  case when g.crew_size > 1 then 'shared visit, ' || g.crew_size || ' on the crew' end,
                  g.note),
      'by', coalesce(hr.fn_person_label(g.decided_by_email), case when g.rule = 'reversal' then 'System' end),
      'decided_at', g.decided_at,
      'source', 'Admin Review',
      'link', case when g.kind = 'visit_bonus' then '/review/' || g.visit_id
                   else '/review-shift/shift-' || g.employee_id || '-' || to_char(g.work_date, 'YYYY-MM-DD') end,
      'reversed', exists (select 1 from hr.bonus_events r where r.reverses_id = g.id)) h
      from hr.bonus_events g
      left join public.visits v on v.id = g.visit_id
      left join public.clients c on c.id = v.client_id
     where g.employee_id = p_id
  ) s;

  select coalesce(jsonb_agg(w order by w->>'week_start' desc), '[]'::jsonb) into v_weeks from (
    select jsonb_build_object('week_start', hr.fn_payroll_week_start(g.work_date),
                              'week_end', hr.fn_payroll_week_start(g.work_date) + 6,
                              'total', sum(g.amount),
                              'visit_bonuses', count(*) filter (where g.kind = 'visit_bonus' and g.rule <> 'reversal'),
                              'shift_bonuses', count(*) filter (where g.kind = 'shift_bonus' and g.rule <> 'reversal')) w
      from hr.bonus_events g where g.employee_id = p_id
     group by hr.fn_payroll_week_start(g.work_date)) s;

  select coalesce(jsonb_agg(a order by (a->>'id')::bigint desc), '[]'::jsonb) into v_activity from (
    select jsonb_build_object(
      'id', l.id, 'at', l.changed_at, 'operation', l.operation,
      'by', coalesce(hr.fn_person_label(l.jwt_claims->>'email'),
                     case l.app_source when 'sql' then 'Database (by hand)' when 'employee-dedup-merge' then 'Duplicate clean-up'
                                       else l.app_source end),
      'app', case l.app_source when 'hr-app' then 'HR App' else null end,
      'changes', (select coalesce(jsonb_agg(jsonb_build_object('field', f.label, 'old', l.old_row->>f.col, 'new', l.new_row->>f.col)
                                             order by f.ord), '[]'::jsonb)
                    from (values (1, 'full_name', 'Name'), (2, 'status', 'Status'), (3, 'shift', 'Shift'), (4, 'email', 'Email'),
                                 (5, 'phone', 'Phone'), (6, 'hire_date', 'Hire date'), (7, 'access_level', 'Access level'),
                                 (8, 'color_hex', 'Colour')) f(ord, col, label)
                   where l.operation = 'INSERT' and l.new_row->>f.col is not null
                      or l.operation = 'UPDATE' and (l.old_row->>f.col) is distinct from (l.new_row->>f.col))) a
      from audit.logs l
     where l.table_name = 'employees' and l.record_pk->>'id' = p_id::text
     order by l.id desc limit 100) s
   where jsonb_array_length(a->'changes') > 0 or a->>'operation' <> 'UPDATE';

  return jsonb_build_object(
    'employee', hr.fn_employee_json(v_e),
    'viewer', jsonb_build_object('level', v_level, 'can_edit', true, 'can_see_pay', v_pay, 'is_self', v_e.id = v_caller,
                                 'can_change_email_status', v_e.id <> v_caller and (v_level = 'admin' or coalesce(v_e.access_level, 'field') = 'field')),
    'impact_if_inactive', hr.fn_employee_impact(p_id),
    'company_bonus', v_company,
    'rates', v_rates,
    'history', v_history,
    'bonus_weeks', v_weeks,
    'activity', v_activity);
end $f$;

CREATE FUNCTION hr.get_pay_summary() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $f$
declare v_level text; v_today date := (now() at time zone 'America/New_York')::date; v_rows jsonb;
begin
  select c.access_level into v_level from hr.fn_require_level(array['admin', 'office']) c;
  if v_level <> 'admin' then
    return jsonb_build_object('can_see_pay', false, 'rows', '[]'::jsonb);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'employee_id', e.id,
           'hourly', (select r.amount from hr.fn_rate_on(e.id, 'hourly', v_today) r),
           'salary_weekly', (select r.amount from hr.fn_rate_on(e.id, 'salary_weekly', v_today) r),
           'salary_yearly', (select r.amount from hr.fn_rate_on(e.id, 'salary_yearly', v_today) r),
           'bonus_this_week', (select sum(g.amount) from hr.bonus_events g
                                where g.employee_id = e.id and hr.fn_payroll_week_start(g.work_date) = hr.fn_payroll_week_start(v_today))
         ) order by e.id), '[]'::jsonb) into v_rows
    from public.employees e;
  return jsonb_build_object('can_see_pay', true, 'rows', v_rows);
end $f$;

CREATE FUNCTION hr.set_pay_rates(p_employee_id bigint, p_rates jsonb, p_effective_from date, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $f$
declare
  v_caller bigint; v_email text := lower(btrim(nullif(auth.jwt()->>'email', '')));
  v_today date := (now() at time zone 'America/New_York')::date;
  k text; v_val jsonb; v_amount numeric; v_current numeric; v_max numeric; v_n int := 0; v_bad text[];
begin
  select c.employee_id into v_caller from hr.fn_require_level(array['admin']) c;
  if not exists (select 1 from public.employees where id = p_employee_id) then
    raise exception 'That person was not found. Reload the page.' using errcode = 'P0002', detail = 'blocker=not_found employee_id=' || p_employee_id;
  end if;
  if p_rates is null or jsonb_typeof(p_rates) <> 'object' or p_rates = '{}'::jsonb then
    raise exception 'Nothing to save.' using errcode = '22023', detail = 'blocker=rates_shape';
  end if;
  if p_rates ? 'per_visit_bonus' or p_rates ? 'per_shift_bonus' then
    raise exception 'The visit and shift bonuses are the same for everyone for now (the amounts Admin Review shows), so they cannot be changed per person. Nothing was saved.'
      using errcode = '22023', detail = 'blocker=bonus_rate_company';
  end if;
  select array_agg(x order by x) into v_bad from jsonb_object_keys(p_rates) x where x not in ('hourly', 'salary_weekly', 'salary_yearly');
  if v_bad is not null then
    raise exception 'These pay kinds are not known: %. Nothing was saved.', array_to_string(v_bad, ', ') using errcode = '22023', detail = 'blocker=rate_kind';
  end if;
  if p_effective_from is null or p_effective_from < date '2020-01-01' or p_effective_from > v_today + 366 then
    raise exception 'Pick the date the new pay starts. Nothing was saved.' using errcode = '22023', detail = 'blocker=effective_from';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'Write why the pay changes. Nothing was saved.' using errcode = '22023', detail = 'blocker=reason_missing';
  end if;
  if length(btrim(p_reason)) > 500 then
    raise exception 'The reason is too long (500 characters at most). Nothing was saved.' using errcode = '22023', detail = 'blocker=reason_long';
  end if;

  -- validate everything before writing anything
  for k, v_val in select * from jsonb_each(p_rates) loop
    if jsonb_typeof(v_val) not in ('number', 'null', 'string') then
      raise exception 'The % amount is not a number. Nothing was saved.', replace(k, '_', ' ') using errcode = '22023', detail = 'blocker=amount_format';
    end if;
    if jsonb_typeof(v_val) = 'string' and btrim(v_val #>> '{}') <> '' and btrim(v_val #>> '{}') !~ '^[0-9]+([.][0-9]{1,2})?$' then
      raise exception 'The % amount is not a number. Nothing was saved.', replace(k, '_', ' ') using errcode = '22023', detail = 'blocker=amount_format';
    end if;
    v_amount := nullif(btrim(v_val #>> '{}'), '')::numeric;
    v_max := case k when 'hourly' then 500 when 'salary_weekly' then 20000 else 1000000 end;
    if v_amount is not null and (v_amount < 0 or v_amount > v_max or v_amount <> round(v_amount, 2)) then
      raise exception 'The % amount is out of range. Nothing was saved.', replace(k, '_', ' ') using errcode = '22023', detail = 'blocker=amount_range';
    end if;
  end loop;

  for k, v_val in select * from jsonb_each(p_rates) loop
    v_amount := nullif(btrim(v_val #>> '{}'), '')::numeric;
    select r.amount into v_current from hr.fn_rate_on(p_employee_id, k, p_effective_from) r;
    if v_current is not distinct from v_amount then continue; end if;
    insert into hr.pay_rates (employee_id, kind, amount, effective_from, reason, created_by_email)
    values (p_employee_id, k, v_amount, p_effective_from, btrim(p_reason), v_email);
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('noop', v_n = 0, 'rows_added', v_n);
end $f$;

-- 11. Grants: owner-only except the four app entry points
REVOKE ALL ON FUNCTION hr.fn_rate_on(bigint, text, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION hr.fn_review_decider(text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION hr.fn_visit_bonus_expected(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION hr.fn_sync_visit_bonus(bigint, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION hr.fn_sync_shift_bonus(bigint, date, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION hr.trg_visit_review_bonus() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION hr.trg_shift_review_bonus() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION hr.fn_sync_all_bonuses(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION hr.fn_payroll_week_start(date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION hr.fn_person_label(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION hr.get_employee_record(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION hr.get_pay_summary() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION hr.set_pay_rates(bigint, jsonb, date, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION hr.get_employee_record(bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION hr.get_pay_summary() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION hr.set_pay_rates(bigint, jsonb, date, text) TO authenticated, service_role;

-- 12. Backfill, then the hourly sweep
DO $b$
DECLARE v jsonb;
BEGIN
  v := hr.fn_sync_all_bonuses('backfill');
  RAISE NOTICE 'backfill %', v;
END $b$;

SELECT cron.schedule('hr-bonus-sweep', '41 * * * *', $c$select hr.fn_sync_all_bonuses()$c$);

-- VERIFY
DO $v$
DECLARE v_bad text; n int; m int;
BEGIN
  -- tables: only the owner and the backup reader
  SELECT string_agg(c.relname || '=' || c.relacl::text, '; ') INTO v_bad
    FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
   WHERE ns.nspname = 'hr' AND c.relkind IN ('r', 'v')
     AND (has_table_privilege('authenticated', c.oid, 'SELECT') OR has_table_privilege('anon', c.oid, 'SELECT')
          OR has_table_privilege('authenticated', c.oid, 'INSERT') OR has_table_privilege('service_role', c.oid, 'SELECT'));
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'VERIFY: hr relation grants too wide: %', v_bad; END IF;
  -- functions: allowlist
  SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v_bad
    FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
   WHERE ns.nspname = 'hr'
     AND (has_function_privilege('anon', p.oid, 'EXECUTE')
          OR has_function_privilege('authenticated', p.oid, 'EXECUTE')
             <> (p.proname IN ('update_employee', 'get_employee_record', 'get_pay_summary', 'set_pay_rates')));
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'VERIFY: hr EXECUTE grants wrong on: %', v_bad; END IF;
  -- backfill: every approved non-test visit with a crew has exactly one open grant per crew member
  SELECT count(*) INTO n FROM hr.v_bonus_drift WHERE problem IN ('missing_grant', 'grant_not_expected');
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY: % drift rows after the backfill', n; END IF;
  SELECT count(*) INTO n FROM public.visit_reviews vr WHERE vr.bonus_status = 'approved' AND hr.fn_visit_bonus_expected(vr.visit_id);
  SELECT count(DISTINCT visit_id) INTO m FROM hr.bonus_events WHERE kind = 'visit_bonus';
  IF n = 0 OR n <> m THEN RAISE EXCEPTION 'VERIFY: % approved visits but % visits in the ledger', n, m; END IF;
  SELECT count(*) INTO n FROM public.shift_reviews WHERE bonus_status = 'approved';
  SELECT count(*) INTO m FROM hr.bonus_events WHERE kind = 'shift_bonus';
  IF n <> m THEN RAISE EXCEPTION 'VERIFY: % approved shifts but % shift rows', n, m; END IF;
  SELECT count(*) INTO n FROM hr.bonus_events WHERE decided_by_email IS NULL;
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY: % backfilled rows have no decider', n; END IF;
  -- a second sweep adds nothing
  IF (hr.fn_sync_all_bonuses()->>'visit_rows')::int + (hr.fn_sync_all_bonuses()->>'shift_rows')::int <> 0 THEN
    RAISE EXCEPTION 'VERIFY: the sweep is not idempotent';
  END IF;
  IF (SELECT count(*) FROM cron.job WHERE jobname = 'hr-bonus-sweep') <> 1 THEN RAISE EXCEPTION 'VERIFY: cron job missing'; END IF;
  RAISE NOTICE 'VERIFY passed';
END $v$;
COMMIT;
