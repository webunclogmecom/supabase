-- Rollback of 2026-11-05_0245_monthly_report_page.sql. Puts hr.check_app_action back and drops the three functions.
-- Run the edge function's undeploy first (or accept that lwt-monthly answers 503 on its access check).
-- The bucket lwt-monthly-work is left in place on purpose: it may hold someone's work in progress. Empty it and remove
-- it from the Storage page only if you mean to lose that work.

BEGIN;

SET LOCAL lock_timeout = '3s';

do $unsplice$
declare v_def text := pg_get_functiondef('hr.check_app_action(text)'::regprocedure);
  v_new text := E'\n                 (''lwt_monthly_view'',             array[''derm_tracker''], ''view''),   -- 2026-11-05_0245: the Monthly Report page'
             || E'\n                 (''lwt_monthly_edit'',             array[''derm_tracker''], ''edit''),   -- 2026-11-05_0245';
begin
  if (length(v_def) - length(replace(v_def, v_new, ''))) / length(v_new) <> 1 then raise exception 'lines not found once; re-read the live body'; end if;
  execute replace(v_def, v_new, '');
  if md5(pg_get_functiondef('hr.check_app_action(text)'::regprocedure)) <> '2d6fe7a461fc3acbcba0eb73a3ea2342' then
    raise exception 'hr.check_app_action is not back to its previous body';
  end if;
end $unsplice$;

drop function derm.lwt_board(text[], date, date);
drop function derm.lwt_stop_suggestions(date, bigint);
drop function derm.lwt_save_trap_size(bigint, integer);

COMMIT;
