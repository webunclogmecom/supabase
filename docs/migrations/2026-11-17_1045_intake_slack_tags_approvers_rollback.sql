-- ROLLBACK of 2026-11-17_1045_intake_slack_tags_approvers: puts back the body of 2026-11-05_0600 (Diego and Serena come
-- back from the edge function's fallback). Refuses to run unless the live body is the one 1045 wrote.
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $guard$
BEGIN
  IF md5(pg_get_functiondef('public.fn_slack_event_claim(text,bigint,boolean,boolean)'::regprocedure)) IS DISTINCT FROM 'c0ed9be5645613cde07fccfa6c3c13d7' THEN
    RAISE EXCEPTION 'fn_slack_event_claim is not the 1045 body: nothing rolled back';
  END IF;
END $guard$;
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
  v := (v - 'client_id') || jsonb_build_object('test', v_test);
  if p_dry_run then return v; end if;
  if v_test and not coalesce(p_post_test, false) then return jsonb_build_object('skip', 'test_client'); end if;

  insert into public.slack_event_posts (event_kind, ref_id) values (p_kind, p_id) on conflict do nothing;
  if not found then return jsonb_build_object('skip', 'already_claimed'); end if;
  return v;
end $function$
;
DO $verify$
BEGIN
  IF md5(pg_get_functiondef('public.fn_slack_event_claim(text,bigint,boolean,boolean)'::regprocedure)) IS DISTINCT FROM 'e05192b2c1867eb0bef4dafeb9a8b9cb' THEN
    RAISE EXCEPTION 'verify_fail: the old body did not come back';
  END IF;
END $verify$;
COMMIT;
