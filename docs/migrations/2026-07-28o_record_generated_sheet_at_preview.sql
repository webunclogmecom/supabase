-- ============================================================================
-- 2026-07-28o — record a generated sheet AT GENERATION, keyed on CLIENTS
-- ============================================================================
-- Fred, 2026-07-28: "make the preview record provenance". The /upload download
-- button (the pdf-service PREVIEW endpoint) is what the office actually prints,
-- and it wrote nothing, so Stamp Studio never knew a sheet was ours and auto-fill
-- could not fire. That is the root cause diagnosed today.
--
-- ⚠ WHY A NEW TABLE AND NOT record_generated_address_sheet(manifest_ids):
-- the preview renders from VISIT ids, BEFORE the dump. Manifests do not exist
-- yet — they are created afterwards from the finished paper sheet, and the schema
-- enforces that (derm_manifests requires dump_ticket_date + disposal_facility_id,
-- both of which only exist post-dump). Worse, the sheet cannot know its TICKET
-- NUMBER at generation either: the county assigns that at the dump and it is
-- hand-written onto the paper. So at generation the only durable identity is
-- "sheet number N was printed for these clients, in this order".
--
-- THE MODEL:
--   generation time  -> derm.address_sheet_clients   (sheet, slot, client, visit)
--   filing time      -> derm.address_sheet_manifests (sheet, manifest, slot)
--   the second is RESOLVED from the first once the manifests exist.
--
-- ORDER IS THE POINT. The preview deliberately preserves the operator's selection
-- order ("Preserve caller's order so the PDF rows match the user's selection
-- order", supabase_client.py), and that order is not derivable from anything
-- stored — nine candidate orderings were tested against two physical sheets and
-- all nine scored 0/2. Recording it here is the only way it is ever knowable.
--
-- ⚠ THE RESOLVER IS DELIBERATELY CONSERVATIVE. Linking the WRONG generated sheet
-- to a ticket would auto-stamp every client onto the wrong row, and the Field
-- Portal blackout would then show each customer someone else's row. So the link
-- is made ONLY on an exact, unambiguous client-set match:
--   * the sheet's client set must equal the ticket's client set exactly,
--   * exactly ONE unlinked candidate sheet may match,
--   * the sheet must not already be linked to a different ticket.
-- Anything ambiguous is left unlinked, fn_sheet_is_generated stays FALSE, and
-- auto-fill refuses to place (2026-07-28n). Refusing is safe; guessing is not.
--
-- AUDIT (ADR 010): derm.* Stamp-Studio/provenance working state, unaudited by
-- design, consistent with address_sheets and address_sheet_manifests.
-- ============================================================================

begin;

-- 1) what the generator knew at print time ------------------------------------
create table if not exists derm.address_sheet_clients (
  sheet_id   bigint  not null references derm.address_sheets(id) on delete cascade,
  slot       integer not null,
  client_id  bigint  not null references public.clients(id),
  visit_id   bigint,
  created_at timestamptz not null default now(),
  primary key (sheet_id, slot)
);
create index if not exists address_sheet_clients_client_idx on derm.address_sheet_clients (client_id);
comment on table derm.address_sheet_clients is
  'The Section B client order a generated sheet was PRINTED with, captured at generation time when no manifest and no ticket number exist yet. slot is 1-based printed position. Resolved into address_sheet_manifests once the manifests are filed.';

-- 2) the preview records itself ------------------------------------------------
create or replace function derm.record_generated_sheet_preview(
  p_sheet_no   bigint,
  p_client_ids bigint[],
  p_visit_ids  bigint[] default null
) returns bigint
language plpgsql security definer set search_path to 'derm','public'
as $fn$
declare v_sheet_id bigint;
begin
  if p_sheet_no is null or p_client_ids is null or array_length(p_client_ids,1) is null then
    raise exception 'sheet_no and client_ids are required';
  end if;

  insert into derm.address_sheets (sheet_no, pdf_bucket, pdf_path)
  values (p_sheet_no, 'preview', 'preview/' || p_sheet_no::text)
  on conflict (sheet_no) where deleted_at is null
  do update set last_generated_at = now()
  returning id into v_sheet_id;

  -- a regeneration of the same sheet number replaces its printed order
  delete from derm.address_sheet_clients where sheet_id = v_sheet_id;
  insert into derm.address_sheet_clients (sheet_id, slot, client_id, visit_id)
  select v_sheet_id, t.ord, t.cid,
         (select p_visit_ids[t.ord] where p_visit_ids is not null)
    from unnest(p_client_ids) with ordinality as t(cid, ord);

  return v_sheet_id;
end $fn$;

revoke all on function derm.record_generated_sheet_preview(bigint, bigint[], bigint[]) from public, anon;
grant execute on function derm.record_generated_sheet_preview(bigint, bigint[], bigint[]) to service_role;

