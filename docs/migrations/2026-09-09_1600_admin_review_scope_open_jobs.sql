-- 2026-09-09_1600  Admin Review queue scope: OPEN JOBS (plus anything already being worked
--                  on), not the SA/SC job title.
--
-- Fred: "I remember asking you to show only the visits at the admin review app that are a
-- SC or SA job on their title. So what i want is actually a filter that only shows the
-- visits from open jobs, and the `Include a past visit` button, let's you bypass that
-- filter of any visit you select there."
--
-- Put to him with the measurement below, he chose OPEN JOBS + ANYTHING ALREADY STARTED.
-- So the policy has three arms and the manual escape hatch keeps working as it did:
--
--     in_review_scope = the job is open
--                    OR work has already been done on this visit
--                    OR an active review_scope_inclusions row
--
-- WHY THE THIRD ARM EXISTS, in one measurement. Service Call jobs close almost immediately
-- after the work, and we classify photos weeks later, so a pure open-job rule would hide
-- most SC visits before anyone reviewed them:
--
--   how long a Service Call job stays open after the work
--     per JOB, from its last completed visit (audit.logs, n=12 since 2026-07-30)
--       median 1.8 days · 11 of 12 within a week · max 13.9
--     per VISIT, so earlier visits on a multi-visit job get longer (n=27)
--       median 5.0 days · 15 of 27 within a week
--   how long it takes us to classify that visit's photos
--     first photo_classifications row, SC visits (n=36)
--       median 16.6 days · 5 of 36 within 2 days · 11 of 36 within a week
--     all visits since 2026-06-01 (n=148): median 18.1 days
--
-- BOTH RATES ARE SURVIVOR-BIASED, and an adversarial review was right to say so. The archive
-- lag can only contain jobs that HAVE archived, and the classification lag only visits
-- somebody HAS classified - a visit nobody ever gets to has an infinite lag and is invisible
-- to the second sample. The bias in the classification number therefore runs SHORT, so the
-- true gap is WIDER than 17 days, not narrower: the caveat strengthens the conclusion rather
-- than undermining it. Read the numbers as a floor.
--
-- THE COST IS CUSTOMER-FACING, NOT JUST A SHORTER LIST. Of the 70 visits leaving the queue
-- tonight, 36 carry photos and NONE of those photos is classified - 173 photos in total.
-- `customer.wo_photos` INNER JOINs `photo_classifications`, so an unclassified photo is not
-- merely hidden from the client, it does not exist for them: those 36 Service Reports show NO
-- photos at all, and after this change no queue lists the visits, so nobody will classify
-- them. They are reachable only through the include modal, one at a time, by somebody who
-- already knows to look. 5 of the 70 are DERM-required.
--
-- The work-started arm does NOT close that gap for an untouched visit - an SC visit nobody
-- has opened still drops out in about two to five days, and nothing surfaces which ones
-- fell out. It protects work IN PROGRESS only. That is Fred's decision, taken against
-- these numbers, and the alternative he declined was a grace window on the archive date.
--
-- THE VIEW HAS TO CHANGE INSTEAD OF THE APP FILTERING ON job_status.
-- `public.include_visits_in_review` refuses any visit that already reads
-- `in_review_scope = true` ("already in the review queue"). If the app filtered on job
-- status client-side while the column still said true, the visits that leave the queue
-- could NEVER BE INCLUDED BACK - which is precisely the bypass Fred is asking for. The
-- queue filter and the include RPC read the same column on purpose, and that is why the
-- policy lives here.
--
-- job_is_sa_sc IS NOT TOUCHED. It is the historical FACT about the job title
-- (2026-09-01_1700), it is what lets the app explain WHY a visit is out of scope, and a
-- policy change must not rewrite it. This migration adds `job_is_open` beside it as a
-- second fact and re-points only the POLICY (`in_review_scope` / `scope_source`).
--
-- "Open" = `job_status NOT IN (archived, closed, destroyed)`.
-- 🛑 I FIRST WROTE `<> 'archived'`, COPYING Supabase/CLAUDE.md, WHICH SAYS "there is no
-- closed/destroyed value in public.jobs.job_status". THAT SENTENCE IS FALSE and an
-- adversarial review caught it. The CHECK constraint on the column admits TWELVE values
-- (requires_invoicing, archived, late, today, upcoming, action_required, on_hold,
-- unscheduled, active, expiring_within_30_days, closed, destroyed) and audit.logs holds
--   closed      40 occurrences, last 2026-09-07  (two days ago)
--   destroyed    2 occurrences, 2026-08-21       (transient: the poll converges it to
--                                                 archived ~20 min later)
--   unscheduled  2 occurrences, 2026-08-07
-- ZERO rows hold closed or destroyed right now, which is exactly why the census reads
-- like a complete domain and why no data-driven assertion can tell the two definitions
-- apart. THE CHECK IS THE DOMAIN; the census is a measurement of this minute. Under the
-- one-value test a closed or destroyed job would have counted as OPEN and kept its visits
-- in the queue - the precise opposite of the ask. The three-value list matches what
-- sync-jobber-job-drift already treats as terminal (.not(job_status,in,
-- (archived,closed,destroyed))), so this is the estate's existing precedent, not a new
-- vocabulary. on_hold / unscheduled / expiring_within_30_days are OPEN states and stay in.
-- VERIFY 2b drives a real job through closed, destroyed and on_hold in a rolled-back
-- savepoint, because a data assertion here would pass vacuously today.
-- A visit with no job row at all is NOT open.
--
-- MEASURED IMPACT, on 2026-09-09 with 1,226 completed visits dated on or before today:
--   queue now            567  (566 by convention + 1 manual)
--   queue after          527  (488 open_job + 38 work_started + 1 manual)
--   leave the queue       70  SA/SC visits on an archived job with no work started
--                             63 SC, 7 SA, 5 DERM-required
--   join the queue        30  29 of them pre-convention visits somebody HAS worked on and
--                             which the SA/SC gate had been hiding, plus 1 open legacy job
--   V-1542 (the one live manual inclusion, on an ARCHIVED job) STAYS IN - the bypass works
--
-- THE WORK-STARTED ARM COLLIDES WITH THE REMOVE FEATURE, AND IT IS LIVE TODAY, NOT
-- LATENT. `review_work_started` is true for V-1542, the single active manual inclusion.
-- Once a visit is in scope because work was done on it, taking the inclusion away CANNOT
-- take it out of the queue, so 2026-09-01_1900's "a reason is required to take it back
-- out" is now friction on an act that no longer does anything - the operator supplies a
-- reason, the RPC reports removed:true, and the card stays. Its premise (that removal is
-- what decides scope) is what Fred's new rule retires.
-- => scope_source precedence stays open_job > manual > work_started, so the "Included
--    manually" chip and the provenance survive on V-1542, and `remove_visits_from_review`
--    now REFUSES a worked-on visit and says why, instead of reporting a success that
--    changes nothing. The app hides the Remove control on `review_work_started` (it
--    already selects that column) so the refusal is a backstop, not the normal path.
--
-- scope_source's automatic arm is RENAMED 'convention' -> 'open_job' and gains
-- 'work_started', because leaving it reading "convention" would be a lie about the rule
-- that admitted the row. That value has exactly two other readers and both are updated in
-- the same cycle:
--   * public.remove_visits_from_review (below, machine-checked against the live body)
--   * the Admin Review bundle (`l.scope_source==="convention"`), which is a SEPARATE Lovable
--     publish and therefore lands LATER, not atomically with this file.
-- => IN THE GAP between applying this and publishing the app, no row reads convention, so
--   `followsConvention` is false everywhere and every job group in the include modal renders
--   "Outside convention". Cosmetic, on a label being deleted in the same cycle, and it is the
--   only visible effect of the rename on the published build. The queue itself is unaffected:
--   the bundle queue mapper folds every non-manual value into one internal label
--   (`scope_source==="manual" ? "manual" : "convention"`), so the chip and the Remove control
--   keep working throughout.
-- The bundle's queue mapper does `scope_source==="manual" ? "manual" : "convention"`,
-- which folds every non-manual value into one internal label, so it survives the rename
-- untouched. Only the include modal's job label reads the literal.
-- The historical comment inside remove_visits_from_review that mentions 'convention' is
-- LEFT ALONE on purpose: it is a dated record of the 2026-09-01_2100 unreachable-branch
-- defect, and correcting a past-tense record to match the present is how evidence
-- disappears (root CLAUDE.md 5.5).
--
-- Rule 8: no new table, no new audited surface. `review_scope_inclusions` keeps its
-- trigger; the views carry no data of their own.

