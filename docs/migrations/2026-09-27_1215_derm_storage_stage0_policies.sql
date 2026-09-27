-- 2026-09-27 12:15 ET
-- DERM storage Stage 0.3: no anonymous uploads under derm/, and no signed-in deletes under derm/,
-- on the two PUBLIC buckets ('GT - Visits Images', 'manifests').
--
-- WHY (Fred, 2026-09-27: "Start with Stage 0"). Plan:
-- docs/superpowers/specs/2026-09-27-derm-storage-private-plan.md, Stage 0.3. The derm/ folders hold
-- ~3,000 DERM paperwork files. Anyone could still UPLOAD into them without logging in (two anon INSERT
-- policies), and any signed-in user could DELETE any of them (bucket-wide authenticated DELETE; there
-- were 0 RESTRICTIVE storage policies). Measured before this change: no anonymous write to
-- manifests/derm since 2026-08-10, 0 of the GT/derm objects have an owner, the DERM Tracker uploads as
-- a signed-in user, and the only storage .remove( in any live app bundle is the Client App's reason
-- photos (another bucket).
--
-- WHAT. (1) Drop the two anon INSERT policies. (2) Add ONE RESTRICTIVE DELETE policy for authenticated:
-- nothing under derm/ in these two buckets can be deleted by a signed-in user. Signed-in INSERT, UPDATE
-- and SELECT are unchanged (the DERM Tracker's uploads keep working). service_role (edge functions,
-- the pdf-service, our migration tooling) bypasses RLS and is unaffected. No object is touched.
--
-- ROLLBACK (the exact originals, read from pg_policies 2026-09-27):
--   create policy "Anon can upload to derm path in GT visit images" on storage.objects
--     as permissive for insert to anon
--     with check ((bucket_id = 'GT - Visits Images'::text) AND ((storage.foldername(name))[1] = 'derm'::text));
--   create policy "Anon can upload to derm path in manifests" on storage.objects
--     as permissive for insert to anon
--     with check ((bucket_id = 'manifests'::text) AND ((storage.foldername(name))[1] = 'derm'::text));
--   drop policy "No signed-in delete under derm (public buckets)" on storage.objects;
--
-- Rule 8: no business table changes; storage.objects policies only.

begin;

drop policy "Anon can upload to derm path in GT visit images" on storage.objects;
drop policy "Anon can upload to derm path in manifests" on storage.objects;

create policy "No signed-in delete under derm (public buckets)" on storage.objects
  as restrictive for delete to authenticated
  using (not (bucket_id in ('GT - Visits Images', 'manifests') and (storage.foldername(name))[1] = 'derm'));

-- VERIFY
do $$
declare v_qual text;
begin
  if exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
              and policyname in ('Anon can upload to derm path in GT visit images', 'Anon can upload to derm path in manifests')) then
    raise exception 'VERIFY: an anon upload policy is still there';
  end if;
  if exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
              and cmd = 'INSERT' and roles::text like '%anon%'
              and (coalesce(with_check, '') ~ '(GT - Visits Images|manifests)')) then
    raise exception 'VERIFY: another anon INSERT policy still reaches these buckets';
  end if;
  select qual into v_qual from pg_policies where schemaname = 'storage' and tablename = 'objects'
     and policyname = 'No signed-in delete under derm (public buckets)' and permissive = 'RESTRICTIVE'
     and cmd = 'DELETE' and roles::text = '{authenticated}';
  if v_qual is null then raise exception 'VERIFY: the restrictive delete policy is missing or misdefined'; end if;

  -- the predicate itself, on sample names (true = delete allowed)
  if (select not (b in ('GT - Visits Images', 'manifests') and (storage.foldername(n))[1] = 'derm')
        from (values ('GT - Visits Images', 'derm/1941/fog.pdf')) v(b, n)) then
    raise exception 'VERIFY: GT derm/1941/fog.pdf would still be deletable';
  end if;
  if (select not (b in ('GT - Visits Images', 'manifests') and (storage.foldername(n))[1] = 'derm')
        from (values ('manifests', 'derm/1600/address_1.jpg')) v(b, n)) then
    raise exception 'VERIFY: manifests derm/... would still be deletable';
  end if;
  if not (select not (b in ('GT - Visits Images', 'manifests') and (storage.foldername(n))[1] = 'derm')
            from (values ('GT - Visits Images', 'visits/123/before_1.jpg')) v(b, n)) then
    raise exception 'VERIFY: visits/ photos would become undeletable (control)';
  end if;
  if not (select not (b in ('GT - Visits Images', 'manifests') and (storage.foldername(n))[1] = 'derm')
            from (values ('manifests', 'redacted/m1-abcdef0123.jpg')) v(b, n)) then
    raise exception 'VERIFY: manifests/redacted would become undeletable (control)';
  end if;
  if not (select not (b in ('GT - Visits Images', 'manifests') and (storage.foldername(n))[1] = 'derm')
            from (values ('reason-photos', 'derm/x.jpg')) v(b, n)) then
    raise exception 'VERIFY: another bucket with a derm/ folder would be affected (control)';
  end if;
  raise notice 'stage 0.3 applied: anon derm uploads closed, signed-in derm deletes blocked';
end $$;

commit;
