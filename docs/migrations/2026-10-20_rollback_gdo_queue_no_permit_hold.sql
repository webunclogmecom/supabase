-- ROLLBACK of 2026-10-20_1345_gdo_queue_no_permit_hold.sql: the five bodies as they were live on 2026-10-20 before it,
-- dumped with pg_get_viewdef(oid, true) / pg_get_functiondef, plus the held view's old authenticated grant.
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $g$ BEGIN
  -- every object this file replaces, so a later change to any of them is never silently undone (post-check 2026-10-20)
  IF md5(rtrim(regexp_replace(pg_get_viewdef('public.v_derm_portal_queue'::regclass, true), '^[[:space:]]+|[[:space:]]+$', '', 'g'), ';')) <> '28987ab073fd690275ab06a20328633a' THEN RAISE EXCEPTION 'rollback guard: queue is not the _1345 body'; END IF;
  IF md5(rtrim(regexp_replace(pg_get_viewdef('public.v_derm_portal_queue_held'::regclass, true), '^[[:space:]]+|[[:space:]]+$', '', 'g'), ';')) <> '323384bb8ae56bc950ac7166f16e4d34' THEN RAISE EXCEPTION 'rollback guard: held view is not the _1345 body'; END IF;
  IF md5(rtrim(regexp_replace(pg_get_viewdef('public.v_rpa_derm_health'::regclass, true), '^[[:space:]]+|[[:space:]]+$', '', 'g'), ';')) <> '889bb6d73ef90575d880aeb2322eca48' THEN RAISE EXCEPTION 'rollback guard: v_rpa_derm_health is not the _1345 body (roll _1405 back first)'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('public.log_rpa_derm_health()'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> '3cfc3d9245dcd72ff32e074005c2de56' THEN RAISE EXCEPTION 'rollback guard: log_rpa_derm_health is not the _1345 body (roll _1405 back first)'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('public.fn_requeue_derm_portal(bigint,bigint,text,text)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> '0070dfd63b093cad7d7572cd3fab00e7' THEN RAISE EXCEPTION 'rollback guard: fn_requeue_derm_portal is not the _1345 body (roll _1405 back first)'; END IF;
END $g$;
CREATE OR REPLACE VIEW public.v_derm_portal_queue AS
SELECT DISTINCT ON (manifest_id, gdo_id) visit_id,
    visit_date,
    client_id,
    client_code,
    client_name,
    client_email,
    address,
    city,
    zip,
    county,
    gdo_number,
    manifest_id,
    white_manifest_number,
    dump_ticket_date,
    disposal_facility,
    derm_address_url,
    derm_address_extra_urls,
    derm_manifest_url,
    derm_manifest_extra_urls,
    updated_at,
    linked_at,
    ticket_number,
    jurisdiction,
    gdo_id,
    NULL::text[] AS visit_sheet_urls
   FROM v_derm_portal_fields f
  WHERE visit_date >= rpa_launch_cutoff() AND NOT (EXISTS ( SELECT 1
           FROM derm_portal_submissions s
             JOIN manifest_visits smv ON smv.visit_id = s.visit_id
          WHERE smv.manifest_id = f.manifest_id AND NOT s.dry_run AND (s.gdo_id IS NULL OR NOT s.gdo_id IS DISTINCT FROM f.gdo_id) AND (s.status = 'SUCCESS'::text OR s.portal_confirmation IS NOT NULL))) AND NOT (EXISTS ( SELECT 1
           FROM derm_portal_submissions s
             JOIN manifest_visits smv ON smv.visit_id = s.visit_id
          WHERE smv.manifest_id = f.manifest_id AND NOT s.dry_run AND (s.gdo_id IS NULL OR NOT s.gdo_id IS DISTINCT FROM f.gdo_id) AND s.created_at > (now() - '20:00:00'::interval))) AND NOT (EXISTS ( SELECT 1
           FROM derm_portal_submissions s
             JOIN manifest_visits smv ON smv.visit_id = s.visit_id
          WHERE smv.manifest_id = f.manifest_id AND NOT s.dry_run AND (s.gdo_id IS NULL OR NOT s.gdo_id IS DISTINCT FROM f.gdo_id) AND NOT s.retryable AND s.status <> 'SUCCESS'::text AND s.created_at > GREATEST(f.updated_at, COALESCE(( SELECT max(rq.requeued_at) AS max
                   FROM derm_portal_requeue rq
                  WHERE rq.manifest_id = f.manifest_id AND (rq.gdo_id IS NULL OR NOT rq.gdo_id IS DISTINCT FROM f.gdo_id)), '-infinity'::timestamp with time zone)))) AND NOT (EXISTS ( SELECT 1
           FROM derm_portal_leases l
             JOIN manifest_visits lmv ON lmv.visit_id = l.visit_id
          WHERE lmv.manifest_id = f.manifest_id AND (l.gdo_id IS NULL OR NOT l.gdo_id IS DISTINCT FROM f.gdo_id) AND l.leased_at > (now() - '20:00:00'::interval)))
  ORDER BY manifest_id, gdo_id, (abs(visit_date - dump_ticket_date)), visit_id;
CREATE OR REPLACE VIEW public.v_derm_portal_queue_held AS
SELECT visit_id,
    gdo_id,
    gdo_number,
    manifest_id,
    client_code,
    visit_date,
        CASE
            WHEN NOT visit_date >= rpa_launch_cutoff() THEN 'before_launch_cutoff'::text
            WHEN (EXISTS ( SELECT 1
               FROM derm_portal_submissions s
                 JOIN manifest_visits smv ON smv.visit_id = s.visit_id
              WHERE smv.manifest_id = f.manifest_id AND NOT s.dry_run AND (s.gdo_id IS NULL OR NOT s.gdo_id IS DISTINCT FROM f.gdo_id) AND (s.status = 'SUCCESS'::text OR s.portal_confirmation IS NOT NULL))) THEN 'already_filed'::text
            WHEN (EXISTS ( SELECT 1
               FROM derm_portal_submissions s
                 JOIN manifest_visits smv ON smv.visit_id = s.visit_id
              WHERE smv.manifest_id = f.manifest_id AND NOT s.dry_run AND (s.gdo_id IS NULL OR NOT s.gdo_id IS DISTINCT FROM f.gdo_id) AND s.created_at > (now() - '20:00:00'::interval))) THEN 'cooldown_20h'::text
            WHEN (EXISTS ( SELECT 1
               FROM derm_portal_submissions s
                 JOIN manifest_visits smv ON smv.visit_id = s.visit_id
              WHERE smv.manifest_id = f.manifest_id AND NOT s.dry_run AND (s.gdo_id IS NULL OR NOT s.gdo_id IS DISTINCT FROM f.gdo_id) AND NOT s.retryable AND s.status <> 'SUCCESS'::text AND s.created_at > GREATEST(f.updated_at, COALESCE(( SELECT max(rq.requeued_at) AS max
                       FROM derm_portal_requeue rq
                      WHERE rq.manifest_id = f.manifest_id AND (rq.gdo_id IS NULL OR NOT rq.gdo_id IS DISTINCT FROM f.gdo_id)), '-infinity'::timestamp with time zone)))) THEN 'data_error'::text
            WHEN (EXISTS ( SELECT 1
               FROM derm_portal_leases l
                 JOIN manifest_visits lmv ON lmv.visit_id = l.visit_id
              WHERE lmv.manifest_id = f.manifest_id AND l.leased_at > (now() - '20:00:00'::interval))) THEN 'leased'::text
            WHEN NOT (EXISTS ( SELECT 1
               FROM v_derm_portal_queue qq
              WHERE qq.visit_id = f.visit_id AND NOT qq.gdo_id IS DISTINCT FROM f.gdo_id)) THEN 'sibling_won_this_pass'::text
            ELSE NULL::text
        END AS held_by
   FROM v_derm_portal_fields f;
CREATE OR REPLACE VIEW public.v_rpa_derm_health AS
SELECT ( SELECT count(*) AS count
           FROM v_derm_portal_queue) AS queue_depth,
    ( SELECT max(s.created_at) AS max
           FROM derm_portal_submissions s
          WHERE NOT s.dry_run) AS last_real_attempt,
    ( SELECT count(*) AS count
           FROM derm_portal_submissions s
          WHERE NOT s.dry_run AND s.status = 'SUCCESS'::text AND s.created_at > (now() - '24:00:00'::interval)) AS success_24h,
    ( SELECT count(*) AS count
           FROM derm_portal_submissions s
          WHERE NOT s.dry_run AND s.screenshot_missing_reason = 'STORE_FAILED'::text) AS store_failed_total,
    ( SELECT count(*) AS count
           FROM ( SELECT s.visit_id,
                    s.gdo_id
                   FROM derm_portal_submissions s
                  WHERE NOT s.dry_run
                  GROUP BY s.visit_id, s.gdo_id
                 HAVING count(*) >= 3 AND count(*) FILTER (WHERE s.status = 'SUCCESS'::text) = 0) q) AS visits_ge3_attempts,
    ( SELECT count(*) AS count
           FROM v_gdo_reporting_derm_mismatch) AS gdo_not_derm_required,
    ( SELECT count(*) AS count
           FROM v_rpa_derm_stale_leases) AS stale_leases,
    NULL::bigint AS held_no_sheet;
CREATE OR REPLACE FUNCTION public.log_rpa_derm_health()
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
declare h record; reasons jsonb := '[]'::jsonb; attn boolean := false;
begin
  select * into h from public.v_rpa_derm_health;
  if h.queue_depth > 0 and (h.last_real_attempt is null or h.last_real_attempt < now() - interval '26 hours') then
    attn := true; reasons := reasons || jsonb_build_object('kind','no_recent_attempts','queue_depth',h.queue_depth,'last_real_attempt',h.last_real_attempt);
  end if;
  if h.store_failed_total > 0 then attn := true; reasons := reasons || jsonb_build_object('kind','evidence_lost_store_failed','count',h.store_failed_total); end if;
  if h.visits_ge3_attempts > 0 then attn := true; reasons := reasons || jsonb_build_object('kind','retry_loop_visits','count',h.visits_ge3_attempts); end if;
  if h.gdo_not_derm_required > 0 then attn := true; reasons := reasons || jsonb_build_object('kind','gdo_code27_not_derm_required','count',h.gdo_not_derm_required); end if;
  if h.stale_leases > 0 then attn := true; reasons := reasons || jsonb_build_object('kind','rpa_lease_no_result','count',h.stale_leases); end if;
  insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
  values ('rpa-derm-health', now(), now(), coalesce(h.queue_depth,0),
          case when attn then 'attention' else 'ok' end,
          jsonb_build_object('queue_depth',h.queue_depth,'last_real_attempt',h.last_real_attempt,
                             'success_24h',h.success_24h,'store_failed_total',h.store_failed_total,
                             'visits_ge3_attempts',h.visits_ge3_attempts,
                             'gdo_not_derm_required',h.gdo_not_derm_required,
                             'stale_leases',h.stale_leases,'reasons',reasons));
  return case when attn then 1 else 0 end;
end $function$;
CREATE OR REPLACE FUNCTION public.fn_requeue_derm_portal(p_visit_id bigint, p_gdo_id bigint, p_reason text, p_by text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_manifest_id bigint;
  v_n_manifests int;
  v_pair_exists boolean;
  v_blocked     boolean;
  v_queued      boolean;
  v_why         text;
  v_reason      text;
  v_jwt_email   text;
BEGIN
  -- (5) strip the whole whitespace class, not just ASCII space. E' ' is NBSP.
  v_reason := btrim(coalesce(p_reason,''), E' \t\r\n ');
  IF v_reason = '' THEN
    RAISE EXCEPTION 'fn_requeue_derm_portal: a reason is required - the next person to read this row has to know why somebody overrode the gate'
      USING ERRCODE = '22023';
  END IF;

  -- (2) a NULL permit is a MANIFEST-WIDE override. Refuse it here: it must never be
  -- reachable by omitting an argument. The table still supports NULL for a deliberate
  -- manifest-wide re-open.
  IF p_gdo_id IS NULL THEN
    RAISE EXCEPTION 'fn_requeue_derm_portal: p_gdo_id is required. A NULL permit re-opens gate 3 for EVERY permit on the manifest, which is a manifest-wide override and must be asked for explicitly, not reached by leaving an argument out.'
      USING ERRCODE = '22023';
  END IF;

  SELECT count(DISTINCT mv.manifest_id) INTO v_n_manifests
    FROM public.manifest_visits mv
    JOIN public.derm_manifests m ON m.id = mv.manifest_id AND m.deleted_at IS NULL
   WHERE mv.visit_id = p_visit_id;

  IF v_n_manifests = 0 THEN
    RAISE EXCEPTION 'fn_requeue_derm_portal: visit % has no live manifest link, so there is nothing for the portal queue to serve', p_visit_id
      USING ERRCODE = 'P0002';
  ELSIF v_n_manifests > 1 THEN
    RAISE EXCEPTION 'fn_requeue_derm_portal: visit % is linked to % live manifests, so which one to re-open is ambiguous. Requeue by manifest instead, or unlink the wrong one first.', p_visit_id, v_n_manifests
      USING ERRCODE = '21000';
  END IF;

  SELECT mv.manifest_id INTO v_manifest_id
    FROM public.manifest_visits mv
    JOIN public.derm_manifests m ON m.id = mv.manifest_id AND m.deleted_at IS NULL
   WHERE mv.visit_id = p_visit_id
   ORDER BY mv.manifest_id
   LIMIT 1;

  -- (1) Does this (visit, permit) pair exist AT ALL? Without this the sibling branch
  -- below tells a caller with a nonsense or wrong-client gdo_id that a sibling won and
  -- their row will come up later. It never will.
  SELECT EXISTS (SELECT 1 FROM public.v_derm_portal_fields f
                  WHERE f.visit_id = p_visit_id
                    AND NOT f.gdo_id IS DISTINCT FROM p_gdo_id)
    INTO v_pair_exists;

  -- (3) mirror the view's gate 3 EXACTLY, anchor clause included, or this answers a
  -- different question than the gate it is named after.
  SELECT EXISTS (
    SELECT 1 FROM public.derm_portal_submissions s
      JOIN public.manifest_visits smv ON smv.visit_id = s.visit_id
     WHERE smv.manifest_id = v_manifest_id AND NOT s.dry_run
       AND (s.gdo_id IS NULL OR NOT s.gdo_id IS DISTINCT FROM p_gdo_id)
       AND NOT s.retryable AND s.status <> 'SUCCESS'
       AND s.created_at > GREATEST(
             (SELECT f.updated_at FROM public.v_derm_portal_fields f
               WHERE f.visit_id = p_visit_id AND NOT f.gdo_id IS DISTINCT FROM p_gdo_id),
             COALESCE((SELECT max(rq.requeued_at) FROM public.derm_portal_requeue rq
                        WHERE rq.manifest_id = v_manifest_id
                          AND (rq.gdo_id IS NULL OR NOT rq.gdo_id IS DISTINCT FROM p_gdo_id)),
                      '-infinity'::timestamptz)))
  INTO v_blocked;

  INSERT INTO public.derm_portal_requeue (manifest_id, gdo_id, reason, requested_by)
  VALUES (v_manifest_id, p_gdo_id, v_reason,
          -- (4) the JWT wins; p_by is only a label for service-role callers with no claim.
          coalesce(current_setting('request.jwt.claims', true)::jsonb->>'email', p_by, session_user));

  SELECT EXISTS (SELECT 1 FROM public.v_derm_portal_queue qq
                  WHERE qq.visit_id = p_visit_id
                    AND NOT qq.gdo_id IS DISTINCT FROM p_gdo_id)
    INTO v_queued;

  IF NOT v_queued THEN
    SELECT CASE
      WHEN NOT v_pair_exists
        THEN 'this (visit, permit) pair does not appear in v_derm_portal_fields at all - check the gdo_id belongs to this visit''s client, and that the visit is on or after rpa_launch_cutoff(). The requeue row was still recorded.'
      WHEN EXISTS (SELECT 1 FROM public.derm_portal_submissions s
                     JOIN public.manifest_visits smv ON smv.visit_id = s.visit_id
                    WHERE smv.manifest_id = v_manifest_id AND NOT s.dry_run
                      AND (s.gdo_id IS NULL OR NOT s.gdo_id IS DISTINCT FROM p_gdo_id)
                      AND (s.status = 'SUCCESS' OR s.portal_confirmation IS NOT NULL))
        THEN 'gate 1: this permit has already filed successfully - nothing to retry'
      WHEN EXISTS (SELECT 1 FROM public.derm_portal_submissions s
                     JOIN public.manifest_visits smv ON smv.visit_id = s.visit_id
                    WHERE smv.manifest_id = v_manifest_id AND NOT s.dry_run
                      AND (s.gdo_id IS NULL OR NOT s.gdo_id IS DISTINCT FROM p_gdo_id)
                      AND s.created_at > now() - interval '20 hours')
        THEN 'gate 2: a 20h cooldown is running after the last attempt - it will serve once that expires'
      WHEN EXISTS (SELECT 1 FROM public.derm_portal_leases l
                     JOIN public.manifest_visits lmv ON lmv.visit_id = l.visit_id
                    WHERE lmv.manifest_id = v_manifest_id AND l.leased_at > now() - interval '20 hours')
        THEN 'gate 4: the manifest is under a dispense lease - the bot already holds it'
      WHEN EXISTS (SELECT 1 FROM public.v_derm_portal_queue qq2
                    WHERE qq2.manifest_id = v_manifest_id)
        THEN 'no gate is blocking it: the queue serves ONE permit per manifest per pass and a sibling permit won this one. It will come up on a later pass, and the requeue is recorded.'
      ELSE 'the pair exists and no gate 1/2/3/4 is blocking it, yet it is not served - re-read v_derm_portal_queue directly, this should not happen'
    END INTO v_why;
  END IF;

  RETURN jsonb_build_object(
    'manifest_id', v_manifest_id,
    'visit_id', p_visit_id,
    'gdo_id', p_gdo_id,
    'pair_exists', v_pair_exists,
    'was_blocked_by_gate3', v_blocked,
    'queued_now', v_queued,
    'still_blocked_by', v_why);
END $function$;
GRANT ALL ON public.v_derm_portal_queue_held TO authenticated;
NOTIFY pgrst, 'reload schema';
COMMIT;
