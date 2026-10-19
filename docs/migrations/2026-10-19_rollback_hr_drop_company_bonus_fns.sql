-- Rollback of 2026-10-19_1240_hr_drop_company_bonus_fns: recreates both functions byte for byte (pg_get_functiondef
-- at 12:38 ET) with their grants (EXECUTE: postgres, authenticated, service_role; PUBLIC revoked).
-- Note: hr.set_company_bonus comes back as the 2026-10-19_1200 body, i.e. it refuses (bonuses stay per person).
BEGIN;
CREATE OR REPLACE FUNCTION hr.get_bonus_amounts()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end $function$;
REVOKE ALL ON FUNCTION hr.get_bonus_amounts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION hr.get_bonus_amounts() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION hr.set_company_bonus(p_kind text, p_amount numeric, p_effective_from date, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_email text := lower(btrim(nullif(auth.jwt()->>'email', '')));
  v_today date := (now() at time zone 'America/New_York')::date;
  v_current numeric;
begin
  perform 1 from hr.fn_require_level(array['admin']);
  -- 2026-10-19_1200: bonuses are per person now; a company amount would change nobody's pay.
  raise exception 'Bonuses are set per person now. Open the person''s page and use Edit next to their visit or shift bonus. Nothing was saved.'
    using errcode = '22023', detail = 'blocker=company_bonus_retired in hr.set_company_bonus';
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
end $function$;
REVOKE ALL ON FUNCTION hr.set_company_bonus(text,numeric,date,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION hr.set_company_bonus(text,numeric,date,text) TO authenticated, service_role;

COMMIT;
