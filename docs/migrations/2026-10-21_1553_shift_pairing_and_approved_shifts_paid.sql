-- 2026-10-21_1553_shift_pairing_and_approved_shifts_paid.sql
--
-- Trello ZEYkT63t (Fred via Viktor, 2026-10-21): "shift bonus reviews ... are automatically declined/rejected whenever one
-- PRE-POST inspection is missing or still pending ... Fix: stop the auto-reject and instead show a confirmation dialog ...
-- on Yes, the approval is saved as approved." Root cause (Fred): "the night shift is split across two calendar days. The
-- PRE-shift inspection is submitted one night ... and the POST-shift inspection the next morning ... We need to merge them
-- into one shift." Fred's picks (2026-10-21): pay the amount when a missing-form shift is approved; pay when approved even
-- if a form reports an issue; re-pair Michael's 5 existing reviews. Spec: Building Apps/Admin Review/docs/specs/
-- 2026-10-21-shift-pairing-and-missing-form.md.
--
-- 1. NEW public.v_inspection_shifts (security_invoker; authenticated + service_role SELECT): the ONE pairing rule. A POST
--    closes the latest PRE of the same person filed before it within 24 hours with no other POST in between; the shift is
--    dated by its PRE's ET clock date; a POST with no PRE filed before noon ET ends the night before. Measured on all 468
--    forms: 163 pairs, no PRE used twice, 72 across midnight, 0 collisions since 2026-09-01 (13 Airtable-era ones before).
--    Every PRE since August carries its ET date as shift_date, so every recent key keeps its date.
-- 2. hr.fn_sync_shift_bonus reads the shift's forms from it, and an APPROVED shift is paid (custom or normal amount) also
--    with a form missing or reporting an issue, with a note saying so; only a shift with no form at all records $0.
--    hr.fn_pending_bonus and hr.get_employee_record count undecided PAIRED shifts (an issue no longer blocks);
--    hr.set_shift_bonus and hr.fn_admin_review_url check the shift exists in the view.
-- 3. hr.v_bonus_drift gains problem shift_pairing_collision (two shifts for one person on one date since 2026-09-01) and
--    public.log_hr_bonus_health words it for the daily health email.
-- 4. Repair (Fred: "Re-pair all 5"): shift_reviews (40, 2026-10-03) and (40, 2026-10-20), both denied, are removed: each
--    was the POST that closes the night before (Oct 2, Oct 19), so their shift no longer exists. Michael's Oct 5 ($0 under
--    the old rule) is recorded again at his shift amount. Sep 24 and Oct 2 stay at $25.
--
-- Rule 8: no new table. public.shift_reviews is audited (audit_shift_reviews), so the two removed rows stay in
-- audit.logs.old_row; hr.bonus_events is append-only (the Oct 5 change is a reversal plus a grant). Rehearsed with
-- scripts/checks/hr_app/probe_shift_pairing.sql and probe_shift_bonus_custom.sql; rollback rehearsed.
-- Rollback: 2026-10-21_rollback_shift_pairing_and_approved_shifts_paid.sql (does not undo the repair).

