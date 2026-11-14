-- =============================================================================
-- 2026-11-14_0213_client_v_intake_submissions_client_app_arm.sql
--
-- WHAT: client.v_intake_submissions, the list of site survey forms (Picture Planner's), also opens to a person who has
--       the Client App at View. ONE anchored edit of the live view text: its gate
--         (hr.fn_app_open('picture_planner', 'view') OR hr.fn_pp_forms_open())
--       gains one arm, OR hr.fn_app_open('client_app', 'view'). Nothing else of the view changes (same columns, rows,
--       grants and options; the VERIFY compares the stored text with the old one plus that arm).
--
-- WHY: Fred, 2026-11-14 about 12:40 AM ET, on the Client App move plan: "AA to FF all yes, and all defaults". Pick BB
--      (decision 3): a person with the Client App alone opens every Clients page, and "the reads the page uses accept
--      the Client App setting or the other app's". The Clients pages' Schedule survey dialog (IntakeScheduleDialog,
--      moving with the Client App) reads this view for a site's waiting forms. Measured 2026-11-14 in a rolled-back
--      rehearsal: person 58 with the Client App alone saw 0 waiting forms where Fred saw 11, with no error: a silent
--      hide, the only read of the Clients pages that failed that person.
--      Nobody's answer changes today: every active person with the Client App also has Picture Planner or the forms
--      switch (measured: 0 people gain a row).
--
-- READ ONLY. A view, no row is written. RULE 8, AUDIT: no table.
-- LOCK: CREATE OR REPLACE VIEW takes an ACCESS EXCLUSIVE lock until the end of this transaction, so it holds only the
--   guard, the statement and cheap checks (lock_timeout 3 s); the behaviour was proven in a rolled-back rehearsal.
-- search_path is '' inside this transaction, so the view text is the schema-qualified text pg_get_viewdef prints.
-- UNDO: 2026-11-14_rollback_client_v_intake_submissions_client_app_arm.sql (puts the old text back, md5-guarded).
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL search_path = '';

do $pin$
begin
  if md5(pg_catalog.pg_get_viewdef('client.v_intake_submissions'::regclass, false)) <> 'e97fd12ed71a8b976673f0addfa385ea' then
    raise exception 'client.v_intake_submissions is not the view this migration was written from; stop';
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
  WHERE ((hr.fn_app_open('picture_planner'::text, 'view'::text) OR hr.fn_pp_forms_open() OR hr.fn_app_open('client_app'::text, 'view'::text)) AND (i.cancelled_at IS NULL) AND ((i.submitted_at IS NOT NULL) OR (i.expires_at > now())));

do $verify$
begin
  if md5(pg_catalog.replace(pg_catalog.pg_get_viewdef('client.v_intake_submissions'::regclass, false), 'WHERE ((hr.fn_app_open(''picture_planner''::text, ''view''::text) OR hr.fn_pp_forms_open() OR hr.fn_app_open(''client_app''::text, ''view''::text)) AND', 'WHERE ((hr.fn_app_open(''picture_planner''::text, ''view''::text) OR hr.fn_pp_forms_open()) AND')) <> 'e97fd12ed71a8b976673f0addfa385ea' then
    raise exception 'verify_fail: the view is not the old one plus the Client App arm';
  end if;
  if (select c.relacl::text from pg_catalog.pg_class c where c.oid = 'client.v_intake_submissions'::regclass)
     is distinct from '{postgres=arwdDxtm/postgres,authenticated=r/postgres,db_backup_reader=r/postgres}'
     or (select c.reloptions from pg_catalog.pg_class c where c.oid = 'client.v_intake_submissions'::regclass) is not null then
    raise exception 'verify_fail: the grants or the options of the view changed';
  end if;
  if pg_catalog.has_table_privilege('anon', 'client.v_intake_submissions', 'SELECT') then
    raise exception 'verify_fail: anon can read the view';
  end if;
  raise notice 'verify ok: client.v_intake_submissions opens to the Client App at View too';
end $verify$;

COMMIT;
