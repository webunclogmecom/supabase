-- 2026-09-01_1700  Expose whether a completed visit's JOB is one of the modern
--                  Service Agreement / Service Call jobs, so Admin Review can show
--                  the whole backlog for those and nothing for the old ad-hoc jobs.
--
-- Fred, 2026-09-01: *"we need to always show the visits, it doesn't matter if the job is
-- closed, but the rule is that it have to be a SC or SA job, not from those old jobs we
-- had before. That way we can always classify the photos it doesn't matter if it's a
-- closed job."*
--
-- 🛑 HIS PREMISE WAS WRONG AND THE FIX IS NOT WHERE HE EXPECTED. Recorded because the
-- obvious change ("remove the job-status filter") would have been a NO-OP and the
-- symptom would have survived it.
--   * `visits_with_review` contains NO job filter at all: it is `v_visits_live LEFT JOIN
--     visit_reviews`, zero mentions of `jobs` or `job_status`.
--   * The live Admin Review bundle contains **0** occurrences of `job_status` or
--     `archived` (walked 2 chunks / 892KB; the first walk found 1 chunk and reported 0
--     for everything, which was the instrument, not the answer - Vite's relative
--     `"./Chunk-hash.js"` imports were not being followed).
--   * A closed job's visits DO show. 11 archived-job visits are in the queue right now.
-- What actually hides them is the queue's own **28-day window**:
--   `.eq(visit_status,completed).lte(visit_date,today)` then `.gte(visit_date, today-28)`
--   unless a show-all flag is set. Archived jobs correlate only because they are OLD:
--   **726 of their 737 completed visits fall outside that window.**
--
-- WHAT THIS MIGRATION DOES. It adds ONE column so the rule has ONE implementation, in
-- the database, rather than a title regex living in a minified bundle. The app change
-- (filter on this column, drop the 28-day lower bound) is separate and comes after.
--
-- 🛑 WHY NOT `ops.v_calendar_visit.service_kind`, WHICH IS THE ESTATE'S SA/SC CLASSIFIER.
-- It cannot express this question. It is a heuristic that buckets EVERY visit into SA or
-- SC and never says "neither": a free-text `Grease Trap Pumping` job is classified `SA`
-- by its `%grease%` arm. Fred's rule needs a THIRD answer, so this is a different
-- question wearing the same words. Do not "unify" them.
--
-- THE RULE IS THE TITLE CONVENTION, and that is a deliberate choice, not laziness:
-- `save-client-job`'s own header states that an SA title starts `Service Agreement` and
-- that **the SC title is exactly `Service Call`**, and `ops.client_service_options`
-- already matches `lower(btrim(title)) = 'service call'`. So the convention is load
-- bearing elsewhere in the estate, not merely descriptive.
--
-- 🛑 THE `[OLD]` EXCLUSION IS NOT DECORATION. **14 `Service Call%` jobs and 3
-- `Service Agreement%` jobs also carry `[OLD]`**, so a prefix test alone re-admits the
-- legacy set this rule exists to drop. (`[` is not a LIKE metacharacter in Postgres, so
-- `%[OLD]%` is a literal match.)
--
-- 🛑 AND IT MUST NOT BE NULLABLE. `j.title` is NULL on 3 jobs and one completed visit has
-- no job at all, so the raw predicate is NULL for 4 visits. A NULL would make the app's
-- filter behaviour undefined and depend on whether it uses `.eq(true)` or `.not(false)`.
-- COALESCEd to FALSE: unknown provenance is NOT a modern job.
--
-- Measured now: 484 completed visits qualify, 657 are excluded, and the backlog this
-- unlocks is 309 SA/SC visits older than 28 days, 280 unreviewed, 223 carrying photos.
--
-- Rule 8: no new table, so no audit opt-in decision. One view, one appended column.

begin;

create or replace view public.visits_with_review as
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
    -- APPENDED 2026-09-01. FALSE, never NULL: an unknown job is not a modern job.
    COALESCE(
      (j.title ILIKE 'Service Agreement%' OR j.title ILIKE 'Service Call%')
        AND j.title NOT ILIKE '%[OLD]%',
      false) AS job_is_sa_sc
   FROM v_visits_live v
     LEFT JOIN visit_reviews vr ON vr.visit_id = v.id
     LEFT JOIN jobs j ON j.id = v.job_id;

