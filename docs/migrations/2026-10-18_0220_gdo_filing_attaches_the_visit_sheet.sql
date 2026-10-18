-- ============================================================================
-- 2026-10-18_0220_gdo_filing_attaches_the_visit_sheet
-- GDO online reports: attach the visit's own sheet when there is no Miami-Dade address sheet, and never
-- serve a report with no sheet at all.
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-18, "go ahead", on: "The GDO bot filed 3 Broward-dump visits with Miami-Dade without their
--   manifest sheet ... The fix is on our side."
-- WHY (measured)
--   rpa-derm-queue attaches derm_address_url (+ extras) as the address document. A Broward-dump visit has no
--   shared Miami-Dade sheet: its sheet is a per-visit FDEP sheet in derm.manifest_visit_sheets (2026-09-07), so
--   the bot got an empty list. 3 of 40 real SUCCESS filings went that way: submissions 2008 (visit 6218, Oct 8),
--   2015 (8089) and 2016 (6721, both Oct 16), all three with a per-visit sheet on file.
-- WHAT CHANGES
--   public.v_derm_portal_fields + visit_sheet_urls (derm.fn_fog_documents, the canonical "this visit's FOG
--     document" used by the Field Portal and the city emails, read only when the manifest has no address
--     sheet) and has_sheet. Appended columns; nothing else moves (VERIFY).
--   v_derm_portal_queue: + visit_sheet_urls, and a row with no sheet at all is not served.
--   v_derm_portal_queue_held: such a row reads 'no_sheet' (rpa-derm-queue's `held` summary shows it).
--   v_derm_portal_dryrun: + visit_sheet_urls, so a dry run carries the same document.
--   v_rpa_derm_health + held_no_sheet; log_rpa_derm_health raises 'rpa_held_no_sheet' with a plain issue and
--     what to do, so it reaches the health email (health-escalate renders issue/what_to_do).
--   Edge fn rpa-derm-queue (deployed with this): documents.address = the address sheet, else visit_sheet_urls.
-- NOT DONE: the 3 past filings went out without their sheet; whether to correct them at the county is Fred's
--   and Jonathan's call.
-- Rule 8: no table. ROLLBACK: 2026-10-18_rollback_gdo_filing_attaches_the_visit_sheet.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $g$ BEGIN
  IF md5(pg_get_viewdef('public.v_derm_portal_fields'::regclass)) IS DISTINCT FROM '1086e5c151226c80f215b7bd19b0330b' THEN RAISE EXCEPTION 'fields changed since this file was written'; END IF;
  IF md5(pg_get_viewdef('public.v_derm_portal_queue'::regclass)) IS DISTINCT FROM '2ae3d280ce3e71e0a155e9698c8c4726' THEN RAISE EXCEPTION 'queue changed since this file was written'; END IF;
  IF md5(pg_get_viewdef('public.v_derm_portal_dryrun'::regclass)) IS DISTINCT FROM 'f5ceb2b6e8faed4fb59951c9b6709c8a' THEN RAISE EXCEPTION 'dry changed since this file was written'; END IF;
  IF md5(pg_get_viewdef('public.v_derm_portal_queue_held'::regclass)) IS DISTINCT FROM 'f3f608479125afd99dc4b04271a2c82d' THEN RAISE EXCEPTION 'held changed since this file was written'; END IF;
  IF md5(pg_get_viewdef('public.v_rpa_derm_health'::regclass)) IS DISTINCT FROM '4fadd0b7a79a111a399f9da4891368d4' THEN RAISE EXCEPTION 'health changed since this file was written'; END IF;
  IF md5(pg_get_functiondef('public.log_rpa_derm_health()'::regprocedure)) IS DISTINCT FROM 'ba0999792942d5d417d1b7ac5208a8ae' THEN RAISE EXCEPTION 'log changed since this file was written'; END IF;
END $g$;
CREATE TEMP TABLE fields_before ON COMMIT DROP AS SELECT to_jsonb(f) AS j FROM public.v_derm_portal_fields f;
CREATE TEMP TABLE queue_before ON COMMIT DROP AS SELECT to_jsonb(q) AS j FROM public.v_derm_portal_queue q;
CREATE TEMP TABLE held_before ON COMMIT DROP AS SELECT visit_id, gdo_id, held_by FROM public.v_derm_portal_queue_held;
CREATE TEMP TABLE acl_before ON COMMIT DROP AS SELECT c.relname, c.relacl::text AS acl FROM pg_class c
 WHERE c.oid IN ('public.v_derm_portal_fields'::regclass, 'public.v_derm_portal_queue'::regclass, 'public.v_derm_portal_dryrun'::regclass,
                 'public.v_derm_portal_queue_held'::regclass, 'public.v_rpa_derm_health'::regclass);

CREATE OR REPLACE VIEW public.v_derm_portal_fields AS
 SELECT v.id AS visit_id,
    v.visit_date,
    v.client_id,
    c.client_code,
    c.name AS client_name,
    (client.fn_derm_recipient(c.id) ->> 'email'::text) AS client_email,
    pp.address,
    pp.city,
    pp.zip,
    pp.county,
    gd.gdo_number,
    m.id AS manifest_id,
    m.white_manifest_number,
    m.dump_ticket_date,
    df.name AS disposal_facility,
    m.derm_address_url,
    m.derm_address_extra_urls,
    m.derm_manifest_url,
    m.derm_manifest_extra_urls,
    GREATEST(v.updated_at, mv_link.linked_at) AS updated_at,
    mv_link.linked_at,
        CASE
            WHEN (m.yellow_ticket_number IS NOT NULL) THEN m.yellow_ticket_number
            WHEN ((m.white_manifest_number IS NOT NULL) AND (length(m.white_manifest_number) >= 5)) THEN m.white_manifest_number
            ELSE NULL::text
        END AS ticket_number,
        CASE
            WHEN (m.yellow_ticket_number IS NOT NULL) THEN 'broward'::text
            WHEN ((m.white_manifest_number IS NOT NULL) AND (length(m.white_manifest_number) >= 5)) THEN 'dade'::text
            ELSE 'unknown'::text
        END AS jurisdiction,
    gd.gdo_id,
    vs.urls AS visit_sheet_urls,
    ((m.derm_address_url IS NOT NULL) OR (COALESCE(cardinality(m.derm_address_extra_urls), 0) > 0) OR (cardinality(vs.urls) > 0)) AS has_sheet
   FROM ((((((visits v
     JOIN clients c ON ((c.id = v.client_id)))
     JOIN LATERAL ( SELECT mv.manifest_id,
            GREATEST(m2.updated_at, m2.created_at) AS linked_at
           FROM (manifest_visits mv
             JOIN derm_manifests m2 ON (((m2.id = mv.manifest_id) AND (m2.deleted_at IS NULL))))
          WHERE (mv.visit_id = v.id)
          ORDER BY m2.created_at DESC
         LIMIT 1) mv_link ON (true))
     JOIN derm_manifests m ON ((m.id = mv_link.manifest_id)))
     LEFT JOIN LATERAL ( SELECT p.address,
            p.city,
            p.zip,
            p.county
           FROM properties p
          WHERE ((p.client_id = c.id) AND p.is_primary)
          ORDER BY p.id
         LIMIT 1) pp ON (true))
     LEFT JOIN LATERAL ( SELECT g.gdo_number,
            g.id AS gdo_id
           FROM gdos g
          WHERE ((g.client_id = c.id) AND (g.status = 'ACTIVE'::text) AND (g.gdo_number ~ '^GDO-[0-9]+$'::text))) gd ON (true))
     LEFT JOIN disposal_facilities df ON ((df.id = m.disposal_facility_id)))
     -- 2026-10-18: the visit's own sheet (a Broward-dump visit's FDEP sheet), read from the canonical
     -- derm.fn_fog_documents, only when the manifest carries no Miami-Dade address sheet
     CROSS JOIN LATERAL ( SELECT CASE
                WHEN ((m.derm_address_url IS NULL) AND (COALESCE(cardinality(m.derm_address_extra_urls), 0) = 0))
                THEN ARRAY( SELECT d.url FROM derm.fn_fog_documents(m.id, v.client_id, v.id) d(effective_page, url) ORDER BY d.effective_page)
                ELSE '{}'::text[]
            END AS urls) vs
  WHERE ((v.deleted_at IS NULL) AND fn_visit_is_gdo_reporting(v.id));

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
    visit_sheet_urls
   FROM v_derm_portal_fields f
  WHERE ((visit_date >= rpa_launch_cutoff()) AND has_sheet AND (NOT (EXISTS ( SELECT 1
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

CREATE OR REPLACE VIEW public.v_derm_portal_dryrun AS
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
    visit_sheet_urls
   FROM v_derm_portal_fields f
  WHERE (visit_date < rpa_launch_cutoff())
  ORDER BY manifest_id, gdo_id, (abs((visit_date - dump_ticket_date))), visit_id;

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
            WHEN (NOT has_sheet) THEN 'no_sheet'::text
            WHEN (NOT (EXISTS ( SELECT 1
               FROM v_derm_portal_queue qq
              WHERE ((qq.visit_id = f.visit_id) AND (NOT (qq.gdo_id IS DISTINCT FROM f.gdo_id)))))) THEN 'sibling_won_this_pass'::text
            ELSE NULL::text
        END AS held_by
   FROM v_derm_portal_fields f;

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
    ( SELECT count(*) AS count
           FROM v_derm_portal_queue_held
          WHERE (v_derm_portal_queue_held.held_by = 'no_sheet'::text)) AS held_no_sheet;

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
  -- 2026-10-18: a GDO report held because its visit has no manifest sheet on file reaches the health email
  if h.held_no_sheet > 0 then attn := true; reasons := reasons || jsonb_build_object('kind','rpa_held_no_sheet','count',h.held_no_sheet,
      'issue', h.held_no_sheet || ' GDO online report' || case when h.held_no_sheet = 1 then ' is' else 's are' end || ' waiting because the visit has no manifest sheet on file',
      'what_to_do', 'Upload the address sheet (Miami-Dade dump) or the visit sheet (Broward dump) in the DERM Tracker. The bot files it on its next pass.'); end if;
  insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
  values ('rpa-derm-health', now(), now(), coalesce(h.queue_depth,0),
          case when attn then 'attention' else 'ok' end,
          jsonb_build_object('queue_depth',h.queue_depth,'last_real_attempt',h.last_real_attempt,
                             'success_24h',h.success_24h,'store_failed_total',h.store_failed_total,
                             'visits_ge3_attempts',h.visits_ge3_attempts,
                             'gdo_not_derm_required',h.gdo_not_derm_required,
                             'stale_leases',h.stale_leases,'held_no_sheet',h.held_no_sheet,'reasons',reasons));
  return case when attn then 1 else 0 end;
end $function$;

DO $v$
DECLARE n int; v_urls text[]; v_served jsonb; v_held text;
BEGIN
  -- 1. every existing column of every row is unchanged
  SELECT count(*) INTO n FROM (
    (SELECT j FROM fields_before EXCEPT ALL SELECT to_jsonb(f) - 'visit_sheet_urls' - 'has_sheet' FROM public.v_derm_portal_fields f)
    UNION ALL
    (SELECT to_jsonb(f) - 'visit_sheet_urls' - 'has_sheet' FROM public.v_derm_portal_fields f EXCEPT ALL SELECT j FROM fields_before)) x;
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 1: % fields rows differ', n; END IF;
  -- 2. the queue serves the same rows, minus only rows with no sheet
  SELECT count(*) INTO n FROM queue_before b
   WHERE NOT EXISTS (SELECT 1 FROM public.v_derm_portal_queue q WHERE to_jsonb(q) - 'visit_sheet_urls' = b.j)
     AND EXISTS (SELECT 1 FROM public.v_derm_portal_fields f WHERE f.visit_id = (b.j->>'visit_id')::bigint AND f.has_sheet);
  IF n <> 0 OR (SELECT count(*) FROM public.v_derm_portal_queue) > (SELECT count(*) FROM queue_before) THEN
    RAISE EXCEPTION 'VERIFY 2: the queue changed beyond the no-sheet rule (% rows)', n;
  END IF;
  -- 3. held reasons unchanged except the new no_sheet
  SELECT count(*) INTO n FROM held_before b JOIN public.v_derm_portal_queue_held a USING (visit_id)
   WHERE a.gdo_id IS NOT DISTINCT FROM b.gdo_id AND a.held_by IS DISTINCT FROM b.held_by AND a.held_by IS DISTINCT FROM 'no_sheet';
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 3: % held reasons moved', n; END IF;
  -- 4. positive control: the three bare filings now carry their visit sheet
  IF (SELECT count(*) FROM public.v_derm_portal_fields f WHERE f.visit_id IN (6218, 8089, 6721) AND f.has_sheet AND cardinality(f.visit_sheet_urls) = 1) <> 3 THEN
    RAISE EXCEPTION 'VERIFY 4: the three Broward visits do not carry their sheet';
  END IF;
  -- 5. rebuilt and undone: visit 6218 not yet filed is served WITH its sheet; with no sheet it is held as no_sheet
  <<ctl>>
  BEGIN
    DELETE FROM public.derm_portal_submissions WHERE visit_id = 6218;
    DELETE FROM public.derm_portal_leases WHERE visit_id = 6218;
    SELECT to_jsonb(q.visit_sheet_urls) INTO v_served FROM public.v_derm_portal_queue q WHERE q.visit_id = 6218;
    UPDATE derm.manifest_visit_sheets SET deleted_at = now() WHERE visit_id = 6218;
    SELECT h.held_by INTO v_held FROM public.v_derm_portal_queue_held h WHERE h.visit_id = 6218;
    RAISE EXCEPTION USING ERRCODE = 'P0099', MESSAGE = coalesce(v_served::text, 'null') || '|' || coalesce(v_held, 'null');
  EXCEPTION WHEN SQLSTATE 'P0099' THEN
    IF split_part(SQLERRM, '|', 1) NOT LIKE '["https://%manifests/%"]' OR split_part(SQLERRM, '|', 2) <> 'no_sheet' THEN
      RAISE EXCEPTION 'VERIFY 5: control read %', SQLERRM;
    END IF;
  END ctl;
  IF (SELECT count(*) FROM public.derm_portal_submissions WHERE visit_id = 6218) <> 1 THEN RAISE EXCEPTION 'VERIFY 5b: control not undone'; END IF;
  -- 6. health has the count, privileges unchanged
  PERFORM held_no_sheet FROM public.v_rpa_derm_health;
  IF EXISTS (SELECT 1 FROM acl_before b JOIN pg_class c ON c.relname = b.relname AND c.relnamespace = 'public'::regnamespace
              WHERE c.relacl::text IS DISTINCT FROM b.acl) THEN RAISE EXCEPTION 'VERIFY 6: privileges moved'; END IF;
  RAISE NOTICE 'VERIFY passed';
END $v$;

NOTIFY pgrst, 'reload schema';
COMMIT;
