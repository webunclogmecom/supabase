-- =============================================================================
-- 2026-09-08_1500  Per-visit FDEP sheet view + the per-document DETACH control
-- =============================================================================
-- Fred, on the /manifests edit redesign: "editing a manifest, in this case broward
-- should be able to add new visits too", "replace images and everything", and a way
-- to take a wrong sheet off a ticket.
--
-- Two objects, one theme: the edit modal can currently only ADD or REPLACE-IN-PLACE,
-- because public.edit_manifest was given a SET CONTAINMENT guard on 2026-09-08_0330 and
-- now refuses any save that would drop a document the ticket holds. That guard is correct
-- and stays. Removal is a DIFFERENT VERB and gets its own control here, so that "I meant
-- to remove this sheet" and "I accidentally dropped two" stop being the same event --
-- which is the only reason a guard could never tell them apart.
--
-- (*) A PREMISE THIS MIGRATION DELIBERATELY DOES **NOT** ACT ON, BECAUSE IT MEASURED FALSE.
-- An earlier plan added a "Broward branch" to public.file_manifest_on_shared_ticket so it
-- would stop copying a sibling derm_address_url onto a newly added Broward visit. That was
-- written on the assumption that derm_address_url on a Broward ticket is the Broward FDEP
-- sheet. It is not. Measured:
--
--     ticket 312433          yellow-keyed, disposal_facility_id 3, county Broward
--     its address sheet      generated sheet 1102, EIGHT clients on one sheet
--     sheet 1102 clients     every one resolves to ticket 312433 and nothing else
--     yellow-only ticket-*   15 of 48 stamp folders
--     Broward manifests already serving a redacted FP document   162 of 167  (Dade: 525)
--
-- A Broward-OFFLOAD ticket carries the same shared multi-client Miami-Dade DERM_V4.00
-- address sheet as any other ticket, and that is correct -- the LWT scope rule is
-- "pickup in Dade OR offload in Dade", so a Broward-offload load full of Dade pickups
-- still needs the Dade paperwork. So derm_address_url IS shared, inheriting it on an added
-- client IS right, and the patch would have left a client added to any of those 15 folders
-- with no shared sheet, cutting it off from the 162 served FP documents. The Broward FDEP
-- 62-705.300(3) form lives in derm.manifest_visit_sheets and NOWHERE ELSE, so the two
-- documents never collide. public.file_manifest_on_shared_ticket is untouched.
--
-- Rule 8 (audit-trail standing check):
--   * derm.manifest_document_detachments -- OPT OUT, and this is the same call
--     public.derm_portal_requeue made. The table IS the audit trail (who, when, why, what
--     was removed). Auditing an audit ledger doubles every row and adds nothing. The
--     documents themselves live on public.derm_manifests, which IS audited, so the actual
--     column change is captured there with old_row intact and is fully recoverable.
--   * derm.v_manifest_visit_sheets -- a view, nothing to audit.
--
-- (*) NOTHING HERE DELETES A STORAGE BLOB. Detaching is a pointer edit. The six URLs
-- detached by the five historical Miami-Dade incidents are all still in the bucket, which
-- is the only reason those losses are recoverable at all.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- PART 1  derm.v_manifest_visit_sheets -- one row per LINKED VISIT of a manifest
-- -----------------------------------------------------------------------------
-- The grain moved and this view is where that is stated once. A Miami-Dade address sheet
-- is per TICKET (up to five clients share one). The Broward FDEP form is per VISIT and
-- carries its own printed sheet number. The modal needs the visit list either way -- to
-- add to, to attach against, to show as empty -- so the view is a LEFT JOIN from the link
-- table and never from the sheet register. A visit with no FDEP sheet is a row of nulls,
-- not a missing row: today that is EVERY visit in the estate (derm.manifest_visit_sheets
-- holds 0 rows), so an inner join would render the whole feature invisible while looking
-- like a clean empty state.
create or replace view derm.v_manifest_visit_sheets
with (security_invoker = on) as
select
  dm.id                                                       as manifest_id,
  coalesce(dm.white_manifest_number, dm.yellow_ticket_number) as ticket_number,
  dm.white_manifest_number,
  dm.yellow_ticket_number,
  -- (*) The county is the FACILITY's, never the ticket key's. They agree on all 712 live
  -- manifests today (167 yellow = facility 3 = BROWARD, 545 white = facility 2 = DADE),
  -- which is exactly why keying on the ticket number looks right and says nothing.
  dm.disposal_facility_id,
  public.fn_dump_county_bucket(df.county)                     as dump_bucket,
  dm.client_id,
  c.client_code,
  c.name                                                      as client_name,
  mv.visit_id,
  v.visit_date,
  v.visit_status,
  v.completed_at,
  v.property_id,
  p.address                                                   as property_address,
  p.city                                                      as property_city,
  p.state                                                     as property_state,
  p.zip                                                       as property_zip,
  p.county                                                    as property_county,
  s.sheet_no,
  s.form_kind,
  s.pdf_bucket,
  s.pdf_path,
  s.photo_bucket,
  s.photo_path,
  s.generated_at,
  s.uploaded_at,
  (s.manifest_id is not null)                                 as has_sheet,
  -- A sheet the office GENERATED but that has not been adopted onto this manifest yet.
  -- The number is already printed on paper the driver is carrying, so the modal must show
  -- it rather than offer to mint a second one. record_manifest_visit_sheet adopts it.
  g.sheet_no                                                  as generated_sheet_no,
  g.pdf_bucket                                                as generated_pdf_bucket,
  g.pdf_path                                                  as generated_pdf_path,
  g.generated_at                                              as generated_at_source
