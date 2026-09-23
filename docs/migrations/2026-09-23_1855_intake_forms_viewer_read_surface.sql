-- =============================================================================
-- 2026-09-23_1855_intake_forms_viewer_read_surface.sql
-- Section A of Building Apps/docs/2026-09-23_intake-forms-viewer-plan.md
--
-- WHAT. The read surface for the Intake Forms viewer Fred asked for in Picture
-- Planner: "i want the Data coming back from the form, to be visible and immutable
-- at the Picture Planner ... it should be read-only ... cards with the key data on
-- it, and when clicked it opens a new view of it". Three objects:
--   A.1 client.v_intake_submissions        the card list (submitted AND awaiting)
--   A.2 client.get_intake(bigint)          one form, in full
--   A.3 storage policy intake_photos_staff_read on bucket intake-photos
-- Plus one grant that fixes an existing latent defect (A.4).
--
-- NOTHING HERE WRITES. The raw submission is already immutable
-- (property_intakes_immutable, 2026-09-22_2043); this migration grants SELECT/EXECUTE
-- only and adds no write RPC.
--
-- WHO "authenticated" IS, MEASURED 2026-09-23 RATHER THAN ASSUMED. The auth hook
-- public.fn_restrict_signup_domains (hook_before_user_created) refuses any sign-up whose
-- domain is not EXACTLY ayache.com or unclogme.com, and auth.users holds 8 accounts:
-- 4 ayache.com, 4 unclogme.com, 0 other. So a grant to authenticated is a grant to staff,
-- enforced at sign-up. get_intake still repeats the staff check, because its payload holds
-- gate codes, lock-box codes and alarm instructions, and the other client.* functions that
-- return intake data do the same.
--
-- 🛑 THE FIRST DRAFT OF THIS MIGRATION WAS WRONG, AND AN ADVERSARIAL REVIEW CAUGHT IT
--    BEFORE IT SHIPPED. It gated intake photos behind "readable only once the form is
--    submitted", on the premise that staff could not read live tokens, because
--    authenticated holds no grant on public.property_intakes. That premise was false.
--    intake-submit stored photos at `<token>/<uuid>.<ext>`, and public.photos.storage_path
--    is readable by every staff session: public.photos carries three authenticated SELECT
--    policies with qual true, and client.photos is an unfiltered view. So the live token was
--    one REST call away, and the storage gate hid a listing while the same string sat in a
--    readable column. Two reviewers found it independently; a skeptic confirmed it.
--    ⇒ THE FIX REMOVED THE SECRET RATHER THAN GUARDING IT. intake-submit v7 (deployed
--      2026-09-23, verified against the deployed body) builds the folder from the INTAKE
--      ID, never the token, and attach checks the exact path shape. 0 photos had been
--      stored under the old scheme, so nothing needed moving. The token now appears nowhere
--      a staff session can read, and the storage policy below can be the estate's plain
--      staff read, a copy of reason_photos_staff_read.
--    ⇒ AND IT KEPT A FUNCTION OUT OF A storage.objects POLICY. Every permissive SELECT
--      policy on storage.objects is OR'd into EVERY staff storage read in EVERY bucket, and
--      Postgres checks EXECUTE when it initialises the expression. A predicate function in
--      that policy would have made all staff photo reads estate-wide depend on one grant.
--
-- PHOTOS ARE RETURNED ONLY FOR A SUBMITTED INTAKE, BY PRODUCT RULE, NOT SECURITY. The
-- submission is the record; an awaiting form's half-uploaded photos are not data yet.
-- The list view reports answered_count, status, photo_count and the pins as NULL for an
-- awaiting intake for the same reason.
--
-- THE QUESTIONS COME FROM THE INTAKE'S OWN form_snapshot, never fn_intake_form_current().
-- A form collected under an older question list renders the questions actually asked.
-- Legacy string-shaped questions ("questions":["access_entry.gate"]) are read too, and a
-- snapshot item with no key cannot poison the membership tests (arrays are built with the
-- NULLs filtered out; a NULL inside `= ANY(...)` would drop every "unlisted" row).
--
-- NOTHING IS DROPPED SILENTLY. get_intake renders every REQUESTED key: the ones the
-- snapshot defines in their sections, and any the snapshot does not define in a final
-- section titled for what it is. Answers and photos on keys that were not requested are
-- returned under unlisted_answers / unlisted_photos.
--
-- STATUS MIRRORS client.v_property_intake EXACTLY: Complete iff every requested key is
-- answered by public.fn_intake_answered. The VERIFY asserts the two agree on a Complete
-- AND an Incomplete intake rather than trusting the expression was copied correctly.
--
-- RULE 8, AUDIT: a view, a function, a storage policy and a grant. Nothing to opt in; the
-- tables they read are already audited.
-- ATOMIC: no COMMIT, so a failed assertion rolls the whole migration back.
-- =============================================================================