begin;

-- Snapshot the OLD answers before replacing anything, so the verify block can prove the
-- change moved what it was supposed to move and nothing else. A count asserted against a
-- number typed in from a measurement taken minutes ago would drift; a join against this
-- table cannot.
-- The WHOLE of both views, every column. CREATE OR REPLACE VIEW enforces column NAME
-- and TYPE and says NOTHING about the expression behind it, so two same-typed columns can
-- be silently transposed and every shape check still passes. 36 of the 38 columns here are
-- retyped in this file and were never meant to move; VERIFY 1 proves it row by row.
create temp table _pre_full on commit drop as select * from public.visits_with_review;
create temp table _pre_pick on commit drop as select * from public.v_review_scope_picker;

create temp table _pre_fn on commit drop as
select 'remove'::text as fn,
       pg_get_functiondef('public.remove_visits_from_review(bigint[],text)'::regprocedure) as def
union all
select 'include',
       pg_get_functiondef('public.include_visits_in_review(bigint[],text)'::regprocedure);

-- ------------------------------------------------------------------- the policy ----

create or replace view public.visits_with_review as
select
  v.id,
  v.client_id,
  v.property_id,
  v.job_id,
  v.vehicle_id,
  v.visit_date,
  v.start_at,
  v.end_at,
  v.completed_at,
  v.duration_minutes,
  v.title,
  v.service_type,
  v.visit_status,
  v.actual_arrival_at,
  v.actual_departure_at,
  v.is_gps_confirmed,
  v.created_at,
  v.updated_at,
  v.invoice_id,
  v.completed_by,
  coalesce(vr.review_status, 'pending'::text) as review_status,
  vr.reviewed_at,
  vr.reviewed_by,
  coalesce(vr.bonus_status, 'pending'::text) as bonus_status,
  vr.bonus_decided_at,
  vr.bonus_decided_by,
  vr.bonus_denial_note,
  vr.quality_flag_note,
  v.public_id,
  coalesce(vr.invoice_status, 'pending'::text) as invoice_status,
  vr.invoice_decided_at,
  vr.invoice_decided_by,
  v.derm_required,
  -- 34. THE FACT about the job title. Byte-identical to 2026-09-01_1700. Not the queue
  -- filter any more, and deliberately still computed: it is the historical record of the
  -- naming-convention era and the only thing that can explain a pre-convention job later.
  coalesce((j.title ilike 'Service Agreement%'::text or j.title ilike 'Service Call%'::text)
           and j.title not ilike '%[OLD]%'::text, false) as job_is_sa_sc,
  -- 35. THE POLICY the Admin Review queue filters on. 2026-09-09.
  -- NOTE the work-started arm reads w.started, the SAME expression column 37 publishes.
  -- It is computed ONCE in the LATERAL below and referenced twice on purpose: writing the
  -- two EXISTS clauses out again here would be a second copy of one rule, and the copy
  -- that drifts is always the one nobody re-tests.
  coalesce(j.job_status not in ('archived'::text, 'closed'::text, 'destroyed'::text), false)
    or w.started
    or (inc.visit_id is not null and inc.removed_at is null) as in_review_scope,
  -- 36. Which arm carried it, highest priority first. A deliberate act outranks a side
  -- effect: 'manual' must survive on a visit that has ALSO been worked on, or the
  -- "Included manually" chip and the provenance behind it vanish from the card.
  case
    when coalesce(j.job_status not in ('archived'::text, 'closed'::text, 'destroyed'::text), false) then 'open_job'::text
    when inc.visit_id is not null and inc.removed_at is null then 'manual'::text
    when w.started then 'work_started'::text
    else null::text
  end as scope_source,
  -- 37. Unchanged in MEANING from 2026-09-01_1900; the expression moved into the LATERAL
  -- so the policy above can share it. The verify block asserts it did not move on any row.
  w.started as review_work_started,
  j.title as job_title,
  -- 39. NEW FACT, appended (create or replace can only add at the end). An app must read
  -- this rather than testing job_status itself - the rule lives in the DB, not in six
  -- copies across the Lovable projects.
  coalesce(j.job_status not in ('archived'::text, 'closed'::text, 'destroyed'::text), false) as job_is_open
