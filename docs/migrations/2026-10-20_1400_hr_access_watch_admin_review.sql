-- 2026-10-20_1400 · Access phase 2 starts: the WATCH mode, Admin Review's writes behind its own check, bonus amounts
-- follow "See bonus amounts"
--
-- Fred, 2026-10-20: "Now start Admin Review phase 2" (plan: Building Apps/HR App/docs/specs/2026-10-19-access-privileges-plan.md,
-- section 5 recipe and Appendix A). This migration is steps 3 and 4 of the recipe for Admin Review:
-- 1. hr.access_refusals: the watch log (one row per change that WOULD be refused once the app is "on"). Opted out of
--    audit (it is the record); service_role reads it; the daily health email lists it (separate migration).
-- 2. hr.fn_check_app(app, level, what): the VOLATILE check for changes. Off: passes. Watch: passes and logs when the
--    caller is below the level. On: refuses with the same sentence as hr.fn_require_app. No claims / service_role pass
--    (hr.fn_app_level), so timed jobs and SQL never log. Repeats are logged at most once a minute per person and action.
-- 3. Admin Review's OWN tables (only Admin Review writes them: audit.logs 90 days, plus exempt SQL): visit_reviews,
--    shift_reviews, photo_classifications, review_scope_inclusions get a BEFORE trigger calling the check (Edit).
-- 4. Its writes to SHARED tables move behind its own functions (a check on visits/properties/photos cannot tell which
--    app writes): public.review_set_visit_manholes, public.review_set_property_counts, public.review_add_visit_photo.
--    The app switches to them in the same cycle; the old direct writes keep working until the last app is checked
--    (phase 6 closes shared tables).
-- 5. hr.get_person_bonus_amounts refuses without "See bonus amounts"; hr.get_review_bonuses keeps the crew and blanks the
--    amounts (amounts_hidden). hr_bonus is already "on", and today every person who can sign in has Yes (Admin, Office).
-- 6. admin_review mode off -> watch.
-- Not here yet: the three edge functions (send-visit-photos-email, rotate-photo, visit-client-note-photos) and
-- public.soft_delete_photo_link (shared with the Client App) get their checks in the next step.
-- Rule 8: hr.access_refusals opted out (the watch log is the record); no other new table.
-- Rollback: 2026-10-20_rollback_hr_access_watch_admin_review.sql.
BEGIN;
DO $g$ BEGIN
  IF md5(pg_get_functiondef('hr.get_person_bonus_amounts(bigint[])'::regprocedure)) <> '073a726aa9a917ebb4c4e4d0b59f1001'
  OR md5(pg_get_functiondef('hr.get_review_bonuses(bigint[],jsonb)'::regprocedure)) <> '3d2800624ca69aff0ffe32291b40eab1' THEN
    RAISE EXCEPTION 'a bonus reader changed since this migration was built';
  END IF;
END $g$;

CREATE TABLE hr.access_refusals (
  id          bigserial PRIMARY KEY,
  at          timestamptz NOT NULL DEFAULT now(),
  app         text NOT NULL REFERENCES hr.access_apps(app),
  needs       text NOT NULL,
  has         text NOT NULL,
  employee_id bigint,
  email       text,
  what        text NOT NULL
);
CREATE INDEX access_refusals_at_idx ON hr.access_refusals (at DESC);
REVOKE ALL ON hr.access_refusals FROM PUBLIC, anon, authenticated;
GRANT SELECT ON hr.access_refusals TO service_role;
REVOKE ALL ON SEQUENCE hr.access_refusals_id_seq FROM PUBLIC, anon, authenticated;
COMMENT ON TABLE hr.access_refusals IS 'Watch log: changes that would be refused once the app is "on" (2026-10-20_1400). Opted out of audit: it is the record.';

CREATE FUNCTION hr.fn_check_app(p_app text, p_level text, p_what text)
 RETURNS void
 LANGUAGE plpgsql
 VOLATILE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_mode text; v_lvl text; v_emp bigint; v_email text;