BEGIN;
SET LOCAL lock_timeout = '3s';
DO $g$ BEGIN
  IF md5(regexp_replace(pg_get_functiondef('hr.fn_sync_shift_bonus(bigint,date,text,text)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> '144f3fe7c81a44dcf40acc7c5e987693' THEN RAISE EXCEPTION 'guard: hr.fn_sync_shift_bonus(bigint,date,text,text) changed'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('hr.fn_pending_bonus(bigint,date)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> '64c9925e6ac02070a6bc25ade74f56be' THEN RAISE EXCEPTION 'guard: hr.fn_pending_bonus(bigint,date) changed'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('hr.get_employee_record(bigint)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> 'e61da465303d8e94f7f7a875b6b537e3' THEN RAISE EXCEPTION 'guard: hr.get_employee_record(bigint) changed'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('hr.set_shift_bonus(bigint,date,numeric,text)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> '75db7193144fe802bbe757b3689180ee' THEN RAISE EXCEPTION 'guard: hr.set_shift_bonus(bigint,date,numeric,text) changed'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('hr.fn_admin_review_url(text,bigint,bigint,date)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> 'bd13367097dbd52ab0f8e501db73e636' THEN RAISE EXCEPTION 'guard: hr.fn_admin_review_url(text,bigint,bigint,date) changed'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('public.log_hr_bonus_health()'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> '3f4ceb093c6105d4a4c83b24cefd513a' THEN RAISE EXCEPTION 'guard: public.log_hr_bonus_health() changed'; END IF;
  IF to_regclass('public.v_inspection_shifts') IS NOT NULL THEN RAISE EXCEPTION 'guard: view exists'; END IF;
  IF md5(pg_get_viewdef('hr.v_bonus_drift'::regclass)) <> '043e87dcf6ddbd66c4718cc7ac6b6b5d' THEN RAISE EXCEPTION 'guard: hr.v_bonus_drift changed'; END IF;
END $g$;
CREATE TEMP TABLE acl_before ON COMMIT DROP AS SELECT p.oid::regprocedure::text k, p.proacl::text a FROM pg_proc p
 WHERE p.oid IN ('hr.fn_sync_shift_bonus(bigint,date,text,text)'::regprocedure, 'hr.fn_pending_bonus(bigint,date)'::regprocedure, 'hr.get_employee_record(bigint)'::regprocedure, 'hr.set_shift_bonus(bigint,date,numeric,text)'::regprocedure, 'hr.fn_admin_review_url(text,bigint,bigint,date)'::regprocedure, 'public.log_hr_bonus_health()'::regprocedure);
CREATE TEMP TABLE drift_acl ON COMMIT DROP AS SELECT relacl::text a FROM pg_class WHERE oid = 'hr.v_bonus_drift'::regclass;
CREATE TEMP TABLE nets_before ON COMMIT DROP AS
  SELECT g.employee_id, g.work_date, sum(g.amount) net FROM hr.bonus_events g WHERE g.kind = 'shift_bonus' GROUP BY 1, 2;
CREATE TEMP TABLE visit_events_before ON COMMIT DROP AS SELECT count(*) n FROM hr.bonus_events WHERE kind = 'visit_bonus';

-- ---------- the ONE rule that says which PRE and POST forms make one shift ----------
CREATE VIEW public.v_inspection_shifts WITH (security_invoker = true) AS
WITH ev AS (
  SELECT i.id, i.employee_id, i.vehicle_id, i.inspection_type, i.submitted_at, coalesce(i.has_issue, false) AS has_issue,
         (i.submitted_at AT TIME ZONE 'America/New_York') AS et
    FROM public.inspections i
   WHERE i.employee_id IS NOT NULL AND i.inspection_type IN ('PRE', 'POST') AND i.submitted_at IS NOT NULL
),
post_pre AS (
  -- each POST closes the latest PRE of the same person filed before it, within 24 hours, with no other POST in between
  SELECT po.id AS post_id,
         (SELECT pr.id FROM ev pr
           WHERE pr.employee_id = po.employee_id AND pr.inspection_type = 'PRE'
             AND pr.submitted_at <= po.submitted_at AND pr.submitted_at > po.submitted_at - interval '24 hours'
             AND NOT EXISTS (SELECT 1 FROM ev y
                              WHERE y.employee_id = po.employee_id AND y.inspection_type = 'POST' AND y.id <> po.id
                                AND y.submitted_at >= pr.submitted_at
                                AND (y.submitted_at < po.submitted_at OR (y.submitted_at = po.submitted_at AND y.id < po.id)))
           ORDER BY pr.submitted_at DESC, pr.id DESC LIMIT 1) AS pre_id
    FROM ev po WHERE po.inspection_type = 'POST'
),
s AS (
  SELECT pp.pre_id, pp.post_id FROM post_pre pp
  UNION ALL
  SELECT pr.id, NULL::bigint FROM ev pr
   WHERE pr.inspection_type = 'PRE' AND NOT EXISTS (SELECT 1 FROM post_pre pp WHERE pp.pre_id = pr.id)
)
SELECT coalesce(pre.employee_id, post.employee_id) AS employee_id,
       -- the shift is dated by its PRE (ET clock date); a POST with no PRE filed before noon ends the night before
       CASE WHEN pre.id IS NOT NULL THEN pre.et::date
            WHEN post.et::time < time '12:00' THEN post.et::date - 1
            ELSE post.et::date END AS shift_date,
       pre.id AS pre_inspection_id, post.id AS post_inspection_id,
       pre.submitted_at AS pre_submitted_at, post.submitted_at AS post_submitted_at,
       pre.vehicle_id AS pre_vehicle_id, post.vehicle_id AS post_vehicle_id,
       (coalesce(pre.has_issue, false) OR coalesce(post.has_issue, false)) AS has_issue,
       CASE WHEN pre.id IS NOT NULL AND post.id IS NOT NULL THEN 'pair'
            WHEN pre.id IS NOT NULL THEN 'pre_only' ELSE 'post_only' END AS kind
  FROM s
  LEFT JOIN ev pre ON pre.id = s.pre_id
  LEFT JOIN ev post ON post.id = s.post_id;
COMMENT ON VIEW public.v_inspection_shifts IS
  'One row per person per shift (Trello ZEYkT63t, Fred 2026-10-21): a POST closes the latest PRE of the same person filed '
  'before it within 24 hours with no other POST in between (a night shift: PRE about 9 PM, POST the next morning). The '
  'shift is dated by its PRE''s ET clock date; a POST with no PRE filed before noon ET belongs to the night before. Read '
  'by Admin Review (queue, Shift Form Review) and by every hr function that needs a shift''s forms. (employee_id, '
  'shift_date) is unique since 2026-09-01; 13 Airtable-era shifts before it collide (health item shift_pairing_collision '
  'watches from 2026-09-01 on).';
REVOKE ALL ON public.v_inspection_shifts FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.v_inspection_shifts TO authenticated, service_role, db_backup_reader;


CREATE OR REPLACE VIEW hr.v_bonus_drift AS
WITH open_grants AS (
         SELECT g.id,
            g.kind,
            g.employee_id,
            g.visit_id,
            g.work_date,
            g.amount,
            g.pay_rate_id,
            g.rule,
            g.note,
            g.crew_size,
            g.pre_present,
            g.post_present,
            g.forms_issue,
            g.decided_by_email,
            g.decided_at,
            g.reverses_id,
            g.filled_by,
            g.created_at
           FROM hr.bonus_events g
          WHERE ((g.reverses_id IS NULL) AND (NOT (EXISTS ( SELECT 1
                   FROM hr.bonus_events r
                  WHERE (r.reverses_id = g.id)))))
        ), approved_visits AS (
         SELECT vr.visit_id
           FROM visit_reviews vr
          WHERE (vr.bonus_status = 'approved'::text)
        )
 SELECT 'missing_grant'::text AS problem,
    'visit_bonus'::text AS kind,
    a.visit_id,
    NULL::bigint AS employee_id,
    NULL::date AS work_date
   FROM approved_visits a
  WHERE (hr.fn_visit_bonus_expected(a.visit_id) AND (EXISTS ( SELECT 1
           FROM visit_team vt
          WHERE (vt.visit_id = a.visit_id))) AND (NOT (EXISTS ( SELECT 1
           FROM open_grants g
          WHERE ((g.kind = 'visit_bonus'::text) AND (g.visit_id = a.visit_id))))))
UNION ALL
 SELECT 'approved_no_crew'::text AS problem,
    'visit_bonus'::text AS kind,
    a.visit_id,
    NULL::bigint AS employee_id,
    NULL::date AS work_date
   FROM approved_visits a
  WHERE (hr.fn_visit_bonus_expected(a.visit_id) AND (NOT (EXISTS ( SELECT 1
           FROM visit_team vt
          WHERE (vt.visit_id = a.visit_id)))))
UNION ALL
 SELECT 'grant_not_expected'::text AS problem,
    g.kind,
    g.visit_id,
    g.employee_id,
    g.work_date
   FROM open_grants g
  WHERE (((g.kind = 'visit_bonus'::text) AND (NOT hr.fn_visit_bonus_expected(g.visit_id))) OR ((g.kind = 'shift_bonus'::text) AND (NOT (EXISTS ( SELECT 1
           FROM shift_reviews sr
          WHERE ((sr.employee_id = g.employee_id) AND (sr.shift_date = g.work_date) AND (sr.bonus_status = 'approved'::text)))))))
UNION ALL
 SELECT 'missing_grant'::text AS problem,
    'shift_bonus'::text AS kind,
    NULL::bigint AS visit_id,
    sr.employee_id,
    sr.shift_date AS work_date
   FROM shift_reviews sr
  WHERE ((sr.bonus_status = 'approved'::text) AND (NOT (EXISTS ( SELECT 1
           FROM open_grants g
          WHERE ((g.kind = 'shift_bonus'::text) AND (g.employee_id = sr.employee_id) AND (g.work_date = sr.shift_date))))))
UNION ALL
 SELECT 'shift_forms_issue'::text AS problem,
    g.kind,
    NULL::bigint AS visit_id,
    g.employee_id,
    g.work_date
   FROM open_grants g
  WHERE (g.rule = 'forms_issue'::text)
UNION ALL
 SELECT 'decider_unknown'::text AS problem,
    g.kind,
    g.visit_id,
    g.employee_id,
    g.work_date
   FROM open_grants g
  WHERE ((g.decided_by_email IS NULL) OR (NOT (EXISTS ( SELECT 1
           FROM employees e
          WHERE ((e.status = 'ACTIVE'::text) AND (e.access_level = ANY (ARRAY['admin'::text, 'office'::text])) AND (lower(btrim(e.email)) = g.decided_by_email))))))
UNION ALL
 SELECT 'decider_is_earner'::text AS problem,
    g.kind,
    g.visit_id,
    g.employee_id,
    g.work_date
   FROM (open_grants g
     JOIN employees e ON ((e.id = g.employee_id)))
  WHERE ((g.decided_by_email IS NOT NULL) AND (lower(btrim(e.email)) = g.decided_by_email))
UNION ALL
 SELECT 'shift_pairing_collision'::text AS problem,
    'shift_bonus'::text AS kind,
    NULL::bigint AS visit_id,
    s.employee_id,
    s.shift_date AS work_date
   FROM public.v_inspection_shifts s
  WHERE s.shift_date >= '2026-09-01'::date
  GROUP BY s.employee_id, s.shift_date
 HAVING count(*) > 1;

CREATE OR REPLACE FUNCTION hr.fn_sync_shift_bonus(p_employee_id bigint, p_shift_date date, p_filled_by text, p_decider text DEFAULT NULL::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_expected boolean; v_open int; v_n int := 0; v_decided timestamptz; v_status text;
  v_pre record; v_post record; v_issue boolean; v_rate_id bigint; v_amount numeric; v_decider text := p_decider;
  v_note text; v_g record; v_ovr bigint; v_custom boolean; v_cnote text;
begin
  perform pg_advisory_xact_lock(hashtextextended('hr.bonus.shift:' || p_employee_id || ':' || p_shift_date, 0));
  select sr.bonus_status, sr.bonus_decided_at into v_status, v_decided
    from public.shift_reviews sr where sr.employee_id = p_employee_id and sr.shift_date = p_shift_date;
  v_expected := coalesce(v_status = 'approved', false);
  select count(*) into v_open from hr.bonus_events g
   where g.kind = 'shift_bonus' and g.employee_id = p_employee_id and g.work_date = p_shift_date and g.reverses_id is null
     and not exists (select 1 from hr.bonus_events r where r.reverses_id = g.id);

  if v_expected and v_open = 0 then
    -- 2026-10-21 (Trello ZEYkT63t): the shift's forms come from public.v_inspection_shifts (a night shift's PRE is filed
    -- one evening and its POST the next morning), never from inspections.shift_date
    select i.id, coalesce(i.has_issue, false) as has_issue into v_pre from public.inspections i
     where i.id = (select s.pre_inspection_id from public.v_inspection_shifts s where s.employee_id = p_employee_id and s.shift_date = p_shift_date
                    order by s.pre_inspection_id nulls last, s.post_inspection_id nulls last limit 1);
    select i.id, coalesce(i.has_issue, false) as has_issue into v_post from public.inspections i
     where i.id = (select s.post_inspection_id from public.v_inspection_shifts s where s.employee_id = p_employee_id and s.shift_date = p_shift_date
                    order by s.pre_inspection_id nulls last, s.post_inspection_id nulls last limit 1);
    v_issue := coalesce(v_pre.has_issue, false) or coalesce(v_post.has_issue, false);
    -- 2026-10-21 (Fred): a custom amount set for this person on this shift replaces their normal amount
    select r.rate_id, r.amount, r.override_id, r.custom_note into v_rate_id, v_amount, v_ovr, v_cnote
      from hr.fn_shift_rate_on(p_employee_id, p_shift_date) r;
    if v_decider is null and p_filled_by <> 'trigger' then
      v_decider := hr.fn_review_decider('shift_reviews',
        jsonb_build_object('employee_id', p_employee_id, 'shift_date', to_char(p_shift_date, 'YYYY-MM-DD')));
    end if;
    insert into hr.bonus_events (kind, employee_id, work_date, amount, pay_rate_id, rule, note, pre_present, post_present,
                                 forms_issue, decided_by_email, decided_at, filled_by, shift_override_id)
    values ('shift_bonus', p_employee_id, p_shift_date,
            -- 2026-10-21 (Fred, ZEYkT63t): the reviewer's approval is paid, also with a form missing or reporting an issue;
            -- only a shift with no form at all records $0
            case when v_pre.id is null and v_post.id is null then 0 else coalesce(v_amount, 0) end,
            v_rate_id,
            case when v_pre.id is null and v_post.id is null then 'forms_issue' else 'approved' end,
            case when v_pre.id is null and v_post.id is null then 'No form was found for that shift, so nothing is paid.'
                 else nullif(concat_ws(' ', rtrim(v_cnote, '.') || '.',
                        case when v_pre.id is null then 'Approved in Admin Review without the start-of-shift (PRE) form.'
                             when v_post.id is null then 'Approved in Admin Review without the end-of-shift (POST) form.' end,
                        case when v_issue then 'A form reports an issue; approved in Admin Review.' end), '') end,
            v_pre.id is not null, v_post.id is not null, v_issue, v_decider, coalesce(v_decided, now()), p_filled_by, v_ovr);
    v_n := 1;
  elsif v_expected and v_open > 0 then
    -- 2026-10-21 (Fred): the custom amount of this shift changed after the bonus was recorded: taken back and recorded
    -- again. Only a change to THIS shift's custom amount re-prices (never a normal-amount change), and a $0 forms-issue
    -- shift stays $0. A grant recorded before any custom amount has shift_override_id NULL, as fn_shift_rate_on has while
    -- the shift has none, so nothing older than this rule can move.
    for v_g in select * from hr.bonus_events g
              where g.kind = 'shift_bonus' and g.employee_id = p_employee_id and g.work_date = p_shift_date
                and g.reverses_id is null and g.rule = 'approved'
                and not exists (select 1 from hr.bonus_events r where r.reverses_id = g.id)
              order by g.id loop
      select r.rate_id, r.amount, r.override_id, r.custom, r.custom_note into v_rate_id, v_amount, v_ovr, v_custom, v_cnote
        from hr.fn_shift_rate_on(p_employee_id, p_shift_date) r;
      continue when v_ovr is not distinct from v_g.shift_override_id or coalesce(v_amount, 0) = v_g.amount;
      insert into hr.bonus_events (kind, employee_id, work_date, amount, pay_rate_id, rule, note, pre_present, post_present,
                                   forms_issue, decided_by_email, decided_at, reverses_id, filled_by)
      values ('shift_bonus', v_g.employee_id, v_g.work_date, -v_g.amount, v_g.pay_rate_id, 'reversal',
              case when v_custom then 'Replaced by the custom amount set for this shift.'
                   else 'The custom amount for this shift was removed.' end,
              v_g.pre_present, v_g.post_present, v_g.forms_issue, p_decider, now(), v_g.id, p_filled_by);
      insert into hr.bonus_events (kind, employee_id, work_date, amount, pay_rate_id, rule, note, pre_present, post_present,
                                   forms_issue, decided_by_email, decided_at, filled_by, shift_override_id)
      values ('shift_bonus', v_g.employee_id, v_g.work_date, coalesce(v_amount, 0), v_rate_id, 'approved', v_cnote,
              v_g.pre_present, v_g.post_present, v_g.forms_issue, coalesce(p_decider, v_g.decided_by_email), now(),
              p_filled_by, v_ovr);
      v_n := v_n + 2;
    end loop;
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
end $function$;

CREATE OR REPLACE FUNCTION hr.fn_pending_bonus(p_employee_id bigint, p_today date)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce((
    select sum(coalesce(r.amount, 0))
      from public.visits_with_review v
      join public.visit_team vt on vt.visit_id = v.id and vt.employee_id = p_employee_id
      cross join lateral hr.fn_visit_rate_on(p_employee_id, v.id, v.visit_date) r
     where v.visit_status = 'completed' and v.in_review_scope
       and v.visit_date <= p_today and coalesce(v.bonus_status, 'pending') = 'pending'
       and not public.fn_is_non_customer(v.client_id)), 0)
  + coalesce((
    select sum(coalesce(r.amount, 0))
      from (select v.shift_date   -- 2026-10-21 ZEYkT63t: paired shifts, an issue no longer blocks
              from public.v_inspection_shifts v
             where v.employee_id = p_employee_id and v.shift_date >= p_today - 28 and v.shift_date <= p_today and v.kind = 'pair'
             group by v.shift_date) s
      cross join lateral hr.fn_shift_rate_on(p_employee_id, s.shift_date) r
     where not exists (select 1 from public.shift_reviews sr
                        where sr.employee_id = p_employee_id and sr.shift_date = s.shift_date
                          and coalesce(sr.bonus_status, 'pending') <> 'pending')), 0)
$function$;

CREATE OR REPLACE FUNCTION hr.get_employee_record(p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_caller bigint; v_level text; v_e public.employees; v_pay boolean; v_seebonus boolean; v_can_edit boolean;
  v_today date := (now() at time zone 'America/New_York')::date;
  v_rates jsonb; v_history jsonb; v_weeks jsonb; v_activity jsonb; v_company jsonb; v_bonus jsonb;
begin
  select c.employee_id, c.access_level into v_caller, v_level from hr.fn_require_level(array['admin', 'office']) c;
  select * into v_e from public.employees where id = p_id;
  if not found then
    raise exception 'That person was not found. Reload the page.' using errcode = 'P0002', detail = 'blocker=not_found employee_id=' || p_id;
  end if;
  -- 2026-10-19_2200: the HR App checks the person's access settings (hr.access_*); pay rates follow "Pay rates and bonus
  -- settings", bonuses "See bonus amounts", editing the HR App level. While a row is not checked, the old group rule stands.
  perform hr.fn_require_app('hr', 'view');
  v_pay := case when hr.fn_app_mode('hr_pay') = 'on' then hr.fn_app_level('hr_pay') = 'yes' else v_level = 'admin' end;
  v_seebonus := case when hr.fn_app_mode('hr_bonus') = 'on' then hr.fn_app_level('hr_bonus') = 'yes' else true end;
  v_can_edit := case when hr.fn_app_mode('hr') = 'on' then hr.fn_app_level('hr') = 'edit' else true end;

  v_company := jsonb_build_object(
    'per_visit_bonus', (select r.amount from hr.fn_rate_on(p_id, 'per_visit_bonus', v_today) r),
    'per_shift_bonus', (select r.amount from hr.fn_rate_on(p_id, 'per_shift_bonus', v_today) r));

  -- 2026-10-19_1200: this person's own bonus amounts (admin and office), with the next scheduled change
  select jsonb_object_agg(k.kind, jsonb_build_object(
           'amount', r.amount,
           'since', p.effective_from,
           'next', (select jsonb_build_object('amount', n.amount, 'effective_from', n.effective_from)
                      from hr.pay_rates n where n.employee_id = p_id and n.kind = k.kind and n.effective_from > v_today
                       and not hr.fn_rate_superseded(n.id, n.employee_id, n.kind, n.effective_from)
                     order by n.effective_from, n.id desc limit 1)))
    into v_bonus
    from unnest(array['per_visit_bonus', 'per_shift_bonus']) k(kind)
    cross join lateral hr.fn_rate_on(p_id, k.kind, v_today) r
    left join hr.pay_rates p on p.id = r.rate_id;

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
    -- 2026-10-19_1815 (Fred): pay rate changes are shown in Activity, never in this history table
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
      'reversed', exists (select 1 from hr.bonus_events r where r.reverses_id = g.id),
      -- 2026-10-19_0215: structured fields (additive; the keys above are unchanged)
      'bonus_kind', g.kind, 'rule', g.rule, 'visit_id', g.visit_id,
      'client_code', c.client_code, 'client_name', c.name,
      'crew_size', g.crew_size,
      'shared_with', (select jsonb_agg(e2.full_name order by e2.full_name)
                        from hr.bonus_events b2 join public.employees e2 on e2.id = b2.employee_id
                       where g.visit_id is not null and b2.visit_id = g.visit_id and b2.employee_id <> g.employee_id
                         and b2.kind = 'visit_bonus' and b2.reverses_id is null
                         and not exists (select 1 from hr.bonus_events r2 where r2.reverses_id = b2.id)),
      'note', g.note,
      'decided_on', (g.decided_at at time zone 'America/New_York')::date, 'decided_time', to_char(g.decided_at at time zone 'America/New_York', 'HH24:MI'),
      'recorded_on', (g.created_at at time zone 'America/New_York')::date,
      'week_start', hr.fn_payroll_week_start(g.work_date, v_e.payroll_week_start_day), 'week_end', hr.fn_payroll_week_start(g.work_date, v_e.payroll_week_start_day) + 6,
      'reverses_id', g.reverses_id,
      'reversed_on', (select (r.created_at at time zone 'America/New_York')::date from hr.bonus_events r where r.reverses_id = g.id order by r.id limit 1),
      'after_week_ended', case when g.rule = 'reversal'
                               then (g.created_at at time zone 'America/New_York')::date > hr.fn_payroll_week_start(g.work_date, v_e.payroll_week_start_day) + 6
                               else (select (r.created_at at time zone 'America/New_York')::date > hr.fn_payroll_week_start(g.work_date, v_e.payroll_week_start_day) + 6
                                       from hr.bonus_events r where r.reverses_id = g.id order by r.id limit 1) end,
      'counts_in_total', true,
      'admin_review_url', hr.fn_admin_review_url(g.kind, g.visit_id, g.employee_id, g.work_date),
      -- 2026-10-19_1900 (Fred): every row says its status
      'status', case when g.rule = 'reversal' then 'taken_back' else 'approved' end) h
      from hr.bonus_events g
      left join public.visits v on v.id = g.visit_id
      left join public.clients c on c.id = v.client_id
     where g.employee_id = p_id
    -- 2026-10-19_1900 (Fred): the bonuses not recorded in HR, so the table shows every bonus with its status.
    -- Pending: what Admin Review still has to decide (the same scope as hr.fn_pending_bonus), priced at the person's
    -- rate on the work date. Rejected: a decision of "not eligible", $0, with Admin Review's reason. Neither counts in
    -- a total. Ids are negative (visits: -visit_id; shifts: -(1000000 + days since 2020-01-01)) so a row key never
    -- equals a recorded bonus id.
    union all
    select jsonb_build_object(
      'id', -v.id, 'type', 'visit_bonus', 'date', v.visit_date, 'sort_at', v.completed_at,
      'title', 'Visit bonus', 'amount', case when coalesce(v.bonus_status, 'pending') = 'pending' then coalesce(r.amount, 0) else 0 end,
      'detail', concat_ws(' ', c.client_code, c.name),
      'by', case when v.bonus_status = 'denied' then coalesce(hr.fn_person_label(rj.email), 'Admin Review') end,
      'decided_at', case when v.bonus_status = 'denied' then vr.bonus_decided_at end,
      'link', '/review/' || v.id,
      'bonus_kind', 'visit_bonus', 'rule', case when v.bonus_status = 'denied' then 'denied' else 'pending' end,
      'visit_id', v.id, 'client_code', c.client_code, 'client_name', c.name,
      'crew_size', (select count(*) from public.visit_team t2 where t2.visit_id = v.id),
      'shared_with', (select jsonb_agg(e2.full_name order by e2.full_name) from public.visit_team t2
                        join public.employees e2 on e2.id = t2.employee_id where t2.visit_id = v.id and t2.employee_id <> p_id),
      'note', case when v.bonus_status = 'denied' then vr.bonus_denial_note else r.custom_note end,
      'decided_on', case when v.bonus_status = 'denied' then (vr.bonus_decided_at at time zone 'America/New_York')::date end,
      'decided_time', case when v.bonus_status = 'denied' then to_char(vr.bonus_decided_at at time zone 'America/New_York', 'HH24:MI') end,
      'week_start', hr.fn_payroll_week_start(v.visit_date, v_e.payroll_week_start_day), 'week_end', hr.fn_payroll_week_start(v.visit_date, v_e.payroll_week_start_day) + 6,
      'admin_review_url', hr.fn_admin_review_url('visit_bonus', v.id, p_id, v.visit_date),
      'status', case when v.bonus_status = 'denied' then 'rejected' else 'pending' end)
      || jsonb_build_object(
      'unit', null, 'source', 'Admin Review', 'reversed', false, 'reverses_id', null, 'reversed_on', null,
      'after_week_ended', false, 'counts_in_total', false, 'recorded_on', null) h
      from public.visits_with_review v
      join public.visit_team t on t.visit_id = v.id and t.employee_id = p_id
      left join public.visit_reviews vr on vr.visit_id = v.id
      left join public.clients c on c.id = v.client_id
      left join lateral hr.fn_visit_rate_on(p_id, v.id, v.visit_date) r on true
      left join lateral (select lower(btrim(nullif(a.jwt_claims->>'email', ''))) as email from audit.logs a
                          where a.table_name = 'visit_reviews' and a.record_pk = jsonb_build_object('visit_id', v.id)
                            and a.new_row->>'bonus_status' = 'denied'
                            and (a.old_row is null or a.old_row->>'bonus_status' is distinct from 'denied')
                          order by a.id desc limit 1) rj on v.bonus_status = 'denied'
     where v.visit_status = 'completed' and not public.fn_is_non_customer(v.client_id)
       and ((coalesce(v.bonus_status, 'pending') = 'pending' and v.in_review_scope and v.visit_date <= v_today)
            or v.bonus_status = 'denied')
    union all
    select jsonb_build_object(
      'id', -(1000000 + (x.shift_date - date '2020-01-01')), 'type', 'shift_bonus', 'date', x.shift_date, 'sort_at', x.shift_date::timestamptz,
      'title', 'Shift bonus', 'amount', case when x.status = 'pending' then coalesce(r.amount, 0) else 0 end,
      'detail', 'Shift forms of ' || to_char(x.shift_date, 'Mon FMDD'),
      'by', case when x.status = 'rejected' then coalesce(hr.fn_person_label(rj.email), 'Admin Review') end,
      'decided_at', x.decided_at, 'link', '/review-shift/shift-' || p_id || '-' || to_char(x.shift_date, 'YYYY-MM-DD'),
      'bonus_kind', 'shift_bonus', 'rule', case when x.status = 'rejected' then 'denied' else 'pending' end,
      'visit_id', null, 'client_code', null, 'client_name', null, 'crew_size', null, 'shared_with', null,
      'note', coalesce(x.note, case when x.status = 'pending' then r.custom_note end),
      'decided_on', (x.decided_at at time zone 'America/New_York')::date,
      'decided_time', to_char(x.decided_at at time zone 'America/New_York', 'HH24:MI'),
      'week_start', hr.fn_payroll_week_start(x.shift_date, v_e.payroll_week_start_day), 'week_end', hr.fn_payroll_week_start(x.shift_date, v_e.payroll_week_start_day) + 6,
      'admin_review_url', hr.fn_admin_review_url('shift_bonus', null, p_id, x.shift_date),
      'status', x.status)
      || jsonb_build_object(
      'unit', null, 'source', 'Admin Review', 'reversed', false, 'reverses_id', null, 'reversed_on', null,
      'after_week_ended', false, 'counts_in_total', false, 'recorded_on', null) h
      from (
        -- pending: the shifts of the last 28 days with both forms and no issue, not decided (as hr.fn_pending_bonus)
        select s.shift_date, 'pending'::text as status, null::timestamptz as decided_at, null::text as note
          from (select v.shift_date from public.v_inspection_shifts v   -- 2026-10-21 ZEYkT63t: paired shifts
                 where v.employee_id = p_id and v.shift_date >= v_today - 28 and v.shift_date <= v_today and v.kind = 'pair'
                 group by v.shift_date) s
         where not exists (select 1 from public.shift_reviews sr where sr.employee_id = p_id and sr.shift_date = s.shift_date
                             and coalesce(sr.bonus_status, 'pending') <> 'pending')
        union all
        select sr.shift_date, 'rejected', sr.bonus_decided_at, sr.bonus_denial_note
          from public.shift_reviews sr where sr.employee_id = p_id and sr.bonus_status = 'denied'
      ) x
      left join lateral hr.fn_shift_rate_on(p_id, x.shift_date) r on true
      left join lateral (select lower(btrim(nullif(a.jwt_claims->>'email', ''))) as email from audit.logs a
                          where a.table_name = 'shift_reviews'
                            and a.record_pk = jsonb_build_object('employee_id', p_id, 'shift_date', to_char(x.shift_date, 'YYYY-MM-DD'))
                            and a.new_row->>'bonus_status' = 'denied'
                            and (a.old_row is null or a.old_row->>'bonus_status' is distinct from 'denied')
                          order by a.id desc limit 1) rj on x.status = 'rejected'
  ) s;

  select coalesce(jsonb_agg(w order by w->>'week_start' desc), '[]'::jsonb) into v_weeks from (
    select jsonb_build_object('week_start', hr.fn_payroll_week_start(g.work_date, v_e.payroll_week_start_day),
                              'week_end', hr.fn_payroll_week_start(g.work_date, v_e.payroll_week_start_day) + 6,
                              'total', sum(g.amount),
                              'visit_bonuses', count(*) filter (where g.kind = 'visit_bonus' and g.rule <> 'reversal'),
                              'shift_bonuses', count(*) filter (where g.kind = 'shift_bonus' and g.rule <> 'reversal')) w
      from hr.bonus_events g where g.employee_id = p_id
     group by hr.fn_payroll_week_start(g.work_date, v_e.payroll_week_start_day)) s;

  select coalesce(jsonb_agg(a order by (a->>'at') desc, (a->>'id')::bigint desc), '[]'::jsonb) into v_activity from (
    select a from (
    select jsonb_build_object(
      'id', l.id, 'at', l.changed_at, 'operation', l.operation,
      'by', coalesce(hr.fn_person_label(l.jwt_claims->>'email'),
                     case when l.app_source is null then 'Not recorded'
                          when l.app_source = 'sql' then 'Changed outside the apps'
                          when l.app_source = 'employee-dedup-merge' then 'Duplicate clean-up'
                          when l.app_source = 'hr-app' then 'HR App'
                          when l.app_source = 'admin-review' then 'Admin Review'
                          when l.app_source = 'visit-calendar' then 'Visit Calendar'
                          when l.app_source = 'client-app' then 'Client App'
                          when l.app_source = 'derm-tracker' then 'DERM Tracker'
                          when l.app_source = 'jobber' then 'Jobber sync'
                          else 'Another app' end),
      'app', case l.app_source when 'hr-app' then 'HR App' else null end,
      'changes', (select coalesce(jsonb_agg(jsonb_build_object('field', f.label,
                      -- 2026-10-19_2130: the payroll week is stored as a day number; Activity shows "Thu to Wed"
                      'old', case when f.col = 'payroll_week_start_day' then hr.fn_week_label((l.old_row->>f.col)::smallint) else l.old_row->>f.col end,
                      'new', case when f.col = 'payroll_week_start_day' then hr.fn_week_label((l.new_row->>f.col)::smallint) else l.new_row->>f.col end)
                                             order by f.ord), '[]'::jsonb)
                    from (values (1, 'full_name', 'Name'), (2, 'status', 'Status'), (3, 'shift', 'Shift'), (4, 'email', 'Email'),
                                 (5, 'phone', 'Phone'), (6, 'hire_date', 'Start date'), (7, 'access_level', 'Access'),
                                 (8, 'color_hex', 'Color'), (9, 'payroll_week_start_day', 'Payroll week')) f(ord, col, label)
                   where l.operation = 'INSERT' and l.new_row->>f.col is not null
                      or l.operation = 'UPDATE' and (l.old_row->>f.col) is distinct from (l.new_row->>f.col))) a
      from audit.logs l
     where l.table_name = 'employees' and l.record_pk->>'id' = p_id::text
     order by l.id desc limit 100) s
   where jsonb_array_length(a->'changes') > 0 or a->>'operation' <> 'UPDATE'
  -- 2026-10-19_1815 (Fred): pay rate changes are part of the person's Activity. Bonus amounts for admin and office,
  -- hourly and salary for admin only. The id is negative so it can never equal an audit row id.
  union all
  select jsonb_build_object(
      'id', -p.id, 'at', p.created_at, 'operation', 'RATE',
      'by', coalesce(hr.fn_person_label(p.created_by_email), 'Changed outside the apps'),
      'app', 'HR App',
      'changes', jsonb_build_array(
        jsonb_build_object('field', case p.kind when 'hourly' then 'Hourly rate' when 'salary_weekly' then 'Weekly salary'
                                                when 'salary_yearly' then 'Yearly salary' when 'per_visit_bonus' then 'Visit bonus'
                                                else 'Shift bonus' end,
                           'old', case when p.prev_amount is null then null else to_char(p.prev_amount, 'FM$999,999,990.00') end,
                           'new', coalesce(to_char(p.amount, 'FM$999,999,990.00'), 'Stopped')
                                  || ' from ' || to_char(p.effective_from, 'Mon FMDD, YYYY')),
        jsonb_build_object('field', 'Reason', 'old', null, 'new', p.reason))
      -- 2026-10-21 (Fred): an amount change that also moved approved bonuses says how many
      || coalesce((select jsonb_build_array(jsonb_build_object('field', 'Approved bonuses updated', 'old', null,
                     'new', count(*) || case when p.kind = 'per_shift_bonus' then ' shift' else ' visit' end
                            || case when count(*) = 1 then '' else 's' end || ' changed to the new amount'))
                     from hr.bonus_events b where b.reprice_rate_id = p.id and b.reverses_id is null having count(*) > 0),
                  '[]'::jsonb)
      -- 2026-10-21 (Fred: "make since replace later amounts too"): the later dated amounts this change replaced
      || coalesce((select jsonb_build_array(jsonb_build_object('field', 'Replaces later amounts', 'old', null,
                     'new', string_agg(to_char(o.amount, 'FM$999,999,990.00') || ' from ' || to_char(o.effective_from, 'Mon FMDD, YYYY'), ', '
                                       order by o.effective_from)))
                     from (select distinct on (o0.effective_from) o0.* from hr.pay_rates o0
                            where p.replaces_later and o0.employee_id = p.employee_id and o0.kind = p.kind
                              and o0.effective_from > p.effective_from and o0.id < p.id
                              and not exists (select 1 from hr.pay_rates y where y.employee_id = o0.employee_id and y.kind = o0.kind
                                                and y.replaces_later and y.id > o0.id and y.id < p.id and y.effective_from <= o0.effective_from)
                            order by o0.effective_from, o0.id desc) o
                   having count(*) > 0), '[]'::jsonb)) a
    from (select p0.*, lag(p0.amount) over (partition by p0.kind order by p0.effective_from, p0.id) as prev_amount
            from hr.pay_rates p0 where p0.employee_id = p_id) p
   where (p.kind in ('per_visit_bonus', 'per_shift_bonus') and v_seebonus) or v_pay
  -- 2026-10-20 (Trello bZvoo91Z, Fred: "that should be saved who change that number btw in the history activity"): a
  -- custom visit bonus amount set or removed in Admin Review for this person on one visit.
  union all
  select jsonb_build_object(
      'id', -(2000000000 + o.id), 'at', o.created_at, 'operation', 'RATE',
      'by', coalesce(hr.fn_person_label(o.created_by_email), 'Changed outside the apps'),
      'app', 'Admin Review',
      'changes', jsonb_build_array(
        jsonb_build_object('field', 'Visit bonus, ' || concat_ws(' ', c.client_code, to_char(v.visit_date, 'Mon FMDD, YYYY')),
                           'old', case when o.prev_amount is not null then to_char(o.prev_amount, 'FM$999,999,990.00') || ' for this visit'
                                       else 'Normal amount' end,
                           'new', case when o.amount is not null then to_char(o.amount, 'FM$999,999,990.00') || ' for this visit'
                                       else 'Normal amount' end))
      || case when o.reason is not null then jsonb_build_array(jsonb_build_object('field', 'Reason', 'old', null, 'new', o.reason))
              else '[]'::jsonb end) a
    from (select o0.*, lag(o0.amount) over (partition by o0.visit_id order by o0.id) as prev_amount
            from hr.visit_bonus_overrides o0 where o0.employee_id = p_id) o
    join public.visits v on v.id = o.visit_id
    left join public.clients c on c.id = v.client_id
   where v_seebonus
     and not public.fn_is_non_customer(v.client_id)   -- 2026-10-20 (Fred): a smoke test on the test client never reaches HR
  -- 2026-10-21 (Fred): a custom SHIFT bonus amount set or removed in Admin Review for this person on one shift.
  union all
  select jsonb_build_object(
      'id', -(3000000000 + o.id), 'at', o.created_at, 'operation', 'RATE',
      'by', coalesce(hr.fn_person_label(o.created_by_email), 'Changed outside the apps'),
      'app', 'Admin Review',
      'changes', jsonb_build_array(
        jsonb_build_object('field', 'Shift bonus, ' || to_char(o.shift_date, 'Mon FMDD, YYYY'),
                           'old', case when o.prev_amount is not null then to_char(o.prev_amount, 'FM$999,999,990.00') || ' for this shift'
                                       else 'Normal amount' end,
                           'new', case when o.amount is not null then to_char(o.amount, 'FM$999,999,990.00') || ' for this shift'
                                       else 'Normal amount' end))
      || case when o.reason is not null then jsonb_build_array(jsonb_build_object('field', 'Reason', 'old', null, 'new', o.reason))
              else '[]'::jsonb end) a
    from (select o0.*, lag(o0.amount) over (partition by o0.shift_date order by o0.id) as prev_amount
            from hr.shift_bonus_overrides o0 where o0.employee_id = p_id) o
   where v_seebonus
  -- 2026-10-19_2145: a change to this person's own access settings ("Visit Calendar: Group default -> View")
  union all
  select jsonb_build_object(
      'id', l.id, 'at', l.changed_at, 'operation', 'ACCESS',
      'by', coalesce(hr.fn_person_label(l.jwt_claims->>'email'), 'Changed outside the apps'),
      'app', 'HR App',
      'changes', jsonb_build_array(jsonb_build_object(
        'field', coalesce(ap.name, coalesce(l.new_row, l.old_row)->>'app'),
        'old', case when l.operation = 'INSERT' then 'Group default' else hr.fn_access_label(l.old_row->>'level') end,
        'new', case when l.operation = 'DELETE' then 'Group default' else hr.fn_access_label(l.new_row->>'level') end))) a
    from audit.logs l
    left join hr.access_apps ap on ap.app = coalesce(l.new_row, l.old_row)->>'app'
   where l.table_schema = 'hr' and l.table_name = 'access_overrides' and v_level = 'admin'   -- 2026-10-19_2230: admins only
     and coalesce(l.new_row, l.old_row)->>'employee_id' = p_id::text
     and (l.operation <> 'UPDATE' or (l.old_row->>'level') is distinct from (l.new_row->>'level'))
  -- 2026-10-19_2300: sign-in changes made from the HR App ("Password reset email sent")
  union all
  select jsonb_build_object(
      'id', -(1000000000 + c.id), 'at', coalesce(c.finished_at, c.created_at), 'operation', 'SIGN_IN',
      'by', coalesce(hr.fn_person_label(c.requested_by_email), 'HR App'), 'app', 'HR App',
      'changes', jsonb_build_array(jsonb_build_object('field', 'Sign-in', 'old', null,
        'new', case c.action when 'reset_email' then 'Password reset email sent' when 'turn_off' then 'Sign-in turned off'
                             when 'sign_out' then 'Signed out on ' || coalesce(c.reason, 'every device')
                             else 'Sign-in turned back on' end
               || case when c.status = 'failed' then ' (failed: ' || coalesce(c.reason, 'no reason') || ')' else '' end))) a
    from hr.sign_in_changes c
   where c.employee_id = p_id and c.status in ('done', 'failed') and v_level = 'admin'
  ) s2;

  if not v_seebonus then
    v_history := '[]'::jsonb; v_weeks := '[]'::jsonb; v_bonus := null; v_company := null;
  end if;

  return jsonb_build_object(
    'employee', hr.fn_employee_json(v_e),
    'viewer', jsonb_build_object('level', v_level, 'can_edit', v_can_edit, 'can_see_pay', v_pay, 'can_see_bonus', v_seebonus, 'is_self', v_e.id = v_caller,
                                 -- 2026-10-19_2145 (decision 10): access follows the email, so only an admin changes email or status
                                 'can_change_email_status', v_e.id <> v_caller and v_level = 'admin',
                                 -- 2026-10-19_2130: only an admin changes a person's payroll week (hr.set_payroll_week)
                                 'can_set_payroll_week', v_pay,
                                 -- 2026-10-19_2300: send a reset email, turn a sign-in off or on (admins, never their own)
                                 'can_manage_sign_in', v_level = 'admin' and v_e.id <> v_caller),
    'sign_in', hr.fn_sign_in_summary(p_id),
    'impact_if_inactive', hr.fn_employee_impact(p_id),
    'company_bonus', v_company,
    'bonus_amounts', v_bonus,
    'rates', v_rates,
    'history', v_history,
    'bonus_weeks', v_weeks,
    'activity', v_activity);
end $function$;

CREATE OR REPLACE FUNCTION hr.set_shift_bonus(p_employee_id bigint, p_shift_date date, p_amount numeric, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-10-21 (Fred): the shift twin of hr.set_visit_bonus. One person's shift bonus on ONE shift; p_amount NULL goes back to
-- their normal amount. Same people (admins, or office with "Pay rates and bonus settings"; Edit in Admin Review). The shift
-- must have at least one form. Every change is a new row; a bonus already recorded is taken back and recorded again at the
-- new amount. Since 2026-10-21 (ZEYkT63t) an approved shift is paid even with a form missing or reporting an issue.
declare
  v_email text := lower(btrim(nullif(auth.jwt()->>'email', '')));
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_current numeric; v_rows int;
begin
  perform hr.fn_check_app('admin_review', 'edit', 'shift bonus amount');
  perform 1 from hr.fn_require_level(array['admin', 'office']);
  perform hr.fn_require_app_or_level('hr_pay', 'yes', array['admin']);
  if not exists (select 1 from public.employees where id = p_employee_id) then
    raise exception 'That person was not found. Reload the page.' using errcode = 'P0002', detail = 'blocker=not_found employee_id=' || coalesce(p_employee_id::text, 'null');
  end if;
  if p_shift_date is null or not exists (select 1 from public.v_inspection_shifts s where s.employee_id = p_employee_id and s.shift_date = p_shift_date) then
    raise exception 'That shift has no forms, so it has no bonus to change. Nothing was saved.' using errcode = '22023', detail = 'blocker=no_shift';
  end if;
  if p_amount is not null and (p_amount < 0 or p_amount > 1000 or p_amount <> round(p_amount, 2)) then
    raise exception 'The amount must be between $0 and $1,000, in cents at most. Nothing was saved.' using errcode = '22023', detail = 'blocker=amount_range';
  end if;
  if length(v_reason) > 500 then
    raise exception 'The reason is too long (500 characters at most). Nothing was saved.' using errcode = '22023', detail = 'blocker=reason_long';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('hr.bonus.shift:' || p_employee_id || ':' || p_shift_date, 0));
  select o.amount into v_current from hr.shift_bonus_overrides o
   where o.employee_id = p_employee_id and o.shift_date = p_shift_date order by o.id desc limit 1;
  if v_current is not distinct from p_amount then
    return jsonb_build_object('noop', true);
  end if;
  insert into hr.shift_bonus_overrides (employee_id, shift_date, amount, reason, created_by_email)
  values (p_employee_id, p_shift_date, p_amount, v_reason, v_email);
  v_rows := hr.fn_sync_shift_bonus(p_employee_id, p_shift_date, 'trigger', v_email);
  return jsonb_build_object('noop', false, 'amount', p_amount, 'bonus_rows', v_rows);
end $function$;

CREATE OR REPLACE FUNCTION hr.fn_admin_review_url(p_kind text, p_visit_id bigint, p_employee_id bigint, p_date date)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  -- The one place the Admin Review address lives for the HR App. NULL (no button) when the decision cannot be opened:
  -- a deleted or missing visit, or a shift with neither a review row nor a form that day.
  -- 2026-10-19_1900: a shift not reviewed yet (a pending bonus) opens from its forms, as Admin Review lists it.
  with base(u) as (select 'https://admin.unclogme.app')
  select case
    when p_kind = 'visit_bonus' then
      (select b.u || '/review/' || v.id from public.visits v, base b where v.id = p_visit_id and v.deleted_at is null)
    when p_kind = 'shift_bonus' then
      (select b.u || '/review-shift/shift-' || s.employee_id || '-' || to_char(s.shift_date, 'YYYY-MM-DD')
         from public.shift_reviews s, base b where s.employee_id = p_employee_id and s.shift_date = p_date
        union all
        select b.u || '/review-shift/shift-' || p_employee_id || '-' || to_char(p_date, 'YYYY-MM-DD')
          from base b
         where exists (select 1 from public.v_inspection_shifts s where s.employee_id = p_employee_id and s.shift_date = p_date)
         limit 1)
  end
$function$;

CREATE OR REPLACE FUNCTION public.log_hr_bonus_health()
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  n integer;
  v_items jsonb;
begin
  with d as (
    select dr.problem, dr.kind, dr.visit_id, dr.employee_id, dr.work_date,
           e.full_name as person,
           c.client_code, v.visit_date,
           case dr.kind when 'visit_bonus' then 'visit bonus' else 'shift bonus' end as what,
           case when dr.visit_id is not null
                then format('visit V-%s (%s, %s)', dr.visit_id, coalesce(c.client_code, 'no client'), to_char(v.visit_date, 'Mon FMDD'))
                else format('the shift of %s', to_char(dr.work_date, 'Mon FMDD')) end as where_txt,
           g.decided_by_email
      from hr.v_bonus_drift dr
      left join public.employees e on e.id = dr.employee_id
      left join public.visits v on v.id = dr.visit_id
      left join public.clients c on c.id = v.client_id
      left join lateral (select b.decided_by_email from hr.bonus_events b
                          where b.kind = dr.kind and b.reverses_id is null
                            and b.employee_id is not distinct from dr.employee_id
                            and b.visit_id is not distinct from dr.visit_id
                            and b.work_date is not distinct from dr.work_date
                          order by b.id desc limit 1) g on true
     where dr.problem <> 'shift_forms_issue'
  ),
  f as (
    select jsonb_build_object(
             'kind', 'hr_bonus:' || d.problem || ':' || coalesce('v' || d.visit_id, '') || coalesce(':e' || d.employee_id, '')
                     || coalesce(':' || d.work_date, ''),
             'issue', d.problem,
             'reason', case d.problem
               when 'missing_grant' then format('The %s for %s was approved in Admin Review%s, but the HR pay history has no bonus for it.',
                                                d.what, d.where_txt, coalesce(' for ' || d.person, ''))
               when 'approved_no_crew' then format('The visit bonus for %s was approved in Admin Review, but the visit has no crew, so nobody was paid.', d.where_txt)
               when 'grant_not_expected' then format('%s still has a %s in the HR pay history for %s, but Admin Review does not show it as approved.',
                                                     coalesce(d.person, 'Someone'), d.what, d.where_txt)
               when 'decider_unknown' then format('%s''s %s for %s was approved by %s, who is not an active admin or office account.',
                                                  coalesce(d.person, 'Someone'), d.what, d.where_txt, coalesce(d.decided_by_email, 'an unknown account'))
               when 'decider_is_earner' then format('%s approved their own %s for %s.', coalesce(d.person, 'Someone'), d.what, d.where_txt)
               when 'shift_pairing_collision' then format('%s has two shifts dated %s in the shift forms, so Admin Review shows only one of them.',
                                                          coalesce(d.person, 'Someone'), to_char(d.work_date, 'Mon FMDD'))
               else format('Bonus problem "%s" on %s.', d.problem, d.where_txt) end,
             'what_to_do', case d.problem
               when 'approved_no_crew' then 'Add the crew to the visit in the Visit Calendar; the bonus is then added within the hour.'
               when 'decider_unknown' then 'Check the decision in Admin Review, and the person''s access level in the HR App.'
               when 'decider_is_earner' then 'Check the decision in Admin Review; someone else should approve it.'
               when 'shift_pairing_collision' then 'Open both shifts in Admin Review: one form was probably filed on the wrong day or under the wrong person.'
               else 'The hourly repair should have fixed this. Run select hr.fn_sync_all_bonuses(); if it is still listed, the bonus rule is failing for this case.' end,
             'person', d.person, 'client_code', d.client_code) as item
      from d
    union all
    select jsonb_build_object(
             'kind', 'hr_bonus:repaired_by_sweep',
             'issue', 'trigger_missed',
             'reason', format('%s bonus row(s) were added by the hourly repair in the last 26 hours instead of at the moment of approval, so the Admin Review triggers are failing.', s.n),
             'what_to_do', 'Check the Postgres logs for warnings from hr.trg_visit_review_bonus / hr.trg_shift_review_bonus.',
             'count', s.n)
      from (select count(*) as n from hr.bonus_events b
             where b.filled_by = 'sweep' and b.created_at > now() - interval '26 hours') s
     where s.n > 0
    union all
    select jsonb_build_object(
             'kind', 'hr_bonus:sweep_not_running',
             'issue', 'sweep_not_running',
             'reason', 'The hourly bonus repair (cron hr-bonus-sweep) has not succeeded in the last 3 hours, so a bonus the triggers missed would stay missing.',
             'what_to_do', 'Check cron.job_run_details for hr-bonus-sweep.')
     where not exists (select 1 from cron.job_run_details r join cron.job j on j.jobid = r.jobid
                        where j.jobname = 'hr-bonus-sweep' and r.status = 'succeeded'
                          and r.end_time > now() - interval '3 hours')
    union all
    -- 2026-10-19_1200: an active person with no bonus amount of their own earns $0 (Fred: "$0 until set")
    select jsonb_build_object(
             'kind', 'hr_bonus:no_amount:e' || e.id || ':' || k.kind,
             'issue', 'no_amount',
             'reason', format('%s has no %s amount, so every %s Admin Review approves for them pays $0.',
                              e.full_name, case k.kind when 'per_visit_bonus' then 'visit bonus' else 'shift bonus' end,
                              case k.kind when 'per_visit_bonus' then 'visit' else 'shift' end),
             'what_to_do', 'Open them in the HR App and set the amount with Edit on their Pay rates card.',
             'person', e.full_name)
      from public.employees e
      cross join unnest(array['per_visit_bonus', 'per_shift_bonus']) k(kind)
     where e.status = 'ACTIVE'
       and (select r.amount from hr.fn_rate_on(e.id, k.kind, (now() at time zone 'America/New_York')::date) r) is null
    union all
    -- 2026-10-19_0215: the history ceiling (server paging is planned past 800 entries)
    select jsonb_build_object(
             'kind', 'hr_bonus:history_large:e' || x.employee_id,
             'issue', 'history_large',
             'reason', format('%s has %s entries in the pay and bonus history. Past 800 the HR App should page the history in the database instead of the browser.',
                              coalesce(e.full_name, 'Someone'), x.n),
             'what_to_do', 'Build hr.get_pay_history (server paging), as planned in the HR App redesign plan of 2026-10-19.',
             'person', e.full_name, 'count', x.n)
      from (select b.employee_id, count(*) as n from hr.bonus_events b group by b.employee_id having count(*) > 800) x
      left join public.employees e on e.id = x.employee_id
    union all
    -- 2026-10-19_0215: a bonus taken back after its payroll week ended (Fred: keep it in the week of the work, but say so)
    select jsonb_build_object(
             'kind', 'hr_bonus:late_take_back:' || r.id,
             'issue', 'late_take_back',
             'reason', format('A %s of %s for %s (work date %s) was taken back on %s, after its payroll week (%s to %s) ended. If that week was already paid, take it off the next pay.',
                              case r.kind when 'visit_bonus' then 'visit bonus' else 'shift bonus' end,
                              to_char(-r.amount, 'FM$999,990.00'), coalesce(e.full_name, 'someone'),
                              to_char(r.work_date, 'Mon FMDD'), to_char(r.created_at at time zone 'America/New_York', 'Mon FMDD'),
                              to_char(hr.fn_payroll_week_start(r.work_date, coalesce(e.payroll_week_start_day, 5::smallint)), 'Dy Mon FMDD'),
                              to_char(hr.fn_payroll_week_start(r.work_date, coalesce(e.payroll_week_start_day, 5::smallint)) + 6, 'Dy Mon FMDD')),
             'what_to_do', 'Check whether that week was already paid, and adjust the next payroll if it was.',
             'person', e.full_name)
      from hr.bonus_events r
      left join public.employees e on e.id = r.employee_id
     where r.rule = 'reversal' and r.amount < 0 and r.created_at > now() - interval '26 hours'
       and r.reprice_rate_id is null   -- 2026-10-21: an amount change applied to approved bonuses is one item below
       and (r.created_at at time zone 'America/New_York')::date > hr.fn_payroll_week_start(r.work_date, coalesce(e.payroll_week_start_day, 5::smallint)) + 6

    union all
    -- 2026-10-21 (Fred): an amount change applied to approved bonuses. One item per change that moved a bonus in a payroll
    -- week already ended, with the net to add to (or take off) the next pay if that week was paid.
    select jsonb_build_object(
             'kind', 'hr_bonus:repriced:' || x.rate_id,
             'issue', 'repriced_paid_weeks',
             'reason', format('%s''s %s was changed to %s from %s and applied to %s approved %s in payroll weeks already ended (net %s). If those weeks were paid, adjust the next pay by that amount.',
                              coalesce(e.full_name, 'Someone'), case x.kind when 'per_visit_bonus' then 'visit bonus' else 'shift bonus' end,
                              to_char(x.amount, 'FM$999,990.00'), to_char(x.effective_from, 'Mon FMDD, YYYY'), x.n,
                              case x.kind when 'per_visit_bonus' then 'visit(s)' else 'shift(s)' end,
                              case when x.net < 0 then '-' else '+' end || to_char(abs(x.net), 'FM$999,990.00')),
             'what_to_do', 'Check whether those weeks were already paid, and adjust the next payroll if they were.',
             'person', e.full_name)
      from (select p.id as rate_id, p.kind, p.amount, p.effective_from, p.employee_id,
                   count(*) filter (where b.reverses_id is null) as n, sum(b.amount) as net
              from hr.bonus_events b
              join hr.pay_rates p on p.id = b.reprice_rate_id
              left join public.employees e2 on e2.id = b.employee_id
             where b.created_at > now() - interval '26 hours'
               and (b.created_at at time zone 'America/New_York')::date
                   > hr.fn_payroll_week_start(b.work_date, coalesce(e2.payroll_week_start_day, 5::smallint)) + 6
             group by p.id, p.kind, p.amount, p.effective_from, p.employee_id) x
      left join public.employees e on e.id = x.employee_id
    union all
    -- 2026-10-20_1500 (access phase 2): a change an app in watch mode let through but would refuse once it is checked
    select jsonb_build_object(
             'kind', 'hr_access:watch:' || w.app || ':' || coalesce(w.email, 'unknown') || ':' || w.what,
             'issue', 'access_watch',
             'reason', format('%s did "%s" in %s %s time(s) since yesterday. Their access (%s) would refuse it once %s is checked; it was let through because %s is in its watch week.',
                              coalesce(e.full_name, w.email, 'A sign-in with no person'), w.what, a.name, w.n,
                              hr.fn_access_label(w.has), a.name, a.name),
             'what_to_do', 'Give them the access they need on the HR App Access tab, or confirm they should be refused before the app is switched on.',
             'person', coalesce(e.full_name, w.email))
      from (select r.app, r.email, r.what, max(r.has) as has, max(r.employee_id) as employee_id, count(*) as n
              from hr.access_refusals r where r.at > now() - interval '26 hours'
             group by r.app, r.email, r.what) w
      join hr.access_apps a on a.app = w.app
      left join public.employees e on e.id = w.employee_id
  )
  select count(*), coalesce(jsonb_agg(item order by item->>'kind'), '[]'::jsonb) into n, v_items from f;

  insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
  values ('hr-bonus-health', clock_timestamp(), clock_timestamp(), n,
          case when n > 0 then 'attention' else 'ok' end,
          jsonb_build_object('count', n, 'items', v_items));
  return n;
end $function$;

COMMENT ON TABLE hr.shift_bonus_overrides IS
  'A custom shift bonus for ONE person on ONE shift (employee_id, shift_date: the shift of public.v_inspection_shifts), set in Admin Review (2026-10-21, Fred). The newest row per (employee_id, shift_date) is in force; amount NULL means back to the person''s normal amount. Append-only. Written only by hr.set_shift_bonus; read through hr.fn_shift_rate_on.';

-- ---------- repair (Fred: "Re-pair all 5"): the reviews that pointed at half of two different nights ----------
-- a) the two denials whose shift no longer exists: each was the POST that closes the night before (Oct 2, Oct 19).
--    public.shift_reviews is audited (audit_shift_reviews): the removed rows stay in audit.logs.old_row.
CREATE TEMP TABLE repair_removed ON COMMIT DROP AS
SELECT sr.* FROM public.shift_reviews sr
 WHERE (sr.employee_id, sr.shift_date) IN ((40, date '2026-10-03'), (40, date '2026-10-20'))
   AND sr.bonus_status = 'denied'
   AND NOT EXISTS (SELECT 1 FROM public.v_inspection_shifts s WHERE s.employee_id = sr.employee_id AND s.shift_date = sr.shift_date);
DO $r$ BEGIN
  IF (SELECT count(*) FROM repair_removed) <> 2 THEN RAISE EXCEPTION 'repair: expected the 2 orphan denials, found %', (SELECT count(*) FROM repair_removed); END IF;
END $r$;
DELETE FROM public.shift_reviews sr USING repair_removed x
 WHERE sr.employee_id = x.employee_id AND sr.shift_date = x.shift_date AND sr.bonus_status = 'denied';
-- b) approved shifts recorded at $0 by the old rule (a form missing or reporting an issue) are recorded again
CREATE TEMP TABLE repair_regrant ON COMMIT DROP AS
SELECT g.* FROM hr.bonus_events g
  JOIN public.shift_reviews sr ON sr.employee_id = g.employee_id AND sr.shift_date = g.work_date AND sr.bonus_status = 'approved'
 WHERE g.kind = 'shift_bonus' AND g.reverses_id IS NULL AND g.rule = 'forms_issue'
   AND NOT EXISTS (SELECT 1 FROM hr.bonus_events r WHERE r.reverses_id = g.id)
   AND EXISTS (SELECT 1 FROM public.v_inspection_shifts s WHERE s.employee_id = g.employee_id AND s.shift_date = g.work_date);
DO $r$ BEGIN
  IF (SELECT count(*) FROM repair_regrant) <> 1 OR NOT EXISTS (SELECT 1 FROM repair_regrant WHERE employee_id = 40 AND work_date = date '2026-10-05') THEN
    RAISE EXCEPTION 'repair: expected only Oct 5 (Michael) to re-record'; END IF;
END $r$;
INSERT INTO hr.bonus_events (kind, employee_id, work_date, amount, pay_rate_id, rule, note, pre_present, post_present,
                             forms_issue, decided_by_email, decided_at, reverses_id, filled_by)
SELECT 'shift_bonus', g.employee_id, g.work_date, -g.amount, g.pay_rate_id, 'reversal',
       'Recorded again: the shift''s PRE and POST forms are now paired correctly, and an approved shift is paid (Trello ZEYkT63t).',
       g.pre_present, g.post_present, g.forms_issue, g.decided_by_email, now(), g.id, 'backfill'
  FROM repair_regrant g;
DO $r$ DECLARE k record; BEGIN
  FOR k IN SELECT employee_id, work_date FROM repair_regrant LOOP
    PERFORM hr.fn_sync_shift_bonus(k.employee_id, k.work_date, 'backfill');
  END LOOP;
END $r$;

DO $v$ DECLARE v_n bigint; BEGIN
  IF EXISTS (SELECT 1 FROM acl_before b JOIN pg_proc p ON p.oid = b.k::regprocedure WHERE p.proacl::text IS DISTINCT FROM b.a) THEN
    RAISE EXCEPTION 'VERIFY 1: privileges of a replaced function moved'; END IF;
  IF (SELECT relacl::text FROM pg_class WHERE oid = 'hr.v_bonus_drift'::regclass) IS DISTINCT FROM (SELECT a FROM drift_acl) THEN
    RAISE EXCEPTION 'VERIFY 2: hr.v_bonus_drift privileges moved'; END IF;
  IF has_table_privilege('anon', 'public.v_inspection_shifts', 'SELECT') OR NOT has_table_privilege('authenticated', 'public.v_inspection_shifts', 'SELECT')
     OR has_table_privilege('authenticated', 'public.v_inspection_shifts', 'INSERT') THEN
    RAISE EXCEPTION 'VERIFY 3: view privileges wrong: %', (SELECT relacl::text FROM pg_class WHERE oid = 'public.v_inspection_shifts'::regclass); END IF;
  SELECT count(*) INTO v_n FROM (SELECT 1 FROM public.v_inspection_shifts WHERE shift_date >= date '2026-09-01' GROUP BY employee_id, shift_date HAVING count(*) > 1) z;
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 4: % shift collisions since Sep 1', v_n; END IF;
  IF (SELECT count(*) FROM public.v_inspection_shifts) <> (SELECT count(*) FROM public.inspections WHERE employee_id IS NOT NULL AND inspection_type = 'PRE' AND submitted_at IS NOT NULL)
       + (SELECT count(*) FROM public.v_inspection_shifts WHERE kind = 'post_only') THEN
    RAISE EXCEPTION 'VERIFY 5: every PRE is in exactly one shift'; END IF;
  IF (SELECT count(*) FROM public.v_inspection_shifts WHERE post_inspection_id IS NOT NULL)
     <> (SELECT count(*) FROM public.inspections WHERE employee_id IS NOT NULL AND inspection_type = 'POST' AND submitted_at IS NOT NULL) THEN
    RAISE EXCEPTION 'VERIFY 6: every POST is in exactly one shift'; END IF;
  -- the night of Oct 14 (Michael): PRE 9 PM, POST 9:30 AM next morning
  IF NOT EXISTS (SELECT 1 FROM public.v_inspection_shifts WHERE employee_id = 40 AND shift_date = date '2026-10-14'
                   AND pre_inspection_id = 537 AND post_inspection_id = 538) THEN RAISE EXCEPTION 'VERIFY 7: Oct 14 night not paired'; END IF;
  IF (SELECT count(*) FROM public.shift_reviews WHERE employee_id = 40) <> 3 THEN RAISE EXCEPTION 'VERIFY 8: Michael should keep 3 reviews'; END IF;
  IF EXISTS (SELECT 1 FROM nets_before b WHERE NOT (b.employee_id = 40 AND b.work_date = date '2026-10-05')
               AND b.net IS DISTINCT FROM (SELECT sum(g.amount) FROM hr.bonus_events g WHERE g.kind = 'shift_bonus' AND g.employee_id = b.employee_id AND g.work_date = b.work_date)) THEN
    RAISE EXCEPTION 'VERIFY 9: a shift other than Oct 5 changed'; END IF;
  IF (SELECT sum(amount) FROM hr.bonus_events WHERE kind = 'shift_bonus' AND employee_id = 40 AND work_date = date '2026-10-05')
     IS DISTINCT FROM (SELECT x.amount FROM hr.fn_shift_rate_on(40, date '2026-10-05') x) THEN RAISE EXCEPTION 'VERIFY 10: Oct 5 not at the shift amount'; END IF;
  IF (SELECT count(*) FROM hr.bonus_events WHERE kind = 'visit_bonus') <> (SELECT n FROM visit_events_before) THEN RAISE EXCEPTION 'VERIFY 11: visit bonuses moved'; END IF;
  IF (SELECT count(*) FROM hr.v_bonus_drift WHERE problem NOT IN ('shift_forms_issue')) <> 0 THEN
    RAISE EXCEPTION 'VERIFY 12: bonus drift after the change: %', (SELECT jsonb_agg(to_jsonb(d)) FROM hr.v_bonus_drift d WHERE problem <> 'shift_forms_issue'); END IF;
  IF (SELECT count(*) FROM public.shift_reviews WHERE (employee_id, shift_date) IN ((40, date '2026-10-03'), (40, date '2026-10-20'))) <> 0 THEN
    RAISE EXCEPTION 'VERIFY 13: orphan denials still there'; END IF;
  RAISE NOTICE 'VERIFY passed';
END $v$;
NOTIFY pgrst, 'reload schema';
COMMIT;
