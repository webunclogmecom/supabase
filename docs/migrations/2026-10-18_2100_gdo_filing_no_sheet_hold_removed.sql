-- ============================================================================
-- 2026-10-18_2100_gdo_filing_no_sheet_hold_removed
-- GDO online reports: remove the 'no_sheet' hold added by 2026-10-18_0220. A report is never held for a sheet.
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-18: "go ahead" on removing the hold and no longer sending documents to the bot.
-- WHY (measured, and read in the bot's own docs this time)
--   The county GDO online report form takes the permit, the hauler, the date pumped and a certification
--   checkbox. It has no attachment. The bot (webunclogmecom/unclogme-gdo-report-bot) never downloads
--   documents.address / documents.receipt (reporter.py, api_client.py: no upload step), and its README,
--   API_CONTRACT and RUNBOOK describe no upload. Our contract's section 9 said the queue signs the raw sheet
--   "because county submission needs the real document", marked "pending confirmation"; it was never confirmed.
--   2026-10-18_0220 was built on that note: it held a report until a sheet was on file, which can only delay
--   a filing. The 3 Broward-dump filings it called incomplete (visits 6218, 8089, 6721) were accepted by DERM
--   and need no correction.
-- WHAT CHANGES (bodies copied verbatim from the rehearsed 2026-10-18_rollback_gdo_filing_attaches_the_visit_sheet)
--   v_derm_portal_queue: no has_sheet gate (visit_sheet_urls emitted as NULL, column kept).
--   v_derm_portal_queue_held: no 'no_sheet' arm.
--   v_rpa_derm_health: held_no_sheet emitted as NULL (column kept for its readers).
--   log_rpa_derm_health: the pre-10-18 body (no rpa_held_no_sheet reason).
--   v_derm_portal_fields keeps its appended visit_sheet_urls / has_sheet (CREATE OR REPLACE cannot drop
--   them); nothing reads them after this.
--   Edge fn rpa-derm-queue (deployed with this, v31): documents.address and documents.receipt are sent as
--   empty lists, so no signed URL of a multi-client sheet leaves the database any more.
-- MEASURED AT WRITE TIME: 0 rows held 'no_sheet', queue 0, so the queue is unchanged today (VERIFY 2).
-- Rule 8: no table. ROLLBACK: 2026-10-18_rollback_gdo_filing_no_sheet_hold_removed.sql (the live bodies
--   dumped before this ran).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $g$ BEGIN
  IF md5(pg_get_viewdef('public.v_derm_portal_queue'::regclass)) IS DISTINCT FROM '558c261cd7f16e5c1237511214b2c8e5' THEN RAISE EXCEPTION 'queue changed since this file was written'; END IF;
  IF md5(pg_get_viewdef('public.v_derm_portal_queue_held'::regclass)) IS DISTINCT FROM '16fded34b2a81434eccb5d09a680226f' THEN RAISE EXCEPTION 'held changed since this file was written'; END IF;
  IF md5(pg_get_viewdef('public.v_rpa_derm_health'::regclass)) IS DISTINCT FROM 'a854f686cac1ae2e22dddef6ee144a26' THEN RAISE EXCEPTION 'health changed since this file was written'; END IF;
  IF md5(pg_get_functiondef('public.log_rpa_derm_health()'::regprocedure)) IS DISTINCT FROM '16f4932bb7933e4157f371dc4685d8f8' THEN RAISE EXCEPTION 'log changed since this file was written'; END IF;
END $g$;
CREATE TEMP TABLE queue_before ON COMMIT DROP AS SELECT visit_id, gdo_id FROM public.v_derm_portal_queue;
CREATE TEMP TABLE held_before ON COMMIT DROP AS SELECT visit_id, gdo_id, held_by FROM public.v_derm_portal_queue_held;
CREATE TEMP TABLE acl_before ON COMMIT DROP AS SELECT c.relname, c.relacl::text AS acl FROM pg_class c
 WHERE c.oid IN ('public.v_derm_portal_queue'::regclass, 'public.v_derm_portal_queue_held'::regclass, 'public.v_rpa_derm_health'::regclass);
CREATE TEMP TABLE facl_before ON COMMIT DROP AS SELECT p.proacl::text AS acl FROM pg_proc p WHERE p.oid = 'public.log_rpa_derm_health()'::regprocedure;
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
CREATE OR REPLACE VIEW public.v_rpa_derm_health AS
 SELECT ( SELECT count(*) AS count
           FROM v_derm_portal_queue) AS queue_depth,
    ( SELECT max(s.created_at) AS max
           FROM derm_portal_submissions s
          WHERE (NOT s.dry_run)) AS last_real_attempt,
    ( SELECT count(*) AS count
           FROM derm_portal_submissions s
          WHERE ((NOT s.dry_run) AND (s.status = 'SUCCESS'::text) AND (s.created_at > (now() - '24:00:00'::interval)))) AS success_24h,
    ( SELECT count(*) AS count
           FROM derm_portal_submissions s
          WHERE ((NOT s.dry_run) AND (s.screenshot_missing_reason = 'STORE_FAILED'::text))) AS store_failed_total,
    ( SELECT count(*) AS count
           FROM ( SELECT s.visit_id,
                    s.gdo_id
                   FROM derm_portal_submissions s
                  WHERE (NOT s.dry_run)
                  GROUP BY s.visit_id, s.gdo_id
                 HAVING ((count(*) >= 3) AND (count(*) FILTER (WHERE (s.status = 'SUCCESS'::text)) = 0))) q) AS visits_ge3_attempts,
    ( SELECT count(*) AS count
           FROM v_gdo_reporting_derm_mismatch) AS gdo_not_derm_required,
    ( SELECT count(*) AS count
           FROM v_rpa_derm_stale_leases) AS stale_leases,
    NULL::bigint AS held_no_sheet;
CREATE OR REPLACE VIEW public.v_derm_portal_queue_held AS
 SELECT visit_id,
    gdo_id,
    gdo_number,
    manifest_id,
    client_code,
    visit_date,
        CASE
            WHEN (NOT (visit_date >= rpa_launch_cutoff())) THEN 'before_launch_cutoff'::text
            WHEN (EXISTS ( SELECT 1
               FROM (derm_portal_submissions s
                 JOIN manifest_visits smv ON ((smv.visit_id = s.visit_id)))
              WHERE ((smv.manifest_id = f.manifest_id) AND (NOT s.dry_run) AND ((s.gdo_id IS NULL) OR (NOT (s.gdo_id IS DISTINCT FROM f.gdo_id))) AND ((s.status = 'SUCCESS'::text) OR (s.portal_confirmation IS NOT NULL))))) THEN 'already_filed'::text
            WHEN (EXISTS ( SELECT 1
               FROM (derm_portal_submissions s
                 JOIN manifest_visits smv ON ((smv.visit_id = s.visit_id)))
              WHERE ((smv.manifest_id = f.manifest_id) AND (NOT s.dry_run) AND ((s.gdo_id IS NULL) OR (NOT (s.gdo_id IS DISTINCT FROM f.gdo_id))) AND (s.created_at > (now() - '20:00:00'::interval))))) THEN 'cooldown_20h'::text
            WHEN (EXISTS ( SELECT 1
               FROM (derm_portal_submissions s
                 JOIN manifest_visits smv ON ((smv.visit_id = s.visit_id)))
              WHERE ((smv.manifest_id = f.manifest_id) AND (NOT s.dry_run) AND ((s.gdo_id IS NULL) OR (NOT (s.gdo_id IS DISTINCT FROM f.gdo_id))) AND (NOT s.retryable) AND (s.status <> 'SUCCESS'::text) AND (s.created_at > GREATEST(f.updated_at, COALESCE(( SELECT max(rq.requeued_at) AS max
                       FROM derm_portal_requeue rq
                      WHERE ((rq.manifest_id = f.manifest_id) AND ((rq.gdo_id IS NULL) OR (NOT (rq.gdo_id IS DISTINCT FROM f.gdo_id))))), '-infinity'::timestamp with time zone)))))) THEN 'data_error'::text
            WHEN (EXISTS ( SELECT 1
               FROM (derm_portal_leases l
                 JOIN manifest_visits lmv ON ((lmv.visit_id = l.visit_id)))
              WHERE ((lmv.manifest_id = f.manifest_id) AND (l.leased_at > (now() - '20:00:00'::interval))))) THEN 'leased'::text
            WHEN (NOT (EXISTS ( SELECT 1
               FROM v_derm_portal_queue qq
              WHERE ((qq.visit_id = f.visit_id) AND (NOT (qq.gdo_id IS DISTINCT FROM f.gdo_id)))))) THEN 'sibling_won_this_pass'::text
            ELSE NULL::text
        END AS held_by
   FROM v_derm_portal_fields f;
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
  WHERE ((visit_date >= rpa_launch_cutoff()) AND (NOT (EXISTS ( SELECT 1
           FROM (derm_portal_submissions s
             JOIN manifest_visits smv ON ((smv.visit_id = s.visit_id)))
          WHERE ((smv.manifest_id = f.manifest_id) AND (NOT s.dry_run) AND ((s.gdo_id IS NULL) OR (NOT (s.gdo_id IS DISTINCT FROM f.gdo_id))) AND ((s.status = 'SUCCESS'::text) OR (s.portal_confirmation IS NOT NULL)))))) AND (NOT (EXISTS ( SELECT 1
           FROM (derm_portal_submissions s
             JOIN manifest_visits smv ON ((smv.visit_id = s.visit_id)))
          WHERE ((smv.manifest_id = f.manifest_id) AND (NOT s.dry_run) AND ((s.gdo_id IS NULL) OR (NOT (s.gdo_id IS DISTINCT FROM f.gdo_id))) AND (s.created_at > (now() - '20:00:00'::interval)))))) AND (NOT (EXISTS ( SELECT 1
           FROM (derm_portal_submissions s
             JOIN manifest_visits smv ON ((smv.visit_id = s.visit_id)))
          WHERE ((smv.manifest_id = f.manifest_id) AND (NOT s.dry_run) AND ((s.gdo_id IS NULL) OR (NOT (s.gdo_id IS DISTINCT FROM f.gdo_id))) AND (NOT s.retryable) AND (s.status <> 'SUCCESS'::text) AND (s.created_at > GREATEST(f.updated_at, COALESCE(( SELECT max(rq.requeued_at) AS max
                   FROM derm_portal_requeue rq
                  WHERE ((rq.manifest_id = f.manifest_id) AND ((rq.gdo_id IS NULL) OR (NOT (rq.gdo_id IS DISTINCT FROM f.gdo_id))))), '-infinity'::timestamp with time zone))))))) AND (NOT (EXISTS ( SELECT 1
           FROM (derm_portal_leases l
             JOIN manifest_visits lmv ON ((lmv.visit_id = l.visit_id)))
          WHERE ((lmv.manifest_id = f.manifest_id) AND ((l.gdo_id IS NULL) OR (NOT (l.gdo_id IS DISTINCT FROM f.gdo_id))) AND (l.leased_at > (now() - '20:00:00'::interval)))))))
  ORDER BY manifest_id, gdo_id, (abs((visit_date - dump_ticket_date))), visit_id;
DO $v$ DECLARE n int; BEGIN
  -- 1. the bodies are exactly the pre-10-18 ones
  IF md5(pg_get_functiondef('public.log_rpa_derm_health()'::regprocedure)) <> 'ba0999792942d5d417d1b7ac5208a8ae'
     OR md5(pg_get_viewdef('public.v_derm_portal_queue_held'::regclass)) <> 'f3f608479125afd99dc4b04271a2c82d' THEN
    RAISE EXCEPTION 'VERIFY 1: bodies differ from the pre-10-18 ones';
  END IF;
  IF position('has_sheet' in pg_get_viewdef('public.v_derm_portal_queue'::regclass)) > 0
     OR position('no_sheet' in pg_get_viewdef('public.v_derm_portal_queue_held'::regclass)) > 0 THEN
    RAISE EXCEPTION 'VERIFY 1b: the sheet hold is still in a body';
  END IF;
  -- 2. the queue only GAINS rows, and only rows that were held as no_sheet (none today)
  SELECT count(*) INTO n FROM queue_before b WHERE NOT EXISTS (SELECT 1 FROM public.v_derm_portal_queue q WHERE q.visit_id = b.visit_id AND q.gdo_id IS NOT DISTINCT FROM b.gdo_id);
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 2: % queue rows lost', n; END IF;
  SELECT count(*) INTO n FROM public.v_derm_portal_queue q WHERE NOT EXISTS (SELECT 1 FROM queue_before b WHERE q.visit_id = b.visit_id AND q.gdo_id IS NOT DISTINCT FROM b.gdo_id)
     AND NOT EXISTS (SELECT 1 FROM held_before h WHERE h.visit_id = q.visit_id AND h.gdo_id IS NOT DISTINCT FROM q.gdo_id AND h.held_by = 'no_sheet');
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 2b: % queue rows appeared that were not held for a sheet', n; END IF;
  -- 3. every other hold reason unchanged
  SELECT count(*) INTO n FROM held_before b JOIN public.v_derm_portal_queue_held a ON a.visit_id = b.visit_id AND a.gdo_id IS NOT DISTINCT FROM b.gdo_id
   WHERE a.held_by IS DISTINCT FROM b.held_by AND b.held_by IS DISTINCT FROM 'no_sheet';
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 3: % hold reasons moved', n; END IF;
  -- 4. the health view still reads
  PERFORM queue_depth, held_no_sheet FROM public.v_rpa_derm_health;
  -- 5. privileges unchanged
  IF EXISTS (SELECT 1 FROM pg_class c JOIN acl_before b ON b.relname = c.relname
              WHERE c.oid IN ('public.v_derm_portal_queue'::regclass, 'public.v_derm_portal_queue_held'::regclass, 'public.v_rpa_derm_health'::regclass)
                AND c.relacl::text IS DISTINCT FROM b.acl)
     OR (SELECT p.proacl::text FROM pg_proc p WHERE p.oid = 'public.log_rpa_derm_health()'::regprocedure) IS DISTINCT FROM (SELECT acl FROM facl_before) THEN
    RAISE EXCEPTION 'VERIFY 5: privileges moved';
  END IF;
  RAISE NOTICE 'VERIFY passed';
END $v$;
NOTIFY pgrst, 'reload schema';
COMMIT;
