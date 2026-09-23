-- =============================================================================
-- 2026-09-22_2120_property_intake_photos.sql
-- Section 2 of Building Apps/docs/2026-09-23_client-intake-build-plan.md
--
-- WHAT. Lets a photo attach to an intake submission, and gives those photos a
-- PRIVATE bucket. Four co-requisite edits plus the bucket, in one atomic migration.
--
-- 🛑 THE ONE LINE THAT MATTERS: entity_type is 'property_intake', NEVER 'property'.
--
--    customer.client_access_photos already selects photo_links where
--    entity_type = ANY (ARRAY['client','property']) and returns pl.caption VERBATIM.
--    It is served by customer.get_client_portal, which is SECURITY DEFINER with
--    EXECUTE granted to anon, keyed on the lowercased client code, i.e. the
--    enumerable 300-ABC scheme the New Client dialog generates. That view has
--    returned zero rows since it was created ONLY because the CHECK forbids both
--    values. Widening the CHECK to 'property' would publish intake photos AND the
--    collector's raw captions to a public, code-guessable feed on this migration.
--    Proven reachable 2026-09-22 end to end: an anon-key POST to
--    /rest/v1/rpc/get_client_portal with Accept-Profile: customer returns HTTP 200
--    with client.access_notes populated.
--
--    'property_intake' is not in that view's array, so the feed stays empty. The
--    VERIFY block asserts BOTH halves: the new value is admitted, and 'property' is
--    still refused.
--
-- WHY THIS SHAPE. The photo stack already exists and already does everything this
-- needs except point at an intake: public.photos (storage_path, exif, rotation) +
-- public.photo_links (polymorphic entity_type/entity_id/role/caption, soft delete,
-- audited). Cloned from 2026-09-16_2030_client_reason_photos.sql, which is six days
-- old and proven.
--
-- ⚠ WHAT DOES NOT CLONE, and it is the half that matters. Every gate in the
--   reason-photos migration is keyed on a SIGNED-IN STAFF identity: the storage
--   INSERT policy requires `to authenticated`, client.fn_reason_photo_path_ok opens
--   with `if auth.uid() is null then return false`, and the attach RPC compares
--   storage owner_id to the caller. Fred's decision 6 is that the collector does NOT
--   log in, so an anonymous collector has no uid, no jwt email and no owner_id and
--   would fail all three. The replacement is token-derived and lives in the
--   intake-submit edge function (section 4 of the plan): the path is derived from the
--   intake token, the number of upload slots per token is capped, and the signed
--   upload URL has a short TTL. NOTHING in this migration grants an anonymous
--   browser a direct write.
--
-- ROLE CONVENTION. photo_links.role carries the INTAKE QUESTION KEY
-- ('access_entry.gate', 'grease_trap.lid'), so photos arrive already sorted by the
-- section they were taken in, which is Serena's requirement 3. Same append-only rule
-- as the question keys themselves.
--
-- CAPTION. photo_links.caption is the collector's RAW note and is never published as
-- written. The office's published caption belongs to the published page, which does
-- not exist yet. Do not add a second caption column here.
--
-- RULE 8, AUDIT: no new table, so nothing to opt in. public.photo_links already
-- carries audit_photo_links (measured: 3 non-internal triggers on it).
--
-- ATOMIC: no COMMIT, so a failed assertion rolls the whole thing back.
-- =============================================================================

-- ------------------------------------------------- 1. ADMIT THE NEW ENTITY TYPE
alter table public.photo_links drop constraint if exists photo_links_entity_type_chk;
alter table public.photo_links add constraint photo_links_entity_type_chk
  check (entity_type = any (array[
    'client_status_change'::text,
    'derm_manifest'::text,
    'inspection'::text,
    'job_frequency_change'::text,
    'note'::text,
    'property_intake'::text,   -- 2026-09-22. NOT 'property'. See the header.
    'visit'::text
  ]));

-- --------------------------------------- 2. THE TARGET MUST EXIST (dangling guard)
-- Without this branch the CHECK admits the kind and the trigger waves through any
-- entity_id, so a link can point at an intake that never existed.
create or replace function public.fn_photo_link_target_exists()
returns trigger language plpgsql set search_path to '' as $function$
begin
  if new.entity_type = 'visit' then
    if not exists (select 1 from public.visits v
                    where v.id = new.entity_id and v.deleted_at is null) then
      raise exception 'photo_links: visit % does not exist or is soft-deleted', new.entity_id
        using errcode = '23503';
    end if;
  elsif new.entity_type = 'job_frequency_change' then
    -- added 2026-08-19. Same class the visit branch closes: a link must not point at a
    -- record that does not exist. Three job_frequency_changes rows have already been deleted.
    if not exists (select 1 from public.job_frequency_changes f
                    where f.id = new.entity_id) then
      raise exception 'photo_links: job_frequency_change % does not exist', new.entity_id
        using errcode = '23503';
    end if;
  elsif new.entity_type = 'client_status_change' then
    -- added 2026-09-16, same class.
    if not exists (select 1 from public.client_status_changes s
                    where s.id = new.entity_id) then
      raise exception 'photo_links: client_status_change % does not exist', new.entity_id
        using errcode = '23503';
    end if;
  elsif new.entity_type = 'property_intake' then
    -- added 2026-09-22, same class. The intake row is the target; the property is
    -- reached through it, which is why there is no 'property' branch here either.
    if not exists (select 1 from public.property_intakes i
                    where i.id = new.entity_id) then
      raise exception 'photo_links: property_intake % does not exist', new.entity_id
        using errcode = '23503';
    end if;
  end if;
  return new;
