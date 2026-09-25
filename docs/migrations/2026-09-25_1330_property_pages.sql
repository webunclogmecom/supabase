-- =============================================================================
-- 2026-09-25_1330_property_pages.sql
-- Build plan section 6: the Page Builder's pages, the two-person approval and the driver link.
-- Plan: Building Apps/docs/2026-09-25_page-builder-and-driver-page-plan.md (revised after a
-- 58-finding adversarial review; every rule below traces to a decision D1..D13 there). This SQL
-- was itself reviewed before apply (3 lenses + a skeptic, 20 findings, 19 confirmed, all fixed here).
--
-- Fred: "Remember to keep building it tho." Fred 2026-09-23: the process is owned by Serena,
-- Yannick and Diego, "one builds the page and another approves it"; "The office edits it."
--
-- WHAT
--   public.property_page_links   one driver link per property (22 base62 chars, about 131 bits)
--   public.property_pages        APPEND-ONLY versions: content frozen at submit, approved once
--   public.property_page_opens   the open log, at most one row per page, minute and staff flag
--   public.fn_page_photo_ids     which photos may appear on a property's page (D8)
--   public.fn_page_content_problem   the content validator (a plain sentence or NULL)
--   public.fn_page_source        the property values a page is prefilled from (D6 baseline)
--   public.fn_page_blocker       why a driver link would NOT open (removed, billing, inactive client)
--   public.fn_page_approver_ids / fn_page_approver_names / fn_page_person_name   who approves, names
--   public.fn_driver_page        what the public driver page shows, service_role only
--   client.page_builder_list, client.get_page_builder, client.submit_property_page,
--   client.approve_property_page, client.rotate_driver_link        the staff surface
--
-- 🛑 GRANTS. A table postgres creates in public gets authenticated=arwdDxtm AND
--    yannick_readonly=r by default, and yannick_readonly is a LOGIN role with BYPASSRLS, so "RLS
--    on, no policies" does nothing against it. Every new table is revoked by name from public,
--    anon, authenticated and yannick_readonly, and the VERIFY asserts the WHOLE relacl. A new
--    public function gets authenticated EXECUTE by default: every public function here is revoked
--    from public, anon and authenticated. The client schema has no function default ACL (so PUBLIC
--    gets EXECUTE): every client function is revoked from public and anon, granted to authenticated.
-- 🛑 A PHOTO IS SERVED ONLY FROM THE BUCKET ITS LINK KIND NAMES, AND ONLY IF THAT OBJECT EXISTS
--    THERE (D8). storage_path is writable by any staff session (the photos INSERT policy checks only
--    the source), and a path like '../manifests/...' joined into a storage URL is normalised into
--    ANOTHER bucket: the review proved it served an unredacted DERM sheet. Binding every row to
--    storage.objects(bucket_id = the link kind's bucket, name = path) closes it; driver-page also
--    refuses any '.' or '..' segment.
-- 🛑 fn_page_content_problem READS TABLES: it must never become a CHECK (a CHECK would re-run on
--    the approval UPDATE and fail the day a photo loses its link).
-- 🛑 property_page_links.public_id is a bearer capability: it is in audit.redacted_columns (row
--    added below, before the audit trigger exists), so audit.logs never copies it.
-- 🛑 ONE answer to "will this link open": public.fn_page_blocker, called by fn_driver_page, submit,
--    approve, the builder and the list, so the office never sees "Live" on a link that does not open.
--
-- RULE 8, AUDIT: property_page_links and property_pages opt IN (human-made, compliance-adjacent).
--   property_page_opens opts OUT: an append-only machine log written by the driver page, one row
--   per page per minute at most; auditing it would double every row for no reader.
-- property_pages has no updated_at: approved_at is the only change a row can ever take.
-- The staff flag on an open is SELF-REPORTED by the page (cookie presence): advisory only.
-- ATOMIC: no COMMIT. The VERIFY's writes run inside a sentinel sub-block and are rolled back.
-- =============================================================================

-- ------------------------------------------------------------------ 1. TABLES
create table public.property_page_links (
  property_id bigint primary key references public.properties(id),
  public_id   text not null unique default public.gen_short_id(22)
              check (public_id ~ '^[A-Za-z0-9]{22}$'),
  created_at  timestamptz not null default now(),
  created_by  uuid,
  rotated_at  timestamptz,
  rotated_by  uuid,
  updated_at  timestamptz not null default now()
);
comment on table public.property_page_links is
  'One driver-page link per property (Page Builder, build plan section 6). public_id is a bearer '
  'capability: whoever holds it reads the live page (gate codes). Redacted from audit.logs. '
  'Rotate with client.rotate_driver_link; the old link stops working at once.';

create table public.property_pages (
  id                 bigint generated always as identity primary key,
  property_id        bigint not null references public.properties(id),
  version            integer not null check (version >= 1),
  content            jsonb not null check (jsonb_typeof(content -> 'photos') = 'array'),
  source             jsonb not null,
  submitted_at       timestamptz not null default now(),
  submitted_by       uuid not null,
  submitted_by_email text not null,
  approved_at        timestamptz,
  approved_by        uuid,
  approved_by_email  text,
  unique (property_id, version),
  check ((approved_at is null) = (approved_by is null)),
  check (approved_by is distinct from submitted_by)
);
comment on table public.property_pages is
  'APPEND-ONLY versions of a property''s driver page. content = everything a driver reads, frozen '
  'at submit (incl. a copy of the site map and each photo''s rotation); source = the property values '
  'the builder prefilled from (fn_page_source, checked unchanged at submit), so a later property '
  'change is visible. The live page is the highest APPROVED version. A trigger refuses an insert '
  'that arrives approved, every UPDATE except recording the approval once, and every DELETE.';
comment on column public.property_pages.source is
  'public.fn_page_source(property_id) as the builder loaded it (submit refuses if it changed): the '
  'baseline for "Property changed since approval".';

create table public.property_page_opens (
  id            bigint generated always as identity primary key,
  property_id   bigint not null references public.properties(id),
  version       integer not null,
  staff         boolean not null default false,
  opened_at     timestamptz not null default now(),
  opened_minute timestamptz not null default date_trunc('minute', now()),
  user_agent    text,
  unique (property_id, opened_minute, staff)
);
comment on table public.property_page_opens is
  'Driver page opens, written only by public.fn_driver_page: at most one row per page, minute and '
  'staff flag. staff is SELF-REPORTED by the page (the staff session cookie is present), so it is '
  'advisory. Not audited (append-only log).';

-- ------------------------------------------------------ 2. APPEND-ONLY GUARD
create or replace function public.fn_property_pages_append_only()
returns trigger language plpgsql set search_path to '' as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Page versions are never deleted.' using errcode = '55000',
      detail = 'blocker=append_only in public.property_pages';
  end if;
  if tg_op = 'INSERT' then
    if new.approved_at is not null or new.approved_by is not null or new.approved_by_email is not null then
      raise exception 'A page version is approved after it is submitted, never while it is written.'
        using errcode = '55000', detail = 'blocker=append_only in public.property_pages';
    end if;
    return new;
  end if;
  if old.approved_at is not null
     or new.approved_at is null
     or (pg_catalog.to_jsonb(new) - 'approved_at' - 'approved_by' - 'approved_by_email')
        is distinct from
        (pg_catalog.to_jsonb(old) - 'approved_at' - 'approved_by' - 'approved_by_email') then
    raise exception 'A page version cannot be changed after it is submitted; only its approval can be recorded, once.'
      using errcode = '55000', detail = 'blocker=append_only in public.property_pages';
  end if;
  return new;
end $$;

create or replace function public.fn_property_pages_no_truncate()
returns trigger language plpgsql set search_path to '' as $$
begin
  raise exception 'Page versions are never deleted.' using errcode = '55000',
    detail = 'blocker=append_only in public.property_pages';
end $$;

create trigger property_pages_append_only before insert or update or delete on public.property_pages
  for each row execute function public.fn_property_pages_append_only();
create trigger property_pages_no_truncate before truncate on public.property_pages
  for each statement execute function public.fn_property_pages_no_truncate();

create trigger trg_property_page_links_updated_at before update on public.property_page_links
  for each row execute function public.set_updated_at();

-- -------------------------------------------- 3. REDACTION, THEN AUDIT TRIGGERS
insert into audit.redacted_columns (table_name, column_name, reason)
select 'property_page_links', 'public_id',
       'driver-page bearer link; holding it opens the live page with the gate and lock box codes'
where not exists (select 1 from audit.redacted_columns
                   where table_name = 'property_page_links' and column_name = 'public_id');

create trigger audit_property_page_links after insert or update or delete on public.property_page_links
  for each row execute function audit.log_change();
create trigger audit_property_pages after insert or update or delete on public.property_pages
  for each row execute function audit.log_change();

-- ------------------------------------------------------------ 4. RLS + GRANTS
alter table public.property_page_links enable row level security;
alter table public.property_pages      enable row level security;
alter table public.property_page_opens enable row level security;

revoke all on public.property_page_links, public.property_pages, public.property_page_opens
  from public, anon, authenticated, yannick_readonly;
do $g$
declare s text;
begin
  foreach s in array array[pg_get_serial_sequence('public.property_pages','id'),
                           pg_get_serial_sequence('public.property_page_opens','id')] loop
    execute format('revoke all on sequence %s from public, anon, authenticated, yannick_readonly', s);
  end loop;
end $g$;

-- ------------------------------------------------------- 5. APPROVERS, NAMES
-- Stored as auth user ids so an email change cannot silently drop or add an approver. Only the
-- service role can edit app_config, so an approver cannot add themselves (D5).
insert into public.app_config (key, value)
select 'page_approvers', string_agg(u.id::text, ',' order by u.email)
  from auth.users u
 where lower(u.email) in ('serena@unclogme.com', 'yannick@ayache.com', 'contact@unclogme.com')
on conflict (key) do update set value = excluded.value;

create or replace function public.fn_page_approver_ids()
returns uuid[] language sql stable set search_path to '' as $$
  select coalesce(array_agg(btrim(x)::uuid), '{}')
    from pg_catalog.regexp_split_to_table(
           coalesce((select value from public.app_config where key = 'page_approvers'), ''), ',') x
   where btrim(x) <> ''
$$;

-- The one first-name rule, shared by every surface that says who submitted or approved.
create or replace function public.fn_page_person_name(p_email text)
returns text language sql stable set search_path to '' as $$
  select coalesce((select split_part(btrim(e.full_name), ' ', 1) from public.employees e
                    where lower(e.email) = lower(p_email) and btrim(coalesce(e.full_name, '')) <> ''
                    order by (e.status = 'ACTIVE') desc, e.id limit 1), 'the office')
$$;

create or replace function public.fn_page_approver_names()
returns text language sql stable set search_path to '' as $$
  with n as (
    select row_number() over (order by e.full_name) i, count(*) over () c,
           split_part(btrim(e.full_name), ' ', 1) nm
      from auth.users u join public.employees e on lower(e.email) = lower(u.email)
     where u.id = any (public.fn_page_approver_ids()) and e.status = 'ACTIVE')
  select case when max(c) is null then 'the page approvers'
              when max(c) = 1 then max(nm)
              else string_agg(nm, ', ' order by i) filter (where i < c) || ' or ' || max(nm) filter (where i = c) end
    from n
$$;

-- ----------------------------------------------- 6. WHICH PHOTOS A PAGE MAY SHOW
-- D8. One row per photo (DISTINCT ON photo_id, deterministic: newest visit date, visit before
-- intake, then the newest visit id). Images only. The bucket comes from the LINK KIND, and the
-- row counts only if that exact object exists in that bucket (see the header: path traversal).
create or replace function public.fn_page_photo_ids(p_property_id bigint)
returns table (photo_id bigint, kind text, bucket text, path text, entity_id bigint,
               visit_date date, question_key text, caption text, rotation_deg smallint,
               content_type text)
language sql stable set search_path to '' as $$
  select distinct on (x.photo_id) x.*
    from (
      select p.id, 'visit'::text, 'GT - Visits Images'::text, p.storage_path, v.id, v.visit_date,
             null::text, pl.caption, p.rotation_deg, p.content_type
        from public.photo_links pl
        join public.photos p on p.id = pl.photo_id
        join public.visits v on v.id = pl.entity_id
       where pl.entity_type = 'visit' and pl.deleted_at is null
         and v.deleted_at is null and v.property_id = p_property_id
         and p.content_type like 'image/%'
      union all
      select p.id, 'intake'::text, 'intake-photos'::text, substr(p.storage_path, 15), i.id, null::date,
             pl.role, null::text, p.rotation_deg, p.content_type
        from public.photo_links pl
        join public.photos p on p.id = pl.photo_id
        join public.property_intakes i on i.id = pl.entity_id
       where pl.entity_type = 'property_intake' and pl.deleted_at is null
         and i.property_id = p_property_id
         and i.submitted_at is not null and i.cancelled_at is null
         and p.storage_path ~ ('^intake-photos/' || i.id::text || '/[0-9a-f-]{36}[.][a-z0-9]{2,5}$')
         and p.content_type like 'image/%'
    ) x (photo_id, kind, bucket, path, entity_id, visit_date, question_key, caption, rotation_deg, content_type)
   where exists (select 1 from storage.objects so where so.bucket_id = x.bucket and so.name = x.path)
   order by x.photo_id, x.visit_date desc nulls last, x.kind desc, x.entity_id desc
$$;

-- ------------------------------------------------ 7. THE PREFILL BASELINE (D6)
-- Read through client.properties so gallons match what the Client App shows (the Pumping
-- service-config fallback included). The map is compared by CONTENT (rev removed): its rev can
-- repeat after a clear and moves on a no-op save. One definition for the builder (prefill), submit
-- (unchanged check + store) and the list (compare).
create or replace function public.fn_page_source(p_property_id bigint)
returns jsonb language sql stable set search_path to '' as $$
  select jsonb_build_object(
           'lock_box_key',   cp.lock_box_key,
           'access_schedule', cp.access_schedule,
           'gallons',        cp.grease_capacity_gallons,
           'manholes',       cp.grease_trap_manhole_count,
           'sample_ports',   cp.sample_port_count,
           'access_notes',   nullif(btrim(cp.access_notes), ''),
           'site_map',       p.site_map - 'rev')
    from client.properties cp
    join public.properties p on p.id = cp.id
   where cp.id = p_property_id
$$;

-- --------------------------------------------- 8. WILL THE DRIVER LINK OPEN?
-- NULL = yes. Otherwise the sentence the office sees. fn_driver_page serves nothing when this is
-- not null; submit and approve refuse; the builder and the list show it.
create or replace function public.fn_page_blocker(p_property_id bigint)
returns text language sql stable set search_path to '' as $$
  select case
    when p.id is null or p.deleted_at is not null then 'This property is not active any more.'
    when coalesce(p.is_billing, false) then 'This is a billing address, not a place we service.'
    when c.status = 'INACTIVE' then 'This client is inactive, so a driver link would not open.'
    else null end
    from (select 1) one
    left join public.properties p on p.id = p_property_id
    left join public.clients c on c.id = p.client_id
$$;

-- ---------------------------------------------------- 9. THE CONTENT VALIDATOR
-- Plain sentences for the office. Most shapes are reachable only through an app bug, so their
-- sentence says to reload rather than naming a technical part.
create or replace function public.fn_page_content_problem(p_property_id bigint, p jsonb)
returns text language plpgsql stable set search_path to '' as $$
declare
  v_n int;
begin
  if p is null or jsonb_typeof(p) <> 'object'
     or exists (select 1 from jsonb_object_keys(p) k
                 where k not in ('v','facts','hours','notes','contacts','include_map','photos'))
     or coalesce(p ->> 'v', '') <> '1' then
    return 'The page could not be read. Reload the Page Builder and try again.';
  end if;
  if octet_length(p::text) > 262144 then return 'The page is too large. Remove some photos or notes.'; end if;

  if p ? 'facts' and jsonb_typeof(p -> 'facts') <> 'null' then
    if jsonb_typeof(p -> 'facts') <> 'object' then return 'The page could not be read. Reload the Page Builder and try again.'; end if;
    if (select count(*) from jsonb_object_keys(p -> 'facts')) > 40 then return 'A page holds at most 40 facts.'; end if;
    if exists (select 1 from jsonb_each(p -> 'facts') e(k, val)
                where length(k) > 60
                   or jsonb_typeof(val) not in ('string','number','null')
                   or (jsonb_typeof(val) = 'string' and (length(val #>> '{}') > 500
                        or translate(val #>> '{}', E'\n\t', '') ~ '[[:cntrl:]]'))) then
      return 'Each fact must be a short text (500 characters at most), a number, or empty.';
    end if;
  end if;

  if p ? 'hours' and jsonb_typeof(p -> 'hours') <> 'null' then
    if jsonb_typeof(p -> 'hours') <> 'object'
       or exists (select 1 from jsonb_each(p -> 'hours') e(k, val)
                   where k not in ('mon','tue','wed','thu','fri','sat','sun')
                      or jsonb_typeof(val) <> 'object'
                      or exists (select 1 from jsonb_object_keys(val) kk where kk not in ('open','close'))
                      or coalesce(val ->> 'open', '')  !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
                      or coalesce(val ->> 'close', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$') then
      return 'Each day we can come needs an opening and a closing time.';
    end if;
  end if;

  if p ? 'notes' and jsonb_typeof(p -> 'notes') not in ('string','null') then return 'The page could not be read. Reload the Page Builder and try again.'; end if;
  if length(coalesce(p ->> 'notes', '')) > 4000 then return 'The notes are too long (4,000 characters at most).'; end if;
  if p ? 'include_map' and jsonb_typeof(p -> 'include_map') <> 'boolean' then return 'The page could not be read. Reload the Page Builder and try again.'; end if;

  if p ? 'contacts' and jsonb_typeof(p -> 'contacts') <> 'null' then
    if jsonb_typeof(p -> 'contacts') <> 'array' or jsonb_array_length(p -> 'contacts') > 10 then
      return 'A page lists at most 10 contacts.';
    end if;
    if exists (select 1 from jsonb_array_elements(p -> 'contacts') c
                where jsonb_typeof(c) <> 'object'
                   or exists (select 1 from jsonb_each(c) e(k, val)
                               where k not in ('name','phone','role')
                                  or jsonb_typeof(val) not in ('string','null')
                                  or length(coalesce(val #>> '{}', '')) > 200)) then
      return 'Each contact has a name, a phone and a role, each 200 characters at most.';
    end if;
  end if;

  -- photos must be a list (the table CHECK requires it; submit strips server-owned keys first).
  if not (p ? 'photos') or jsonb_typeof(p -> 'photos') <> 'array' then
    return 'The page could not be read. Reload the Page Builder and try again.';
  end if;
  if jsonb_array_length(p -> 'photos') > 80 then return 'A page holds at most 80 photos.'; end if;
  if exists (select 1 from jsonb_array_elements(p -> 'photos') ph
              where jsonb_typeof(ph) <> 'object'
                 or exists (select 1 from jsonb_object_keys(ph) k where k not in ('photo_id','section','note','marks'))
                 or jsonb_typeof(ph -> 'photo_id') is distinct from 'number'
                 or (ph ->> 'photo_id') !~ '^[1-9][0-9]{0,11}$'
                 or coalesce(ph ->> 'section', '') not in ('access','grease_trap','job')) then
    return 'The page could not be read. Reload the Page Builder and try again.';
  end if;
  if exists (select 1 from jsonb_array_elements(p -> 'photos') ph
              where (ph ? 'note' and jsonb_typeof(ph -> 'note') not in ('string','null'))
                 or length(coalesce(ph ->> 'note', '')) > 1000) then
    return 'A photo note is too long (1,000 characters at most).';
  end if;
  select count(*) - count(distinct (ph ->> 'photo_id')::bigint) into v_n from jsonb_array_elements(p -> 'photos') ph;
  if v_n > 0 then return 'The same photo is on the page twice.'; end if;
  if exists (select 1 from jsonb_array_elements(p -> 'photos') ph
              where ph ? 'marks' and jsonb_typeof(ph -> 'marks') <> 'null'
                and (jsonb_typeof(ph -> 'marks') <> 'array' or jsonb_array_length(ph -> 'marks') > 30)) then
    return 'A photo carries at most 30 marks.';
  end if;
  if exists (select 1 from jsonb_array_elements(p -> 'photos') ph,
                           jsonb_array_elements(case when jsonb_typeof(ph -> 'marks') = 'array' then ph -> 'marks' else '[]'::jsonb end) m
              where jsonb_typeof(m) <> 'object'
                 or exists (select 1 from jsonb_object_keys(m) k
                             where k not in ('id','kind','x','y','w','h','x1','y1','x2','y2','number','text','color'))
                 or coalesce(m ->> 'kind', '') not in ('circle','ring','rect','arrow','text')
                 or (m ? 'color' and coalesce(m ->> 'color', '') not in ('red','blue','green','yellow','orange','white'))
                 or (m ? 'id' and (jsonb_typeof(m -> 'id') <> 'string' or length(m ->> 'id') > 64))
                 or (m ? 'text' and (jsonb_typeof(m -> 'text') <> 'string' or length(m ->> 'text') > 200))
                 or (m ? 'number' and (jsonb_typeof(m -> 'number') <> 'number' or (m ->> 'number') !~ '^[1-9][0-9]?$'))
                 or exists (select 1 from jsonb_each(m) e(k, val)
                             where k in ('x','y','w','h','x1','y1','x2','y2')
                               and (jsonb_typeof(val) <> 'number' or (val #>> '{}')::numeric not between 0 and 1))) then
    return 'A mark on a photo is not valid (its shape, colour, text or position).';
  end if;
  if exists (select 1 from jsonb_array_elements(p -> 'photos') ph
              where not exists (select 1 from public.fn_page_photo_ids(p_property_id) o
                                 where o.photo_id = (ph ->> 'photo_id')::bigint)) then
    return 'A photo on the page no longer belongs to this property (it was removed from its visit or its form). Reload the Page Builder to see it.';
  end if;

  return null;
end $$;

-- ------------------------------------------------------ 10. STAFF: THE LIST
-- A SECURITY DEFINER function, not a view: a function called inside a view is checked against the
-- CALLER's EXECUTE grant and runs with the caller's rights, and the helpers above are not granted
-- to authenticated (the view/function asymmetry in Supabase CLAUDE.md). A function also carries
-- the staff gate, which a view cannot.
create or replace function client.page_builder_list()
returns table (property_id bigint, client_id bigint, client_code text, client_name text,
               property_name text, address text, city text, intake_status text, intake_id bigint,
               live_version integer, live_approved_at timestamptz, live_approved_by_name text,
               pending_version integer, pending_submitted_at timestamptz, pending_submitted_by_name text,
               property_changed_since_live boolean, photos_no_longer_available integer,
               has_link boolean, link_blocker text, last_opened_at timestamptz, last_open_was_staff boolean)
language plpgsql stable security definer set search_path to '' as $$
declare
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if auth.uid() is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.page_builder_list';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.page_builder_list';
  end if;
  return query
  select pi.property_id,
         pi.client_id,
         c.client_code::text,
         c.name::text,
         nullif(btrim(p.name), '')::text,
         p.address::text,
         p.city::text,
         pi.intake_status::text,
         pi.intake_id,
         lv.version,
         lv.approved_at,
         case when lv.id is null then null else public.fn_page_person_name(lv.approved_by_email) end,
         pv.version,
         pv.submitted_at,
         case when pv.id is null then null else public.fn_page_person_name(pv.submitted_by_email) end,
         (lv.id is not null and lv.source is distinct from public.fn_page_source(p.id)),
         case when lv.id is null then 0 else (
           select count(*)::int from jsonb_array_elements(lv.content -> 'photos') ph
            where not exists (select 1 from public.fn_page_photo_ids(p.id) o
                               where o.photo_id = (ph ->> 'photo_id')::bigint)) end,
         (l.property_id is not null),
         public.fn_page_blocker(p.id),
         lo.opened_at,
         lo.staff
    from client.v_property_intake pi
    join public.properties p on p.id = pi.property_id
    join public.clients c    on c.id = pi.client_id
    left join lateral (select x.* from public.property_pages x
                        where x.property_id = p.id and x.approved_at is not null
                        order by x.version desc limit 1) lv on true
    left join lateral (select x.* from public.property_pages x
                        where x.property_id = p.id and x.approved_at is null
                          and x.version > coalesce(lv.version, 0)
                        order by x.version desc limit 1) pv on true
    left join lateral (select o.opened_at, o.staff from public.property_page_opens o
                        where o.property_id = p.id order by o.opened_at desc limit 1) lo on true
    left join public.property_page_links l on l.property_id = p.id
   where nullif(btrim(c.client_code), '') is not null
   order by c.client_code, p.id;
end $$;

comment on function client.page_builder_list() is
  'Page Builder home list: service properties (live, not billing, with a client code) with their '
  'intake status and page state. No page content and no link value: those come from '
  'client.get_page_builder. last_open_was_staff is self-reported by the page (advisory).';

-- --------------------------------------------------- 11. STAFF: THE BUILDER READ
create or replace function client.get_page_builder(p_property_id bigint)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_p     record;
  v_live  public.property_pages;
  v_pend  public.property_pages;
  v_newest int;
  v_out   jsonb;
  v_block text;
begin
  if v_uid is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.get_page_builder';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.get_page_builder';
  end if;
  if p_property_id is null then
    raise exception 'No property was chosen. Go back to the list and pick one.' using errcode = '22023',
      detail = 'blocker=no_property in client.get_page_builder';
  end if;

  select p.id, p.client_id, p.name, p.address, p.city, p.latitude, p.longitude, p.site_map,
         p.is_billing, p.deleted_at, c.client_code, c.name as client_name
    into v_p
    from public.properties p join public.clients c on c.id = p.client_id
   where p.id = p_property_id;
  if not found or v_p.deleted_at is not null then
    raise exception 'This property is not active any more.' using errcode = 'P0002',
      detail = 'blocker=property_retired in client.get_page_builder';
  end if;
  if coalesce(v_p.is_billing, false) then
    raise exception 'This is a billing address, not a place we service.' using errcode = '22023',
      detail = 'blocker=billing_property in client.get_page_builder';
  end if;

  select max(version) into v_newest from public.property_pages where property_id = p_property_id;
  select * into v_live from public.property_pages
   where property_id = p_property_id and approved_at is not null order by version desc limit 1;
  select * into v_pend from public.property_pages
   where property_id = p_property_id and approved_at is null and version > coalesce(v_live.version, 0)
   order by version desc limit 1;

  v_block := case
    when v_pend.id is null then 'There is nothing waiting for approval.'
    when not (v_uid = any (public.fn_page_approver_ids())) then
      'Only ' || public.fn_page_approver_names() || ' can approve a page.'
    when v_pend.submitted_by = v_uid then 'You submitted this version, so another person has to approve it.'
    else public.fn_page_blocker(p_property_id) end;

  with owned as (
    select o.*, q.label from public.fn_page_photo_ids(p_property_id) o
      left join client.v_intake_questions q on q.question_key = o.question_key),
  item as (
    select o.photo_id, jsonb_build_object(
             'photo_id', o.photo_id, 'kind', o.kind, 'bucket', o.bucket, 'path', o.path,
             'visit_id', case when o.kind = 'visit' then o.entity_id end,
             'intake_id', case when o.kind = 'intake' then o.entity_id end,
             'visit_date', o.visit_date, 'question_key', o.question_key,
             'label', coalesce(o.label, o.question_key), 'caption', o.caption,
             'rotation_deg', o.rotation_deg, 'content_type', o.content_type) as j,
           o.kind, o.entity_id, o.visit_date
      from owned o),
  recent_visits as (
    select entity_id from owned where kind = 'visit'
     group by entity_id order by max(visit_date) desc, entity_id desc limit 12),
  refd as (
    select distinct (ph ->> 'photo_id')::bigint as photo_id
      from (select v_live.content as c union all select v_pend.content) s,
           jsonb_array_elements(s.c -> 'photos') ph
     where s.c is not null)
  select jsonb_build_object(
    'property', jsonb_build_object(
        'id', v_p.id, 'client_id', v_p.client_id, 'client_code', v_p.client_code,
        'client_name', v_p.client_name, 'name', nullif(btrim(v_p.name), ''),
        'address', v_p.address, 'city', v_p.city, 'lat', v_p.latitude, 'lng', v_p.longitude,
        'site_map', v_p.site_map, 'site_map_rev', coalesce((v_p.site_map ->> 'rev')::int, 0),
        'source', public.fn_page_source(p_property_id),
        'driver_link_blocker', public.fn_page_blocker(p_property_id)),
    'intake', (select jsonb_build_object('intake_id', i.id, 'submitted_at', i.submitted_at, 'collector', i.collector)
                 from public.property_intakes i
                where i.property_id = p_property_id and i.submitted_at is not null and i.cancelled_at is null
                order by i.submitted_at desc limit 1),
    'pool', coalesce((select jsonb_agg(it.j order by it.kind, it.visit_date desc nulls last, it.photo_id)
                        from item it
                       where it.kind = 'intake' or it.entity_id in (select entity_id from recent_visits)), '[]'::jsonb),
    'referenced', coalesce((select jsonb_agg(case when it.photo_id is null
                    then jsonb_build_object('photo_id', r.photo_id, 'owned', false)
                    else it.j || jsonb_build_object('owned', true) end)
                  from refd r left join item it on it.photo_id = r.photo_id), '[]'::jsonb),
    -- People only (a name or a role), per D7 "unknown stays unknown"; the client-record label
    -- ("Business - 123-AB") is offered separately as the main line, never as a person.
    'contacts', coalesce((select jsonb_agg(jsonb_build_object(
                  'name', nullif(btrim(concat_ws(' ', cc.first_name, cc.last_name)), ''),
                  'phone', nullif(btrim(cc.phone), ''),
                  'role', coalesce(nullif(btrim(cc.person_role_other), ''), nullif(btrim(cc.person_role), '')))
                  order by cc.property_id nulls last, cc.id)
                from public.client_contacts cc
               where cc.client_id = v_p.client_id and cc.contact_role = 'primary'
                 and (cc.property_id is null or cc.property_id = p_property_id)
                 and (nullif(btrim(concat_ws(' ', cc.first_name, cc.last_name)), '') is not null
                      or nullif(btrim(cc.person_role), '') is not null
                      or nullif(btrim(cc.person_role_other), '') is not null)), '[]'::jsonb),
    'main_line', (select jsonb_build_object(
                    'name', regexp_replace(v_p.client_name, '\s*-\s*' || coalesce(v_p.client_code, '') || '\s*$', ''),
                    'phone', nullif(btrim(cc.phone), ''), 'role', 'Main line')
                    from public.client_contacts cc
                   where cc.client_id = v_p.client_id and cc.contact_role = 'primary'
                     and nullif(btrim(cc.phone), '') is not null
                   order by cc.property_id = p_property_id desc nulls last, cc.id limit 1),
    'newest_version', coalesce(v_newest, 0),
    'live', case when v_live.id is null then null else jsonb_build_object(
              'page_id', v_live.id, 'version', v_live.version, 'content', v_live.content,
              'source', v_live.source, 'submitted_at', v_live.submitted_at,
              'submitted_by_name', public.fn_page_person_name(v_live.submitted_by_email),
              'approved_at', v_live.approved_at,
              'approved_by_name', public.fn_page_person_name(v_live.approved_by_email)) end,
    'pending', case when v_pend.id is null then null else jsonb_build_object(
              'page_id', v_pend.id, 'version', v_pend.version, 'content', v_pend.content,
              'source', v_pend.source, 'submitted_at', v_pend.submitted_at,
              'submitted_by_name', public.fn_page_person_name(v_pend.submitted_by_email),
              'mine', v_pend.submitted_by = v_uid) end,
    'link', (select jsonb_build_object('public_id', l.public_id, 'created_at', l.created_at, 'rotated_at', l.rotated_at)
               from public.property_page_links l where l.property_id = p_property_id),
    'can_approve', v_block is null,
    'approve_blocker', v_block,
    'approvers', public.fn_page_approver_names())
  into v_out;
  return v_out;
end $$;

-- ------------------------------------------------------- 12. STAFF: SUBMIT
create or replace function client.submit_property_page(
  p_property_id      bigint,
  p_content          jsonb,
  p_expected_version integer,
  p_expected_map_rev integer,
  p_expected_source  jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_uid     uuid := auth.uid();
  v_email   text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_p       record;
  v_newest  int;
  v_problem text;
  v_block   text;
  v_source  jsonb;
  v_in      jsonb;
  v_content jsonb;
  v_bad     text;
  v_id      bigint;
begin
  if v_uid is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.submit_property_page';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.submit_property_page';
  end if;
  if p_property_id is null or p_expected_version is null or p_expected_map_rev is null or p_expected_source is null then
    raise exception 'The page could not be sent. Reload the Page Builder and try again.' using errcode = '22023',
      detail = 'blocker=expected_version_required in client.submit_property_page';
  end if;

  -- One submit at a time per property, so the version check below is exact.
  perform pg_advisory_xact_lock(7342, p_property_id::int);

  v_block := public.fn_page_blocker(p_property_id);
  if v_block is not null then
    raise exception '%', v_block using errcode = '22023', detail = 'blocker=link_would_not_open in client.submit_property_page';
  end if;

  -- FOR SHARE: the map check, the frozen map copy and the source all come from this one read.
  select p.id, p.site_map into v_p from public.properties p where p.id = p_property_id for share;

  select coalesce(max(version), 0) into v_newest from public.property_pages where property_id = p_property_id;
  if v_newest <> p_expected_version then
    raise exception 'Someone submitted a newer version of this page since you opened it. Reload to see it before you submit.'
      using errcode = '40001', detail = format('blocker=version_clash in client.submit_property_page (you had %s, newest is %s)', p_expected_version, v_newest);
  end if;
  if coalesce((v_p.site_map ->> 'rev')::int, 0) <> p_expected_map_rev then
    raise exception 'The site map changed since you opened this page. Reload to see it before you submit.'
      using errcode = '40001', detail = 'blocker=map_changed in client.submit_property_page';
  end if;
  v_source := public.fn_page_source(p_property_id);
  if v_source is distinct from p_expected_source then
    raise exception 'The property''s details changed since you opened this page (hours, lock box, capacity, counts, notes or the map). Reload to see them before you submit.'
      using errcode = '40001', detail = 'blocker=source_changed in client.submit_property_page';
  end if;

  -- The server owns site_map and each photo's rot: strip them so a stored version can be sent
  -- back as it is (the freeze below adds them again).
  v_in := p_content - 'site_map';
  if jsonb_typeof(v_in -> 'photos') = 'array' then
    v_in := v_in || jsonb_build_object('photos', (
      select coalesce(jsonb_agg(case when jsonb_typeof(ph) = 'object' then ph - 'rot' else ph end order by e.ord), '[]'::jsonb)
        from jsonb_array_elements(v_in -> 'photos') with ordinality e(ph, ord)));
  end if;

  v_problem := public.fn_page_content_problem(p_property_id, v_in);
  if v_problem is not null then
    select ph ->> 'photo_id' into v_bad
      from jsonb_array_elements(case when jsonb_typeof(v_in -> 'photos') = 'array' then v_in -> 'photos' else '[]'::jsonb end) ph
     where (ph ->> 'photo_id') ~ '^[1-9][0-9]{0,11}$'
       and not exists (select 1 from public.fn_page_photo_ids(p_property_id) o where o.photo_id = (ph ->> 'photo_id')::bigint)
     limit 1;
    raise exception '%', v_problem using errcode = '22023',
      detail = 'blocker=content in client.submit_property_page' || coalesce(' photo_id=' || v_bad, '');
  end if;

  -- Freeze: the site map as it is now, and each photo's rotation at submit (to remap marks later).
  v_content := v_in
    || jsonb_build_object('site_map', v_p.site_map)
    || jsonb_build_object('photos', coalesce((
         select jsonb_agg(ph || jsonb_build_object('rot', ph2.rotation_deg) order by e.ord)
           from jsonb_array_elements(v_in -> 'photos') with ordinality e(ph, ord)
           join public.photos ph2 on ph2.id = (ph ->> 'photo_id')::bigint), '[]'::jsonb));

  insert into public.property_pages (property_id, version, content, source, submitted_by, submitted_by_email)
  values (p_property_id, v_newest + 1, v_content, v_source, v_uid, v_email)
  returning id into v_id;

  insert into public.property_page_links (property_id, created_by)
  values (p_property_id, v_uid)
  on conflict (property_id) do nothing;

  return jsonb_build_object('ok', true, 'page_id', v_id, 'version', v_newest + 1);
end $$;

-- ------------------------------------------------------- 13. STAFF: APPROVE
create or replace function client.approve_property_page(p_page_id bigint)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_page  public.property_pages;
  v_newest int;
  v_block text;
begin
  if v_uid is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.approve_property_page';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.approve_property_page';
  end if;
  if not (v_uid = any (public.fn_page_approver_ids())) then
    raise exception 'Only % can approve a page.', public.fn_page_approver_names() using errcode = '42501',
      detail = 'blocker=not_an_approver in client.approve_property_page';
  end if;

  select * into v_page from public.property_pages where id = p_page_id;
  if not found then
    raise exception 'That version of the page does not exist. Reload the Page Builder.' using errcode = 'P0002',
      detail = 'blocker=no_such_version in client.approve_property_page';
  end if;
  perform pg_advisory_xact_lock(7342, v_page.property_id::int);
  select * into v_page from public.property_pages where id = p_page_id;

  if v_page.approved_at is not null then
    raise exception 'This version is already approved.' using errcode = '22023',
      detail = 'blocker=already_approved in client.approve_property_page';
  end if;
  select max(version) into v_newest from public.property_pages where property_id = v_page.property_id;
  if v_page.version <> v_newest then
    raise exception 'A newer version of this page was submitted. Approve that one instead.' using errcode = '22023',
      detail = 'blocker=not_newest in client.approve_property_page';
  end if;
  if v_page.submitted_by = v_uid then
    raise exception 'You submitted this version, so another person has to approve it.' using errcode = '42501',
      detail = 'blocker=own_version in client.approve_property_page';
  end if;
  v_block := public.fn_page_blocker(v_page.property_id);
  if v_block is not null then
    raise exception '%', v_block using errcode = '22023', detail = 'blocker=link_would_not_open in client.approve_property_page';
  end if;

  update public.property_pages
     set approved_at = now(), approved_by = v_uid, approved_by_email = v_email
   where id = p_page_id;

  return jsonb_build_object('ok', true, 'page_id', p_page_id, 'version', v_page.version);
end $$;

-- ------------------------------------------------------- 14. STAFF: ROTATE
create or replace function client.rotate_driver_link(p_property_id bigint)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_new   text;
begin
  if v_uid is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.rotate_driver_link';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.rotate_driver_link';
  end if;
  update public.property_page_links
     set public_id = public.gen_short_id(22), rotated_at = now(), rotated_by = v_uid
   where property_id = p_property_id
  returning public_id into v_new;
  if v_new is null then
    raise exception 'This page has no driver link yet. It gets one when it is first submitted.' using errcode = 'P0002',
      detail = 'blocker=no_link in client.rotate_driver_link';
  end if;
  return jsonb_build_object('ok', true, 'public_id', v_new);
end $$;

-- ------------------------------------------- 15. SERVICE ROLE: THE DRIVER PAGE
-- SECURITY INVOKER on purpose: only service_role (and postgres) hold the grants it needs, so a stray
-- EXECUTE grant would still end in permission denied. Returns NULL for every kind of unknown link
-- (bad shape, no such link, rotated, never approved, fn_page_blocker says no).
create or replace function public.fn_driver_page(p_code text, p_staff boolean default false, p_user_agent text default null)
returns jsonb language plpgsql volatile set search_path to '' as $$
declare
  v_pid    bigint;
  v_p      record;
  v_page   public.property_pages;
  v_photos jsonb;
  v_total  int;
begin
  if p_code is null or p_code !~ '^[A-Za-z0-9]{22}$' then return null; end if;
  select l.property_id into v_pid from public.property_page_links l where l.public_id = p_code;
  if v_pid is null then return null; end if;
  if public.fn_page_blocker(v_pid) is not null then return null; end if;

  select p.name, p.address, p.city, p.latitude, p.longitude, c.client_code, c.name as client_name
    into v_p
    from public.properties p join public.clients c on c.id = p.client_id
   where p.id = v_pid;

  select * into v_page from public.property_pages
   where property_id = v_pid and approved_at is not null order by version desc limit 1;
  if v_page.id is null then return null; end if;

  v_total := jsonb_array_length(v_page.content -> 'photos');
  select coalesce(jsonb_agg(ph || jsonb_build_object('bucket', o.bucket, 'path', o.path, 'rot_now', o.rotation_deg)
                            order by e.ord), '[]'::jsonb)
    into v_photos
    from jsonb_array_elements(v_page.content -> 'photos') with ordinality e(ph, ord)
    join public.fn_page_photo_ids(v_pid) o on o.photo_id = (ph ->> 'photo_id')::bigint;

  insert into public.property_page_opens (property_id, version, staff, user_agent)
  values (v_pid, v_page.version, coalesce(p_staff, false), left(p_user_agent, 200))
  on conflict (property_id, opened_minute, staff) do nothing;

  return jsonb_build_object(
    'property', jsonb_build_object('name', nullif(btrim(v_p.name), ''), 'address', v_p.address,
                  'city', v_p.city, 'lat', v_p.latitude, 'lng', v_p.longitude,
                  'client_code', v_p.client_code, 'client_name', v_p.client_name),
    'version', v_page.version,
    'approved_at', v_page.approved_at,
    'approved_by', public.fn_page_person_name(v_page.approved_by_email),
    'content', v_page.content - 'photos',
    'photos', v_photos,
    'photos_unavailable', v_total - jsonb_array_length(v_photos));
end $$;

-- ------------------------------------------------------ 16. FUNCTION GRANTS
revoke all on function public.fn_property_pages_append_only()                 from public, anon, authenticated;
revoke all on function public.fn_property_pages_no_truncate()                 from public, anon, authenticated;
revoke all on function public.fn_page_approver_ids()                          from public, anon, authenticated;
revoke all on function public.fn_page_approver_names()                        from public, anon, authenticated;
revoke all on function public.fn_page_person_name(text)                       from public, anon, authenticated;
revoke all on function public.fn_page_photo_ids(bigint)                       from public, anon, authenticated;
revoke all on function public.fn_page_source(bigint)                          from public, anon, authenticated;
revoke all on function public.fn_page_blocker(bigint)                         from public, anon, authenticated;
revoke all on function public.fn_page_content_problem(bigint, jsonb)          from public, anon, authenticated;
revoke all on function public.fn_driver_page(text, boolean, text)             from public, anon, authenticated;
grant execute on function public.fn_driver_page(text, boolean, text) to service_role;
grant execute on function public.fn_page_photo_ids(bigint)           to service_role;
grant execute on function public.fn_page_blocker(bigint)             to service_role;
grant execute on function public.fn_page_person_name(text)           to service_role;

revoke all on function client.page_builder_list()                                          from public, anon;
revoke all on function client.get_page_builder(bigint)                                     from public, anon;
revoke all on function client.submit_property_page(bigint, jsonb, integer, integer, jsonb) from public, anon;
revoke all on function client.approve_property_page(bigint)                                from public, anon;
revoke all on function client.rotate_driver_link(bigint)                                   from public, anon;
grant execute on function client.page_builder_list()                                          to authenticated;
grant execute on function client.get_page_builder(bigint)                                     to authenticated;
grant execute on function client.submit_property_page(bigint, jsonb, integer, integer, jsonb) to authenticated;
grant execute on function client.approve_property_page(bigint)                                to authenticated;
grant execute on function client.rotate_driver_link(bigint)                                   to authenticated;

-- ----------------------------------------------------------------- 17. VERIFY
do $verify$
declare
  v_fred   uuid; v_yan uuid; v_serena uuid; v_diego uuid;
  v_ok     jsonb;
  v_pb     jsonb;
  v_src    jsonb;
  v_state  text; v_detail text; v_msg text;
  v_code   text; v_code2 text;
  v_page2  bigint; v_page1 bigint;
  v_n      int;
  v_row    record;
  v_content jsonb;
  v_intake bigint; v_ph bigint; v_forged bigint; v_inactive bigint;
  v_t text;
begin
  select id into v_fred   from auth.users where lower(email) = 'fred@ayache.com';
  select id into v_yan    from auth.users where lower(email) = 'yannick@ayache.com';
  select id into v_serena from auth.users where lower(email) = 'serena@unclogme.com';
  select id into v_diego  from auth.users where lower(email) = 'contact@unclogme.com';
  if v_fred is null or v_yan is null or v_serena is null or v_diego is null then
    raise exception 'VERIFY 0: a test account is missing';
  end if;

  -- V1. The whole ACL of each table, and every role that must NOT read it.
  foreach v_t in array array['property_page_links','property_pages','property_page_opens'] loop
    select c.relacl::text into v_msg from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relname = v_t;
    if v_msg <> '{postgres=arwdDxtm/postgres,service_role=arwdDxtm/postgres}' then
      raise exception 'VERIFY 1a: public.% relacl is %', v_t, v_msg;
    end if;
    if has_table_privilege('yannick_readonly', 'public.' || v_t, 'SELECT')
       or has_table_privilege('authenticated', 'public.' || v_t, 'SELECT')
       or has_table_privilege('anon', 'public.' || v_t, 'SELECT') then
      raise exception 'VERIFY 1b: public.% is readable by a role that must not read it', v_t;
    end if;
  end loop;
  if has_sequence_privilege('anon', pg_get_serial_sequence('public.property_pages','id'), 'SELECT')
     or has_sequence_privilege('yannick_readonly', pg_get_serial_sequence('public.property_page_opens','id'), 'SELECT') then
    raise exception 'VERIFY 1c: an identity sequence is still readable by anon or yannick_readonly';
  end if;

  -- V2. Function grants: never anon or authenticated for the public ones; authenticated for the client ones.
  if has_function_privilege('authenticated', 'public.fn_driver_page(text,boolean,text)', 'EXECUTE')
     or has_function_privilege('anon', 'public.fn_driver_page(text,boolean,text)', 'EXECUTE')
     or not has_function_privilege('service_role', 'public.fn_driver_page(text,boolean,text)', 'EXECUTE') then
    raise exception 'VERIFY 2a: public.fn_driver_page grants are wrong';
  end if;
  foreach v_t in array array['public.fn_page_photo_ids(bigint)','public.fn_page_source(bigint)',
                             'public.fn_page_content_problem(bigint,jsonb)','public.fn_page_approver_ids()',
                             'public.fn_page_approver_names()','public.fn_page_blocker(bigint)',
                             'public.fn_page_person_name(text)'] loop
    if has_function_privilege('authenticated', v_t, 'EXECUTE') or has_function_privilege('anon', v_t, 'EXECUTE') then
      raise exception 'VERIFY 2b: % is executable by anon or authenticated', v_t;
    end if;
  end loop;
  foreach v_t in array array['client.get_page_builder(bigint)','client.submit_property_page(bigint,jsonb,integer,integer,jsonb)',
                             'client.approve_property_page(bigint)','client.rotate_driver_link(bigint)','client.page_builder_list()'] loop
    if not has_function_privilege('authenticated', v_t, 'EXECUTE') or has_function_privilege('anon', v_t, 'EXECUTE') then
      raise exception 'VERIFY 2c: % grants are wrong', v_t;
    end if;
  end loop;

  -- V3. Redaction row, approvers, names.
  if not exists (select 1 from audit.redacted_columns where table_name = 'property_page_links' and column_name = 'public_id') then
    raise exception 'VERIFY 3a: public_id is not in audit.redacted_columns';
  end if;
  if (select array_agg(x order by x) from unnest(public.fn_page_approver_ids()) x)
     is distinct from (select array_agg(x order by x) from unnest(array[v_yan, v_serena, v_diego]) x) then
    raise exception 'VERIFY 3b: page_approvers is not exactly Serena, Yannick and Diego';
  end if;
  if public.fn_page_approver_names() <> 'Diego, Serena or Yannick' then
    raise exception 'VERIFY 3c: approver names read "%"', public.fn_page_approver_names();
  end if;
  if public.fn_page_person_name('serena@unclogme.com') <> 'Serena' or public.fn_page_person_name('contact@unclogme.com') <> 'Diego'
     or public.fn_page_person_name('nobody@example.com') <> 'the office' then
    raise exception 'VERIFY 3d: fn_page_person_name is wrong';
  end if;

  -- V4. Photo ownership arms (D8), each with its positive control.
  if not exists (select 1 from public.fn_page_photo_ids(162) where photo_id = 24909 and bucket = 'GT - Visits Images') then
    raise exception 'VERIFY 4a: control failed: visit photo 24909 is not offered for property 162';
  end if;
  if not exists (select 1 from public.fn_page_photo_ids(1164) where photo_id = 27404 and bucket = 'intake-photos'
                 and path not like 'intake-photos/%') then
    raise exception 'VERIFY 4b: control failed: intake photo 27404 (intake 167) is not offered for 1164 with a bucket-relative path';
  end if;
  if exists (select 1 from public.fn_page_photo_ids(162) where photo_id = 27404) then
    raise exception 'VERIFY 4c: another property''s intake photo is offered for 162';
  end if;
  if exists (select 1 from public.fn_page_photo_ids(7) where photo_id = 17884) then
    raise exception 'VERIFY 4d: a VIDEO is offered';
  end if;
  if exists (select 1 from public.fn_page_photo_ids(66) where photo_id = 3783) then
    raise exception 'VERIFY 4e: a photo whose only link is soft-deleted is offered';
  end if;

  -- V4f. Will the link open: an INACTIVE client's property is refused (control: 162 is fine).
  select pi.property_id into v_inactive
    from client.v_property_intake pi join public.clients c on c.id = pi.client_id
   where c.status = 'INACTIVE' order by pi.property_id limit 1;
  if public.fn_page_blocker(162) is not null then raise exception 'VERIFY 4f: control failed: 162 is blocked: %', public.fn_page_blocker(162); end if;
  if v_inactive is not null and coalesce(public.fn_page_blocker(v_inactive), '') not like '%inactive%' then
    raise exception 'VERIFY 4g: an INACTIVE client''s property (%) is not blocked', v_inactive;
  end if;
  if coalesce(public.fn_page_blocker(-1), '') not like '%not active%' then raise exception 'VERIFY 4h: a missing property is not blocked'; end if;

  -- V5. The content validator: the good page passes, each bad shape fails.
  v_content := jsonb_build_object('v', 1,
    'facts', jsonb_build_object('gate', 'yes', 'gate_code', '[TEST] 1234', 'manholes', null, 'gallons', 750),
    'hours', jsonb_build_object('mon', jsonb_build_object('open', '21:00', 'close', '06:00')),
    'notes', '[TEST] verify page', 'include_map', true,
    'contacts', jsonb_build_array(jsonb_build_object('name', '[TEST] Maria', 'phone', '305 555 0100', 'role', null)),
    'photos', jsonb_build_array(jsonb_build_object('photo_id', 24908, 'section', 'access', 'note', '[TEST] turn here',
       'marks', jsonb_build_array(jsonb_build_object('id', 'm1', 'kind', 'circle', 'x', 0.5, 'y', 0.4, 'number', 1, 'color', 'red')))));
  if public.fn_page_content_problem(162, v_content) is not null then
    raise exception 'VERIFY 5a: control failed: the good page was refused: %', public.fn_page_content_problem(162, v_content);
  end if;
  if public.fn_page_content_problem(162, v_content || '{"site_map":{}}') is null then raise exception 'VERIFY 5b: a client-sent site_map was accepted by the validator'; end if;
  if public.fn_page_content_problem(162, jsonb_set(v_content, '{photos,0,photo_id}', '27404')) is null then raise exception 'VERIFY 5c: a foreign photo was accepted'; end if;
  if public.fn_page_content_problem(162, jsonb_set(v_content, '{photos,0,marks,0,color}', '"purple"')) is null then raise exception 'VERIFY 5d: a bad colour was accepted'; end if;
  if public.fn_page_content_problem(162, jsonb_set(v_content, '{photos,0,marks,0,x}', '1.5')) is null then raise exception 'VERIFY 5e: a mark outside the photo was accepted'; end if;
  if public.fn_page_content_problem(162, jsonb_set(v_content, '{photos}', (v_content -> 'photos') || (v_content -> 'photos'))) is null then raise exception 'VERIFY 5f: a duplicate photo was accepted'; end if;
  if public.fn_page_content_problem(162, jsonb_set(v_content, '{hours,mon,close}', '"25:00"')) is null then raise exception 'VERIFY 5g: an impossible hour was accepted'; end if;
  if public.fn_page_content_problem(162, jsonb_set(v_content, '{photos,0,section}', '"greaseTrap"')) is null then raise exception 'VERIFY 5h: the app-side section key was accepted (it must be mapped to grease_trap)'; end if;
  if public.fn_page_content_problem(162, jsonb_set(v_content, '{photos,0,photo_id}', '"24908"')) is null then raise exception 'VERIFY 5i: a STRING photo id was accepted'; end if;
  if public.fn_page_content_problem(162, jsonb_set(v_content, '{photos}', (v_content -> 'photos') || jsonb_build_array(jsonb_build_object('photo_id', '024908', 'section', 'job')))) is null then
    raise exception 'VERIFY 5j: a leading-zero duplicate was accepted';
  end if;
  if public.fn_page_content_problem(162, jsonb_set(v_content, '{photos,0,marks,0,number}', '0')) is null then raise exception 'VERIFY 5k: mark number 0 was accepted'; end if;
  if public.fn_page_content_problem(162, '{"v":1,"photos":null}'::jsonb) is null then raise exception 'VERIFY 5l: photos null was accepted'; end if;

  -- V6..V13 write test rows; the sentinel at the end rolls every one of them back.
  begin
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', v_fred, 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);

    -- V6. A signed-in browser cannot read the tables or call the driver function directly.
    begin
      perform 1 from public.property_pages limit 1;
      raise exception 'VERIFY 6a: authenticated read public.property_pages' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      if v_state <> '42501' then raise; end if;
    end;
    begin
      perform public.fn_driver_page('AAAAAAAAAAAAAAAAAAAAAA');
      raise exception 'VERIFY 6b: authenticated executed public.fn_driver_page' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      if v_state <> '42501' then raise; end if;
    end;

    -- V6c. A photo row forged by a staff session with a '../' path onto visit 8113 is never offered.
    insert into public.photos (storage_path, content_type, source)
    values ('../manifests/derm/1710/address_1.jpg', 'image/jpeg', 'admin_review_upload') returning id into v_forged;
    insert into public.photo_links (photo_id, entity_type, entity_id, role) values (v_forged, 'visit', 8113, '[TEST] forged');

    -- V7. The builder read, and the submit guards (Fred).
    v_pb := client.get_page_builder(162);
    v_src := v_pb -> 'property' -> 'source';
    if not (v_pb -> 'pool') @> '[{"photo_id":24908},{"photo_id":24909}]'::jsonb then
      raise exception 'VERIFY 7a: the pool for 162 lacks the two visit photos: %', v_pb -> 'pool';
    end if;
    if (v_pb -> 'pool') @> jsonb_build_array(jsonb_build_object('photo_id', v_forged)) then
      raise exception 'VERIFY 7a2: the forged ../ photo is in the pool';
    end if;
    if (v_pb ->> 'newest_version')::int <> 0 or (v_pb ->> 'can_approve')::boolean
       or v_pb -> 'property' -> 'driver_link_blocker' <> 'null'::jsonb then
      raise exception 'VERIFY 7b: a fresh property should have version 0, nothing to approve, and a working link';
    end if;
    begin
      perform client.submit_property_page(162, v_content, null, 0, v_src);
      raise exception 'VERIFY 7c: a NULL expected_version was accepted' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '22023' or v_detail not like 'blocker=expected_version_required%' then raise; end if;
    end;
    begin
      perform client.submit_property_page(162, jsonb_set(v_content, '{photos,0,photo_id}', to_jsonb(v_forged)), 0, 0, v_src);
      raise exception 'VERIFY 7c2: the forged ../ photo was accepted by submit' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '22023' or v_detail not like ('blocker=content% photo_id=' || v_forged) then raise; end if;
    end;
    -- 7c3. A property change between loading the builder and submitting is refused (rolled back here).
    begin
      reset role;
      update public.properties set grease_trap_manhole_count = grease_trap_manhole_count + 1 where id = 162;
      set local role authenticated;
      perform client.submit_property_page(162, v_content, 0, 0, v_src);
      raise exception 'VERIFY 7c3: a changed property was not noticed at submit' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '40001' or v_detail not like 'blocker=source_changed%' then raise; end if;
    end;
    v_ok := client.submit_property_page(162, v_content, 0, 0, v_src);
    v_page1 := (v_ok ->> 'page_id')::bigint;
    if (v_ok ->> 'version')::int <> 1 then raise exception 'VERIFY 7d: first submit should be version 1: %', v_ok; end if;
    begin
      perform client.submit_property_page(162, v_content, 0, 0, v_src);
      raise exception 'VERIFY 7e: a stale expected_version was accepted' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '40001' or v_detail not like 'blocker=version_clash%' then raise; end if;
    end;
    begin
      perform client.submit_property_page(162, v_content, 1, 5, v_src);
      raise exception 'VERIFY 7f: a stale map revision was accepted' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '40001' or v_detail not like 'blocker=map_changed%' then raise; end if;
    end;
    begin
      perform client.submit_property_page(162, jsonb_set(v_content, '{photos,0,photo_id}', '27404'), 1, 0, v_src);
      raise exception 'VERIFY 7g: a foreign photo was accepted by submit' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '22023' or v_detail not like 'blocker=content% photo_id=27404' then raise; end if;
    end;
    begin
      perform client.approve_property_page(v_page1);
      raise exception 'VERIFY 7h: Fred (not an approver) approved' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '42501' or v_detail not like 'blocker=not_an_approver%' then raise; end if;
    end;

    -- V8. Two-person rule: Yannick submits v2 (the STORED v1 content sent back as it is), cannot
    --     approve it; Serena cannot approve the older v1, approves v2, cannot approve it twice.
    perform set_config('request.jwt.claims', json_build_object('sub', v_yan, 'email', 'yannick@ayache.com', 'role', 'authenticated')::text, true);
    v_pb := client.get_page_builder(162);
    v_ok := client.submit_property_page(162, v_pb -> 'pending' -> 'content', 1, 0, v_pb -> 'property' -> 'source');
    v_page2 := (v_ok ->> 'page_id')::bigint;
    begin
      perform client.approve_property_page(v_page2);
      raise exception 'VERIFY 8a: Yannick approved his own version' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '42501' or v_detail not like 'blocker=own_version%' then raise; end if;
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', v_serena, 'email', 'serena@unclogme.com', 'role', 'authenticated')::text, true);
    v_pb := client.get_page_builder(162);
    if not (v_pb ->> 'can_approve')::boolean or (v_pb -> 'pending' ->> 'version')::int <> 2
       or v_pb -> 'pending' ->> 'submitted_by_name' <> 'Yannick' then
      raise exception 'VERIFY 8b: Serena should be able to approve pending v2 by Yannick: %', v_pb ->> 'approve_blocker';
    end if;
    begin
      perform client.approve_property_page(v_page1);
      raise exception 'VERIFY 8c: an older version was approved' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '22023' or v_detail not like 'blocker=not_newest%' then raise; end if;
    end;
    perform client.approve_property_page(v_page2);
    begin
      perform client.approve_property_page(v_page2);
      raise exception 'VERIFY 8d: a version was approved twice' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      if v_state <> '22023' or v_detail not like 'blocker=already_approved%' then raise; end if;
    end;
    v_pb := client.get_page_builder(162);
    v_code := v_pb -> 'link' ->> 'public_id';
    if v_code is null or v_code !~ '^[A-Za-z0-9]{22}$' then raise exception 'VERIFY 8e: no 22-character link after the first submit'; end if;
    if (v_pb -> 'live' ->> 'version')::int <> 2 or v_pb -> 'pending' <> 'null'::jsonb
       or v_pb -> 'live' ->> 'approved_by_name' <> 'Serena' then
      raise exception 'VERIFY 8f: live should be v2 approved by Serena with nothing pending';
    end if;
    if (v_pb -> 'live' -> 'content' -> 'photos' -> 0 ->> 'rot') is null or not (v_pb -> 'live' -> 'content' ? 'site_map') then
      raise exception 'VERIFY 8g: the frozen version lacks the photo rotation or the site map copy';
    end if;
    -- 8h..8j. The link was audited WITHOUT its value; the approval was audited.
    select count(*) into v_n from audit.logs a
     where a.table_name = 'property_page_links' and a.operation = 'INSERT'
       and (a.new_row ->> 'property_id')::bigint = 162;
    if v_n <> 1 then raise exception 'VERIFY 8h: expected 1 audit row for the new link, got %', v_n; end if;
    if exists (select 1 from audit.logs a where a.table_name = 'property_page_links'
                and (a.new_row ? 'public_id' or a.old_row ? 'public_id')) then
      raise exception 'VERIFY 8i: audit.logs holds a driver link value';
    end if;
    if not exists (select 1 from audit.logs a where a.table_name = 'property_pages' and a.operation = 'UPDATE'
                    and (a.new_row ->> 'version')::int = 2 and a.new_row ->> 'approved_by_email' = 'serena@unclogme.com') then
      raise exception 'VERIFY 8j: the approval was not audited';
    end if;

    -- V9. The driver page, called as service_role (the edge function's role).
    reset role;
    set local role service_role;
    if public.fn_driver_page('short') is not null then raise exception 'VERIFY 9a: a malformed code returned a page'; end if;
    if public.fn_driver_page('AAAAAAAAAAAAAAAAAAAAAA') is not null then raise exception 'VERIFY 9b: an unknown code returned a page'; end if;
    v_ok := public.fn_driver_page(v_code, false, '[TEST] verify');
    if v_ok is null or (v_ok ->> 'version')::int <> 2 or v_ok ->> 'approved_by' <> 'Serena'
       or jsonb_array_length(v_ok -> 'photos') <> 1 or v_ok -> 'photos' -> 0 ->> 'bucket' <> 'GT - Visits Images'
       or v_ok -> 'photos' -> 0 ->> 'path' not like 'admin-review/8113/%' or (v_ok ->> 'photos_unavailable')::int <> 0
       or v_ok -> 'content' ? 'photos' or v_ok -> 'property' ->> 'client_code' <> '112-YA' then
      raise exception 'VERIFY 9c: the driver page is wrong: %', v_ok;
    end if;
    perform public.fn_driver_page(v_code, false, '[TEST] verify');
    perform public.fn_driver_page(v_code, true, '[TEST] verify');
    select count(*) into v_n from public.property_page_opens where property_id = 162;
    if v_n <> 2 then raise exception 'VERIFY 9d: expected 2 open rows (one driver, one staff), got %', v_n; end if;
    reset role;

    -- V10. The list, then a newer pending version does not replace the live one; rotation.
    select * into v_row from client.page_builder_list() x where x.property_id = 162;
    if v_row.live_version <> 2 or v_row.pending_version is not null or not v_row.has_link
       or v_row.last_opened_at is null or v_row.property_changed_since_live or v_row.photos_no_longer_available <> 0
       or v_row.link_blocker is not null or v_row.live_approved_by_name <> 'Serena' then
      raise exception 'VERIFY 10a: the list row for 162 is wrong';
    end if;
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', v_fred, 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
    perform client.submit_property_page(162, jsonb_set(v_content, '{notes}', '"[TEST] v3"'), 2, 0, v_src);
    v_code2 := (client.rotate_driver_link(162)) ->> 'public_id';
    reset role;
    if exists (select 1 from audit.logs a where a.table_name = 'property_page_links'
                and (a.new_row ? 'public_id' or a.old_row ? 'public_id')) then
      raise exception 'VERIFY 10e: the rotation put a driver link value into audit.logs';
    end if;
    select * into v_row from client.page_builder_list() x where x.property_id = 162;
    if v_row.live_version <> 2 or v_row.pending_version <> 3 or v_row.pending_submitted_by_name <> 'Fred' then
      raise exception 'VERIFY 10b: live 2 and pending 3 by Fred expected';
    end if;
    if public.fn_driver_page(v_code) is not null then raise exception 'VERIFY 10c: the rotated-away link still works'; end if;
    if (public.fn_driver_page(v_code2) ->> 'version')::int <> 2 then raise exception 'VERIFY 10d: the new link must serve the live v2, not pending v3'; end if;

    -- V11. A photo removed from its visit disappears; a property change is flagged; a removed property serves nothing.
    update public.photo_links set deleted_at = now() where photo_id = 24908 and entity_type = 'visit' and entity_id = 8113;
    v_ok := public.fn_driver_page(v_code2);
    if jsonb_array_length(v_ok -> 'photos') <> 0 or (v_ok ->> 'photos_unavailable')::int <> 1 then
      raise exception 'VERIFY 11a: a photo unlinked from its visit still shows: %', v_ok -> 'photos';
    end if;
    if (select x.photos_no_longer_available from client.page_builder_list() x where x.property_id = 162) <> 1 then
      raise exception 'VERIFY 11b: the list does not count the unavailable photo';
    end if;
    update public.properties set grease_trap_manhole_count = grease_trap_manhole_count + 1 where id = 162;
    if not (select x.property_changed_since_live from client.page_builder_list() x where x.property_id = 162) then
      raise exception 'VERIFY 11c: a property change since approval is not flagged';
    end if;
    update public.properties set deleted_at = now() where id = 162;
    if public.fn_driver_page(v_code2) is not null then raise exception 'VERIFY 11d: a removed property still serves its page'; end if;

    -- V12. Append-only, including an insert that arrives approved.
    begin
      update public.property_pages set content = '{"photos":[]}'::jsonb where property_id = 162 and version = 1;
      raise exception 'VERIFY 12a: a version was edited' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      if v_state <> '55000' then raise; end if;
    end;
    begin
      delete from public.property_pages where property_id = 162;
      raise exception 'VERIFY 12b: a version was deleted' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      if v_state <> '55000' then raise; end if;
    end;
    begin
      insert into public.property_pages (property_id, version, content, source, submitted_by, submitted_by_email, approved_at, approved_by, approved_by_email)
      values (1164, 1, '{"v":1,"photos":[]}', '{}', v_fred, 'fred@ayache.com', now(), v_serena, 'serena@unclogme.com');
      raise exception 'VERIFY 12c: a version arrived already approved' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      if v_state <> '55000' then raise; end if;
    end;
    begin
      insert into public.property_pages (property_id, version, content, source, submitted_by, submitted_by_email)
      values (1164, 1, '{"v":1,"photos":null}', '{}', v_fred, 'fred@ayache.com');
      raise exception 'VERIFY 12d: a version with photos null was stored' using errcode = 'P0003';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      if v_state <> '23514' then raise; end if;
    end;

    -- V13. An unsubmitted intake's photo is not offered (fixture intake on 1164, rolled back).
    insert into public.property_intakes (property_id, form_snapshot, requested, requested_by)
    select 1164, s, to_jsonb(public.fn_intake_normalise_requested(s, (select array_agg(question_key) from client.v_intake_questions))),
           '[TEST] page verify'
      from (select public.fn_intake_form_current() s) x
    returning id into v_intake;
    insert into public.photos (storage_path, content_type)
    values ('intake-photos/' || v_intake || '/00000000-0000-0000-0000-000000000000.jpg', 'image/jpeg')
    returning id into v_ph;
    insert into public.photo_links (photo_id, entity_type, entity_id, role)
    values (v_ph, 'property_intake', v_intake, 'access_entry.gate_photos');
    if exists (select 1 from public.fn_page_photo_ids(1164) where photo_id = v_ph) then
      raise exception 'VERIFY 13: a photo of an UNSUBMITTED intake is offered';
    end if;

    raise exception 'VERIFY_ROLLBACK_SENTINEL';
  exception when others then
    if sqlerrm <> 'VERIFY_ROLLBACK_SENTINEL' then raise; end if;
  end;

  -- V14. Nothing from the test survived.
  if exists (select 1 from public.property_pages) or exists (select 1 from public.property_page_links)
     or exists (select 1 from public.property_page_opens)
     or exists (select 1 from public.property_intakes where requested_by = '[TEST] page verify')
     or exists (select 1 from public.photos where storage_path = '../manifests/derm/1710/address_1.jpg') then
    raise exception 'VERIFY 14: test rows survived the rollback';
  end if;
  if exists (select 1 from public.properties where id = 162 and deleted_at is not null) then
    raise exception 'VERIFY 14b: property 162 is still marked removed';
  end if;

  raise notice 'VERIFY: all page assertions passed';
end $verify$;

notify pgrst, 'reload schema';
