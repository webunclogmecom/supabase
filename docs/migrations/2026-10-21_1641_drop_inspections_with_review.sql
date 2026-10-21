-- 2026-10-21_1641 ET · Drop public.inspections_with_review (nothing reads it)
--
-- Fred, 2026-10-21: "Yes, drop public.inspections_with_review: migration with a backup of the view definition, a
-- rollback file, and update the LM11 doc line that names it."
--
-- What it was: a security_invoker view, public.inspections LEFT JOIN public.shift_reviews on (employee_id, shift_date),
-- built for the Admin Review shift queue in May. It is superseded: since 2026-10-21_1553 which PRE and POST make one
-- shift is public.v_inspection_shifts, and joining on inspections.shift_date is the rule that migration says never to use
-- (a night shift's PRE and POST carry different dates).
--
-- Why it can go, measured 2026-10-21 (every check with a control that did find something):
--   * pg_stat_statements, since its reset 2026-10-06: no app statement. The only 7 calls naming it are this session's own
--     revoke and VERIFY at 16:23 ET (2026-10-21_1624). Control v_inspection_shifts: 184 calls.
--   * API gateway logs, 2026-10-14 16:00 to 2026-10-21 16:41 ET: 0 requests out of about 541,000 to /rest/v1/.
--     Control shift_reviews: 51.
--   * pg_depend: no view, rule or function depends on it or on its row type; no function body, view text, policy or
--     cron job names it.
--   * Live bundles of 12 app hosts: 0 references (Admin Review's carries shift_reviews and v_inspection_shifts).
--   * Local repos: only old migrations and audit notes mention it; no code.
--
-- A view holds no data, so nothing is lost. DROP without CASCADE: it refuses if anything came to depend on it, and the
-- guard refuses if the definition changed since it was backed up.
-- Backup: the definition, options, owner and grants are in 2026-10-21_rollback_drop_inspections_with_review.sql
-- (rehearsed: drop then rollback in one transaction gives back the same definition md5, options and grants) and in the
-- workspace backups/2026-10-21_inspections_with_review_view.json.
-- Docs: the readers line of docs/reference/samsara-lm11-level-monitor.md (it was the only reader of
-- inspections.water_gallons). Not a table, so rule 8 (audit) does not apply.

BEGIN;
SET LOCAL lock_timeout = '3s';

do $guard$
begin
  if md5(pg_get_viewdef('public.inspections_with_review'::regclass, true)) <> '8d13b84364c0c09899c14aa1b643b79f' then
    raise exception 'guard: public.inspections_with_review changed since it was backed up; re-read it first';
  end if;
end $guard$;

drop view public.inspections_with_review;

do $verify$
begin
  if to_regclass('public.inspections_with_review') is not null then raise exception 'VERIFY: view still there'; end if;
  if to_regclass('public.inspections') is null or to_regclass('public.shift_reviews') is null then
    raise exception 'VERIFY: a base table is missing';
  end if;
  -- the sibling that replaced it still reads (positive control)
  if (select count(*) from public.v_inspection_shifts) = 0 then raise exception 'VERIFY: v_inspection_shifts reads nothing'; end if;
  raise notice 'VERIFY ok';
end $verify$;

COMMIT;