begin
  select a.mode into v_mode from hr.access_apps a where a.app = p_app;
  if v_mode is null then
    raise exception 'Unknown app "%".', p_app using errcode = '22023', detail = 'blocker=unknown_app in hr.fn_check_app';
  end if;
  if v_mode = 'off' then return; end if;
  v_lvl := hr.fn_app_level(p_app);
  if hr.fn_access_rank(v_lvl) >= hr.fn_access_rank(p_level) then return; end if;
  if v_mode = 'on' then
    perform hr.fn_require_app(p_app, p_level);   -- raises the plain sentence
    return;
  end if;
  -- watch: let it through, note it (at most once a minute per person and action)
  v_emp := hr.fn_access_caller();
  select u.email into v_email from auth.users u where u.id = auth.uid();
  if not exists (select 1 from hr.access_refusals r where r.app = p_app and r.what = p_what
                   and r.email is not distinct from v_email and r.at > now() - interval '1 minute') then
    insert into hr.access_refusals (app, needs, has, employee_id, email, what)
    values (p_app, p_level, coalesce(v_lvl, 'none'), v_emp, v_email, left(p_what, 200));
  end if;
end $function$;

CREATE FUNCTION hr.trg_check_admin_review()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform hr.fn_check_app('admin_review', 'edit', tg_table_name || ' ' || lower(tg_op));
  return coalesce(new, old);
end $function$;

CREATE TRIGGER aa_access_admin_review BEFORE INSERT OR UPDATE OR DELETE ON public.visit_reviews FOR EACH ROW EXECUTE FUNCTION hr.trg_check_admin_review();
CREATE TRIGGER aa_access_admin_review BEFORE INSERT OR UPDATE OR DELETE ON public.shift_reviews FOR EACH ROW EXECUTE FUNCTION hr.trg_check_admin_review();
CREATE TRIGGER aa_access_admin_review BEFORE INSERT OR UPDATE OR DELETE ON public.photo_classifications FOR EACH ROW EXECUTE FUNCTION hr.trg_check_admin_review();
CREATE TRIGGER aa_access_admin_review BEFORE INSERT OR UPDATE OR DELETE ON public.review_scope_inclusions FOR EACH ROW EXECUTE FUNCTION hr.trg_check_admin_review();

