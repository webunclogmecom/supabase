-- 2026-11-24_1430_derm_portal_waiting_visits_rollback.sql
-- Puts back ops.portal_waiting as it was before 2026-11-24_1430 (md5 ebc977d61e661cad3d5823ec797ce29d) and drops the two new functions.
-- Run it only while the portal does not call derm.portal_waiting_visits (its filters would then read nothing).
begin;
do $guard$ begin
  if position('derm.fn_gdo_pending()' in pg_get_functiondef('ops.portal_waiting'::regproc)) = 0 then
    raise exception 'GUARD: ops.portal_waiting is not the 2026-11-24_1430 body; nothing to roll back here';
  end if;
end $guard$;
CREATE OR REPLACE FUNCTION ops.portal_waiting()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_access jsonb := hr.get_my_access();
  v_closed text[];
  v_out jsonb := '{}'::jsonb;
  v_admin jsonb;
BEGIN
  IF v_access IS NULL OR v_access->>'employee_id' IS NULL THEN
    RETURN v_out;
  END IF;

  SELECT coalesce(array_agg(a->>'app'), '{}'::text[]) INTO v_closed
    FROM jsonb_array_elements(coalesce(v_access->'apps', '[]'::jsonb)) a
   WHERE a->>'mode' = 'on' AND coalesce(a->>'level', 'none') NOT IN ('view', 'edit');

  IF NOT 'visit_calendar' = ANY (v_closed) THEN
    v_out := v_out || jsonb_build_object(
      'call_first', (SELECT count(*) FROM ops.visit_requests r
                      WHERE r.deleted_at IS NULL AND r.status = 'open' AND r.call_required),
      'time_on_site', jsonb_array_length(coalesce(
        public.fn_time_on_site_gaps(((now() AT TIME ZONE 'America/New_York')::date - 1))->'visits', '[]'::jsonb)));
  END IF;

  IF NOT 'admin_review' = ANY (v_closed) THEN
    v_admin := public.fn_admin_review_pending();
    v_out := v_out || jsonb_build_object(
      'photos_unsorted', coalesce((v_admin->'photos'->>'count')::int, 0),
      'city_emails', jsonb_array_length(coalesce(v_admin->'city', '[]'::jsonb)));
  END IF;

  IF NOT 'stamp_studio' = ANY (v_closed) THEN
    v_out := v_out || jsonb_build_object('stamp_sheets', jsonb_array_length(coalesce(derm.fn_stamp_open_sheets(), '[]'::jsonb)));
  END IF;

  IF NOT 'derm_tracker' = ANY (v_closed) THEN
    v_out := v_out || jsonb_build_object('unopened_emails', jsonb_array_length(coalesce(public.fn_unopened_emails(now())->'emails', '[]'::jsonb)));
  END IF;

  -- 2026-11-09_1230: Site file versions waiting for approval, only for someone who can approve them (Picture Planner open,
  -- and "Approve site files" by the one approver rule, public.fn_page_approver_ids()). The same versions the
  -- #apps-notifications post announces (public.fn_slack_event_claim, version_waiting): neither approved nor rejected, on a
  -- real client (test clients left out the same way), on a property not removed, and above the property's live version,
  -- because a version below the live one can no longer be decided (Picture Planner rules 20 and 27).
  IF NOT 'picture_planner' = ANY (v_closed) AND auth.uid() = ANY (public.fn_page_approver_ids()) THEN
    -- 2026-11-18 (Fred: "E 2"): counted per LOCATION, so the menu, the bell and the Home say what the Page Builder list's
    -- "Waiting for approval" says (354-TBS had v1 and v2 both waiting: 3 versions, 2 locations). The Slack post stays one
    -- per version.
    v_out := v_out || jsonb_build_object('site_files', (
      SELECT count(DISTINCT pg.property_id)
        FROM public.property_pages pg
        JOIN public.properties p ON p.id = pg.property_id
       WHERE pg.approved_at IS NULL AND pg.rejected_at IS NULL AND p.deleted_at IS NULL
         AND pg.version > coalesce((SELECT max(l.version) FROM public.property_pages l
                                     WHERE l.property_id = pg.property_id AND l.approved_at IS NOT NULL), 0)
         AND NOT coalesce(public.fn_is_non_customer(p.client_id, array['test', 'fixture']), false)));
  END IF;

  -- 2026-11-16 (Trello #210, Fred's default "bell"): the Ops Portal's Home lists "Needs you" from this same answer, so the
  -- bell and the Home can never disagree. Four counts added, each behind the app that holds its list:
  --   late_today, requests_open (Visit Calendar): today's visits past their job's due date (late_status 'late', the
  --     Calendar's red mark; ops.portal_home's "late" is the same predicate), and every open visit request (call_first
  --     stays: the Home shows it as the detail of this line);
  --   reviews_pending (Admin Review): the review queue's rule (completed, in scope, dated today or before, pending);
  --   manifests_need_someone (DERM Tracker): the Manifests list's "Needs someone" rows, read from the one core
  --     (derm.fn_manifest_row_states_core): a test row never counts, a row counts when any place is amber or red.
  IF NOT 'visit_calendar' = ANY (v_closed) THEN
    v_out := v_out || jsonb_build_object(
      'late_today', (SELECT count(*) FROM ops.v_calendar_visit v
                      WHERE v.visit_date = (now() AT TIME ZONE 'America/New_York')::date
                        AND v.visit_status <> 'cancelled' AND v.late_status = 'late'),
      'requests_open', (SELECT count(*) FROM ops.visit_requests r WHERE r.deleted_at IS NULL AND r.status = 'open'));
  END IF;

  IF NOT 'admin_review' = ANY (v_closed) THEN
    v_out := v_out || jsonb_build_object('reviews_pending', (
      SELECT count(*) FROM public.visits_with_review w
       WHERE w.visit_status = 'completed' AND w.in_review_scope
         AND w.visit_date <= (now() AT TIME ZONE 'America/New_York')::date AND w.review_status = 'pending'));
  END IF;

  IF NOT 'derm_tracker' = ANY (v_closed) THEN
    v_out := v_out || jsonb_build_object('manifests_need_someone', (
      SELECT count(*) FROM jsonb_each(derm.fn_manifest_row_states_core()) e
       WHERE NOT coalesce((e.value->>'test')::boolean, false)
         AND EXISTS (SELECT 1 FROM unnest(ARRAY['papers', 'stamps', 'copies', 'city', 'visit', 'email']) p(place)
                      WHERE e.value->p.place->>'s' IN ('warn', 'bad'))));
  END IF;

  -- 2026-11-17_1720 (Trello #161, Fred: the menu's counts follow what #apps-notifications posts). Two counts:
  --   gdo_pending (DERM Tracker, the same gate as the other DERM keys): the GDO Online Report bot's "pending" list, as its
  --     08:00 Daily digest prints it, rebuilt from the results the bot posts to us (rpa-derm-result writes
  --     public.derm_portal_submissions). The bot's own rule (its db.attention_sql): a live ERROR attempt in the last 30 days
  --     with no SUCCESS on the same permit and manifest after it; an attempt with no permit is settled by a later SUCCESS
  --     on the same visit and manifest. One per (permit, manifest), as the digest lists them. A filing recorded by hand
  --     in the DERM Tracker counts as filed here; the bot never hears of it, so its digest would keep listing it.
  --   intake_back (Picture Planner, the same gate as site_files; the "Intake form back" post tags these approvers): a
  --     returned site survey (submitted, not cancelled, real client, property not removed), counted until a Site file
  --     version made after the form came back is approved (Fred: "counted until its Site file version is approved").
  IF NOT 'derm_tracker' = ANY (v_closed) THEN
    v_out := v_out || jsonb_build_object('gdo_pending', (
      SELECT count(DISTINCT (e.gdo_id, e.manifest_id))
        FROM public.derm_portal_submissions e
       WHERE e.status LIKE 'ERROR%' AND NOT e.dry_run
         AND e.attempted_at >= now() - interval '30 days'
         AND NOT EXISTS (SELECT 1 FROM public.derm_portal_submissions s
                          WHERE s.manifest_id = e.manifest_id AND NOT s.dry_run
                            AND (s.status = 'SUCCESS' OR s.portal_confirmation IS NOT NULL)
                            AND s.attempted_at > e.attempted_at
                            AND (s.gdo_id = e.gdo_id OR (e.gdo_id IS NULL AND s.visit_id = e.visit_id)))));
  END IF;

  IF NOT 'picture_planner' = ANY (v_closed) AND auth.uid() = ANY (public.fn_page_approver_ids()) THEN
    v_out := v_out || jsonb_build_object('intake_back', (
      SELECT count(*)
        FROM public.property_intakes i
        JOIN public.properties p ON p.id = i.property_id
       WHERE i.submitted_at IS NOT NULL AND i.cancelled_at IS NULL AND p.deleted_at IS NULL
         AND NOT coalesce(public.fn_is_non_customer(p.client_id, array['test', 'fixture']), false)
         AND NOT EXISTS (SELECT 1 FROM public.property_pages pg
                          WHERE pg.property_id = i.property_id AND pg.approved_at IS NOT NULL
                            AND pg.submitted_at > i.submitted_at)));
  END IF;

  RETURN v_out;
END;
$function$;
drop function if exists derm.portal_waiting_visits(text);
drop function if exists derm.fn_gdo_pending();
do $verify$ begin
  if md5(pg_get_functiondef('ops.portal_waiting'::regproc)) <> 'ebc977d61e661cad3d5823ec797ce29d' then
    raise exception 'VERIFY: ops.portal_waiting is not back to its 2026-11-17 body';
  end if;
end $verify$;
commit;
