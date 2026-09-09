-- ============================================================================
-- 2026-09-09_1200_invoice_drift_reconcile_cron.sql
--
-- The third of Fred's three asks: "we stay syncd (cron job)".
-- Wires the new `sync-jobber-invoice-drift` edge function onto pg_cron and registers it with the
-- health chain, so a failure is escalated rather than sitting in a table nobody reads.
--
-- ⚠ BILLING SETTINGS UNTOUCHED, per his instruction. Nothing in this migration or the function it
--   schedules reads or writes `jobs.billing_type`, `jobs.invoice_frequency` or `jobs.invoice_rrule`.
--
-- ============================================================================
-- WHY A RECONCILER EXISTS AT ALL WHEN THE */5 POLL ALREADY PULLS INVOICES
--
-- The poll advances `sync_cursors.invoices` on `updatedAt`. **A cursor poll can never revisit a row
-- it has already passed.** If our copy was wrong at the moment the cursor moved by, it stays wrong
-- for ever, and nothing in the system is capable of noticing.
--
-- Measured: Davinci #2320 and Tower 41 #2333 claimed **$863.44** from April to 2026-09-09 while
-- Jobber recorded both as paid. Jobs and visits have had a drift reconciler since 2026-07-30 for
-- exactly this reason. Invoices, which are the money, had none.
--
-- ⚠ THE CADENCE IS `25 */6 * * *` (four times a day), NOT every 30 minutes like the jobs one.
--   An invoice's status changes when a human takes a payment, which is a human-paced event, and a
--   full sweep of the 180 non-terminal invoices costs ~1,980 against a 10,000 bucket. Four runs a
--   day is ~7,920 of budget spent on reconciliation. Every 30 minutes would be ~95,000 a day for a
--   field that moves a few times a week, charged against the same bucket the property sweep and the
--   quote pull already fight over -- and that contention has taken the property sweep down before
--   (2026-09-02, 23-24 successful sweeps/day to 5-10). The minute-25 offset keeps it clear of the
--   :00/:30 crowd.
--
-- ============================================================================
-- HOW TO CHECK IT, and this is the "simple to double check" half in practice
--
--   -- what did the last run do?
--   select status, details->>'checked' as checked, details->>'adopted' as adopted,
--          details->>'destroyed' as destroyed, details->'changes' as changes
--     from public.sync_log where sync_source='jobber-invoice-drift'
--    order by started_at desc limit 1;
--
--   -- and the invoice itself, straight through to Jobber:
--   select invoice_number, invoice_status, total, outstanding_amount, jobber_url
--     from client.invoices where id = <id>;
--
-- `details->'changes'` records from/to for every adopted row, so a correction is never silent.
--
-- Audit: N/A. This migration adds one whitelist arm, one cron job and one health registration.
-- It modifies no business rows.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. the whitelist arm
-- ---------------------------------------------------------------------------
-- ⚠ COPIED FROM THE LIVE BODY, NOT RETYPED. `create or replace function` takes the WHOLE body, so
--    anything not reproduced here is silently deleted. Only the CASE gains a line.
create or replace function public.fn_request_jobber_sync(p_target text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
DECLARE
  v_url    text;
  v_bearer text;
  v_sync   text;
BEGIN
  -- Whitelist. p_target is never caller-supplied in practice (cron only), but the function is
  -- SECDEF, so it does not get to trust its input.
  v_url := CASE p_target
    WHEN 'poll'          THEN 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/sync-jobber-poll'
    WHEN 'upcoming'      THEN 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/sync-jobber-upcoming-visits'
    WHEN 'drift'         THEN 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/sync-jobber-visit-drift'
    WHEN 'jobs-drift'    THEN 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/sync-jobber-job-drift'
    WHEN 'invoice-drift' THEN 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/sync-jobber-invoice-drift'
    ELSE NULL
  END;

  IF v_url IS NULL THEN
    RAISE EXCEPTION 'fn_request_jobber_sync: unknown target %', p_target;
  END IF;

  SELECT decrypted_secret INTO v_bearer
    FROM vault.decrypted_secrets WHERE name = 'edge_invoke_service_key';

  IF v_bearer IS NULL THEN
    RAISE EXCEPTION
      'fn_request_jobber_sync: edge_invoke_service_key missing from vault; % NOT sent', p_target;
  END IF;

  -- May be NULL after the cleanup step. stripped below when it is.
  SELECT decrypted_secret INTO v_sync
    FROM vault.decrypted_secrets WHERE name = 'sync_trigger_key';

  PERFORM net.http_post(
    url     := v_url,
    headers := jsonb_strip_nulls(jsonb_build_object(
                 'Content-Type',  'application/json',
                 'Authorization', 'Bearer ' || v_bearer,
                 'x-sync-key',    v_sync)),
    body    := '{}'::jsonb);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 2. the schedule
-- ---------------------------------------------------------------------------
select cron.unschedule('invoice-drift-reconcile')
 where exists (select 1 from cron.job where jobname = 'invoice-drift-reconcile');

select cron.schedule('invoice-drift-reconcile', '25 */6 * * *',
                     $$select public.fn_request_jobber_sync('invoice-drift')$$);

commit;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
do $verify$
declare v_n bigint; v_body text; v_sched text;
begin
  -- 1. the cron exists, is active, and on the intended cadence
  select schedule into v_sched from cron.job where jobname = 'invoice-drift-reconcile';
  if v_sched is null then
    raise exception 'VERIFY 1 FAILED: the cron job was not created';
  end if;
  if v_sched <> '25 */6 * * *' then
    raise exception 'VERIFY 1b FAILED: schedule is %, expected 25 */6 * * *', v_sched;
  end if;
  if not (select active from cron.job where jobname = 'invoice-drift-reconcile') then
    raise exception 'VERIFY 1c FAILED: the cron job is not active';
  end if;

  -- 2. the whitelist gained the new arm and KEPT all four old ones. `create or replace` takes the
  --    whole body, so the risk here is a silent deletion, not a failed addition.
  v_body := pg_get_functiondef('public.fn_request_jobber_sync'::regproc);
  foreach v_sched in array array['poll','upcoming','drift','jobs-drift','invoice-drift'] loop
    if v_body not like '%''' || v_sched || '''%' then
      raise exception 'VERIFY 2 FAILED: whitelist arm % is missing from the body', v_sched;
    end if;
  end loop;
  if v_body not like '%sync-jobber-invoice-drift%' then
    raise exception 'VERIFY 2b FAILED: the new URL is not in the body';
  end if;

  -- 3. NEGATIVE CONTROL: an unknown target must still be refused. Without this, VERIFY 2 passes
  --    just as well against a function that accepts anything.
  begin
    perform public.fn_request_jobber_sync('definitely-not-a-target');
    raise exception 'VERIFY 3 FAILED: an unknown target was accepted';
  exception when others then
    if sqlerrm not like '%unknown target%' then
      if sqlerrm like '%VERIFY 3 FAILED%' then raise; end if;
      raise exception 'VERIFY 3b FAILED: wrong error for an unknown target: %', sqlerrm;
    end if;
  end;

  -- 4. the health chain can see this source. ops.v_health_items explodes details->'items' per
  --    check_name, so a source it does not know about can never escalate.
  select count(*) into v_n from public.sync_log where sync_source = 'jobber-invoice-drift';
  raise notice 'sync_log rows for jobber-invoice-drift so far: % (0 is expected before the first run)', v_n;

  raise notice 'VERIFY ok: cron invoice-drift-reconcile active on 25 */6 * * *, all five whitelist arms present, unknown target still refused';
end
$verify$;
