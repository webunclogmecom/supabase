-- 2026-09-02_1830_visits_with_review_job_title.sql
--
-- WHAT: adds job_title to public.visits_with_review, appended as the last column. It is j.title
--       from the jobs table the view ALREADY left-joins. Nothing else changes.
--
-- WHY:  MY MISTAKE, caught by looking at the rendered page rather than at my own reasoning.
--       The Admin Review queue was told to show "the real title of the service" instead of the raw
--       line items. I pointed the app at visits_with_review.title because the column list read
--       "job_id, title, service_type" and I took `title` to be the job's. It is not: it is the
--       VISIT's own composed title, which prefixes the client. Measured:
--
--         visits_with_review.title  ->  "186-PV Pura Vida Coconut Grove - Service Agreement -
--                                        Grease Trap & Lift Station Pumping & Tank Cleaning"
--         jobs.title                ->  "Service Agreement - Grease Trap & Lift Station Pumping
--                                        & Tank Cleaning"
--
--       So the queue card rendered the client code and name twice: once as its own heading and
--       again inside the service line. Fred's requested output is the second string, exactly.
--
-- WHY A VIEW COLUMN RATHER THAN STRIPPING THE PREFIX IN THE APP. The prefix is
--       "<client_code> <client_name> - " and client names in this estate contain hyphens and
--       parentheses of their own ("247-LOU (SLBURGER6 LLC) Skinny Louie Coral Gables - ..."), so
--       any client-side split on " - " is a guess that fails on real data. The clean value already
--       exists one join away; expose it and let the app read a field that means what it is called.
--
-- ⚠ APPENDED AT THE END ON PURPOSE. CREATE OR REPLACE VIEW may add columns only at the end of the
--    select list; inserting job_title next to title would force a DROP and recreate, which discards
--    grants. VERIFY 3 checks the grant survived rather than assuming it.
--
-- ⚠ title IS DELIBERATELY LEFT ALONE. Something may depend on the composed form, and silently
--    changing the meaning of an existing column is how a reader ends up trusting the wrong string.
--
-- RULE 8 (audit): no table or column changes on a base table. A view definition only.
-- RULE 2/3: nothing derived, copied or stored; job_title is read through the existing FK join.

BEGIN;

CREATE OR REPLACE VIEW public.visits_with_review AS
 SELECT v.id,
    v.client_id,
    v.property_id,
    v.job_id,
    v.vehicle_id,
    v.visit_date,
    v.start_at,
    v.end_at,
    v.completed_at,
    v.duration_minutes,
    v.title,
    v.service_type,
    v.visit_status,
    v.actual_arrival_at,
    v.actual_departure_at,
    v.is_gps_confirmed,
    v.created_at,
    v.updated_at,
    v.invoice_id,
    v.completed_by,
    COALESCE(vr.review_status, 'pending'::text) AS review_status,
    vr.reviewed_at,
    vr.reviewed_by,
    COALESCE(vr.bonus_status, 'pending'::text) AS bonus_status,
    vr.bonus_decided_at,
    vr.bonus_decided_by,
    vr.bonus_denial_note,
    vr.quality_flag_note,
    v.public_id,
    COALESCE(vr.invoice_status, 'pending'::text) AS invoice_status,
    vr.invoice_decided_at,
    vr.invoice_decided_by,
    v.derm_required,
    COALESCE((j.title ~~* 'Service Agreement%'::text OR j.title ~~* 'Service Call%'::text) AND j.title !~~* '%[OLD]%'::text, false) AS job_is_sa_sc,
    COALESCE((j.title ~~* 'Service Agreement%'::text OR j.title ~~* 'Service Call%'::text) AND j.title !~~* '%[OLD]%'::text, false) OR inc.visit_id IS NOT NULL AND inc.removed_at IS NULL AS in_review_scope,
        CASE
            WHEN COALESCE((j.title ~~* 'Service Agreement%'::text OR j.title ~~* 'Service Call%'::text) AND j.title !~~* '%[OLD]%'::text, false) THEN 'convention'::text
            WHEN inc.visit_id IS NOT NULL AND inc.removed_at IS NULL THEN 'manual'::text
            ELSE NULL::text
        END AS scope_source,
    (EXISTS ( SELECT 1
           FROM photo_links pl
             JOIN photo_classifications pc ON pc.photo_link_id = pl.id
          WHERE pl.entity_type = 'visit'::text AND pl.entity_id = v.id AND pl.deleted_at IS NULL)) OR (EXISTS ( SELECT 1
           FROM visit_reviews r
          WHERE r.visit_id = v.id AND (COALESCE(r.review_status, 'pending'::text) <> 'pending'::text OR COALESCE(r.bonus_status, 'pending'::text) <> 'pending'::text OR COALESCE(r.invoice_status, 'pending'::text) <> 'pending'::text OR r.quality_flag_note IS NOT NULL OR r.reviewed_at IS NOT NULL))) AS review_work_started,
    j.title AS job_title
   FROM v_visits_live v
     LEFT JOIN visit_reviews vr ON vr.visit_id = v.id
     LEFT JOIN jobs j ON j.id = v.job_id
     LEFT JOIN review_scope_inclusions inc ON inc.visit_id = v.id;

DO $$
DECLARE
  v_cols int; v_jt text; v_t text; v_authn boolean; v_cov int; v_tot int; v_mismatch int;
BEGIN
  -- 1. the column exists, and every existing column survived
  SELECT count(*) INTO v_cols FROM information_schema.columns
   WHERE table_schema='public' AND table_name='visits_with_review';
  IF v_cols <> 37 + 1 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: the view has % columns, expected % + 1', v_cols, 37;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema='public' AND table_name='visits_with_review'
                    AND column_name='job_title') THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: job_title is missing';
  END IF;

  -- 2. it carries the CLEAN service title, and title still carries the composed one.
  --    Both halves matter: if title had silently changed, a different consumer would break.
  SELECT job_title, title INTO v_jt, v_t FROM public.visits_with_review WHERE id = 6418;
  IF v_jt IS DISTINCT FROM 'Service Agreement - Grease Trap & Lift Station Pumping & Tank Cleaning' THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: job_title reads %', coalesce(v_jt,'<null>');
  END IF;
  IF v_t NOT LIKE '186-PV %' THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: the composed title changed, it now reads %', coalesce(v_t,'<null>');
  END IF;

  -- CONTROL: job_title must equal jobs.title for EVERY row, not just the one I looked at
  SELECT count(*) INTO v_mismatch
    FROM public.visits_with_review x
    LEFT JOIN public.jobs j ON j.id = x.job_id
   WHERE x.job_title IS DISTINCT FROM j.title;
  IF v_mismatch <> 0 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: % row(s) where job_title does not match jobs.title', v_mismatch;
  END IF;

  -- 3. grants survived CREATE OR REPLACE
  SELECT has_table_privilege('authenticated','public.visits_with_review','SELECT') INTO v_authn;
  IF v_authn IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: authenticated lost SELECT on visits_with_review';
  END IF;

  -- 4. coverage, so the app knows how often it must fall back
  SELECT count(*) FILTER (WHERE nullif(btrim(job_title),'') IS NOT NULL), count(*)
    INTO v_cov, v_tot
    FROM public.visits_with_review WHERE visit_status = 'completed';
  IF v_cov * 100 < v_tot * 99 THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: only % of % completed visits have a job_title', v_cov, v_tot;
  END IF;
  RAISE NOTICE 'OK: job_title exposed; % of % completed visits carry one.', v_cov, v_tot;
END $$;

COMMIT;
