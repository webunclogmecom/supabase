-- ============================================================================
-- 2026-07-30_1552 — fn_record_client_job: the atomic DB half of the job saga
-- ============================================================================
-- Companion to 2026-07-30_1531 (read that header + the design doc first).
--
-- WHY THIS EXISTS: after `save-client-job` verifies a jobCreate in Jobber it must
-- write jobs + entity_source_links + line_items. Three sequential PostgREST writes
-- leave a crash window in which a jobs row exists WITHOUT its ESL link — and the
-- */5 poll then imports the Jobber job as a DUPLICATE row (the exact 2026-06-02
-- class: 680 Jobber jobs, none linked). One SECDEF function, one transaction,
-- no window.
--
-- UPSERT SEMANTICS: keyed on the Jobber GID via entity_source_links, NOT on
-- job_number (jobs_active_job_number_uniq is partial — archived numbers repeat).
-- If the GID is already linked → UPDATE that jobs row; else INSERT + link. So the
-- same function serves create, edit, close and reopen recording, and is idempotent
-- against replays.
--
-- NO-CLOBBER: mirrors handleJob's semantics — client_id / property_id /
-- frequency_days / notes are written only when the payload carries them
-- (jsonb key present), never NULLed by omission. p_line_items:
--   absent/null  -> line items untouched
--   json array   -> wipe job-scoped lines + reinsert (the sync's shape). The wipe
--                   is scoped job_id = X AND visit_id IS NULL AND invoice_id IS
--                   NULL — STRICTLY NARROWER than handleJob's wipe-by-job_id, so
--                   visit- or invoice-attached rows can never be collateral.
--
-- AUDIT: jobs is audited as of 2026-07-30_1531; this function's writes land with
-- app_source='client-app' (the edge fn's service client sets X-App-Source).
--
-- ROLLBACK: drop function public.fn_record_client_job(jsonb);
-- ============================================================================

begin;

create or replace function public.fn_record_client_job(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_gid     text := nullif(btrim(coalesce(p->>'gid','')), '');
  v_job_id  bigint;
  v_created boolean := false;
  v_li      jsonb := p->'line_items';
  v_r       record;
begin
  if v_gid is null then
    raise exception 'fn_record_client_job: gid is required' using errcode = '22023';
  end if;

  select l.entity_id into v_job_id
    from public.entity_source_links l
   where l.entity_type = 'job' and l.source_system = 'jobber' and l.source_id = v_gid;

  if v_job_id is null then
    insert into public.jobs (client_id, property_id, job_number, title, job_status,
                             start_at, end_at, total, notes, frequency_days)
    values ((p->>'client_id')::bigint,
            (p->>'property_id')::bigint,
            p->>'job_number',
            p->>'title',
            lower(p->>'job_status'),
            nullif(p->>'start_at','')::timestamptz,
            nullif(p->>'end_at','')::timestamptz,
            nullif(p->>'total','')::numeric,
            p->>'notes',
            nullif(p->>'frequency_days','')::integer)
    returning id into v_job_id;
    v_created := true;

    insert into public.entity_source_links
      (entity_type, entity_id, source_system, source_id, source_name, match_method, match_confidence)
    values ('job', v_job_id, 'jobber', v_gid, p->>'title', 'client-app', 1.0)
    on conflict (entity_type, entity_id, source_system)
    do update set source_id = excluded.source_id, source_name = excluded.source_name;
  else
    update public.jobs j
       set title          = coalesce(p->>'title', j.title),
           job_status     = coalesce(lower(p->>'job_status'), j.job_status),
           start_at       = case when p ? 'start_at' then nullif(p->>'start_at','')::timestamptz else j.start_at end,
           end_at         = case when p ? 'end_at'   then nullif(p->>'end_at','')::timestamptz   else j.end_at   end,
           total          = case when p ? 'total'    then nullif(p->>'total','')::numeric        else j.total    end,
           notes          = case when p ? 'notes'    then p->>'notes'                            else j.notes    end,
           frequency_days = case when p ? 'frequency_days'
                                 then nullif(p->>'frequency_days','')::integer
                                 else j.frequency_days end
     where j.id = v_job_id;
  end if;

  if v_li is not null and jsonb_typeof(v_li) = 'array' then
    delete from public.line_items
     where job_id = v_job_id and visit_id is null and invoice_id is null;
    for v_r in select * from jsonb_array_elements(v_li) as e(x) loop
      insert into public.line_items (job_id, name, quantity, unit_price, total_price)
      values (v_job_id,
              v_r.x->>'name',
              coalesce(nullif(v_r.x->>'quantity','')::numeric, 1),
              nullif(v_r.x->>'unit_price','')::numeric,
              nullif(v_r.x->>'total_price','')::numeric);
    end loop;
  end if;

  return jsonb_build_object('job_id', v_job_id, 'created', v_created);
end
$fn$;

revoke all on function public.fn_record_client_job(jsonb) from public;
revoke all on function public.fn_record_client_job(jsonb) from anon;
revoke all on function public.fn_record_client_job(jsonb) from authenticated;
grant execute on function public.fn_record_client_job(jsonb) to service_role;

commit;
