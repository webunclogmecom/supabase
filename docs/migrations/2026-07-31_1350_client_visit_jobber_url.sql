-- ============================================================================
-- 2026-07-31_1350 — client.visits gains jobber_url (for the visit drawer's
--                   "Open in Jobber" button)
-- ============================================================================
-- ASK (Fred, 2026-07-31): "on the drawer it opens when clicking a visit of a
-- job, add the `Open in Jobber` button".
--
-- ⚠ THE LINK IS THE VISIT'S **JOB**, NOT THE VISIT — measured, not assumed.
-- Visits DO have their own Jobber GID (gid://Jobber/Visit/<n>, 1,260 linked),
-- but Jobber has no per-visit page: the constructed
-- /work_orders/<job>/visits/<visit> URL returns a real 404, and a Jobber job
-- page contains ZERO per-visit anchors (visits render inline). The Visit
-- Calendar reached the same conclusion — `ops.v_calendar_visit_detail` builds
-- only `jobber_job_url`. So this column deliberately resolves the visit's JOB,
-- which is where a human can actually see and act on that visit.
-- Do NOT "fix" this later by pointing it at the visit GID; it 404s.
--
-- Derivation matches 2026-07-31_1035 (defensive decode: two legacy job links
-- stored a RAW NUMERIC source_id, and a bare decode() raised 22023 across the
-- whole view scan — those 8 rows were removed in 2026-07-31_1119, but the
-- format-tolerant branch stays so a future numeric row cannot break the view).
--
-- 3NF / Rule 1: derived in the view from entity_source_links, nothing stored.
-- Audit (ADR 010): no table change. Grants: CREATE OR REPLACE VIEW preserves
-- the existing ACLs (client.visits is authenticated-readable).
-- ROLLBACK: re-create client.visits from git (it is `select ... from
--   public.v_visits_live` plus this one derived column).
-- ============================================================================

begin;

create or replace view client.visits as
select v.id, v.client_id, v.property_id, v.job_id, v.vehicle_id, v.visit_date,
       v.start_at, v.end_at, v.completed_at, v.duration_minutes, v.title,
       v.service_type, v.visit_status, v.actual_arrival_at, v.actual_departure_at,
       v.is_gps_confirmed, v.created_at, v.updated_at, v.invoice_id, v.completed_by,
       v.source, v.manhole_count, v.manhole_breakdown, v.ticket_number,
       v.trap_condition_notes, v.derm_required, v.public_id, v.deleted_at,
       v.service_line_item_id, v.notes,
       (select case
            when l.source_id ~ '^[0-9]+$'
              then 'https://secure.getjobber.com/work_orders/' || l.source_id
            when length(l.source_id) % 4 = 0 and l.source_id ~ '^[A-Za-z0-9+/]+={0,2}$'
              then 'https://secure.getjobber.com/work_orders/' ||
                   split_part(convert_from(decode(l.source_id, 'base64'), 'UTF8'), '/', -1)
          end
          from public.entity_source_links l
         where l.entity_type = 'job' and l.source_system = 'jobber'
           and l.entity_id = v.job_id
         limit 1) as jobber_url
from public.v_visits_live v;

commit;
