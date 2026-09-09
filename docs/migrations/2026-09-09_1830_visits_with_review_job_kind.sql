-- 2026-09-09_1830  visits_with_review gains job_kind: 'SA' | 'SC' | 'other'.
--
-- Fred: "we need to create a new filter for the type of jobs, like 'Service Call', 'Service
-- Agreement' or 'Others'. It can be multiple select. By default it should be all selected ...
-- Also the 'Others' are the jobs that aren't SA or SC, usually they're old closed jobs that were
-- added manually."
--
-- The Admin Review queue already selects job_title, so the app COULD have split these itself. It
-- must not: this estate's rule is that the job classification lives in the DB and never in an app
-- (Admin Review CLAUDE.md, "no title tests"). One column, one rule, one place to correct it.
--
-- 🛑 job_kind IS CONSISTENT WITH job_is_sa_sc BY CONSTRUCTION, AND THE MIGRATION ASSERTS IT:
--       job_is_sa_sc  =  (job_kind IN ('SA','SC'))
-- on every row. That is what stops a second, subtly different copy of the SA/SC rule existing
-- beside the first - the exact failure this file's 2026-09-09_1600 sibling was written to avoid.
-- 🛑 THE CONSEQUENCE, AND IT IS BIGGER THAN IT LOOKS: '[OLD]' OUTRANKS THE TITLE MATCH, SO A JOB
-- TITLED "Service Call [OLD]" IS 'other', NOT 'SC'. Measured estate-wide:
--     "Service Call [OLD]" / "Service call [OLD]"     23 visits
--     "Service Agreement - Grey Water [OLD]"           6 visits
--     "Service Agreement - Auxiliary Line Cleaning [OLD]"  1 visit
-- plus 60-odd other '[OLD]' visits whose titles were never SA/SC anyway.
-- Someone filtering for "Service Call" will NOT see those 23. That is deliberate on three
-- grounds: it is what job_is_sa_sc has always done, it is the only ordering that keeps the two
-- consistent, and '[OLD]' is this estate's marker for the pre-convention era - which is exactly
-- how Fred described Others ("old closed jobs that were added manually").
-- ⚠ Only ONE '[OLD]' visit is in the queue today, an SA-titled one, so this is nearly invisible
-- right now. It becomes visible the moment one of those old jobs is manually included.
-- ⚠ MY FIRST VERSION OF THE PRECEDENCE ASSERTION FORGOT THIS AND THE DRY RUN REFUSED THE
-- MIGRATION. The rule was right and the test was over-broad; both directions are now asserted.
--
-- ⚠ 'Service Call%' IS A PREFIX MATCH, NOT THE ESTATE'S EXACT MATCH, AND THAT IS DELIBERATE HERE.
-- ops.client_service_options and the Client App lifecycle use lower(btrim(title)) = 'service call'.
-- Measured over the 527 queued visits: the prefix matches 214, the exact match 213, and the single
-- difference is a job titled "Service call - 341" - which a person filtering for Service Calls
-- plainly wants. job_is_sa_sc has always used the prefix, so using it here is also what keeps the
-- invariant above true. Do not "align" this to the exact form without re-checking both.
--
-- MEASURED on 2026-09-09 over the 527 visits then in the queue:
--   SA     283   every title starts "Service Agreement"
--   SC     214   213 exactly "Service Call", plus "Service call - 341"
--   other   30   "Grease Trap Pumping", "Hydrojet Cleaning", "service", "Grease trap " ...
--                i.e. the pre-convention free-text jobs, which is Fred's description exactly
--
-- Never NULL: a visit with no job row at all reads 'other'.
--
-- Rule 8: no new table, no new audited surface. One appended view column.

begin;

