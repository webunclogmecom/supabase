-- Rollback of 2026-11-24_1310_note_photo_railway_health.sql (Trello #247): the reverse splices, from the live bodies.
begin;
do $rb$
declare v text; f text;
begin
  v := pg_get_viewdef('public.v_jobber_note_photo_health'::regclass);
  v := replace(v, '(now() - a.last_run_at) > ''02:00:00''::interval', '(now() - a.last_run_at) > ''12:00:00''::interval');
  v := replace(v, '(now() - a.last_full_sweep_at) > ''26:00:00''::interval', '(now() - a.last_full_sweep_at) > ''24:00:00''::interval');
  execute 'create or replace view public.v_jobber_note_photo_health as ' || v;
  f := pg_get_functiondef('public.log_jobber_note_photo_health()'::regprocedure);
  f := replace(f, '(alert at 26h)', '(alert at 24h)');
  f := replace(f, '(alert at 2h; it runs hourly on Railway, service note-photo)', '(alert at 12h)');
  execute f;
  f := pg_get_functiondef('public.log_jobber_sync_health()'::regprocedure);
  f := replace(f,
       E'      -- 2026-11-24 (Trello #247): hourly on Railway (service note-photo); 2 hours = one missed run. The script''s\n'
    || E'      -- own row and the Railway runner''s row (exit code, stderr tail) are both watched.\n'
    || E'      (''jobber_note_photo_sync'',        interval ''2 hours''),\n'
    || E'      (''railway_note_photo'',            interval ''2 hours''),\n',
       E'      -- ⚠ This one runs irregularly by design (max observed gap 731 minutes), so a staleness\n'
    || E'      --    window would be a guess. NULL means "watch it for failures, never for lateness".\n'
    || E'      (''jobber_note_photo_sync'',        null::interval),\n');
  execute f;
end
$rb$;
commit;