-- 3) resolve sheet -> ticket once the manifests exist ---------------------------
create or replace function derm.fn_resolve_generated_sheet_for_ticket(p_ticket text)
returns bigint
language plpgsql security definer set search_path to 'derm','public'
as $fn$
declare v_sheet_id bigint; v_n int;
begin
  if p_ticket is null then return null; end if;

  -- already resolved?
  select s.id into v_sheet_id
    from derm.address_sheets s
    join derm.address_sheet_manifests l on l.sheet_id = s.id
    join public.derm_manifests m on m.id = l.manifest_id and m.deleted_at is null
   where s.deleted_at is null
     and coalesce(m.white_manifest_number, m.yellow_ticket_number) = p_ticket
   limit 1;
  if v_sheet_id is not null then return v_sheet_id; end if;

  -- candidates whose printed client set EXACTLY equals the ticket's client set
  with ticket_clients as (
    select distinct m.client_id
      from public.derm_manifests m
     where coalesce(m.white_manifest_number, m.yellow_ticket_number) = p_ticket
       and m.deleted_at is null
  ), cand as (
    select c.sheet_id
      from derm.address_sheet_clients c
      join derm.address_sheets s on s.id = c.sheet_id and s.deleted_at is null
     where not exists (select 1 from derm.address_sheet_manifests l where l.sheet_id = c.sheet_id)
     group by c.sheet_id
    having array_agg(distinct c.client_id order by c.client_id)
         = (select array_agg(distinct tc.client_id order by tc.client_id) from ticket_clients tc)
  )
  select count(*), min(sheet_id) into v_n, v_sheet_id from cand;

  -- exactly one unambiguous match, or nothing
  if v_n <> 1 then return null; end if;

  insert into derm.address_sheet_manifests (sheet_id, manifest_id, slot)
  select v_sheet_id, m.id, c.slot
    from public.derm_manifests m
    join derm.address_sheet_clients c
      on c.client_id = m.client_id and c.sheet_id = v_sheet_id
   where coalesce(m.white_manifest_number, m.yellow_ticket_number) = p_ticket
     and m.deleted_at is null
  on conflict (sheet_id, manifest_id) do update set slot = excluded.slot;

  update public.derm_manifests m
     set derm_address_no = (select s.sheet_no from derm.address_sheets s where s.id = v_sheet_id)
   where coalesce(m.white_manifest_number, m.yellow_ticket_number) = p_ticket
     and m.deleted_at is null
     and m.derm_address_no is distinct from (select s.sheet_no from derm.address_sheets s where s.id = v_sheet_id);

  return v_sheet_id;
end $fn$;

revoke all on function derm.fn_resolve_generated_sheet_for_ticket(text) from public, anon;
grant execute on function derm.fn_resolve_generated_sheet_for_ticket(text) to authenticated, service_role;

commit;

-- ----------------------------------------------------------------------------
-- 2026-07-28o (amendment) — PUBLIC wrappers so PostgREST can actually reach these.
-- The pdf-service builds its client with create_client(url, key) and sends NO
-- Accept-Profile/Content-Profile header, so sb.rpc('x') resolves to PUBLIC.x.
-- A derm-only function returns 404 PGRST202 ("Searched for the function
-- public.record_generated_sheet_preview ... no matches"), and because the caller
-- treats provenance as best-effort that 404 would have been swallowed into a log
-- line — leaving derm.address_sheets empty forever, i.e. the exact bug being fixed.
-- Verified by calling the endpoint the same way the service does. This is why
-- public.record_generated_address_sheet already exists as a wrapper.
-- ----------------------------------------------------------------------------
create or replace function public.record_generated_sheet_preview(
  p_sheet_no bigint, p_client_ids bigint[], p_visit_ids bigint[] default null
) returns bigint language sql security definer set search_path to 'derm','public'
as $w$ select derm.record_generated_sheet_preview(p_sheet_no, p_client_ids, p_visit_ids) $w$;

revoke all on function public.record_generated_sheet_preview(bigint, bigint[], bigint[]) from public, anon;
grant execute on function public.record_generated_sheet_preview(bigint, bigint[], bigint[]) to service_role;

create or replace function public.fn_resolve_generated_sheet_for_ticket(p_ticket text)
returns bigint language sql security definer set search_path to 'derm','public'
as $w$ select derm.fn_resolve_generated_sheet_for_ticket(p_ticket) $w$;

revoke all on function public.fn_resolve_generated_sheet_for_ticket(text) from public, anon;
grant execute on function public.fn_resolve_generated_sheet_for_ticket(text) to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 2026-07-28o (amendment 2) — close an escalation the wrapper opened.
-- Supabase ALTER DEFAULT PRIVILEGES grants EXECUTE on new public.* functions to
-- authenticated. "revoke ... from public, anon" does NOT remove that explicit
-- grant, so public.record_generated_sheet_preview came out authenticated=true
-- while its derm.* target was authenticated=false. The wrapper is SECURITY
-- DEFINER, so that let any signed-in staff user FABRICATE provenance: invent a
-- sheet for arbitrary client ids, have it resolve onto a real ticket, and drive
-- auto-fill to stamp clients onto rows they are not on — which the Field Portal
-- blackout then serves to the wrong customer. Only the pdf-service (service_role)
-- may assert that we generated a sheet.
-- fn_resolve_generated_sheet_for_ticket deliberately KEEPS authenticated: it
-- creates nothing, only links an already-recorded sheet on an exact client-set
-- match, so the filing app can trigger resolution.
-- ----------------------------------------------------------------------------
revoke all on function public.record_generated_sheet_preview(bigint, bigint[], bigint[]) from authenticated;
revoke all on function derm.record_generated_sheet_preview(bigint, bigint[], bigint[]) from authenticated;
