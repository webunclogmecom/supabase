-- Retire service_configs, part 2 of 2: DROP the table and its two wrapper views
--
-- Fred, 2026-10-02: "these 'service configs' should be removed", then "go ahead and build".
-- Part 1 (2026-10-02_1414_retire_service_configs_readers) moved all 13 reading views to
-- public.v_client_agreement_services and save-client-property v13 stopped counting it.
--
-- Measured before this file (2026-10-05):
--   * only client.service_configs and ops.service_configs (thin select-* wrappers) depend on it;
--     no app bundle names any of the three (10 live apps scanned 2026-10-02)
--   * 0 writes since 2026-07-14, 0 reads since part 1 (pg_stat_user_tables last scan 2026-10-02 18:13 UTC)
--   * no inbound foreign keys; no function reads it (client.update_property_capacity names it in a comment)
-- Backup: backups/2026-10-05_service_configs_final_backup.json (263 rows, columns, constraints,
-- indexes, triggers, ACL, both wrapper view definitions, restore hint). The table's audit trigger
-- does NOT record a DROP, so that file is the restore path.
--
-- Plain DROP, no CASCADE: anything that still depends on it makes this fail instead of vanishing.
-- Not dropped here, still referencing it in code (dead paths, noted in docs):
--   scripts/sync/cron_generate_recurring_visits.js (workflow schedule paused since 2026-06-02;
--   generation moved to public.fn_generate_sa_visits), scripts/populate/populate.js (legacy full load).

begin;

drop view client.service_configs;
drop view ops.service_configs;
drop table public.service_configs;

do $verify$
begin
  if to_regclass('public.service_configs') is not null
     or to_regclass('client.service_configs') is not null
     or to_regclass('ops.service_configs') is not null then
    raise exception 'VERIFY something survived';
  end if;
  if to_regclass('public.v_client_agreement_services') is null then
    raise exception 'VERIFY the replacement view is missing';
  end if;
end $verify$;

commit;
