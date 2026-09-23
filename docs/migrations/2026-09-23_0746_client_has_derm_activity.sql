-- 2026-09-23 07:46 ET
-- client.fn_client_has_derm_activity(bigint) -> boolean
--
-- WHY THIS EXISTS. The Client App's Edit-contact dialog is about to warn that changing the
-- client-record contact's email also changes who receives the DERM service report. That warning is
-- only TRUE for clients who actually get service reports, and the app has no way to know which
-- those are. This is that signal, and nothing else.
--
-- 🛑 IT IS DELIBERATELY *NOT* GATED ON THE `service_report` COMMUNICATION PREF. Measured
-- 2026-09-23: `trg_seed_client_communication` seeds invoice + quote_approval + service_report onto
-- every client-record contact at birth, so there are exactly 1,191 pref rows over 397 clients,
-- three each, with NOT ONE CLIENT DIFFERING. That tick is a trigger default that nobody chose, so
-- gating a compliance warning on it would fire on all 397 and carry no information. See
-- `Building Apps/Client App/docs/2026-09-23_derm-recipient-disclosure-decision.md`.
--
-- 🛑 IT USES `fn_visit_requires_derm`, NOT `visits.derm_required`. The stored column and the
-- function disagree on 7 clients today (measured). The standing rule is that the function is
-- authoritative; the column is a cached value that can go stale. Using the column here would
-- silently drop clients from the warning.
--
-- TWO ARMS ON PURPOSE:
--   manifests  -> the client HAS had DERM activity (historical, 171 of the 397 pref clients)
--   requires   -> the client IS DERM-required but has no manifest yet (10 more, forward-looking).
--                 Without this arm a brand-new DERM client silently gets no warning at all, which
--                 is the exact failure the warning exists to prevent.
-- Combined: 181 of 397. The remaining 216 are clients for whom no service report exists, has
-- existed, or is coming - and for them the sentence would be false, so it must stay silent.
--
-- ⚠ 181, NOT 182. A loose pre-flight measurement that ignored soft-deletes said 182; this
-- migration's own VERIFY block caught the difference and rolled the whole thing back. The client
-- is 777-YA, whose ONLY DERM-required visit is soft-deleted - a deleted visit produces no report,
-- so it must not get the warning. The assertion was right and the measurement was loose.
--
-- Soft-deletes are excluded on both arms (`deleted_at is null`), per the estate's soft-delete rule.

begin;

create or replace function client.fn_client_has_derm_activity(p_client_id bigint)
returns boolean
language sql
stable
security definer
set search_path to 'public', 'pg_catalog'
as $fn$
  select exists (
           select 1 from public.derm_manifests dm
            where dm.client_id = p_client_id
              and dm.deleted_at is null
         )
      or exists (
           select 1 from public.visits v
            where v.client_id = p_client_id
              and v.deleted_at is null
              and public.fn_visit_requires_derm(v.id)
         );
$fn$;

comment on function client.fn_client_has_derm_activity(bigint) is
  'True when this client has had a DERM manifest or has a DERM-required visit. Drives whether the '
  'Client App warns that editing the client-record contact email moves the service-report '
  'recipient. NOT the service_report pref, which is a trigger default on every client.';

revoke all on function client.fn_client_has_derm_activity(bigint) from public;
grant execute on function client.fn_client_has_derm_activity(bigint) to authenticated, service_role;

-- ── VERIFY ────────────────────────────────────────────────────────────────────────────────────
-- Asserts the shape measured before writing this. A bare "it returns a boolean" would pass on a
-- function that returns true for everyone, which is the failure mode that matters here.
do $v$
declare
  n_prefs int; n_true int; n_manifest_only int; n_control int;
begin
  select count(distinct client_id) into n_prefs
    from public.client_communication_prefs where comm_type = 'service_report';

  select count(*) into n_true from (
    select distinct client_id from public.client_communication_prefs where comm_type = 'service_report'
  ) p where client.fn_client_has_derm_activity(p.client_id);

  select count(*) into n_manifest_only from (
    select distinct client_id from public.client_communication_prefs where comm_type = 'service_report'
  ) p where exists (select 1 from public.derm_manifests dm
                     where dm.client_id = p.client_id and dm.deleted_at is null);

  -- POSITIVE CONTROL: the function must DISCRIMINATE. If it returned true for every client the
  -- warning would be exactly the over-firing one we rejected, and a count check alone would not
  -- notice. This is the assertion that would have caught that.
  select count(*) into n_control from (
    select distinct client_id from public.client_communication_prefs where comm_type = 'service_report'
  ) p where not client.fn_client_has_derm_activity(p.client_id);

  raise notice 'pref clients=% | has derm activity=% | manifest arm alone=% | silent=%',
    n_prefs, n_true, n_manifest_only, n_control;

  if n_prefs <> 397 then
    raise exception 'expected 397 clients with a service_report pref, found %', n_prefs;
  end if;
  if n_true <> 181 then
    raise exception 'expected 181 clients with DERM activity, found % - re-measure before shipping the warning', n_true;
  end if;
  if n_manifest_only <> 171 then
    raise exception 'expected 171 on the manifest arm alone, found %', n_manifest_only;
  end if;
  if n_control <> 216 then
    raise exception 'expected 216 clients to stay SILENT, found % - the function is not discriminating', n_control;
  end if;
end $v$;

commit;
