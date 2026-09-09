-- ============================================================================
-- 2026-09-09_1330_remove_phantom_duplicate_visit_8050.sql
--
-- Removes the ONE live artefact of the visit create race. Runs AFTER _1200/_1230/_1300, because
-- cleaning before the source is fixed just makes room for the next one.
--
-- ⚠ SOFT DELETE, per rule 6. Nothing is hard-deleted.
-- ⚠ Backup taken first: backups/2026-09-09_phantom_visit_8050.json (gitignored). It holds the full
--   row, its twin, every dependent, and the 8 webhook_events_log rows from the collision second.
--
-- ============================================================================
-- WHAT THIS ROW IS
--
-- Visit 8050, La Granja 36th St (client 295), 2026-09-09 09:45 ET, visit_status='scheduled',
-- NO entity_source_links row. Created 2026-09-09 00:15:46.774661Z, **74 milliseconds** after visit
-- 8049, by the losing half of a double-delivered VISIT_CREATE:
--
--   20:15:46 ET  VISIT_CREATE  failed     ms=534   <- inserted 8050, then 23505 on idx_esl_source_id
--   20:15:47 ET  VISIT_CREATE  processed  ms=689   <- resolved to 8049, which holds the link
--
-- Both rows were inserted by webhook-jobber with app_source='jobber' and source='jobber' (per
-- audit.logs). 8049's source column reads 'visit-calendar' TODAY only because the office edited it
-- at 01:04:05Z, 48 minutes later.
--
-- 🛑 JOBBER HOLDS ONE VISIT, NOT TWO. Queried against the live Jobber API on 2026-09-09:
--   client Z2lkOi8vSm9iYmVyL0NsaWVudC8xMDAyMDYxNzg= -> job #99901095 -> ONE visit today,
--   2319988875 at 1:30 PM, which is our 8049. There is no 9:45 AM visit in Jobber.
-- So this is a purely local phantom and removing it makes our calendar agree with Jobber. It is not
-- a decision about what the crew should do.
--
-- ============================================================================
-- WHY IT COULD NOT SIT THERE HARMLESSLY
--
-- 8050 carries no Jobber link, and trg_push_visit_update has no source filter on its upsert path.
-- So the first time anyone moved or retimed it in the Visit Calendar, jobber-push-visit would call
-- jobberGid('visit', 8050), get NULL, and **CREATE it in Jobber for real** -- turning a local
-- phantom into an actual duplicate on the crew's Jobber schedule. jobber-push-visit's own linkVisit
-- comment names this hazard: "A silently-failed link leaves a LIVE Jobber visit unlinked -> the
-- next edit re-CREATEs a duplicate on the crew's schedule."
--
-- ============================================================================
-- WHY ONLY ONE ROW
--
-- Three alive visits carry source='jobber' with no jobber link. Only ONE is a race artefact:
--
--   id    created     status     title                                    verdict
--   5801  2026-06-16  cancelled  "110-CLA Claudie - Service Call [OLD]"    legacy, PRE-WEBHOOK
--   5818  2026-06-19  cancelled  "106-ALC A la Carte - pick up ... [OLD]"  legacy, PRE-WEBHOOK
--   8050  2026-09-09  scheduled  "La Granja 36th St - 032-LG - la granja"  THE RACE ARTEFACT
--
-- The first real Jobber webhook this system ever accepted arrived 2026-08-10, so a June row cannot
-- be a webhook race product. Both are cancelled and both are titled "[OLD]", i.e. deliberate legacy
-- cleanup. They are LEFT ALONE: removing rows because they resemble the thing being fixed is how a
-- cleanup migration destroys unrelated history.
--
-- The other race artefact, visit 7884 (2026-08-31 14:26:01, 13ms after 7883), was already
-- soft-deleted by hand on 2026-09-01 14:17. Nothing to do.
--
-- Audit: public.visits carries an audit trigger, so this UPDATE is recorded in audit.logs with its
-- full old row. The JSON backup is belt-and-braces.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- PRE-FLIGHT: refuse if the row is not exactly what this migration expects.
-- The world may have changed between the audit and the apply.
-- ---------------------------------------------------------------------------
do $pre$
declare
  v_n bigint;
begin
  select count(*) into v_n
    from public.visits v
   where v.id = 8050
     and v.deleted_at is null
     and v.source = 'jobber'
     and v.visit_status = 'scheduled'
     and v.client_id = 295
     and v.visit_date = date '2026-09-09'
     and not exists (select 1 from public.entity_source_links l
                      where l.entity_type = 'visit' and l.entity_id = 8050
                        and l.source_system = 'jobber');
  if v_n <> 1 then
    raise exception 'PRE-FLIGHT FAILED: visit 8050 is not the unlinked scheduled phantom this migration was written for (matched % rows). Re-audit before proceeding.', v_n;
  end if;

  -- Its twin must still exist, be alive, and hold the link. If 8049 were gone, deleting 8050 would
  -- remove the client's only record of today's visit.
  select count(*) into v_n
    from public.visits v
    join public.entity_source_links l
      on l.entity_type = 'visit' and l.entity_id = v.id and l.source_system = 'jobber'
   where v.id = 8049 and v.deleted_at is null
     and l.source_id = 'Z2lkOi8vSm9iYmVyL1Zpc2l0LzIzMTk5ODg4NzU=';
  if v_n <> 1 then
    raise exception 'PRE-FLIGHT FAILED: the linked twin 8049 is missing or unlinked. Deleting 8050 would leave the client with no visit today.';
  end if;

  -- No dependents that a soft delete would strand. line_items.visit_id and visit_team are the two
  -- that matter; both were 0 at audit time.
  select (select count(*) from public.line_items where visit_id = 8050)
       + (select count(*) from public.visit_team where visit_id = 8050)
       + (select count(*) from public.manifest_visits where visit_id = 8050)
    into v_n;
  if v_n <> 0 then
    raise exception 'PRE-FLIGHT FAILED: visit 8050 has % dependent row(s); it is no longer the empty shell that was audited', v_n;
  end if;

  raise notice 'PRE-FLIGHT ok: 8050 is the unlinked phantom, 8049 is alive and linked, 0 dependents';
