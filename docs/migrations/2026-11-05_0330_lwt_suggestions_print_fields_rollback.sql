-- Rollback of 2026-11-05_0330_lwt_suggestions_print_fields.sql. Run this BEFORE 2026-11-05_rollback_monthly_report_page.sql.
-- A page already live would pick stops with no state or ZIP after this, so roll the page back first.

BEGIN;

SET LOCAL lock_timeout = '3s';

do $splice$
declare
  v_def text := pg_get_functiondef('derm.lwt_stop_suggestions(date,bigint)'::regprocedure);
  a1 text := E'\n           derm.fn_lwt_form_name(c.name) form_name,'
          || E'\n           derm.fn_lwt_form_address(coalesce(p.address, pp.address), coalesce(p.city, pp.city), coalesce(p.state, pp.state), coalesce(p.zip, pp.zip)) form_address,';
  a2 text := E'\n           ''form_name'', form_name, ''form_address'', form_address,';
begin
  if position(a1 in v_def) = 0 or position(a2 in v_def) = 0 then raise exception 'the print fields are not there; nothing to roll back'; end if;
  execute replace(replace(v_def, a1, ''), a2, '');
end $splice$;

drop function derm.fn_lwt_form_address(text, text, text, text);
drop function derm.fn_lwt_form_name(text);

do $verify$
begin
  if md5(pg_get_functiondef('derm.lwt_stop_suggestions(date,bigint)'::regprocedure)) <> '40ac337ca82b40b2e1ff69e4cc8bde06' then
    raise exception 'VERIFY: the body did not return to the one before the migration';
  end if;
end $verify$;

COMMIT;
