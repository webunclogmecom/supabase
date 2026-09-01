-- 2026-09-01_1900  Undo a mistaken inclusion: take a visit back out of the review queue.
--
-- Fred: "And what if we made a mistake at the included visit? can we take it out from
-- the queue?" The answer today is no, because I cut the undo from 2026-09-01_1800 as
-- speculative. He asked for it within the hour, which is the evidence it was not.
--
-- His rule for the friction: **one click while nothing has been done, a reason once
-- someone has done work against the visit.**
--
-- 🛑 THE OBVIOUS PREDICATE FOR "ALREADY REVIEWED" IS DEAD AND WOULD NEVER FIRE.
-- `review_status <> 'pending'` reads like the test and is worthless: **all 1,145
-- completed visits read 'pending'**, because the column COALESCEs to it and nothing
-- writes anything else. `reviewed_at` is set on **0** of the 87 `visit_reviews` rows. A
-- reason requirement built on either is a guard at the cap that can never trip, and it
-- would have shipped looking correct.
--
-- The real signal is the WORK PRODUCT. Admin Review exists to classify photos, so:
--   * a photo of the visit carries a `photo_classifications` row (1,492 exist), or
--   * its `visit_reviews` row carries an actual decision (bonus/invoice/quality/reviewed_at)
-- Measured: **165 of 1,145** completed visits qualify, 3 by the decision arm alone. A
-- real split, not a degenerate one.
--
-- REMOVAL IS SOFT. The row stays as the record that a decision was made AND REVERSED,
-- which is the whole reason this table exists: an exception to a historic line has to
-- stay defensible later. A DELETE would leave audit.logs as the only trace of both.
--
-- Rule 8: the table already carries its audit trigger from 2026-09-01_1800; adding
-- columns to an audited table is captured automatically, so there is nothing to opt in.

begin;

alter table public.review_scope_inclusions
  add column if not exists removed_at     timestamptz,
  add column if not exists removed_by     text,
  add column if not exists removed_reason text;

comment on column public.review_scope_inclusions.removed_at is
  'Set when the inclusion is reversed. The row is kept: it records that a visit was deliberately pulled into the queue and then deliberately pulled back out. in_review_scope requires this to be NULL.';

-- ------------------------------------------------------------ scope respects it ----
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
    COALESCE((j.title ILIKE 'Service Agreement%' OR j.title ILIKE 'Service Call%')
        AND j.title NOT ILIKE '%[OLD]%', false) AS job_is_sa_sc,
    COALESCE((j.title ILIKE 'Service Agreement%' OR j.title ILIKE 'Service Call%')
        AND j.title NOT ILIKE '%[OLD]%', false)
      OR (inc.visit_id IS NOT NULL AND inc.removed_at IS NULL) AS in_review_scope,
    CASE
      WHEN COALESCE((j.title ILIKE 'Service Agreement%' OR j.title ILIKE 'Service Call%')
                      AND j.title NOT ILIKE '%[OLD]%', false) THEN 'convention'::text
      WHEN inc.visit_id IS NOT NULL AND inc.removed_at IS NULL THEN 'manual'::text
      ELSE NULL::text
    END AS scope_source,
    -- Has anybody actually DONE anything with this visit? Drives whether removing it
    -- needs a reason. NOT review_status, which is 'pending' on every row in the estate.
    (EXISTS (SELECT 1 FROM photo_links pl
               JOIN photo_classifications pc ON pc.photo_link_id = pl.id
              WHERE pl.entity_type = 'visit' AND pl.entity_id = v.id AND pl.deleted_at IS NULL)
     OR EXISTS (SELECT 1 FROM visit_reviews r
                 WHERE r.visit_id = v.id
                   AND (COALESCE(r.review_status,'pending') <> 'pending'
                     OR COALESCE(r.bonus_status,'pending') <> 'pending'
                     OR COALESCE(r.invoice_status,'pending') <> 'pending'
                     OR r.quality_flag_note IS NOT NULL
                     OR r.reviewed_at IS NOT NULL))) AS review_work_started
   FROM v_visits_live v
     LEFT JOIN visit_reviews vr ON vr.visit_id = v.id
     LEFT JOIN jobs j ON j.id = v.job_id
     LEFT JOIN review_scope_inclusions inc ON inc.visit_id = v.id;

