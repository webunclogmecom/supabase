-- ============================================================================
-- 2026-08-15_0626 — send log for the Admin Review "Send email to City" button
-- ============================================================================
-- Fred, 2026-08-15: *"we need to add a button that after we classify the photos
-- that says `Send email to City`"*, and on the gate: *"when there is only
-- classification, because the model for the email it's gonna be a text i give you
-- + the classified photos attached to it."*
--
-- 🛑 THIS IS NOT THE DERM MANIFEST MAILER. `send-derm-email` mails manifest PDFs
-- to municipal FOG inboxes resolved from `public.municipality_regulators`. THIS is
-- a different email: a body Fred supplies plus the visit's CLASSIFIED PHOTOS as
-- attachments. Different payload, different gate, different log. They must not be
-- conflated, and in particular this table is NOT `derm_email_sends`.
--
-- 🛑 CITY SENDING IS STILL OFF. Fred, 2026-08-10: *"remember the emailing
-- functionality to the city is disabled for now, until i explicitly say
-- otherwise."* His 2026-08-15 instruction for THIS button is *"Build it, but
-- test-send only to me"*, so the edge function hard-wires the recipient to
-- fred@ayache.com and stamps `is_test = true`. `recipient_email` is stored so that
-- when a real city address is eventually permitted, the log already distinguishes
-- who actually received it. Nothing here enables a real city send.
--
-- WHY A TABLE AND NOT JUST audit.logs: the send has to be IDEMPOTENT-CHECKABLE
-- BEFORE it happens. `send-derm-email` has no guard of any kind and it shows:
-- measured 2026-08-15, NINE (manifest, client, recipient) triples were each sent
-- twice, 19 seconds apart, on 2026-06-11 (control: 28 triples sent once). An
-- audit trail records what happened; it cannot stop the second send. The function
-- reads this table first and refuses a repeat unless the caller passes
-- confirm_resend.
--
-- SECURITY MODEL — copied deliberately from `public.derm_email_sends`, measured
-- rather than assumed:
--     rls = true, policies = NONE, relacl = postgres + service_role (+ a readonly
--     role), authenticated holds NOTHING, not even SELECT.
-- RLS with zero policies denies every non-bypass role, so service_role is the only
-- writer. ⚠ `CREATE TABLE` hands out grants before any GRANT statement runs (this
-- bit `job_frequency_changes` on 2026-08-07, which shipped with authenticated
-- holding DELETE and TRUNCATE while its own header claimed otherwise), so this
-- migration REVOKES explicitly and then asserts `relacl` against the sibling.
--
-- The app still needs "already sent on <date>" to avoid a double send, so that is
-- exposed through the owner-rights view `public.v_visit_photo_email_status`, which
-- publishes counts and timestamps and NEVER `recipient_email`. Same discipline
-- `derm.visits` applies to the .gov addresses in `municipality_regulators`.
--
-- AUDIT-TRAIL STANDING CHECK (rule 8): OPT-IN. `derm_email_sends` carries the
-- trigger and this is the same class of record (an outbound communication about a
-- client, adjacent to DERM compliance), so rule 8's "no table touching customer.*,
-- billing, DERM compliance or webhook secrets may skip audit" applies.
--
-- 3NF: no derived column is stored. `photo_count` / `bytes_sent` are NOT
-- derivable after the fact (photos can be added, soft-deleted or reclassified
-- later), so they are a point-in-time record of what was actually transmitted, not
-- a denormalised copy of a live value. That is the ADR 004 exception, stated here
-- on purpose rather than left implicit.
-- ============================================================================

-- pre-flight: refuse to run twice, and refuse if the sibling we copy is missing
do $do$
begin
  if to_regclass('public.visit_photo_email_sends') is not null then
    raise exception 'public.visit_photo_email_sends already exists';
  end if;
  if to_regclass('public.derm_email_sends') is null then
    raise exception 'sibling public.derm_email_sends is missing; the ACL control cannot run';
  end if;
end
$do$;

