-- Rollback of 2026-11-17_0435_visit_reviews_missed_next_step.sql. A view cannot lose a column by REPLACE, so both views are dropped and recreated from
-- their pre-migration bodies (md5 5c92d7fc..., 28df2c76...), with their grants, then the column goes. The review
-- history of the column is kept in audit.logs.
begin;
set local lock_timeout = '3s';
drop view public.v_review_scope_picker;
drop view public.visits_with_review;
CREATE VIEW public.visits_with_review AS
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
CREATE VIEW public.v_review_scope_picker AS
 SELECT w.client_id,
    c.client_code,
    c.name AS client_name,
    w.id AS visit_id,
    w.public_id,
    w.visit_date,
    w.job_id,
    COALESCE(j.title, '(no job title)'::text) AS job_title,
    j.job_status,
    w.derm_required,
    w.in_review_scope,
    w.scope_source,
    (( SELECT count(*) AS count
           FROM photo_links pl
          WHERE pl.entity_type = 'visit'::text AND pl.entity_id = w.id AND pl.deleted_at IS NULL))::integer AS photo_count,
    w.job_is_open
   FROM visits_with_review w
     JOIN clients c ON c.id = w.client_id
     LEFT JOIN jobs j ON j.id = w.job_id
  WHERE w.visit_status = 'completed'::text;
revoke all on public.visits_with_review, public.v_review_scope_picker from public, anon;
grant all on public.visits_with_review, public.v_review_scope_picker to authenticated, service_role;
grant select on public.visits_with_review, public.v_review_scope_picker to yannick_readonly, db_backup_reader;
alter table public.visit_reviews drop column missed_next_step;
do $v$ begin
  if md5(pg_get_viewdef('public.visits_with_review'::regclass, true)) <> '5c92d7fc5eb2d12cf7017c02fec62c8a'
     or md5(pg_get_viewdef('public.v_review_scope_picker'::regclass, true)) <> '28df2c76f072c0b0aeae63d2d0b2e1e2' then
    raise exception 'ROLLBACK VERIFY: a body differs';
  end if;
end $v$;
commit;