from public.v_visits_live v
  left join public.visit_reviews vr on vr.visit_id = v.id
  left join public.jobs j on j.id = v.job_id
  left join public.review_scope_inclusions inc on inc.visit_id = v.id
  left join lateral (
    select (exists (select 1
                      from public.photo_links pl
                      join public.photo_classifications pc on pc.photo_link_id = pl.id
                     where pl.entity_type = 'visit'::text
                       and pl.entity_id = v.id
                       and pl.deleted_at is null))
        or (exists (select 1
                      from public.visit_reviews r
                     where r.visit_id = v.id
                       and (coalesce(r.review_status, 'pending'::text) <> 'pending'::text
                         or coalesce(r.bonus_status, 'pending'::text) <> 'pending'::text
                         or coalesce(r.invoice_status, 'pending'::text) <> 'pending'::text
                         or r.quality_flag_note is not null
                         or r.reviewed_at is not null))) as started
  ) w on true;

comment on view public.visits_with_review is
  'Admin Review queue source. in_review_scope is the POLICY (the job is open, OR work has already been done on the visit, OR an active review_scope_inclusions row); job_is_sa_sc and job_is_open are FACTS. Do not re-implement either rule in an app.';

-- The picker gains the same fact. The modal does NOT read it today - it renders the raw
-- job_status chip it already had - so this is here for the next thing that needs to ask
-- "is this job open?", which must read this column and never test job_status itself.
-- Appended; every existing column keeps its position and its type.
create or replace view public.v_review_scope_picker as
select
  w.client_id,
  c.client_code,
  c.name as client_name,
  w.id as visit_id,
  w.public_id,
  w.visit_date,
  w.job_id,
  coalesce(j.title, '(no job title)'::text) as job_title,
  j.job_status,
  w.derm_required,
  w.in_review_scope,
  w.scope_source,
  ((select count(*) as count
      from public.photo_links pl
     where pl.entity_type = 'visit'::text
       and pl.entity_id = w.id
       and pl.deleted_at is null))::integer as photo_count,
  w.job_is_open
from public.visits_with_review w
  join public.clients c on c.id = w.client_id
  left join public.jobs j on j.id = w.job_id
where w.visit_status = 'completed'::text;

comment on view public.v_review_scope_picker is
  'Source for the Admin Review "Include a past visit" modal. It deliberately returns BOTH in-scope and out-of-scope visits; the modal filters to in_review_scope = false so a visit already in the queue is not offered (Fred, 2026-09-09). That filter lives in the APP query and ships on the Lovable side, not in this view - do not read this comment as a predicate.';

-- --------------------------------------------- the one other reader of the value ----
-- Two changes only: the 'convention' arm becomes 'open_job' and gains a 'work_started'
-- sibling, and the reason-required arm becomes a refusal (see the collision note in the
-- header). Machine-checked below against the live body captured into _pre_fn above, so a
-- transcription slip cannot ship.

create or replace function public.remove_visits_from_review(p_visit_ids bigint[], p_reason text default null::text)
returns jsonb
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
  v_row    boolean;
  v_exists  boolean;
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
    v_exists := FOUND;
    SELECT (inc.visit_id IS NOT NULL AND inc.removed_at IS NULL),
           (inc.visit_id IS NOT NULL)
      INTO v_active, v_row
      FROM public.review_scope_inclusions inc WHERE inc.visit_id = v_id;

    -- 2026-09-01_2100. This chain used to key "does the visit exist" off scope_source,
    -- which is NULL for ANY out-of-scope visit. A visit whose inclusion had been REMOVED
    -- therefore took the first arm and was told it had never been included, while its
    -- inclusion row sat there carrying a reason, a removed_by and a removed_at. Observed
    -- live in a two-tab race: tab B removed the visit, tab A confirmed a moment later and
    -- read "no such visit, or it was never included".
    -- The old ELSE ("it was not included, or the inclusion was already removed") was
    -- UNREACHABLE: it needed scope_source non-null, not 'convention', and no active
    -- inclusion, but scope_source = 'manual' IS "an active inclusion exists" (measured:
    -- 0 visits read 'manual' without one, against a control of 1 that does).
    -- Existence now comes from the visit lookup and the row lookup, so the four cases are
    -- distinguishable and each gets its own sentence.
    IF NOT coalesce(v_exists,false) THEN
      v_out := v_out || jsonb_build_object('visit_id', v_id, 'removed', false,
                 'skipped_because', 'no such visit, or it is soft-deleted');
    -- 2026-09-09: scope_source's automatic arm is now 'open_job' (the job is not archived),
    -- not 'convention' (an SA/SC title), and 'work_started' is a third way in. Renamed and
    -- extended with the view in the same migration.
    ELSIF NOT coalesce(v_active,false) AND v_src = 'open_job' THEN
      -- Checked BEFORE the already-removed arm: when both are true this is the one that
      -- explains why removing anything would not help, which is what the caller needs.
      v_out := v_out || jsonb_build_object('visit_id', v_id, 'removed', false,
                 'skipped_because', 'this visit is in the queue because its job is open, not because it was included');
    ELSIF NOT coalesce(v_active,false) AND v_src = 'work_started' THEN
      v_out := v_out || jsonb_build_object('visit_id', v_id, 'removed', false,
                 'skipped_because', 'this visit is in the queue because work has already been done on it, not because it was included');
    ELSIF NOT coalesce(v_active,false) AND coalesce(v_row,false) THEN
      v_out := v_out || jsonb_build_object('visit_id', v_id, 'removed', false,
                 'skipped_because', 'the inclusion was already removed');
    ELSIF NOT coalesce(v_active,false) THEN
      v_out := v_out || jsonb_build_object('visit_id', v_id, 'removed', false,
                 'skipped_because', 'this visit was never included in the queue');
    ELSIF coalesce(v_work,false) THEN
      -- 2026-09-09. This arm used to be "work has been done, so a REASON is required",
      -- Fred's 2026-09-01 friction rule. Work now keeps a visit in scope on its own, so
      -- removing the inclusion cannot take it out of the queue and a reason would buy a
      -- change that does not happen. Refuse and name the real state instead of reporting
      -- a success that alters nothing.
      v_out := v_out || jsonb_build_object('visit_id', v_id, 'removed', false,
                 'skipped_because', 'work has already been done on this visit, so it stays in the queue whatever happens to the inclusion');
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

