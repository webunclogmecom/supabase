-- =============================================================================
-- 2026-11-05_0600_intake_slack_posts
--
-- WHAT: a Slack post when an intake form comes back and when a Site file version waits for approval.
--   1. NEW table public.slack_event_posts: one row per event that was claimed for posting. The claim is what makes a post
--      go out once, and the row is where a failed post leaves its reason.
--   2. NEW public.trg_slack_event_request(), triggers zz_slack_form_back (public.property_intakes, submitted_at NULL to
--      set, once ever) and zz_slack_version_waiting (public.property_pages, on INSERT): queue one pg_net call to the edge
--      function intake-slack-post. Inside the writer's transaction, so a rolled-back submit posts nothing.
--      Its errors are swallowed (a warning): a submit can never fail because of it. Same shape as trg_size_lookup_request.
--   3. NEW public.fn_slack_event_claim(): the facts one post may say, named keys only, and the claim.
--   4. public.fn_notification_health_items (spliced, md5-pinned, one anchored edit): item intake_post_missing, in Fred's
--      health email, for an event with no posted_at from 15 minutes on, for 7 days. Real clients only.
--   5. app_config intake_slack_posts_since: events before this migration are never listed.
--
-- WHY: Fred, 2026-11-05, office training film (Trello sfD4mhwm), asked how the office learns a form is back or a version waits, picked
--      "Build a Slack post first". From the mockups: "go with option B short". Tags: "Diego and Serena", never the person who made the version.
--      The gap, measured the same day: 11 real forms back, 0 saved; 2 real versions on one client (Oct 21), 0 approved, nobody told.
--      No backfill: only new events post.
--
-- 🛑 NO CODES: fn_slack_event_claim reads client.v_intake_submissions (no token, no answers: the view does not carry them)
--    and named columns of property_pages (never content, never source). VERIFY plants a value and looks for it.
-- WHY NOT IN intake-submit: it is the public no-login function; it stays unchanged, holds no Slack token and needs no
--    redeploy. client.submit_property_page runs in the browser's request, so no edge function sees a version at all. One
--    trigger path covers both events and every future writer. Proven path: zz_size_lookup_on_submit does the same, a real
--    form at 2026-11-05 02:44:25 UTC had its lookup row at 02:44:30.
-- WHY A DEFINER FUNCTION: service_role holds NO select on client.v_intake_submissions (has_table_privilege false, measured
--    2026-11-05, and SET ROLE service_role answers 42501), and rule 3b says read the app's own view, never rebuild it.
--
-- RULE 8, AUDIT: public.slack_event_posts opts OUT. A machine log of ids and Slack timestamps, written only by this feature,
--    no person edits it, nothing about a client lives in it. property_intakes and property_pages stay audited.
-- RLS: on by the event trigger; no policy on purpose, no app reads it.
-- ATOMIC: one transaction, no statement after COMMIT. CREATE TRIGGER and ALTER ... DISABLE TRIGGER take SHARE ROW EXCLUSIVE
--    on the two tables, which blocks writes, never reads; the whole file runs in about 2 seconds.
-- DEPLOY ORDER: the edge function FIRST (config.toml block verify_jwt = true, deploy, read the body back with
--    scripts/probes/edge_deployed_body.js), then this file. The other way round, real events call a 404 and post nothing.
-- ROLLBACK: 2026-11-05_0600_intake_slack_posts_rollback.sql
-- ponytail: no retry sweep. A lost post is listed in the health email and the form or version still shows in its app.
--    Add a sweep if intake_post_missing ever fires for real.
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $guard$
BEGIN
  IF md5(pg_get_functiondef('public.fn_notification_health_items(jsonb,timestamp with time zone)'::regprocedure))
     IS DISTINCT FROM '8acedc59f5879ad060d7957f3c18dff7' THEN
    RAISE EXCEPTION 'fn_notification_health_items changed since this file was written: splice again';
  END IF;
  IF to_regclass('public.slack_event_posts') IS NOT NULL THEN
    RAISE EXCEPTION 'public.slack_event_posts already exists';
  END IF;
