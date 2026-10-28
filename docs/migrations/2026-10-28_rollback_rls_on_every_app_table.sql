-- 2026-10-28_rollback_rls_on_every_app_table.sql
--
-- Rolls back 2026-10-28_1804_rls_on_every_app_table.sql (Trello FFSF71BI): drops the event trigger
-- and its function, drops derm.page_slots_staff_read, and turns RLS back off on exactly the 49
-- tables that migration turned on. Tables created after it keep the RLS the trigger gave them
-- (the safe direction); turn those off by hand only if an app needs it and a policy will not do.
--
-- Rehearsed 2026-10-28 inside a rolled-back transaction after the apply body: it ends at the
-- measured 49 RLS-off tables, no page_slots policy, no rls_auto_enable.

begin;
set local lock_timeout = '3s';

do $guard$
begin
  if not exists (select 1 from pg_event_trigger where evtname = 'rls_auto_enable') then
    raise exception 'GUARD: rls_auto_enable is not installed; nothing to roll back';
  end if;
end
$guard$;

drop event trigger rls_auto_enable;
drop function public.rls_auto_enable();
drop policy page_slots_staff_read on derm.page_slots;

alter table derm.address_row_map disable row level security;
alter table derm.address_sheet_manifests disable row level security;
alter table derm.address_sheet_scan_reads disable row level security;
alter table derm.address_sheets disable row level security;
alter table derm.band_review disable row level security;
alter table derm.client_aliases disable row level security;
alter table derm.manifest_document_detachments disable row level security;
alter table derm.page_row_rules disable row level security;
alter table derm.page_rule_scans disable row level security;
alter table derm.page_slots disable row level security;
alter table derm.sheet_number_ocr_attempts disable row level security;
alter table derm.stamp_sheet_status disable row level security;
alter table ops.client_call_policy disable row level security;
alter table ops.pgss_snapshot_20260903_medium disable row level security;
alter table public.derm_required_backfill_snapshot_2026_06_24 disable row level security;
alter table public.dump_sites disable row level security;
alter table public.review_scope_inclusions disable row level security;
alter table derm.address_sheet_clients disable row level security;
alter table derm.address_sheet_row_reads disable row level security;
alter table derm.generated_measure_attempts disable row level security;
alter table derm.page_reference_attempts disable row level security;
alter table derm.row_ocr_attempts disable row level security;
alter table hr.access_apps disable row level security;
alter table hr.access_group_defaults disable row level security;
alter table hr.access_overrides disable row level security;
alter table hr.access_refusals disable row level security;
alter table hr.jobber_user_ignores disable row level security;
alter table hr.jobber_users disable row level security;
alter table hr.shift_bonus_overrides disable row level security;
alter table hr.sign_in_changes disable row level security;
alter table hr.visit_bonus_overrides disable row level security;
alter table ops.dispatch_routing_usage disable row level security;
alter table ops.marker_jobber_claims disable row level security;
alter table ops.marker_push_retries disable row level security;
alter table ops.plan_fill_request disable row level security;
alter table ops.plan_fill_run disable row level security;
alter table ops.plan_routing_usage disable row level security;
alter table ops.route_leg_cache disable row level security;
alter table ops.route_leg_fail disable row level security;
alter table ops.start_heal_attempts disable row level security;
alter table ops.start_heal_kick disable row level security;
alter table ops.start_recheck_queue disable row level security;
alter table public.app_config disable row level security;
alter table public.client_status_changes disable row level security;
alter table public.derm_portal_requeue disable row level security;
alter table public.health_alert_state disable row level security;
alter table public.intake_task_closures disable row level security;
alter table public.job_frequency_changes disable row level security;
alter table public.non_customer_clients disable row level security;

do $verify$
declare v_n int;
begin
  select count(*) into v_n
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname in ('public', 'derm', 'ops', 'client', 'customer', 'hr')
     and c.relkind in ('r', 'p') and not c.relrowsecurity;
  if v_n < 49 then raise exception 'ROLLBACK VERIFY: only % RLS-off tables, expected at least 49', v_n; end if;
  if exists (select 1 from pg_event_trigger where evtname = 'rls_auto_enable') then
    raise exception 'ROLLBACK VERIFY: rls_auto_enable still installed';
  end if;
end
$verify$;

commit;
