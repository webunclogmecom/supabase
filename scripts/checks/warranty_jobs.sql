-- Warranty of Drainage subscriptions (Trello #179, Fred 2026-11-06): live jobs whose only service is code 08.
-- Run as owner, read only. Every row below is a job to look at; a healthy estate returns none but the CONTROL.
--   no_frequency_zero  it holds a frequency, which would do nothing (the generator never books code 08)
--   never_invoices     it invoices per visit, and it has no visits (a live visit_based job on a schedule is fine)
--   ended              past its end date: Jobber stops asking for invoices, so the subscription has gone quiet
--   ends_soon          ends within 60 days: someone must extend it in Jobber, nothing renews it
-- CONTROL: must read at least 1, or this file is reading nothing and its silence proves nothing.
with w as (
  select j.id, j.job_number, j.frequency_days, j.invoice_frequency, j.end_at, c.client_code
    from public.jobs j
    join public.clients c on c.id = j.client_id
   where j.job_status not in ('archived', 'destroyed')
     and j.title not ilike '%test%'
     and c.client_code <> '112-YA'
     and exists (select 1 from public.line_items li where li.job_id = j.id and li.visit_id is null and li.invoice_id is null and li.name ~ '^0?8[[:space:]]*-')
     and not exists (select 1 from public.line_items li where li.job_id = j.id and li.visit_id is null and li.invoice_id is null and li.name ~ '^0?[1-7][[:space:]]*-')
)
select 'CONTROL: live warranty-only jobs' as issue, count(*)::text as detail from w
union all select 'no_frequency_zero', job_number || ' ' || client_code || ' frequency ' || frequency_days from w where coalesce(frequency_days, 0) <> 0
union all select 'never_invoices', job_number || ' ' || client_code from w where invoice_frequency = 'per_visit'
union all select 'ended', job_number || ' ' || client_code || ' ended ' || (end_at at time zone 'America/New_York')::date from w where end_at < now()
union all select 'ends_soon', job_number || ' ' || client_code || ' ends ' || (end_at at time zone 'America/New_York')::date from w where end_at >= now() and end_at < now() + interval '60 days'
order by 1;
