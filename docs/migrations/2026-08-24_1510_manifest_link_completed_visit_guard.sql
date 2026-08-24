-- 2026-08-24_1510_manifest_link_completed_visit_guard.sql
-- ---------------------------------------------------------------------------
-- Close what can be closed around ticket 830673 / visit 6756: a manifest link that
-- was LEGAL and CORRECT when written, and became a physical impossibility eight
-- days later, with nothing re-checking it.
--
-- trg_ac_link_visit_not_after_dump (2026-07-07) fires BEFORE INSERT OR UPDATE OF
-- (manifest_id, visit_id) ON public.manifest_visits. It reads TWO OTHER TABLES --
-- visits.visit_date and derm_manifests.dump_ticket_date -- but only ever runs when
-- manifest_visits is written. Either source can move afterwards and no path
-- re-evaluates the pair. It guards the LINK, not the INVARIANT.
--
-- WHAT ACTUALLY HAPPENED (audit.logs + public.notes, all timestamps ET):
--   2026-06-24 21:56  service-agreement-cron creates visit 6756 (175-PV) for 07-19.
--   2026-07-19 23:35  app_source 'jobber': visit marked COMPLETED, tap 07-20 03:33.
--   2026-07-20 04:41  Jobber note on visit 6756:
--                     "Couldn't compete the job because the PTO had broken".
--                     The pump drive failed. Nothing was actually collected -- but
--                     the visit was already flagged completed.
--   2026-07-22 13:40  contact@unclogme.com files ticket 830673 in DERM Tracker and
--                     links visit 6756 (manifest row 1628). The visit was dated
--                     07-19 AND MARKED COMPLETED, so every existing guard passed,
--                     and the filing was reasonable on the information available.
--   2026-07-29 13:46  jobber-daily-completion-reconcile REVERSES the completion:
--                     visit_status completed -> scheduled, completed_at -> NULL.
--                     Jobber was the source of truth: the job had not been done.
--                     *** THIS is the moment the link became false. ***
--   2026-07-29 21:34  contact@unclogme.com moves the visit 07-19 -> 07-29 in the
--                     Visit Calendar. Truthful: the job was re-run.
--   2026-07-30 06:05  re-completed, tap 06:02.
--   => pickup now sits 7 days AFTER its own offload, and it prints on Jonathan's
--      Miami-Dade LWT monthly filing via derm.v_lwt_monthly_rows -> rpa-derm-monthly.
--
-- ⚠ CORRECTION TO A TEMPTING BUT WRONG READING, recorded because the first pass of
--   this migration was written on it. Comparing the link timestamp to the visit's
--   CURRENT completed_at suggests "the link was made against a pending visit", and
--   that is FALSE. completed_at was rewritten twice; the value in the row today
--   (07-30) is the SECOND completion. Reconstructing visit_status from audit.logs
--   at the link instant shows the visit WAS completed on 2026-07-22. A guard
--   requiring completion at link time would NOT have stopped this. Any measurement
--   of "state at time T" taken from a mutable column is a measurement of now, not
--   of T -- rebuild it from the audit trail or do not claim it.
--
-- FULL AUDIT (read-only, before implementing):
--   * 690 live links. 543 have an audit-trail INSERT; of the 453 whose visit_status
--     at link time is reconstructable, 337 were completed, 1 was not, 115 have no
--     prior audit row and are unknowable. The single non-completed one is visit 7278
--     (112-YA, linked 2026-07-20 while 'scheduled', manifest 1418 which has no
--     ticket number and no dump date) and that link no longer exists.
--   * 0 of the 690 current links sit on a non-completed visit, so trg_ad below
--     rejects nothing that exists.
--   * A LINKED VISIT HAS BEEN UN-COMPLETED 7 TIMES, ACROSS 4 VISITS, AND EVERY ONE
--     WAS AUTOMATED: visit-calendar 5 times on visits 3910/3916 (2026-05-27, both
--     re-completed on the same date, so no violation), and
--     jobber-daily-completion-reconcile twice -- visit 6756 (this one) and visit
--     7090 (112-YA, 2026-07-30, now 'skipped' AND ALREADY UNLINKED BY HAND).
--     7090 is the precedent: when a linked visit turns out not to have happened,
--     the link is what gets removed.
--   * Manifest side: dump_ticket_date has changed 195 times, 98 of them EARLIER,
--     across 24 manifests, 204 of those on manifests that carry links today. Sole
--     writer derm-tracker (188), last change 2026-07-03 -- before trg_ac existed.
--   * NULL-dump hole: trg_ac deliberately passes when dump_ticket_date IS NULL.
--     4 manifests have gone NULL -> value and 2 links were made before their dump
--     date was known. None violate today, but nothing re-checks them.
--
-- DESIGN -- and the important part is what this migration deliberately does NOT do:
--
--   * NO BLOCKING TRIGGER ON public.visits. Three independent reasons:
--     (a) THE WRITER IS A RECONCILER RECORDING THE TRUTH. What broke this link was
--         jobber-daily-completion-reconcile discovering the job had not been done.
--         Blocking it would force the database to keep asserting a service that
--         never happened. The reconciler is right; the link is wrong.
--     (b) IT IS AUTOMATED AND CANNOT READ AN ERROR. A RAISE there aborts a cron,
--         and it would fail into public.sync_log, which NOTHING READS (below).
--     (c) Automated writers also move visit_date on already-completed visits --
--         jobber-daily-completion-reconcile 6 times through 2026-08-05, jobber 2
--         times through 2026-07-22, sql 182 times -- and links live on completed
--         visits, so the intersection is not empty.
--     For the record, a block on visit_date would have fired exactly once ever via
--     an app path (6756, visit-calendar, 2026-07-29), and that once it would have
--     been wrong.
--
--   * trg_ad BELOW IS DEFENCE IN DEPTH, NOT THE FIX FOR 6756. Stated plainly so
--     nobody reads this migration and believes the case is closed by a trigger.
--     A link against a visit that has not happened is still a real impossibility
--     worth forbidding, it costs nothing (0 of 690), and derm.v_stamp_row_candidate_
--     visits ALREADY requires visit_status='completed' when offering candidates --
--     so this enforces at the WRITE what the Stamp Studio read path has always
--     assumed and what the DERM Tracker filing path (public.file_manifest,
--     derm.file_manifest_and_link, public.file_manifest_on_shared_ticket,
--     derm.link_row_visit) never applied.
--
--   * trg_ae DOES guard the manifest side, because there the writer is an
--     interactive app that can show an error, and the path is demonstrably active
--     (98 backward moves). It also closes the NULL -> value hole, since that is an
--     UPDATE OF dump_ticket_date.
--
--   * THE DETECTOR CARRIES THE REST, and it covers BOTH conflict shapes:
--       pickup_after_offload  - the date-based one (finds 6756 today)
--       visit_not_completed   - the status-based one, which is the 6756 class caught
--                               at its TRUE moment, hours before the date even moved
--     A date-only detector would have stayed silent from 13:46 to 21:34 on 07-29
--     while the link was already false.
--
-- ⚠ WHY THE DETECTOR IS A VIEW AND NOT ANOTHER sync_log HEALTH CHECK.
--   The house pattern is v_<x>_health + log_<x>_health() + a cron INSERTing into
--   public.sync_log with status 'attention'. Measured 2026-08-24: NOTHING CONSUMES
--   public.sync_log. Swept every file in the workspace against a positive control;
--   every hit is a doc, a migration, or a WRITER. Three health checks are sitting in
--   'attention' right now and no human is being told:
--     calendar-push-health   49 attention days since 2026-06-27 (NOT consecutive - it has
--                             also gone 'ok' 10 times; longest run 29 days, current run 6)
--     rpa-derm-health        26 consecutive 'ok', then 10 consecutive 'attention' from
--                             2026-08-15 - a datable regime change, not noise
--     blackout-health         6 attention days since 2026-08-19, one sheet blocked ~7d
--   ⚠ CORRECTED 2026-08-24: I first wrote that this meant "10 clients seeing an EMPTY
--     eManifest", quoting the alarm's own what_it_means text. BOTH HALVES ARE WRONG.
--     The card is not empty - it renders "DERM FOG eManifest / DERM 833049 / DOCUMENTED
--     / On file, not available for online viewing", which is exactly what Field Portal
--     rule 8 prescribes when a document NUMBER exists but no viewable file. And it is
--     22 work orders across 22 clients, not 10: derm.v_blackout_blocked_sheets filters
--     stamp_y_pct IS NOT NULL, so it is blind to UNSTAMPED sheets and misses tickets
--     312024 (9) and 833530 (3). The customer-impact measure is
--       select count(*) from customer.work_orders
--        where derm_manifest_number is not null and derm_manifest_url is null;   -> 22
--     The blocked-sheets view measures stamped-but-unmeasured sheets. It is not a
--     measure of customer impact and must not be read as one.
--   ⚠ CORRECTED 2026-08-24: an earlier version of this header said calendar-push-health had
--     been in attention "continuously" since 2026-06-27. It has not. That came from reading
--     min(started_at) over the attention rows as if it were the start of an unbroken run.
--     min() of a filtered set is not a run length - measure runs with a gaps-and-islands
--     query, not with min/max.
--   Adding a fifth alarm to an unread queue is not a fix. This migration creates the
--   instrument; SURFACING it belongs where a human already looks -- the
--   rpa-derm-monthly response, so John cannot file blind. That is a separate,
--   app-facing change and is documented as the next step rather than smuggled in here.
--
-- Restore/backfill gotcha, same as trg_ac and the cross-client guard: replaying a
--   backup that links a not-yet-completed visit, or that lowers a dump date under an
--   existing link, now RAISEs. Filter those out or apply with the triggers disabled,
--   then re-run the VERIFY block.
--
-- Audit (Rule 8): triggers and one view only. No column added, changed or dropped on
-- any audited table, so audit_manifest_visits / audit_derm_manifests / audit_visits
-- are unaffected and no audit opt-in list changes.
--
-- Grants: derm.v_manifest_link_date_conflicts is service_role only, matching
-- derm.v_lwt_monthly_rows. It carries client codes and service dates and has no
-- business reaching anon or authenticated.
--
-- @Building Apps. Claimed in WORKING-NOW.md. No Lovable project touched. The DERM
-- Tracker claim held by @Supabase is app-only and does not overlap. Remediation of
-- the one existing violation is a SEPARATE migration (2026-08-24_1520).

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Link side (defence in depth): a visit that has not happened cannot have
--    supplied grease. Does NOT close the 6756 case -- see the header.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_manifest_visit_completed()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE v_status text; v_date date; v_cid bigint; v_code text; v_wm text; v_dump date;
BEGIN
  SELECT v.visit_status, v.visit_date, v.client_id
    INTO v_status, v_date, v_cid
    FROM public.visits v WHERE v.id = NEW.visit_id;

  IF v_status IS NULL THEN RETURN NEW; END IF;   -- visit missing: trg_aa/trg_ac speak to that
  IF v_status = 'completed' THEN RETURN NEW; END IF;

  SELECT client_code INTO v_code FROM public.clients WHERE id = v_cid;
  SELECT coalesce(dm.white_manifest_number, dm.yellow_ticket_number), dm.dump_ticket_date
    INTO v_wm, v_dump
    FROM public.derm_manifests dm WHERE dm.id = NEW.manifest_id;

  RAISE EXCEPTION USING
    errcode = 'P0001',
    message = format(
      'link rejected: visit %s (%s, scheduled %s) is %s, not completed - grease that was never pumped cannot be on ticket %s, dumped %s',
      NEW.visit_id, coalesce(v_code, v_cid::text), v_date, upper(v_status),
      coalesce(v_wm, '?'), coalesce(v_dump::text, 'unknown')),
    hint = 'Wait until the visit is completed, then link it. If the service did not happen (broken pump, no access, cancelled), that client did not supply this load and does not belong on this ticket.';
