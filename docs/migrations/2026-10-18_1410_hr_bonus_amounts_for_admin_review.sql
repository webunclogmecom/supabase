-- ============================================================================
-- 2026-10-18_1410 Bonus amounts come from HR: a reader for Admin Review and a writer for the HR App
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-18: "make Admin Review read the bonus amounts from HR". Until now Admin Review carried $10 and
--   $25 as constants in its code while HR held the same amounts in hr.pay_rates (company rows, 2026-10-18_0400),
--   so a change in one place would silently disagree with the other.
-- WHAT IT DOES
--   hr.get_bonus_amounts(): the company amounts for the visit bonus and the shift bonus, each with its schedule
--     (effective_from, amount), newest first, plus today's amount. Any signed-in staff account may read it (the
--     company amounts are not personal pay, and Admin Review is used by office staff and by staff sign-ins with no
--     employee row). The app picks, for each visit or shift, the newest row with effective_from <= its date, which
--     is exactly hr.fn_rate_on, the rule the bonus history uses: the two cannot disagree.
--   hr.set_company_bonus(p_kind, p_amount, p_effective_from, p_reason): admins only (hr.fn_require_level). A new
--     company row, never an update. The start date must be today (ET) or later: a backdated amount would make Admin
--     Review show a new amount for past visits while the bonuses already granted keep the old one.
--   Per-person bonus amounts stay refused (hr.set_pay_rates): Admin Review would have to show one person's pay to
--   the office reviewers. The company rows are the only bonus amounts.
-- RULE 8: no new table. hr.pay_rates stays opted out of audit (append-only, own who / when / why).
-- GRANTS: both functions revoked from PUBLIC / anon, granted to authenticated + service_role.
-- ROLLBACK: drop the two functions (2026-10-18_rollback_hr_bonus_amounts_for_admin_review.sql). Company rows added
--   through the HR App stay (they are history; the triggers already priced bonuses with them).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

CREATE FUNCTION hr.get_bonus_amounts() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $f$
declare
  v_email text := lower(btrim(nullif(auth.jwt()->>'email', '')));
  v_today date := (now() at time zone 'America/New_York')::date;
begin
  if auth.uid() is null or v_email is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in hr.get_bonus_amounts';
  end if;
  if not (v_email like '%@unclogme.com' or v_email like '%@ayache.com') then
    raise exception 'This is for UnclogMe staff accounts only.' using errcode = '42501', detail = 'blocker=not_staff in hr.get_bonus_amounts';
  end if;
  return (
    select jsonb_object_agg(k.kind, jsonb_build_object(
             'today', (select r.amount from hr.fn_rate_on(null, k.kind, v_today) r),
             'schedule', coalesce((select jsonb_agg(jsonb_build_object('effective_from', p.effective_from, 'amount', p.amount)
                                                    order by p.effective_from desc, p.id desc)
                                     from (select distinct on (p2.effective_from) p2.* from hr.pay_rates p2
                                            where p2.employee_id is null and p2.kind = k.kind
                                            order by p2.effective_from, p2.id desc) p), '[]'::jsonb)))
      from unnest(array['per_visit_bonus', 'per_shift_bonus']) k(kind));
end $f$;

CREATE FUNCTION hr.set_company_bonus(p_kind text, p_amount numeric, p_effective_from date, p_reason text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $f$
declare
  v_email text := lower(btrim(nullif(auth.jwt()->>'email', '')));
  v_today date := (now() at time zone 'America/New_York')::date;
  v_current numeric;
begin
  perform 1 from hr.fn_require_level(array['admin']);
  if p_kind not in ('per_visit_bonus', 'per_shift_bonus') then
    raise exception 'Pick the visit bonus or the shift bonus. Nothing was saved.' using errcode = '22023', detail = 'blocker=bonus_kind';
  end if;
  if p_amount is null or p_amount < 0 or p_amount > 1000 or p_amount <> round(p_amount, 2) then
    raise exception 'The amount must be between $0 and $1,000, in cents at most. Nothing was saved.' using errcode = '22023', detail = 'blocker=amount_range';
  end if;
  if p_effective_from is null or p_effective_from < v_today or p_effective_from > v_today + 366 then
    raise exception 'The new amount can start today or later (within a year), never in the past: bonuses already approved keep the amount of their day. Nothing was saved.'
      using errcode = '22023', detail = 'blocker=effective_from';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'Write why the bonus changes. Nothing was saved.' using errcode = '22023', detail = 'blocker=reason_missing';
  end if;
  if length(btrim(p_reason)) > 500 then
    raise exception 'The reason is too long (500 characters at most). Nothing was saved.' using errcode = '22023', detail = 'blocker=reason_long';
  end if;
  select r.amount into v_current from hr.fn_rate_on(null, p_kind, p_effective_from) r;
  if v_current is not distinct from p_amount then
    return jsonb_build_object('noop', true);
  end if;
  insert into hr.pay_rates (employee_id, kind, amount, effective_from, reason, created_by_email)
  values (null, p_kind, p_amount, p_effective_from, btrim(p_reason), v_email);
  return jsonb_build_object('noop', false);
end $f$;

REVOKE ALL ON FUNCTION hr.get_bonus_amounts() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION hr.set_company_bonus(text, numeric, date, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION hr.get_bonus_amounts() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION hr.set_company_bonus(text, numeric, date, text) TO authenticated, service_role;

DO $v$
DECLARE v_bad text; v jsonb;
BEGIN
  SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v_bad
    FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
   WHERE ns.nspname = 'hr'
     AND (has_function_privilege('anon', p.oid, 'EXECUTE')
          OR has_function_privilege('authenticated', p.oid, 'EXECUTE')
             <> (p.proname IN ('update_employee', 'get_employee_record', 'get_pay_summary', 'set_pay_rates',
                               'get_bonus_amounts', 'set_company_bonus')));
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'VERIFY: hr EXECUTE grants wrong on: %', v_bad; END IF;
  -- the reader agrees with fn_rate_on today (as a staff caller)
  PERFORM set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000001","email":"nobody-verify@unclogme.com","role":"authenticated"}', true);
  v := hr.get_bonus_amounts();
  PERFORM set_config('request.jwt.claims', '', true);
  IF (v->'per_visit_bonus'->>'today')::numeric <> 10 OR (v->'per_shift_bonus'->>'today')::numeric <> 25
     OR jsonb_array_length(v->'per_visit_bonus'->'schedule') < 1 THEN
    RAISE EXCEPTION 'VERIFY: unexpected amounts %', v;
  END IF;
  RAISE NOTICE 'VERIFY passed %', v;
END $v$;
COMMIT;
