-- 2026-08-28_0915_client_past_due_jobber_id.sql
--
-- Adds jobber_client_id to ops.v_client_past_due so the Calendar drawer's past-due line can carry a
-- real "Open in Jobber" link instead of a constructed one.
--
-- 🛑 WHY THE ID COMES FROM THE DB AND NOT FROM THE APP. There is a standing rule that a Jobber URL
-- must never be built from a visible human-facing number: Jobber's web app needs an internal id that
-- has no relationship to the numbers we display. The real id lives in
-- `public.entity_source_links.source_id` as a base64 GID, e.g.
--     Z2lkOi8vSm9iYmVyL0NsaWVudC85MTU5Mjc3MA==  ->  gid://Jobber/Client/91592770
-- Decoding it here means the app receives a value it can only use correctly.
--
-- ⚠ FILTER ON source_system = 'jobber' BEFORE DECODING. `entity_type='client'` also holds
-- **airtable** (217) and **samsara** (208) links whose ids are NOT base64, and decoding those raises
-- `22023 invalid base64 end sequence`. That error is how this was found.
--
-- ⚠ The link is per (entity, system) but a client can carry more than one row, so this takes
-- max(...) rather than assuming exactly one and letting the view fail on a duplicate.
--
-- ✅ Coverage measured before writing: all 37 past-due clients have a jobber client link, so the
-- link renders for every one of them. If that ever stops being true the app must render NO link
-- rather than a dead one, which is the same rule the drawer's existing "Open in Jobber" follows.

begin;

create or replace view ops.v_client_past_due as
select
  c.id                                            as client_id,
  c.client_code                                   as client_code,
  count(*)::int                                   as past_due_invoice_count,
  round(sum(i.outstanding_amount)::numeric, 2)    as past_due_amount,
  (
    select max(split_part(convert_from(decode(esl.source_id, 'base64'), 'UTF8'), '/', 5))
    from public.entity_source_links esl
    where esl.entity_type   = 'client'
      and esl.source_system = 'jobber'
      and esl.entity_id     = c.id
  )                                               as jobber_client_id
from public.clients c
join public.invoices i on i.client_id = c.id
where i.invoice_status = 'past_due'
  and i.outstanding_amount > 0
group by c.id, c.client_code;

comment on view ops.v_client_past_due is
  'One row per client carrying a Jobber past_due balance. Definition A (Fred, 2026-08-28): '
  'invoice_status = ''past_due'' AND outstanding_amount > 0. NOT a date comparison; billing truth '
  'is Jobber invoices. jobber_client_id is decoded from the base64 GID in entity_source_links so the '
  'app never constructs a Jobber URL from a displayed number. Consumed by the Visit Calendar card, '
  'hover card and drawer.';

grant select on ops.v_client_past_due to authenticated;
grant select on ops.v_client_past_due to service_role;
grant select on ops.v_client_past_due to yannick_readonly;

-- ─── VERIFY ───────────────────────────────────────────────────────────────────────────────────
do $$
declare
  bad text := '';
  v_clients int; v_invs int; v_amt numeric; v_with_jobber int; v_bad_shape int;
  v_alc text;
begin
  select count(*), sum(past_due_invoice_count), round(sum(past_due_amount),2),
         count(jobber_client_id)
    into v_clients, v_invs, v_amt, v_with_jobber
  from ops.v_client_past_due;

  -- 1. the definition did not drift while adding a column
  if v_clients <> 37 then bad := bad || 'clients ' || v_clients || ' not 37; '; end if;
  if v_invs <> 40 then bad := bad || 'invoices ' || v_invs || ' not 40; '; end if;
  if v_amt <> 34795.02 then bad := bad || 'amount ' || v_amt || ' not 34795.02; '; end if;

  -- 2. every past-due client resolves to a Jobber id
  if v_with_jobber <> v_clients then
    bad := bad || 'only ' || v_with_jobber || ' of ' || v_clients || ' have a jobber_client_id; ';
  end if;

  -- 3. 🛑 the id must be all digits. A decode that silently produced a GID fragment, an
  --    airtable rec-id or an empty string would still be non-null, so non-null is NOT the test.
  select count(*) into v_bad_shape
    from ops.v_client_past_due
   where jobber_client_id is not null and jobber_client_id !~ '^[0-9]+$';
  if v_bad_shape > 0 then
    bad := bad || v_bad_shape || ' jobber_client_id values are not purely numeric; ';
  end if;

  -- 4. named fixture stays put
  select jobber_client_id into v_alc from ops.v_client_past_due where client_code = '293-ALC';
  if v_alc is null or v_alc !~ '^[0-9]+$' then
    bad := bad || '293-ALC jobber_client_id is ' || coalesce(v_alc,'null') || '; ';
  end if;

  if bad <> '' then raise exception 'jobber_client_id verification FAILED: %', bad; end if;
  raise notice 'verified: % clients, % invoices, $%, all with a numeric jobber_client_id (293-ALC = %)',
    v_clients, v_invs, v_amt, v_alc;
end $$;

notify pgrst, 'reload schema';

commit;
