-- =============================================================================
-- 2026-11-17_1045_intake_slack_tags_approvers
--
-- WHAT: public.fn_slack_event_claim also returns `approvers`: every person who can approve a Site file today (the HR App's
--   switch "Approve site files", public.fn_page_approver_ids), as {email, name}, minus the person who made the version.
--   intake-slack-post (deployed right after this file) tags them, in place of its fixed Diego and Serena.
--   Two anchored edits on the live body (md5-pinned): the version branch carries the maker's email for one statement,
--   and the last assignment adds the list and drops the maker key. Nothing else moved (diff kept in the session scratchpad).
--
-- WHY: Trello #218 (4ulTXZPc), huddle with Serena 2026-11-17: Yannick never learned a Site file was waiting (354-TBS, Oct 21).
--   Fred: "for the notifications use the one at slack the notifications app channel and tag the persons who can approve the
--   form (also remember to include the links on the notification so they can just click on it and it opens the submitted
--   review)". Measured the same day: 11 posts since 2026-11-05, all delivered, each tagging only Diego and Serena; the switch
--   lists five people (Aaron, Diego, Fred, Serena, Yannick).
--
-- 🛑 NO CODES, unchanged: the new key holds staff emails and first names only.
-- RULE 8, AUDIT: no table changes.
-- DEPLOY ORDER: this file FIRST, then intake-slack-post. The old function ignores the new key; the new function falls back to
--   Diego and Serena when the key is missing, so either order is safe.
-- ROLLBACK: 2026-11-17_1045_intake_slack_tags_approvers_rollback.sql (the old body, md5-guarded).
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $guard$
BEGIN
  IF md5(pg_get_functiondef('public.fn_slack_event_claim(text,bigint,boolean,boolean)'::regprocedure)) IS DISTINCT FROM 'e05192b2c1867eb0bef4dafeb9a8b9cb' THEN
    RAISE EXCEPTION 'fn_slack_event_claim changed since this file was written: splice again';
  END IF;
END $guard$;

-- The old body, under a temporary name: the control that must fail.
DO $old$
BEGIN
  EXECUTE replace(pg_get_functiondef('public.fn_slack_event_claim(text,bigint,boolean,boolean)'::regprocedure), 'public.fn_slack_event_claim(', 'pg_temp.old_slack_event_claim(');
END $old$;

