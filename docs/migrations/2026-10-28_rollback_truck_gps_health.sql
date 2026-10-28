-- Rollback for 2026-10-28_1010_truck_gps_health.sql: the two health views back to their live bodies (verbatim),
-- then the cron job and the logger dropped. Old sync_log rows of truck-gps-health stay (they are history).
begin;
set local lock_timeout = '3s';
CREATE OR REPLACE VIEW ops.v_health_items AS
 WITH latest AS (
         SELECT DISTINCT ON (l.sync_source) l.sync_source,
            l.status,
            l.started_at,
            l.details
           FROM sync_log l
          WHERE l.sync_source = ANY (ARRAY['calendar-push-health'::text, 'blackout-health'::text, 'rpa-derm-health'::text, 'sa-schedule-gap-check'::text, 'jobber-sync-health'::text, 'note-photo-sync-health'::text, 'jobber-client-state-sweep'::text, 'start-flags-health'::text, 'db-backup-health'::text, 'notification-health'::text, 'samsara-feed-health'::text, 'hr-bonus-health'::text, 'trap-size-health'::text, 'access-health'::text])
          ORDER BY l.sync_source, l.started_at DESC
        )
 SELECT la.sync_source AS check_name,
    la.status,
    la.started_at AS last_run_at,
    COALESCE(i.value ->> 'visit_id'::text, i.value ->> 'dump_folder'::text, i.value ->> 'kind'::text, i.value ->> 'client_code'::text, i.value::text) AS item_key,
    i.value AS item
   FROM latest la
     CROSS JOIN LATERAL jsonb_array_elements(
        CASE la.sync_source
            WHEN 'calendar-push-health'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            WHEN 'blackout-health'::text THEN COALESCE(la.details -> 'sheets'::text, '[]'::jsonb)
            WHEN 'rpa-derm-health'::text THEN COALESCE(la.details -> 'reasons'::text, '[]'::jsonb)
            WHEN 'sa-schedule-gap-check'::text THEN COALESCE(la.details -> 'sample'::text, '[]'::jsonb)
            WHEN 'jobber-sync-health'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            WHEN 'note-photo-sync-health'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            WHEN 'jobber-client-state-sweep'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            WHEN 'start-flags-health'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            WHEN 'db-backup-health'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            WHEN 'notification-health'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            WHEN 'samsara-feed-health'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            WHEN 'hr-bonus-health'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            WHEN 'trap-size-health'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            WHEN 'access-health'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            ELSE '[]'::jsonb
        END) i(value);
