-- ============================================================================
-- 2026-08-01_1120 — Persist a job's BILLING settings so the app can show them
-- ============================================================================
-- ASK (Fred, 2026-08-01): "it seems i can't change the Jobs data in the clients
-- app, why? i want to change the settings of the existing Jobs too, i'm pretty
-- sure anything set on a job on the moment of creation can be changed."
--
-- ---------------------------------------------------------------------------
-- WHY THIS MIGRATION EXISTS (measured, not assumed)
-- ---------------------------------------------------------------------------
-- The Edit-job dialog renders "Billing type" and "Invoice frequency" controls,
-- but `public.jobs` HAS NO BILLING COLUMNS. Billing is sent to Jobber on create
-- and never persisted, so:
--
--   1. the dialog cannot show a job's real billing - it always falls back to
--      "Visit based" + "After each visit is completed", whatever the job
--      actually is in Jobber; and
--   2. because the dialog sends only CHANGED keys, a user who touches one
--      billing control submits the *displayed* value for the other half -
--      i.e. a wrong default can silently rewrite the real setting.
--
-- (2) is the reason this is a migration and not just an edge-function change.
-- Making billing editable while the form is pre-filled from a guess would turn
-- a read-only display bug into a write bug.
--
-- ---------------------------------------------------------------------------
-- WHY THESE COLUMNS ARE SAFE TO STORE (the clobber question)
-- ---------------------------------------------------------------------------
-- A locally-written jobs column is only safe if no inbound path overwrites it.
-- Measured over the two inbound writers:
--   * webhook-jobber handleJob unconditionally overwrites title, job_status,
--     start_at, end_at, job_number (and frequency_days when Jobber's Frequency
--     custom field is present). It does not know these columns exist.
--   * sync-jobber-job-drift reconciles 5 scalars + job line items, Jobber -> DB
--     only. It does not know these columns exist either.
-- So nothing clobbers them. They are written ONLY by fn_record_client_job, from
-- the VERIFIED post-mutation read of the Jobber job - never from what the caller
-- asked for. That ordering matters: we record what Jobber confirmed, not intent.
--
-- ⚠ KNOWN AND ACCEPTED GAP: a billing change made directly in Jobber's own UI
-- does NOT flow back here, because the drift reconciler does not compare these
-- fields. They are therefore "last known confirmed by us", not a live mirror.
-- The app must label them as such rather than implying real-time truth. Adding
-- them to the drift diff is a separate, larger change (it would need the
-- reconciler to fetch invoiceSchedule for all 462 candidates every 30 minutes).
--
-- 3NF / Rule 1: these are attributes of the job itself, functionally dependent
-- on the job's own key - not a copy of anything referenced elsewhere. No new
-- table is warranted. invoice_rrule is NULL except for periodic schedules.
-- Audit (ADR 010): public.jobs already carries an audit trigger (added
-- 2026-07-30_1531), so the new columns are captured automatically.
--
-- ROLLBACK:
--   alter table public.jobs drop column billing_type,
--                           drop column invoice_frequency,
--                           drop column invoice_rrule;
--   -- then restore client.jobs and fn_record_client_job from 2026-07-31_1035
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. the columns
-- ---------------------------------------------------------------------------
alter table public.jobs
  add column if not exists billing_type      text,
  add column if not exists invoice_frequency text,
  add column if not exists invoice_rrule     text;

-- Constrain to the vocabulary save-client-job already uses, so a bad value
-- cannot reach the app and render as a silently wrong radio button.
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'jobs_billing_type_chk') then
    alter table public.jobs add constraint jobs_billing_type_chk
      check (billing_type is null or billing_type in ('visit_based','fixed'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'jobs_invoice_frequency_chk') then
    alter table public.jobs add constraint jobs_invoice_frequency_chk
      check (invoice_frequency is null or invoice_frequency in
             ('per_visit','monthly_last_day','once_closed','as_needed','custom'));
  end if;
end $$;

comment on column public.jobs.billing_type is
  'visit_based | fixed. Jobber invoicingType VISIT_BASED / FIXED_PRICE. Written ONLY by fn_record_client_job from the verified Jobber read. NULL = never confirmed by us (pre-2026-08-01 job); the app must ask rather than assume. No inbound sync writes this, and a change made in Jobber''s own UI does not flow back.';
comment on column public.jobs.invoice_frequency is
  'per_visit | monthly_last_day | once_closed | as_needed | custom. Maps to Jobber invoicingSchedule PER_VISIT / PERIODIC / ON_COMPLETION / NEVER. Same provenance and same caveat as billing_type.';
comment on column public.jobs.invoice_rrule is
  'The RRULE behind a PERIODIC invoice schedule (e.g. RRULE:FREQ=MONTHLY;BYMONTHDAY=-1). NULL for non-periodic schedules.';

-- ---------------------------------------------------------------------------
-- 2. fn_record_client_job — key-presence-aware, exactly like the existing
--    columns. An absent key must LEAVE THE COLUMN ALONE: the edit path sends a
--    partial patch, and a `coalesce(p->>'x', j.x)` would be wrong for a
--    deliberate NULL while a bare assignment would wipe on every partial write.
-- ---------------------------------------------------------------------------
create or replace function public.fn_record_client_job(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
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
$function$;

-- ---------------------------------------------------------------------------
-- 3. expose them to the app. New columns go at the END so `create or replace
--    view` accepts it (Postgres allows appending, never reordering).
-- ---------------------------------------------------------------------------
create or replace view client.jobs as
  select j.id, j.client_id, j.property_id, j.job_number, j.title, j.job_status,
         j.start_at, j.end_at, j.total, j.created_at, j.updated_at, j.quote_id,
         j.notes, j.frequency_days,
         (select case
                   when l.source_id ~ '^[0-9]+$'
                     then 'https://secure.getjobber.com/work_orders/' || l.source_id
                   when length(l.source_id) % 4 = 0 and l.source_id ~ '^[A-Za-z0-9+/]+={0,2}$'
                     then 'https://secure.getjobber.com/work_orders/' ||
                          split_part(convert_from(decode(l.source_id, 'base64'), 'UTF8'), '/', -1)
                 end
            from public.entity_source_links l
           where l.entity_type = 'job' and l.source_system = 'jobber' and l.entity_id = j.id
           limit 1) as jobber_url,
         j.billing_type,
         j.invoice_frequency,
         j.invoice_rrule
    from public.jobs j;

grant select on client.jobs to authenticated;

commit;