end
$pre$;

-- ---------------------------------------------------------------------------
-- THE REMOVAL
-- ---------------------------------------------------------------------------
-- ⚠ Pinned to the id AND re-asserting the predicates that make it deletable, so it cannot fire if
--   the world changed between the pre-flight and here.
-- ⚠ `and deleted_at is null` also makes this idempotent: a re-run is a no-op rather than a second
--   retirement that overwrites when it actually happened.
--
-- 🛑 `skip_reason` IS DELIBERATELY NOT SET, THOUGH IT LOOKS LIKE THE OBVIOUS PLACE FOR THE REASON.
--    Measured: all 5 rows that carry it are `visit_status='skipped'`, none is deleted, and **0 of
--    the 50 already-soft-deleted source='jobber' visits carry one**. It is the SKIP vocabulary
--    ("Customer owns money. Aaron says skip service."), read by the skip-removal retry and by
--    unskip_visit. Writing a delete reason into it would invent a second meaning for a live column
--    on the strength of it being nearby. The reason lives in audit.logs (visits is audited, so the
--    full old row is captured), in this header, and in
--    backups/2026-09-09_phantom_visit_8050.json.
--
-- ⚠ THIS UPDATE DOES FIRE trg_push_visit_update, and that was checked rather than assumed. Its WHEN
--   clause has a source-independent disjunct `(old.deleted_at IS DISTINCT FROM new.deleted_at) AND
--   (new.deleted_at IS NOT NULL)`. fn_push_visit_to_jobber then computes v_op='delete' and, because
--   source is neither 'visit-calendar' nor 'supabase_cron', requires a request origin beginning
--   'http'. A Management API statement carries no request.headers, so v_origin is NULL and the
--   function RETURNs early. **No outbound Jobber call is enqueued.** That is also the correct
--   outcome on its own terms: there is nothing in Jobber to delete.
update public.visits
   set deleted_at = now()
 where id = 8050
   and deleted_at is null
   and source = 'jobber'
   and visit_status = 'scheduled'
   and not exists (select 1 from public.entity_source_links l
                    where l.entity_type = 'visit' and l.entity_id = 8050
                      and l.source_system = 'jobber');

commit;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
do $verify$
declare
  v_n bigint;
  v_d timestamptz;
begin
  -- 1. it is retired
  select deleted_at into v_d from public.visits where id = 8050;
  if v_d is null then
    raise exception 'VERIFY 1 FAILED: visit 8050 is still alive';
  end if;

  -- 2. the twin is untouched and still linked
  select count(*) into v_n
    from public.visits v
    join public.entity_source_links l
      on l.entity_type = 'visit' and l.entity_id = v.id and l.source_system = 'jobber'
   where v.id = 8049 and v.deleted_at is null;
  if v_n <> 1 then
    raise exception 'VERIFY 2 FAILED: the twin 8049 is no longer alive-and-linked';
  end if;

  -- 3. the client still has exactly one live visit today, and it is the linked one
  select count(*) into v_n
    from public.visits v
   where v.client_id = 295 and v.visit_date = date '2026-09-09' and v.deleted_at is null;
  if v_n <> 1 then
    raise exception 'VERIFY 3 FAILED: client 295 has % live visits on 2026-09-09, expected exactly 1', v_n;
  end if;

  -- 4. ⚠ UNSCOPED. Not "did 8050 go away" -- that can only confirm the change. This asserts the
  --    PROPERTY over the whole live population, then subtracts the two known legacy rows BY ID.
  --    A check shaped like the delete is the failure this estate has already paid for once.
  select count(*) into v_n
    from public.visits v
   where v.source = 'jobber'
     and v.deleted_at is null
     and v.id not in (5801, 5818)
     and not exists (select 1 from public.entity_source_links l
                      where l.entity_type = 'visit' and l.entity_id = v.id
                        and l.source_system = 'jobber');
  if v_n <> 0 then
    raise exception 'VERIFY 4 FAILED: % unlinked live jobber visit(s) remain beyond the two known legacy rows', v_n;
  end if;

  -- 5. POSITIVE ANCHOR for assertion 4. Without it, 4 would pass just as well against a query that
  --    matches nothing at all (a wrong column name, a typo'd source value).
  select count(*) into v_n
    from public.visits v
   where v.source = 'jobber' and v.deleted_at is null;
  if v_n < 100 then
    raise exception 'VERIFY 5 FAILED: only % live jobber visits exist; assertion 4 is an untested instrument', v_n;
  end if;

  -- 6. the two legacy rows are still ALIVE. This migration must not have touched them.
  select count(*) into v_n
    from public.visits where id in (5801, 5818) and deleted_at is null;
  if v_n <> 2 then
    raise exception 'VERIFY 6 FAILED: the two legacy [OLD] visits were modified; only % of 2 remain alive', v_n;
  end if;

  raise notice 'VERIFY ok: 8050 retired, 8049 alive and linked, client 295 has exactly 1 live visit today, 0 unlinked live jobber visits beyond the 2 legacy rows (anchor: % live jobber visits)',
               (select count(*) from public.visits where source = 'jobber' and deleted_at is null);
end
$verify$;
