-- ============================================================================
-- 2026-07-02 — Expose visits.sync_state on ops.v_calendar_visit_detail (Calendar fix #3)
-- ============================================================================
-- The Calendar drawer's "Saving… syncing to Jobber" spinner hangs on a fixed wait even
-- though the Jobber push settles fast server-side (p50 0.69s / p95 3.89s over 1029 pushes;
-- all 1518 live visits sync_state='confirmed'). Root cause = FRONTEND over-wait: the drawer
-- had no durable server signal to watch. public.visits.sync_state is that signal — a BEFORE
-- trigger sets it 'pending' in the same txn as the edit, and the jobber-push-visit edge fn
-- flips it to 'confirmed' (settled) or 'failed' at the end of its request. It was already on
-- ops.v_calendar_visit (grid) but NOT on ops.v_calendar_visit_detail (the drawer's own fetch).
--
-- This adds sync_state as the LAST column of the detail view (CREATE OR REPLACE only appends;
-- all existing columns unchanged, so anon SELECT grant + downstream consumers are preserved),
-- so the drawer can poll its own feed: spin while 'pending', clear on 'confirmed', surface a
-- retry affordance on 'failed'. Frontend wiring is the paired Lovable change.
-- Idempotent (CREATE OR REPLACE). Additive only.
-- ============================================================================
CREATE OR REPLACE VIEW ops.v_calendar_visit_detail AS
 SELECT v.id AS visit_id,
    v.job_id,
    v.client_id,
    v.title,
    v.visit_date,
    v.visit_status,
    v.derm_required,
        CASE
            WHEN j.title ~~* 'Service Agreement%'::text THEN 'service_agreement'::text
            WHEN j.title ~~* 'Service Call%'::text THEN 'service_call'::text
            ELSE NULL::text
        END AS service_kind,
    j.frequency_days AS agreement_frequency_days,
        CASE
            WHEN esl.source_id IS NOT NULL THEN 'https://secure.getjobber.com/work_orders/'::text || split_part(convert_from(decode(esl.source_id, 'base64'::text), 'UTF8'::name), '/'::text, '-1'::integer)
            ELSE NULL::text
        END AS jobber_job_url,
    COALESCE(( SELECT json_agg(json_build_object('name', li.name, 'description', li.description, 'quantity', li.quantity, 'unit_price', li.unit_price) ORDER BY li.name) AS json_agg
           FROM public.line_items li
          WHERE li.visit_id = v.id), ( SELECT json_agg(json_build_object('name', li.name, 'description', li.description, 'quantity', li.quantity, 'unit_price', li.unit_price) ORDER BY li.name) AS json_agg
           FROM public.line_items li
          WHERE li.job_id = v.job_id AND li.visit_id IS NULL AND li.invoice_id IS NULL), '[]'::json) AS line_items,
    j.job_number AS jobber_job_number,
    v.sync_state
   FROM public.visits v
     LEFT JOIN public.jobs j ON j.id = v.job_id
     LEFT JOIN public.entity_source_links esl ON esl.entity_type = 'job'::text AND esl.source_system = 'jobber'::text AND esl.entity_id = v.job_id
  WHERE v.deleted_at IS NULL;
