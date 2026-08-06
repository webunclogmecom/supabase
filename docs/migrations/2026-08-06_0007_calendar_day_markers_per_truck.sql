-- 2026-08-06_0007 — ops.calendar_day_markers goes PER-TRUCK, and gains a Jobber Task link
--
-- Fred: "go with per-truck markers, add the column and push to jobber."
--
-- ⚠ THIS REVERSES A RECORDED DECISION. On 2026-07-28 a per-truck marker model was mocked up, offered
-- to Fred, and REJECTED — "keep the route markers per-day as they are now" — and that is written into
-- Building Apps/Visit Calendar/CLAUDE.md. He has now asked for the opposite. The app doc is updated in
-- the same cycle; do not "restore" per-day on the strength of the older note.
--
-- WHY A TRUCK DIMENSION IS NEEDED NOW: the markers are being pushed to Jobber as **Tasks**, and a
-- Jobber Task carries `assignedTo`. A day-scoped marker has nobody to assign. Per-truck is what makes
-- "Moises leaves the yard at 06:00" expressible on the crew's own schedule.
--
-- WHY TASKS AND NOT EVENTS (measured against the live Jobber API 2026-04-16, and it contradicts
-- Jobber AI, which recommended Events):
--   mutations available:  taskCreate / taskEdit / taskDelete   vs   eventCreate ONLY
-- Markers get dragged and deleted. With Events, every move would strand an un-editable, un-deletable
-- ghost on the crew's schedule forever. That alone settles it. Additionally Jobber AI itself notes an
-- Event is "not a true single-person assignment ... visible to all team members", which cannot express
-- a per-truck day start. And the crew ALREADY uses Tasks this way: 11 this week, 7 with no client,
-- assigned to Aaron / Mark / Grecia, with real start/end times.
--
-- 🛑 AUDIT: opt-out, consistent with the table's original 2026-07-28 decision. These are scheduling
-- annotations, not business records; they touch no customer.*, billing, DERM or webhook-secret data.
-- ⚠ CONSEQUENCE (unchanged, restated because it is load-bearing): there is NO audit trigger here, so
-- `audit.logs` silence proves NOTHING about whether this table is used. Do not revoke its grants on
-- that basis — the Visit Calendar is the writer.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. The truck dimension
-- ─────────────────────────────────────────────────────────────────────────────
-- NULL is a legitimate value and means "the whole day, not a specific truck" — the shape every
-- existing marker would have had. It is NOT a missing value to be backfilled away.
alter table ops.calendar_day_markers
  add column if not exists vehicle_id bigint references public.vehicles(id);

comment on column ops.calendar_day_markers.vehicle_id is
  'The truck this marker belongs to (public.vehicles). NULL = a day-wide marker not tied to a truck, '
  'which is what every marker was before 2026-08-06. Per-truck was Fred''s reversal of the 2026-07-28 '
  'per-day decision, needed because a Jobber Task carries assignedTo.';

create index if not exists calendar_day_markers_vehicle_date_idx
  on ops.calendar_day_markers (vehicle_id, marker_date);

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Reshape the uniqueness rule
-- ─────────────────────────────────────────────────────────────────────────────
-- Was: one 'start' and one 'end' per DATE. Now: one of each per (DATE, TRUCK).
--
-- 🛑 `NULLS NOT DISTINCT` IS THE WHOLE POINT OF THIS STATEMENT, NOT A FLOURISH.
-- A plain unique index treats every NULL as distinct from every other NULL, so with a nullable
-- vehicle_id the day-wide marker — precisely the shape that exists today — could be inserted an
-- unlimited number of times and the app's delete-then-insert "re-drop replaces" behaviour would
-- silently start stacking duplicates instead of moving one marker. PG 15+ required; Prod is 17.6.
drop index if exists ops.calendar_day_markers_start_end_uniq;

create unique index calendar_day_markers_start_end_uniq
  on ops.calendar_day_markers (marker_date, vehicle_id, marker_type)
  nulls not distinct
  where marker_type in ('start','end');

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Where the Jobber Task id lives
-- ─────────────────────────────────────────────────────────────────────────────
-- 🛑 NO `jobber_task_id` COLUMN. Supabase CLAUDE.md rule #1 is absolute: zero source-prefixed columns
-- on any business table; cross-system identity lives in public.entity_source_links. This is the same
-- bridge that already holds 1,292 visit links and 1,798 job links.
--   entity_type = 'calendar_day_marker'
--   entity_id   = ops.calendar_day_markers.id
--   source_system = 'jobber'
--   source_id   = the Jobber Task GID  (gid://Jobber/Task/<id>)
-- Nothing to create here — the bridge is polymorphic and already accepts this. Recorded so the next
-- reader does not go looking for a column.

commit;

-- Verification run after apply, AS THE REAL ROLE (`set local role authenticated`), never as owner —
-- owner-rights testing hides exactly the 42501 that grants exist to prevent:
--   * a second 'start' for the SAME (date, truck) must fail 23505
--   * a second 'start' for the same date but a DIFFERENT truck must SUCCEED
--   * a second day-wide 'start' (vehicle_id NULL) for the same date must fail 23505  <- nulls not distinct
--   * 'dump' remains repeatable
-- All four asserted; the third is the one a plain unique index would silently allow.
