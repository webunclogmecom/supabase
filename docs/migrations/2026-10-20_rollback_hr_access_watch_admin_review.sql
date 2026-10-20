-- Rollback of 2026-10-20_1400. Run the Admin Review build that no longer calls review_* BEFORE this.
BEGIN;
UPDATE hr.access_apps SET mode = 'off' WHERE app = 'admin_review';
DROP TRIGGER aa_access_admin_review ON public.visit_reviews;
DROP TRIGGER aa_access_admin_review ON public.shift_reviews;
DROP TRIGGER aa_access_admin_review ON public.photo_classifications;
DROP TRIGGER aa_access_admin_review ON public.review_scope_inclusions;
DROP FUNCTION public.review_set_visit_manholes(bigint, integer);
DROP FUNCTION public.review_set_property_counts(bigint, integer, integer, boolean, boolean);
DROP FUNCTION public.review_add_visit_photo(bigint, text, text, text, bigint);
DROP FUNCTION hr.trg_check_admin_review();
DROP FUNCTION hr.fn_check_app(text, text, text);
DROP TABLE hr.access_refusals;
CREATE OR REPLACE FUNCTION hr.get_person_bonus_amounts(p_employee_ids bigint[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-10-19_1200: each person's own bonus amounts, every dated row (newest first), so Admin Review can price a visit or
-- shift on its own date. Same gate as hr.get_bonus_amounts (any staff sign-in). A person with no row earns $0.
declare
  v_email text := lower(btrim(nullif(auth.jwt()->>'email', '')));
begin
  if auth.uid() is null or v_email is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in hr.get_person_bonus_amounts';
  end if;
  if not (v_email like '%@unclogme.com' or v_email like '%@ayache.com') then
    raise exception 'This is for UnclogMe staff accounts only.' using errcode = '42501', detail = 'blocker=not_staff in hr.get_person_bonus_amounts';
  end if;
  if p_employee_ids is null or cardinality(p_employee_ids) > 200 then
    raise exception 'Ask for up to 200 people at a time.' using errcode = '22023', detail = 'blocker=ids in hr.get_person_bonus_amounts';
  end if;
  return coalesce((
    select jsonb_object_agg(e.id::text, jsonb_build_object(
             'per_visit_bonus', coalesce((select jsonb_agg(jsonb_build_object('effective_from', p.effective_from, 'amount', p.amount)
                                                           order by p.effective_from desc, p.id desc)
                                            from (select distinct on (p2.effective_from) p2.* from hr.pay_rates p2
                                                   where p2.employee_id = e.id and p2.kind = 'per_visit_bonus'
                                                   order by p2.effective_from, p2.id desc) p), '[]'::jsonb),
             'per_shift_bonus', coalesce((select jsonb_agg(jsonb_build_object('effective_from', p.effective_from, 'amount', p.amount)
                                                           order by p.effective_from desc, p.id desc)
                                            from (select distinct on (p2.effective_from) p2.* from hr.pay_rates p2
                                                   where p2.employee_id = e.id and p2.kind = 'per_shift_bonus'
                                                   order by p2.effective_from, p2.id desc) p), '[]'::jsonb)))
      from public.employees e where e.id = any(p_employee_ids)), '{}'::jsonb);
end $function$;
CREATE OR REPLACE FUNCTION hr.get_review_bonuses(p_visit_ids bigint[], p_shifts jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-10-19_1815: what Admin Review needs to show a bonus the way HR pays it. Per visit: the Calendar crew (who is paid)
-- and, once the bonus is approved, the amounts HR recorded. Per shift ("<employee_id>|<YYYY-MM-DD>"): the recorded amount.
-- Same gate as hr.get_person_bonus_amounts (any staff sign-in).
declare
  v_email text := lower(btrim(nullif(auth.jwt()->>'email', '')));
begin
  if auth.uid() is null or v_email is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in hr.get_review_bonuses';
  end if;
  if not (v_email like '%@unclogme.com' or v_email like '%@ayache.com') then
    raise exception 'This is for UnclogMe staff accounts only.' using errcode = '42501', detail = 'blocker=not_staff in hr.get_review_bonuses';
  end if;
  if p_visit_ids is null or cardinality(p_visit_ids) > 2000
     or p_shifts is null or jsonb_typeof(p_shifts) <> 'array' or jsonb_array_length(p_shifts) > 500 then
    raise exception 'Ask for up to 2,000 visits and 500 shifts at a time.' using errcode = '22023', detail = 'blocker=size in hr.get_review_bonuses';
  end if;
  return jsonb_build_object(
    'visits', coalesce((
      select jsonb_object_agg(v.id::text, jsonb_build_object(
               'crew', coalesce((select jsonb_agg(jsonb_build_object('employee_id', e.id, 'name', e.full_name) order by e.full_name)
                                   from public.visit_team vt join public.employees e on e.id = vt.employee_id
                                  where vt.visit_id = v.id), '[]'::jsonb),
               'recorded', (select jsonb_agg(jsonb_build_object('employee_id', g.employee_id, 'amount', g.amount) order by g.employee_id)
                              from hr.bonus_events g
                             where g.kind = 'visit_bonus' and g.visit_id = v.id and g.reverses_id is null
                               and not exists (select 1 from hr.bonus_events r where r.reverses_id = g.id))))
        from (select distinct unnest(p_visit_ids) as id) v), '{}'::jsonb),
    'shifts', coalesce((
      select jsonb_object_agg((x->>'employee_id') || '|' || (x->>'shift_date'), g.amount)
        from jsonb_array_elements(p_shifts) x
        join hr.bonus_events g on g.kind = 'shift_bonus' and g.employee_id = (x->>'employee_id')::bigint
                              and g.work_date = (x->>'shift_date')::date and g.reverses_id is null
                              and not exists (select 1 from hr.bonus_events r where r.reverses_id = g.id)), '{}'::jsonb));
end $function$;
COMMIT;