-- ============================================================ A.1 the card list
create or replace view client.v_intake_submissions as
select
  i.id                                                    as intake_id,
  case when i.submitted_at is not null then 'submitted' else 'awaiting' end as state,
  i.property_id,
  p.client_id,
  c.client_code,
  c.name                                                  as client_name,
  p.address,
  p.city,
  (p.deleted_at is not null)                              as property_deleted,
  i.requested_by,
  i.requested_at,
  i.expires_at,
  i.collector,
  i.submitted_at,
  jsonb_array_length(i.requested)                         as requested_count,
  case when i.submitted_at is null then null else
    (select count(*)::integer
       from jsonb_array_elements_text(i.requested) k(value)
      where public.fn_intake_answered(i.answers, k.value)) end              as answered_count,
  case when i.submitted_at is null then null
       when not exists (select 1
                          from jsonb_array_elements_text(i.requested) k(value)
                         where not public.fn_intake_answered(i.answers, k.value)) then 'Complete'
       else 'Incomplete' end                                                as status,
  case when i.submitted_at is null then null else
    (select count(*)::integer
       from public.photo_links pl
      where pl.entity_type = 'property_intake'
        and pl.entity_id = i.id
        and pl.deleted_at is null) end                                      as photo_count,
  case when i.submitted_at is null then null
       else public.fn_intake_answered(i.answers, 'site_map.gt_location') end   as has_gt_pin,
  case when i.submitted_at is null then null
       else public.fn_intake_answered(i.answers, 'site_map.truck_parking') end as has_truck_pin,
  (select count(*)::integer
     from public.property_intake_accepts a where a.intake_id = i.id)        as accepted_count,
  (select max(a.accepted_at)
     from public.property_intake_accepts a where a.intake_id = i.id)        as last_accepted_at
from public.property_intakes i
join public.properties p on p.id = i.property_id
left join public.clients c on c.id = p.client_id
where i.cancelled_at is null
  and (i.submitted_at is not null or i.expires_at > now());

comment on view client.v_intake_submissions is
  'One row per intake the Picture Planner /forms list shows: every submitted intake, and every '
  'awaiting one whose link is still live (state = awaiting). Cancelled and expired-unused intakes '
  'are excluded. Carries no answer VALUES: those, including gate and lock-box codes, come only '
  'from client.get_intake, which re-checks the staff domain. answered_count, status, photo_count '
  'and the pin flags are NULL for an awaiting intake, because nothing has been collected yet. '
  'status mirrors client.v_property_intake: Complete iff every requested key is answered.';

revoke all on client.v_intake_submissions from public, anon, authenticated;
grant select on client.v_intake_submissions to authenticated;