from public.derm_manifests dm
join public.manifest_visits mv          on mv.manifest_id = dm.id
join public.visits v                    on v.id = mv.visit_id and v.deleted_at is null
left join public.clients c              on c.id = dm.client_id
left join public.properties p           on p.id = v.property_id
left join public.disposal_facilities df on df.id = dm.disposal_facility_id
left join derm.manifest_visit_sheets s  on s.manifest_id = dm.id
                                       and s.visit_id    = mv.visit_id
                                       and s.deleted_at is null
left join derm.generated_visit_sheets g on g.visit_id = mv.visit_id
                                       and g.deleted_at is null
where dm.deleted_at is null;

comment on view derm.v_manifest_visit_sheets is
  'One row per LINKED VISIT of a live manifest, LEFT JOINed to its Broward FDEP per-visit '
  'sheet (derm.manifest_visit_sheets) and to any sheet the office generated but has not '
  'adopted yet (derm.generated_visit_sheets). A visit with no sheet is a row of nulls, not '
  'a missing row. dump_bucket comes from the disposal FACILITY, never from whether the '
  'ticket is white- or yellow-keyed. Read by the DERM Tracker /manifests edit modal.';

-- security_invoker is on, so the caller needs the underlying grants in their own right.
-- authenticated was verified to hold SELECT on all six base relations and EXECUTE on
-- public.fn_dump_county_bucket before this shipped; VERIFY 1 re-asserts it AS THAT ROLE
-- rather than trusting the reasoning, because a SECURITY INVOKER function called from a
-- view adds an invoker-side EXECUTE check to the view's read path -- the asymmetry this
-- estate has now paid for five times.
revoke all on derm.v_manifest_visit_sheets from public;
revoke all on derm.v_manifest_visit_sheets from anon;
grant select on derm.v_manifest_visit_sheets to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- PART 2  the detach ledger
-- -----------------------------------------------------------------------------
create table if not exists derm.manifest_document_detachments (
  id             bigserial primary key,
  ticket_number  text        not null,
  manifest_id    bigint      not null,
  kind           text        not null check (kind in ('address','manifest')),
  url            text        not null,
  rows_touched   integer     not null,
  remaining      integer     not null,
  reason         text        not null,
  detached_by    text        not null,
  detached_at    timestamptz not null default now(),
  -- (*) btrim() strips ASCII SPACE only, so a TAB / NEWLINE / NBSP reason defeats it
  -- entirely -- the hole public.fn_requeue_derm_portal already had to close. Requiring an
  -- alphanumeric is escape-free and cannot be defeated by any whitespace class.
  constraint manifest_document_detachments_reason_chk check (reason ~ '[[:alnum:]]')
);

comment on table derm.manifest_document_detachments is
  'Ledger of documents deliberately DETACHED from a DERM ticket through '
  'public.detach_manifest_document. This table IS the audit trail (who, when, why), which '
  'is why it carries no audit trigger. The storage blob is never deleted: a detached URL '
  'can always be re-attached.';

