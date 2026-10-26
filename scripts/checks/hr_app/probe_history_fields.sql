-- Probes for the history fields of hr.get_employee_record and the two new hr-bonus-health items (2026-10-19_0215).
-- Fixtures are written with triggers off (session_replication_role = replica) and the block ends by RAISE-ing its
-- results, so nothing is ever committed. Run with scripts/checks/hr_app/run.js probe_history_fields.sql.
DO $p$
DECLARE
  r jsonb := '[]'::jsonb; j jsonb; it jsonb;
  c_admin text; c_office text;
  v_visit bigint; v_grant bigint; v_rev bigint; v_rate bigint; v_d1 date;
BEGIN
  c_admin := json_build_object('sub',coalesce((select u.id::text from auth.users u where lower(u.email) = lower((select email from public.employees where id = 2))), '00000000-0000-0000-0000-000000000001'),'email',(select email from public.employees where id = 2),'role','authenticated')::text;
  c_office := json_build_object('sub',coalesce((select u.id::text from auth.users u where lower(u.email) = lower((select email from public.employees where id = (select e.id from public.employees e join auth.users u on lower(u.email) = lower(e.email) where e.status = 'ACTIVE' and e.access_level = 'office' and u.email_confirmed_at is not null and u.banned_until is null and not exists (select 1 from hr.access_overrides o where o.employee_id = e.id) order by e.id limit 1)))), '00000000-0000-0000-0000-000000000001'),'email',(select email from public.employees where id = (select e.id from public.employees e join auth.users u on lower(u.email) = lower(e.email) where e.status = 'ACTIVE' and e.access_level = 'office' and u.email_confirmed_at is not null and u.banned_until is null and not exists (select 1 from hr.access_overrides o where o.employee_id = e.id) order by e.id limit 1)),'role','authenticated')::text;
  -- The office fixture must NOT hold Pay rates and bonus settings: that is the premise of every 'office cannot ...'
  -- check. Office defaults can change (Fred set Office hr_pay = yes on 2026-10-23), so pin it here; the run's
  -- ROLLBACK undoes it.
  INSERT INTO hr.access_overrides (employee_id, app, level, set_by_email) SELECT e.id, 'hr_pay', 'no', 'probe' FROM public.employees e WHERE lower(e.email) = lower(c_office::jsonb->>'email');
  SELECT id INTO v_visit FROM public.visits WHERE deleted_at IS NULL AND visit_status = 'completed' ORDER BY id DESC LIMIT 1;

  SET LOCAL session_replication_role = replica;
  -- a bonus approved at 11:30 PM ET on Oct 7 (03:30 UTC on Oct 8), later taken back after its payroll week ended
  INSERT INTO hr.bonus_events (kind, employee_id, visit_id, work_date, amount, rule, decided_by_email, decided_at, filled_by, created_at)
  VALUES ('visit_bonus', 40, v_visit, date '2026-10-07', 10, 'approved', 'probe@unclogme.com', timestamptz '2026-10-08 03:30:00+00', 'trigger', timestamptz '2026-10-08 03:30:00+00')
  RETURNING id INTO v_grant;
  INSERT INTO hr.bonus_events (kind, employee_id, visit_id, work_date, amount, rule, reverses_id, decided_at, filled_by, created_at)
  VALUES ('visit_bonus', 40, v_visit, date '2026-10-07', -10, 'reversal', v_grant, now(), 'trigger', now())
  RETURNING id INTO v_rev;
  -- two pay rates, the second replacing the first, dated after any real hourly rate of the person so the first is
  -- the second's previous amount whatever pay the person really has
  v_d1 := greatest(date '2026-09-01', (SELECT max(effective_from) + 1 FROM hr.pay_rates WHERE employee_id = 40 AND kind = 'hourly'));
  INSERT INTO hr.pay_rates (employee_id, kind, amount, effective_from, reason, created_by_email)
  VALUES (40, 'hourly', 18, v_d1, 'probe first', 'probe@unclogme.com');
  INSERT INTO hr.pay_rates (employee_id, kind, amount, effective_from, reason, created_by_email)
  VALUES (40, 'hourly', 20, v_d1 + 30, 'probe raise', 'probe@unclogme.com') RETURNING id INTO v_rate;
  SET LOCAL session_replication_role = origin;

  PERFORM set_config('request.jwt.claims', c_admin, true);
  j := hr.get_employee_record(40);
  SELECT h INTO it FROM jsonb_array_elements(j->'history') h WHERE (h->>'id')::bigint = v_grant AND h->>'type' = 'visit_bonus';
  r := r || jsonb_build_object('t','1 an 11:30 PM ET approval is dated that ET day','ok', it->>'decided_on' = '2026-10-07' AND it->>'decided_time' = '23:30', 'v', it->>'decided_on');
  r := r || jsonb_build_object('t','2 the grant knows it was taken back after its week','ok', (it->>'reversed')::boolean AND (it->>'after_week_ended')::boolean, 'v', it->'after_week_ended');
  r := r || jsonb_build_object('t','3 the link is absolute','ok', it->>'admin_review_url' = 'https://admin.unclogme.app/review/' || v_visit);
  -- since 2026-10-19_1815 a pay change is in Activity, never in the history
  SELECT a INTO it FROM jsonb_array_elements(j->'activity') a WHERE (a->>'id')::bigint = -v_rate AND a->>'operation' = 'RATE';
  r := r || jsonb_build_object('t','4 a pay change is in Activity with the previous amount, not in the history','ok',
        it->'changes'->0->>'field' = 'Hourly rate' AND it->'changes'->0->>'old' = '$18.00' AND it->'changes'->0->>'new' = '$20.00 from ' || to_char(v_d1 + 30, 'Mon FMDD, YYYY')
        AND it->'changes'->1->>'new' = 'probe raise'
        AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j->'history') h WHERE h->>'type' = 'rate_change'), 'v', it);

  PERFORM set_config('request.jwt.claims', c_office, true);
  j := hr.get_employee_record(40);
  r := r || jsonb_build_object('t','5 office never receives an hourly change','ok',
        NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j->'activity') a WHERE (a->>'id')::bigint = -v_rate)
        AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j->'history') h WHERE h->>'type' = 'rate_change'));

  -- a deleted visit gives no button
  SET LOCAL session_replication_role = replica;
  UPDATE public.visits SET deleted_at = now() WHERE id = v_visit;
  SET LOCAL session_replication_role = origin;
  PERFORM set_config('request.jwt.claims', c_admin, true);
  j := hr.get_employee_record(40);
  SELECT h INTO it FROM jsonb_array_elements(j->'history') h WHERE (h->>'id')::bigint = v_grant;
  r := r || jsonb_build_object('t','6 a deleted visit has no Admin Review link','ok', it ? 'admin_review_url' AND it->>'admin_review_url' IS NULL);
  PERFORM set_config('request.jwt.claims', '', true);

  -- the late take-back reaches the health email
  PERFORM public.log_hr_bonus_health();
  r := r || jsonb_build_object('t','7 a late take-back becomes a health item','ok', EXISTS (SELECT 1 FROM ops.v_health_items
           WHERE check_name = 'hr-bonus-health' AND item->>'kind' = 'hr_bonus:late_take_back:' || v_rev));

  RAISE EXCEPTION 'PROBE_RESULT %', r::text;
END $p$;
