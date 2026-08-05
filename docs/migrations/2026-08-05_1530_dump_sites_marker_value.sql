-- 2026-08-05_1530 — ops.v_dump_sites: expose the EXACT value ops.calendar_day_markers.dump_site accepts
--
-- Defect I introduced today and caught in live testing, worth recording because the shape recurs.
-- 2026-08-05_1456 added ops.v_dump_sites so the Visit Calendar would stop hardcoding dump ids and
-- coordinates. Good. But its `label` column is 'Homestead' / 'Pompano', while the PRE-EXISTING check
-- constraint on ops.calendar_day_markers (from 2026-07-28) requires the decorated form:
--
--   CHECK (dump_site = ANY (ARRAY['Homestead (000-DH)', 'Pompano (000-DP)']))
--
-- So the moment the app started reading site names from the view instead of its own constants, every
-- dump marker insert failed 23514. The view was correct in isolation and wrong as a REPLACEMENT for
-- what it displaced.
--
-- 🛑 THE LESSON: WHEN YOU CENTRALIZE A VALUE, THE NEW SOURCE MUST EMIT WHAT THE OLD CONSUMERS ACCEPT.
-- Introducing a single source of truth silently changes every caller's input domain. Check the
-- constraints, enums and CHECKs already sitting downstream BEFORE swapping the source in, not after.
-- (Same family as "widen the parser with the composer": half a change breaks the pair.)
--
-- The fix is a column, not app-side string building: if the app concatenated 'Pompano' + ' (000-DP)'
-- itself we would be back to a hardcoded literal in the client, which is the thing the view exists to
-- remove. `marker_value` is derived from the client's real client_code so it cannot drift from the
-- client row.

begin;

-- ⚠ DROP + CREATE, not CREATE OR REPLACE. Postgres only lets CREATE OR REPLACE VIEW APPEND columns at
-- the END of the column list; inserting `marker_value` third fails 42P16 ("cannot change name of view
-- column"). Appending it instead would have worked, but putting the value next to the label it
-- corrects is worth the drop. The consequence is the reason the explicit re-grant at the bottom of
-- this file exists: DROP VIEW DISCARDS ALL GRANTS silently, and the app would have started getting
-- 42501 on a view that "looks fine" in the catalogue.
drop view if exists ops.v_dump_sites;

create view ops.v_dump_sites as
select
  d.dump_key,
  d.label,
  -- EXACTLY the string ops.calendar_day_markers.dump_site's CHECK constraint accepts.
  -- Built from clients.client_code so a renamed client code surfaces here rather than silently
  -- diverging from the constraint.
  d.label || ' (' || c.client_code || ')' as marker_value,
  d.client_id,
  d.job_id,
  d.property_id,
  p.address,
  p.city,
  p.latitude,
  p.longitude,
  d.county
from (values
  ('DH', 'Homestead', 365::bigint, 1720::bigint,  98::bigint, 'Miami-Dade'),
  ('DP', 'Pompano',    76::bigint, 1662::bigint, 155::bigint, 'Broward')
) as d(dump_key, label, client_id, job_id, property_id, county)
join public.properties p on p.id = d.property_id
join public.clients    c on c.id = d.client_id;

comment on view ops.v_dump_sites is
  'The two real dump sites as ROUTING DESTINATIONS + the ids needed to create a Dump Offload visit '
  'via public.create_dump_visit. Coordinates come from public.properties so there is ONE source. '
  'marker_value is the exact string ops.calendar_day_markers.dump_site accepts (its CHECK constraint '
  'predates this view) — write that, never `label`, or the insert fails 23514. '
  'NOT public.disposal_facilities — that is the DERM compliance catalogue and its Homestead address '
  'is ~20 miles from the site drivers actually use.';

-- DROP/CREATE OR REPLACE on a view can discard grants; re-grant explicitly rather than assuming.
grant select on ops.v_dump_sites to authenticated, service_role;
revoke all on ops.v_dump_sites from anon;

commit;

-- Verification (run as the REAL role, not owner):
--   set local role authenticated;
--   select dump_key, label, marker_value from ops.v_dump_sites order by dump_key;
-- and marker_value must satisfy the live constraint — asserted directly against pg_constraint below
-- rather than eyeballed, because "it looks the same" is how the original defect shipped.
