-- Permit names come from the permit PDF, from now on (Fred, 2026-10-05: "yes build both")
--
-- gdos.location_label (the name under the permit number on the Field Portal card, the Client App
-- permit editor, the DERM Tracker and the Stamp Studio) was written once by a 2026-05-22 DERM portal
-- lookup that stored the county's facility name on record, sometimes a previous tenant. 13 labels
-- were corrected by hand to the PDF's "Permit Issued To" on 2026-10-02 (backup
-- backups/2026-10-02_gdo_location_label_before.json). Nothing kept them right after that.
--
-- This adds the automatic half:
--   * public.gdo_permit_label_reads: ledger, one row per read of (gdo, storage object eTag).
--     A replaced PDF has a new eTag and is read again; a staff edit of the label in the Client App
--     stands until the PDF itself changes. Rule 8: OPT-OUT, a machine ledger whose every effect lands
--     in public.gdos, which is audited (app_source 'gdo-permit-reader', header from the edge fn).
--   * public.fn_gdo_permit_label_targets(p_limit, p_gdo_ids): permits whose current PDF object has
--     no successful read and fewer than 3 errors; p_gdo_ids re-reads given permits whatever the ledger.
--   * public.fn_request_gdo_permit_label_sweep(): posts to edge fn gdo-permit-label only when there
--     is something to read (no HTTP call otherwise), cron gdo-permit-label-sweep every 15 minutes.
--   * SEED: every permit's CURRENT object is recorded 'seeded', so installing this rewrites no label
--     (the 13 hand-set ones, the two 148-MOR staff labels and the 113 blank ones stay as they are).
--     Filling the blanks is a separate decision.
-- The two backfill scripts that wrote the portal name no longer write location_label (same commit).

begin;

create table public.gdo_permit_label_reads (
  id           bigserial primary key,
  gdo_id       bigint not null references public.gdos(id),
  storage_path text not null,
  etag         text not null,
  outcome      text not null check (outcome in ('seeded','set','same','unreadable','not_pdf','error')),
  issued_to    text,
  detail       text,
  read_at      timestamptz not null default now()
);
create index gdo_permit_label_reads_gdo_etag_idx on public.gdo_permit_label_reads (gdo_id, etag);
alter table public.gdo_permit_label_reads enable row level security;
revoke all on public.gdo_permit_label_reads from public, anon, authenticated;
revoke all on sequence public.gdo_permit_label_reads_id_seq from public, anon, authenticated;
grant select, insert on public.gdo_permit_label_reads to service_role;
grant usage on sequence public.gdo_permit_label_reads_id_seq to service_role;
comment on table public.gdo_permit_label_reads is
  'One row per read of a permit PDF (gdo + storage eTag) by edge fn gdo-permit-label. seeded = present at install, never read. 2026-10-05_0640.';

create function public.fn_gdo_permit_label_targets(p_limit integer default 3, p_gdo_ids bigint[] default null)
returns table (gdo_id bigint, storage_path text, etag text, current_label text)
language sql stable security definer
set search_path = public, storage
as $$
  select g.id, g.permit_document_path, o.metadata->>'eTag', g.location_label
    from public.gdos g
    join storage.objects o on o.bucket_id = 'gdo-permits' and o.name = g.permit_document_path
   where o.metadata->>'eTag' is not null
     and (
       (p_gdo_ids is not null and g.id = any (p_gdo_ids))
       or (p_gdo_ids is null
           and not exists (select 1 from public.gdo_permit_label_reads r
                            where r.gdo_id = g.id and r.etag = o.metadata->>'eTag' and r.outcome <> 'error')
           and (select count(*) from public.gdo_permit_label_reads r
                 where r.gdo_id = g.id and r.etag = o.metadata->>'eTag' and r.outcome = 'error') < 3)
     )
   order by g.id
   limit greatest(coalesce(p_limit, 3), 0)
$$;
revoke all on function public.fn_gdo_permit_label_targets(integer, bigint[]) from public, anon, authenticated;
grant execute on function public.fn_gdo_permit_label_targets(integer, bigint[]) to service_role;

create function public.fn_request_gdo_permit_label_sweep()
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
    body := jsonb_build_object('limit', 3),
    timeout_milliseconds := 150000);
end; $$;
revoke all on function public.fn_request_gdo_permit_label_sweep() from public, anon, authenticated;

insert into public.gdo_permit_label_reads (gdo_id, storage_path, etag, outcome, issued_to, detail)
select g.id, g.permit_document_path, o.metadata->>'eTag', 'seeded', g.location_label, 'present at install, not read'
  from public.gdos g
  join storage.objects o on o.bucket_id = 'gdo-permits' and o.name = g.permit_document_path
 where o.metadata->>'eTag' is not null;

select cron.schedule('gdo-permit-label-sweep', '11-59/15 * * * *',
                     'select public.fn_request_gdo_permit_label_sweep()');

do $verify$
declare n int;
begin
  select count(*) into n from public.fn_gdo_permit_label_targets(100, null);
  if n <> 0 then raise exception 'VERIFY: % permits still targeted after the seed', n; end if;
  select count(*) into n from public.fn_gdo_permit_label_targets(10, array[129]::bigint[]);
  if n <> 1 then raise exception 'VERIFY control: explicit re-read of gdo 129 returned % rows', n; end if;
  if has_table_privilege('authenticated', 'public.gdo_permit_label_reads', 'SELECT')
     or has_table_privilege('anon', 'public.gdo_permit_label_reads', 'SELECT') then
    raise exception 'VERIFY: ledger readable by anon/authenticated'; end if;
  if has_function_privilege('authenticated', 'public.fn_gdo_permit_label_targets(integer, bigint[])', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.fn_request_gdo_permit_label_sweep()', 'EXECUTE')
     or has_function_privilege('anon', 'public.fn_request_gdo_permit_label_sweep()', 'EXECUTE') then
    raise exception 'VERIFY: functions executable by anon/authenticated'; end if;
  if not exists (select 1 from cron.job where jobname = 'gdo-permit-label-sweep') then
    raise exception 'VERIFY: cron missing'; end if;
end $verify$;

commit;