END $guard$;

-- The old body, kept for this transaction: the control that must fail.
CREATE TEMP TABLE slack_old_def ON COMMIT DROP AS
  SELECT pg_get_functiondef('public.fn_notification_health_items(jsonb,timestamp with time zone)'::regprocedure) AS d;

-- ---------------------------------------------------------------- 1. the claim table
CREATE TABLE public.slack_event_posts (
  event_kind text NOT NULL CHECK (event_kind IN ('form_back', 'version_waiting')),
  ref_id     bigint NOT NULL,                 -- property_intakes.id or property_pages.id, by event_kind
  claimed_at timestamptz NOT NULL DEFAULT now(),
  posted_at  timestamptz,                     -- NULL = no post went out: error says why, or the function died before it could
  message_ts text,                            -- Slack's id of the message
  error      text,
  PRIMARY KEY (event_kind, ref_id)
);
COMMENT ON TABLE public.slack_event_posts IS
  'One row per Slack post claimed by intake-slack-post (2026-11-05). The primary key is what makes it post once. Audit: opted out, see the migration header.';
REVOKE ALL ON public.slack_event_posts FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.slack_event_posts TO service_role;
GRANT UPDATE (posted_at, message_ts, error) ON public.slack_event_posts TO service_role;

INSERT INTO public.app_config (key, value) VALUES ('intake_slack_posts_since', now()::text)
  ON CONFLICT (key) DO UPDATE SET value = excluded.value;

-- ---------------------------------------------------------------- 2. the request
CREATE FUNCTION public.trg_slack_event_request()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_key text;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'edge_invoke_service_key';
  if v_key is null then
    raise warning 'edge_invoke_service_key vault secret missing; no Slack post for % %', tg_argv[0], new.id;
    return null;
  end if;
  perform net.http_post(
    url := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/intake-slack-post',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
    body := jsonb_build_object('kind', tg_argv[0], 'id', new.id),
    timeout_milliseconds := 30000);
  return null;
exception when others then
  raise warning 'Slack post request failed for % % (% %); the form or version is saved, the health email lists the missing post',
    tg_argv[0], new.id, sqlstate, sqlerrm;
  return null;
end $function$;
REVOKE ALL ON FUNCTION public.trg_slack_event_request() FROM PUBLIC, anon, authenticated, service_role;

-- One row, once ever: intake-submit's compare-and-set can only win once, and fn_property_intake_immutable refuses a change
-- to submitted_at afterwards. A second tap updates 0 rows, so no trigger.
CREATE TRIGGER zz_slack_form_back AFTER UPDATE OF submitted_at ON public.property_intakes
  FOR EACH ROW WHEN (old.submitted_at IS NULL AND new.submitted_at IS NOT NULL)
  EXECUTE FUNCTION public.trg_slack_event_request('form_back');
-- Append-only, UNIQUE (property_id, version), and fn_property_pages_append_only refuses an INSERT already approved or
-- rejected, so every new row IS a version waiting.
CREATE TRIGGER zz_slack_version_waiting AFTER INSERT ON public.property_pages
  FOR EACH ROW EXECUTE FUNCTION public.trg_slack_event_request('version_waiting');

