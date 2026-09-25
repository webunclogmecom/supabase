-- =====================================================================================================
-- 2026-09-24_2350  The health escalation re-notifies every 7 days, as designed, not every 8
-- =====================================================================================================
-- Fred: "go ahead and fix the 8-day re-notify".
--
-- public.fn_health_alert_scan re-sends a still-open item when `now() - last_alerted_at >= 7 days`. Both
-- sides are 13:30 UTC, but not the same instant: the scan reads now() when health-escalate calls it, and
-- public.fn_health_alert_mark_sent stamps last_alerted_at a moment LATER, after Resend has accepted the
-- email (measured: 13:30:00.53 to 13:30:00.88). So seven days on, the scan is a fraction of a second short
-- of 7 days, says "not due", and the item goes out on day 8. Measured in public.health_alert_state before
-- this change: blackout-health 2026-08-28 -> 2026-09-21 in 3 re-sends, and rpa-derm-health 2026-09-04 ->
-- 2026-09-20 in 2, both exactly 8.000 days apart.
--
-- Fix: both day comparisons of the stale arm (open >= p_stale_days, last emailed >= p_renotify_days ago)
-- allow one hour, so "7 days" means the 7th daily run. One hour is far below the one-day gap between runs,
-- so an item can never be re-sent a day early. Nothing else in the function changes (spliced from the live
-- body, anchors asserted once, md5 pinned); its ACL (postgres + service_role, set by 2026-09-24_1045) is
-- kept by CREATE OR REPLACE and asserted below.
-- Rule 8: no table change.
-- ROLLBACK: re-apply the scan from 2026-08-24_1820 (or remove the two "- interval '1 hour'").
-- =====================================================================================================

begin;

do $$
declare v_def text := pg_get_functiondef('public.fn_health_alert_scan(integer,integer)'::regprocedure);
  function_anchor_1 text := '     AND now() - s.first_seen_at >= make_interval(days => p_stale_days)';
  function_anchor_2 text := '          OR now() - s.last_alerted_at >= make_interval(days => p_renotify_days));';
begin
  if md5(v_def) <> '87638ac4b9fd3fc5d905cb4f53371ed6' then
    raise exception 'fn_health_alert_scan changed since this migration was written';
  end if;
  if (length(v_def) - length(replace(v_def, function_anchor_1, ''))) / length(function_anchor_1) <> 1
     or (length(v_def) - length(replace(v_def, function_anchor_2, ''))) / length(function_anchor_2) <> 1 then
    raise exception 'fn_health_alert_scan: an anchor does not occur exactly once';
  end if;
  v_def := replace(v_def, function_anchor_1,
    '     -- 2026-09-24_2350: an hour of tolerance. last_alerted_at is stamped a moment AFTER this scan''s now(),' || chr(10) ||
    '     -- so an exact comparison missed the 7th daily run by under a second and re-sent on day 8.' || chr(10) ||
    '     AND now() - s.first_seen_at >= make_interval(days => p_stale_days) - interval ''1 hour''');
  v_def := replace(v_def, function_anchor_2,
    '          OR now() - s.last_alerted_at >= make_interval(days => p_renotify_days) - interval ''1 hour'');');
  execute v_def;
end $$;

-- =====================================================================================================
-- VERIFY on a real open item, rolled back through VERIFY_OK
-- =====================================================================================================
do $verify$
declare
  k  record;
  r  jsonb;
  hit boolean;
begin
  if (select proacl::text from pg_proc where oid = 'public.fn_health_alert_scan(integer,integer)'::regprocedure)
     <> '{postgres=X/postgres,service_role=X/postgres}' then
    raise exception 'V0 the scan''s grants changed';
  end if;

  select s.check_name, s.item_key into k
    from public.health_alert_state s join ops.v_health_items i using (check_name, item_key)
   where s.resolved_at is null and s.alert_count > 0
   order by s.check_name, s.item_key limit 1;
  if k.check_name is null then
    raise exception 'V0b no open, already-emailed item to test with: the checks below would prove nothing';
  end if;

  -- V1 the weekly boundary as it really happens: emailed 7 days ago, stamped 2 s after that scan's now()
  update public.health_alert_state
     set last_alerted_at = now() - interval '7 days' + interval '2 seconds',
         first_seen_at = now() - interval '30 days', acknowledged_until = null
   where check_name = k.check_name and item_key = k.item_key;
  r := public.fn_health_alert_scan(3, 7);
  select exists (select 1 from jsonb_array_elements(r->'stale') x
                  where x->>'check_name' = k.check_name and x->>'item_key' = k.item_key) into hit;
  if not hit then raise exception 'V1 an item emailed 7 days ago (2 s after the scan) is not due: still 8-day'; end if;

  -- V2 still weekly, not daily: emailed 6 days ago is not due
  update public.health_alert_state set last_alerted_at = now() - interval '6 days'
   where check_name = k.check_name and item_key = k.item_key;
  r := public.fn_health_alert_scan(3, 7);
  select exists (select 1 from jsonb_array_elements(r->'stale') x
                  where x->>'check_name' = k.check_name and x->>'item_key' = k.item_key) into hit;
  if hit then raise exception 'V2 an item emailed 6 days ago is due again'; end if;

  -- V3 and 6 days 22 hours is not due either (the tolerance is an hour, not a day)
  update public.health_alert_state set last_alerted_at = now() - interval '6 days 22 hours'
   where check_name = k.check_name and item_key = k.item_key;
  r := public.fn_health_alert_scan(3, 7);
  select exists (select 1 from jsonb_array_elements(r->'stale') x
                  where x->>'check_name' = k.check_name and x->>'item_key' = k.item_key) into hit;
  if hit then raise exception 'V3 an item emailed 6 days 22 hours ago is due'; end if;

  raise exception 'VERIFY_OK';
exception when raise_exception then
  if sqlerrm <> 'VERIFY_OK' then raise; end if;
end
$verify$;

commit;