END $fn$;

DROP TRIGGER IF EXISTS trg_ad_link_visit_completed ON public.manifest_visits;
CREATE TRIGGER trg_ad_link_visit_completed
BEFORE INSERT OR UPDATE OF manifest_id, visit_id ON public.manifest_visits
FOR EACH ROW EXECUTE FUNCTION public.fn_manifest_visit_completed();

-- ---------------------------------------------------------------------------
-- 2. Manifest side: moving a dump date must not strand its own links.
--    Covers dump_ticket_date moving EARLIER *and* NULL -> value, which trg_ac
--    deliberately let through.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_manifest_dump_date_keeps_links_valid()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE v_n int; v_visit bigint; v_vdate date; v_code text;
BEGIN
  IF NEW.dump_ticket_date IS NULL THEN RETURN NEW; END IF;
  IF NEW.dump_ticket_date IS NOT DISTINCT FROM OLD.dump_ticket_date THEN RETURN NEW; END IF;

  SELECT count(*) INTO v_n
    FROM public.manifest_visits mv
    JOIN public.visits v ON v.id = mv.visit_id
   WHERE mv.manifest_id = NEW.id
     AND v.visit_date > NEW.dump_ticket_date + 1;

  IF v_n = 0 THEN RETURN NEW; END IF;

  SELECT v.id, v.visit_date, c.client_code
    INTO v_visit, v_vdate, v_code
    FROM public.manifest_visits mv
    JOIN public.visits v ON v.id = mv.visit_id
    LEFT JOIN public.clients c ON c.id = v.client_id
   WHERE mv.manifest_id = NEW.id
     AND v.visit_date > NEW.dump_ticket_date + 1
   ORDER BY v.visit_date DESC LIMIT 1;

  RAISE EXCEPTION USING
    errcode = 'P0001',
    message = format(
      'dump date rejected: moving ticket %s to %s would strand %s linked visit(s) - e.g. visit %s (%s) serviced %s, which is after the new dump date',
      coalesce(NEW.white_manifest_number, NEW.yellow_ticket_number, NEW.id::text),
      NEW.dump_ticket_date, v_n, v_visit, coalesce(v_code, '?'), v_vdate),
    hint = 'Unlink the visits that postdate the corrected dump date first, then change the date. They belong on a later ticket.';
