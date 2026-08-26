-- 2026-08-26_1815_lwt_filings_lock_down.sql
--
-- Make the append-only claim TRUE. It was written down in four places today and was never
-- implemented.
--
-- Rule 8 (audit opt-in): public.lwt_filings and public.lwt_filing_tickets ARE audited by this
-- migration. They are the record of what we told Miami-Dade, so opting out was never defensible.
-- The originating migration (2026-08-26_1615) stated neither an opt-in nor an opt-out, which is
-- itself the rule-8 violation.
--
-- WHAT WENT WRONG IN 2026-08-26_1615
-- It wrote `REVOKE ALL ... FROM PUBLIC` and then `GRANT SELECT, INSERT`. That reads like
-- hardening and is not: `CREATE TABLE` had already handed out full privileges via Supabase's
-- ALTER DEFAULT PRIVILEGES, and a REVOKE aimed at the PUBLIC pseudo-role does not touch a grant
-- held by a named role. So the GRANTs added nothing and the REVOKE removed nothing.
-- This is the same defect as public.job_frequency_changes (fixed 2026-08-07), recurring verbatim
-- on a compliance table. The GRANT lines in 1615 are correct and are deliberately not rewritten
-- here; what was missing is the REVOKE against the NAMED roles.
--
-- MEASURED BEFORE (both tables):
--   authenticated  SELECT+ INSERT+ UPDATE+ DELETE+ TRUNCATE+   rls=false   0 audit triggers
--   service_role   SELECT+ INSERT+ UPDATE+ DELETE+ TRUNCATE+
--   anon           nothing                                     <- this half was always correct
-- The sibling this design copied, public.derm_portal_submissions:
--   authenticated  nothing                                     rls=true    2 triggers
--
-- COST OF LEAVING IT: any signed-in staff browser could PATCH or DELETE a county filing record
-- straight through PostgREST. lwt_filing_tickets.filing_id is ON DELETE CASCADE, so deleting one
-- header row silently re-queues every ticket on it for a second filing with Miami-Dade.
-- Exposure was prospective, not realised: 2 rows existed, both dry_run, 0 real filings.
--
-- SAFE TO REVOKE, checked rather than assumed:
--   * derm.v_lwt_ticket_reported is NOT security_invoker and is owned by postgres, so it reads as
--     its owner. authenticated keeps SELECT on the view and loses nothing it actually uses.
--   * The Building Apps repos reference these tables 0 times (positive control: the same search
--     finds derm_manifests/visit_locations 328 times across 60 files, so the zero is real).
--     Audit silence could NOT have told us this: neither table has ever had an audit trigger, so
--     an empty audit.logs is a false all-clear here by construction.
--   * rpa-derm-monthly-filed contains no .update(, .delete( or .upsert(, so revoking UPDATE and
--     DELETE from service_role cannot break it.
--   * service_role has rolbypassrls = true, so enabling RLS cannot break the endpoint either.

begin;

-- 1. authenticated loses everything, matching derm_portal_submissions. Apps read the view.
revoke all on public.lwt_filings        from authenticated;
revoke all on public.lwt_filing_tickets from authenticated;

-- 2. service_role keeps exactly what the endpoint uses, so "append-only" becomes a grant and not
--    a branch, which is what we told the bot developer in writing.
revoke update, delete, truncate on public.lwt_filings        from service_role;
revoke update, delete, truncate on public.lwt_filing_tickets from service_role;
grant  select, insert            on public.lwt_filings        to service_role;
grant  select, insert            on public.lwt_filing_tickets to service_role;

-- 3. Defence in depth. service_role bypasses RLS; this closes the direct-table path for anyone
--    who is not service_role, so a future accidental GRANT does not silently reopen the table.
alter table public.lwt_filings        enable row level security;
alter table public.lwt_filing_tickets enable row level security;

-- 4. Audit, exactly as public.derm_portal_submissions does it.
drop trigger if exists audit_lwt_filings        on public.lwt_filings;
drop trigger if exists audit_lwt_filing_tickets on public.lwt_filing_tickets;
create trigger audit_lwt_filings
  after insert or delete or update on public.lwt_filings
  for each row execute function audit.log_change();
create trigger audit_lwt_filing_tickets
  after insert or delete or update on public.lwt_filing_tickets
  for each row execute function audit.log_change();

-- 5. Refuse to commit unless the end state is the one described above. A migration that reports
--    success without changing anything is exactly how 1615 got here.
do $$
declare
  bad text := '';
  t   text;
begin
  foreach t in array array['lwt_filings','lwt_filing_tickets'] loop
    if has_table_privilege('authenticated', 'public.' || t, 'SELECT')  then bad := bad || t || ':authenticated still has SELECT; '; end if;
    if has_table_privilege('authenticated', 'public.' || t, 'DELETE')  then bad := bad || t || ':authenticated still has DELETE; '; end if;
    if has_table_privilege('service_role',  'public.' || t, 'UPDATE')  then bad := bad || t || ':service_role still has UPDATE; '; end if;
    if has_table_privilege('service_role',  'public.' || t, 'DELETE')  then bad := bad || t || ':service_role still has DELETE; '; end if;
    if has_table_privilege('service_role',  'public.' || t, 'TRUNCATE')then bad := bad || t || ':service_role still has TRUNCATE; '; end if;
    -- the endpoint must KEEP working
    if not has_table_privilege('service_role', 'public.' || t, 'SELECT') then bad := bad || t || ':service_role LOST SELECT; '; end if;
    if not has_table_privilege('service_role', 'public.' || t, 'INSERT') then bad := bad || t || ':service_role LOST INSERT; '; end if;
    if not exists (select 1 from pg_class c where c.oid = ('public.' || t)::regclass and c.relrowsecurity) then bad := bad || t || ':RLS not enabled; '; end if;
    if not exists (select 1 from pg_trigger g where g.tgrelid = ('public.' || t)::regclass and not g.tgisinternal and g.tgname = 'audit_' || t) then bad := bad || t || ':audit trigger missing; '; end if;
  end loop;
  -- anon was already correct; assert it stayed that way rather than trusting it
  if has_table_privilege('anon', 'public.lwt_filings', 'SELECT') then bad := bad || 'anon gained SELECT; '; end if;
  -- and the view authenticated actually reads must still be readable
  if not has_table_privilege('authenticated', 'derm.v_lwt_ticket_reported', 'SELECT') then bad := bad || 'authenticated lost the VIEW; '; end if;
  if bad <> '' then
    raise exception 'lock-down verification FAILED: %', bad;
  end if;
  raise notice 'lock-down verified: authenticated has nothing, service_role has SELECT+INSERT only, RLS on, both tables audited, view still readable';
end $$;

commit;
