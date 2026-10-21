-- 2026-10-21 19:20 ET · Access: the Calendar's last direct write grant removed (ops.calendar_day_markers.dump_visit_id)
--
-- Fred, 2026-10-21: "go ahead with all recommended" (plan Building Apps/HR App/docs/specs/
-- 2026-10-21-access-switch-on-and-invite-plan.md). The day marker's dump link moved behind ops.link_day_marker_dump_visit
-- (access phase 5, checked as Visit Calendar Edit). The Visit Calendar went on at 19:05:10 (2026-10-21_1900) and its live
-- check passed; this was the one planned revoke it listed.
-- Measured first: the live Calendar bundle has no direct write to calendar_day_markers (its only direct writes are zones,
-- checked by trigger aa_access_zones); pg_stat_statements (since 2026-10-06) holds no UPDATE of dump_visit_id other than
-- through link_day_marker_dump_visit. The table has no audit trigger, so audit.logs could not answer this.
-- Undo: grant update (dump_visit_id) on ops.calendar_day_markers to authenticated;

BEGIN;

revoke update (dump_visit_id) on ops.calendar_day_markers from authenticated;

do $verify$
begin
  if has_column_privilege('authenticated', 'ops.calendar_day_markers', 'dump_visit_id', 'UPDATE') then
    raise exception 'VERIFY: authenticated can still update calendar_day_markers.dump_visit_id';
  end if;
  if not has_function_privilege('authenticated', 'ops.link_day_marker_dump_visit(bigint, bigint)', 'EXECUTE') then
    raise exception 'VERIFY: the Calendar lost its sanctioned path ops.link_day_marker_dump_visit';
  end if;
  raise notice 'VERIFY ok';
end $verify$;

COMMIT;
