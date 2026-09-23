-- 2026-09-23 14:25 ET
-- client.v_derm_no_recipient -- EMPTY IS HEALTHY.
--
-- A client that receives DERM service reports and has NOBODY to send them to. Measured today:
-- **19 rows**, 17 of which already have real DERM manifests on file, so the compliance work was
-- done and documented and the report has never been sendable. 186-PV alone has 7 manifests.
--
-- 🛑 WHY THIS WAS INVISIBLE, AND THE MISTAKE IT CORRECTS. On 2026-09-23 I answered the plan's
-- "clients whose service report has nowhere to go" question with "2 clients, none DERM-active,
-- inert". That query was scoped to clients that HAVE a service_report pref, which structurally
-- excludes every client that has NO pref at all -- and that is exactly where the problem lives:
-- 71 of 463 live clients hold no communication preference whatsoever. A check scoped to the
-- CONFIGURED population cannot see the UNCONFIGURED one. This view keys on the OUTCOME
-- (fn_derm_recipients returns an empty array) rather than on the configuration, so it cannot
-- repeat that error.
--
-- ✅ NOT A REGRESSION FROM THE CONTACTS SHIP, and that was checked before writing this. The
-- pre-2026-09-22 rule read public.client_contacts directly (any contact with an email,
-- role-ordered, limit 1); today's reads client_communication_prefs only. A/B over every live
-- client: 0 lost a recipient, 0 gained one, 390 have one under both rules. The backfill did its
-- job; these 19 have never had a recipient.
--
-- ⚠ WHETHER JOBBER HOLDS AN ADDRESS FOR THEM IS UNANSWERED. public.client_jobber_contacts is NOT
-- a second source: it fills lazily when somebody opens a client in the app, and estate-wide only
-- **2** clients have a row in it. So its emptiness proves nothing, and the Jobber API was
-- throttling when this shipped. Answer that before deciding the remedy is "ask a person".

begin;

create or replace view client.v_derm_no_recipient as
select c.id                                as client_id,
       c.client_code,
       c.name,
       case
         when not exists (select 1 from public.client_contacts cc where cc.client_id = c.id)
           then 'no contact record at all'
         when not exists (select 1 from public.client_contacts cc
                           where cc.client_id = c.id and coalesce(btrim(cc.email), '') <> '')
           then 'has a contact, no email on it'
         else 'has an email but no service_report preference'
       end                                 as blocker,
       (select count(*) from public.derm_manifests dm
         where dm.client_id = c.id and dm.deleted_at is null)          as manifests_on_file,
       (select max(dm.service_date) from public.derm_manifests dm
         where dm.client_id = c.id and dm.deleted_at is null)          as last_manifest_date
  from public.clients c
 where c.status <> 'INACTIVE'
   and client.fn_client_has_derm_activity(c.id)
   and jsonb_array_length(client.fn_derm_recipients(c.id)) = 0;

comment on view client.v_derm_no_recipient is
  'EMPTY IS HEALTHY. Live clients that receive DERM service reports and resolve to zero '
  'recipients, so the report cannot be sent. Keyed on the OUTCOME (fn_derm_recipients returns an '
  'empty array), never on whether a communication preference exists -- 71 of 463 live clients hold '
  'no preference at all, and a configuration-scoped check is blind to exactly them.';

revoke all on client.v_derm_no_recipient from public;
grant select on client.v_derm_no_recipient to authenticated, service_role;

-- ── VERIFY ────────────────────────────────────────────────────────────────────────────────────
do $v$
declare
  n_rows int; n_manifests int; n_control int; n_nocontact int;
begin
  select count(*) into n_rows from client.v_derm_no_recipient;
  select count(*) into n_manifests from client.v_derm_no_recipient where manifests_on_file > 0;
  select count(*) into n_nocontact from client.v_derm_no_recipient where blocker = 'no contact record at all';

  -- POSITIVE CONTROL: the view must DISCRIMINATE. A view returning every DERM client, or none,
  -- would satisfy a bare count. 181 DERM-active clients DO have a recipient and must NOT appear.
  select count(*) into n_control
    from public.clients c
   where c.status <> 'INACTIVE'
     and client.fn_client_has_derm_activity(c.id)
     and jsonb_array_length(client.fn_derm_recipients(c.id)) > 0;

  raise notice 'no-recipient=% | with manifests=% | no contact row=% | control (have a recipient)=%',
    n_rows, n_manifests, n_nocontact, n_control;

  if n_rows <> 19 then
    raise exception 'expected 19 clients with no DERM recipient, found % - re-measure before shipping', n_rows;
  end if;
  if n_manifests <> 17 then
    raise exception 'expected 17 of them to hold real manifests, found %', n_manifests;
  end if;
  if n_nocontact <> 12 then
    raise exception 'expected 12 with no contact record at all, found %', n_nocontact;
  end if;
  if n_control <> 181 then
    raise exception 'expected 181 DERM-active clients WITH a recipient, found % - the view is not discriminating', n_control;
  end if;
end $v$;

commit;
