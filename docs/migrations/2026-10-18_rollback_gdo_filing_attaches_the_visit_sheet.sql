-- ROLLBACK of 2026-10-18_0220_gdo_filing_attaches_the_visit_sheet
-- CREATE OR REPLACE cannot drop appended columns, and v_derm_portal_fields has dependents in other schemas, so
-- the appended columns stay (harmless) and every behaviour goes back: the logger body, the health count (NULL),
-- the held arm, the queue gate (visit_sheet_urls re-emitted as NULL). Deploy the previous rpa-derm-queue too
-- (it ignores the column). Grants are untouched by CREATE OR REPLACE.
BEGIN;
SET LOCAL lock_timeout = '3s';
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
DO $v$ BEGIN
  IF md5(pg_get_functiondef('public.log_rpa_derm_health()'::regprocedure)) <> 'ba0999792942d5d417d1b7ac5208a8ae'
     OR md5(pg_get_viewdef('public.v_derm_portal_queue_held'::regclass)) <> 'f3f608479125afd99dc4b04271a2c82d' THEN
    RAISE EXCEPTION 'rollback VERIFY: bodies differ from the pre-migration ones';
  END IF;
END $v$;
NOTIFY pgrst, 'reload schema';
COMMIT;
