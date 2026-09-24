-- =============================================================================
-- 2026-09-23_1949_intake_applicability_and_token_redaction.sql
-- Fix-forward of 2026-09-23_1855, from the SECOND adversarial review round
-- (14 agents, 11 findings confirmed, 0 refuted).
--
-- 🛑 1. STATUS COUNTED A CORRECTLY HIDDEN QUESTION AS MISSING. Live since 2026-09-22.
--    The form shows a follow-up only when its parent matches (show_if, e.g.
--    "access_entry.gate=yes"). Status was "every REQUESTED key answered", so:
--      - request "Is there a closed gate?" plus "What is the gate code?", answer No:
--        the gate-code question is never shown, never answered, and the form read
--        Incomplete FOREVER although it was filled in correctly;
--      - request both branches of a choice (lock-box code AND key instructions): one is
--        always hidden, so Complete was impossible.
--    The Client App's Schedule intake dialog pre-checks follow-ups and checks a parent
--    with its child, so most real intakes would have hit this, and it feeds the Clients
--    list Intake status column.
--    ⇒ ONE RULE, DEFINED ONCE: a requested key is APPLICABLE when every show_if in its
--      chain is satisfied by the submitted answers (public.fn_intake_applicable), and the
--      form is Complete iff no applicable requested key is unanswered
--      (public.fn_intake_missing). client.v_property_intake, client.v_intake_submissions,
--      client.get_intake and the edge function intake-submit (v8, via rpc) all call it.
--      Before this, the edge function carried its own TypeScript copy of the rule.
--    Requested keys are normalised in the same place: NULL, blank and duplicate elements
--    are ignored, so the list, the detail and the status can never count different sets.
--    ⚠ The comparison is the answered value as text against the text after '=' in show_if,
--      exactly as the form's visible() does it. A cycle in an authored tree is treated as
--      applicable (visible, so it stays Incomplete until someone looks), capped at 10.
--
-- 🛑 2. THE TOKEN WAS STILL COPIED INTO audit.logs. My 1855 header said the token appears
--    nowhere a staff session can read. False at the grant layer: audit.log_change writes the
--    whole row into audit.logs.new_row/old_row, and authenticated holds SELECT on audit.logs
--    behind an RLS policy of `true`. Not reachable today (audit is not a PostgREST schema and
--    no history RPC covers intakes), but one config change or one RPC edit away. The estate's
--    own mechanism for exactly this is audit.redacted_columns, which already holds the webhook
--    OAuth secrets. property_intakes.token is added to it.
--    ⚠ The EXISTING audit rows still carry tokens. Every one belongs to an intake that has been
--      deleted (property_intakes held 0 rows when this was written), so each token is dead.
--      Scrubbing them would be an audit-trail rewrite, which needs Fred's explicit OK and buys
--      nothing here, so it is deliberately NOT done.
--    ⇒ Same lesson as the storage_path defect, learned twice in one evening: a secret is as
--      exposed as the least-protected column that copies it, and "who can read the table I
--      put it in" is the wrong question. Ask "where else does it get copied".
--
-- 3. BLANK MEANT DIFFERENT THINGS IN SQL AND JS. fn_intake_answered trimmed spaces only, the
--    form and the edge function trim all whitespace, so a newline-only answer was Complete in
--    one and Incomplete in the other. The SQL now trims whitespace and NBSP. Same signature,
--    still IMMUTABLE; get_intake_compare and accept_intake_answers pick it up unchanged.
--
-- The photo-cap and phantom-attach findings are fixed in intake-submit v8, not here.
--
-- RULE 8, AUDIT: two functions, three replaced objects, one redaction row. Nothing to opt in.
-- ATOMIC: no COMMIT, so a failed assertion rolls the whole migration back.
-- =============================================================================


-- ============================================================ 1. the token out of audit
insert into audit.redacted_columns (table_name, column_name, reason)
select 'property_intakes', 'token',
       'intake collector bearer token; holding it lets anyone submit that form, and the raw submission is immutable'
 where not exists (select 1 from audit.redacted_columns where table_name = 'property_intakes' and column_name = 'token');


-- ============================================================ 2. blank = whitespace, one definition
create or replace function public.fn_intake_answered(p_answers jsonb, p_key text)
 returns boolean
 language sql
 immutable
 set search_path to ''
as $function$
  select coalesce(
    p_answers is not null
    and p_answers -> p_key ? 'value'
    and jsonb_typeof(p_answers -> p_key -> 'value') <> 'null'
    and case jsonb_typeof(p_answers -> p_key -> 'value')
          when 'string' then btrim(p_answers -> p_key ->> 'value', E' \t\n\r\f\v' || chr(160)) <> ''
          when 'object' then (p_answers -> p_key -> 'value') <> '{}'::jsonb
          when 'array'  then (p_answers -> p_key -> 'value') <> '[]'::jsonb
          else true                       -- a number or a boolean is an answer, incl. 0 and false
        end,
  false);
$function$;


-- ============================================================ 3. applicability, defined once
create or replace function public.fn_intake_applicable(p_snapshot jsonb, p_answers jsonb, p_key text)
returns boolean
language plpgsql
immutable
set search_path to ''
as $$
declare
  v_key    text := p_key;
  v_show   text;
  v_parent text;
  v_want   text;
  v_depth  int := 0;
