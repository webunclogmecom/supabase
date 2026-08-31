-- 2026-08-31_1300_emergency_session_grants.sql
--
-- The issuance ledger for emergency access mode, built during the live GoTrue outage.
-- Spec: docs/specs/2026-08-31-emergency-default-user-access.md
--
-- Fred, 2026-08-31: "We need to keep working, and no app with an Auth is working, so we gotta do a
-- temporary fix ... make it so we work with a user called Default ... and just make all the apps
-- skip the auth."
--
-- WHY THIS TABLE EXISTS. The whole emergency mode hands out `authenticated` JWTs behind a
-- passphrase. The one thing that makes that defensible after the fact is being able to say exactly
-- how many were handed out, when, and to whom. Without this table the mode is unauditable, and an
-- unauditable emergency credential is how a temporary measure quietly becomes a permanent hole.
--
-- 🛑 THE `Default` IDENTITY IS A SENTINEL UUID WITH NO ROW IN auth.users, ON PURPOSE.
-- Creating a real auth user requires GoTrue, which is the thing that is down. Reusing a real
-- person's uuid was the tempting shortcut and is rejected: it would write FALSE per-person
-- attribution into a compliance trail, which is worse than no attribution.
-- ✅ VERIFIED SAFE BEFORE WRITING THIS (2026-08-31, with a positive control):
--      policies whose USING/WITH CHECK references auth.users .... 0   (control: 136 policies exist)
--      functions in public/client/ops/derm/customer selecting
--      from auth.users ........................................... 0
--    so auth.uid() resolving to a uuid with no row breaks nothing. RE-RUN THAT CHECK before any
--    future reuse of this pattern; it is the hard gate.
--
-- ⚠ AUDIT TRAILS STAY HONEST RATHER THAN BREAKING. audit.logs.changed_by has never been populated
-- (it reads the singular request.jwt.claim.sub while PostgREST sets the plural), so real
-- attribution rides on jwt_claims->>'email'. Emergency writes will read `default@unclogme.com`,
-- which correctly marks them as emergency-mode actions instead of impersonating a person.
--
-- RULE 8 (ADR 010): opt-IN. This table records who was granted a credential during an incident, so
-- it is exactly the kind of human-consequential row the audit trigger exists for. Cheap: issuance
-- is a handful of rows for the life of one outage.
--
begin;

create table if not exists public.emergency_session_grants (
  id            bigint generated always as identity primary key,
  issued_at     timestamptz  not null default now(),
  expires_at    timestamptz  not null,
  app           text,
  ip            text,
  user_agent    text,
  outcome       text         not null check (outcome in ('granted','refused')),
  refusal_reason text
);

comment on table public.emergency_session_grants is
  'Issuance ledger for emergency Default-user access during the 2026-08-31 Supabase Auth outage. '
  'One row per call to the emergency-session edge function, granted or refused. This is the only '
  'record that the credential was used, so never trim it while the mode is live.';

comment on column public.emergency_session_grants.expires_at is
  'Hard-capped at issued_at + 4 hours by the edge function. This cap is what makes the whole mode '
  'self-limiting: unlike a GRANT, every credential dies on its own even if every human forgets '
  'the rollback. Do not raise it.';

-- 🛑 NOBODY BUT service_role TOUCHES THIS. The edge function writes it; no app reads it. An app
-- that could read the ledger could enumerate when the door was open.
revoke all on public.emergency_session_grants from public, anon, authenticated;
grant select, insert on public.emergency_session_grants to service_role;
grant usage, select on sequence public.emergency_session_grants_id_seq to service_role;

alter table public.emergency_session_grants enable row level security;
-- No policies: service_role bypasses RLS, everyone else is denied by having no grant AND no policy.
-- Belt and braces on a table that exists because of a security compromise.

drop trigger if exists audit_emergency_session_grants on public.emergency_session_grants;
create trigger audit_emergency_session_grants
  after insert or update or delete on public.emergency_session_grants
  for each row execute function audit.log_change();

commit;
