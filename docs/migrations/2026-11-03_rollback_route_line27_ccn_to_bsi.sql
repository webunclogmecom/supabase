-- ROLLBACK of 2026-11-03_1830_route_line27_ccn_to_bsi: the three bodies go back to their pre-1830 text (reverse
-- anchored edits; md5 asserted equal to the pins the migration started from), then the rule is dropped.
-- ⚠ Once any Boca Raton job carries line 27, undoing this puts those visits back in the DERM queue as no_permit and
-- back in the daily health email: take line 27 off those jobs first, or accept the noise.
-- ORDER (added 2026-11-03 ~20:50 ET): this file fails on its own now. Run 2026-11-03_rollback_route_line27_alerts.sql,
-- then 2026-11-03_rollback_route_line27_followups.sql, then this one: since _1848 derm.gdo_report_status calls the rule
-- this file drops, and the logger pin below matches only the pre-_1848 body. Rehearsed as one chain, undone.
begin;
set local lock_timeout = '3s';
set local search_path = public, extensions;

do $undo$
declare d text; a text; b text;
begin
  d := rtrim(btrim(pg_get_viewdef('public.v_derm_portal_fields'::regclass, false)), ';');
  a := ' AND (NOT fn_client_files_with_bsi(v.client_id)))';
  b := ')';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'rollback: fields clause not found once'; end if;
  execute 'create or replace view public.v_derm_portal_fields as ' || replace(d, a, b);

  d := rtrim(btrim(pg_get_viewdef('public.v_gdo_reporting_derm_mismatch'::regclass, false)), ';');
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'rollback: mismatch clause not found once'; end if;
  execute 'create or replace view public.v_gdo_reporting_derm_mismatch as ' || replace(d, a, b);

  d := pg_get_functiondef('public.log_rpa_derm_health()'::regprocedure);
  a := E'             and not public.fn_client_files_with_bsi(c.id)   -- 2026-11-03_1830: a Boca Raton client files with BSI\n';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'rollback: health clause not found once'; end if;
  execute replace(d, a, '');
end $undo$;

drop function public.fn_client_files_with_bsi(bigint);

do $verify$
begin
  if md5(pg_get_viewdef('public.v_derm_portal_fields'::regclass, false)) <> 'e6b1167b167d0fc07cb40262f512dc94'
     or md5(pg_get_viewdef('public.v_gdo_reporting_derm_mismatch'::regclass, false)) <> '824b66ccdcbe9e6bf4f50ad63470ce94'
     or md5((select prosrc from pg_proc where oid = 'public.log_rpa_derm_health()'::regprocedure)) <> '7fab5d6618275c287dbdb4ed2eaad41f' then
    raise exception 'rollback VERIFY: a body is not back to its pre-1830 text';
  end if;
end $verify$;

commit;