END $fn$;

DROP TRIGGER IF EXISTS trg_ae_dump_date_keeps_links_valid ON public.derm_manifests;
CREATE TRIGGER trg_ae_dump_date_keeps_links_valid
BEFORE UPDATE OF dump_ticket_date ON public.derm_manifests
FOR EACH ROW EXECUTE FUNCTION public.fn_manifest_dump_date_keeps_links_valid();

-- ---------------------------------------------------------------------------
-- 3. The detector. Guards only cover writes from here on; this sees the STATE,
--    and it is the only thing that covers the un-completion path at all.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW derm.v_manifest_link_date_conflicts AS
SELECT
  mv.manifest_id,
  mv.visit_id,
  coalesce(m.white_manifest_number, m.yellow_ticket_number)      AS ticket_number,
  CASE WHEN m.white_manifest_number IS NOT NULL
       THEN 'white' ELSE 'yellow' END                            AS ticket_kind,
  m.dump_ticket_date                                             AS offload_date,
  v.visit_date                                                   AS pickup_date,
  (v.visit_date - m.dump_ticket_date)                            AS days_after_offload,
  v.visit_status,
  v.completed_at,
  c.client_code,
  c.name                                                         AS client_name,
  -- WHICH impossibility. A link can carry both.
  CASE
    WHEN v.visit_status IS DISTINCT FROM 'completed'
         AND m.dump_ticket_date IS NOT NULL
         AND v.visit_date > m.dump_ticket_date          THEN 'both'
    WHEN v.visit_status IS DISTINCT FROM 'completed'    THEN 'visit_not_completed'
    ELSE                                                     'pickup_after_offload'
  END                                                            AS conflict_kind,
  -- true  = trg_ac_link_visit_not_after_dump would REJECT this pair today
  -- false = it sits inside the +1-day grace, or the conflict is status-only
  (m.dump_ticket_date IS NOT NULL
     AND v.visit_date > m.dump_ticket_date + 1)                  AS violates_guard,
  -- does this row print on a Miami-Dade LWT monthly filing?
  (m.white_manifest_number IS NOT NULL
     OR coalesce(p.county = 'Dade', false))                      AS on_lwt_report
