-- 2026-08-17_1200_dump_marker_visit_link_and_cleanup.sql
--
-- WHY -----------------------------------------------------------------------------------------
-- Fred, 2026-08-17: "fix the vehicle_id and make marker delete remove the orphan visit."
--
-- The Dump-marker smoke test earlier today (write-up:
-- docs/reference/calendar-day-markers.md) measured two defects:
--
--   1. The Calendar hardcodes `p_vehicle_id: null` in its create_dump_visit call, so a dump visit
--      never carries its truck and is invisible on the truck board it was created from. That half
--      is an APP fix (Lovable project 6533c3ee) and is NOT in this migration.
--   2. Deleting a Dump marker removed the marker, its entity_source_links row and its Jobber Task
--      but LEFT the created public.visits row alive and scheduled — an orphan Dump Offload visit
--      that a truck-filtered board will not show you. That is what this migration fixes.
--
-- WHAT ----------------------------------------------------------------------------------------
--   a) ops.calendar_day_markers gains `dump_visit_id` — the visit a Dump marker created.
--   b) AFTER DELETE trigger soft-deletes that visit, but ONLY when it is still safe to.
--
-- WHY A STORED LINK AND NOT A MATCH ------------------------------------------------------------
-- The obvious alternative is to find the visit at delete time by (marker_date, dump-site client,
-- start_at = the marker minute, source, status). That is a heuristic, and its failure mode is
-- deleting ANOTHER TRUCK'S dump visit when two trucks dump at the same site in the same minute —
-- which is legal today, because the unique index on this table covers only start/end markers.
-- A stored id makes the wrong deletion impossible instead of unlikely.
--
-- THE GUARD, AND WHY IT FAILS SAFE -------------------------------------------------------------
-- The trigger soft-deletes only when the linked visit is `visit_status = 'scheduled'` AND
-- `source = 'manual'` AND `deleted_at IS NULL`.
--   * `scheduled`  -> a dump the crew already COMPLETED is a real business record. Never delete it.
--   * `manual`     -> that is what create_dump_visit stamps when p_push_to_jobber = false. Anything
--                     Jobber-sourced is out of scope by construction.
--   * not deleted  -> idempotent; a second delete is a no-op, never an error.
-- Every excluded case leaves the visit ALIVE. The failure direction is "an orphan survives", never
-- "a real record was destroyed".
--
-- SECURITY DEFINER IS DELIBERATE ---------------------------------------------------------------
-- `authenticated` cannot write the visit lifecycle directly (Phase 3, 2026-07-11) — that is exactly
-- why the cleanup cannot live in the app. postgres holds rolbypassrls and public.visits has RLS
-- ENABLED AND FORCED, so this function does widen reach; the guard above is the control on that
-- widening, and the probe below exercises it. search_path is pinned (CLAUDE.md).
--
-- IT DOES NOT CALL public.delete_calendar_visit ON PURPOSE ------------------------------------
-- That function RAISES when it finds no undeleted row. Our guard means "sometimes correctly do
-- nothing", which must not abort the user's marker delete. So it is a guarded UPDATE instead.
--
-- NO SPURIOUS JOBBER PUSH ---------------------------------------------------------------------
-- fn_push_marker_to_jobber fires on UPDATE too, but its guard compares only marker_date,
-- marker_type, minutes, vehicle_id and dump_site. `dump_visit_id` is not in that list, so the app
-- writing the back-link does NOT trigger a Jobber round-trip. Verified by reading the body.
--
-- AUDIT (rule #8) -----------------------------------------------------------------------------
-- ops.calendar_day_markers stays audit OPT-OUT — unchanged, it is dispatch state, not business
-- data. public.visits IS audited, so the soft-delete this trigger performs is captured in
-- audit.logs with old_row intact and is therefore recoverable.
--
-- FIRING ORDER --------------------------------------------------------------------------------
-- Triggers fire alphabetically. `trg_push_marker_to_jobber` < `trg_zz_dump_visit_cleanup`, so the
-- Jobber Task delete runs first and the visit cleanup last. They touch different objects so the
-- order is not load-bearing today; the name pins it anyway. Renaming either is a breaking change.

begin;

-- (a) the link -----------------------------------------------------------------------------------
alter table ops.calendar_day_markers
  add column if not exists dump_visit_id bigint
    references public.visits(id) on delete set null;

comment on column ops.calendar_day_markers.dump_visit_id is
  'The public.visits row this DUMP marker created via public.create_dump_visit. NULL for start/end '
  'markers, and NULL for dump markers placed before 2026-08-17 (they predate the link and their '
  'visits must be cleaned up by hand). Read by trg_zz_dump_visit_cleanup on DELETE.';

-- (b) the cleanup --------------------------------------------------------------------------------
create or replace function ops.fn_cleanup_dump_visit_on_marker_delete()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_rows int;
begin
  -- Not a dump marker, or placed before the link existed: nothing to do.
  if old.marker_type is distinct from 'dump' or old.dump_visit_id is null then
    return old;
  end if;

  -- Guarded soft-delete. Every predicate here is a REASON NOT TO DELETE; see the migration header.
  update public.visits
     set deleted_at = now()
   where id            = old.dump_visit_id
     and deleted_at   is null
     and visit_status  = 'scheduled'
     and source        = 'manual';

  get diagnostics v_rows = row_count;

  -- Deliberately a NOTICE, not an exception: "the visit was completed, so I left it" is a correct
  -- outcome, not a failure, and it must never abort the marker delete the user asked for.
  if v_rows = 0 then
    raise notice 'dump marker % deleted; linked visit % left alone (already deleted, not scheduled, or not manual)',
      old.id, old.dump_visit_id;
  end if;

  return old;
end;
$function$;

revoke all on function ops.fn_cleanup_dump_visit_on_marker_delete() from public;

drop trigger if exists trg_zz_dump_visit_cleanup on ops.calendar_day_markers;
create trigger trg_zz_dump_visit_cleanup
  after delete on ops.calendar_day_markers
  for each row execute function ops.fn_cleanup_dump_visit_on_marker_delete();

commit;