CREATE OR REPLACE FUNCTION public.fn_slack_event_claim(p_kind text, p_id bigint, p_post_test boolean DEFAULT false, p_dry_run boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- What one Slack post may say, and the claim that makes it post once. 🛑 Named keys only: never a form's answers, a link
-- code, a version's content or source. A test client's event is skipped unless a holder of the server key asks with
-- p_post_test; the [TEST] mark comes from the client, never from the caller.
declare
  v jsonb;
  v_test boolean;
begin
  if p_kind = 'form_back' then
    select jsonb_build_object(
             'kind', 'form_back', 'ref_id', s.intake_id, 'client_id', s.client_id,
             'client_code', s.client_code, 'client_name', s.client_name, 'address', s.address, 'city', s.city,
             'who', s.collector, 'status', s.status,
             'answered', s.answered_count, 'of', s.applicable_count, 'photos', s.photo_count)
      into v
      from client.v_intake_submissions s
     where s.intake_id = p_id and s.submitted_at is not null;
  elsif p_kind = 'version_waiting' then
    select jsonb_build_object(
             'kind', 'version_waiting', 'ref_id', pg.id, 'client_id', p.client_id,
             'client_code', c.client_code, 'client_name', c.name, 'address', p.address, 'city', p.city,
             'property_id', pg.property_id, 'version', pg.version,
             'who', public.fn_page_staff_name(pg.submitted_by_email),
             'maker', lower(pg.submitted_by_email),
             'restored_from', pg.restored_from_version,
             'live_version', (select max(l.version) from public.property_pages l
                               where l.property_id = pg.property_id and l.approved_at is not null))
      into v
      from public.property_pages pg
      join public.properties p on p.id = pg.property_id
      left join public.clients c on c.id = p.client_id
     where pg.id = p_id and pg.approved_at is null and pg.rejected_at is null;
  else
    raise exception 'Unknown Slack event.' using errcode = '22023', detail = 'blocker=unknown_kind in public.fn_slack_event_claim';
  end if;
  if v is null then return jsonb_build_object('skip', 'not_found'); end if;

  v_test := coalesce(public.fn_is_non_customer((v ->> 'client_id')::bigint, array['test', 'fixture']), false);
  -- Who can approve a Site file today (the HR App's switch "Approve site files", public.fn_page_approver_ids), never the
  -- person who made this version: they cannot approve it (Trello #218, 2026-11-17). Emails, never codes; the edge function
  -- maps each to a Slack tag. Read here, at post time, so a change in the HR App needs nothing else.
  v := (v - 'client_id' - 'maker') || jsonb_build_object('test', v_test,
         'approvers', coalesce((select jsonb_agg(jsonb_build_object('email', lower(u.email), 'name', public.fn_page_staff_name(u.email))
                                                 order by lower(u.email))
                                  from auth.users u
                                 where u.id = any(public.fn_page_approver_ids())
                                   and lower(u.email) is distinct from (v ->> 'maker')), '[]'::jsonb));
  if p_dry_run then return v; end if;
  if v_test and not coalesce(p_post_test, false) then return jsonb_build_object('skip', 'test_client'); end if;

  insert into public.slack_event_posts (event_kind, ref_id) values (p_kind, p_id) on conflict do nothing;
  if not found then return jsonb_build_object('skip', 'already_claimed'); end if;
  return v;
end $function$
;

DO $verify$
DECLARE
  v_all int := (select count(*) from auth.users u where u.id = any(public.fn_page_approver_ids()));
  v_ver jsonb; v_form jsonb; v_old jsonb; v_maker text;
  v_page bigint; v_intake bigint;
BEGIN
  IF md5(pg_get_functiondef('public.fn_slack_event_claim(text,bigint,boolean,boolean)'::regprocedure)) IS DISTINCT FROM 'c0ed9be5645613cde07fccfa6c3c13d7' THEN
    RAISE EXCEPTION 'verify_fail: the new body is not the one written';
  END IF;
  IF v_all < 2 THEN RAISE EXCEPTION 'verify_fail: fewer than two approvers, the checks below would prove nothing'; END IF;
  -- a waiting version made by an approver, and a submitted form (dry runs write nothing)
  SELECT pg.id, lower(pg.submitted_by_email) INTO v_page, v_maker FROM public.property_pages pg
   WHERE pg.approved_at IS NULL AND pg.rejected_at IS NULL
     AND EXISTS (SELECT 1 FROM auth.users u WHERE u.id = any(public.fn_page_approver_ids()) AND lower(u.email) = lower(pg.submitted_by_email))
   ORDER BY pg.id DESC LIMIT 1;
  SELECT i.id INTO v_intake FROM public.property_intakes i WHERE i.submitted_at IS NOT NULL ORDER BY i.id DESC LIMIT 1;
  IF v_page IS NULL OR v_intake IS NULL THEN RAISE EXCEPTION 'verify_fail: no fixture'; END IF;

  v_ver := public.fn_slack_event_claim('version_waiting', v_page, false, true);
  v_form := public.fn_slack_event_claim('form_back', v_intake, false, true);
  IF jsonb_array_length(v_ver -> 'approvers') <> v_all - 1 THEN
    RAISE EXCEPTION 'verify_fail: version: % approvers, want %', jsonb_array_length(v_ver -> 'approvers'), v_all - 1;
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_ver -> 'approvers') a WHERE a ->> 'email' = v_maker) THEN
    RAISE EXCEPTION 'verify_fail: the maker is tagged';
  END IF;
  IF jsonb_array_length(v_form -> 'approvers') <> v_all THEN
    RAISE EXCEPTION 'verify_fail: form: % approvers, want %', jsonb_array_length(v_form -> 'approvers'), v_all;
  END IF;
  IF v_ver ? 'maker' OR v_form ? 'maker' OR v_ver ? 'client_id' THEN
    RAISE EXCEPTION 'verify_fail: a key that must not leave the function';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_form -> 'approvers') a
              WHERE coalesce(a ->> 'name', '') = '' OR position('@' in coalesce(a ->> 'email', '')) = 0) THEN
    RAISE EXCEPTION 'verify_fail: an approver with no name or email';
  END IF;
  -- the control: the old body has no list
  v_old := pg_temp.old_slack_event_claim('version_waiting', v_page, false, true);
  IF v_old ? 'approvers' THEN RAISE EXCEPTION 'verify_fail: the control passed, the check proves nothing'; END IF;
  -- grants unchanged
  IF has_function_privilege('anon', 'public.fn_slack_event_claim(text,bigint,boolean,boolean)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.fn_slack_event_claim(text,bigint,boolean,boolean)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.fn_slack_event_claim(text,bigint,boolean,boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'verify_fail: fn_slack_event_claim is callable by the wrong role';
  END IF;
  RAISE NOTICE 'verify ok: % approvers; version % tags %; form % tags %', v_all, v_page,
    jsonb_array_length(v_ver -> 'approvers'), v_intake, jsonb_array_length(v_form -> 'approvers');
END $verify$;

COMMIT;
