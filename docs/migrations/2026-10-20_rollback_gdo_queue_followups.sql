-- ROLLBACK of 2026-10-20_1405_gdo_queue_followups.sql: the three bodies as live after 2026-10-20_1345 and before _1405.
-- Run it BEFORE 2026-10-20_rollback_gdo_queue_no_permit_hold.sql.
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $g$ BEGIN
  IF md5(rtrim(regexp_replace(pg_get_viewdef('public.v_rpa_derm_health'::regclass, true), '^[[:space:]]+|[[:space:]]+$', '', 'g'), ';')) <> '60bec0755488bcbfa039ec1177356239' THEN RAISE EXCEPTION 'rollback guard: v_rpa_derm_health is not the _1405 body'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('public.log_rpa_derm_health()'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> '42db8a5a90c2c19eb7c8be4de6bec420' THEN RAISE EXCEPTION 'rollback guard: log_rpa_derm_health is not the _1405 body'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('public.fn_requeue_derm_portal(bigint,bigint,text,text)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> 'a3fabe39866827df65453daa967b0f8c' THEN RAISE EXCEPTION 'rollback guard: fn_requeue_derm_portal is not the _1405 body'; END IF;
END $g$;
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
                  WHERE NOT s.dry_run AND s.gdo_id IS NOT NULL
                  GROUP BY s.visit_id, s.gdo_id
                 HAVING count(*) >= 3 AND count(*) FILTER (WHERE s.status = 'SUCCESS'::text) = 0 AND NOT (EXISTS ( SELECT 1
                           FROM derm_portal_submissions s2
                          WHERE s2.visit_id = s.visit_id AND NOT s2.dry_run AND (s2.status = 'SUCCESS'::text OR s2.portal_confirmation IS NOT NULL) AND (s.gdo_id IS NULL OR s2.gdo_id IS NULL OR s2.gdo_id = s.gdo_id)))) q) AS visits_ge3_attempts,
    ( SELECT count(*) AS count
           FROM v_gdo_reporting_derm_mismatch) AS gdo_not_derm_required,
    ( SELECT count(*) AS count
           FROM v_rpa_derm_stale_leases) AS stale_leases,
    NULL::bigint AS held_no_sheet;
