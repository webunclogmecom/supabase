-- ============================================================================
-- 2026-08-01_1520 — Schedule SA generation in pg_cron; split PROMOTE out
-- ============================================================================
-- Second half of the port agreed with @Supabase 2 (see 2026-08-01_1450 for the
-- reasoning and the two measurements). This file:
--   1. schedules the nightly sweep as a real cron.job entry
--   2. moves PROMOTE out of the generator into its own cron
--
-- ⚠ The GitHub workflow `.github/workflows/sa-visit-generation.yml` and
-- `scripts/sync/generate_service_agreement_visits.js` are DELETED in the same
-- commit. Two implementations would drift, and this workspace has paid for drift
-- more than once. Do not "keep the script around just in case" — it holds the
-- Management-API round-trip design that made the run take 3 minutes, and a
-- future reader would not know which one is authoritative.
--
-- ---------------------------------------------------------------------------
-- WHY PROMOTE IS ITS OWN CRON (change (c), @Supabase 2's call — and correct)
-- ---------------------------------------------------------------------------
-- `trg_push_visit_insert` already pushes a visit to Jobber at INSERT. The push
-- gate (`fn_visit_in_jobber_scope`) skips anything beyond Jobber's horizon —
-- the next 60 days plus each job's single next visit — so a visit generated 5
-- months out is deliberately DB-only at first.
--
-- PROMOTE re-pushes visits that have ROLLED INTO that window as days pass. That
-- is a daily concern about the passage of time, NOT about generation: it must
-- run even on a day when nothing new is generated. Keeping it inside the
-- generator also forced an HTTP call into the generation path, which is exactly
-- what stops generation being one transaction.
--
-- pg_net is fire-and-forget, which is fine HERE and only here: the push already
-- has `resolve-stale-visit-sync-pending` retrying every 3 minutes, so a dropped
-- request self-heals. That retry is what makes fire-and-forget acceptable for
-- the push and unacceptable for generation.
--
-- ROLLBACK:
--   select cron.unschedule('sa-visit-generation');
--   select cron.unschedule('sa-visit-promote');
--   drop function public.fn_promote_sa_visits_to_jobber();
--   -- and restore the workflow + script from git history
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. PROMOTE — push cron visits that have rolled into Jobber's window
-- ---------------------------------------------------------------------------
create or replace function public.fn_promote_sa_visits_to_jobber(p_limit int default 200)
returns jsonb
language plpgsql
security definer
set search_path = 'public', 'pg_temp'
as $fn$
declare
  v_ids bigint[];
  v_n   int := 0;
begin
  select array_agg(v.id order by v.visit_date)
    into v_ids
    from (
      select v.id, v.visit_date
        from public.visits v
       where v.source = 'supabase_cron'
         and v.visit_status = 'scheduled'
         and v.deleted_at is null
         and v.visit_date >= (now() at time zone 'America/New_York')::date
         and public.fn_visit_in_jobber_scope(v.id)
         and not exists (
           select 1 from public.entity_source_links esl
            where esl.entity_type = 'visit'
              and esl.entity_id = v.id
              and esl.source_system = 'jobber')
       order by v.visit_date
       limit p_limit
    ) v;

  v_n := coalesce(array_length(v_ids, 1), 0);
  if v_n > 0 then
    -- fn_request_jobber_push -> pg_net -> jobber-push-visit. Fire-and-forget is
    -- safe here because resolve-stale-visit-sync-pending retries every 3 min.
    perform public.fn_request_jobber_push(id, 'upsert') from unnest(v_ids) as id;
  end if;

  return jsonb_build_object('promoted', v_n);
end;
$fn$;

comment on function public.fn_promote_sa_visits_to_jobber(int) is
  'Re-pushes generated cron visits that have rolled INTO Jobber''s 60-day horizon as days pass. Split out of the visit generator 2026-08-01: it is about the passage of time, not generation, and it must run on days when nothing is generated. Keeping it in the generator also forced an HTTP call into what is otherwise a single transaction.';

revoke all on function public.fn_promote_sa_visits_to_jobber(int) from public, anon;

-- ---------------------------------------------------------------------------
-- 2. schedule both — replacing the GitHub workflow
-- ---------------------------------------------------------------------------
-- 06:00 EDT / 05:00 EST, matching the workflow's `0 10 * * *` exactly so the
-- cutover changes WHERE it runs, not WHEN.
select cron.unschedule('sa-visit-generation')
 where exists (select 1 from cron.job where jobname = 'sa-visit-generation');
select cron.schedule('sa-visit-generation', '0 10 * * *',
                     $$ select public.fn_generate_sa_visits(null, 6, false) $$);

-- Promote runs shortly after generation and again through the day, so a visit
-- crossing the 60-day boundary reaches Jobber the same day.
select cron.unschedule('sa-visit-promote')
 where exists (select 1 from cron.job where jobname = 'sa-visit-promote');
select cron.schedule('sa-visit-promote', '20 * * * *',
                     $$ select public.fn_promote_sa_visits_to_jobber(200) $$);

commit;