begin
  loop
    v_show := null;
    select q ->> 'show_if' into v_show
      from jsonb_array_elements(coalesce(p_snapshot -> 'sections', '[]'::jsonb)) s,
           jsonb_array_elements(coalesce(s -> 'questions', '[]'::jsonb)) q
     where jsonb_typeof(q) = 'object' and q ->> 'key' = v_key
     limit 1;
    if v_show is null or btrim(v_show) = '' or position('=' in v_show) = 0 then
      return true;                                   -- no condition: always asked
    end if;
    v_parent := substr(v_show, 1, position('=' in v_show) - 1);
    v_want   := substr(v_show, position('=' in v_show) + 1);
    if coalesce(p_answers -> v_parent ->> 'value', '') is distinct from v_want then
      return false;                                  -- the form hid it
    end if;
    v_depth := v_depth + 1;
    if v_depth >= 10 then
      return true;                                   -- a cycle in an authored tree: stay visible
    end if;
    v_key := v_parent;                               -- the parent must itself have been shown
  end loop;
end $$;

comment on function public.fn_intake_applicable(jsonb, jsonb, text) is
  'TRUE when the intake question p_key was actually shown to the collector: every show_if in its '
  'chain is satisfied by p_answers (answered value as text = the text after "="), exactly as the '
  'form''s visible() decides. A key the snapshot does not define has no condition and is applicable.';

create or replace function public.fn_intake_missing(p_snapshot jsonb, p_requested jsonb, p_answers jsonb)
returns text[]
language sql
immutable
set search_path to ''
as $$
  select coalesce(array_agg(r.k order by r.k), '{}'::text[])
    from (select distinct x as k
            from jsonb_array_elements_text(
                   case when jsonb_typeof(p_requested) = 'array' then p_requested else '[]'::jsonb end) x
           where x is not null and btrim(x) <> '') r
   where public.fn_intake_applicable(p_snapshot, p_answers, r.k)
     and not public.fn_intake_answered(p_answers, r.k);
$$;

comment on function public.fn_intake_missing(jsonb, jsonb, jsonb) is
  'THE completeness rule for an intake: the requested keys (NULL, blank and duplicates ignored) that '
  'were shown to the collector and are unanswered. Empty = Complete. Called by client.v_property_intake, '
  'client.v_intake_submissions, client.get_intake and intake-submit; do not re-implement it.';

revoke all on function public.fn_intake_applicable(jsonb, jsonb, text) from public, anon;
revoke all on function public.fn_intake_missing(jsonb, jsonb, jsonb)   from public, anon;
-- the views are owner-rights but these are INVOKER functions, so every READER needs EXECUTE
grant execute on function public.fn_intake_applicable(jsonb, jsonb, text) to authenticated, service_role, pg_read_all_data;
grant execute on function public.fn_intake_missing(jsonb, jsonb, jsonb)   to authenticated, service_role, pg_read_all_data;


-- ============================================================ 4. v_property_intake on the rule
-- Copied from pg_get_viewdef (2026-09-23), schema-qualified; ONLY intake_status and
-- missing_keys change. Columns, names, types and order are identical, which is what lets
-- CREATE OR REPLACE keep client.clients (which depends on it) and the grants.
create or replace view client.v_property_intake as
 SELECT p.id AS property_id,
    p.client_id,
    i.id AS intake_id,
    i.submitted_at,
    i.collector,
        CASE
            WHEN i.id IS NULL THEN 'Nothing'::text
            WHEN cardinality(public.fn_intake_missing(i.form_snapshot, i.requested, i.answers)) = 0 THEN 'Complete'::text
            ELSE 'Incomplete'::text
        END AS intake_status,
    (EXISTS ( SELECT 1
           FROM public.property_intakes s
          WHERE s.property_id = p.id AND s.submitted_at IS NULL AND s.cancelled_at IS NULL AND s.expires_at > now())) AS intake_scheduled,
    COALESCE(public.fn_intake_missing(i.form_snapshot, i.requested, i.answers), '{}'::text[]) AS missing_keys
   FROM public.properties p
     LEFT JOIN LATERAL ( SELECT x.id,
            x.property_id,
            x.form_snapshot,
            x.requested,
            x.token,
            x.expires_at,
            x.requested_by,
            x.requested_at,
            x.collector,
            x.answers,
            x.submitted_at,
            x.accepted,
            x.cancelled_at,
            x.created_at,
            x.updated_at
           FROM public.property_intakes x
          WHERE x.property_id = p.id AND x.cancelled_at IS NULL AND x.submitted_at IS NOT NULL
          ORDER BY x.submitted_at DESC
         LIMIT 1) i ON true
  WHERE p.deleted_at IS NULL AND COALESCE(p.is_billing, false) = false;


-- ============================================================ 5. the list on the rule
-- Same column order as 1855; applicable_count is APPENDED (a replace may only append).
-- requested_count now counts DISTINCT non-blank keys, so it can never disagree with the
-- set the status is computed over; answered_count counts answered APPLICABLE keys.
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
  pr.n_req                                                as requested_count,
  case when i.submitted_at is null then null
       else pr.n_app - cardinality(public.fn_intake_missing(i.form_snapshot, i.requested, i.answers)) end as answered_count,
  case when i.submitted_at is null then null
       when cardinality(public.fn_intake_missing(i.form_snapshot, i.requested, i.answers)) = 0 then 'Complete'
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
     from public.property_intake_accepts a where a.intake_id = i.id)        as last_accepted_at,
  case when i.submitted_at is null then null else pr.n_app end              as applicable_count
from public.property_intakes i
join public.properties p on p.id = i.property_id
left join public.clients c on c.id = p.client_id
cross join lateral (
  select count(*)::integer as n_req,
         (count(*) filter (where public.fn_intake_applicable(i.form_snapshot, i.answers, r.k)))::integer as n_app
    from (select distinct x as k
            from jsonb_array_elements_text(i.requested) x
           where x is not null and btrim(x) <> '') r
) pr
where i.cancelled_at is null
  and (i.submitted_at is not null or i.expires_at > now());

