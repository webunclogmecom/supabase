-- ROLLBACK of 2026-11-15_0400_ops_fn_visit_pump_kinds_service_agreement.sql (LL: a visit marked Pumping whose only old
-- line is "Service Agreement" counts as a grease trap pumping).
--
-- Puts ops.fn_visit_pump_kinds(bigint, bigint) back to the body it had before (verbatim, md5 babdac78c98b1f1133525adc9e5d03f0 with carriage
-- returns removed; CREATE OR REPLACE keeps its grants). Guarded: refuses unless the live body is the one LL applied (md5
-- c1e484205b1e89b51d366e7d2a4b7e60). The 36 visits are then "not a pumping" again in B1 and in the Calendar's live estimate; nothing stored moves.

BEGIN;
SET LOCAL lock_timeout = '3s';

do $pin$
begin
  if md5(replace(pg_get_functiondef('ops.fn_visit_pump_kinds(bigint,bigint)'::regprocedure), chr(13), '')) <> 'c1e484205b1e89b51d366e7d2a4b7e60' then
    raise exception 'ops.fn_visit_pump_kinds is not the body of 2026-11-15_0400_ops_fn_visit_pump_kinds_service_agreement; do not undo blindly';
  end if;
end
$pin$;

CREATE OR REPLACE FUNCTION ops.fn_visit_pump_kinds(p_visit_id bigint, p_job_id bigint)
 RETURNS text[]
 LANGUAGE sql
 STABLE
 SET search_path TO 'ops', 'public', 'pg_temp'
AS $function$
  WITH own AS (
    SELECT sli.service_type, sli.location_target
      FROM public.line_items li
      JOIN public.service_line_items sli ON sli.code = lpad(substring(btrim(li.name), '^([0-9]+)'), 2, '0')
     WHERE li.visit_id = p_visit_id AND sli.schedulable
  ), coded AS (
    SELECT * FROM own
    UNION ALL
    SELECT sli.service_type, sli.location_target
      FROM public.line_items li
      JOIN public.service_line_items sli ON sli.code = lpad(substring(btrim(li.name), '^([0-9]+)'), 2, '0')
     WHERE li.job_id = p_job_id AND li.visit_id IS NULL AND li.invoice_id IS NULL AND sli.schedulable
       AND NOT EXISTS (SELECT 1 FROM own)
  ), old_text AS (  -- dated exception: lines from before the codes, only when nothing is coded
    SELECT btrim(li.name) AS nm
      FROM public.line_items li
     WHERE (li.visit_id = p_visit_id OR (li.job_id = p_job_id AND li.visit_id IS NULL AND li.invoice_id IS NULL))
       AND btrim(li.name) !~ '^[0-9]'
       AND NOT EXISTS (SELECT 1 FROM coded)
  ), k AS (
    SELECT CASE WHEN c.service_type = 'Pumping' AND c.location_target ~* 'grease trap' THEN 1
                WHEN c.service_type = 'Pumping' AND c.location_target ~* 'grey water' THEN 2
                WHEN c.service_type = 'Pumping' AND c.location_target ~* 'lift station' THEN 3 END AS r
      FROM coded c
    UNION ALL
    SELECT CASE WHEN o.nm ~* 'grease trap' THEN 1
                WHEN o.nm ~* 'grey water' THEN 2
                WHEN o.nm ~* '(lift|lyft) station' THEN 3 END
      FROM old_text o
  )
  SELECT coalesce(array_agg(CASE r WHEN 1 THEN 'grease_trap' WHEN 2 THEN 'grey_water' ELSE 'lift_station' END ORDER BY r),
                  '{}'::text[])
    FROM (SELECT DISTINCT r FROM k WHERE r IS NOT NULL) d
$function$;

do $verify$
begin
  if md5(replace(pg_get_functiondef('ops.fn_visit_pump_kinds(bigint,bigint)'::regprocedure), chr(13), '')) <> 'babdac78c98b1f1133525adc9e5d03f0' then
    raise exception 'verify_fail: ops.fn_visit_pump_kinds is not the old body';
  end if;
  if has_function_privilege('authenticated', 'ops.fn_visit_pump_kinds(bigint,bigint)', 'execute') or has_function_privilege('anon', 'ops.fn_visit_pump_kinds(bigint,bigint)', 'execute')
     or not has_function_privilege('service_role', 'ops.fn_visit_pump_kinds(bigint,bigint)', 'execute') then
    raise exception 'verify_fail: the grants of ops.fn_visit_pump_kinds are not what they were';
  end if;
  if exists (select 1 from public.visits vv where vv.id = 1248 and ops.fn_visit_pump_kinds(vv.id, vv.job_id) <> '{}') then
    raise exception 'verify_fail: visit 1248 still counts as a pumping';
  end if;
  raise notice 'verify ok: ops.fn_visit_pump_kinds is the old body again';
end $verify$;

COMMIT;
