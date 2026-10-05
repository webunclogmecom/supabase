-- Permit names: read on UPLOAD (trigger), keep a daily safety net, and fix the retry rule
--
-- Fred, 2026-10-05: "why do we need a cron of every 15 minutes? why not just a trigger of when
-- uploading the PDF?" then "yes" to: trigger first, daily cron only to retry failures.
-- Follows 2026-10-05_0640_gdo_permit_label_from_pdf.sql.
--
-- 1. TWO TRIGGERS, because a new PDF reaches a permit two ways:
--    * storage.objects (bucket gdo-permits) INSERT or UPDATE: a PDF uploaded or overwritten at the same
--      path. postgres holds TRIGGER on storage.objects (measured: created and rolled back cleanly).
--    * public.gdos INSERT or UPDATE OF permit_document_path: a permit pointed at a new file (the
--      Client App uploads "-uploaded-<date>.pdf" then saves the permit, so the object row exists first
--      and only this second event can match it).
--    Both call public.fn_request_gdo_permit_label_sweep(), which posts to edge fn gdo-permit-label only
--    when a permit is waiting (net.http_post is queued and sent after COMMIT, so a rolled-back save
--    sends nothing). Both swallow their own errors: a failed request must never block a permit save or
--    a file upload; the daily safety net retries.
-- 2. RETRY RULE: a permit is waiting when its CURRENT PDF (gdo + storage eTag) has no read yet, or its
--    LATEST read is an error with fewer than 3 errors in the last 24 hours. Before this, any earlier
--    non-error row (the install's 'seeded') hid a later error for ever, so the 9 permits that failed on
--    2026-10-05 when the Anthropic credit ran out would never have been retried. An 'error' is a
--    transport/API/download failure; an unreadable PDF is 'unreadable' and is not retried.
-- 3. The cron gdo-permit-label-sweep goes from every 15 minutes to once a day, 05:11 ET (09:11 UTC):
--    a safety net for failures, not the main path. Posts up to 10 per request (was 3).
-- Rule 8: no new table; public.gdos writes stay audited as app_source 'gdo-permit-reader'.

begin;

create or replace function public.fn_gdo_permit_label_targets(p_limit integer default 3, p_gdo_ids bigint[] default null)
returns table (gdo_id bigint, storage_path text, etag text, current_label text)
language sql stable security definer
set search_path = public, storage
as $$
  select g.id, g.permit_document_path, o.metadata->>'eTag', g.location_label
    from public.gdos g
    join storage.objects o on o.bucket_id = 'gdo-permits' and o.name = g.permit_document_path
    left join lateral (select r.outcome from public.gdo_permit_label_reads r
                        where r.gdo_id = g.id and r.etag = o.metadata->>'eTag'
                        order by r.read_at desc, r.id desc limit 1) last on true
   where o.metadata->>'eTag' is not null
     and (
       (p_gdo_ids is not null and g.id = any (p_gdo_ids))
       or (p_gdo_ids is null
           and (last.outcome is null
                or (last.outcome = 'error'
                    and (select count(*) from public.gdo_permit_label_reads r
                          where r.gdo_id = g.id and r.etag = o.metadata->>'eTag' and r.outcome = 'error'
                            and r.read_at > now() - interval '24 hours') < 3)))
     )
   order by g.id
   limit greatest(coalesce(p_limit, 3), 0)
$$;

create or replace function public.fn_request_gdo_permit_label_sweep()
returns void
language plpgsql security definer
set search_path = public
as $$
declare v_key text;
begin
  if not exists (select 1 from public.fn_gdo_permit_label_targets(1, null)) then
    return;   -- nothing to read: no HTTP call
  end if;
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'edge_invoke_service_key';
  if v_key is null then
    raise warning 'edge_invoke_service_key vault secret missing; skipping permit label sweep';
    return;
  end if;
  perform net.http_post(
    url := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/gdo-permit-label',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||v_key),
    body := jsonb_build_object('limit', 10),
    timeout_milliseconds := 150000);
end; $$;

create function public.trg_gdo_permit_label_request()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  perform public.fn_request_gdo_permit_label_sweep();
  return null;
exception when others then
  raise warning 'gdo permit label request failed (% %); the daily sweep will retry', sqlstate, sqlerrm;
  return null;
end; $$;
revoke all on function public.trg_gdo_permit_label_request() from public, anon, authenticated;

create trigger zz_gdo_permit_label_on_upload
  after insert or update on storage.objects
  for each row when (new.bucket_id = 'gdo-permits')
  execute function public.trg_gdo_permit_label_request();

create trigger zz_gdo_permit_label_on_path
  after insert or update of permit_document_path on public.gdos
  for each statement
  execute function public.trg_gdo_permit_label_request();

select cron.alter_job((select jobid from cron.job where jobname = 'gdo-permit-label-sweep'),
                      schedule := '11 9 * * *');

do $verify$
declare n int; s text;
begin
  -- the 9 permits that failed on 2026-10-05 (latest read = error) are waiting again
  select count(*) into n from public.fn_gdo_permit_label_targets(100, null)
   where gdo_id in (75,169,170,171,177,207,210,253,254);
  if n <> 9 then raise exception 'VERIFY retry rule: % of the 9 failed permits are waiting', n; end if;
  -- and nothing whose latest read is seeded/set/same/unreadable/not_pdf
  select count(*) into n from public.fn_gdo_permit_label_targets(1000, null) t
   where not exists (select 1 from public.gdo_permit_label_reads r where r.gdo_id = t.gdo_id and r.outcome = 'error');
  if n <> 0 then raise exception 'VERIFY: % permits waiting that never errored', n; end if;
  select schedule into s from cron.job where jobname = 'gdo-permit-label-sweep';
  if s <> '11 9 * * *' then raise exception 'VERIFY cron schedule: %', s; end if;
  if (select count(*) from pg_trigger where tgname in ('zz_gdo_permit_label_on_upload','zz_gdo_permit_label_on_path')) <> 2 then
    raise exception 'VERIFY triggers missing'; end if;
  if has_function_privilege('authenticated', 'public.trg_gdo_permit_label_request()', 'EXECUTE') then
    raise exception 'VERIFY trigger function executable by authenticated'; end if;
end $verify$;

commit;
