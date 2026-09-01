-- 2026-09-01_1400  The leased-but-no-result watchdog for the GDO reporting bot.
--
-- WHAT IT ANSWERS. `rpa-derm-queue` writes a row into public.derm_portal_leases for
-- every (visit, permit) it hands the bot, and gate 4 of public.v_derm_portal_queue
-- then hides that pair for 20 hours. If the bot takes the work and never posts a
-- result, the pair is frozen for those 20 hours and NOTHING says so: the queue
-- reports a smaller depth, which is exactly what a healthy drain looks like.
-- Jonathan hit the readable half of this on 2026-08-25 ("the queue read empty on the
-- 21st-23rd while 11024 sat excluded, so 'empty' and 'stuck' looked identical").
-- This is the other half: dispensed and silent.
--
-- THE JOIN THAT LOOKS RIGHT AND IS NOT, measured before anything was written.
-- Matching a lease to its result on (visit_id, gdo_id) with `IS NOT DISTINCT FROM`
-- reports 11 of 11 leases unresolved, i.e. a 100% failure rate on a bot that has in
-- fact filed everything it was ever handed. Every existing lease row predates the
-- 2026-08-31 multi-permit change and therefore carries `gdo_id IS NULL`, while its
-- submission carries the real permit id that `rpa-derm-result` resolved. NULL never
-- matches 60. A 100% failure rate is the signature of a broken comparison, not of
-- broken data, and this one would have shipped an alert naming every filing we have.
--   => A NULL lease is a WHOLE-TICKET lease (that is what it meant before the column
--      existed, and it is still how gate 4 reads it), so ANY live submission for that
--      visit satisfies it. A non-null lease must be satisfied by its own permit.
--
-- MATCH ON `created_at`, NOT `attempted_at`. `attempted_at` is the BOT's clock and
-- diverges from ours by up to 123 seconds on real rows; `created_at` is ours. Both
-- give 11 of 11 today, but only one of them stays true if Jonathan's host drifts.
--
-- THE THRESHOLD IS 3 HOURS AND IT COMES FROM THE DATA. Measured lease-to-result
-- latency across all 11 leases: min 14s, max 48s. The bot's own poll interval is
-- 60 minutes. 3 hours is about 225x the worst observed latency and still absorbs a
-- wholly missed poll cycle, so a row reaching this view has missed at least two
-- chances to report. The 5-minute back-grace on the match absorbs clock skew between
-- the edge function's `new Date()` and `now()`.
--
-- ONE KNOWN, LEGITIMATE WAY TO SET THIS OFF, and it is a finding rather than a false
-- positive: Jonathan's `SHADOW_MODE=true` makes every run a dry run, while his
-- 60-minute poll reads the PRODUCTION queue, which leases. So a shadow-mode poll that
-- finds work drains the queue for 20h and files nothing. That is precisely the state
-- worth an email. It has never happened (0 orphan leases in the estate's history),
-- but if it starts, do not "fix" the detector.
--
-- Leases are never deleted, only upserted per (visit, permit), so `leased_at` is
-- always the LATEST dispense and an old result can never satisfy a fresh lease.
--
-- Rule 8: no new table, so no audit opt-in decision. Two views and one function.

begin;

-- ---------------------------------------------------------------- the detector ----
create or replace view public.v_rpa_derm_stale_leases as
select
  l.visit_id,
  l.gdo_id,
  g.gdo_number,
  c.client_code,
  c.name                                                       as client_name,
  v.visit_date,
  l.leased_at,
  round(extract(epoch from (now() - l.leased_at)) / 3600.0, 1) as hours_open,
  (select max(s.created_at)
     from public.derm_portal_submissions s
    where s.visit_id = l.visit_id
      and not s.dry_run)                                       as last_live_result_any_permit
from public.derm_portal_leases l
join public.visits v on v.id = l.visit_id
left join public.clients c on c.id = v.client_id
left join public.gdos g on g.id = l.gdo_id
where now() - l.leased_at > interval '3 hours'
  and not exists (
    select 1
      from public.derm_portal_submissions s
     where s.visit_id = l.visit_id
       and (l.gdo_id is null or s.gdo_id is not distinct from l.gdo_id)
       and not s.dry_run
       and s.created_at >= l.leased_at - interval '5 minutes'
  );

comment on view public.v_rpa_derm_stale_leases is
  'GDO bot leases with no live result after 3h. A NULL gdo_id lease is whole-ticket and any live submission for the visit clears it; a permit-scoped lease needs its own. Matches on created_at (ours), never attempted_at (the bot clock). Empty is healthy.';

-- REVOKE BY NAME, and this is not belt and braces: the first apply of this file was
-- REFUSED by its own step-5 assertion because `authenticated` held `arwdDxtm` on a
-- view created seconds earlier. Supabase's ALTER DEFAULT PRIVILEGES grants it to
-- `authenticated` BY NAME, and `REVOKE ... FROM public` cannot remove a role-specific
-- grant, so the obvious line below is necessary and was not sufficient.
revoke all on public.v_rpa_derm_stale_leases from public;
revoke all on public.v_rpa_derm_stale_leases from anon, authenticated;
grant select on public.v_rpa_derm_stale_leases to service_role, yannick_readonly;

-- ------------------------------------------------------- fold into the health ----
-- CREATE OR REPLACE with `stale_leases` APPENDED. The six existing columns keep
-- their names, types and order, which is what makes this a replace rather than a
-- drop-and-recreate (a drop discards grants). Body copied from pg_get_viewdef, not
-- retyped.
create or replace view public.v_rpa_derm_health as
 SELECT ( SELECT count(*) AS count
           FROM v_derm_portal_queue) AS queue_depth,
    ( SELECT max(s.created_at) AS max
           FROM derm_portal_submissions s
          WHERE NOT s.dry_run) AS last_real_attempt,
    ( SELECT count(*) AS count
           FROM derm_portal_submissions s
          WHERE NOT s.dry_run AND s.status = 'SUCCESS'::text AND s.created_at > (now() - '24:00:00'::interval)) AS success_24h,
    ( SELECT count(*) AS count
           FROM derm_portal_submissions s
          WHERE NOT s.dry_run AND s.screenshot_missing_reason = 'STORE_FAILED'::text) AS store_failed_total,
    ( SELECT count(*) AS count
           FROM ( SELECT s.visit_id,
                    s.gdo_id
                   FROM derm_portal_submissions s
                  WHERE NOT s.dry_run
                  GROUP BY s.visit_id, s.gdo_id
                 HAVING count(*) >= 3 AND count(*) FILTER (WHERE s.status = 'SUCCESS'::text) = 0) q) AS visits_ge3_attempts,
    ( SELECT count(*) AS count
           FROM v_gdo_reporting_derm_mismatch) AS gdo_not_derm_required,
    ( SELECT count(*) AS count
           FROM v_rpa_derm_stale_leases) AS stale_leases;

-- ------------------------------------------------------------- the logger --------
-- Copied from pg_get_functiondef and edited in place: one new IF, one new key in
-- `details`. Nothing else moved, and the VERIFY below proves the other arms survive.
-- ops.v_health_items and ops.v_health_status need NO change: both already read
-- rpa-derm-health's `reasons` array and key each item on `kind`, so a new kind is
-- escalated by the existing chain (and mailed by health-escalate) for free.
create or replace function public.log_rpa_derm_health()
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
declare h record; reasons jsonb := '[]'::jsonb; attn boolean := false;
begin
  select * into h from public.v_rpa_derm_health;
  if h.queue_depth > 0 and (h.last_real_attempt is null or h.last_real_attempt < now() - interval '26 hours') then
    attn := true; reasons := reasons || jsonb_build_object('kind','no_recent_attempts','queue_depth',h.queue_depth,'last_real_attempt',h.last_real_attempt);
  end if;
  if h.store_failed_total > 0 then attn := true; reasons := reasons || jsonb_build_object('kind','evidence_lost_store_failed','count',h.store_failed_total); end if;
  if h.visits_ge3_attempts > 0 then attn := true; reasons := reasons || jsonb_build_object('kind','retry_loop_visits','count',h.visits_ge3_attempts); end if;
  if h.gdo_not_derm_required > 0 then attn := true; reasons := reasons || jsonb_build_object('kind','gdo_code27_not_derm_required','count',h.gdo_not_derm_required); end if;
  if h.stale_leases > 0 then attn := true; reasons := reasons || jsonb_build_object('kind','rpa_lease_no_result','count',h.stale_leases); end if;
  insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
  values ('rpa-derm-health', now(), now(), coalesce(h.queue_depth,0),
          case when attn then 'attention' else 'ok' end,
          jsonb_build_object('queue_depth',h.queue_depth,'last_real_attempt',h.last_real_attempt,
                             'success_24h',h.success_24h,'store_failed_total',h.store_failed_total,
                             'visits_ge3_attempts',h.visits_ge3_attempts,
                             'gdo_not_derm_required',h.gdo_not_derm_required,
                             'stale_leases',h.stale_leases,'reasons',reasons));
  return case when attn then 1 else 0 end;
end $function$;

-- ------------------------------------------------------------------ VERIFY -------
do $$
declare
  v_now         int;
  v_leases      int;
  v_fired       int;
  v_below       int;
  v_restored    int;
  v_acl         text;
  v_sibling_acl text;
  v_pick_visit  bigint;
  v_pick_at     timestamptz;
  v_details     jsonb;
begin
  -- 1. The view is EMPTY today, and that statement is worthless on its own.
  select count(*) into v_now    from public.v_rpa_derm_stale_leases;
  select count(*) into v_leases from public.derm_portal_leases;
  if v_leases = 0 then
    raise exception 'control failed: there are no leases at all, so an empty detector proves nothing';
  end if;
  if v_now <> 0 then
    raise notice 'NOTE: % stale lease(s) present at migration time', v_now;
  end if;

  -- 2. POSITIVE CONTROL. It MUST fire, or the zero above is an untested instrument.
  --    Nothing is created: an existing legacy lease whose only result is from July is
  --    moved forward in time inside a savepoint. Even if it leaked (it cannot, the
  --    inner block always raises), the row is a visit filed in July, which gate 1
  --    keeps out of the queue regardless.
  select l.visit_id, l.leased_at into v_pick_visit, v_pick_at
    from public.derm_portal_leases l
   where l.gdo_id is null
   order by l.leased_at
   limit 1;
  if v_pick_visit is null then
    raise exception 'control failed: no legacy lease available to drive the positive control';
  end if;

  begin
    update public.derm_portal_leases
       set leased_at = now() - interval '5 hours'
     where visit_id = v_pick_visit and gdo_id is null;
    select count(*) into v_fired
      from public.v_rpa_derm_stale_leases where visit_id = v_pick_visit;

    -- 3. NEGATIVE CONTROL on the THRESHOLD itself: the same row, one hour old, must
    --    NOT appear. Without this, a view returning every lease would pass step 2.
    update public.derm_portal_leases
       set leased_at = now() - interval '1 hour'
     where visit_id = v_pick_visit and gdo_id is null;
    select count(*) into v_below
      from public.v_rpa_derm_stale_leases where visit_id = v_pick_visit;

    raise exception 'ROLLBACK_CONTROL';
  exception when others then
    if sqlerrm <> 'ROLLBACK_CONTROL' then raise; end if;
  end;

  if v_fired <> 1 then
    raise exception 'positive control FAILED: a 5h-old lease with no result was not reported (got %)', v_fired;
  end if;
  if v_below <> 0 then
    raise exception 'threshold control FAILED: a 1h-old lease was reported (got %), so the 3h gate is not real', v_below;
  end if;

  -- 4. The savepoint really unwound: the lease is back where it was.
  select count(*) into v_restored
    from public.derm_portal_leases
   where visit_id = v_pick_visit and gdo_id is null and leased_at = v_pick_at;
  if v_restored <> 1 then
    raise exception 'control leaked: lease for visit % was not restored to %', v_pick_visit, v_pick_at;
  end if;

  -- 5. GRANTS. Supabase default privileges hand out grants nobody wrote, so read the
  --    ACL AFTER the fact rather than trusting the GRANT statements above.
  select c.relacl::text into v_acl
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname = 'v_rpa_derm_stale_leases';
  select c.relacl::text into v_sibling_acl
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname = 'v_rpa_derm_health';
  if has_table_privilege('anon','public.v_rpa_derm_stale_leases','SELECT')
     or has_table_privilege('authenticated','public.v_rpa_derm_stale_leases','SELECT') then
    raise exception 'grant FAILED: anon or authenticated can read the detector (acl %)', v_acl;
  end if;
  if not has_table_privilege('service_role','public.v_rpa_derm_stale_leases','SELECT') then
    raise exception 'grant FAILED: service_role cannot read the detector (acl %)', v_acl;
  end if;

  -- 6. The logger still fires and writes the metric. Exercised, not read: PL/pgSQL is
  --    not parsed at creation time, so "the migration applied" says nothing about
  --    whether the function runs.
  begin
    perform public.log_rpa_derm_health();
    select details into v_details from public.sync_log
      where sync_source = 'rpa-derm-health' order by id desc limit 1;
    raise exception 'ROLLBACK_CONTROL';
  exception when others then
    if sqlerrm <> 'ROLLBACK_CONTROL' then raise; end if;
  end;
  if v_details is null or not (v_details ? 'stale_leases') then
    raise exception 'logger FAILED: details carries no stale_leases key (%)', v_details;
  end if;
  if not (v_details ? 'gdo_not_derm_required') then
    raise exception 'logger FAILED: an older metric went missing from details (%)', v_details;
  end if;

  raise notice 'VERIFY OK: detector empty (% rows), positive control fired, 1h row refused, lease restored, grants match sibling %, logger writes stale_leases',
               v_now, v_sibling_acl;
end $$;

commit;