create table public.visit_photo_email_sends (
  id               bigint generated always as identity primary key,
  visit_id         bigint      not null references public.visits(id),
  recipient_email  text        not null,
  status           text        not null check (status in ('sent','skipped','error')),
  reason           text,
  is_test          boolean     not null default true,
  photo_count      integer     not null default 0 check (photo_count >= 0),
  bytes_sent       bigint      not null default 0 check (bytes_sent >= 0),
  resend_email_id  text,
  subject          text,
  sent_by_email    text,
  sent_by_user_id  uuid,
  sent_at          timestamptz not null default now()
);

comment on table public.visit_photo_email_sends is
  'Append-only log of the Admin Review "Send email to City" email (body + the visit''s classified photos). NOT the DERM manifest mailer, which logs to derm_email_sends. Read by send-visit-photos-email BEFORE sending, to refuse a duplicate.';
comment on column public.visit_photo_email_sends.is_test is
  'TRUE while city sending is disabled (Fred 2026-08-10) and the recipient is hard-wired to fred@ayache.com.';
comment on column public.visit_photo_email_sends.photo_count is
  'What was actually transmitted at send time. Not derivable later: photos can be added, soft-deleted or reclassified afterwards.';

create index visit_photo_email_sends_visit_idx
  on public.visit_photo_email_sends (visit_id, sent_at desc);
create index visit_photo_email_sends_real_sent_idx
  on public.visit_photo_email_sends (visit_id, sent_at desc)
  where status = 'sent' and is_test = false;

-- rule 8: opt-in
create trigger audit_visit_photo_email_sends
  after insert or update or delete on public.visit_photo_email_sends
  for each row execute function audit.log_change();

alter table public.visit_photo_email_sends enable row level security;
-- deliberately NO policies: RLS with none denies every role that does not bypass it,
-- which leaves service_role (and the table owner) as the only writer.

revoke all on public.visit_photo_email_sends from anon, authenticated;
grant select, insert on public.visit_photo_email_sends to service_role;

-- ---------------------------------------------------------------------------
-- What the app reads. Owner-rights view (NOT security_invoker) so a signed-in
-- staff user can see send history without holding a grant on the table, and
-- WITHOUT ever seeing recipient_email.
-- ---------------------------------------------------------------------------
create view public.v_visit_photo_email_status as
select
  s.visit_id,
  count(*)                                                    as send_count,
  count(*) filter (where s.status = 'sent')                   as sent_count,
  max(s.sent_at) filter (where s.status = 'sent')             as last_sent_at,
  max(s.sent_at) filter (where s.status = 'sent'
                           and s.is_test = false)             as last_real_sent_at,
  (array_agg(s.status order by s.sent_at desc))[1]            as last_status,
  (array_agg(s.reason order by s.sent_at desc))[1]            as last_reason,
  (array_agg(s.sent_by_email order by s.sent_at desc))[1]     as last_sent_by,
  (array_agg(s.photo_count order by s.sent_at desc))[1]       as last_photo_count
from public.visit_photo_email_sends s
group by s.visit_id;

comment on view public.v_visit_photo_email_status is
  'Per-visit send history for the Admin Review button. Owner-rights on purpose: publishes counts/timestamps/actor, never recipient_email.';

grant select on public.v_visit_photo_email_status to authenticated;

-- ============================================================================
-- VERIFY. Asserted AFTER the fact against a sibling control, because a migration
-- that only checks its own GRANT statements passes while the table stays open.
-- ============================================================================
do $do$
declare
  v_acl text; v_sib text; v_pol int; v_rls boolean; v_aud int;
  v_a_sel boolean; v_a_ins boolean; v_a_del boolean; v_anon boolean;
  v_view_ok boolean; v_view_invoker text;