comment on view client.v_intake_submissions is
  'One row per intake the Picture Planner /forms list shows: every submitted intake, and every '
  'awaiting one whose link is still live (state = awaiting). Cancelled and expired-unused intakes '
  'are excluded. Carries no answer VALUES: those come only from client.get_intake, which re-checks '
  'the staff domain. requested_count = distinct requested keys; applicable_count = those the '
  'collector was actually shown (a follow-up hidden by its parent''s answer is not applicable); '
  'answered_count = answered applicable keys; status from public.fn_intake_missing. Collected-data '
  'columns are NULL for an awaiting intake.';

revoke all on client.v_intake_submissions from public, anon, authenticated;
grant select on client.v_intake_submissions to authenticated;


-- ============================================================ 6. the detail on the rule
-- Copied from 1855; changes: v_req is DISTINCT, each question carries `applicable`, status
-- comes from fn_intake_missing, and requested_count / applicable_count are returned.
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
  v_missing      text[];
  v_applicable   int;
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

  -- The same normalisation fn_intake_missing uses: distinct, no NULL, no blank. A NULL inside
  -- `x = ANY(arr)` would make every non-member test NULL and empty the unlisted lists.
  select coalesce(array_agg(distinct x) filter (where x is not null and btrim(x) <> ''), '{}') into v_req
    from jsonb_array_elements_text(v_i.requested) x;

  select coalesce(array_agg(k) filter (where k is not null and k <> ''), '{}') into v_known
    from jsonb_array_elements(coalesce(v_i.form_snapshot -> 'sections', '[]'::jsonb)) s,
         jsonb_array_elements(coalesce(s -> 'questions', '[]'::jsonb)) q,
         lateral (select case when jsonb_typeof(q) = 'string' then q #>> '{}' else q ->> 'key' end) kk(k);

  select coalesce(array_agg(r order by r), '{}') into v_orphans
    from unnest(v_req) r
   where not (r = any (v_known));

  -- Photos only for a submitted intake: the product rule. The folder is the intake id since
  -- intake-submit v7, never the token, so `path` carries no secret.
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

  select coalesce(jsonb_agg(z.sec order by z.s_ord), '[]'::jsonb) into v_sections
    from (select s.ord as s_ord,
                 jsonb_build_object(
                   'id',    s.section ->> 'id',
                   'title', coalesce(s.section ->> 'title', s.section ->> 'id'),
                   'questions', jsonb_agg(jsonb_build_object(
                       'key',        q.k,
                       'label',      q.label,
                       'type',       q.typ,
                       'options',    q.opts,
                       'show_if',    q.show_if,
                       'applicable', case when v_submitted then public.fn_intake_applicable(v_i.form_snapshot, v_i.answers, q.k) end,
                       'answered',   v_submitted and public.fn_intake_answered(v_i.answers, q.k),
                       'value',      case when v_submitted then v_i.answers -> q.k -> 'value' end,
                       'photos',     coalesce(v_photos -> q.k, '[]'::jsonb)) order by q.ord)) as sec
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

  if cardinality(v_orphans) > 0 then
    v_sections := v_sections || jsonb_build_array(jsonb_build_object(
      'id',    '_not_in_form_definition',
      'title', 'Asked, but not in this form''s definition',
      'questions', (select jsonb_agg(jsonb_build_object(
                        'key',        o,
                        'label',      o,
                        'type',       null,
                        'options',    null,
                        'show_if',    null,
                        'applicable', case when v_submitted then true end,
                        'answered',   v_submitted and public.fn_intake_answered(v_i.answers, o),
                        'value',      case when v_submitted then v_i.answers -> o -> 'value' end,
                        'photos',     coalesce(v_photos -> o, '[]'::jsonb)) order by o)
                      from unnest(v_orphans) o)));
  end if;

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

  -- THE rule, called, not copied.
  v_missing := public.fn_intake_missing(v_i.form_snapshot, v_i.requested, v_i.answers);
  select count(*) into v_applicable from unnest(v_req) k
   where public.fn_intake_applicable(v_i.form_snapshot, v_i.answers, k);
  v_status := case when not v_submitted then null
                   when cardinality(v_missing) = 0 then 'Complete'
                   else 'Incomplete' end;

  return jsonb_build_object(
    'intake_id',        v_i.id,
    'state',            v_state,
    'status',           v_status,
    'missing',          case when v_submitted then to_jsonb(v_missing) end,
    'property',         v_prop,
    'requested_by',     v_i.requested_by,
    'requested_at',     v_i.requested_at,
    'expires_at',       v_i.expires_at,
    'collector',        v_i.collector,
    'submitted_at',     v_i.submitted_at,
    'requested_count',  cardinality(v_req),
    'applicable_count', case when v_submitted then v_applicable end,
    'sections',         v_sections,
    'unlisted_answers', v_other,
    'unlisted_photos',  v_other_photos,
    'accepted',         v_accepted);
end $$;

comment on function client.get_intake(bigint) is
  'One intake, read-only, for the Picture Planner /forms/$id view. Questions come from the intake''s own '
  'frozen form_snapshot, requested questions only, in snapshot order, each flagged applicable (was it '
  'shown, given its parent''s answer) and answered. status and missing come from public.fn_intake_missing. '
  'A requested key the snapshot does not define is rendered in a final section. Photos only for a '
  'SUBMITTED intake. Staff-gated (28000 / 42501).';

revoke all on function client.get_intake(bigint) from public, anon;
grant execute on function client.get_intake(bigint) to authenticated;


-- ============================================================ VERIFY
do $verify$
declare
  v_p1 bigint;  v_p2 bigint;
  v_a bigint; v_tok_a text;  v_b bigint; v_tok_b text;
  v_c bigint; v_d bigint; v_e bigint; v_g bigint;
  v_f bigint; v_tok_f text;  v_h bigint; v_j bigint;
  v_ids bigint[];
  v_ph  bigint[] := '{}';
  v_id  bigint;
  v_row record;
  v_j1  jsonb; v_jb jsonb; v_jf jsonb;
  v_raised boolean;
  v_n   int;
  -- NON-alphabetical section order, a legacy string question, a keyless item, and the two
  -- show_if shapes that broke status: a yes/no follow-up and both branches of a choice.
  v_snap jsonb := jsonb_build_object('sections', jsonb_build_array(
    jsonb_build_object('id','site_map','title','Site map','questions', jsonb_build_array(
      jsonb_build_object('key','site_map.gt_location','label','Grease trap location','type','gps_pin'),
      jsonb_build_object('key','site_map.truck_parking','label','Truck parking','type','gps_pin'))),
    jsonb_build_object('id','access_entry','title','Access & entry','questions', jsonb_build_array(
      jsonb_build_object('key','access_entry.gate','label','[TEST] label from THIS snapshot','type','yes_no'),
      jsonb_build_object('key','access_entry.gate_code','label','Gate code','type','text','show_if','access_entry.gate=yes'),
      jsonb_build_object('key','access_entry.how_access','label','How do we get in?','type','choice'),
      jsonb_build_object('key','access_entry.lock_box_code','label','Lock box code','type','text','show_if','access_entry.how_access=Lock box'),
      jsonb_build_object('key','access_entry.key_instruction','label','Key instructions','type','text','show_if','access_entry.how_access=Key'),
      to_jsonb('access_entry.alarm'::text))),
    jsonb_build_object('id','grease_trap','title','Grease trap','questions', jsonb_build_array(
      jsonb_build_object('key','grease_trap.photos','label','Photos','type','photos'),
      jsonb_build_object('key','grease_trap.systems_count','label','Systems','type','number'),
      jsonb_build_object('label','a snapshot item with no key','type','text')))));
begin
  -- ============================================ V0 the premises
  select count(*) into v_n from auth.users
   where lower(coalesce(email,'')) not like '%@ayache.com' and lower(coalesce(email,'')) not like '%@unclogme.com';
  if v_n is distinct from 0 then raise exception 'VERIFY V0a: % non-staff auth users exist; "authenticated = staff" is false', v_n; end if;
  if not exists (select 1 from audit.redacted_columns where table_name = 'property_intakes' and column_name = 'token') then
    raise exception 'VERIFY V0b: property_intakes.token is not redacted from audit.logs'; end if;

  -- ============================================ V1 privileges, policy, object kinds
  if has_table_privilege('anon','client.v_intake_submissions','SELECT') then raise exception 'VERIFY V1a: anon reads the list'; end if;
  if not has_table_privilege('authenticated','client.v_intake_submissions','SELECT') then raise exception 'VERIFY V1b'; end if;
  if has_table_privilege('authenticated','client.v_intake_submissions','INSERT,UPDATE,DELETE,TRUNCATE') then raise exception 'VERIFY V1c: a write privilege on the list'; end if;
  if not has_table_privilege('authenticated','client.v_property_intake','SELECT') then raise exception 'VERIFY V1d: the replace lost v_property_intake''s grant'; end if;
  if has_function_privilege('anon','client.get_intake(bigint)','EXECUTE') then raise exception 'VERIFY V1e: anon executes get_intake'; end if;
  if has_function_privilege('anon','public.fn_intake_missing(jsonb,jsonb,jsonb)','EXECUTE')
     or has_function_privilege('anon','public.fn_intake_applicable(jsonb,jsonb,text)','EXECUTE') then
    raise exception 'VERIFY V1f: anon executes a rule function'; end if;
  if not (has_function_privilege('authenticated','public.fn_intake_missing(jsonb,jsonb,jsonb)','EXECUTE')
      and has_function_privilege('authenticated','public.fn_intake_applicable(jsonb,jsonb,text)','EXECUTE')
      and has_function_privilege('authenticated','public.fn_intake_answered(jsonb,text)','EXECUTE')
      and has_function_privilege('pg_read_all_data','public.fn_intake_missing(jsonb,jsonb,jsonb)','EXECUTE')
      and has_function_privilege('pg_read_all_data','public.fn_intake_applicable(jsonb,jsonb,text)','EXECUTE')
      and has_function_privilege('pg_read_all_data','public.fn_intake_answered(jsonb,text)','EXECUTE')
      and has_function_privilege('service_role','public.fn_intake_missing(jsonb,jsonb,jsonb)','EXECUTE')) then
    raise exception 'VERIFY V1g: a reader of the views, or the edge function, cannot execute the rule'; end if;
  -- the storage policy, whole expression, not a substring
  select count(*) into v_n from pg_policy pol
   where pol.polrelid = 'storage.objects'::regclass
     and coalesce(pg_get_expr(pol.polqual, pol.polrelid), '') || ' ' || coalesce(pg_get_expr(pol.polwithcheck, pol.polrelid), '') like '%intake-photos%';
  if v_n is distinct from 1 then raise exception 'VERIFY V1h: % policies mention intake-photos, expected 1', v_n; end if;
  if not exists (select 1 from pg_policy pol
                  where pol.polrelid = 'storage.objects'::regclass and pol.polname = 'intake_photos_staff_read'
                    and pol.polcmd = 'r' and pol.polpermissive and pol.polwithcheck is null
                    and pol.polroles = array['authenticated'::regrole]::oid[]
                    and pg_get_expr(pol.polqual, pol.polrelid) = '((bucket_id = ''intake-photos''::text) AND (auth.uid() IS NOT NULL))') then
    raise exception 'VERIFY V1i: intake_photos_staff_read is not exactly the plain staff read'; end if;
  if (select public from storage.buckets where id = 'intake-photos') is not false then raise exception 'VERIFY V1j: bucket not private'; end if;
  -- owner-rights view and SECURITY DEFINER function, or staff reads break behind a green VERIFY
  if (select reloptions from pg_class where oid = 'client.v_intake_submissions'::regclass) is not null then
    raise exception 'VERIFY V1k: v_intake_submissions carries reloptions (security_invoker?)'; end if;
  if not (select prosecdef from pg_proc where oid = 'client.get_intake(bigint)'::regprocedure) then
    raise exception 'VERIFY V1l: get_intake is not SECURITY DEFINER'; end if;

  -- ============================================ V2 the rule, as pure functions
  -- yes/no follow-up hidden by "no"
  if public.fn_intake_missing(v_snap, '["access_entry.gate","access_entry.gate_code"]',
        '{"access_entry.gate":{"value":"no"}}') is distinct from '{}'::text[] then
    raise exception 'VERIFY V2a: a follow-up hidden by its parent''s "no" is counted as missing'; end if;
  -- the same follow-up, SHOWN by "yes" and left blank, is missing
  if public.fn_intake_missing(v_snap, '["access_entry.gate","access_entry.gate_code"]',
        '{"access_entry.gate":{"value":"yes"}}') is distinct from array['access_entry.gate_code'] then
    raise exception 'VERIFY V2b: a shown and unanswered follow-up is not missing'; end if;
  -- both branches of a choice requested: only the taken branch counts
  if public.fn_intake_missing(v_snap, '["access_entry.how_access","access_entry.lock_box_code","access_entry.key_instruction"]',
        '{"access_entry.how_access":{"value":"Lock box"},"access_entry.lock_box_code":{"value":"1234"}}') is distinct from '{}'::text[] then
    raise exception 'VERIFY V2c: the branch not taken blocks Complete'; end if;
  -- NULL, blank and duplicate requested elements ignored
  if public.fn_intake_missing(v_snap, '[null,"", "  ","access_entry.alarm","access_entry.alarm"]', '{}')
     is distinct from array['access_entry.alarm'] then
    raise exception 'VERIFY V2d: requested normalisation wrong'; end if;
  -- blank is whitespace, including a newline, a tab and a no-break space
  if public.fn_intake_answered(jsonb_build_object('k', jsonb_build_object('value', E'\n\t ' || chr(160))), 'k') is not false then
    raise exception 'VERIFY V2e: a whitespace-only answer counts as answered'; end if;
  if public.fn_intake_answered('{"k":{"value":0}}', 'k') is not true
     or public.fn_intake_answered('{"k":{"value":false}}', 'k') is not true
     or public.fn_intake_answered('{"k":{"value":"x"}}', 'k') is not true then
    raise exception 'VERIFY V2f: 0 / false / text must still count as answers'; end if;
  -- an undefined requested key has no condition: applicable, and missing when blank
  if public.fn_intake_missing(v_snap, '["access_entry.gate","orphan2.undefined"]', '{"access_entry.gate":{"value":"yes"}}')
     is distinct from array['orphan2.undefined'] then
    raise exception 'VERIFY V2g: an undefined requested key is not treated as asked'; end if;

  -- ============================================ fixtures, tagged [TEST]
  select min(p.id), max(p.id) into v_p1, v_p2 from public.properties p
   where p.client_id = (select id from public.clients where client_code = '112-YA')
     and p.deleted_at is null and coalesce(p.is_billing,false) = false;
  if v_p1 is null or v_p1 = v_p2 then raise exception 'VERIFY: need two live service properties on 112-YA'; end if;

  -- A (p1): submitted now. requested out of snapshot order, with a null and a duplicate.
  -- Distinct requested = 6, all applicable (gate = yes shows gate_code); alarm unanswered.
  insert into public.property_intakes (property_id, form_snapshot, requested, collector, answers, submitted_at)
  values (v_p1, v_snap,
          '["grease_trap.photos",null,"access_entry.alarm","site_map.gt_location","access_entry.gate","access_entry.gate_code","orphan.requested_key","access_entry.gate"]'::jsonb,
          '[TEST] viewer verify 2',
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
  insert into public.property_intakes (property_id, form_snapshot, requested, requested_by)
  values (v_p1, v_snap, '["access_entry.gate"]'::jsonb, '[TEST] viewer verify 2') returning id, token into v_b, v_tok_b;
  insert into public.property_intakes (property_id, form_snapshot, requested, requested_by, cancelled_at)
  values (v_p1, v_snap, '["access_entry.gate"]'::jsonb, '[TEST] viewer verify 2', now()) returning id into v_c;
  insert into public.property_intakes (property_id, form_snapshot, requested, requested_by, expires_at)
  values (v_p1, v_snap, '["access_entry.gate"]'::jsonb, '[TEST] viewer verify 2', now() - interval '1 day') returning id into v_d;
  insert into public.property_intakes (property_id, form_snapshot, requested, collector, answers, submitted_at, cancelled_at)
  values (v_p1, v_snap, '["access_entry.gate"]'::jsonb, '[TEST] viewer verify 2',
          '{"access_entry.gate":{"value":"no"}}'::jsonb, now() - interval '1 hour', now()) returning id into v_e;
  -- G (p1): submitted two days ago, link since expired, NOT cancelled: a record, so it shows
  insert into public.property_intakes (property_id, form_snapshot, requested, collector, answers, submitted_at, expires_at)
  values (v_p1, v_snap, '["access_entry.gate"]'::jsonb, '[TEST] viewer verify 2',
          '{"access_entry.gate":{"value":"yes"}}'::jsonb, now() - interval '2 days', now() - interval '1 day') returning id into v_g;
  -- F (p2, latest there): the HIGH finding. gate = no hides gate_code; how_access = Lock box hides
  -- key_instruction. Under the old rule this read Incomplete forever. 6 requested, 4 applicable.
  insert into public.property_intakes (property_id, form_snapshot, requested, collector, answers, submitted_at)
  values (v_p2, v_snap,
          '["access_entry.gate","access_entry.gate_code","access_entry.how_access","access_entry.lock_box_code","access_entry.key_instruction","grease_trap.systems_count"]'::jsonb,
          '[TEST] viewer verify 2',
          jsonb_build_object('access_entry.gate',          jsonb_build_object('value','no'),
                             'access_entry.how_access',    jsonb_build_object('value','Lock box'),
                             'access_entry.lock_box_code', jsonb_build_object('value','1234'),
                             'grease_trap.systems_count',  jsonb_build_object('value', 0)),
          now() - interval '1 minute')
  returning id, token into v_f, v_tok_f;
  -- H (p2, older): the only unanswered key is one the snapshot does not define
  insert into public.property_intakes (property_id, form_snapshot, requested, collector, answers, submitted_at)
  values (v_p2, v_snap, '["access_entry.gate","orphan2.undefined"]'::jsonb, '[TEST] viewer verify 2',
          '{"access_entry.gate":{"value":"yes"}}'::jsonb, now() - interval '2 minutes') returning id into v_h;
  -- J (p2, oldest): a whitespace-only answer
  insert into public.property_intakes (property_id, form_snapshot, requested, collector, answers, submitted_at)
  values (v_p2, v_snap, '["access_entry.alarm"]'::jsonb, '[TEST] viewer verify 2',
          jsonb_build_object('access_entry.alarm', jsonb_build_object('value', E'\n\t ' || chr(160))), now() - interval '3 minutes') returning id into v_j;
  v_ids := array[v_a, v_b, v_c, v_d, v_e, v_g, v_f, v_h, v_j];

  insert into public.photos (storage_path, source, content_type) values ('intake-photos/'||v_a||'/p1.jpg','intake_upload','image/jpeg') returning id into v_id; v_ph := v_ph || v_id;
  insert into public.photo_links (photo_id, entity_type, entity_id, role, caption) values (v_id, 'property_intake', v_a, 'grease_trap.photos', '[TEST] caption A');
  insert into public.photos (storage_path, source, content_type) values ('intake-photos/'||v_a||'/p8.jpg','intake_upload','image/jpeg') returning id into v_id; v_ph := v_ph || v_id;
  insert into public.photo_links (photo_id, entity_type, entity_id, role, caption) values (v_id, 'property_intake', v_a, 'orphan.requested_key', '[TEST] orphan-key photo');
  insert into public.photos (storage_path, source, content_type) values ('intake-photos/'||v_a||'/p9.jpg','intake_upload','image/jpeg') returning id into v_id; v_ph := v_ph || v_id;
  insert into public.photo_links (photo_id, entity_type, entity_id, role, caption) values (v_id, 'property_intake', v_a, 'zzz.orphan_role', '[TEST] unrequested-role photo');
  -- a SOFT-DELETED link on A: must be neither counted nor returned
  insert into public.photos (storage_path, source, content_type) values ('intake-photos/'||v_a||'/p7.jpg','intake_upload','image/jpeg') returning id into v_id; v_ph := v_ph || v_id;
  insert into public.photo_links (photo_id, entity_type, entity_id, role, caption, deleted_at) values (v_id, 'property_intake', v_a, 'grease_trap.photos', '[TEST] soft-deleted', now());
  insert into public.photos (storage_path, source, content_type) values ('intake-photos/'||v_b||'/p2.jpg','intake_upload','image/jpeg') returning id into v_id; v_ph := v_ph || v_id;
  insert into public.photo_links (photo_id, entity_type, entity_id, role, caption) values (v_id, 'property_intake', v_b, 'grease_trap.photos', '[TEST] awaiting photo');
  insert into public.property_intake_accepts (intake_id, property_id, question_key, target_column, old_value, new_value, actor)
  values (v_a, v_p1, 'access_entry.gate', '[TEST] none', 'null'::jsonb, '"yes"'::jsonb, '[TEST] viewer verify 2');

  -- ============================================ V3 the token did not reach audit.logs (a REAL control:
  -- before the redaction row above, every one of these rows carried it)
  select count(*) into v_n from audit.logs
   where table_name = 'property_intakes'
     and coalesce(new_row ->> 'id', old_row ->> 'id')::bigint = any (v_ids);
  if v_n < 9 then raise exception 'VERIFY V3a: expected audit rows for the 9 fixtures, found % (the check would be vacuous)', v_n; end if;
  select count(*) into v_n from audit.logs
   where table_name = 'property_intakes'
     and coalesce(new_row ->> 'id', old_row ->> 'id')::bigint = any (v_ids)
     and (coalesce(new_row, '{}') ? 'token' or coalesce(old_row, '{}') ? 'token');
  if v_n is distinct from 0 then raise exception 'VERIFY V3b: % audit rows still carry the token', v_n; end if;

  -- ============================================ V4 the list view (read as postgres)
  select * into v_row from client.v_intake_submissions where intake_id = v_a;
  if v_row.state is distinct from 'submitted' or v_row.status is distinct from 'Incomplete'
     or v_row.requested_count is distinct from 6 or v_row.applicable_count is distinct from 6
     or v_row.answered_count is distinct from 5 or v_row.photo_count is distinct from 3
     or v_row.has_gt_pin is not true or v_row.has_truck_pin is not false
     or v_row.accepted_count is distinct from 1 then
    raise exception 'VERIFY V4a: A wrong: % % req % app % ans % photos % gt % truck % acc %', v_row.state, v_row.status,
      v_row.requested_count, v_row.applicable_count, v_row.answered_count, v_row.photo_count, v_row.has_gt_pin, v_row.has_truck_pin, v_row.accepted_count; end if;
  select * into v_row from client.v_intake_submissions where intake_id = v_b;
  if v_row.state is distinct from 'awaiting' or v_row.status is not null or v_row.answered_count is not null
     or v_row.applicable_count is not null or v_row.photo_count is not null or v_row.has_gt_pin is not null or v_row.has_truck_pin is not null then
    raise exception 'VERIFY V4b: an awaiting row carries collected data'; end if;
  select * into v_row from client.v_intake_submissions where intake_id = v_f;
  if v_row.status is distinct from 'Complete' or v_row.requested_count is distinct from 6
     or v_row.applicable_count is distinct from 4 or v_row.answered_count is distinct from 4 then
    raise exception 'VERIFY V4c: F (hidden follow-up + untaken branch) must be Complete 4 of 4: % req % app % ans %',
      v_row.status, v_row.requested_count, v_row.applicable_count, v_row.answered_count; end if;
  if (select status from client.v_intake_submissions where intake_id = v_h) is distinct from 'Incomplete' then
    raise exception 'VERIFY V4d: H (only an undefined key unanswered) must be Incomplete'; end if;
  if (select status from client.v_intake_submissions where intake_id = v_j) is distinct from 'Incomplete' then
    raise exception 'VERIFY V4e: J (whitespace-only answer) must be Incomplete'; end if;
  if (select state from client.v_intake_submissions where intake_id = v_g) is distinct from 'submitted' then
    raise exception 'VERIFY V4f: a submitted intake whose link later expired must still show as submitted'; end if;
  select count(*) into v_n from client.v_intake_submissions where intake_id in (v_c, v_d, v_e);
  if v_n is distinct from 0 then raise exception 'VERIFY V4g: % cancelled/expired-unused intakes appear', v_n; end if;

  -- ============================================ V5 MIRROR: the Clients-list source agrees, both branches
  if (select intake_id from client.v_property_intake where property_id = v_p1) is distinct from v_a
     or (select intake_status from client.v_property_intake where property_id = v_p1) is distinct from 'Incomplete'
     or (select missing_keys from client.v_property_intake where property_id = v_p1) is distinct from array['access_entry.alarm'] then
    raise exception 'VERIFY V5a: v_property_intake wrong for p1'; end if;
  if (select intake_id from client.v_property_intake where property_id = v_p2) is distinct from v_f
     or (select intake_status from client.v_property_intake where property_id = v_p2) is distinct from 'Complete'
     or (select missing_keys from client.v_property_intake where property_id = v_p2) is distinct from '{}'::text[] then
    raise exception 'VERIFY V5b: v_property_intake does not show F as Complete (the HIGH finding)'; end if;

  -- ============================================ V6 get_intake (gate, then staff)
  perform set_config('request.jwt.claims', '', true);
  v_raised := false;
  begin perform client.get_intake(v_a); exception when sqlstate '28000' then v_raised := true; end;
  if not v_raised then raise exception 'VERIFY V6a: no refusal without a JWT'; end if;
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000001","email":"someone@gmail.com","role":"authenticated"}', true);
  v_raised := false;
  begin perform client.get_intake(v_a); exception when sqlstate '42501' then v_raised := true; end;
  if not v_raised then raise exception 'VERIFY V6b: no refusal for a non-staff email'; end if;
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000002","email":"verify@ayache.com","role":"authenticated"}', true);

  v_j1 := client.get_intake(v_a);
  if v_j1->>'status' is distinct from 'Incomplete' or v_j1->'missing' is distinct from '["access_entry.alarm"]'::jsonb
     or (v_j1->>'requested_count')::int is distinct from 6 or (v_j1->>'applicable_count')::int is distinct from 6 then
    raise exception 'VERIFY V6c: A header wrong: % % % %', v_j1->>'status', v_j1->'missing', v_j1->>'requested_count', v_j1->>'applicable_count'; end if;
  -- snapshot order, not alphabetical and not requested order
  if v_j1#>>'{sections,0,id}' is distinct from 'site_map' or v_j1#>>'{sections,1,id}' is distinct from 'access_entry'
     or v_j1#>>'{sections,2,id}' is distinct from 'grease_trap' or v_j1#>>'{sections,3,id}' is distinct from '_not_in_form_definition'
     or jsonb_array_length(v_j1->'sections') is distinct from 4 then
    raise exception 'VERIFY V6d: sections not in snapshot order'; end if;
  if v_j1#>>'{sections,1,questions,0,key}' is distinct from 'access_entry.gate'
     or v_j1#>>'{sections,1,questions,0,label}' is distinct from '[TEST] label from THIS snapshot'
     or v_j1#>>'{sections,1,questions,1,value}' is distinct from '1234'
     or v_j1#>>'{sections,1,questions,1,applicable}' is distinct from 'true'
     or v_j1#>>'{sections,1,questions,2,key}' is distinct from 'access_entry.alarm'
     or v_j1#>>'{sections,1,questions,2,answered}' is distinct from 'false'
     or jsonb_array_length(v_j1#>'{sections,1,questions}') is distinct from 3 then
    raise exception 'VERIFY V6e: access_entry questions wrong: %', v_j1#>'{sections,1,questions}'; end if;
  if jsonb_array_length(v_j1#>'{sections,0,questions}') is distinct from 1
     or jsonb_array_length(v_j1#>'{sections,2,questions}') is distinct from 1
     or jsonb_array_length(v_j1#>'{sections,2,questions,0,photos}') is distinct from 1
     or v_j1#>>'{sections,2,questions,0,photos,0,path}' is distinct from v_a||'/p1.jpg' then
    raise exception 'VERIFY V6f: unrequested question rendered, or photos wrong (soft-deleted returned?)'; end if;
  if v_j1#>>'{sections,3,questions,0,key}' is distinct from 'orphan.requested_key'
     or v_j1#>>'{sections,3,questions,0,answered}' is distinct from 'true'
     or jsonb_array_length(v_j1#>'{sections,3,questions,0,photos}') is distinct from 1 then
    raise exception 'VERIFY V6g: the requested-but-undefined key was dropped'; end if;
  select count(*) into v_n from jsonb_array_elements(v_j1->'unlisted_answers') x
   where x->>'key' in ('grease_trap.systems_count','zzz.not_in_form');
  if v_n is distinct from 2 or jsonb_array_length(v_j1->'unlisted_answers') is distinct from 2 then
    raise exception 'VERIFY V6h: unlisted_answers wrong: %', v_j1->'unlisted_answers'; end if;
  if jsonb_array_length(v_j1->'unlisted_photos') is distinct from 1 or v_j1#>>'{unlisted_photos,0,role}' is distinct from 'zzz.orphan_role' then
    raise exception 'VERIFY V6i: unlisted_photos wrong'; end if;
  if v_j1::text like '%/p7.jpg%' then raise exception 'VERIFY V6j: a soft-deleted photo was returned'; end if;

  v_jf := client.get_intake(v_f);
  if v_jf->>'status' is distinct from 'Complete' or (v_jf->>'applicable_count')::int is distinct from 4 then
    raise exception 'VERIFY V6k: get_intake does not report F Complete 4 applicable: % %', v_jf->>'status', v_jf->>'applicable_count'; end if;
  select count(*) into v_n from jsonb_array_elements(v_jf#>'{sections,0,questions}') q
   where q->>'key' in ('access_entry.gate_code','access_entry.key_instruction') and q->>'applicable' = 'false';
  if v_n is distinct from 2 then raise exception 'VERIFY V6l: the two hidden questions are not flagged applicable=false'; end if;

  v_jb := client.get_intake(v_b);
  if v_jb->>'state' is distinct from 'awaiting' or v_jb->>'status' is not null
     or jsonb_array_length(v_jb->'sections') is distinct from 1 or v_jb::text like '%/p2.jpg%' then
    raise exception 'VERIFY V6m: awaiting detail wrong or returned its photo'; end if;
  if (client.get_intake(v_c))->>'state' is distinct from 'cancelled' or (client.get_intake(v_d))->>'state' is distinct from 'expired'
     or (client.get_intake(v_e))->>'state' is distinct from 'cancelled' or (client.get_intake(v_g))->>'state' is distinct from 'submitted' then
    raise exception 'VERIFY V6n: state order wrong'; end if;
  if v_j1::text like '%'||v_tok_a||'%' or v_j1::text like '%'||v_tok_b||'%' or v_jb::text like '%'||v_tok_b||'%'
     or v_jf::text like '%'||v_tok_f||'%' then
    raise exception 'VERIFY V6o: a token appears in a get_intake payload'; end if;

  -- ============================================ V7 the same reads AS authenticated, through the grants
  execute 'set local role authenticated';
  if (select status from client.v_intake_submissions where intake_id = v_f) is distinct from 'Complete'
     or (select intake_status from client.v_property_intake where property_id = v_p2) is distinct from 'Complete'
     or (client.get_intake(v_a))->>'status' is distinct from 'Incomplete' then
    raise exception 'VERIFY V7: a staff session does not see what postgres sees'; end if;
  execute 'reset role';

  -- ============================================ V8 standing checks on LIVE data, not on fixtures
  select count(*) into v_n from public.photos ph join public.property_intakes t on position(t.token in ph.storage_path) > 0;
  if v_n is distinct from 0 then raise exception 'VERIFY V8a: % photo paths contain a live intake token', v_n; end if;
  select count(*) into v_n from storage.objects o where o.bucket_id = 'intake-photos' and o.name !~ '^[0-9]+/';
  if v_n is distinct from 0 then raise exception 'VERIFY V8b: % intake-photos objects are not in an id-named folder', v_n; end if;
  select count(*) into v_n from pg_attribute where attrelid = 'client.v_intake_submissions'::regclass and attname ilike '%token%' and not attisdropped;
  if v_n is distinct from 0 then raise exception 'VERIFY V8c: the list view exposes a token column'; end if;

  -- ============================================ V9 the raw record stays immutable
  v_raised := false;
  begin
    update public.property_intakes set answers = '{}'::jsonb where id = v_a;
  exception when sqlstate '22023' then v_raised := sqlerrm like '%raw intake submission is immutable%';
  end;
  if not v_raised then raise exception 'VERIFY V9: the immutability trigger did not refuse'; end if;

  -- ============================================ cleanup, scoped to the fixtures, then prove it
  perform set_config('request.jwt.claims', '', true);
  delete from public.property_intake_accepts where intake_id = any (v_ids);
  delete from public.photo_links where photo_id = any (v_ph);
  delete from public.photos where id = any (v_ph);
  delete from public.property_intakes where id = any (v_ids);
  if exists (select 1 from public.property_intakes where id = any (v_ids))
     or exists (select 1 from public.photos where id = any (v_ph))
     or exists (select 1 from public.photo_links where photo_id = any (v_ph))
     or exists (select 1 from public.property_intake_accepts where intake_id = any (v_ids)) then
    raise exception 'VERIFY: fixtures left behind'; end if;

  raise notice 'VERIFY: applicability, redaction and viewer surface, all assertions passed';
end $verify$;

notify pgrst, 'reload schema';