comment on view public.visits_with_review is
  'Visits plus their review state. job_is_sa_sc marks the modern Service Agreement / Service Call jobs by the title convention save-client-job enforces, excluding [OLD]; it is FALSE and never NULL. Admin Review shows the full history for those regardless of job status, and nothing for the pre-convention ad-hoc jobs. It is NOT ops.v_calendar_visit.service_kind, which buckets everything into SA or SC and cannot answer this.';

do $$
declare
  v_sa_sc      int;
  v_excluded   int;
  v_nulls      int;
  v_old_admit  int;
  v_backlog    int;
  v_deps       int;
  v_authn      int;
  v_cols       int;
begin
  -- 1. The column is total: no NULLs, ever.
  select count(*) filter (where job_is_sa_sc),
         count(*) filter (where not job_is_sa_sc),
         count(*) filter (where job_is_sa_sc is null)
    into v_sa_sc, v_excluded, v_nulls
    from public.visits_with_review where visit_status = 'completed';
  if v_nulls <> 0 then
    raise exception '% completed visits have a NULL job_is_sa_sc; the app filter would be undefined', v_nulls;
  end if;
  if v_sa_sc = 0 or v_excluded = 0 then
    raise exception 'control failed: the split is degenerate (% in / % out), so the predicate is not discriminating', v_sa_sc, v_excluded;
  end if;

  -- 2. POSITIVE CONTROL on the [OLD] exclusion, which a prefix-only test would miss.
  --    17 jobs are SA/SC-titled AND [OLD]; not one of their visits may qualify.
  select count(*) into v_old_admit
    from public.visits_with_review w
    join public.jobs j on j.id = w.job_id
   where w.job_is_sa_sc and j.title ilike '%[OLD]%';
  if v_old_admit <> 0 then
    raise exception '% visits on [OLD] jobs were admitted as SA/SC', v_old_admit;
  end if;
  if (select count(*) from public.jobs
       where (title ilike 'Service Agreement%' or title ilike 'Service Call%')
         and title ilike '%[OLD]%') = 0 then
    raise exception 'control failed: no SA/SC-titled [OLD] job exists, so check 2 proves nothing';
  end if;

  -- 3. The backlog this is for actually exists, or the app change has nothing to show.
  select count(*) into v_backlog
    from public.visits_with_review w
    left join public.visit_reviews r on r.visit_id = w.id
   where w.visit_status = 'completed' and w.job_is_sa_sc
     and w.visit_date < (now() at time zone 'America/New_York')::date - 28
     and r.visit_id is null;
  if v_backlog = 0 then
    raise exception 'control failed: no unreviewed SA/SC visit older than 28 days, so the change would surface nothing';
  end if;

  -- 4. Appending a column must not have broken a dependent, and there were none.
  select count(*) into v_deps
    from pg_depend d join pg_rewrite rw on rw.oid = d.objid
    join pg_class c on c.oid = rw.ev_class
   where d.refobjid = 'public.visits_with_review'::regclass and c.relname <> 'visits_with_review';

  -- 5. Grants survived the replace, and the app's role can still read it.
  if not has_table_privilege('authenticated','public.visits_with_review','SELECT') then
    raise exception 'authenticated lost SELECT on visits_with_review';
  end if;
  begin
    execute 'set local role authenticated';
    execute 'select count(*) from public.visits_with_review' into v_authn;
    execute 'reset role';
  exception when others then
    execute 'reset role';
    raise exception 'authenticated cannot read visits_with_review: % (%)', sqlerrm, sqlstate;
  end;
  if coalesce(v_authn,0) = 0 then
    raise exception 'authenticated read the view but saw no rows';
  end if;

  select count(*) into v_cols from information_schema.columns
   where table_schema='public' and table_name='visits_with_review';

  raise notice 'VERIFY OK: % SA/SC completed, % excluded, 0 nulls, 0 [OLD] admitted, % unreviewed backlog older than 28d, % dependents, % columns, authenticated read % rows',
               v_sa_sc, v_excluded, v_backlog, v_deps, v_cols, v_authn;
end $$;

commit;