-- ---------------------------------------- the include RPC names the retired rule ----
-- Its missing-reason RAISE reads "...why a PRE-CONVENTION visit was pulled into the
-- queue". That was the reason a visit sat outside the queue until today; from now on the
-- reason is that its JOB IS CLOSED and nobody has touched it. Left as-is it is a message
-- describing a rule we just retired, sitting in the one place an operator reads when they
-- are confused - and this estate has already paid for stale wording being quoted back as
-- if it were current.
--
-- ONE LINE CHANGES. The whole definition below was MACHINE-COPIED from the live
-- pg_get_functiondef and machine-patched (a script wrote it, nothing was retyped): the
-- patch moved exactly 1 line of 108 and 3 characters of 4,905. VERIFY 6b reverse-patches
-- it back and requires the result to equal the live body byte for byte.

CREATE OR REPLACE FUNCTION public.include_visits_in_review(p_visit_ids bigint[], p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_reason  text;
  v_actor   text;
  v_id      bigint;
  v_out     jsonb := '[]'::jsonb;
  v_status  text;
  v_scope   boolean;
  v_ok      boolean;
  v_revived boolean;
BEGIN
  -- Same whitespace class as the CHECK and as fn_requeue_derm_portal.
  v_reason := btrim(translate(coalesce(p_reason,''), chr(9)||chr(10)||chr(13)||chr(160), '    '), ' ');
  IF v_reason = '' THEN
    RAISE EXCEPTION 'include_visits_in_review: a reason is required - the next person to read this row has to know why a visit from a closed job was pulled into the queue'
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
      -- 2026-09-01_2000. A row can already EXIST and be soft-removed. in_review_scope
      -- requires removed_at IS NULL, so such a visit arrives here reading out-of-scope,
      -- and the bare INSERT below raised 23505 against the visit_id PRIMARY KEY. That
      -- error is not caught per visit, so it aborted the WHOLE batch: one previously
      -- removed visit in a batch of ten killed the other nine, and removal was one-way.
      -- Reset per iteration: a stale true from the previous visit would skip the INSERT
      -- and report an inclusion that never happened.
      v_revived := NULL;
      SELECT (inc.removed_at IS NOT NULL) INTO v_revived
        FROM public.review_scope_inclusions inc WHERE inc.visit_id = v_id;

      IF v_revived THEN
        -- Revive rather than insert. The table is audited, so include -> remove ->
        -- include stays legible in audit.logs.old_row even though the row itself only
        -- ever holds the latest state. The removed_at IS NOT NULL predicate is repeated
        -- on the UPDATE so it cannot rewrite an ACTIVE inclusion's reason if the world
        -- changed between the read and the write.
        UPDATE public.review_scope_inclusions
           SET removed_at = NULL, removed_by = NULL, removed_reason = NULL,
               reason = v_reason, included_by = v_actor, included_at = now()
         WHERE visit_id = v_id AND removed_at IS NOT NULL;
      ELSE
        INSERT INTO public.review_scope_inclusions (visit_id, reason, included_by)
        VALUES (v_id, v_reason, v_actor);
      END IF;

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
END $function$
;

-- -------------------------------------------------------------------- VERIFY ----
-- Inside the transaction on purpose: a failed assertion rolls the whole change back
-- rather than leaving a half-applied policy live for the queue to read.

do $$
declare
  v_today        date := (now() at time zone 'America/New_York')::date;
  v_n            bigint;
  v_open         bigint;
  v_manual       bigint;
  v_work         bigint;
  v_queue_before bigint;
  v_queue_after  bigint;
  v_left         bigint;
  v_joined       bigint;
  v_old_def      text;
  v_expect_def   text;
  v_new_def      text;
  v_probe_id     bigint;
  v_subject      bigint;
  v_res          jsonb;
  v_authn        bigint;
begin
  ---------------------------------------------------------------- 1. the facts ----
  -- job_is_sa_sc is the historical FACT and must be identical on every row. So is
  -- review_work_started: the policy below USES it as an operand, and an operand that
  -- moved in the same migration would make assertion 2 prove nothing.
  select count(*) into v_n
    from _pre_full p join public.visits_with_review n on n.id = p.id
   where p.job_is_sa_sc is distinct from n.job_is_sa_sc;
  if v_n <> 0 then
    raise exception 'job_is_sa_sc moved on % rows - the historical fact must not change', v_n;
  end if;

  select count(*) into v_n
    from _pre_full p join public.visits_with_review n on n.id = p.id
   where p.review_work_started is distinct from n.review_work_started;
  if v_n <> 0 then
    raise exception 'review_work_started moved on % rows when it only moved into a LATERAL', v_n;
  end if;

  select count(*) into v_n from _pre_full p
   where not exists (select 1 from public.visits_with_review n where n.id = p.id);
  if v_n <> 0 then
    raise exception '% rows vanished from visits_with_review - the join shape changed', v_n;
  end if;

  -- Every column this migration RETYPED but did not intend to change, compared row by
  -- row in BOTH directions. EXCEPT ALL, not EXCEPT, so a duplicated or dropped row counts
  -- too. This is the assertion that makes retyping a 38-column view safe; the two named
  -- checks above survive because a specific message beats a generic one when it fires.
  select count(*) into v_n from (
    (select
           id, client_id, property_id, job_id, vehicle_id, visit_date, start_at, end_at,
           completed_at, duration_minutes, title, service_type, visit_status,
           actual_arrival_at, actual_departure_at, is_gps_confirmed, created_at, updated_at,
           invoice_id, completed_by, review_status, reviewed_at, reviewed_by, bonus_status,
           bonus_decided_at, bonus_decided_by, bonus_denial_note, quality_flag_note, public_id,
           invoice_status, invoice_decided_at, invoice_decided_by, derm_required, job_is_sa_sc,
           review_work_started, job_title
       from _pre_full
     except all
     select
           id, client_id, property_id, job_id, vehicle_id, visit_date, start_at, end_at,
           completed_at, duration_minutes, title, service_type, visit_status,
           actual_arrival_at, actual_departure_at, is_gps_confirmed, created_at, updated_at,
           invoice_id, completed_by, review_status, reviewed_at, reviewed_by, bonus_status,
           bonus_decided_at, bonus_decided_by, bonus_denial_note, quality_flag_note, public_id,
           invoice_status, invoice_decided_at, invoice_decided_by, derm_required, job_is_sa_sc,
           review_work_started, job_title
       from public.visits_with_review)
    union all
    (select
           id, client_id, property_id, job_id, vehicle_id, visit_date, start_at, end_at,
           completed_at, duration_minutes, title, service_type, visit_status,
           actual_arrival_at, actual_departure_at, is_gps_confirmed, created_at, updated_at,
           invoice_id, completed_by, review_status, reviewed_at, reviewed_by, bonus_status,
           bonus_decided_at, bonus_decided_by, bonus_denial_note, quality_flag_note, public_id,
           invoice_status, invoice_decided_at, invoice_decided_by, derm_required, job_is_sa_sc,
           review_work_started, job_title
       from public.visits_with_review
     except all
     select
           id, client_id, property_id, job_id, vehicle_id, visit_date, start_at, end_at,
           completed_at, duration_minutes, title, service_type, visit_status,
           actual_arrival_at, actual_departure_at, is_gps_confirmed, created_at, updated_at,
           invoice_id, completed_by, review_status, reviewed_at, reviewed_by, bonus_status,
           bonus_decided_at, bonus_decided_by, bonus_denial_note, quality_flag_note, public_id,
           invoice_status, invoice_decided_at, invoice_decided_by, derm_required, job_is_sa_sc,
           review_work_started, job_title
       from _pre_full)
  ) d;
  if v_n <> 0 then
    raise exception '% row-differences in visits_with_review on the 36 columns this migration was not supposed to touch', v_n;
  end if;

  select count(*) into v_n from (
    (select
           client_id, client_code, client_name, visit_id, public_id, visit_date, job_id,
           job_title, job_status, derm_required, photo_count
       from _pre_pick
     except all
     select
           client_id, client_code, client_name, visit_id, public_id, visit_date, job_id,
           job_title, job_status, derm_required, photo_count
       from public.v_review_scope_picker)
    union all
    (select
           client_id, client_code, client_name, visit_id, public_id, visit_date, job_id,
           job_title, job_status, derm_required, photo_count
       from public.v_review_scope_picker
     except all
     select
           client_id, client_code, client_name, visit_id, public_id, visit_date, job_id,
           job_title, job_status, derm_required, photo_count
       from _pre_pick)
  ) d;
  if v_n <> 0 then
    raise exception '% row-differences in v_review_scope_picker on the 11 columns this migration was not supposed to touch', v_n;
  end if;

  -------------------------------------------------------------- 2. the policy ----
  -- Asserted against the SOURCE TABLES for the job and inclusion arms, and against the
  -- column assertion 1 just proved unchanged for the work arm. Not against a paraphrase
  -- of the view's own expression, which would agree with itself whatever shipped.
  select count(*) into v_n
    from public.visits_with_review n
    left join public.jobs j on j.id = n.job_id
    left join public.review_scope_inclusions inc on inc.visit_id = n.id
   where n.in_review_scope is distinct from
         (coalesce(j.job_status not in ('archived','closed','destroyed'), false)
          or n.review_work_started
          or (inc.visit_id is not null and inc.removed_at is null));
  if v_n <> 0 then
    raise exception 'in_review_scope disagrees with (job open OR work started OR active inclusion) on % rows', v_n;
  end if;

  select count(*) into v_n
    from public.visits_with_review n
    left join public.jobs j on j.id = n.job_id
    left join public.review_scope_inclusions inc on inc.visit_id = n.id
   where n.scope_source is distinct from
         (case when coalesce(j.job_status not in ('archived','closed','destroyed'), false) then 'open_job'
               when inc.visit_id is not null and inc.removed_at is null then 'manual'
               when n.review_work_started then 'work_started'
               else null end);
  if v_n <> 0 then
    raise exception 'scope_source disagrees with the rule on % rows', v_n;
  end if;

  select count(*) into v_n
    from public.visits_with_review n
    left join public.jobs j on j.id = n.job_id
   where n.job_is_open is distinct from coalesce(j.job_status not in ('archived','closed','destroyed'), false);
  if v_n <> 0 then
    raise exception 'job_is_open disagrees with (job_status not in archived/closed/destroyed) on % rows', v_n;
  end if;

  -------------------------------------------- 2b. the DOMAIN, not the census ----
  -- public.jobs.job_status is CHECK-pinned to TWELVE values. 'closed' has occurred 40
  -- times (last 2026-09-07) and 'destroyed' twice, but ZERO rows hold either right now,
  -- so every data-driven assertion above would pass just as happily against a one-value
  -- denylist that treats a closed job as OPEN. Drive a real row through the real view
  -- inside a savepoint instead - the only test that can tell the two definitions apart.
  select j.id into v_probe_id
    from public.jobs j
    join public.v_visits_live v on v.job_id = j.id
   where j.job_status not in ('archived','closed','destroyed')
     and v.visit_status = 'completed'
   order by j.id limit 1;
  if v_probe_id is null then
    raise exception 'control failed: no open job with a completed visit exists to drive the domain probe';
  end if;
  if not exists (select 1 from public.visits_with_review where job_id = v_probe_id and job_is_open) then
    raise exception 'control failed: job % does not read open BEFORE the probe, so the probe proves nothing', v_probe_id;
  end if;

  begin
    update public.jobs set job_status = 'closed' where id = v_probe_id;
    if exists (select 1 from public.visits_with_review where job_id = v_probe_id and job_is_open) then
      raise exception 'a job in state closed still reads job_is_open - the test only covers archived';
    end if;

    update public.jobs set job_status = 'destroyed' where id = v_probe_id;
    if exists (select 1 from public.visits_with_review where job_id = v_probe_id and job_is_open) then
      raise exception 'a job in state destroyed still reads job_is_open';
    end if;

    -- The other direction, so this is not a denylist that swallows everything: on_hold is
    -- an OPEN state and its visits must STAY in the queue.
    update public.jobs set job_status = 'on_hold' where id = v_probe_id;
    if not exists (select 1 from public.visits_with_review where job_id = v_probe_id and job_is_open) then
      raise exception 'a job on hold reads closed - on_hold is an open state and must stay in the queue';
    end if;

    raise exception 'ROLLBACK_PROBE';
  exception when others then
    if sqlerrm <> 'ROLLBACK_PROBE' then raise; end if;
  end;

  if not exists (select 1 from public.visits_with_review where job_id = v_probe_id and job_is_open) then
    raise exception 'the domain probe leaked: job % did not come back to an open state', v_probe_id;
  end if;

  ------------------------------------------------- 3. absence + positive anchors ----
  -- The value 'convention' is gone, and ALL THREE surviving arms actually fire. An
  -- absence assertion with no positive anchor passes vacuously for ever.
  select count(*) into v_n from public.visits_with_review where scope_source = 'convention';
  if v_n <> 0 then
    raise exception '% rows still read scope_source = convention', v_n;
  end if;

  select count(*) into v_open   from public.visits_with_review where scope_source = 'open_job';
  select count(*) into v_manual from public.visits_with_review where scope_source = 'manual';
  select count(*) into v_work   from public.visits_with_review where scope_source = 'work_started';
  if v_open = 0 then
    raise exception 'no row reads scope_source = open_job - the job arm never fires, so the absence check above is vacuous';
  end if;
  if v_manual = 0 then
    raise exception 'no row reads scope_source = manual - the bypass arm never fires, and the include button would be pointless';
  end if;
  if v_work = 0 then
    raise exception 'no row reads scope_source = work_started - the arm Fred chose today never fires';
  end if;

  -- The discriminator: under the OLD definition this was 79 (archived SA/SC jobs); under
  -- a pure open-job rule it would be 38. If the replace silently did not take, or the work
  -- arm was dropped, this is what fails.
  -- IS DISTINCT FROM, never <>: scope_source is NULL on every out-of-scope visit and
  -- `NULL <> 'manual'` is NULL, so a plain <> would DROP exactly the rows a broken policy
  -- would produce and pass vacuously.
  select count(*) into v_n
    from public.visits_with_review
   where in_review_scope and not job_is_open and not review_work_started
     and scope_source is distinct from 'manual';
  if v_n <> 0 then
    raise exception '% rows are in scope with a closed job, no work started and no inclusion', v_n;
  end if;

  ------------------------------------------------------- 4. the measured movement ----
  select count(*) into v_queue_before from _pre_full
   where visit_status = 'completed' and in_review_scope and visit_date <= v_today;
  select count(*) into v_queue_after from public.visits_with_review
   where visit_status = 'completed' and in_review_scope and visit_date <= v_today;

  select count(*) into v_left
    from _pre_full p join public.visits_with_review n on n.id = p.id
   where p.visit_status = 'completed' and p.visit_date <= v_today
     and p.in_review_scope and not n.in_review_scope;
  select count(*) into v_joined
    from _pre_full p join public.visits_with_review n on n.id = p.id
   where p.visit_status = 'completed' and p.visit_date <= v_today
     and not p.in_review_scope and n.in_review_scope;

  -- Every visit that left must have left for the stated reason: a closed job, no work
  -- started and no active inclusion. Not "roughly 70" - zero exceptions.
  select count(*) into v_n
    from _pre_full p join public.visits_with_review n on n.id = p.id
   where p.in_review_scope and not n.in_review_scope
     and (n.job_is_open or n.review_work_started or n.scope_source is not null);
  if v_n <> 0 then
    raise exception '% visits left the queue for a reason other than a closed, untouched, un-included visit', v_n;
  end if;

  select count(*) into v_n
    from _pre_full p join public.visits_with_review n on n.id = p.id
   where not p.in_review_scope and n.in_review_scope
     and not (n.job_is_open or n.review_work_started);
  if v_n <> 0 then
    raise exception '% visits joined the queue without an open job or work started', v_n;
  end if;

  -- The four counts above are the whole point of the change and NOTHING asserted them: the
  -- only consumer is the closing RAISE NOTICE, and the Management API transport this repo
  -- applies migrations through returns the last result set and DISCARDS notices. So they were
  -- computed, reported to nobody, and could have read anything. Bounds, not exact values,
  -- because the data moves between the measurement and the apply - but a change that moves
  -- nothing, or moves half the estate, must not commit quietly.
  if v_left = 0 then
    raise exception 'no visit left the queue - the policy did not actually narrow anything';
  end if;
  if v_joined = 0 then
    raise exception 'no visit joined the queue - the work_started arm admitted nobody';
  end if;
  if v_left > 300 or v_joined > 300 then
    raise exception 'the queue moved by an implausible amount: % left, % joined', v_left, v_joined;
  end if;
  if v_queue_after = 0 then
    raise exception 'the queue is empty after the change';
  end if;

  ------------------------------------------ 5. the bypass, and the precedence ----
  -- V-1542 is the one live manual inclusion, its job IS archived, and work HAS been done
  -- on it. So it is simultaneously the bypass test and the precedence test: manual must
  -- outrank work_started, or the "Included manually" chip disappears from the card.
  if not exists (select 1 from public.review_scope_inclusions
                  where visit_id = 1542 and removed_at is null) then
    raise exception 'control failed: V-1542 is no longer an active inclusion, so it cannot test the bypass';
  end if;
  -- jobs.job_status is a pure mirror of Jobber and can flip on any */5 poll. If either anchor
  -- job is reopened upstream these tests stop testing what they claim, so say THAT rather than
  -- accusing the policy of a fault it does not have.
  if (select job_is_open from public.visits_with_review where id = 1542) then
    raise exception 'control failed: V-1542 job has reopened upstream, so it can no longer test the closed-job bypass';
  end if;
  if not (select review_work_started from public.visits_with_review where id = 1542) then
    raise exception 'control failed: V-1542 no longer has work started, so it cannot test the precedence';
  end if;
  select count(*) into v_n from public.visits_with_review
   where id = 1542 and in_review_scope and scope_source = 'manual' and not job_is_open;
  if v_n <> 1 then
    raise exception 'V-1542 does not read manual-on-a-closed-job: the bypass or the precedence is broken';
  end if;

  -- V-5093's inclusion was REMOVED on 2026-09-01 and its job is archived, so the manual
  -- arm must not carry it - but work has been done on it, so under Fred's new rule it is
  -- correctly in scope by that arm instead. Both halves asserted: the removal is still
  -- honoured AND the reason it is here is the work, not the dead inclusion.
  if exists (select 1 from public.review_scope_inclusions
              where visit_id = 5093 and removed_at is null) then
    raise exception 'control failed: V-5093 inclusion is active again, so it cannot test a removed inclusion';
  end if;
  if (select job_is_open from public.visits_with_review where id = 5093) then
    raise exception 'control failed: V-5093 job has reopened upstream, so work_started is no longer the arm carrying it';
  end if;
  select count(*) into v_n from public.visits_with_review
   where id = 5093 and in_review_scope and scope_source = 'work_started';
  if v_n <> 1 then
    raise exception 'V-5093 does not read work_started - a removed inclusion is being honoured wrongly, or the work arm is broken';
  end if;

  ------------------------------------- 6. the remove RPC body, machine-checked ------
  -- Reverse-patch: apply the four intended edit hunks to the LIVE body captured before
  -- the replace and require the result to equal what is live now, byte for byte. The
  -- hunks below were GENERATED from a line diff of the two bodies, not typed, and each
  -- was asserted to occur exactly once in the live body before being written here. A
  -- typo anywhere else in 82 lines fails here instead of shipping.
  select def into v_old_def from _pre_fn where fn = 'remove';
  v_expect_def := v_old_def;
  v_expect_def := replace(v_expect_def,
    '    ELSIF NOT coalesce(v_active,false) AND v_src = ''convention'' THEN
',
    '    -- 2026-09-09: scope_source''s automatic arm is now ''open_job'' (the job is not archived),
    -- not ''convention'' (an SA/SC title), and ''work_started'' is a third way in. Renamed and
    -- extended with the view in the same migration.
    ELSIF NOT coalesce(v_active,false) AND v_src = ''open_job'' THEN
');
  v_expect_def := replace(v_expect_def,
    '                 ''skipped_because'', ''this visit is in the queue because its job follows the convention, not because it was included'');
',
    '                 ''skipped_because'', ''this visit is in the queue because its job is open, not because it was included'');
    ELSIF NOT coalesce(v_active,false) AND v_src = ''work_started'' THEN
      v_out := v_out || jsonb_build_object(''visit_id'', v_id, ''removed'', false,
                 ''skipped_because'', ''this visit is in the queue because work has already been done on it, not because it was included'');
');
  v_expect_def := replace(v_expect_def,
    '    ELSIF coalesce(v_work,false) AND v_reason = '''' THEN
      -- Fred''s rule: one click while nothing has been done, a reason once it has.
',
    '    ELSIF coalesce(v_work,false) THEN
      -- 2026-09-09. This arm used to be "work has been done, so a REASON is required",
      -- Fred''s 2026-09-01 friction rule. Work now keeps a visit in scope on its own, so
      -- removing the inclusion cannot take it out of the queue and a reason would buy a
      -- change that does not happen. Refuse and name the real state instead of reporting
      -- a success that alters nothing.
');
  v_expect_def := replace(v_expect_def,
    '                 ''skipped_because'', ''work has already been done on this visit, so a reason is required to take it back out'');
',
    '                 ''skipped_because'', ''work has already been done on this visit, so it stays in the queue whatever happens to the inclusion'');
');
  if v_expect_def = v_old_def then
    raise exception 'the remove reverse-patch changed nothing, so it proves nothing - the anchors did not match the live body';
  end if;
  v_new_def := pg_get_functiondef('public.remove_visits_from_review(bigint[],text)'::regprocedure);
  if v_new_def <> v_expect_def then
    raise exception 'remove_visits_from_review differs from the live body plus the four intended hunks (live % chars, expected % chars, new % chars)',
      length(v_old_def), length(v_expect_def), length(v_new_def);
  end if;

  ------------------------------- 6b. the include RPC, the same reverse-patch ------
  select def into v_old_def from _pre_fn where fn = 'include';
  v_expect_def := replace(v_old_def,
    'a reason is required - the next person to read this row has to know why a pre-convention visit was pulled into the queue',
    'a reason is required - the next person to read this row has to know why a visit from a closed job was pulled into the queue');
  if v_expect_def = v_old_def then
    raise exception 'the include reverse-patch changed nothing, so it proves nothing - the anchor did not match the live body';
  end if;
  v_new_def := pg_get_functiondef('public.include_visits_in_review(bigint[],text)'::regprocedure);
  if v_new_def <> v_expect_def then
    raise exception 'include_visits_in_review differs from the live body plus the one intended edit (live % chars, expected % chars, new % chars)',
      length(v_old_def), length(v_expect_def), length(v_new_def);
  end if;
  if v_new_def ilike '%pre-convention%' then
    raise exception 'include_visits_in_review still names the retired pre-convention rule';
  end if;

  ------------------------------------------- 7. every refusal actually fires -------
  -- All three are read-only: none of these arms writes, so no rollback probe is needed.
  select id into v_probe_id from public.visits_with_review
   where scope_source = 'open_job' and visit_status = 'completed' order by id limit 1;
  if v_probe_id is null then
    raise exception 'control failed: no open-job visit exists to test the refusal message';
  end if;
  v_res := public.remove_visits_from_review(array[v_probe_id]::bigint[], null);
  if (v_res->'results'->0->>'skipped_because') not like '%its job is open%' then
    raise exception 'an open-job visit was not refused with the new message: %', v_res->'results'->0;
  end if;

  select id into v_probe_id from public.visits_with_review
   where scope_source = 'work_started' and visit_status = 'completed' order by id limit 1;
  if v_probe_id is null then
    raise exception 'control failed: no work_started visit exists to test the refusal message';
  end if;
  v_res := public.remove_visits_from_review(array[v_probe_id]::bigint[], null);
  if (v_res->'results'->0->>'skipped_because') not like '%work has already been done on it, not because it was included%' then
    raise exception 'a work_started visit was not refused with the new message: %', v_res->'results'->0;
  end if;

  -- The collision arm: V-1542 is manual AND worked-on, so removal must be refused rather
  -- than reported as a success that leaves the card exactly where it was.
  v_res := public.remove_visits_from_review(array[1542]::bigint[], 'a reason, which must no longer be enough');
  if (v_res->>'removed')::int <> 0 then
    raise exception 'V-1542 was removed even though work has been done on it: %', v_res;
  end if;
  if (v_res->'results'->0->>'skipped_because') not like '%stays in the queue whatever happens to the inclusion%' then
    raise exception 'the worked-on refusal did not fire on V-1542: %', v_res->'results'->0;
  end if;
  if not (v_res->'results'->0->>'in_scope_now')::boolean then
    raise exception 'V-1542 fell out of scope during a refused removal';
  end if;
  if exists (select 1 from public.review_scope_inclusions
              where visit_id = 1542 and removed_at is not null) then
    raise exception 'the refused removal wrote a removed_at anyway';
  end if;

  -------------------------- 8. include -> remove still round-trips, then rolls back --
  -- On a FRESH subject, because V-1542 can no longer be removed. Anything out of scope
  -- under the new rule necessarily has no work started, so the one-click path applies.
  select w.id into v_subject from public.visits_with_review w
   where not w.in_review_scope and w.visit_status = 'completed'
     and not exists (select 1 from public.review_scope_inclusions i where i.visit_id = w.id)
   order by w.id limit 1;
  if v_subject is null then
    raise exception 'control failed: no out-of-scope visit exists to round-trip the include';
  end if;
  begin
    v_res := public.include_visits_in_review(array[v_subject]::bigint[], 'migration probe');
    if (v_res->>'included')::int <> 1 then
      raise exception 'the include path is broken for visit %: %', v_subject, v_res;
    end if;
    if (select scope_source from public.visits_with_review where id = v_subject) <> 'manual' then
      raise exception 'an included visit does not read scope_source = manual';
    end if;
    v_res := public.remove_visits_from_review(array[v_subject]::bigint[], null);
    if (v_res->>'removed')::int <> 1 then
      raise exception 'a freshly included, untouched visit could not be removed in one click: %', v_res;
    end if;
    if (v_res->'results'->0->>'in_scope_now')::boolean then
      raise exception 'a removed visit still reads in scope';
    end if;
    raise exception 'ROLLBACK_PROBE';
  exception when others then
    if sqlerrm <> 'ROLLBACK_PROBE' then raise; end if;
  end;

  if exists (select 1 from public.review_scope_inclusions where visit_id = v_subject) then
    raise exception 'the probe leaked: an inclusion row for visit % survived the rollback', v_subject;
  end if;

  ------------------------------------------------ 9. shape, grants, reachability --
  if (select column_name from information_schema.columns
       where table_schema='public' and table_name='visits_with_review' and ordinal_position=39) <> 'job_is_open' then
    raise exception 'job_is_open is not column 39 of visits_with_review';
  end if;
  if (select count(*) from information_schema.columns
       where table_schema='public' and table_name='visits_with_review') <> 39 then
    raise exception 'visits_with_review no longer has exactly 39 columns';
  end if;
  if (select column_name from information_schema.columns
       where table_schema='public' and table_name='v_review_scope_picker' and ordinal_position=14) <> 'job_is_open' then
    raise exception 'job_is_open is not column 14 of v_review_scope_picker';
  end if;

  -- create or replace keeps the ACL; a drop would have discarded it silently.
  if not has_table_privilege('authenticated','public.visits_with_review','SELECT')
     or not has_table_privilege('authenticated','public.v_review_scope_picker','SELECT')
     or not has_table_privilege('yannick_readonly','public.v_review_scope_picker','SELECT') then
    raise exception 'a SELECT grant was lost - the views were dropped rather than replaced';
  end if;
  if not has_function_privilege('authenticated','public.remove_visits_from_review(bigint[], text)','EXECUTE')
     or not has_function_privilege('authenticated','public.include_visits_in_review(bigint[], text)','EXECUTE') then
    raise exception 'authenticated lost EXECUTE on a scope RPC';
  end if;

  begin
    execute 'set local role authenticated';
    execute 'select count(*) from public.v_review_scope_picker where not in_review_scope' into v_authn;
    execute 'reset role';
  exception when others then
    execute 'reset role';
    raise exception 'authenticated cannot read the picker: % (%)', sqlerrm, sqlstate;
  end;
  if v_authn = 0 then
    raise exception 'the include modal would have nothing to offer: 0 completed visits are out of scope';
  end if;

  raise notice 'VERIFY OK: queue % -> % (% left, % joined); scope_source open_job % / work_started % / manual % / convention 0; both RPC bodies machine-checked; V-1542 bypass + precedence hold; picker offers % out-of-scope visits',
    v_queue_before, v_queue_after, v_left, v_joined, v_open, v_work, v_manual, v_authn;
end $$;

commit;