-- --------------------------------------------------------------------- the RPC ----
create or replace function public.remove_visits_from_review(
  p_visit_ids bigint[],
  p_reason    text default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
DECLARE
  v_reason text;
  v_actor  text;
  v_id     bigint;
  v_out    jsonb := '[]'::jsonb;
  v_src    text;
  v_work   boolean;
  v_active boolean;
BEGIN
  v_reason := btrim(translate(coalesce(p_reason,''), chr(9)||chr(10)||chr(13)||chr(160), '    '), ' ');

  IF p_visit_ids IS NULL OR array_length(p_visit_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'remove_visits_from_review: no visits were passed' USING ERRCODE = '22023';
  END IF;

  BEGIN
    v_actor := nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email';
  EXCEPTION WHEN others THEN
    v_actor := NULL;
  END;
  v_actor := coalesce(nullif(v_actor,''), session_user);

  FOREACH v_id IN ARRAY p_visit_ids LOOP
    SELECT w.scope_source, w.review_work_started INTO v_src, v_work
      FROM public.visits_with_review w WHERE w.id = v_id;
    SELECT (inc.visit_id IS NOT NULL AND inc.removed_at IS NULL) INTO v_active
      FROM public.review_scope_inclusions inc WHERE inc.visit_id = v_id;

    IF v_src IS NULL AND NOT coalesce(v_active,false) THEN
      v_out := v_out || jsonb_build_object('visit_id', v_id, 'removed', false,
                 'skipped_because', 'no such visit, or it was never included');
    ELSIF NOT coalesce(v_active,false) THEN
      -- Includes the case where the visit is in the queue on its own merits: removing
      -- an inclusion would not take it out, so saying "done" would be a lie.
      v_out := v_out || jsonb_build_object('visit_id', v_id, 'removed', false,
                 'skipped_because', CASE WHEN v_src = 'convention'
                   THEN 'this visit is in the queue because its job follows the convention, not because it was included'
                   ELSE 'it was not included, or the inclusion was already removed' END);
    ELSIF coalesce(v_work,false) AND v_reason = '' THEN
      -- Fred's rule: one click while nothing has been done, a reason once it has.
      v_out := v_out || jsonb_build_object('visit_id', v_id, 'removed', false,
                 'skipped_because', 'work has already been done on this visit, so a reason is required to take it back out');
    ELSE
      UPDATE public.review_scope_inclusions
         SET removed_at = now(), removed_by = v_actor,
             removed_reason = nullif(v_reason,'')
       WHERE visit_id = v_id AND removed_at IS NULL;
      v_out := v_out || jsonb_build_object('visit_id', v_id, 'removed', true,
                 'skipped_because', NULL);
    END IF;

    v_out := jsonb_set(v_out, ARRAY[(jsonb_array_length(v_out)-1)::text, 'in_scope_now'],
             to_jsonb(coalesce((SELECT w.in_review_scope FROM public.visits_with_review w WHERE w.id = v_id), false)));
  END LOOP;

  RETURN jsonb_build_object(
    'requested', array_length(p_visit_ids,1),
    'removed',   (SELECT count(*) FROM jsonb_array_elements(v_out) e WHERE (e->>'removed')::boolean),
    'by',        v_actor,
    'results',   v_out);
END $function$;

comment on function public.remove_visits_from_review(bigint[], text) is
  'Reverse a manual inclusion. Soft: the row is kept with removed_at/by/reason. A reason is required ONLY when review_work_started is true (classified photos or a real decision), per Fred 2026-09-01. Refuses a visit that is in the queue on its own merits, because removing an inclusion would not take it out.';

revoke all on function public.remove_visits_from_review(bigint[], text) from public;
revoke all on function public.remove_visits_from_review(bigint[], text) from anon;
grant execute on function public.remove_visits_from_review(bigint[], text) to authenticated, service_role;

-- ------------------------------------------------------------------- VERIFY -------
do $$
declare
  v_work_yes int;
  v_work_no  int;
  v_res      jsonb;
  v_scope    boolean;
  v_src_after text;
  v_authn    int;
begin
  -- 1. CONTROL ON THE PREDICATE ITSELF. If review_work_started were the dead
  --    review_status test, it would be false everywhere and the reason requirement
  --    could never fire. Both sides must be non-empty.
  select count(*) filter (where review_work_started),
         count(*) filter (where not review_work_started)
    into v_work_yes, v_work_no
    from public.visits_with_review where visit_status = 'completed';
  if v_work_yes = 0 or v_work_no = 0 then
    raise exception 'control failed: review_work_started is % / % - a guard that can never trip', v_work_yes, v_work_no;
  end if;

  -- 2. V-1542 is currently included, with no work done, so it is the one-click case.
  select in_review_scope into v_scope from public.visits_with_review where id = 1542;
  if not v_scope then
    raise exception 'control failed: V-1542 is not in scope, so removal has nothing to prove';
  end if;
  if (select review_work_started from public.visits_with_review where id = 1542) then
    raise exception 'control failed: V-1542 now has work done, so it no longer tests the no-reason path';
  end if;

  begin
    -- 3. POSITIVE: no reason needed, and it really leaves the queue.
    v_res := public.remove_visits_from_review(ARRAY[1542]::bigint[], NULL);
    if (v_res->>'removed')::int <> 1 then
      raise exception 'V-1542 was not removed without a reason: %', v_res;
    end if;
    select in_review_scope, scope_source into v_scope, v_src_after
      from public.visits_with_review where id = 1542;
    if v_scope then
      raise exception 'V-1542 is still in scope after removal';
    end if;

    -- 4. NEGATIVE: removing it again must refuse, not silently succeed.
    v_res := public.remove_visits_from_review(ARRAY[1542]::bigint[], NULL);
    if (v_res->>'removed')::int <> 0 then
      raise exception 'a second removal reported success: %', v_res;
    end if;

    -- 5. NEGATIVE: a convention visit cannot be removed by this path.
    v_res := public.remove_visits_from_review(ARRAY[6311]::bigint[], NULL);
    if (v_res->'results'->0->>'skipped_because') not like '%follows the convention%' then
      raise exception 'a convention visit was not refused correctly: %', v_res->'results'->0;
    end if;

    raise exception 'ROLLBACK_PROBE';
  exception when others then
    if sqlerrm <> 'ROLLBACK_PROBE' then raise; end if;
  end;

  -- 6. The probe unwound: V-1542 is back in the queue.
  select in_review_scope into v_scope from public.visits_with_review where id = 1542;
  if not v_scope then
    raise exception 'probe leaked: V-1542 did not come back into scope';
  end if;
  if exists (select 1 from public.review_scope_inclusions where removed_at is not null) then
    raise exception 'probe leaked: a removal survived the rollback';
  end if;

  -- 7. The app's role can still read and can execute the new RPC.
  begin
    execute 'set local role authenticated';
    execute 'select count(*) from public.visits_with_review' into v_authn;
    execute 'reset role';
  exception when others then
    execute 'reset role';
    raise exception 'authenticated cannot read visits_with_review: % (%)', sqlerrm, sqlstate;
  end;
  if not has_function_privilege('authenticated','public.remove_visits_from_review(bigint[], text)','EXECUTE') then
    raise exception 'authenticated cannot execute remove_visits_from_review';
  end if;

  raise notice 'VERIFY OK: work_started % yes / % no, V-1542 removed without a reason then refused on repeat, convention visit refused, rollback clean, authenticated reads % rows',
               v_work_yes, v_work_no, v_authn;
end $$;

commit;