CREATE OR REPLACE FUNCTION public.log_rpa_derm_health()
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
declare h record; reasons jsonb := '[]'::jsonb; attn boolean := false; np jsonb; nc jsonb;
begin
  select * into h from public.v_rpa_derm_health;
  if h.queue_depth > 0 and (h.last_real_attempt is null or h.last_real_attempt < now() - interval '26 hours') then
    attn := true; reasons := reasons || jsonb_build_object('kind','no_recent_attempts','queue_depth',h.queue_depth,'last_real_attempt',h.last_real_attempt);
  end if;
  if h.store_failed_total > 0 then attn := true; reasons := reasons || jsonb_build_object('kind','evidence_lost_store_failed','count',h.store_failed_total); end if;
  if h.visits_ge3_attempts > 0 then attn := true; reasons := reasons || jsonb_build_object('kind','retry_loop_visits','count',h.visits_ge3_attempts); end if;
  if h.gdo_not_derm_required > 0 then attn := true; reasons := reasons || jsonb_build_object('kind','gdo_code27_not_derm_required','count',h.gdo_not_derm_required); end if;
  if h.stale_leases > 0 then attn := true; reasons := reasons || jsonb_build_object('kind','rpa_lease_no_result','count',h.stale_leases); end if;
  -- 2026-10-20: a GDO-reporting visit whose client has no ACTIVE permit is never served (v_derm_portal_queue
  -- skips gdo_id IS NULL). One item per visit, keyed on visit_id by ops.v_health_items, emailed the day it appears.
  select coalesce(jsonb_agg(jsonb_build_object('kind','gdo_no_permit','visit_id',q.visit_id,'client_code',q.client_code,
           'visit_date',q.visit_date,'manifest_id',q.manifest_id,
           'reason','no ACTIVE GDO permit on file for this client, so its DERM online report cannot be filed',
           'what_to_do','Diego or Yan: confirm the client''s own GDO permit (the county PDF issued to this business at this address) and enter it with its PDF in the Client App; the visit then files by itself on the next bot pass, even if late. Never enter a permit found at the address under another business. If the client has no permit, decide whether it is still billed 27 - GDO Online Reporting.')
         order by q.visit_id), '[]'::jsonb)
    into np
    from public.v_derm_portal_queue_held q
   where q.held_by = 'no_permit'
     and not exists (select 1 from public.derm_portal_submissions s
                      where s.visit_id = q.visit_id and not s.dry_run
                        and (s.status = 'SUCCESS' or s.portal_confirmation is not null));
  if jsonb_array_length(np) > 0 then attn := true; reasons := reasons || np; end if;
  -- Upstream of the visits: an open job billing 27 - GDO Online Reporting for a client with no ACTIVE permit
  -- (Yan, 2026-09-04: the list of locations with online reporting and no GDO permit). Keyed on client_code.
  select coalesce(jsonb_agg(jsonb_build_object('client_code',x.client_code,'client',x.name,'jobs',x.jobs,
           'issue','an open job bills 27 - GDO Online Reporting but the client has no ACTIVE GDO permit',
           'what_to_do','Diego or Yan: get the client''s own GDO permit (county PDF) and enter it in the Client App before its next visit, or take line 27 off the job if the client has no permit.')
         order by x.client_code), '[]'::jsonb)
    into nc
    from (select c.client_code, c.name, jsonb_agg(distinct j.job_number) as jobs
            from public.jobs j
            join public.clients c on c.id = j.client_id
            join public.line_items li on li.job_id = j.id and li.visit_id is null
           where public.fn_line_item_is_gdo_reporting(li.name)
             and j.job_status not in ('archived','destroyed')
             and c.client_code is not null
             and not exists (select 1 from public.v_non_customer_clients n where n.client_id = c.id)
             and not exists (select 1 from public.gdos g
                              where g.client_id = c.id and g.status = 'ACTIVE' and g.gdo_number ~ '^GDO-[0-9]+$')
           group by c.client_code, c.name) x;
  if jsonb_array_length(nc) > 0 then attn := true; reasons := reasons || nc; end if;
  insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
  values ('rpa-derm-health', now(), now(), coalesce(h.queue_depth,0),
          case when attn then 'attention' else 'ok' end,
          jsonb_build_object('queue_depth',h.queue_depth,'last_real_attempt',h.last_real_attempt,
                             'success_24h',h.success_24h,'store_failed_total',h.store_failed_total,
                             'visits_ge3_attempts',h.visits_ge3_attempts,
                             'gdo_not_derm_required',h.gdo_not_derm_required,
                             'stale_leases',h.stale_leases,'held_no_permit',jsonb_array_length(np),'line27_no_permit_clients',jsonb_array_length(nc),'reasons',reasons));
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
       AND NOT s.gdo_id IS DISTINCT FROM p_gdo_id
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
                    WHERE lmv.manifest_id = v_manifest_id AND (l.gdo_id IS NULL OR NOT l.gdo_id IS DISTINCT FROM p_gdo_id)
                      AND l.leased_at > now() - interval '20 hours')
        THEN 'gate 4: this permit is under a dispense lease - the bot already holds it'
      WHEN EXISTS (SELECT 1 FROM public.v_derm_portal_queue qq2
                    WHERE qq2.manifest_id = v_manifest_id)
        THEN 'no gate is blocking it: the queue serves at most 25 rows per pass, oldest first, and this one did not make the cut. It will come up on a later pass, and the requeue is recorded.'
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
NOTIFY pgrst, 'reload schema';
COMMIT;