revoke all on derm.manifest_document_detachments from public;
revoke all on derm.manifest_document_detachments from anon;
grant select on derm.manifest_document_detachments to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- PART 3  public.detach_manifest_document -- remove ONE document from a ticket
-- -----------------------------------------------------------------------------
create or replace function public.detach_manifest_document(
  p_manifest_id bigint,
  p_kind        text,
  p_url         text,
  p_reason      text
) returns table (
  out_ticket_number text,
  out_kind          text,
  out_url           text,
  out_rows_touched  integer,
  out_remaining     text[]
)
language plpgsql
security definer
set search_path to 'public', 'derm', 'pg_temp'
as $function$
declare
  v_kind   text := lower(btrim(p_kind));
  v_url    text := btrim(p_url);
  v_ticket text;
  v_before text[];
  v_after  text[];
  v_rows   integer := 0;
  v_actor  text;
begin
  if p_manifest_id is null then
    raise exception 'A manifest is required.' using errcode = '22023';
  end if;
  if v_kind not in ('address','manifest') then
    raise exception 'kind must be address or manifest, got %.', coalesce(quote_literal(p_kind),'NULL')
      using errcode = '22023';
  end if;
  if coalesce(v_url,'') = '' then
    raise exception 'The document to detach must be named by its URL.' using errcode = '22023';
  end if;
  if coalesce(p_reason,'') !~ '[[:alnum:]]' then
    raise exception 'A reason is required, and it must say something.' using errcode = '22023';
  end if;

  -- Resolve the TICKET, not the row. edit_manifest replicates the document arrays across
  -- every live row of a ticket, so a per-row detach would leave the ticket internally
  -- inconsistent and the next save would put the URL straight back from a sibling.
  select coalesce(dm.white_manifest_number, dm.yellow_ticket_number)
    into v_ticket
    from public.derm_manifests dm
   where dm.id = p_manifest_id and dm.deleted_at is null;

  if v_ticket is null then
    raise exception 'Manifest % does not exist or has been deleted.', p_manifest_id
      using errcode = '22023';
  end if;

  -- (*) Lock BEFORE reading the before-set, in a deterministic order. Two operators on one
  -- ticket would otherwise both pass their checks and the later write would silently undo
  -- the earlier. Same reasoning as the edit_manifest containment guard.
  perform 1
     from public.derm_manifests dm
    where coalesce(dm.white_manifest_number, dm.yellow_ticket_number) = v_ticket
      and dm.deleted_at is null
    order by dm.id
      for update;

  -- The ticket's whole document set for this kind. FILTER (WHERE ...) rather than
  -- array_remove(arr, NULL): nothing equals NULL, so array_remove does NOT remove NULLs
  -- and every downstream comparison would come back NULL and fail open.
  select coalesce(array_agg(distinct u) filter (where u is not null and u <> ''), array[]::text[])
    into v_before
    from public.derm_manifests dm
    cross join lateral unnest(
      case when v_kind = 'address'
           then array[dm.derm_address_url]  || coalesce(dm.derm_address_extra_urls,  array[]::text[])
           else array[dm.derm_manifest_url] || coalesce(dm.derm_manifest_extra_urls, array[]::text[])
      end) as u
   where coalesce(dm.white_manifest_number, dm.yellow_ticket_number) = v_ticket
     and dm.deleted_at is null;

  -- (*) Refuse a document the ticket does not hold. A stale modal must not report a
  -- successful removal of something that was already gone -- that is how an operator comes
  -- to believe they acted. Same reasoning as fn_requeue_derm_portal returning its
  -- post-condition rather than "ok".
  if not (v_url = any (v_before)) then
    raise exception 'Ticket % does not carry that % document, so there is nothing to detach. It holds % document(s).',
      v_ticket, v_kind, coalesce(array_length(v_before,1),0)
      using errcode = '22023';
  end if;

  -- Re-pack every live row of the ticket: first survivor becomes the primary, the rest the
  -- extras. Writing the primary and the extras TOGETHER is what stops the two halves of one
  -- list disagreeing -- derm.v_stamp_row_bands already shows what per-edge writes cost.
  if v_kind = 'address' then
    with rows_to_fix as (
      select dm.id,
             (select coalesce(array_agg(u order by ord), array[]::text[])
                from unnest(array[dm.derm_address_url] || coalesce(dm.derm_address_extra_urls, array[]::text[]))
                       with ordinality as t(u, ord)
               where u is not null and u <> '' and u <> v_url) as keep
        from public.derm_manifests dm
       where coalesce(dm.white_manifest_number, dm.yellow_ticket_number) = v_ticket
         and dm.deleted_at is null
    )
    update public.derm_manifests d
       set derm_address_url        = r.keep[1],
           derm_address_extra_urls = case when coalesce(array_length(r.keep,1),0) > 1
                                          then r.keep[2:] else array[]::text[] end
      from rows_to_fix r
     where d.id = r.id;
  else
    with rows_to_fix as (
      select dm.id,
             (select coalesce(array_agg(u order by ord), array[]::text[])
                from unnest(array[dm.derm_manifest_url] || coalesce(dm.derm_manifest_extra_urls, array[]::text[]))
                       with ordinality as t(u, ord)
               where u is not null and u <> '' and u <> v_url) as keep
        from public.derm_manifests dm
       where coalesce(dm.white_manifest_number, dm.yellow_ticket_number) = v_ticket
         and dm.deleted_at is null
    )
    update public.derm_manifests d
       set derm_manifest_url        = r.keep[1],
           derm_manifest_extra_urls = case when coalesce(array_length(r.keep,1),0) > 1
                                           then r.keep[2:] else array[]::text[] end
      from rows_to_fix r
     where d.id = r.id;
  end if;
  get diagnostics v_rows = row_count;

  select coalesce(array_agg(distinct u) filter (where u is not null and u <> ''), array[]::text[])
    into v_after
    from public.derm_manifests dm
    cross join lateral unnest(
      case when v_kind = 'address'
           then array[dm.derm_address_url]  || coalesce(dm.derm_address_extra_urls,  array[]::text[])
           else array[dm.derm_manifest_url] || coalesce(dm.derm_manifest_extra_urls, array[]::text[])
      end) as u
   where coalesce(dm.white_manifest_number, dm.yellow_ticket_number) = v_ticket
     and dm.deleted_at is null;

  -- Post-conditions, asserted rather than assumed. Removing ONE document must never be
  -- able to take a second with it: that equal-size-swap shape is exactly the loss the
  -- edit_manifest containment guard exists to refuse, and this function must not become a
  -- way around it.
  if v_url = any (v_after) then
    raise exception 'Detach did not take: ticket % still carries that % document.', v_ticket, v_kind
      using errcode = '23514';
  end if;
  if not (v_after <@ v_before) then
    raise exception 'Detach altered the ticket in an unexpected way and has been rolled back.'
      using errcode = '23514';
  end if;
  if coalesce(array_length(v_before,1),0) - coalesce(array_length(v_after,1),0) <> 1 then
    raise exception 'Detach removed % documents, expected exactly 1. Rolled back.',
      coalesce(array_length(v_before,1),0) - coalesce(array_length(v_after,1),0)
      using errcode = '23514';
  end if;

  -- derm._actor reads request.jwt.claims (PLURAL). The singular key PostgREST never sets
  -- is why audit.logs.changed_by has been NULL for its entire life.
  v_actor := derm._actor('sql');

  insert into derm.manifest_document_detachments
    (ticket_number, manifest_id, kind, url, rows_touched, remaining, reason, detached_by)
  values
    (v_ticket, p_manifest_id, v_kind, v_url, v_rows,
     coalesce(array_length(v_after,1),0), btrim(p_reason), v_actor);

  return query select v_ticket, v_kind, v_url, v_rows, v_after;
end;
$function$;

comment on function public.detach_manifest_document(bigint,text,text,text) is
  'Detach ONE document (kind address|manifest) from every live row of a DERM ticket, with a '
  'required reason, recorded in derm.manifest_document_detachments. The storage blob is '
  'NEVER deleted. This is the deliberate-removal verb that public.edit_manifest cannot be: '
  'edit_manifest carries a set-containment guard so a save can only ADD or REPLACE IN '
  'PLACE, which is what stops an accidental drop -- and is exactly why an intentional '
  'removal needs a separate control that says so.';

-- Supabase ALTER DEFAULT PRIVILEGES grants EXECUTE on new public functions to roles nobody
-- named. Revoke by name; a REVOKE FROM PUBLIC does not remove a grant it did not create.
revoke all on function public.detach_manifest_document(bigint,text,text,text) from public;
revoke all on function public.detach_manifest_document(bigint,text,text,text) from anon;
grant execute on function public.detach_manifest_document(bigint,text,text,text)
  to authenticated, service_role;

commit;
