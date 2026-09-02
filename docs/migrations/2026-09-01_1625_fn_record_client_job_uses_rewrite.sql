-- 2026-09-01_1625_fn_record_client_job_uses_rewrite.sql
--
-- WHAT: route public.fn_record_client_job's line-item block through public.rewrite_job_line_items
--   (the atomic, per-job-serialized rewrite from 2026-09-01_1620), so the third of the three inbound
--   line-item writers no longer does its own non-atomic delete-then-insert. Completes the fix for the
--   duplication race (webhook-jobber and sync-jobber-job-drift are done in the same cycle, edge-fn side).
-- HOW: CREATE OR REPLACE with the EXACT live pg_get_functiondef body; ONLY the line-item block changed
--   (copy, don't retype). The v_li guard is kept, so behavior is identical: v_li null/not-array -> no
--   delete (unchanged); an array -> the RPC deletes, then inserts only if the array is NON-EMPTY
--   (rewrite_job_line_items guards the INSERT with jsonb_array_length(p_lines) > 0, so an EMPTY array
--   deletes then inserts nothing, i.e. clears the job's job-scope lines). CREATE OR REPLACE preserves
--   the existing service_role-only grants.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_record_client_job(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_gid     text := nullif(btrim(coalesce(p->>'gid','')), '');
  v_job_id  bigint;
  v_created boolean := false;
  v_li      jsonb := p->'line_items';
  v_r       record;
begin

  -- ---- ATTEST THE HUMAN, so the audit trail names a person and not an app ---------------------
  -- 🛑 WHY THIS IS HERE AND NOT IN THE EDGE FUNCTION. audit.log_change reads
  --    current_setting('request.jwt.claims'), and that GUC is TRANSACTION-scoped. save-client-job
  --    writes as service_role over PostgREST, where each call is its own transaction, so a claim
  --    set outside this function would not be visible to the trigger that fires inside it. It has
  --    to be set in the same transaction as the write, which means here.
  -- ⚠ TRUST MODEL: this function is SECURITY DEFINER and only service_role may execute it, so the
  --    only callers are our own edge functions, each of which has already verified the bearer token
  --    with auth.getUser() before calling. The email is therefore attested, not asserted by a
  --    browser. Same shape as send-derm-email's sent_by_email (2026-07-21h).
  -- ⚠ OPTIONAL BY DESIGN: a caller that sends no actor_email behaves exactly as before, so this is
  --    a non-breaking change for every existing caller.
  if nullif(btrim(coalesce(p->>'actor_email','')), '') is not null then
    perform set_config('request.jwt.claims',
                       json_build_object('email', btrim(p->>'actor_email'))::text,
                       true);
  end if;

  if v_gid is null then
    raise exception 'fn_record_client_job: gid is required' using errcode = '22023';
  end if;

  select l.entity_id into v_job_id
    from public.entity_source_links l
   where l.entity_type = 'job' and l.source_system = 'jobber' and l.source_id = v_gid;

  if v_job_id is null then
    insert into public.jobs (client_id, property_id, job_number, title, job_status,
                             start_at, end_at, total, notes, frequency_days,
                             billing_type, invoice_frequency, invoice_rrule)
    values ((p->>'client_id')::bigint,
            (p->>'property_id')::bigint,
            p->>'job_number',
            p->>'title',
            lower(p->>'job_status'),
            nullif(p->>'start_at','')::timestamptz,
            nullif(p->>'end_at','')::timestamptz,
            nullif(p->>'total','')::numeric,
            p->>'notes',
            nullif(p->>'frequency_days','')::integer,
            nullif(p->>'billing_type',''),
            nullif(p->>'invoice_frequency',''),
            nullif(p->>'invoice_rrule',''))
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
                                 else j.frequency_days end,
           billing_type      = case when p ? 'billing_type'
                                    then nullif(p->>'billing_type','')      else j.billing_type      end,
           invoice_frequency = case when p ? 'invoice_frequency'
                                    then nullif(p->>'invoice_frequency','') else j.invoice_frequency end,
           invoice_rrule     = case when p ? 'invoice_rrule'
                                    then nullif(p->>'invoice_rrule','')     else j.invoice_rrule     end
     where j.id = v_job_id;
  end if;

  if v_li is not null and jsonb_typeof(v_li) = 'array' then
    -- Atomic, per-job-serialized rewrite via public.rewrite_job_line_items (ends the duplication
    -- race, 2026-09-01). v_li is the same jsonb array this used to loop over; the RPC preserves the
    -- prior mapping (name/quantity/unit_price/total_price; description NULL and taxable false default).
    perform public.rewrite_job_line_items(v_job_id, v_li);
  end if;

  return jsonb_build_object('job_id', v_job_id, 'created', v_created);
end
$function$;

NOTIFY pgrst, 'reload schema';

COMMIT;