CREATE OR REPLACE VIEW ops.v_health_status AS
 WITH runs AS (
         SELECT l.id,
            l.sync_source,
            l.status,
            l.started_at,
            l.rows_errored,
            l.details,
            row_number() OVER (PARTITION BY l.sync_source ORDER BY l.started_at DESC) AS rn,
                CASE l.sync_source
                    WHEN 'calendar-push-health'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    WHEN 'blackout-health'::text THEN COALESCE(l.details -> 'sheets'::text, '[]'::jsonb)
                    WHEN 'rpa-derm-health'::text THEN COALESCE(l.details -> 'reasons'::text, '[]'::jsonb)
                    WHEN 'sa-schedule-gap-check'::text THEN COALESCE(l.details -> 'sample'::text, '[]'::jsonb)
                    WHEN 'jobber-sync-health'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    WHEN 'jobber-client-state-sweep'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    WHEN 'start-flags-health'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    WHEN 'note-photo-sync-health'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    WHEN 'db-backup-health'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    WHEN 'notification-health'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    WHEN 'samsara-feed-health'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    WHEN 'hr-bonus-health'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    WHEN 'trap-size-health'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    WHEN 'access-health'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    ELSE '[]'::jsonb
                END AS raw_items
           FROM sync_log l
          WHERE l.sync_source = ANY (ARRAY['calendar-push-health'::text, 'blackout-health'::text, 'rpa-derm-health'::text, 'sa-schedule-gap-check'::text, 'jobber-sync-health'::text, 'jobber-client-state-sweep'::text, 'start-flags-health'::text, 'note-photo-sync-health'::text, 'db-backup-health'::text, 'notification-health'::text, 'samsara-feed-health'::text, 'hr-bonus-health'::text, 'trap-size-health'::text, 'access-health'::text])
        ), keyed AS (
         SELECT r.id,
            r.sync_source,
            r.status,
            r.started_at,
            r.rows_errored,
            r.details,
            r.rn,
            r.raw_items,
            COALESCE(( SELECT jsonb_agg(DISTINCT COALESCE(i.value ->> 'visit_id'::text, i.value ->> 'dump_folder'::text, i.value ->> 'kind'::text, i.value ->> 'client_code'::text, i.value::text)) AS jsonb_agg
                   FROM jsonb_array_elements(r.raw_items) i(value)), '[]'::jsonb) AS item_keys
           FROM runs r
          WHERE r.rn <= 2
        ), streak AS (
         SELECT g.sync_source,
            g.status,
            count(*) AS runs_in_streak,
            min(g.started_at) AS streak_started_at
           FROM ( SELECT l.sync_source,
                    l.status,
                    l.started_at,
                    row_number() OVER (PARTITION BY l.sync_source ORDER BY l.started_at DESC) - row_number() OVER (PARTITION BY l.sync_source, l.status ORDER BY l.started_at DESC) AS grp
                   FROM sync_log l
                  WHERE l.sync_source = ANY (ARRAY['calendar-push-health'::text, 'blackout-health'::text, 'rpa-derm-health'::text, 'sa-schedule-gap-check'::text, 'jobber-sync-health'::text, 'jobber-client-state-sweep'::text, 'start-flags-health'::text, 'note-photo-sync-health'::text, 'db-backup-health'::text, 'notification-health'::text, 'samsara-feed-health'::text, 'hr-bonus-health'::text, 'trap-size-health'::text, 'access-health'::text])) g
          GROUP BY g.sync_source, g.status, g.grp
         HAVING max(g.started_at) = (( SELECT max(l2.started_at) AS max
                   FROM sync_log l2
                  WHERE l2.sync_source = g.sync_source))
        ), cur AS (
         SELECT keyed.id,
            keyed.sync_source,
            keyed.status,
            keyed.started_at,
            keyed.rows_errored,
            keyed.details,
            keyed.rn,
            keyed.raw_items,
            keyed.item_keys
           FROM keyed
          WHERE keyed.rn = 1
        ), prev AS (
         SELECT keyed.id,
            keyed.sync_source,
            keyed.status,
            keyed.started_at,
            keyed.rows_errored,
            keyed.details,
            keyed.rn,
            keyed.raw_items,
            keyed.item_keys
           FROM keyed
          WHERE keyed.rn = 2
        )
 SELECT c.sync_source AS check_name,
    c.status,
    c.started_at AS last_run_at,
    jsonb_array_length(c.item_keys) AS item_count,
    COALESCE(jsonb_array_length(p.item_keys), 0) AS item_count_previous_run,
    c.rows_errored AS rows_errored_raw,
    ( SELECT COALESCE(jsonb_agg(k.value), '[]'::jsonb) AS "coalesce"
           FROM jsonb_array_elements(c.item_keys) k(value)
          WHERE NOT COALESCE(p.item_keys, '[]'::jsonb) @> jsonb_build_array(k.value)) AS new_items,
    ( SELECT COALESCE(jsonb_agg(k.value), '[]'::jsonb) AS "coalesce"
           FROM jsonb_array_elements(COALESCE(p.item_keys, '[]'::jsonb)) k(value)
          WHERE NOT c.item_keys @> jsonb_build_array(k.value)) AS resolved_items,
    c.item_keys = COALESCE(p.item_keys, '[]'::jsonb) AS unchanged_since_last_run,
    s.runs_in_streak AS consecutive_runs_same_status,
    s.streak_started_at AS status_since,
    c.details
   FROM cur c
     LEFT JOIN prev p ON p.sync_source = c.sync_source
     LEFT JOIN streak s ON s.sync_source = c.sync_source AND s.status = c.status;
select cron.unschedule('truck-gps-health') where exists (select 1 from cron.job where jobname = 'truck-gps-health');
drop function if exists public.log_truck_gps_health();
do $v$ begin
  if md5(pg_get_viewdef('ops.v_health_items'::regclass, true)) <> 'be48923e4befe72d082b674535095c33'
  or md5(pg_get_viewdef('ops.v_health_status'::regclass, true)) <> '9eafbcb43fbc54472762c242f704a246' then
    raise exception 'rollback: view bodies are not the pre-2026-10-28_1010 ones';
  end if;
end $v$;
commit;
