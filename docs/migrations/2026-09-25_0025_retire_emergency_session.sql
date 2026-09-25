-- =====================================================================================================
-- 2026-09-25_0025  Remove the emergency-session leftovers (the 2026-08-31 no-login "Default" mode)
-- =====================================================================================================
-- Fred: "yes, remove the emergency-session leftovers".
--
-- During the 2026-08-31 Supabase Auth outage the edge fn emergency-session minted short `authenticated`
-- tokens for a shared "Default" identity (spec docs/specs/2026-08-31-emergency-default-user-access.md).
-- The window closed 2026-09-01 10:11 ET and the function is no longer deployed, but its machinery was
-- still in place: the edge secret holding the project JWT secret, the source with a verify_jwt=false
-- entry (a bulk deploy would have put it back online), and these database pieces. This migration:
--   * drops public.emergency_whoami(), the mode's diagnostic (it echoed the caller's JWT claims; EXECUTE
--     to authenticated). Nothing calls it: 0 functions, 0 views, 0 live app bundles name it.
--   * deletes public.app_config 'emergency_access_until' (the window switch, '2000-01-01' = closed). Only
--     the removed edge fn read it (app_config is audited, so the delete is on record).
--   * KEEPS public.emergency_session_grants, the ledger of the window (85 requests, 70 grants, with IPs and
--     user agents): it is the only record of who used emergency access. Frozen: service_role loses INSERT,
--     UPDATE, DELETE and TRUNCATE, so nothing can add to it; SELECT stays (service_role, yannick_readonly).
--     Its audit trigger stays.
-- The same change unsets the edge secrets EMERGENCY_PASSPHRASE and EMERGENCY_JWT_SECRET and removes the
-- source and config.toml entry. NOT changed: the six apps (Hub, Admin, Client App, Calendar, DERM, Stamp)
-- still carry the dormant bootstrap that POSTs to emergency-session on load and carries on when it is
-- refused (today a 404): reported to Fred.
-- Rule 8: no new table; the ledger keeps its audit trigger.
-- ROLLBACK: git history (the 2026-08-31_1300 / _1400 migrations, the function source) plus re-granting the
-- ledger; the secrets would have to be set again by hand.
-- =====================================================================================================

begin;

do $$
begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname not in ('pg_catalog', 'information_schema')
                and p.proname <> 'emergency_whoami'
                and p.prosrc ~* 'emergency_whoami|emergency_access_until|emergency_session_grants')
     or exists (select 1 from pg_views where definition ~* 'emergency_whoami|emergency_access_until|emergency_session_grants') then
    raise exception 'something in the database still uses the emergency mode';
  end if;
  if (select value from public.app_config where key = 'emergency_access_until') is distinct from '2000-01-01' then
    raise exception 'the emergency window is not the closed value this migration expects';
  end if;
end $$;

drop function public.emergency_whoami();
delete from public.app_config where key = 'emergency_access_until';
revoke insert, update, delete, truncate on public.emergency_session_grants from service_role;
comment on table public.emergency_session_grants is
  'FROZEN RECORD (2026-09-25_0025): the ledger of the 2026-08-31 / 09-01 emergency "Default" access window (edge fn emergency-session, retired). Nothing writes it any more; kept as the only record of who used emergency access. Read only.';

do $verify$
begin
  if exists (select 1 from pg_proc where proname = 'emergency_whoami') then raise exception 'VERIFY whoami'; end if;
  if exists (select 1 from public.app_config where key = 'emergency_access_until') then raise exception 'VERIFY config key'; end if;
  if has_table_privilege('service_role', 'public.emergency_session_grants', 'INSERT')
     or has_table_privilege('service_role', 'public.emergency_session_grants', 'UPDATE')
     or has_table_privilege('service_role', 'public.emergency_session_grants', 'DELETE')
     or has_table_privilege('authenticated', 'public.emergency_session_grants', 'SELECT')
     or not has_table_privilege('service_role', 'public.emergency_session_grants', 'SELECT') then
    raise exception 'VERIFY ledger grants';
  end if;
  if (select count(*) from public.emergency_session_grants) <> 85 then raise exception 'VERIFY ledger rows'; end if;
end
$verify$;

commit;