-- The whole view before the change. CREATE OR REPLACE VIEW validates column NAME, TYPE and ORDER
-- and says NOTHING about the expression behind them, so the only way to prove that appending a
-- column moved nothing else is to compare every other column row by row.
create temp table _pre_full on commit drop as select * from public.visits_with_review;

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
    COALESCE((j.title ~~* 'Service Agreement%'::text OR j.title ~~* 'Service Call%'::text) AND j.title !~~* '%[OLD]%'::text, false) AS job_is_sa_sc,
    COALESCE(j.job_status <> ALL (ARRAY['archived'::text, 'closed'::text, 'destroyed'::text]), false) OR w.started OR inc.visit_id IS NOT NULL AND inc.removed_at IS NULL AS in_review_scope,
        CASE
            WHEN COALESCE(j.job_status <> ALL (ARRAY['archived'::text, 'closed'::text, 'destroyed'::text]), false) THEN 'open_job'::text
            WHEN inc.visit_id IS NOT NULL AND inc.removed_at IS NULL THEN 'manual'::text
            WHEN w.started THEN 'work_started'::text
            ELSE NULL::text
        END AS scope_source,
    w.started AS review_work_started,
    j.title AS job_title,
    COALESCE(j.job_status <> ALL (ARRAY['archived'::text, 'closed'::text, 'destroyed'::text]), false) AS job_is_open,
        CASE
            WHEN j.title ~~* '%[OLD]%'::text THEN 'other'::text
            WHEN j.title ~~* 'Service Agreement%'::text THEN 'SA'::text
            WHEN j.title ~~* 'Service Call%'::text THEN 'SC'::text
            ELSE 'other'::text
        END AS job_kind
   FROM v_visits_live v
     LEFT JOIN visit_reviews vr ON vr.visit_id = v.id
     LEFT JOIN jobs j ON j.id = v.job_id
     LEFT JOIN review_scope_inclusions inc ON inc.visit_id = v.id
     LEFT JOIN LATERAL ( SELECT (EXISTS ( SELECT 1
                   FROM photo_links pl
                     JOIN photo_classifications pc ON pc.photo_link_id = pl.id
                  WHERE pl.entity_type = 'visit'::text AND pl.entity_id = v.id AND pl.deleted_at IS NULL)) OR (EXISTS ( SELECT 1
                   FROM visit_reviews r
                  WHERE r.visit_id = v.id AND (COALESCE(r.review_status, 'pending'::text) <> 'pending'::text OR COALESCE(r.bonus_status, 'pending'::text) <> 'pending'::text OR COALESCE(r.invoice_status, 'pending'::text) <> 'pending'::text OR r.quality_flag_note IS NOT NULL OR r.reviewed_at IS NOT NULL))) AS started) w ON true;

comment on column public.visits_with_review.job_kind is
  'SA | SC | other, from the job title, never NULL. Consistent with job_is_sa_sc by construction: job_is_sa_sc = (job_kind IN (SA, SC)). A [OLD]-tagged Service Agreement is other. Read this column; never re-implement the title test in an app.';

-- -------------------------------------------------------------------- VERIFY ----

do $$
declare
  v_n bigint; v_sa bigint; v_sc bigint; v_other bigint; v_probe bigint;