begin
  select relacl::text, relrowsecurity into v_acl, v_rls
    from pg_class where oid = 'public.visit_photo_email_sends'::regclass;
  select relacl::text into v_sib from pg_class where oid = 'public.derm_email_sends'::regclass;

  -- (a) authenticated and anon must hold NOTHING on the table
  v_a_sel := has_table_privilege('authenticated','public.visit_photo_email_sends','SELECT');
  v_a_ins := has_table_privilege('authenticated','public.visit_photo_email_sends','INSERT');
  v_a_del := has_table_privilege('authenticated','public.visit_photo_email_sends','DELETE');
  v_anon  := has_table_privilege('anon','public.visit_photo_email_sends','SELECT');
  if v_a_sel or v_a_ins or v_a_del or v_anon then
    raise exception 'ACL too wide. authenticated select/insert/delete = %/%/%, anon select = %. acl=%',
      v_a_sel, v_a_ins, v_a_del, v_anon, v_acl;
  end if;

  -- (b) service_role must actually be able to write, or the function is dead on arrival
  if not has_table_privilege('service_role','public.visit_photo_email_sends','INSERT') then
    raise exception 'service_role cannot INSERT; the edge function could never log a send';
  end if;

  -- (c) RLS on, zero policies (matching the sibling)
  if not v_rls then raise exception 'RLS is OFF'; end if;
  select count(*) into v_pol from pg_policy where polrelid = 'public.visit_photo_email_sends'::regclass;
  if v_pol <> 0 then raise exception 'expected 0 policies, found %', v_pol; end if;

  -- (d) rule 8 audit trigger present
  select count(*) into v_aud from pg_trigger t
    join pg_proc p on p.oid = t.tgfoid
    join pg_namespace pn on pn.oid = p.pronamespace
   where t.tgrelid = 'public.visit_photo_email_sends'::regclass
     and pn.nspname = 'audit' and p.proname = 'log_change' and not t.tgisinternal;
  if v_aud <> 1 then raise exception 'expected 1 audit trigger, found %', v_aud; end if;

  -- (e) the view must be OWNER-rights, or authenticated (holding no table grant) reads nothing
  select reloptions::text into v_view_invoker from pg_class where oid = 'public.v_visit_photo_email_status'::regclass;
  if v_view_invoker is not null and v_view_invoker like '%security_invoker=t%' then
    raise exception 'view is security_invoker; authenticated holds no table grant so it would return nothing';
  end if;
  v_view_ok := has_table_privilege('authenticated','public.v_visit_photo_email_status','SELECT');
  if not v_view_ok then raise exception 'authenticated cannot read the status view'; end if;

  raise notice 'table acl=%  (sibling derm_email_sends acl=%)', v_acl, v_sib;
  raise notice 'rls=% policies=% audit=% view readable by authenticated=%', v_rls, v_pol, v_aud, v_view_ok;
end
$do$;

-- (f) PROVE the owner-rights view actually works for a role holding no table grant.
-- A rolled-back probe: insert a row, read it back as `authenticated`, then undo.
do $do$
declare v_seen int; v_leak int;
begin
  insert into public.visit_photo_email_sends (visit_id, recipient_email, status, photo_count, bytes_sent, subject)
  select id, 'probe@example.invalid', 'sent', 3, 123, 'probe'
    from public.visits where deleted_at is null order by id limit 1;

  perform set_config('request.jwt.claims','{"sub":"00000000-0000-0000-0000-000000000009","role":"authenticated"}', true);
  set local role authenticated;
  select count(*) into v_seen from public.v_visit_photo_email_status;
  -- the view must not expose the address under any column name
  select count(*) into v_leak
    from information_schema.columns
   where table_schema='public' and table_name='v_visit_photo_email_status'
     and column_name ilike '%recipient%';
  reset role;

  if v_seen < 1 then raise exception 'owner-rights view returned no rows to authenticated'; end if;
  if v_leak <> 0 then raise exception 'the status view exposes % recipient column(s)', v_leak; end if;
  raise notice 'probe: authenticated saw % visit row(s) through the view, 0 recipient columns', v_seen;

  raise exception 'PROBE_ROLLBACK_OK';
exception when others then
  if sqlerrm <> 'PROBE_ROLLBACK_OK' then raise; end if;
  raise notice 'probe rolled back cleanly';
end
$do$;

-- final state: the probe row must be gone
do $do$
declare n int;
begin
  select count(*) into n from public.visit_photo_email_sends;
  if n <> 0 then raise exception '% probe row(s) survived the rollback', n; end if;
  raise notice 'visit_photo_email_sends is empty and ready';
end
$do$;