FROM public.manifest_visits mv
JOIN public.derm_manifests m  ON m.id = mv.manifest_id AND m.deleted_at IS NULL
JOIN public.visits v          ON v.id = mv.visit_id    AND v.deleted_at IS NULL
LEFT JOIN public.clients c    ON c.id = v.client_id
LEFT JOIN public.properties p ON p.id = v.property_id
WHERE
  -- the pickup is dated after its own offload
  (m.dump_ticket_date IS NOT NULL AND v.visit_date > m.dump_ticket_date)
  -- or the service this link claims supplied the load did not happen
  OR v.visit_status IS DISTINCT FROM 'completed';

COMMENT ON VIEW derm.v_manifest_link_date_conflicts IS
  'Manifest links that assert something physically impossible. conflict_kind pickup_after_offload = the visit is dated after the load was dumped (grease is pumped before it is dumped); visit_not_completed = the link claims a service that is not marked completed, which is how ticket 830673 / visit 6756 broke when jobber-daily-completion-reconcile reversed a completion on 2026-07-29. violates_guard=true means trg_ac_link_visit_not_after_dump would reject the pair today; false means it sits inside the +1-day grace or the conflict is status-only. These rows reach the Miami-Dade LWT monthly filing through derm.v_lwt_monthly_rows and are deliberately NOT clamped or hidden there - silently correcting a compliance date is worse than printing an odd one. Added 2026-08-24 with trg_ad_link_visit_completed and trg_ae_dump_date_keeps_links_valid.';