end
$function$;

-- ------------------------------------- 3. CLOSE THE DENYLIST INSERT POLICY AGAIN
-- The authenticated INSERT policy on photo_links is a DENYLIST: it permits every
-- entity_type except the ones named. A newly admitted kind is therefore writable
-- from any signed-in browser BY DEFAULT. Intake links are written server-side only
-- (the intake-submit edge function on the service role), so name it and deny it,
-- exactly as job_frequency_change and client_status_change already are.
drop policy if exists "Authenticated insert photo_links" on public.photo_links;
create policy "Authenticated insert photo_links" on public.photo_links
  for insert to authenticated
  with check (
    (select auth.uid()) is not null
    and entity_type is distinct from 'job_frequency_change'
    and coalesce(role, '') is distinct from 'approval_proof'
    and entity_type is distinct from 'client_status_change'
    and coalesce(role, '') is distinct from 'reason_photo'
    and entity_type is distinct from 'property_intake'   -- 2026-09-22
  );

-- --------------------------------------------------------- 4. THE PRIVATE BUCKET
-- PRIVATE. The 5 MB ceiling on our other private buckets is a per-bucket setting each
-- migration chose, not a platform rule (app-assets is PUBLIC at 5 MB, gdo-permits is
-- PUBLIC with no limit at all), so a private bucket can hold the 50 MB the intake form
-- advertises. No anon or authenticated storage policy is created for it: uploads
-- arrive on a short-lived signed URL minted server-side, and reads are signed the
-- same way.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('intake-photos', 'intake-photos', false, 52428800,
        array['image/jpeg','image/png','image/webp','image/heic'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- ------------------------------------------------------------------- 5. VERIFY
do $verify$
declare
  v_prop bigint;
  v_intake bigint;
  v_photo bigint;
  v_link bigint;
  v_raised boolean;
  v_n int;
begin
  select id into v_prop from public.properties p
   where p.client_id = (select id from public.clients where client_code = '112-YA')
     and p.deleted_at is null and coalesce(p.is_billing,false) = false
   order by p.id limit 1;
  if v_prop is null then raise exception 'VERIFY: no 112-YA service property'; end if;

  insert into public.property_intakes (property_id, form_snapshot, requested, collector)
  values (v_prop, '{"sections":[{"id":"access_entry","questions":["access_entry.gate"]}]}'::jsonb,
          '["access_entry.gate"]'::jsonb, '[TEST] photo migration verify')
  returning id into v_intake;

  insert into public.photos (storage_path, source)
  values ('intake-photos/[TEST]/verify.jpg', 'intake_upload') returning id into v_photo;

  -- 5.1 POSITIVE CONTROL: a valid property_intake link is accepted.
  insert into public.photo_links (photo_id, entity_type, entity_id, role, caption)
  values (v_photo, 'property_intake', v_intake, 'access_entry.gate', 'gate from the alley')
  returning id into v_link;
  if v_link is null then raise exception 'VERIFY 5.1: a valid intake photo link must be accepted'; end if;

  -- 5.2 🛑 'property' MUST STILL BE REFUSED. This is the anon-portal guard.
  v_raised := false;
  begin
    insert into public.photo_links (photo_id, entity_type, entity_id, role)
    values (v_photo, 'property', v_prop, 'access');
  exception when others then v_raised := true;
  end;
  if not v_raised then
    raise exception 'VERIFY 5.2: entity_type property was ADMITTED. customer.client_access_photos would publish intake photos to the anon portal.';
  end if;

  -- 5.3 the dangling guard actually fires for the new kind
  v_raised := false;
  begin
    insert into public.photo_links (photo_id, entity_type, entity_id, role)
    values (v_photo, 'property_intake', 999999999, 'access_entry.gate');
  exception when others then v_raised := true;
  end;
  if not v_raised then raise exception 'VERIFY 5.3: a dangling property_intake link was accepted'; end if;

  -- 5.4 the anon-facing view is still empty, and stays empty by construction
  select count(*) into v_n from customer.client_access_photos;
  if v_n <> 0 then
    raise exception 'VERIFY 5.4: customer.client_access_photos returned % rows, it must stay empty', v_n;
  end if;

  -- 5.5 the denylist policy names the new kind (a signed-in browser cannot insert one)
  select count(*) into v_n from pg_policy
   where polrelid = 'public.photo_links'::regclass and polcmd = 'a'
     and pg_get_expr(polwithcheck, polrelid) like '%property_intake%';
  if v_n <> 1 then raise exception 'VERIFY 5.5: the INSERT policy does not deny property_intake'; end if;

  -- 5.6 the bucket is private, 50 MB, image-only
  select count(*) into v_n from storage.buckets
   where id = 'intake-photos' and public = false and file_size_limit = 52428800;
  if v_n <> 1 then raise exception 'VERIFY 5.6: intake-photos bucket is missing or not private/50MB'; end if;

  -- 5.7 no anon or authenticated storage policy reaches the new bucket
  select count(*) into v_n from pg_policy
   where polrelid = 'storage.objects'::regclass
     and pg_get_expr(coalesce(polqual, polwithcheck), polrelid) like '%intake-photos%';
  if v_n <> 0 then raise exception 'VERIFY 5.7: % storage policies mention intake-photos; uploads must be server-mediated', v_n; end if;

  -- clean up
  delete from public.photo_links where photo_id = v_photo;
  delete from public.photos where id = v_photo;
  delete from public.property_intakes where id = v_intake;

  raise notice 'VERIFY: all photo assertions passed';
end $verify$;

notify pgrst, 'reload schema';