begin
  ------------------------------------------------------- 1. nothing else moved ----
  select count(*) into v_n from (
    (select
           id, client_id, property_id, job_id, vehicle_id, visit_date, start_at, end_at,
           completed_at, duration_minutes, title, service_type, visit_status,
           actual_arrival_at, actual_departure_at, is_gps_confirmed, created_at, updated_at,
           invoice_id, completed_by, review_status, reviewed_at, reviewed_by, bonus_status,
           bonus_decided_at, bonus_decided_by, bonus_denial_note, quality_flag_note, public_id,
           invoice_status, invoice_decided_at, invoice_decided_by, derm_required, job_is_sa_sc,
           in_review_scope, scope_source, review_work_started, job_title, job_is_open
       from _pre_full
     except all
     select
           id, client_id, property_id, job_id, vehicle_id, visit_date, start_at, end_at,
           completed_at, duration_minutes, title, service_type, visit_status,
           actual_arrival_at, actual_departure_at, is_gps_confirmed, created_at, updated_at,
           invoice_id, completed_by, review_status, reviewed_at, reviewed_by, bonus_status,
           bonus_decided_at, bonus_decided_by, bonus_denial_note, quality_flag_note, public_id,
           invoice_status, invoice_decided_at, invoice_decided_by, derm_required, job_is_sa_sc,
           in_review_scope, scope_source, review_work_started, job_title, job_is_open
       from public.visits_with_review)
    union all
    (select
           id, client_id, property_id, job_id, vehicle_id, visit_date, start_at, end_at,
           completed_at, duration_minutes, title, service_type, visit_status,
           actual_arrival_at, actual_departure_at, is_gps_confirmed, created_at, updated_at,
           invoice_id, completed_by, review_status, reviewed_at, reviewed_by, bonus_status,
           bonus_decided_at, bonus_decided_by, bonus_denial_note, quality_flag_note, public_id,
           invoice_status, invoice_decided_at, invoice_decided_by, derm_required, job_is_sa_sc,
           in_review_scope, scope_source, review_work_started, job_title, job_is_open
       from public.visits_with_review
     except all
     select
           id, client_id, property_id, job_id, vehicle_id, visit_date, start_at, end_at,
           completed_at, duration_minutes, title, service_type, visit_status,
           actual_arrival_at, actual_departure_at, is_gps_confirmed, created_at, updated_at,
           invoice_id, completed_by, review_status, reviewed_at, reviewed_by, bonus_status,
           bonus_decided_at, bonus_decided_by, bonus_denial_note, quality_flag_note, public_id,
           invoice_status, invoice_decided_at, invoice_decided_by, derm_required, job_is_sa_sc,
           in_review_scope, scope_source, review_work_started, job_title, job_is_open
       from _pre_full)
  ) d;
  if v_n <> 0 then
    raise exception '% row-differences on the 39 columns this migration only retyped', v_n;
  end if;

  if (select count(*) from information_schema.columns
       where table_schema='public' and table_name='visits_with_review') <> 40 then
    raise exception 'visits_with_review no longer has exactly 40 columns';
  end if;
  if (select column_name from information_schema.columns
       where table_schema='public' and table_name='visits_with_review' and ordinal_position=40) <> 'job_kind' then
    raise exception 'job_kind is not column 40';
  end if;

  --------------------------------------------------------- 2. the invariant ----
  -- The whole reason this column is safe to add: it cannot disagree with job_is_sa_sc.
  select count(*) into v_n from public.visits_with_review
   where job_is_sa_sc is distinct from (job_kind in ('SA','SC'));
  if v_n <> 0 then
    raise exception 'job_kind disagrees with job_is_sa_sc on % rows - two copies of one rule', v_n;
  end if;

  -- Never NULL, and never a fourth value.
  select count(*) into v_n from public.visits_with_review
   where job_kind is null or job_kind not in ('SA','SC','other');
  if v_n <> 0 then
    raise exception '% rows read a NULL or unexpected job_kind', v_n;
  end if;

  ------------------------------------------- 3. all three arms actually fire ----
  select count(*) filter (where job_kind='SA'),
         count(*) filter (where job_kind='SC'),
         count(*) filter (where job_kind='other')
    into v_sa, v_sc, v_other
    from public.visits_with_review
   where visit_status='completed'
     and visit_date <= (now() at time zone 'America/New_York')::date;
  if v_sa = 0 or v_sc = 0 or v_other = 0 then
    raise exception 'a job_kind arm never fires (SA % / SC % / other %) - the filter would have a dead option', v_sa, v_sc, v_other;
  end if;

  -- The '[OLD]' carve-out is real, not theoretical: it must send an SA-titled job to other.
  select count(*) into v_n from public.visits_with_review
   where job_title ilike '%[OLD]%' and job_title ilike 'Service Agreement%' and job_kind <> 'other';
  if v_n <> 0 then
    raise exception '% [OLD]-tagged Service Agreements did not land in other', v_n;
  end if;
  if not exists (select 1 from public.visits_with_review
                  where job_title ilike '%[OLD]%' and job_title ilike 'Service Agreement%') then
    raise notice 'NOTE: no [OLD]-tagged Service Agreement exists right now, so that carve-out is unexercised';
  end if;

  -- THE PRECEDENCE TEST. '[OLD]' outranks the SA/SC title match, so a job titled
  -- "Service Call [OLD]" is 'other', not 'SC' - 23 visits carry exactly that title today.
  -- That precedence is what keeps job_kind consistent with job_is_sa_sc, and it is what Fred
  -- described Others as. The first version of this assertion forgot the carve-out and correctly
  -- refused the migration; the rule was right and the test was over-broad.
  select count(*) into v_probe from public.visits_with_review
   where job_title ilike 'Service Call%' and job_title ilike '%[OLD]%';
  if v_probe = 0 then
    raise notice 'NOTE: no [OLD]-tagged Service Call exists any more, so the precedence check is unexercised';
  elsif exists (select 1 from public.visits_with_review
                 where job_title ilike 'Service Call%' and job_title ilike '%[OLD]%'
                   and job_kind <> 'other') then
    raise exception 'an [OLD]-tagged Service Call did not land in other - [OLD] must outrank the title match';
  end if;

  -- "Service call - 341" is the one live row separating the prefix rule from the exact one. If it
  -- ever stops existing this assertion tells you the header's justification went stale.
  select count(*) into v_probe from public.visits_with_review
   where job_title ilike 'Service Call%' and lower(btrim(job_title)) <> 'service call'
     and job_title not ilike '%[OLD]%';
  if v_probe = 0 then
    raise notice 'NOTE: no prefix-but-not-exact Service Call title exists any more; re-read the header before trusting its reasoning';
  elsif exists (select 1 from public.visits_with_review
                 where job_title ilike 'Service Call%' and lower(btrim(job_title)) <> 'service call'
                   and job_title not ilike '%[OLD]%' and job_kind <> 'SC') then
    raise exception 'a prefix Service Call title did not land in SC';
  end if;

  --------------------------------------------------- 4. reachability + grants ----
  if not has_table_privilege('authenticated','public.visits_with_review','SELECT') then
    raise exception 'authenticated lost SELECT - the view was dropped rather than replaced';
  end if;
  begin
    execute 'set local role authenticated';
    execute 'select count(*) from public.visits_with_review where job_kind = ''SA''' into v_n;
    execute 'reset role';
  exception when others then
    execute 'reset role';
    raise exception 'authenticated cannot read job_kind: % (%)', sqlerrm, sqlstate;
  end;
  if v_n = 0 then
    raise exception 'authenticated reads 0 SA visits';
  end if;

  -- The dependent view still resolves after its parent was replaced.
  perform 1 from public.v_review_scope_picker limit 1;

  raise notice 'VERIFY OK: job_kind added at column 40; queue SA % / SC % / other %; invariant with job_is_sa_sc holds on every row',
    v_sa, v_sc, v_other;
end $$;

commit;
