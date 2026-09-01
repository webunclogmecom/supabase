-- 2026-09-01_1800  A deliberate escape hatch: pull a pre-convention visit into the
--                  Admin Review queue, recorded, without touching Jobber.
--
-- Design: docs/superpowers/specs/2026-09-01-admin-review-scope-inclusions-design.md
--
-- Fred, on 117-BH: a March visit (V-1542, 9 photos, derm_required true) cannot be
-- reviewed because its job (83, "Grease Trap Pumping & Hydrojet Cleaning", archived)
-- predates the SA/SC naming convention the queue was scoped to in 2026-09-01_1700.
-- He settled the principle: **"the line is a historic change of before/after naming
-- convention"**, so it marks an ERA, not quality, and an exception to it should be a
-- deliberate recorded act rather than a rule change.
--
-- 🛑 RENAMING THE JOB IN JOBBER IS DELIBERATELY REJECTED HERE, even though two jobs were
-- renamed exactly that way earlier today. Jobs 1771 ("Service") and 1839 ("Emergency
-- call") had VAGUE titles, so retitling them "Service Call" made a customer-facing
-- record more accurate. Job 83's title is TRUE. Relabelling it would degrade Jobber to
-- satisfy a query, and it does not scale: 276 jobs are excluded, 145 of them carrying a
-- DERM-required photographed visit.
--
-- Scope of the problem, measured: of 660 excluded completed visits, 563 carry photos,
-- 431 are derm_required, 413 are both, 479 have a filed manifest link, and only 89 carry
-- the [OLD] marker.
--
-- Rule 8: this table OPTS IN to audit triggers. `derm_portal_requeue` is the precedent
-- for opting out on the grounds that such a table IS its own audit trail, but that holds
-- only because it is append-only. This one has human-editable fields.

begin;

-- ------------------------------------------------------------------ the record ----
create table if not exists public.review_scope_inclusions (
  visit_id    bigint primary key references public.visits(id),
  reason      text not null,
  included_at timestamptz not null default now(),
  included_by text,
  -- Strip the WHOLE whitespace class, not just ASCII space. btrim(x,' ') alone lets a
  -- TAB or NBSP reason through, which is the hole fn_requeue_derm_portal had to close.
  -- chr() codepoints rather than literal invisible characters, so the constraint cannot
  -- be silently corrupted by whatever edits this file. All functions here are IMMUTABLE,
  -- which a CHECK requires.
  constraint review_scope_inclusions_reason_not_blank
    check (btrim(translate(reason, chr(9)||chr(10)||chr(13)||chr(160), '    '), ' ') <> '')
);

comment on table public.review_scope_inclusions is
  'One row per visit deliberately pulled into the Admin Review queue despite its job predating the Service Agreement / Service Call naming convention. The PK on visit_id makes inclusion idempotent. Removal is deliberately not modelled: see the design doc.';

-- Supabase default privileges hand out grants nobody wrote, so revoke BY NAME and then
-- grant only what is intended. The relacl is read back in the VERIFY.
revoke all on public.review_scope_inclusions from public;
revoke all on public.review_scope_inclusions from anon, authenticated;
grant select on public.review_scope_inclusions to authenticated;
grant all    on public.review_scope_inclusions to service_role;

-- Rule 8 opt-in.
drop trigger if exists audit_review_scope_inclusions on public.review_scope_inclusions;
create trigger audit_review_scope_inclusions
  after insert or update or delete on public.review_scope_inclusions
  for each row execute function audit.log_change();

-- ------------------------------------------------------- policy on the queue view ----
-- Appended, so this stays CREATE OR REPLACE. `job_is_sa_sc` keeps its meaning: it is a
-- FACT about the job. `in_review_scope` is the POLICY the queue filters on. Collapsing
-- them would let a policy change rewrite the historical fact and would leave the modal
-- unable to explain WHY a visit is out of scope.
create or replace view public.visits_with_review as
 SELECT v.id, v.client_id, v.property_id, v.job_id, v.vehicle_id, v.visit_date,
    v.start_at, v.end_at, v.completed_at, v.duration_minutes, v.title, v.service_type,
    v.visit_status, v.actual_arrival_at, v.actual_departure_at, v.is_gps_confirmed,
    v.created_at, v.updated_at, v.invoice_id, v.completed_by,
    COALESCE(vr.review_status, 'pending'::text) AS review_status,
    vr.reviewed_at, vr.reviewed_by,
    COALESCE(vr.bonus_status, 'pending'::text) AS bonus_status,
    vr.bonus_decided_at, vr.bonus_decided_by, vr.bonus_denial_note, vr.quality_flag_note,
    v.public_id,
    COALESCE(vr.invoice_status, 'pending'::text) AS invoice_status,
    vr.invoice_decided_at, vr.invoice_decided_by, v.derm_required,
    COALESCE(
      (j.title ILIKE 'Service Agreement%' OR j.title ILIKE 'Service Call%')
        AND j.title NOT ILIKE '%[OLD]%',
      false) AS job_is_sa_sc,
    -- POLICY: what the queue filters on.
    COALESCE(
      (j.title ILIKE 'Service Agreement%' OR j.title ILIKE 'Service Call%')
        AND j.title NOT ILIKE '%[OLD]%',
      false)
      OR (inc.visit_id IS NOT NULL) AS in_review_scope,
    -- CONVENTION WINS when both are true. Reachable only if a job is renamed to comply
    -- AFTER a manual inclusion, which is exactly what happened to jobs 1771 and 1839
    -- today. Once the job qualifies on its own the inclusion is no longer carrying it,
    -- and the badge must stop claiming otherwise. The inclusion row stays as the record.
    CASE
      WHEN COALESCE((j.title ILIKE 'Service Agreement%' OR j.title ILIKE 'Service Call%')
                      AND j.title NOT ILIKE '%[OLD]%', false) THEN 'convention'::text
      WHEN inc.visit_id IS NOT NULL THEN 'manual'::text
      ELSE NULL::text
    END AS scope_source
   FROM v_visits_live v
     LEFT JOIN visit_reviews vr ON vr.visit_id = v.id
     LEFT JOIN jobs j ON j.id = v.job_id
     LEFT JOIN review_scope_inclusions inc ON inc.visit_id = v.id;

-- ------------------------------------------------------------------ the picker ----
create or replace view public.v_review_scope_picker as
 select w.client_id,
        c.client_code,
        c.name                                   as client_name,
        w.id                                     as visit_id,
        w.public_id,
        w.visit_date,
        w.job_id,
        coalesce(j.title, '(no job title)')      as job_title,
        j.job_status,
        w.derm_required,
        w.in_review_scope,
        w.scope_source,
        (select count(*) from public.photo_links pl
          where pl.entity_type = 'visit' and pl.entity_id = w.id and pl.deleted_at is null)::int
                                                 as photo_count
   from public.visits_with_review w
   join public.clients c on c.id = w.client_id
   left join public.jobs j on j.id = w.job_id
  where w.visit_status = 'completed';

comment on view public.v_review_scope_picker is
  'Feeds the Admin Review "include a past visit" modal: one row per completed visit with its job and scope state, so the browser does not have to join jobs and count photo_links itself and the "why is this out of scope" answer comes from one place.';

revoke all on public.v_review_scope_picker from public;
revoke all on public.v_review_scope_picker from anon;
grant select on public.v_review_scope_picker to authenticated, service_role;

-- --------------------------------------------------------------------- the RPC ----
create or replace function public.include_visits_in_review(
  p_visit_ids bigint[],
  p_reason    text
) returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
DECLARE
  v_reason  text;
  v_actor   text;
  v_id      bigint;
  v_out     jsonb := '[]'::jsonb;
  v_status  text;
  v_scope   boolean;
  v_ok      boolean;
BEGIN
  -- Same whitespace class as the CHECK and as fn_requeue_derm_portal.
  v_reason := btrim(translate(coalesce(p_reason,''), chr(9)||chr(10)||chr(13)||chr(160), '    '), ' ');
  IF v_reason = '' THEN
    RAISE EXCEPTION 'include_visits_in_review: a reason is required - the next person to read this row has to know why a pre-convention visit was pulled into the queue'
      USING ERRCODE = '22023';
  END IF;

  IF p_visit_ids IS NULL OR array_length(p_visit_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'include_visits_in_review: no visits were passed'
      USING ERRCODE = '22023';
  END IF;

  -- Prefer the JWT over anything the caller could supply. Same shape as
  -- fn_requeue_derm_portal. NOTE request.jwt.claims, PLURAL: the singular key is never
  -- set by PostgREST, which is why audit.logs.changed_by has been NULL on every row.
  BEGIN
    v_actor := nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email';
  EXCEPTION WHEN others THEN
    v_actor := NULL;
  END;
  v_actor := coalesce(nullif(v_actor,''), session_user);

  -- PARTIAL, not all-or-nothing: one already-in-scope visit in a batch of ten must not
  -- abort the other nine. Every requested visit gets its own verdict, and the caller
  -- renders them, so a partly applied batch is visible rather than assumed.
  FOREACH v_id IN ARRAY p_visit_ids LOOP
    SELECT w.visit_status, w.in_review_scope INTO v_status, v_scope
      FROM public.visits_with_review w WHERE w.id = v_id;

    v_ok := false;
    IF v_status IS NULL THEN
      v_out := v_out || jsonb_build_object('visit_id', v_id, 'included', false,
                 'skipped_because', 'no such visit, or it is soft-deleted');
    ELSIF v_status <> 'completed' THEN
      v_out := v_out || jsonb_build_object('visit_id', v_id, 'included', false,
                 'skipped_because', format('visit is %s, and the queue only reviews completed visits', v_status));
    ELSIF v_scope THEN
      -- An inclusion that changes nothing while reporting success is the "operator
      -- believes they acted" failure fn_requeue_derm_portal exists to prevent.
      v_out := v_out || jsonb_build_object('visit_id', v_id, 'included', false,
                 'skipped_because', 'already in the review queue');
    ELSE
      INSERT INTO public.review_scope_inclusions (visit_id, reason, included_by)
      VALUES (v_id, v_reason, v_actor);
      v_ok := true;
      v_out := v_out || jsonb_build_object('visit_id', v_id, 'included', true,
                 'skipped_because', NULL);
    END IF;

    -- Report the POST-CONDITION, not "ok".
    v_out := jsonb_set(v_out, ARRAY[(jsonb_array_length(v_out)-1)::text, 'in_scope_now'],
             to_jsonb(coalesce((SELECT w.in_review_scope FROM public.visits_with_review w WHERE w.id = v_id), false)));
  END LOOP;

  RETURN jsonb_build_object(
    'requested', array_length(p_visit_ids,1),
    'included',  (SELECT count(*) FROM jsonb_array_elements(v_out) e WHERE (e->>'included')::boolean),
    'reason',    v_reason,
    'by',        v_actor,
    'results',   v_out);
END $function$;

comment on function public.include_visits_in_review(bigint[], text) is
  'Pull pre-convention visits into the Admin Review queue. Partial by design: each visit gets its own verdict. Refuses a visit already in scope rather than reporting a success that changed nothing.';

revoke all on function public.include_visits_in_review(bigint[], text) from public;
revoke all on function public.include_visits_in_review(bigint[], text) from anon;
grant execute on function public.include_visits_in_review(bigint[], text) to authenticated, service_role;

-- ------------------------------------------------------------------- VERIFY -------
do $$
declare
  v_acl        text;
  v_sib        text;
  v_before     int;
  v_after      int;
  v_res        jsonb;
  v_scope      boolean;
  v_src        text;
  v_authn      int;
  v_pick       int;
  v_refused    text;
begin
  -- 1. GRANTS, read AFTER creation. CREATE TABLE hands out privileges before any GRANT
  --    runs, which is how job_frequency_changes shipped with authenticated holding
  --    TRUNCATE. Compare against a sibling rather than against my expectations.
  select c.relacl::text into v_acl from pg_class c join pg_namespace n on n.oid=c.relnamespace
   where n.nspname='public' and c.relname='review_scope_inclusions';
  select c.relacl::text into v_sib from pg_class c join pg_namespace n on n.oid=c.relnamespace
   where n.nspname='public' and c.relname='derm_portal_requeue';
  if has_table_privilege('anon','public.review_scope_inclusions','SELECT') then
    raise exception 'anon can read review_scope_inclusions (acl %)', v_acl;
  end if;
  if has_table_privilege('authenticated','public.review_scope_inclusions','INSERT')
     or has_table_privilege('authenticated','public.review_scope_inclusions','DELETE')
     or has_table_privilege('authenticated','public.review_scope_inclusions','TRUNCATE') then
    raise exception 'authenticated holds a write grant on review_scope_inclusions (acl %) - it must go through the RPC', v_acl;
  end if;
  if not has_table_privilege('authenticated','public.review_scope_inclusions','SELECT') then
    raise exception 'authenticated cannot read review_scope_inclusions (acl %)', v_acl;
  end if;

  -- 2. Rule 8 opt-in actually attached.
  if not exists (select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid
                  where c.relname='review_scope_inclusions' and t.tgname='audit_review_scope_inclusions'
                    and not t.tgisinternal) then
    raise exception 'audit trigger missing on review_scope_inclusions';
  end if;

  -- 3. THE CASE. V-1542 must be out of scope BEFORE, or this migration is asserting
  --    into a vacuum.
  select in_review_scope, scope_source into v_scope, v_src
    from public.visits_with_review where id = 1542;
  if v_scope is not false then
    raise exception 'control failed: V-1542 is already in scope (%), so the fix has nothing to prove', v_scope;
  end if;
  if v_src is not null then
    raise exception 'control failed: V-1542 already reports scope_source %', v_src;
  end if;

  -- 4. POSITIVE CONTROL + NEGATIVE CONTROL in one call, inside a savepoint so nothing
  --    commits: a real pre-convention visit, one already in scope, and a nonexistent id.
  select count(*) into v_before from public.visits_with_review where in_review_scope;
  begin
    v_res := public.include_visits_in_review(ARRAY[1542, 6311, -1]::bigint[], 'verify probe');

    if (v_res->>'included')::int <> 1 then
      raise exception 'expected exactly 1 inclusion, got %: %', v_res->>'included', v_res;
    end if;
    if not ((v_res->'results'->0->>'included')::boolean) then
      raise exception 'V-1542 was not included: %', v_res->'results'->0;
    end if;
    if (v_res->'results'->1->>'skipped_because') is distinct from 'already in the review queue' then
      raise exception 'V-6311 should have been refused as already in scope, got %', v_res->'results'->1;
    end if;
    if (v_res->'results'->2->>'skipped_because') not like 'no such visit%' then
      raise exception 'a nonexistent visit should have been refused, got %', v_res->'results'->2;
    end if;

    select in_review_scope, scope_source into v_scope, v_src
      from public.visits_with_review where id = 1542;
    if not v_scope or v_src is distinct from 'manual' then
      raise exception 'after inclusion V-1542 reads scope=% source=%', v_scope, v_src;
    end if;
    select count(*) into v_after from public.visits_with_review where in_review_scope;
    if v_after <> v_before + 1 then
      raise exception 'queue moved by % rather than exactly 1', v_after - v_before;
    end if;

    -- the blank-reason guard must bite
    begin
      perform public.include_visits_in_review(ARRAY[1542]::bigint[], chr(9)||chr(160)||' ');
      raise exception 'control failed: a whitespace-only reason was accepted';
    exception when sqlstate '22023' then null;
    end;

    raise exception 'ROLLBACK_PROBE';
  exception when others then
    if sqlerrm <> 'ROLLBACK_PROBE' then raise; end if;
  end;

  -- 5. The probe really unwound.
  select in_review_scope into v_scope from public.visits_with_review where id = 1542;
  if v_scope then
    raise exception 'probe leaked: V-1542 is still in scope after rollback';
  end if;
  if exists (select 1 from public.review_scope_inclusions) then
    raise exception 'probe leaked: review_scope_inclusions is not empty';
  end if;

  -- 6. The role the app uses can actually read both objects and execute the RPC. The
  --    view/function privilege asymmetry has broken five things here; reasoning is not
  --    evidence.
  begin
    execute 'set local role authenticated';
    execute 'select count(*) from public.visits_with_review' into v_authn;
    execute 'select count(*) from public.v_review_scope_picker' into v_pick;
    execute 'reset role';
  exception when others then
    execute 'reset role';
    raise exception 'authenticated cannot read the new objects: % (%)', sqlerrm, sqlstate;
  end;
  if coalesce(v_authn,0) = 0 or coalesce(v_pick,0) = 0 then
    raise exception 'authenticated read the views but saw % / % rows', v_authn, v_pick;
  end if;
  if not has_function_privilege('authenticated','public.include_visits_in_review(bigint[], text)','EXECUTE') then
    raise exception 'authenticated cannot execute the RPC';
  end if;

  raise notice 'VERIFY OK: acl % (sibling %), audit trigger on, V-1542 out of scope before, probe included exactly 1 and refused 2, rolled back clean, authenticated reads %/% rows',
               v_acl, v_sib, v_authn, v_pick;
end $$;

commit;
