-- 2026-10-21_rollback_drop_inspections_with_review.sql: undoes 2026-10-21_1641_drop_inspections_with_review.sql.
-- Puts the view back exactly as it was at the drop: the definition read with pg_get_viewdef (md5 8d13b84364c0c09899c14aa1b643b79f),
-- security_invoker, owner postgres, and the grants it held after 2026-10-21_1624 (anon nothing). The table names are
-- schema-qualified here; pg_get_viewdef prints them unqualified, and the VERIFY proves the result is byte-identical.
-- Rehearsed: drop + this file in one rolled-back transaction gives back the same md5, options and grants.
BEGIN;
SET LOCAL lock_timeout = '3s';

CREATE VIEW public.inspections_with_review WITH (security_invoker = true) AS
 SELECT i.id,
    i.vehicle_id,
    i.employee_id,
    i.shift_date,
    i.inspection_type,
    i.submitted_at,
    i.sludge_gallons,
    i.water_gallons,
    i.gas_level,
    i.is_valve_closed,
    i.has_issue,
    i.issue_note,
    i.created_at,
    i.updated_at,
    COALESCE(asr.review_status, 'pending'::text) AS shift_review_status,
    asr.reviewed_at AS shift_reviewed_at,
    asr.reviewed_by AS shift_reviewed_by,
    COALESCE(asr.bonus_status, 'pending'::text) AS shift_bonus_status,
    asr.bonus_decided_at AS shift_bonus_decided_at,
    asr.bonus_decided_by AS shift_bonus_decided_by,
    asr.bonus_denial_note AS shift_bonus_denial_note,
    asr.shift_quality_note
   FROM public.inspections i
     LEFT JOIN public.shift_reviews asr ON asr.employee_id = i.employee_id AND asr.shift_date = i.shift_date;

ALTER VIEW public.inspections_with_review OWNER TO postgres;
-- default privileges hand out grants nobody wrote, so clear them and grant exactly what was there
REVOKE ALL ON public.inspections_with_review FROM PUBLIC, anon, authenticated, service_role, yannick_readonly, db_backup_reader;
GRANT ALL ON public.inspections_with_review TO authenticated, service_role;
GRANT SELECT ON public.inspections_with_review TO yannick_readonly, db_backup_reader;

do $verify$
declare v_acl text[];
begin
  if md5(pg_get_viewdef('public.inspections_with_review'::regclass, true)) <> '8d13b84364c0c09899c14aa1b643b79f' then
    raise exception 'VERIFY: definition differs from the one dropped';
  end if;
  if (select reloptions::text from pg_class where oid = 'public.inspections_with_review'::regclass) <> '{security_invoker=true}' then
    raise exception 'VERIFY: security_invoker not set';
  end if;
  select array(select x from unnest(relacl::text[]) x order by x) into v_acl from pg_class where oid = 'public.inspections_with_review'::regclass;
  if v_acl <> array['authenticated=arwdDxtm/postgres','db_backup_reader=r/postgres','postgres=arwdDxtm/postgres',
                    'service_role=arwdDxtm/postgres','yannick_readonly=r/postgres'] then
    raise exception 'VERIFY: grants differ from before the drop: %', v_acl;
  end if;
  raise notice 'VERIFY ok';
end $verify$;

COMMIT;
