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
          WHERE r.visit_id = v.id AND (COALESCE(r.review_status, 'pending'::text) <> 'pending'::text OR COALESCE(r.bonus_status, 'pending'::text) <> 'pending'::text OR COALESCE(r.invoice_status, 'pending'::text) <> 'pending'::text OR r.quality_flag_note IS NOT NULL OR r.reviewed_at IS NOT NULL))) AS review_work_started
   FROM v_visits_live v
     LEFT JOIN visit_reviews vr ON vr.visit_id = v.id
     LEFT JOIN jobs j ON j.id = v.job_id
     LEFT JOIN review_scope_inclusions inc ON inc.visit_id = v.id;