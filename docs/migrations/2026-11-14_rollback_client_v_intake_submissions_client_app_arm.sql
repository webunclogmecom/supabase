-- ROLLBACK of 2026-11-14_0213_client_v_intake_submissions_client_app_arm.sql
--
-- Puts client.v_intake_submissions back to the text it had (verbatim, md5 e97fd12ed71a8b976673f0addfa385ea as printed with an empty search_path):
-- the Client App at View no longer opens it. Guarded: refuses unless the live view is the old one plus that arm.
-- A person with the Client App alone then sees no waiting form in the Schedule survey dialog again (nobody, today).

BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL search_path = '';

do $pin$
begin
  if md5(pg_catalog.replace(pg_catalog.pg_get_viewdef('client.v_intake_submissions'::regclass, false), 'WHERE ((hr.fn_app_open(''picture_planner''::text, ''view''::text) OR hr.fn_pp_forms_open() OR hr.fn_app_open(''client_app''::text, ''view''::text)) AND', 'WHERE ((hr.fn_app_open(''picture_planner''::text, ''view''::text) OR hr.fn_pp_forms_open()) AND')) <> 'e97fd12ed71a8b976673f0addfa385ea'
     or pg_catalog.md5(pg_catalog.pg_get_viewdef('client.v_intake_submissions'::regclass, false)) = 'e97fd12ed71a8b976673f0addfa385ea' then
    raise exception 'client.v_intake_submissions is not the view of 2026-11-14_0213_client_v_intake_submissions_client_app_arm; do not undo blindly';
  end if;
end
$pin$;

CREATE OR REPLACE VIEW client.v_intake_submissions AS
SELECT i.id AS intake_id,
        CASE
            WHEN (i.submitted_at IS NOT NULL) THEN 'submitted'::text
            ELSE 'awaiting'::text
        END AS state,
    i.property_id,
    p.client_id,
    c.client_code,
    c.name AS client_name,
    p.address,
    p.city,
    (p.deleted_at IS NOT NULL) AS property_deleted,
    i.requested_by,
    i.requested_at,
    i.expires_at,
    i.collector,
    i.submitted_at,
    pr.n_req AS requested_count,
        CASE
            WHEN (i.submitted_at IS NULL) THEN NULL::integer
            ELSE (pr.n_app - cardinality(public.fn_intake_missing(i.form_snapshot, i.requested, i.answers)))
        END AS answered_count,
        CASE
            WHEN (i.submitted_at IS NULL) THEN NULL::text
            WHEN (cardinality(public.fn_intake_missing(i.form_snapshot, i.requested, i.answers)) = 0) THEN 'Complete'::text
            ELSE 'Incomplete'::text
        END AS status,
        CASE
            WHEN (i.submitted_at IS NULL) THEN NULL::integer
            ELSE ( SELECT (count(*))::integer AS count
               FROM public.photo_links pl
              WHERE ((pl.entity_type = 'property_intake'::text) AND (pl.entity_id = i.id) AND (pl.deleted_at IS NULL) AND ((NOT (i.requested ? pl.role)) OR (public.fn_intake_applicable(i.form_snapshot, i.answers, pl.role) AND public.fn_intake_answered(i.answers, pl.role)))))
        END AS photo_count,
        CASE
            WHEN (i.submitted_at IS NULL) THEN NULL::boolean
            ELSE (public.fn_intake_answered(i.answers, 'site_map.gt_location'::text) AND public.fn_intake_applicable(i.form_snapshot, i.answers, 'site_map.gt_location'::text))
        END AS has_gt_pin,
        CASE
            WHEN (i.submitted_at IS NULL) THEN NULL::boolean
            ELSE (public.fn_intake_answered(i.answers, 'site_map.truck_parking'::text) AND public.fn_intake_applicable(i.form_snapshot, i.answers, 'site_map.truck_parking'::text))
        END AS has_truck_pin,
    ( SELECT (count(*))::integer AS count
           FROM public.property_intake_accepts a
          WHERE (a.intake_id = i.id)) AS accepted_count,
    ( SELECT max(a.accepted_at) AS max
           FROM public.property_intake_accepts a
          WHERE (a.intake_id = i.id)) AS last_accepted_at,
        CASE
            WHEN (i.submitted_at IS NULL) THEN NULL::integer
            ELSE pr.n_app
        END AS applicable_count
   FROM (((public.property_intakes i
     JOIN public.properties p ON ((p.id = i.property_id)))
     LEFT JOIN public.clients c ON ((c.id = p.client_id)))
     CROSS JOIN LATERAL ( SELECT (count(*))::integer AS n_req,
            (count(*) FILTER (WHERE public.fn_intake_required(i.form_snapshot, i.answers, r.k)))::integer AS n_app
           FROM ( SELECT DISTINCT x.value AS k
                   FROM jsonb_array_elements_text(i.requested) x(value)
                  WHERE ((x.value IS NOT NULL) AND (btrim(x.value) <> ''::text))) r) pr)
  WHERE ((hr.fn_app_open('picture_planner'::text, 'view'::text) OR hr.fn_pp_forms_open()) AND (i.cancelled_at IS NULL) AND ((i.submitted_at IS NOT NULL) OR (i.expires_at > now())));

do $verify$
begin
  if md5(pg_catalog.pg_get_viewdef('client.v_intake_submissions'::regclass, false)) <> 'e97fd12ed71a8b976673f0addfa385ea' then
    raise exception 'verify_fail: client.v_intake_submissions is not the old text';
  end if;
  raise notice 'verify ok: client.v_intake_submissions is the old view again';
end $verify$;

COMMIT;