-- ---------------------------------------------------------------- 3. the facts and the claim
CREATE FUNCTION public.fn_slack_event_claim(p_kind text, p_id bigint, p_post_test boolean DEFAULT false, p_dry_run boolean DEFAULT false)
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
end $function$;
REVOKE ALL ON FUNCTION public.fn_slack_event_claim(text, bigint, boolean, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_slack_event_claim(text, bigint, boolean, boolean) TO service_role;

-- ---------------------------------------------------------------- 4. the health item, one anchored edit on the live body
DO $splice$
DECLARE
  v_old text := (SELECT d FROM slack_old_def);
  v_anchor text := $a$x.sent_at > p_as_of - interval '7 days' AND x.sent_at < p_as_of - interval '15 minutes'$a$;
  v_item text := $i$
    UNION ALL
    -- intake_post_missing (2026-11-05): a form back or a Site file version waiting whose Slack post did not go out, from 15
    -- minutes after the event, for 7 days. Only the alert is missing: the form or the version is saved and shows in its app.
    SELECT jsonb_build_object(
             'kind', 'intake_post_missing:' || y.event_kind || '-' || y.ref_id, 'issue', 'intake_post_missing',
             'client_code', cl.client_code, 'property', y.property_id,
             'reason', CASE y.event_kind WHEN 'form_back' THEN 'The intake form' ELSE 'The Site file version' END
                       || ' for ' || coalesce(cl.client_code, 'no client') || ' came in '
                       || to_char(y.event_at AT TIME ZONE 'America/New_York', 'Mon FMDD FMHH12:MI AM') || ' ET and its Slack post did not go out'
                       || coalesce(': ' || left(sp.error, 200), '') || '.',
             'what_to_do', 'Nothing is lost, but nobody was told. Open it in the Picture Planner (Forms, or Page Builder, Waiting) and tell the office. '
                           || 'Then read the logs of the edge function intake-slack-post.')
      FROM (SELECT 'form_back'::text AS event_kind, i.id AS ref_id, i.property_id, i.submitted_at AS event_at
              FROM public.property_intakes i
             WHERE i.submitted_at IS NOT NULL AND i.cancelled_at IS NULL
            UNION ALL
            SELECT 'version_waiting', pg.id, pg.property_id, pg.submitted_at
              FROM public.property_pages pg
             WHERE pg.approved_at IS NULL AND pg.rejected_at IS NULL) y
      JOIN public.properties pr ON pr.id = y.property_id
      LEFT JOIN public.clients cl ON cl.id = pr.client_id
      LEFT JOIN public.slack_event_posts sp ON sp.event_kind = y.event_kind AND sp.ref_id = y.ref_id
     WHERE sp.posted_at IS NULL
       AND NOT coalesce(public.fn_is_non_customer(pr.client_id, ARRAY['test', 'fixture']), false)
       AND y.event_at >= coalesce((SELECT nullif(btrim(value), '')::timestamptz FROM public.app_config WHERE key = 'intake_slack_posts_since'),
                                  'infinity'::timestamptz)
       AND y.event_at > p_as_of - interval '7 days' AND y.event_at < p_as_of - interval '15 minutes'$i$;
BEGIN
  IF position(chr(13) IN v_item) > 0 THEN RAISE EXCEPTION 'this file has CRLF line endings: restore LF before applying'; END IF;
  IF (length(v_old) - length(replace(v_old, v_anchor, ''))) / length(v_anchor) <> 1 THEN
    RAISE EXCEPTION 'the anchor must occur exactly once';
  END IF;
  EXECUTE replace(v_old, v_anchor, v_anchor || v_item);
  -- nothing else moved: taking the item out gives back the old body, byte for byte
  IF replace(pg_get_functiondef('public.fn_notification_health_items(jsonb,timestamp with time zone)'::regprocedure), v_item, '') IS DISTINCT FROM v_old THEN
    RAISE EXCEPTION 'verify_fail: the splice moved something else';
  END IF;
  EXECUTE replace(v_old, 'public.fn_notification_health_items', 'pg_temp.slack_items_before');
END $splice$;

-- ---------------------------------------------------------------- VERIFY: every write below is undone by the sentinel
DO $verify$
DECLARE
  c_plant constant text := 'PLANTED-7391';
  c_form  constant text[] := ARRAY['kind','ref_id','client_code','client_name','address','city','who','status','answered','of','photos','test'];
  c_page  constant text[] := ARRAY['kind','ref_id','client_code','client_name','address','city','property_id','version','who','restored_from','live_version','test'];
  v_test_prop bigint; v_real_prop bigint;
  v_ids bigint[]; v_i1 bigint; v_i2 bigint; v_i3 bigint; v_i4 bigint;
  v_page bigint; v_real_page bigint; v_real_form bigint;
  v_n bigint; v_facts jsonb; v_outcome text; v_tdef text; v_items text; v_boom text; v_token text;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"role":"service_role"}', true);   -- what the edge function runs under

  -- grants, read from the catalogue after the fact (a GRANT cannot remove what CREATE TABLE already handed out)
  IF has_table_privilege('anon', 'public.slack_event_posts', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN')
     OR has_table_privilege('authenticated', 'public.slack_event_posts', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN') THEN
    RAISE EXCEPTION 'verify_fail: anon or authenticated holds something on slack_event_posts';
  END IF;
  IF NOT has_table_privilege('service_role', 'public.slack_event_posts', 'SELECT') THEN
    RAISE EXCEPTION 'verify_fail: control: service_role cannot read slack_event_posts';
  END IF;
  IF has_function_privilege('anon', 'public.fn_slack_event_claim(text,bigint,boolean,boolean)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.fn_slack_event_claim(text,bigint,boolean,boolean)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.fn_slack_event_claim(text,bigint,boolean,boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'verify_fail: fn_slack_event_claim is callable by the wrong role';
  END IF;

  BEGIN
    SELECT min(p.id) INTO v_test_prop FROM public.properties p JOIN public.clients c ON c.id = p.client_id
     WHERE c.client_code = '112-YA' AND p.deleted_at IS NULL AND NOT coalesce(p.is_billing, false);
    SELECT p.id INTO v_real_prop FROM public.properties p
     WHERE p.deleted_at IS NULL AND NOT coalesce(p.is_billing, false) AND p.client_id IS NOT NULL
       AND NOT coalesce(public.fn_is_non_customer(p.client_id, ARRAY['test', 'fixture']), false)
     ORDER BY p.id LIMIT 1;
    IF v_test_prop IS NULL OR v_real_prop IS NULL THEN RAISE EXCEPTION 'verify_fail: no fixture property'; END IF;

    -- four waiting forms on 112-YA, the way the Client App makes them
    WITH s AS (SELECT public.fn_intake_form_current() AS f),
         made AS (INSERT INTO public.property_intakes (property_id, form_snapshot, requested, requested_by)
                  SELECT v_test_prop, s.f,
                         to_jsonb(public.fn_intake_normalise_requested(s.f, (SELECT array_agg(question_key) FROM client.v_intake_questions))),
                         '[TEST] verify'
                    FROM s, generate_series(1, 4)
                  RETURNING id)
    SELECT array_agg(id ORDER BY id) INTO STRICT v_ids FROM made;
    v_i1 := v_ids[1]; v_i2 := v_ids[2]; v_i3 := v_ids[3]; v_i4 := v_ids[4];

    -- A. nothing is queued while a form waits
    SELECT count(*) INTO v_n FROM net.http_request_queue q
     WHERE q.url LIKE '%/functions/v1/intake-slack-post%' AND convert_from(q.body, 'UTF8')::jsonb -> 'id' = to_jsonb(v_i1);
    IF v_n <> 0 THEN RAISE EXCEPTION 'verify_fail: A queued before submit (%)', v_n; END IF;

    -- B. the submit, exactly intake-submit's update: one call queued, carrying only the kind and the id
    UPDATE public.property_intakes
       SET answers = jsonb_build_object('access.lock_box_code', jsonb_build_object('value', c_plant)), collector = 'Verify collector', submitted_at = now()
     WHERE id = v_i1 AND submitted_at IS NULL;
    SELECT count(*) INTO v_n FROM net.http_request_queue q
     WHERE q.url LIKE '%/functions/v1/intake-slack-post%'
       AND convert_from(q.body, 'UTF8')::jsonb = jsonb_build_object('kind', 'form_back', 'id', v_i1);
    IF v_n <> 1 THEN RAISE EXCEPTION 'verify_fail: B one submit queued % calls', v_n; END IF;

    -- C. a second tap updates 0 rows and queues nothing; a change to submitted_at is refused
    UPDATE public.property_intakes SET collector = 'Second tap', submitted_at = now() WHERE id = v_i1 AND submitted_at IS NULL;
    SELECT count(*) INTO v_n FROM net.http_request_queue q
     WHERE q.url LIKE '%/functions/v1/intake-slack-post%' AND convert_from(q.body, 'UTF8')::jsonb -> 'id' = to_jsonb(v_i1);
    IF v_n <> 1 THEN RAISE EXCEPTION 'verify_fail: C a second tap queued again (%)', v_n; END IF;
    BEGIN
      UPDATE public.property_intakes SET submitted_at = now() + interval '1 minute' WHERE id = v_i1;
      RAISE EXCEPTION 'verify_fail: C submitted_at changed';
    EXCEPTION WHEN invalid_parameter_value THEN NULL; END;

    -- D. the control that must fail: with the trigger off (the state before this file) assertion B reads 0
    ALTER TABLE public.property_intakes DISABLE TRIGGER zz_slack_form_back;
    UPDATE public.property_intakes SET answers = '{}'::jsonb, collector = 'Control', submitted_at = now() WHERE id = v_i2 AND submitted_at IS NULL;
    SELECT count(*) INTO v_n FROM net.http_request_queue q
     WHERE q.url LIKE '%/functions/v1/intake-slack-post%' AND convert_from(q.body, 'UTF8')::jsonb -> 'id' = to_jsonb(v_i2);
    IF v_n <> 0 THEN RAISE EXCEPTION 'verify_fail: D the control queued a call, so B proved nothing'; END IF;
    ALTER TABLE public.property_intakes ENABLE TRIGGER zz_slack_form_back;

    -- E. the claim, as the edge function calls it. A test client: skipped, no row.
    SET LOCAL ROLE service_role;
    v_facts := public.fn_slack_event_claim('form_back', v_i1);
    RESET ROLE;
    IF v_facts ->> 'skip' IS DISTINCT FROM 'test_client' THEN RAISE EXCEPTION 'verify_fail: E test client not skipped: %', v_facts; END IF;
    SELECT count(*) INTO v_n FROM public.slack_event_posts WHERE event_kind = 'form_back' AND ref_id = v_i1;
    IF v_n <> 0 THEN RAISE EXCEPTION 'verify_fail: E a skip left a row'; END IF;

    -- F. asked for by the server key: the facts, marked test, named keys only, no planted value, no link code
    SET LOCAL ROLE service_role;
    v_facts := public.fn_slack_event_claim('form_back', v_i1, true);
    RESET ROLE;
    IF (v_facts ->> 'test') IS DISTINCT FROM 'true' OR v_facts ->> 'who' IS DISTINCT FROM 'Verify collector' OR v_facts ->> 'status' IS NULL THEN
      RAISE EXCEPTION 'verify_fail: F facts wrong: %', v_facts;
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_object_keys(v_facts) k WHERE k <> ALL (c_form)) THEN RAISE EXCEPTION 'verify_fail: F an unnamed key'; END IF;
    SELECT token INTO v_token FROM public.property_intakes WHERE id = v_i1;
    IF position(c_plant IN v_facts::text) > 0 OR position(v_token IN v_facts::text) > 0 THEN RAISE EXCEPTION 'verify_fail: F a code reached the facts'; END IF;

    -- G. a repeat delivery posts nothing; the function may write the result and nothing else
    SET LOCAL ROLE service_role;
    v_facts := public.fn_slack_event_claim('form_back', v_i1, true);
    UPDATE public.slack_event_posts SET posted_at = now(), message_ts = '1.2' WHERE event_kind = 'form_back' AND ref_id = v_i1;
    v_outcome := 'allowed';
    BEGIN
      UPDATE public.slack_event_posts SET ref_id = 0 WHERE event_kind = 'form_back' AND ref_id = v_i1;
    EXCEPTION WHEN insufficient_privilege THEN v_outcome := 'refused'; END;
    RESET ROLE;
    IF v_facts ->> 'skip' IS DISTINCT FROM 'already_claimed' THEN RAISE EXCEPTION 'verify_fail: G claimed twice'; END IF;
    IF v_outcome <> 'refused' THEN RAISE EXCEPTION 'verify_fail: G service_role moved ref_id'; END IF;

    -- H. a version: one call, named keys only, no planted value in content or source
    INSERT INTO public.property_pages (property_id, version, content, source, submitted_by, submitted_by_email)
    SELECT v_test_prop, coalesce(max(version), 0) + 1, jsonb_build_object('photos', '[]'::jsonb, 'lock_box', c_plant),
           jsonb_build_object('lock_box_key', c_plant), gen_random_uuid(), 'fred@ayache.com'
      FROM public.property_pages WHERE property_id = v_test_prop
    RETURNING id INTO v_page;
    SELECT count(*) INTO v_n FROM net.http_request_queue q
     WHERE q.url LIKE '%/functions/v1/intake-slack-post%'
       AND convert_from(q.body, 'UTF8')::jsonb = jsonb_build_object('kind', 'version_waiting', 'id', v_page);
    IF v_n <> 1 THEN RAISE EXCEPTION 'verify_fail: H one version queued % calls', v_n; END IF;
    SET LOCAL ROLE service_role;
    v_facts := public.fn_slack_event_claim('version_waiting', v_page, true);
    RESET ROLE;
    IF v_facts ->> 'who' IS DISTINCT FROM 'Fred' OR (v_facts ->> 'property_id')::bigint IS DISTINCT FROM v_test_prop OR v_facts ->> 'version' IS NULL THEN
      RAISE EXCEPTION 'verify_fail: H facts wrong: %', v_facts;
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_object_keys(v_facts) k WHERE k <> ALL (c_page)) THEN RAISE EXCEPTION 'verify_fail: H an unnamed key'; END IF;
    IF position(c_plant IN v_facts::text) > 0 THEN RAISE EXCEPTION 'verify_fail: H a code reached the facts'; END IF;

    -- I. 🛑 a failure inside the trigger never fails the submit, and the same body without its handler does (the control)
    v_tdef := pg_get_functiondef('public.trg_slack_event_request()'::regprocedure);
    v_boom := replace(v_tdef, 'perform net.http_post(', 'raise exception ''verify_boom''; perform net.http_post(');
    IF v_boom = v_tdef THEN RAISE EXCEPTION 'verify_fail: I the failure was not injected'; END IF;
    EXECUTE v_boom;
    UPDATE public.property_intakes SET answers = '{}'::jsonb, collector = 'Boom', submitted_at = now() WHERE id = v_i3 AND submitted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'verify_fail: I the submit did not land'; END IF;
    EXECUTE regexp_replace(v_boom, 'exception when others then.*?return null;', '');
    v_outcome := 'saved';
    BEGIN
      UPDATE public.property_intakes SET answers = '{}'::jsonb, collector = 'Boom', submitted_at = now() WHERE id = v_i4 AND submitted_at IS NULL;
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'verify_boom' THEN RAISE; END IF;
      v_outcome := 'aborted';
    END;
    IF v_outcome <> 'aborted' THEN RAISE EXCEPTION 'verify_fail: I the control without the handler did not fail, so the proof is empty'; END IF;
    EXECUTE v_tdef;

    -- J. the health item: a real client's version with no post is listed; the OLD body does not list it (the control that must
    --    fail); posted: gone; refused by Slack: listed with the reason; a test client: never
    INSERT INTO public.property_pages (property_id, version, content, source, submitted_by, submitted_by_email)
    SELECT v_real_prop, coalesce(max(version), 0) + 1, '{"photos":[]}'::jsonb, '{}'::jsonb, gen_random_uuid(), 'verify@example.invalid'
      FROM public.property_pages WHERE property_id = v_real_prop
    RETURNING id INTO v_real_page;
    WITH s AS (SELECT public.fn_intake_form_current() AS f)
    INSERT INTO public.property_intakes (property_id, form_snapshot, requested, requested_by)
    SELECT v_real_prop, s.f, to_jsonb(public.fn_intake_normalise_requested(s.f, (SELECT array_agg(question_key) FROM client.v_intake_questions))), '[TEST] verify'
      FROM s
    RETURNING id INTO v_real_form;
    UPDATE public.property_intakes SET answers = '{}'::jsonb, collector = 'Verify collector', submitted_at = now() WHERE id = v_real_form AND submitted_at IS NULL;
    v_items := public.fn_notification_health_items('[]'::jsonb, now() + interval '1 hour')::text;
    IF position('intake_post_missing:version_waiting-' || v_real_page || '"' IN v_items) = 0 THEN RAISE EXCEPTION 'verify_fail: J not listed'; END IF;
    IF position('intake_post_missing:form_back-' || v_real_form || '"' IN v_items) = 0 THEN RAISE EXCEPTION 'verify_fail: J the form arm not listed'; END IF;
    IF position('intake_post_missing:version_waiting-' || v_page || '"' IN v_items) > 0 THEN RAISE EXCEPTION 'verify_fail: J a test client listed'; END IF;
    IF position('intake_post_missing' IN pg_temp.slack_items_before('[]'::jsonb, now() + interval '1 hour')::text) > 0 THEN
      RAISE EXCEPTION 'verify_fail: J the old body listed it, so the control proves nothing';
    END IF;
    IF position('intake_post_missing:version_waiting-' || v_real_page || '"' IN public.fn_notification_health_items('[]'::jsonb, now())::text) > 0 THEN
      RAISE EXCEPTION 'verify_fail: J listed before 15 minutes';
    END IF;
    PERFORM public.fn_slack_event_claim('version_waiting', v_real_page);
    UPDATE public.slack_event_posts SET error = 'Slack: channel_not_found' WHERE event_kind = 'version_waiting' AND ref_id = v_real_page;
    IF position('channel_not_found' IN public.fn_notification_health_items('[]'::jsonb, now() + interval '1 hour')::text) = 0 THEN
      RAISE EXCEPTION 'verify_fail: J the refusal reason is not in the item';
    END IF;
    UPDATE public.slack_event_posts SET posted_at = now(), error = NULL WHERE event_kind = 'version_waiting' AND ref_id = v_real_page;
    PERFORM public.fn_slack_event_claim('form_back', v_real_form);
    UPDATE public.slack_event_posts SET posted_at = now() WHERE event_kind = 'form_back' AND ref_id = v_real_form;
    IF position('intake_post_missing:form_back-' || v_real_form || '"' IN public.fn_notification_health_items('[]'::jsonb, now() + interval '1 hour')::text) > 0 THEN
      RAISE EXCEPTION 'verify_fail: J the form still listed after the post';
    END IF;
    IF position('intake_post_missing:version_waiting-' || v_real_page || '"' IN public.fn_notification_health_items('[]'::jsonb, now() + interval '1 hour')::text) > 0 THEN
      RAISE EXCEPTION 'verify_fail: J still listed after the post';
    END IF;

    RAISE EXCEPTION 'verify_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'verify_undo' THEN RAISE; END IF;
  END;
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);

  -- the sentinel left nothing: no row, no queued call
  IF EXISTS (SELECT 1 FROM public.slack_event_posts) THEN RAISE EXCEPTION 'verify_fail: rows left in slack_event_posts'; END IF;
  IF EXISTS (SELECT 1 FROM net.http_request_queue q WHERE q.url LIKE '%/functions/v1/intake-slack-post%') THEN
    RAISE EXCEPTION 'verify_fail: a queued call survived the rollback';
  END IF;
END $verify$;

NOTIFY pgrst, 'reload schema';
COMMIT;
