-- 2026-10-20_1935_visit_bonus_custom_amount_and_sorted_photos.sql
--
-- Trello bZvoo91Z ("Admin Review App: custom bonus override per visit", from Yan in the 2026-10-19 huddle). Fred, 2026-10-20:
--   "the idea is to put the bonus on the Admin Review App to be able to be changed manually when looking at it, but one
--    caveat, all the pictures there has to be sorted and Approved before the drivers get the bonus from now on."
--   "When i mean approved is that each section of photos have a "Bonus" approved or rejected, so all of them needs to be
--    approved for the driver to get a bonus. Then it will be shown at the "Photo Bonus:" at the end, where it should put it
--    on 0 if any was rejected, or in green with the bonus amount. And that should be editable ... also that should be saved
--    who change that number btw in the history activity"
-- Yan (huddle [26:36]-[27:11]): Michael's bonus is $13; a very complicated job gets e.g. $40, "to replace the 13 by
-- something else". So a custom amount REPLACES the person's amount on that one visit; it does not add to it.
--
-- 1. Custom amount per person per visit. NEW hr.visit_bonus_overrides (append-only, newest row per visit and person wins,
--    amount NULL = back to the normal amount; who / when / optional why). Written only by NEW hr.set_visit_bonus (same people
--    as hr.set_person_bonus: admins, or office with "Pay rates and bonus settings"; plus Edit in Admin Review; the person must
--    be on the visit's Calendar crew, the crew HR pays). NEW hr.fn_visit_rate_on prices one person on one visit.
--    - hr.fn_sync_visit_bonus records an approved bonus at the custom amount (note "Custom amount for this visit, set by X:
--      why"; NEW column hr.bonus_events.override_id). When the custom amount changes AFTER the bonus was recorded, the
--      bonus is taken back and recorded again at the new amount. Only a change to THIS visit's custom amount does that: the
--      2026-10-19_1815 rule (a change to the person's normal amount never re-prices a recorded bonus) is unchanged, and
--      every bonus recorded before today has override_id NULL, so none can move.
--    - hr.fn_pending_bonus and hr.get_employee_record's pending rows use the custom amount; the person's Activity in the HR
--      App lists every change (operation RATE, app "Admin Review", old -> new, reason) as Fred asked.
--    - hr.get_review_bonuses returns per visit `custom` ({employee_id: amount, reason, set_by, set_on}, hidden like the other
--      amounts) and `can_set_amounts` for the Admin Review edit button.
-- 2. Photos sorted before a bonus. NEW BEFORE trigger ab_bonus_needs_sorted_photos on public.visit_reviews: moving a visit
--    bonus TO approved needs every photo sorted (public.v_visit_photo_counts, the "Photos Not Sorted" count). "Approved" per
--    photo section stays the app's rule (it writes bonus_status = approved only when all three sections say Approved). Only
--    the move to approved is checked: bonuses approved before today stay. Measured 2026-10-20 19:30 ET: 2 approved bonuses
--    have photos not sorted (visits 8591 and 8860, both approved 2026-10-20 ~12:00 ET); they are left as they are ("from
--    now on"). Measured after: both were fully sorted when approved, the photos arrived afterwards (8860: 1 photo 2 min
--    later; 8591: 3 photos 1.5 h later), so no bonus was approved against this rule. The review page already shows the
--    Bonus sections only once every photo is confirmed; this trigger covers a photo that arrives while the page is open
--    and every other writer. A Missed visit or Not eligible save writes denied and is never blocked.
--
-- Rule 8: tables touched: NEW hr.visit_bonus_overrides; hr.bonus_events gains one NULL column (append-only table, no row
-- rewritten); public.visit_reviews gains one trigger. Rehearsed in BEGIN ... ROLLBACK with
-- scripts/checks/hr_app/probe_visit_bonus_custom.sql, and the rollback rehearsed after the forward.
-- Rollback: 2026-10-20_rollback_visit_bonus_custom_amount_and_sorted_photos.sql.

BEGIN;
SET LOCAL lock_timeout = '3s';
DO $g$ BEGIN
  IF md5(regexp_replace(pg_get_functiondef('hr.fn_sync_visit_bonus(bigint,text,text)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> 'cbab4056146d6a39bf3cc5bb5e393d21' THEN RAISE EXCEPTION 'guard: hr.fn_sync_visit_bonus(bigint,text,text) changed'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('hr.fn_pending_bonus(bigint,date)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> '452827687edbf4342cbe6392b3eb2d7d' THEN RAISE EXCEPTION 'guard: hr.fn_pending_bonus(bigint,date) changed'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('hr.get_review_bonuses(bigint[],jsonb)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> '9e131bde6f568ceab91801f42dacd2ce' THEN RAISE EXCEPTION 'guard: hr.get_review_bonuses(bigint[],jsonb) changed'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('hr.get_employee_record(bigint)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> '3bd58f602f3c4c891e71b246c91b4a1d' THEN RAISE EXCEPTION 'guard: hr.get_employee_record(bigint) changed'; END IF;
  IF to_regclass('hr.visit_bonus_overrides') IS NOT NULL THEN RAISE EXCEPTION 'guard: hr.visit_bonus_overrides already exists'; END IF;
END $g$;
CREATE TEMP TABLE acl_before ON COMMIT DROP AS
  SELECT p.oid::regprocedure::text k, p.proacl::text a FROM pg_proc p
   WHERE p.oid IN ('hr.fn_sync_visit_bonus(bigint,text,text)'::regprocedure, 'hr.fn_pending_bonus(bigint,date)'::regprocedure, 'hr.get_review_bonuses(bigint[],jsonb)'::regprocedure, 'hr.get_employee_record(bigint)'::regprocedure);
CREATE TEMP TABLE pending_before ON COMMIT DROP AS
  SELECT e.id, hr.fn_pending_bonus(e.id, (now() at time zone 'America/New_York')::date) amt FROM public.employees e;
CREATE TEMP TABLE grants_before ON COMMIT DROP AS SELECT count(*) n, sum(amount) s FROM hr.bonus_events;

-- ---------- the custom amounts: one row per change, never edited ----------
CREATE TABLE hr.visit_bonus_overrides (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  visit_id bigint NOT NULL REFERENCES public.visits(id) ON DELETE RESTRICT,
  employee_id bigint NOT NULL REFERENCES public.employees(id) ON DELETE RESTRICT,
  amount numeric CHECK (amount IS NULL OR (amount >= 0 AND amount <= 1000 AND amount = round(amount, 2))),
  reason text CHECK (reason IS NULL OR (btrim(reason) <> '' AND length(reason) <= 500)),
  created_by_email text,
  created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE hr.visit_bonus_overrides IS
  'A custom visit bonus for ONE person on ONE visit, set in Admin Review (Trello bZvoo91Z, 2026-10-20). The newest row per '
  '(visit_id, employee_id) is in force; amount NULL means back to the person''s normal amount. Append-only: every change '
  'is a new row (who, when, why). Written only by hr.set_visit_bonus; read through hr.fn_visit_rate_on.';
CREATE INDEX visit_bonus_overrides_pair ON hr.visit_bonus_overrides (visit_id, employee_id, id DESC);
CREATE INDEX visit_bonus_overrides_employee ON hr.visit_bonus_overrides (employee_id);
CREATE TRIGGER visit_bonus_overrides_append_only BEFORE UPDATE OR DELETE ON hr.visit_bonus_overrides
  FOR EACH ROW EXECUTE FUNCTION public.fn_append_only_guard();
CREATE TRIGGER visit_bonus_overrides_no_truncate BEFORE TRUNCATE ON hr.visit_bonus_overrides
  FOR EACH STATEMENT EXECUTE FUNCTION public.fn_append_only_guard();
REVOKE ALL ON hr.visit_bonus_overrides FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON hr.visit_bonus_overrides TO db_backup_reader;

-- which custom amount a recorded bonus was priced with (NULL = none, as every bonus recorded before this migration)
ALTER TABLE hr.bonus_events ADD COLUMN override_id bigint REFERENCES hr.visit_bonus_overrides(id);
COMMENT ON COLUMN hr.bonus_events.override_id IS
  'The hr.visit_bonus_overrides row in force when this visit bonus was recorded (also a row that removed a custom amount). '
  'hr.fn_sync_visit_bonus re-prices a recorded bonus only when this differs from the newest row for the visit and person.';

-- ---------- one person's visit bonus on one visit ----------
CREATE FUNCTION hr.fn_visit_rate_on(p_employee_id bigint, p_visit_id bigint, p_day date)
 RETURNS TABLE(rate_id bigint, amount numeric, override_id bigint, custom boolean, custom_note text)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  -- 2026-10-20 (Trello bZvoo91Z): a custom amount set for this person on this visit (the newest
  -- hr.visit_bonus_overrides row, when its amount is not NULL) replaces their normal amount; otherwise their normal amount
  -- on the visit date (hr.fn_rate_on, rate_id set). override_id is the newest row even when it removed the custom amount.
  select case when o.amount is not null then null else r.rate_id end,
         case when o.amount is not null then o.amount else r.amount end,
         o.id,
         coalesce(o.amount is not null, false),
         case when o.amount is not null then 'Custom amount for this visit, set by '
                || coalesce(hr.fn_person_label(o.created_by_email), 'someone outside the apps') || coalesce(': ' || o.reason, '') end
    from hr.fn_rate_on(p_employee_id, 'per_visit_bonus', p_day) r
    left join lateral (select x.id, x.amount, x.reason, x.created_by_email from hr.visit_bonus_overrides x
                        where x.visit_id = p_visit_id and x.employee_id = p_employee_id
                        order by x.id desc limit 1) o on true
$function$;
REVOKE ALL ON FUNCTION hr.fn_visit_rate_on(bigint, bigint, date) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION hr.set_visit_bonus(p_visit_id bigint, p_employee_id bigint, p_amount numeric, p_reason text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-10-20 (Trello bZvoo91Z). Fred: "that should be editable, so you can put a manual amount in case someone wants to put
-- a different number, also that should be saved who change that number". Yan (huddle 2026-10-19): a complicated job gets
-- e.g. $40 instead of the person's $13. One person's visit bonus on ONE visit; p_amount NULL goes back to their normal
-- amount. Same people as hr.set_person_bonus (admins, or office with "Pay rates and bonus settings"), plus Edit in Admin
-- Review. Every change is a new row; a bonus already recorded is taken back and recorded again at the new amount.
declare
  v_email text := lower(btrim(nullif(auth.jwt()->>'email', '')));
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_status text; v_deleted timestamptz; v_found boolean := false; v_current numeric; v_rows int;
begin
  perform hr.fn_check_app('admin_review', 'edit', 'visit bonus amount');
  perform 1 from hr.fn_require_level(array['admin', 'office']);
  perform hr.fn_require_app_or_level('hr_pay', 'yes', array['admin']);
  select true, v.visit_status, v.deleted_at into v_found, v_status, v_deleted from public.visits v where v.id = p_visit_id;
  if not coalesce(v_found, false) or v_deleted is not null then
    raise exception 'That visit was not found. Reload the page.' using errcode = 'P0002', detail = 'blocker=not_found visit_id=' || coalesce(p_visit_id::text, 'null');
  end if;
  if v_status <> 'completed' then
    raise exception 'A bonus amount can be set only on a completed visit. Nothing was saved.' using errcode = '22023', detail = 'blocker=not_completed';
  end if;
  if not exists (select 1 from public.visit_team t where t.visit_id = p_visit_id and t.employee_id = p_employee_id) then
    raise exception 'That person is not on this visit''s crew in the Visit Calendar, so they get no bonus for it. Nothing was saved.'
      using errcode = '22023', detail = 'blocker=not_on_crew';
  end if;
  if p_amount is not null and (p_amount < 0 or p_amount > 1000 or p_amount <> round(p_amount, 2)) then
    raise exception 'The amount must be between $0 and $1,000, in cents at most. Nothing was saved.' using errcode = '22023', detail = 'blocker=amount_range';
  end if;
  if length(v_reason) > 500 then
    raise exception 'The reason is too long (500 characters at most). Nothing was saved.' using errcode = '22023', detail = 'blocker=reason_long';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('hr.bonus.visit:' || p_visit_id, 0));
  select o.amount into v_current from hr.visit_bonus_overrides o
   where o.visit_id = p_visit_id and o.employee_id = p_employee_id order by o.id desc limit 1;
  if v_current is not distinct from p_amount then   -- the same amount, or "normal" when it already is
    return jsonb_build_object('noop', true);
  end if;
  insert into hr.visit_bonus_overrides (visit_id, employee_id, amount, reason, created_by_email)
  values (p_visit_id, p_employee_id, p_amount, v_reason, v_email);
  v_rows := hr.fn_sync_visit_bonus(p_visit_id, 'trigger', v_email);
  return jsonb_build_object('noop', false, 'amount', p_amount, 'bonus_rows', v_rows);
end $function$;
REVOKE ALL ON FUNCTION hr.set_visit_bonus(bigint, bigint, numeric, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION hr.set_visit_bonus(bigint, bigint, numeric, text) TO authenticated;

-- ---------- a visit bonus is approved only when every photo is sorted ----------
CREATE FUNCTION hr.trg_visit_bonus_needs_sorted_photos()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-10-20 (Trello bZvoo91Z). Fred: "all the pictures there has to be sorted and Approved before the drivers get the bonus
-- from now on". Approving a visit bonus needs every photo of the visit sorted (before / after / internal / extra: the rule of
-- public.v_visit_photo_counts, the same count as the queue's "Photos Not Sorted" filter). "Approved" (every photo section's
-- Bonus button) is the app's rule and it writes bonus_status only then. Only the move TO approved is checked, so a bonus
-- approved before this rule, or before a late photo arrived, stays approved and can be saved again. An upsert fires the
-- INSERT trigger first even when the row exists, so the INSERT branch reads the stored row.
declare v_was text; v_left bigint;
begin
  if new.bonus_status is distinct from 'approved' then return new; end if;
  if tg_op = 'UPDATE' then v_was := old.bonus_status;
  else select r.bonus_status into v_was from public.visit_reviews r where r.visit_id = new.visit_id;
  end if;
  if v_was is not distinct from 'approved' then return new; end if;
  select c.total_images - c.classified_images into v_left from public.v_visit_photo_counts c where c.visit_id = new.visit_id;
  if coalesce(v_left, 0) > 0 then
    raise exception 'Sort every photo of this visit before approving the bonus (% still not sorted). Nothing was saved.', v_left
      using errcode = '23514', detail = 'blocker=photos_not_sorted visit_id=' || new.visit_id;
  end if;
  return new;
end $function$;
REVOKE ALL ON FUNCTION hr.trg_visit_bonus_needs_sorted_photos() FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER ab_bonus_needs_sorted_photos BEFORE INSERT OR UPDATE ON public.visit_reviews
  FOR EACH ROW EXECUTE FUNCTION hr.trg_visit_bonus_needs_sorted_photos();


CREATE OR REPLACE FUNCTION hr.fn_sync_visit_bonus(p_visit_id bigint, p_filled_by text, p_decider text DEFAULT NULL::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_expected boolean; v_open int; v_n int := 0; v_date date; v_decided timestamptz;
  v_crew bigint[]; v_e bigint; v_rate_id bigint; v_amount numeric; v_decider text := p_decider;
  v_note text; v_status text; v_g record; v_ovr bigint; v_custom boolean; v_cnote text;
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
      -- 2026-10-20 (Trello bZvoo91Z): a custom amount set for this person on this visit replaces their normal amount
      select r.rate_id, r.amount, r.override_id, r.custom_note into v_rate_id, v_amount, v_ovr, v_cnote
        from hr.fn_visit_rate_on(v_e, p_visit_id, v_date) r;
      insert into hr.bonus_events (kind, employee_id, visit_id, work_date, amount, pay_rate_id, rule, note, crew_size,
                                   decided_by_email, decided_at, filled_by, override_id)
      values ('visit_bonus', v_e, p_visit_id, v_date, coalesce(v_amount, 0), v_rate_id, 'approved', v_cnote, cardinality(v_crew),
              v_decider, coalesce(v_decided, now()), p_filled_by, v_ovr);
      v_n := v_n + 1;
    end loop;
  elsif v_expected and v_open > 0 then
    -- 2026-10-20 (Trello bZvoo91Z): the custom amount of this visit changed after the bonus was recorded. Only a change to
    -- THIS visit's custom amount re-prices a recorded bonus (taken back, recorded again); a change to the person's normal
    -- amount never does (2026-10-19_1815). A grant recorded before any custom amount has override_id NULL and so does
    -- fn_visit_rate_on while the visit has none: nothing older than this rule can ever move.
    for v_g in select * from hr.bonus_events g
              where g.kind = 'visit_bonus' and g.visit_id = p_visit_id and g.reverses_id is null
                and not exists (select 1 from hr.bonus_events r where r.reverses_id = g.id)
              order by g.id loop
      select r.rate_id, r.amount, r.override_id, r.custom, r.custom_note into v_rate_id, v_amount, v_ovr, v_custom, v_cnote
        from hr.fn_visit_rate_on(v_g.employee_id, p_visit_id, v_g.work_date) r;
      continue when v_ovr is not distinct from v_g.override_id or coalesce(v_amount, 0) = v_g.amount;
      insert into hr.bonus_events (kind, employee_id, visit_id, work_date, amount, pay_rate_id, rule, note, crew_size,
                                   decided_by_email, decided_at, reverses_id, filled_by)
      values ('visit_bonus', v_g.employee_id, p_visit_id, v_g.work_date, -v_g.amount, v_g.pay_rate_id, 'reversal',
              case when v_custom then 'Replaced by the custom amount set for this visit.'
                   else 'The custom amount for this visit was removed.' end,
              v_g.crew_size, p_decider, now(), v_g.id, p_filled_by);
      insert into hr.bonus_events (kind, employee_id, visit_id, work_date, amount, pay_rate_id, rule, note, crew_size,
                                   decided_by_email, decided_at, filled_by, override_id)
      values ('visit_bonus', v_g.employee_id, p_visit_id, v_g.work_date, coalesce(v_amount, 0), v_rate_id, 'approved', v_cnote,
              v_g.crew_size, coalesce(p_decider, v_g.decided_by_email), now(), p_filled_by, v_ovr);
      v_n := v_n + 2;
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
      from (select i.shift_date
              from public.inspections i
             where i.employee_id = p_employee_id and i.shift_date >= p_today - 28 and i.shift_date <= p_today
             group by i.shift_date
            having bool_or(i.inspection_type = 'PRE') and bool_or(i.inspection_type = 'POST')
               and not bool_or(coalesce(i.has_issue, false))) s
      cross join lateral hr.fn_rate_on(p_employee_id, 'per_shift_bonus', s.shift_date) r
     where not exists (select 1 from public.shift_reviews sr
                        where sr.employee_id = p_employee_id and sr.shift_date = s.shift_date
                          and coalesce(sr.bonus_status, 'pending') <> 'pending')), 0)
$function$;

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
    -- 2026-10-20 (Trello bZvoo91Z): may this person set a custom amount (hr.set_visit_bonus would let them)
    'can_set_amounts', v_see and coalesce(hr.fn_caller_level() in ('admin', 'office'), false)
                       and case when hr.fn_app_mode('hr_pay') = 'on' then hr.fn_access_rank(hr.fn_app_level('hr_pay')) >= 1
                                else hr.fn_caller_level() = 'admin' end
                       and (hr.fn_app_mode('admin_review') <> 'on' or hr.fn_access_rank(hr.fn_app_level('admin_review')) >= 2),
    'visits', coalesce((
      select jsonb_object_agg(v.id::text, jsonb_build_object(
               'crew', coalesce((select jsonb_agg(jsonb_build_object('employee_id', e.id, 'name', e.full_name) order by e.full_name)
                                   from public.visit_team vt join public.employees e on e.id = vt.employee_id
                                  where vt.visit_id = v.id), '[]'::jsonb),
               'recorded', case when not v_see then null else (select jsonb_agg(jsonb_build_object('employee_id', g.employee_id, 'amount', g.amount) order by g.employee_id)
                              from hr.bonus_events g
                             where g.kind = 'visit_bonus' and g.visit_id = v.id and g.reverses_id is null
                               and not exists (select 1 from hr.bonus_events r where r.reverses_id = g.id)) end,
               -- 2026-10-20 (Trello bZvoo91Z): custom amounts for this visit, per crew member ("employee_id": {...})
               'custom', case when not v_see then null else (
                 select jsonb_object_agg(o.employee_id::text, jsonb_build_object('amount', o.amount, 'reason', o.reason,
                          'set_by', hr.fn_person_label(o.created_by_email),
                          'set_on', (o.created_at at time zone 'America/New_York')::date))
                   from (select distinct on (x.employee_id) x.* from hr.visit_bonus_overrides x
                          where x.visit_id = v.id order by x.employee_id, x.id desc) o
                  where o.amount is not null) end))
        from (select distinct unnest(p_visit_ids) as id) v), '{}'::jsonb),
    'shifts', case when not v_see then '{}'::jsonb else coalesce((
      select jsonb_object_agg((x->>'employee_id') || '|' || (x->>'shift_date'), g.amount)
        from jsonb_array_elements(p_shifts) x
        join hr.bonus_events g on g.kind = 'shift_bonus' and g.employee_id = (x->>'employee_id')::bigint
                              and g.work_date = (x->>'shift_date')::date and g.reverses_id is null
                              and not exists (select 1 from hr.bonus_events r where r.reverses_id = g.id)), '{}'::jsonb) end);
end $function$;

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
      'note', x.note,
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
          from (select i.shift_date from public.inspections i
                 where i.employee_id = p_id and i.shift_date >= v_today - 28 and i.shift_date <= v_today
                 group by i.shift_date
                having bool_or(i.inspection_type = 'PRE') and bool_or(i.inspection_type = 'POST')
                   and not bool_or(coalesce(i.has_issue, false))) s
         where not exists (select 1 from public.shift_reviews sr where sr.employee_id = p_id and sr.shift_date = s.shift_date
                             and coalesce(sr.bonus_status, 'pending') <> 'pending')
        union all
        select sr.shift_date, 'rejected', sr.bonus_decided_at, sr.bonus_denial_note
          from public.shift_reviews sr where sr.employee_id = p_id and sr.bonus_status = 'denied'
      ) x
      left join lateral hr.fn_rate_on(p_id, 'per_shift_bonus', x.shift_date) r on true
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
        jsonb_build_object('field', 'Reason', 'old', null, 'new', p.reason))) a
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

DO $v$ BEGIN
  IF EXISTS (SELECT 1 FROM acl_before b JOIN pg_proc p ON p.oid = b.k::regprocedure WHERE p.proacl::text IS DISTINCT FROM b.a) THEN
    RAISE EXCEPTION 'VERIFY 1: privileges of a replaced function moved'; END IF;
  IF (SELECT proacl::text FROM pg_proc WHERE oid = 'hr.set_visit_bonus(bigint,bigint,numeric,text)'::regprocedure)
     IS DISTINCT FROM '{postgres=X/postgres,authenticated=X/postgres}' THEN
    RAISE EXCEPTION 'VERIFY 2: hr.set_visit_bonus privileges are %', (SELECT proacl::text FROM pg_proc WHERE oid = 'hr.set_visit_bonus(bigint,bigint,numeric,text)'::regprocedure); END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid IN ('hr.fn_visit_rate_on(bigint,bigint,date)'::regprocedure, 'hr.trg_visit_bonus_needs_sorted_photos()'::regprocedure)
              AND p.proacl::text IS DISTINCT FROM '{postgres=X/postgres}') THEN
    RAISE EXCEPTION 'VERIFY 3: a helper function is callable by more than its owner'; END IF;
  IF has_table_privilege('authenticated', 'hr.visit_bonus_overrides', 'SELECT') OR has_table_privilege('anon', 'hr.visit_bonus_overrides', 'SELECT') THEN
    RAISE EXCEPTION 'VERIFY 4: hr.visit_bonus_overrides is readable by an app role'; END IF;
  IF EXISTS (SELECT 1 FROM pending_before b WHERE b.amt IS DISTINCT FROM hr.fn_pending_bonus(b.id, (now() at time zone 'America/New_York')::date)) THEN
    RAISE EXCEPTION 'VERIFY 5: a pending bonus total moved (there is no custom amount yet)'; END IF;
  IF (SELECT count(*) FROM hr.bonus_events) <> (SELECT n FROM grants_before) THEN
    RAISE EXCEPTION 'VERIFY 6: hr.bonus_events changed'; END IF;
  RAISE NOTICE 'VERIFY passed';
END $v$;
NOTIFY pgrst, 'reload schema';
COMMIT;
