-- 2026-10-20_1345_gdo_queue_no_permit_hold.sql
--
-- Fred, 2026-10-20: "Do a full check, to make sure what you understand is correct and what you're trying to do is
-- correct as well. once that is done, design the plan and execute it." Follows the 2026-10-19 reading of the
-- GDO report bot (docs/reference/gdo-report-bot.md) and its Slack digest of 10-19: two "needs review" lines,
-- "No readable GDO permit in ''", for 315-CAP (visit 7849) and 249-LOU (visit 7859). 7860 (249-LOU) followed 10-20.
--
-- WHAT WAS WRONG (checked by five independent verifiers on 2026-10-20, read only):
-- 1. The queue served GDO-reporting visits whose client has no ACTIVE permit (v_derm_portal_fields.gdo_id NULL).
--    The bot can only refuse them. Gate 3 then held each refusal as data_error, but that hold lifts on ANY write to
--    the visit or manifest row: public.set_updated_at stamps updated_at on every UPDATE, even one that changes
--    nothing, and audit.log_change drops such UPDATEs, so the re-serves of 7849 on 09-03 and 10-06 have no audited
--    cause. Each re-serve was another refusal, another Slack alert and another "needs review" digest line
--    (7849 refused 5 times, 7859 4 times, 7860 once). Jonathan asked on 2026-09-03 for exactly this filter.
-- 2. Gate 3 matched a NULL-permit failure against EVERY permit of the manifest, so entering the missing permit did
--    not release the visit. On 2026-09-03 the two Skinny Louie visits filed only because an unrelated manifest
--    UPDATE moved the anchor.
-- 3. The health check's retry_loop_visits item (open since 2026-09-04, emailed 7 times) carried only a count, and a
--    (visit, NULL) group could never resolve once the visit was filed under a permit.
--
-- WHAT CHANGES (each body is the live body with anchored, exact-once edits; never retyped):
-- a. v_derm_portal_queue: `f.gdo_id IS NOT NULL` (the queue never serves a row with no permit); gate 3 is
--    exact-pair: `NOT s.gdo_id IS DISTINCT FROM f.gdo_id` (a failure holds only its own permit's row; a NULL-permit
--    failure holds only a NULL-permit row). Gates 1, 2 and 4 keep NULL matching: a NULL SUCCESS still retires every
--    permit, the 20h cooldown and the lease are unchanged.
--    => once a client's permit is entered (or reactivated), its held visits file on the next pass with no requeue,
--       EVEN IF LATE (a no-permit visit's DERM deadline, the 15th of the next month, can pass while it waits).
--       Fred, 2026-10-18, on Broward dumps: a Dade pickup "still owe[s] the DERM GDO report"; owed reports file.
--       Measured: this releases 0 rows today; 8095 (246-LOUI, permit 217, county login refused) stays held.
-- b. v_derm_portal_queue_held: new reason 'no_permit' right after 'already_filed' (same transaction as (a), or the
--    three rows would fall through to 'sibling_won_this_pass', which rpa-derm-queue counts as not held); gate 3
--    exact-pair; the 'leased' arm matches the permit like gate 4 does (it was manifest-wide).
-- c. v_rpa_derm_health.visits_ge3_attempts: a (visit, permit) group stops counting once the visit is filed for that
--    permit, or at all for a NULL group. Same column list.
-- d. log_rpa_derm_health(): one 'gdo_no_permit' item per held visit (keyed on visit_id by ops.v_health_items, so a
--    new one is emailed the day it appears, with the client and what to do), and one item per client whose open job
--    bills 27 - GDO Online Reporting with no ACTIVE permit (no 'kind', so the key is the client_code; Yan asked on
--    2026-09-04 for the list of locations with online reporting and no GDO permit). Today: 7849, 7859, 7860 and
--    249-LOU. details gains held_no_permit and line27_no_permit_clients.
-- e. fn_requeue_derm_portal: its gate-3 mirror follows (a); its gate-4 message is per permit; the stale "ONE permit
--    per manifest per pass" text (untrue since 2026-08-31) is replaced.
-- f. REVOKE anon/authenticated on v_derm_portal_queue_held (no app reads it; pg_stat_statements: only service_role
--    through rpa-derm-queue's held summary, and postgres). Its siblings already grant authenticated nothing.
--
-- NOT CHANGED: gate 3's "lifts on any write" (updated_at has many readers: a separate decision); v_derm_portal_fields;
-- the dryrun view; fn_record_manual_gdo_report and fn_resolve_rpa_permit (read the fields view only); every LWT
-- monthly object; the rpa-derm-queue edge fn (its held summary counts held_by generically, so 'no_permit' appears in
-- by_reason with no deploy). The bot (webunclogmecom/unclogme-gdo-report-bot) never reads `held`.
--
-- PEOPLE, NOT THIS MIGRATION: GDO-14738 for 249-LOU (county PDF in Slack since 2026-08-17; Fred 09-18: needs Diego or
-- Yan approval); Capas 315-CAP (no permit found; lead: GDO-14098, SIR FOOD LLC, same address, expired 2024-12-31;
-- Viktor's sentinel wrongly names GDO-09083, another business's permit); the $35 line-27 charges billed for reports
-- never filed.
--
-- Rule 8 (audit): no table is created or altered. Rehearsed in BEGIN ... ROLLBACK (forward, logger, health items,
-- requeue probe, rollback restores the live md5s). Rollback: 2026-10-20_rollback_gdo_queue_no_permit_hold.sql.

BEGIN;
SET LOCAL lock_timeout = '3s';
DO $g$ BEGIN
  IF md5(rtrim(regexp_replace(pg_get_viewdef('public.v_derm_portal_queue'::regclass, true), '^[[:space:]]+|[[:space:]]+$', '', 'g'), ';')) <> '85040a0430b2bea16639f49282007260' THEN RAISE EXCEPTION 'guard: v_derm_portal_queue changed since it was read'; END IF;
  IF md5(rtrim(regexp_replace(pg_get_viewdef('public.v_derm_portal_queue_held'::regclass, true), '^[[:space:]]+|[[:space:]]+$', '', 'g'), ';')) <> '5896c66645417370f43bc5b25ddf2c3c' THEN RAISE EXCEPTION 'guard: v_derm_portal_queue_held changed'; END IF;
  IF md5(rtrim(regexp_replace(pg_get_viewdef('public.v_rpa_derm_health'::regclass, true), '^[[:space:]]+|[[:space:]]+$', '', 'g'), ';')) <> '179f9acb9822f1426b79c93acb7f8a37' THEN RAISE EXCEPTION 'guard: v_rpa_derm_health changed'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('public.log_rpa_derm_health()'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> '2f08b2c60e5b48fbad7b03d7e756d8dd' THEN RAISE EXCEPTION 'guard: log_rpa_derm_health changed'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('public.fn_requeue_derm_portal(bigint,bigint,text,text)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> '89457e3c2ac79eb5b965fd1ff288ebbb' THEN RAISE EXCEPTION 'guard: fn_requeue_derm_portal changed'; END IF;
END $g$;
CREATE TEMP TABLE queue_before ON COMMIT DROP AS SELECT visit_id, gdo_id FROM public.v_derm_portal_queue;
CREATE TEMP TABLE held_before ON COMMIT DROP AS SELECT visit_id, gdo_id, held_by FROM public.v_derm_portal_queue_held;
CREATE TEMP TABLE acl_before ON COMMIT DROP AS
  SELECT c.oid::regclass::text AS obj, c.relacl::text AS acl FROM pg_class c
   WHERE c.oid IN ('public.v_derm_portal_queue'::regclass,'public.v_rpa_derm_health'::regclass)
  UNION ALL
  SELECT p.oid::regprocedure::text, p.proacl::text FROM pg_proc p
   WHERE p.oid IN ('public.log_rpa_derm_health()'::regprocedure,'public.fn_requeue_derm_portal(bigint,bigint,text,text)'::regprocedure);
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
  WHERE visit_date >= rpa_launch_cutoff() AND f.gdo_id IS NOT NULL AND NOT (EXISTS ( SELECT 1
           FROM derm_portal_submissions s
             JOIN manifest_visits smv ON smv.visit_id = s.visit_id
          WHERE smv.manifest_id = f.manifest_id AND NOT s.dry_run AND (s.gdo_id IS NULL OR NOT s.gdo_id IS DISTINCT FROM f.gdo_id) AND (s.status = 'SUCCESS'::text OR s.portal_confirmation IS NOT NULL))) AND NOT (EXISTS ( SELECT 1
           FROM derm_portal_submissions s
             JOIN manifest_visits smv ON smv.visit_id = s.visit_id
          WHERE smv.manifest_id = f.manifest_id AND NOT s.dry_run AND (s.gdo_id IS NULL OR NOT s.gdo_id IS DISTINCT FROM f.gdo_id) AND s.created_at > (now() - '20:00:00'::interval))) AND NOT (EXISTS ( SELECT 1
           FROM derm_portal_submissions s
             JOIN manifest_visits smv ON smv.visit_id = s.visit_id
          WHERE smv.manifest_id = f.manifest_id AND NOT s.dry_run AND NOT s.gdo_id IS DISTINCT FROM f.gdo_id AND NOT s.retryable AND s.status <> 'SUCCESS'::text AND s.created_at > GREATEST(f.updated_at, COALESCE(( SELECT max(rq.requeued_at) AS max
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
            WHEN f.gdo_id IS NULL THEN 'no_permit'::text
            WHEN (EXISTS ( SELECT 1
               FROM derm_portal_submissions s
                 JOIN manifest_visits smv ON smv.visit_id = s.visit_id
              WHERE smv.manifest_id = f.manifest_id AND NOT s.dry_run AND (s.gdo_id IS NULL OR NOT s.gdo_id IS DISTINCT FROM f.gdo_id) AND s.created_at > (now() - '20:00:00'::interval))) THEN 'cooldown_20h'::text
            WHEN (EXISTS ( SELECT 1
               FROM derm_portal_submissions s
                 JOIN manifest_visits smv ON smv.visit_id = s.visit_id
              WHERE smv.manifest_id = f.manifest_id AND NOT s.dry_run AND NOT s.gdo_id IS DISTINCT FROM f.gdo_id AND NOT s.retryable AND s.status <> 'SUCCESS'::text AND s.created_at > GREATEST(f.updated_at, COALESCE(( SELECT max(rq.requeued_at) AS max
                       FROM derm_portal_requeue rq
                      WHERE rq.manifest_id = f.manifest_id AND (rq.gdo_id IS NULL OR NOT rq.gdo_id IS DISTINCT FROM f.gdo_id)), '-infinity'::timestamp with time zone)))) THEN 'data_error'::text
            WHEN (EXISTS ( SELECT 1
               FROM derm_portal_leases l
                 JOIN manifest_visits lmv ON lmv.visit_id = l.visit_id
              WHERE lmv.manifest_id = f.manifest_id AND (l.gdo_id IS NULL OR NOT l.gdo_id IS DISTINCT FROM f.gdo_id) AND l.leased_at > (now() - '20:00:00'::interval))) THEN 'leased'::text
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
-- No app reads the held view (pg_stat_statements: service_role 598 calls, the rpa-derm-queue held summary; postgres).
-- Its siblings grant authenticated nothing; it held authenticated=arwdDxtm. Same ACL as the queue view now.
REVOKE ALL ON public.v_derm_portal_queue_held FROM anon, authenticated;
DO $v$ DECLARE n int; BEGIN
  -- 1. the queue lost only gdo_id IS NULL rows, and serves none
  SELECT count(*) INTO n FROM queue_before b WHERE b.gdo_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.v_derm_portal_queue q WHERE q.visit_id = b.visit_id AND q.gdo_id = b.gdo_id);
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 1: % permitted queue rows lost', n; END IF;
  IF EXISTS (SELECT 1 FROM public.v_derm_portal_queue WHERE gdo_id IS NULL) THEN RAISE EXCEPTION 'VERIFY 1b: a NULL-permit row is still served'; END IF;
  -- 2. the queue gained nothing today (exact-pair gate 3 releases 0 rows: measured 2026-10-20)
  SELECT count(*) INTO n FROM public.v_derm_portal_queue q
   WHERE NOT EXISTS (SELECT 1 FROM queue_before b WHERE b.visit_id = q.visit_id AND b.gdo_id IS NOT DISTINCT FROM q.gdo_id);
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 2: queue widened by % rows', n; END IF;
  -- 3. only NULL-permit rows changed hold reason, only to no_permit, and all three known ones did
  SELECT count(*) INTO n FROM held_before b JOIN public.v_derm_portal_queue_held a
      ON a.visit_id = b.visit_id AND a.gdo_id IS NOT DISTINCT FROM b.gdo_id
   WHERE a.held_by IS DISTINCT FROM b.held_by AND NOT (b.gdo_id IS NULL AND a.held_by = 'no_permit');
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 3: % hold reasons moved that are not no_permit', n; END IF;
  SELECT count(*) INTO n FROM public.v_derm_portal_queue_held WHERE held_by = 'no_permit' AND visit_id IN (7849, 7859, 7860);
  IF n <> 3 THEN RAISE EXCEPTION 'VERIFY 3b: expected 7849, 7859, 7860 as no_permit, got %', n; END IF;
  -- 3c. 8095 (246-LOUI, permit 217, county login refused) stays held as data_error
  IF NOT EXISTS (SELECT 1 FROM public.v_derm_portal_queue_held WHERE visit_id = 8095 AND gdo_id = 217 AND held_by = 'data_error') THEN
    RAISE EXCEPTION 'VERIFY 3c: 8095 is no longer held as data_error'; END IF;
  -- 4. privileges unchanged on the objects that keep them; the held view lost anon/authenticated only
  IF EXISTS (SELECT 1 FROM acl_before b
              WHERE b.acl IS DISTINCT FROM COALESCE(
                (SELECT c.relacl::text FROM pg_class c WHERE c.oid::regclass::text = b.obj),
                (SELECT p.proacl::text FROM pg_proc p WHERE p.oid::regprocedure::text = b.obj))) THEN
    RAISE EXCEPTION 'VERIFY 4: privileges moved';
  END IF;
  IF has_table_privilege('authenticated', 'public.v_derm_portal_queue_held', 'SELECT')
     OR NOT has_table_privilege('service_role', 'public.v_derm_portal_queue_held', 'SELECT') THEN
    RAISE EXCEPTION 'VERIFY 4b: held view grants wrong';
  END IF;
  PERFORM queue_depth, visits_ge3_attempts FROM public.v_rpa_derm_health;
  RAISE NOTICE 'VERIFY passed';
END $v$;
NOTIFY pgrst, 'reload schema';
COMMIT;