REVOKE ALL ON derm.v_manifest_link_date_conflicts FROM PUBLIC;
REVOKE ALL ON derm.v_manifest_link_date_conflicts FROM anon, authenticated;
GRANT SELECT ON derm.v_manifest_link_date_conflicts TO service_role;

COMMIT;

-- VERIFY (run after applying; every assertion must hold)
--
-- 1. all three objects exist and are attached to the right tables
--    select t.tgname, c.relname from pg_trigger t join pg_class c on c.oid=t.tgrelid
--     where t.tgname in ('trg_ad_link_visit_completed','trg_ae_dump_date_keeps_links_valid');
--    -- expect trg_ad on manifest_visits, trg_ae on derm_manifests
--
-- 2. THE GUARD REJECTS NOTHING THAT EXISTS. If this is not 0, an existing link
--    would fail its next update.
--    select count(*) from public.manifest_visits mv join public.visits v on v.id=mv.visit_id
--     where v.visit_status <> 'completed';
--    -- expect 0
--
-- 3. POSITIVE CONTROL, so the 0 above is not a broken instrument: the detector must
--    SEE the four known conflicts, and classify them.
--    select conflict_kind, violates_guard, count(*) from derm.v_manifest_link_date_conflicts
--     group by 1,2 order by 1;
--    -- expect pickup_after_offload / false / 3   (visits 1265, 1496, 3942, all +1 day)
--    --        pickup_after_offload / true  / 1   (visit 6756, +7 days)
--    -- after 2026-08-24_1520 the true/1 row is gone and only the three remain
--
-- 4. MUTATION TEST the guard rather than trusting it fires. Both blocks must RAISE.
--    do $$ begin
--      insert into public.manifest_visits(manifest_id, visit_id)
--      select 1418, 7278;                       -- 112-YA, visit_status 'scheduled'
--      raise exception 'FAIL: trg_ad did not fire';
--    exception when others then
--      if sqlerrm like 'FAIL:%' then raise; end if;
--      raise notice 'trg_ad OK: %', sqlerrm;
--    end $$;
--    -- and the manifest side, on a manifest that has links:
--    do $$ declare v_m bigint; begin
--      select mv.manifest_id into v_m from public.manifest_visits mv
--        join public.visits v on v.id=mv.visit_id
--        join public.derm_manifests m on m.id=mv.manifest_id
--       where m.dump_ticket_date is not null order by v.visit_date desc limit 1;
--      update public.derm_manifests set dump_ticket_date = '2020-01-01' where id = v_m;
--      raise exception 'FAIL: trg_ae did not fire';
--    exception when others then
--      if sqlerrm like 'FAIL:%' then raise; end if;
--      raise notice 'trg_ae OK: %', sqlerrm;
--    end $$;
--    -- ⚠ BOTH blocks swallow their own exception, so NOTHING is committed. Do not
--    --   rewrite them to run the statement bare "just to see": the insert would
--    --   stick and the update would rewrite a real dump date.
--
-- 5. grants are service_role only
--    select grantee, privilege_type from information_schema.role_table_grants
--     where table_schema='derm' and table_name='v_manifest_link_date_conflicts';
--    -- expect service_role / SELECT only; no anon, no authenticated