-- Admin Review's writes to shared tables, behind its own check
CREATE FUNCTION public.review_set_visit_manholes(p_visit_id bigint, p_count integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_n int;
begin
  perform hr.fn_check_app('admin_review', 'edit', 'visit manholes');
  if p_count is not null and (p_count < 0 or p_count > 50) then
    raise exception 'The manhole count must be between 0 and 50.' using errcode = '22023', detail = 'blocker=count_range';
  end if;
  update public.visits set manhole_count = p_count where id = p_visit_id and deleted_at is null;
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'That visit was not found. Reload the page.' using errcode = 'P0002', detail = 'blocker=not_found'; end if;
  return jsonb_build_object('id', p_visit_id, 'manhole_count', p_count);
end $function$;

CREATE FUNCTION public.review_set_property_counts(p_property_id bigint, p_manholes integer DEFAULT NULL, p_sample_ports integer DEFAULT NULL,
                                                  p_set_manholes boolean DEFAULT false, p_set_sample_ports boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_row public.properties;
begin
  perform hr.fn_check_app('admin_review', 'edit', 'property counts');
  if (p_set_manholes and p_manholes is not null and (p_manholes < 0 or p_manholes > 50))
     or (p_set_sample_ports and p_sample_ports is not null and (p_sample_ports < 0 or p_sample_ports > 50)) then
    raise exception 'Counts must be between 0 and 50.' using errcode = '22023', detail = 'blocker=count_range';
  end if;
  update public.properties
     set grease_trap_manhole_count = case when p_set_manholes then p_manholes else grease_trap_manhole_count end,
         sample_port_count = case when p_set_sample_ports then p_sample_ports else sample_port_count end
   where id = p_property_id
  returning * into v_row;
  if v_row.id is null then raise exception 'That property was not found. Reload the page.' using errcode = 'P0002', detail = 'blocker=not_found'; end if;
  return jsonb_build_object('id', v_row.id, 'grease_trap_manhole_count', v_row.grease_trap_manhole_count, 'sample_port_count', v_row.sample_port_count);
end $function$;

CREATE FUNCTION public.review_add_visit_photo(p_visit_id bigint, p_storage_path text, p_file_name text, p_content_type text, p_size_bytes bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_photo bigint; v_link bigint;
begin
  perform hr.fn_check_app('admin_review', 'edit', 'add visit photo');
  if not exists (select 1 from public.visits v where v.id = p_visit_id and v.deleted_at is null) then
    raise exception 'That visit was not found. Reload the page.' using errcode = 'P0002', detail = 'blocker=not_found';
  end if;
  if not exists (select 1 from storage.objects o where o.bucket_id = 'GT - Visits Images' and o.name = p_storage_path) then
    raise exception 'The photo did not finish uploading. Try again.' using errcode = '22023', detail = 'blocker=photo_missing';
  end if;
  if coalesce(p_content_type, '') not in ('image/png', 'image/jpeg') then
    raise exception 'Only PNG or JPEG photos can be added.' using errcode = '22023', detail = 'blocker=photo_type';
  end if;
  insert into public.photos (storage_path, file_name, content_type, size_bytes, source, uploaded_by_employee_id)
  values (p_storage_path, p_file_name, p_content_type, p_size_bytes, 'admin_review_upload', hr.fn_access_caller())
  returning id into v_photo;
  insert into public.photo_links (photo_id, entity_type, entity_id, role)
  values (v_photo, 'visit', p_visit_id, 'other')
  returning id into v_link;
  return jsonb_build_object('photo_id', v_photo, 'photo_link_id', v_link);
end $function$;

REVOKE ALL ON FUNCTION hr.fn_check_app(text, text, text), hr.trg_check_admin_review() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.review_set_visit_manholes(bigint, integer), public.review_set_property_counts(bigint, integer, integer, boolean, boolean),
  public.review_add_visit_photo(bigint, text, text, text, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.review_set_visit_manholes(bigint, integer), public.review_set_property_counts(bigint, integer, integer, boolean, boolean),
  public.review_add_visit_photo(bigint, text, text, text, bigint) TO authenticated, service_role;

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
  -- 2026-10-20_1400 (phase 2): amounts follow the HR "See bonus amounts" setting
  if hr.fn_access_rank(hr.fn_app_level('hr_bonus')) < 1 then
    raise exception 'You cannot see bonus amounts. Ask Fred or Yannick to change it.'
      using errcode = '42501', detail = 'blocker=no_access app=hr_bonus in hr.get_person_bonus_amounts';
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
  v_see boolean;
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
  -- 2026-10-20_1400 (phase 2): the crew always, the amounts only with the HR "See bonus amounts" setting
  v_see := hr.fn_access_rank(hr.fn_app_level('hr_bonus')) >= 1;
  return jsonb_build_object(
    'amounts_hidden', not v_see,
    'visits', coalesce((
      select jsonb_object_agg(v.id::text, jsonb_build_object(
               'crew', coalesce((select jsonb_agg(jsonb_build_object('employee_id', e.id, 'name', e.full_name) order by e.full_name)
                                   from public.visit_team vt join public.employees e on e.id = vt.employee_id
                                  where vt.visit_id = v.id), '[]'::jsonb),
               'recorded', case when not v_see then null else (select jsonb_agg(jsonb_build_object('employee_id', g.employee_id, 'amount', g.amount) order by g.employee_id)
                              from hr.bonus_events g
                             where g.kind = 'visit_bonus' and g.visit_id = v.id and g.reverses_id is null
                               and not exists (select 1 from hr.bonus_events r where r.reverses_id = g.id)) end))
        from (select distinct unnest(p_visit_ids) as id) v), '{}'::jsonb),
    'shifts', case when not v_see then '{}'::jsonb else coalesce((
      select jsonb_object_agg((x->>'employee_id') || '|' || (x->>'shift_date'), g.amount)
        from jsonb_array_elements(p_shifts) x
        join hr.bonus_events g on g.kind = 'shift_bonus' and g.employee_id = (x->>'employee_id')::bigint
                              and g.work_date = (x->>'shift_date')::date and g.reverses_id is null
                              and not exists (select 1 from hr.bonus_events r where r.reverses_id = g.id)), '{}'::jsonb) end);
end $function$;

UPDATE hr.access_apps SET mode = 'watch' WHERE app = 'admin_review';

-- VERIFY (rehearsal, always rolled back): every real sign-in passes as today; a caller with no employee is logged, not refused
DO $v$
DECLARE r jsonb; n int; vid bigint; pid bigint;
  c_fred text := json_build_object('sub','5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b','email','fred@ayache.com','role','authenticated')::text;
  c_aaron text := json_build_object('sub','77d4c343-1e21-44eb-98ce-c221028d028a','email','aaron@unclogme.com','role','authenticated')::text;
  c_nobody text := json_build_object('sub', gen_random_uuid(), 'email','nobody@unclogme.com','role','authenticated')::text;
BEGIN
  SELECT id INTO vid FROM public.visits WHERE deleted_at IS NULL ORDER BY id DESC LIMIT 1;
  SELECT id INTO pid FROM public.properties ORDER BY id DESC LIMIT 1;
  BEGIN
    -- office edits pass and are not logged
    PERFORM set_config('request.jwt.claims', c_aaron, true);
    r := public.review_set_visit_manholes(vid, (SELECT manhole_count FROM public.visits WHERE id = vid));
    r := public.review_set_property_counts(pid, NULL, NULL, false, false);
    IF EXISTS (SELECT 1 FROM hr.access_refusals) THEN RAISE EXCEPTION 'V1 office was logged'; END IF;
    IF (hr.get_review_bonuses(ARRAY[vid], '[]'::jsonb)->>'amounts_hidden')::boolean THEN RAISE EXCEPTION 'V2 office amounts hidden'; END IF;
    PERFORM hr.get_person_bonus_amounts(ARRAY[26::bigint]);
    -- a sign-in with no employee: logged, still allowed while watching
    PERFORM set_config('request.jwt.claims', c_nobody, true);
    PERFORM hr.fn_check_app('admin_review', 'edit', 'probe');
    IF NOT EXISTS (SELECT 1 FROM hr.access_refusals WHERE what = 'probe' AND has = 'none') THEN RAISE EXCEPTION 'V3 not logged'; END IF;
    PERFORM hr.fn_check_app('admin_review', 'edit', 'probe');
    IF (SELECT count(*) FROM hr.access_refusals WHERE what = 'probe') <> 1 THEN RAISE EXCEPTION 'V4 repeat logged twice'; END IF;
    -- switched on: the same caller is refused
    UPDATE hr.access_apps SET mode = 'on' WHERE app = 'admin_review';
    BEGIN PERFORM hr.fn_check_app('admin_review', 'edit', 'probe2'); RAISE EXCEPTION 'V5 not refused when on';
    EXCEPTION WHEN sqlstate '42501' THEN NULL; END;
    -- the table trigger refuses a direct write when on
    PERFORM set_config('request.jwt.claims', c_nobody, true);
    BEGIN UPDATE public.visit_reviews SET updated_at = updated_at WHERE visit_id = (SELECT visit_id FROM public.visit_reviews LIMIT 1);
      IF FOUND THEN RAISE EXCEPTION 'V6 trigger let it through'; END IF;
    EXCEPTION WHEN sqlstate '42501' THEN NULL; END;
    -- bonus amounts hidden for a caller without See bonus amounts
    BEGIN PERFORM hr.get_person_bonus_amounts(ARRAY[26::bigint]); RAISE EXCEPTION 'V7 amounts shown to nobody';
    EXCEPTION WHEN sqlstate '42501' OR sqlstate '28000' THEN NULL; END;
    RAISE EXCEPTION 'rollback_probe';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'rollback_probe' THEN RAISE; END IF; END;
  IF EXISTS (SELECT 1 FROM hr.access_refusals) THEN RAISE EXCEPTION 'V8 probe not rolled back'; END IF;
  -- service role and timed jobs never log
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM hr.fn_check_app('admin_review', 'edit', 'job');
  IF EXISTS (SELECT 1 FROM hr.access_refusals) THEN RAISE EXCEPTION 'V9 a timed job was logged'; END IF;
  IF has_function_privilege('authenticated', 'hr.fn_check_app(text,text,text)', 'EXECUTE')
     OR has_table_privilege('authenticated', 'hr.access_refusals', 'SELECT')
     OR has_function_privilege('anon', 'public.review_add_visit_photo(bigint,text,text,text,bigint)', 'EXECUTE') THEN RAISE EXCEPTION 'V10 grants'; END IF;
  IF (SELECT mode FROM hr.access_apps WHERE app = 'admin_review') <> 'watch' THEN RAISE EXCEPTION 'V11 mode'; END IF;
END $v$;
COMMIT;