-- ============================================================ A.2 one form, in full
create or replace function client.get_intake(p_intake_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  v_i            public.property_intakes;
  v_submitted    boolean;
  v_req          text[];
  v_known        text[];
  v_orphans      text[];
  v_photos       jsonb := '{}'::jsonb;
  v_sections     jsonb;
  v_other        jsonb;
  v_other_photos jsonb;
  v_accepted     jsonb;
  v_prop         jsonb;
  v_status       text;
  v_state        text;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email', '')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email', '')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_intake_id is null then
    raise exception 'p_intake_id is required' using errcode = '22023';
  end if;

  select * into v_i from public.property_intakes where id = p_intake_id;
  if not found then
    raise exception 'intake % does not exist', p_intake_id using errcode = 'P0002';
  end if;

  v_submitted := v_i.submitted_at is not null;
  v_state := case when v_i.cancelled_at is not null then 'cancelled'
                  when v_submitted                   then 'submitted'
                  when v_i.expires_at <= now()       then 'expired'
                  else 'awaiting' end;

  -- Both key sets are built WITHOUT NULLs. A NULL inside `x = ANY(arr)` makes every
  -- non-member test NULL, which a WHERE clause drops, so one keyless snapshot item would
  -- otherwise empty the unlisted lists for the whole intake.
  select coalesce(array_agg(x) filter (where x is not null and x <> ''), '{}') into v_req
    from jsonb_array_elements_text(v_i.requested) x;

  select coalesce(array_agg(k) filter (where k is not null and k <> ''), '{}') into v_known
    from jsonb_array_elements(coalesce(v_i.form_snapshot -> 'sections', '[]'::jsonb)) s,
         jsonb_array_elements(coalesce(s -> 'questions', '[]'::jsonb)) q,
         lateral (select case when jsonb_typeof(q) = 'string' then q #>> '{}' else q ->> 'key' end) kk(k);

  -- Requested keys this snapshot does not define. schedule_property_intake refuses them,
  -- so this should be empty, but "should be" is not "is": they are rendered, not dropped.
  select coalesce(array_agg(r order by r), '{}') into v_orphans
    from unnest(v_req) r
   where not (r = any (v_known));

  -- Photos only for a submitted intake: the product rule (see the header). The folder is
  -- the intake id since intake-submit v7, never the token, so `path` carries no secret.
  if v_submitted then
    select coalesce(jsonb_object_agg(z.role, z.photos), '{}'::jsonb) into v_photos
      from (select pl.role,
                   jsonb_agg(jsonb_build_object(
                       'photo_id',     ph.id,
                       'bucket',       'intake-photos',
                       'path',         substr(ph.storage_path, length('intake-photos/') + 1),
                       'caption',      pl.caption,
                       'content_type', ph.content_type) order by pl.id) as photos
              from public.photo_links pl
              join public.photos ph on ph.id = pl.photo_id
             where pl.entity_type = 'property_intake'
               and pl.entity_id = v_i.id
               and pl.deleted_at is null
               and ph.storage_path like 'intake-photos/%'
               and pl.role is not null
             group by pl.role) z;
  end if;

  -- The intake's OWN snapshot, requested questions only, in snapshot order; a section
  -- with no requested question is omitted; an unanswered requested question is kept with
  -- answered = false so it renders as an explicit blank.
  select coalesce(jsonb_agg(z.sec order by z.s_ord), '[]'::jsonb) into v_sections
    from (select s.ord as s_ord,
                 jsonb_build_object(
                   'id',    s.section ->> 'id',
                   'title', coalesce(s.section ->> 'title', s.section ->> 'id'),
                   'questions', jsonb_agg(jsonb_build_object(
                       'key',      q.k,
                       'label',    q.label,
                       'type',     q.typ,
                       'options',  q.opts,
                       'show_if',  q.show_if,
                       'answered', v_submitted and public.fn_intake_answered(v_i.answers, q.k),
                       'value',    case when v_submitted then v_i.answers -> q.k -> 'value' end,
                       'photos',   coalesce(v_photos -> q.k, '[]'::jsonb)) order by q.ord)) as sec
            from jsonb_array_elements(coalesce(v_i.form_snapshot -> 'sections', '[]'::jsonb))
                   with ordinality s(section, ord)
            cross join lateral (
              select qq.ord,
                     case when jsonb_typeof(qq.q) = 'string' then qq.q #>> '{}' else qq.q ->> 'key' end as k,
                     case when jsonb_typeof(qq.q) = 'string' then qq.q #>> '{}'
                          else coalesce(qq.q ->> 'label', qq.q ->> 'key') end                     as label,
                     case when jsonb_typeof(qq.q) = 'object' then qq.q ->> 'type' end              as typ,
                     case when jsonb_typeof(qq.q) = 'object' then qq.q -> 'options' end            as opts,
                     case when jsonb_typeof(qq.q) = 'object' then qq.q ->> 'show_if' end           as show_if
                from jsonb_array_elements(coalesce(s.section -> 'questions', '[]'::jsonb))
                       with ordinality qq(q, ord)
            ) q
           where q.k = any (v_req)
           group by s.ord, s.section) z;

  -- Requested but undefined keys: one final section, never dropped.
  if cardinality(v_orphans) > 0 then
    v_sections := v_sections || jsonb_build_array(jsonb_build_object(
      'id',    '_not_in_form_definition',
      'title', 'Asked, but not in this form''s definition',
      'questions', (select jsonb_agg(jsonb_build_object(
                        'key',      o,
                        'label',    o,
                        'type',     null,
                        'options',  null,
                        'show_if',  null,
                        'answered', v_submitted and public.fn_intake_answered(v_i.answers, o),
                        'value',    case when v_submitted then v_i.answers -> o -> 'value' end,
                        'photos',   coalesce(v_photos -> o, '[]'::jsonb)) order by o)
                      from unnest(v_orphans) o)));
  end if;

  -- Answers and photos on keys that were NOT requested: surfaced, never dropped. Every
  -- requested key is rendered above (defined or orphan), so "not requested" is the
  -- complete complement and nothing falls between the two lists.
  select coalesce(jsonb_agg(jsonb_build_object('key', e.k, 'value', e.v -> 'value') order by e.k), '[]'::jsonb)
    into v_other
    from jsonb_each(coalesce(v_i.answers, '{}'::jsonb)) e(k, v)
   where v_submitted and not (e.k = any (v_req));

  select coalesce(jsonb_agg(jsonb_build_object('role', e.key, 'photos', e.value) order by e.key), '[]'::jsonb)
    into v_other_photos
    from jsonb_each(v_photos) e
   where not (e.key = any (v_req));

  select coalesce(jsonb_agg(jsonb_build_object(
             'question_key',  a.question_key,
             'target_column', a.target_column,
             'old_value',     a.old_value,
             'new_value',     a.new_value,
             'actor',         a.actor,
             'accepted_at',   a.accepted_at) order by a.accepted_at, a.id), '[]'::jsonb)
    into v_accepted
    from public.property_intake_accepts a
   where a.intake_id = v_i.id;

  select jsonb_build_object(
           'id',          p.id,
           'address',     p.address,
           'city',        p.city,
           'deleted',     p.deleted_at is not null,
           'client_id',   c.id,
           'client_code', c.client_code,
           'client_name', c.name)
    into v_prop
    from public.properties p
    left join public.clients c on c.id = p.client_id
   where p.id = v_i.property_id;

  -- Mirrors client.v_property_intake exactly (over the raw requested array, as it does).
  v_status := case when not v_submitted then null
                   when not exists (select 1
                                      from jsonb_array_elements_text(v_i.requested) k(value)
                                     where not public.fn_intake_answered(v_i.answers, k.value)) then 'Complete'
                   else 'Incomplete' end;

  return jsonb_build_object(
    'intake_id',        v_i.id,
    'state',            v_state,
    'status',           v_status,
    'property',         v_prop,
    'requested_by',     v_i.requested_by,
    'requested_at',     v_i.requested_at,
    'expires_at',       v_i.expires_at,
    'collector',        v_i.collector,
    'submitted_at',     v_i.submitted_at,
    'requested_count',  jsonb_array_length(v_i.requested),
    'sections',         v_sections,
    'unlisted_answers', v_other,
    'unlisted_photos',  v_other_photos,
    'accepted',         v_accepted);
end $$;

comment on function client.get_intake(bigint) is
  'One intake, read-only, for the Picture Planner /forms/$id view. Questions come from the '
  'intake''s own frozen form_snapshot, requested questions only, in snapshot order; a requested key '
  'the snapshot does not define is rendered in a final section rather than dropped. Photos are '
  'returned only for a SUBMITTED intake (product rule: the submission is the record). Answers and '
  'photos on unrequested keys come back under unlisted_answers / unlisted_photos. Staff-gated '
  '(28000 / 42501).';

revoke all on function client.get_intake(bigint) from public, anon;
grant execute on function client.get_intake(bigint) to authenticated;


-- ============================================================ A.3 photos: a plain staff read
-- A copy of reason_photos_staff_read, deliberately. No predicate function: see the header.
drop policy if exists intake_photos_staff_read on storage.objects;
create policy intake_photos_staff_read on storage.objects
  for select to authenticated
  using (bucket_id = 'intake-photos' and auth.uid() is not null);


-- ============================================================ A.4 read-only roles
-- client.v_intake_submissions and client.v_property_intake are owner-rights views that call
-- the SECURITY INVOKER function public.fn_intake_answered, so the READER needs EXECUTE on it.
-- pg_read_all_data (and supabase_read_only_user, which inherits it) could SELECT the views
-- and then hit 42501 on the status columns. Same fix, same reasoning, as 2026-08-25_1500 did
-- for derm.fn_normalize_state_input: the function is IMMUTABLE and reads no table.
grant execute on function public.fn_intake_answered(jsonb, text) to pg_read_all_data;


-- ============================================================ VERIFY
do $verify$
declare
  v_p1   bigint;  v_p2 bigint;
  v_a    bigint;  v_tok_a text;
  v_b    bigint;  v_tok_b text;
  v_c    bigint;  v_d bigint;  v_e bigint;
  v_f    bigint;  v_tok_f text;
  v_ph   bigint[] := '{}';
  v_id   bigint;
  v_row  record;
  v_j    jsonb;   v_jb jsonb;
  v_raised boolean;
  v_n    int;
  -- Snapshot sections in NON-alphabetical order (site_map, access_entry, grease_trap), so
  -- an implementation that sorts by id or title cannot pass the order check. It carries a
  -- legacy string question and a keyless object question on purpose.
  v_snap jsonb := jsonb_build_object('sections', jsonb_build_array(
    jsonb_build_object('id','site_map','title','Site map','questions', jsonb_build_array(
      jsonb_build_object('key','site_map.gt_location','label','Grease trap location','type','gps_pin'),
      jsonb_build_object('key','site_map.truck_parking','label','Truck parking','type','gps_pin'))),
    jsonb_build_object('id','access_entry','title','Access & entry','questions', jsonb_build_array(
      jsonb_build_object('key','access_entry.gate','label','[TEST] label from THIS snapshot','type','yes_no'),
      jsonb_build_object('key','access_entry.gate_code','label','Gate code','type','text','show_if','access_entry.gate=yes'),
      to_jsonb('access_entry.alarm'::text))),
    jsonb_build_object('id','grease_trap','title','Grease trap','questions', jsonb_build_array(
      jsonb_build_object('key','grease_trap.photos','label','Photos','type','photos'),
      jsonb_build_object('key','grease_trap.systems_count','label','Systems','type','number'),
      jsonb_build_object('label','a snapshot item with no key','type','text')))));
begin
  -- ---------------------------------------------------------- V1 privileges and policy
  if has_table_privilege('anon','client.v_intake_submissions','SELECT') then
    raise exception 'VERIFY V1a: anon can read client.v_intake_submissions'; end if;
  if not has_table_privilege('authenticated','client.v_intake_submissions','SELECT') then
    raise exception 'VERIFY V1b: authenticated cannot read client.v_intake_submissions'; end if;
  if has_table_privilege('authenticated','client.v_intake_submissions','INSERT,UPDATE,DELETE,TRUNCATE') then
    raise exception 'VERIFY V1c: authenticated holds a write privilege on the list view'; end if;
  if has_function_privilege('anon','client.get_intake(bigint)','EXECUTE') then
    raise exception 'VERIFY V1d: anon can execute client.get_intake'; end if;
  if not has_function_privilege('authenticated','client.get_intake(bigint)','EXECUTE') then
    raise exception 'VERIFY V1e: authenticated cannot execute client.get_intake'; end if;
  -- the view calls an INVOKER function, so the READER needs EXECUTE on it
  if not has_function_privilege('authenticated','public.fn_intake_answered(jsonb,text)','EXECUTE') then
    raise exception 'VERIFY V1f: authenticated cannot execute fn_intake_answered, the view would 42501'; end if;
  if not has_function_privilege('pg_read_all_data','public.fn_intake_answered(jsonb,text)','EXECUTE') then
    raise exception 'VERIFY V1g: pg_read_all_data cannot execute fn_intake_answered'; end if;
  -- the storage policy, read off pg_policy. qual AND with_check are both searched, because
  -- an INSERT policy keeps its predicate only in with_check and qual would miss it.
  select count(*) into v_n
    from pg_policy pol
   where pol.polrelid = 'storage.objects'::regclass
     and coalesce(pg_get_expr(pol.polqual, pol.polrelid), '') || ' ' ||
         coalesce(pg_get_expr(pol.polwithcheck, pol.polrelid), '') like '%intake-photos%';
  if v_n is distinct from 1 then
    raise exception 'VERIFY V1h: expected exactly 1 policy mentioning intake-photos, found %', v_n; end if;
  select count(*) into v_n
    from pg_policy pol
   where pol.polrelid = 'storage.objects'::regclass
     and pol.polname = 'intake_photos_staff_read'
     and pol.polcmd = 'r'
     and pol.polpermissive
     and pol.polroles = array['authenticated'::regrole]::oid[]
     and pg_get_expr(pol.polqual, pol.polrelid) like '%bucket_id = ''intake-photos''%'
     and pg_get_expr(pol.polqual, pol.polrelid) like '%auth.uid() IS NOT NULL%';
  if v_n is distinct from 1 then
    raise exception 'VERIFY V1i: intake_photos_staff_read is not a permissive SELECT for authenticated on the bucket with the uid check'; end if;
  if (select public from storage.buckets where id = 'intake-photos') is not false then
    raise exception 'VERIFY V1j: bucket intake-photos is not private'; end if;

  -- ---------------------------------------------------------- fixtures, tagged [TEST]
  select min(p.id), max(p.id) into v_p1, v_p2
    from public.properties p
   where p.client_id = (select id from public.clients where client_code = '112-YA')
     and p.deleted_at is null and coalesce(p.is_billing,false) = false;
  if v_p1 is null or v_p1 = v_p2 then
    raise exception 'VERIFY: need two live service properties on 112-YA, have % and %', v_p1, v_p2; end if;

  -- A: submitted, 5 of 6 requested answered. One requested key the snapshot does not
  -- define; one answer on a defined-but-unrequested key; one answer on an undefined key.
  insert into public.property_intakes (property_id, form_snapshot, requested, collector, answers, submitted_at)
  values (v_p1, v_snap,
          '["site_map.gt_location","access_entry.gate","access_entry.gate_code","access_entry.alarm","grease_trap.photos","orphan.requested_key"]'::jsonb,
          '[TEST] viewer verify',
          jsonb_build_object(
            'site_map.gt_location',      jsonb_build_object('value', jsonb_build_object('lat', 25.79, 'lng', -80.13)),
            'access_entry.gate',         jsonb_build_object('value','yes'),
            'access_entry.gate_code',    jsonb_build_object('value','1234'),
            'grease_trap.photos',        jsonb_build_object('value', jsonb_build_array('p1')),
            'orphan.requested_key',      jsonb_build_object('value','answered orphan'),
            'grease_trap.systems_count', jsonb_build_object('value', 2),
            'zzz.not_in_form',           jsonb_build_object('value','surfaced')),
          now())
  returning id, token into v_a, v_tok_a;

  -- B: awaiting, with a photo already attached
  insert into public.property_intakes (property_id, form_snapshot, requested, requested_by)
  values (v_p1, v_snap, '["access_entry.gate"]'::jsonb, '[TEST] viewer verify')
  returning id, token into v_b, v_tok_b;

  -- C: awaiting then cancelled.  D: never submitted, link expired.  E: submitted then cancelled.
  insert into public.property_intakes (property_id, form_snapshot, requested, requested_by, cancelled_at)
  values (v_p1, v_snap, '["access_entry.gate"]'::jsonb, '[TEST] viewer verify', now()) returning id into v_c;
  insert into public.property_intakes (property_id, form_snapshot, requested, requested_by, expires_at)
  values (v_p1, v_snap, '["access_entry.gate"]'::jsonb, '[TEST] viewer verify', now() - interval '1 day') returning id into v_d;
  insert into public.property_intakes (property_id, form_snapshot, requested, collector, answers, submitted_at, cancelled_at)
  values (v_p1, v_snap, '["access_entry.gate"]'::jsonb, '[TEST] viewer verify',
          jsonb_build_object('access_entry.gate', jsonb_build_object('value','no')), now() - interval '1 hour', now())
  returning id into v_e;

  -- F: submitted on the SECOND property, every requested key answered, including a 0 and a false
  insert into public.property_intakes (property_id, form_snapshot, requested, collector, answers, submitted_at)
  values (v_p2, v_snap, '["access_entry.gate","grease_trap.systems_count","access_entry.alarm"]'::jsonb,
          '[TEST] viewer verify',
          jsonb_build_object('access_entry.gate',         jsonb_build_object('value', false),
                             'grease_trap.systems_count', jsonb_build_object('value', 0),
                             'access_entry.alarm',        jsonb_build_object('value','no')),
          now())
  returning id, token into v_f, v_tok_f;

  -- photos, in the id-named folders intake-submit v7 creates
  insert into public.photos (storage_path, source, content_type) values ('intake-photos/'||v_a||'/p1.jpg','intake_upload','image/jpeg') returning id into v_id; v_ph := v_ph || v_id;
  insert into public.photo_links (photo_id, entity_type, entity_id, role, caption) values (v_id, 'property_intake', v_a, 'grease_trap.photos', '[TEST] caption A');
  insert into public.photos (storage_path, source, content_type) values ('intake-photos/'||v_a||'/p8.jpg','intake_upload','image/jpeg') returning id into v_id; v_ph := v_ph || v_id;
  insert into public.photo_links (photo_id, entity_type, entity_id, role, caption) values (v_id, 'property_intake', v_a, 'orphan.requested_key', '[TEST] orphan-key photo');
  insert into public.photos (storage_path, source, content_type) values ('intake-photos/'||v_a||'/p9.jpg','intake_upload','image/jpeg') returning id into v_id; v_ph := v_ph || v_id;
  insert into public.photo_links (photo_id, entity_type, entity_id, role, caption) values (v_id, 'property_intake', v_a, 'zzz.orphan_role', '[TEST] unrequested-role photo');
  insert into public.photos (storage_path, source, content_type) values ('intake-photos/'||v_b||'/p2.jpg','intake_upload','image/jpeg') returning id into v_id; v_ph := v_ph || v_id;
  insert into public.photo_links (photo_id, entity_type, entity_id, role, caption) values (v_id, 'property_intake', v_b, 'grease_trap.photos', '[TEST] awaiting photo');

  insert into public.property_intake_accepts (intake_id, property_id, question_key, target_column, old_value, new_value, actor)
  values (v_a, v_p1, 'access_entry.gate', '[TEST] none', 'null'::jsonb, '"yes"'::jsonb, '[TEST] viewer verify');

  -- ---------------------------------------------------------- V2 the list view
  select * into v_row from client.v_intake_submissions where intake_id = v_a;
  if v_row.state is distinct from 'submitted' or v_row.status is distinct from 'Incomplete'
     or v_row.answered_count is distinct from 5 or v_row.requested_count is distinct from 6
     or v_row.photo_count is distinct from 3 or v_row.client_code is distinct from '112-YA'
     or v_row.has_gt_pin is not true or v_row.has_truck_pin is not false
     or v_row.accepted_count is distinct from 1 or v_row.last_accepted_at is null then
    raise exception 'VERIFY V2a: submitted row wrong: % % answered % of % photos % gt % truck % accepts %',
      v_row.state, v_row.status, v_row.answered_count, v_row.requested_count, v_row.photo_count,
      v_row.has_gt_pin, v_row.has_truck_pin, v_row.accepted_count;
  end if;
  select * into v_row from client.v_intake_submissions where intake_id = v_b;
  if v_row.state is distinct from 'awaiting' or v_row.status is not null or v_row.photo_count is not null
     or v_row.answered_count is not null or v_row.has_gt_pin is not null or v_row.has_truck_pin is not null then
    raise exception 'VERIFY V2b: an awaiting row must carry no collected data: % % % % % %',
      v_row.state, v_row.status, v_row.photo_count, v_row.answered_count, v_row.has_gt_pin, v_row.has_truck_pin;
  end if;
  select * into v_row from client.v_intake_submissions where intake_id = v_f;
  if v_row.status is distinct from 'Complete' or v_row.answered_count is distinct from 3 then
    raise exception 'VERIFY V2c: an all-answered intake (with a 0 and a false) is not Complete: % %', v_row.status, v_row.answered_count; end if;

  -- ---------------------------------------------------------- V3 what the list must NOT show
  select count(*) into v_n from client.v_intake_submissions where intake_id in (v_c, v_d, v_e);
  if v_n is distinct from 0 then
    raise exception 'VERIFY V3: % cancelled or expired intake(s) appear in the list', v_n; end if;

  -- ---------------------------------------------------------- V4 MIRROR, on both branches
  if (select intake_status from client.v_property_intake where property_id = v_p1)
     is distinct from (select status from client.v_intake_submissions where intake_id = v_a)
     or (select intake_id from client.v_property_intake where property_id = v_p1) is distinct from v_a then
    raise exception 'VERIFY V4a: v_property_intake and v_intake_submissions disagree on the Incomplete intake'; end if;
  if (select intake_status from client.v_property_intake where property_id = v_p2)
     is distinct from (select status from client.v_intake_submissions where intake_id = v_f)
     or (select intake_id from client.v_property_intake where property_id = v_p2) is distinct from v_f then
    raise exception 'VERIFY V4b: v_property_intake and v_intake_submissions disagree on the Complete intake'; end if;

  -- ---------------------------------------------------------- V5 get_intake's gate
  perform set_config('request.jwt.claims', '', true);
  v_raised := false;
  begin perform client.get_intake(v_a); exception when sqlstate '28000' then v_raised := true; end;
  if not v_raised then raise exception 'VERIFY V5a: get_intake did not refuse a missing JWT'; end if;
  perform set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-000000000001","email":"someone@gmail.com","role":"authenticated"}', true);
  v_raised := false;
  begin perform client.get_intake(v_a); exception when sqlstate '42501' then v_raised := true; end;
  if not v_raised then raise exception 'VERIFY V5b: get_intake did not refuse a non-staff email'; end if;

  perform set_config('request.jwt.claims',
    '{"sub":"00000000-0000-0000-0000-000000000002","email":"verify@ayache.com","role":"authenticated"}', true);

  -- ---------------------------------------------------------- V6 get_intake, submitted form A
  v_j := client.get_intake(v_a);
  if v_j->>'state' is distinct from 'submitted' or v_j->>'status' is distinct from 'Incomplete'
     or (v_j->>'requested_count')::int is distinct from 6
     or v_j#>>'{property,client_code}' is distinct from '112-YA' then
    raise exception 'VERIFY V6a: header fields wrong: % % % %', v_j->>'state', v_j->>'status', v_j->>'requested_count', v_j#>>'{property,client_code}'; end if;
  if jsonb_array_length(v_j->'sections') is distinct from 4 then
    raise exception 'VERIFY V6b: expected 4 sections (3 defined + 1 for the undefined key), got %', jsonb_array_length(v_j->'sections'); end if;
  -- snapshot order, not alphabetical: access_entry would sort first
  if v_j#>>'{sections,0,id}' is distinct from 'site_map' or v_j#>>'{sections,1,id}' is distinct from 'access_entry'
     or v_j#>>'{sections,2,id}' is distinct from 'grease_trap' or v_j#>>'{sections,3,id}' is distinct from '_not_in_form_definition' then
    raise exception 'VERIFY V6c: sections not in snapshot order: % % % %',
      v_j#>>'{sections,0,id}', v_j#>>'{sections,1,id}', v_j#>>'{sections,2,id}', v_j#>>'{sections,3,id}'; end if;
  -- only requested questions: site_map shows gt_location, NOT truck_parking
  if jsonb_array_length(v_j#>'{sections,0,questions}') is distinct from 1
     or jsonb_array_length(v_j#>'{sections,2,questions}') is distinct from 1 then
    raise exception 'VERIFY V6d: an unrequested question was rendered'; end if;
  if v_j#>>'{sections,1,questions,0,label}' is distinct from '[TEST] label from THIS snapshot' then
    raise exception 'VERIFY V6e: label did not come from the intake''s own snapshot'; end if;
  if v_j#>>'{sections,1,questions,2,key}' is distinct from 'access_entry.alarm'
     or v_j#>>'{sections,1,questions,2,answered}' is distinct from 'false' then
    raise exception 'VERIFY V6f: legacy string question lost, or its unanswered state wrong'; end if;
  if v_j#>>'{sections,1,questions,1,value}' is distinct from '1234' then
    raise exception 'VERIFY V6g: answer value not returned'; end if;
  if jsonb_array_length(v_j#>'{sections,2,questions,0,photos}') is distinct from 1
     or v_j#>>'{sections,2,questions,0,photos,0,path}' is distinct from v_a||'/p1.jpg'
     or v_j#>>'{sections,2,questions,0,photos,0,bucket}' is distinct from 'intake-photos' then
    raise exception 'VERIFY V6h: photo path or bucket wrong: %', v_j#>'{sections,2,questions,0,photos}'; end if;
  -- the requested-but-undefined key is rendered, answered, with its photo
  if v_j#>>'{sections,3,questions,0,key}' is distinct from 'orphan.requested_key'
     or v_j#>>'{sections,3,questions,0,answered}' is distinct from 'true'
     or jsonb_array_length(v_j#>'{sections,3,questions,0,photos}') is distinct from 1 then
    raise exception 'VERIFY V6i: a requested key the snapshot does not define was dropped'; end if;
  -- unrequested answers surfaced, INCLUDING one on a defined key, despite a keyless snapshot item
  select count(*) into v_n from jsonb_array_elements(v_j->'unlisted_answers') x
   where x->>'key' in ('grease_trap.systems_count', 'zzz.not_in_form');
  if v_n is distinct from 2 or jsonb_array_length(v_j->'unlisted_answers') is distinct from 2 then
    raise exception 'VERIFY V6j: unlisted_answers wrong: %', v_j->'unlisted_answers'; end if;
  if jsonb_array_length(v_j->'unlisted_photos') is distinct from 1
     or v_j#>>'{unlisted_photos,0,role}' is distinct from 'zzz.orphan_role' then
    raise exception 'VERIFY V6k: unlisted_photos wrong: %', v_j->'unlisted_photos'; end if;
  if jsonb_array_length(v_j->'accepted') is distinct from 1 then
    raise exception 'VERIFY V6l: the accept row is missing'; end if;

  -- ---------------------------------------------------------- V7 awaiting, cancelled, expired
  v_jb := client.get_intake(v_b);
  if v_jb->>'state' is distinct from 'awaiting' or v_jb->>'status' is not null then
    raise exception 'VERIFY V7a: awaiting state/status wrong'; end if;
  if jsonb_array_length(v_jb->'sections') is distinct from 1 then
    raise exception 'VERIFY V7b: sections with no requested question were not omitted'; end if;
  if v_jb::text like '%/p2.jpg%' then
    raise exception 'VERIFY V7c: an awaiting intake returned its photo'; end if;
  if (client.get_intake(v_c))->>'state' is distinct from 'cancelled'
     or (client.get_intake(v_d))->>'state' is distinct from 'expired'
     or (client.get_intake(v_e))->>'state' is distinct from 'cancelled' then
    raise exception 'VERIFY V7d: cancelled / expired states wrong'; end if;
  if (client.get_intake(v_f))->>'status' is distinct from 'Complete' then
    raise exception 'VERIFY V7e: get_intake does not report the all-answered intake as Complete'; end if;

  -- ---------------------------------------------------------- V8 no token anywhere
  if v_j::text like '%'||v_tok_a||'%' or v_j::text like '%'||v_tok_b||'%'
     or v_jb::text like '%'||v_tok_a||'%' or v_jb::text like '%'||v_tok_b||'%'
     or (client.get_intake(v_f))::text like '%'||v_tok_f||'%' then
    raise exception 'VERIFY V8a: a token appears in a get_intake payload'; end if;
  select count(*) into v_n from public.photos where id = any (v_ph)
     and (storage_path like '%'||v_tok_a||'%' or storage_path like '%'||v_tok_b||'%');
  if v_n is distinct from 0 then raise exception 'VERIFY V8b: a token appears in a storage path'; end if;

  -- ---------------------------------------------------------- V9 read-only: the raw record
  v_raised := false;
  begin
    update public.property_intakes set answers = '{}'::jsonb where id = v_a;
  exception when sqlstate '22023' then
    v_raised := sqlerrm like '%raw intake submission is immutable%';
  end;
  if not v_raised then raise exception 'VERIFY V9: a submitted intake''s answers were not refused by the immutability trigger'; end if;

  -- ---------------------------------------------------------- cleanup, then prove it
  perform set_config('request.jwt.claims', '', true);
  delete from public.property_intake_accepts where intake_id in (v_a, v_b, v_c, v_d, v_e, v_f);
  delete from public.photo_links where photo_id = any (v_ph);
  delete from public.photos where id = any (v_ph);
  delete from public.property_intakes where id in (v_a, v_b, v_c, v_d, v_e, v_f);
  if (select count(*) from public.property_intakes) is distinct from 0::bigint
     or (select count(*) from public.property_intake_accepts) is distinct from 0::bigint
     or (select count(*) from public.photo_links where entity_type = 'property_intake') is distinct from 0::bigint then
    raise exception 'VERIFY: fixtures left behind'; end if;

  raise notice 'VERIFY: intake viewer read surface, all assertions passed';
end $verify$;

notify pgrst, 'reload schema';
