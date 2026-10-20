-- 2026-10-20_1300 · HR Access tab: each group's original defaults, for "Set to default" on the group cards
--
-- Fred, 2026-10-20: "at the /access view, let's add Set to default too on each group and also add a Global action on
-- each group for Edit, Read or No access."
-- "Default" needs a fixed reference: hr.access_group_defaults.recommended_level = the values the access rules started
-- with (2026-10-19_2145: Office = Edit in every app, Pay rates No, See bonus amounts Yes, Approve site files No;
-- Field = No access / No). hr.get_access_overview returns it as defaults[].recommended. The app stages the changes and
-- saves through the existing hr.set_group_access (all its rules apply). The global Edit / View / No access action is
-- app-side only (it stages every app level of that group; Yes/No settings untouched). Admin is fixed, untouched.
-- Rule 8: a column on an audited table (captured automatically). Changed only by migration (no writer grants).
-- Rollback: restore hr.get_access_overview (md5 db186de2...) then ALTER TABLE hr.access_group_defaults DROP COLUMN recommended_level;
BEGIN;
DO $g$ BEGIN
  IF md5(pg_get_functiondef('hr.get_access_overview()'::regprocedure)) <> 'db186de2eabf663787e3dd2ee3b7d94f' THEN RAISE EXCEPTION 'get_access_overview changed'; END IF;
END $g$;
ALTER TABLE hr.access_group_defaults ADD COLUMN recommended_level text;
UPDATE hr.access_group_defaults d SET recommended_level =
  CASE WHEN d.grp = 'field' THEN CASE WHEN a.parent IS NULL THEN 'none' ELSE 'no' END
       WHEN a.app = 'hr_pay' THEN 'no'
       WHEN a.app = 'hr_bonus' THEN 'yes'
       WHEN a.app = 'pp_approve' THEN 'no'
       ELSE 'edit' END
  FROM hr.access_apps a WHERE a.app = d.app;
ALTER TABLE hr.access_group_defaults ALTER COLUMN recommended_level SET NOT NULL,
  ADD CONSTRAINT access_group_defaults_recommended_chk CHECK (recommended_level IN ('none','view','edit','no','yes'));
COMMENT ON COLUMN hr.access_group_defaults.recommended_level IS 'The original default for this group and app (2026-10-19_2145); "Set to default" on the Access tab returns the group to it. Changed only by migration.';
CREATE OR REPLACE FUNCTION hr.get_access_overview()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_caller bigint := hr.fn_require_access_admin();
begin
  return jsonb_build_object(
    'apps', (select jsonb_agg(jsonb_build_object('app', a.app, 'name', a.name, 'parent', a.parent, 'needs', a.needs, 'mode', a.mode, 'on_since', a.on_since) order by a.sort) from hr.access_apps a),
    'defaults', (select jsonb_agg(jsonb_build_object('group', d.grp, 'app', d.app, 'level', d.level, 'recommended', d.recommended_level) order by d.grp, a.sort)
                   from hr.access_group_defaults d join hr.access_apps a on a.app = d.app),
    'people', (select jsonb_agg(jsonb_build_object('id', e.id, 'name', e.full_name, 'group', coalesce(e.access_level, 'field'),
                       'has_sign_in', hr.fn_has_sign_in(e.email), 'is_self', e.id = v_caller,
                       'custom', case when e.access_level = 'admin' then 0 else (select count(*) from hr.access_overrides o where o.employee_id = e.id) end,
                       'own', case when e.access_level = 'admin' then '{}'::jsonb else (select coalesce(jsonb_object_agg(o.app, o.level), '{}'::jsonb) from hr.access_overrides o where o.employee_id = e.id) end) order by e.full_name)
                 from public.employees e where e.status = 'ACTIVE'),
    'last_change', (select jsonb_build_object('at', l.changed_at, 'by', coalesce(hr.fn_person_label(l.jwt_claims->>'email'), 'Changed outside the apps'),
                            'group', l.new_row->>'grp', 'app', (select a.name from hr.access_apps a where a.app = l.new_row->>'app'),
                            'old', hr.fn_access_label(l.old_row->>'level'), 'new', hr.fn_access_label(l.new_row->>'level'))
                      from audit.logs l
                     where l.table_schema = 'hr' and l.table_name = 'access_group_defaults' and l.operation = 'UPDATE'
                       and (l.old_row->>'level') is distinct from (l.new_row->>'level')
                     order by l.id desc limit 1),
    'version', hr.fn_defaults_version());
end $function$;

DO $v$ DECLARE r jsonb; fred text := json_build_object('sub','5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b','email','fred@ayache.com','role','authenticated')::text;
BEGIN
  IF (SELECT count(*) FROM hr.access_group_defaults WHERE recommended_level IS NULL) > 0 THEN RAISE EXCEPTION 'V1 nulls'; END IF;
  IF (SELECT recommended_level FROM hr.access_group_defaults WHERE grp='office' AND app='hr_bonus') <> 'yes'
     OR (SELECT recommended_level FROM hr.access_group_defaults WHERE grp='field' AND app='hr') <> 'none' THEN RAISE EXCEPTION 'V2 values'; END IF;
  PERFORM set_config('request.jwt.claims', fred, true);
  r := hr.get_access_overview();
  IF NOT (r->'defaults'->0 ? 'recommended') THEN RAISE EXCEPTION 'V3 overview'; END IF;
  PERFORM set_config('request.jwt.claims', '', true);
END $v$;
COMMIT;
