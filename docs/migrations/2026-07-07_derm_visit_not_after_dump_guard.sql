-- 2026-07-07_derm_visit_not_after_dump_guard.sql
-- Fred: after unlinking the 6 over-attached visits (service AFTER the ticket's
-- dump), add a guard so the class can't re-enter — reject a new link whose visit
-- postdates the manifest's dump. Grease is pumped BEFORE the dump, so a visit
-- dated after the dump cannot be on that load (the old fuzzy-linker's over-attach
-- of a client's NEXT visit).
--
-- FULL AUDIT (read-only, before implementing):
--   * Fleet lag dump→visit: of 522 live links, 517 are visit ON/BEFORE dump, 0 have
--     a NULL dump date, and only 5 are visit-AFTER-dump: three +1 day, one +3, one
--     +10 — all pre-audit-trail rows (app_source NULL), no active writer makes them.
--   * The 6 just-unlinked disease cases were +3..+9 days.
--   * Writers of manifest_visits: derm.link_row_visit, derm.file_manifest_and_link
--     (+ add_client_card_and_link), public.file_manifest, public.file_manifest_on_shared_ticket,
--     plus direct DERM Tracker / Stamp / script inserts. NO replay-loop risk from a RAISE:
--     (a) the only AT-side writer is a DORMANT fuzzy linker in webhook-airtable
--     handleDermRecord (index.ts ~678, Path B) — the AT→DERM automation is retired,
--     DERM Tracker is the sole LIVE writer (DB: 0 inserts in 30d, last NULL-source
--     insert 2026-05-23); AND (b) that upsert never checks .error/.throwOnError(), so a
--     trigger RAISE returns an ignored PostgREST error object — no JS throw, no 500, no
--     Airtable retry. (Follow-up, separate task: delete that dead block so the invariant
--     is true in code, not just dormant — different edge fn, coordinate on its own.)
--
-- DESIGN — reject visit_date > dump_ticket_date + 1 day:
--   * NULL dump_ticket_date PASSES (fill-later workflow; the inherit trigger fills it).
--   * +1-day GRACE absorbs (a) generic 1-day dump-ticket data-entry noise and (b) the
--     exactly-06:00-ET operating-date cutoff boundary (e.g. visit 3942, a 06:00 service).
--     NOTE: the strictly-overnight early-AM class (00:00:01-05:59 ET) is pulled to the
--     PRIOR night, moving visit_date EARLIER — it never lags the dump, so "overnight" is
--     NOT the reason for the grace. This still catches 100% of the real disease (+3..+9);
--     strict >0 was rejected (false-positive risk on the 06:00 boundary + 1-day entry
--     noise), +2 rejected (no legit +2 exists, only erodes margin below the +3 disease floor).
--   * Fires on INSERT and UPDATE OF (manifest_id, visit_id), like trg_aa_link_same_client
--     / trg_ab_link_one_white. Composes cleanly (each BEFORE trigger validates independently;
--     a RAISE means no row + no audit row). NOTE on effective tolerance by path: the two
--     CREATE-and-link RPCs (file_manifest_and_link, file_manifest_on_shared_ticket) file the
--     manifest first, where the STRICTER CHECK derm_manifests_service_before_dump_chk
--     (service_date <= dump_ticket_date, 0-day) fires — so a dump+1 sibling via those paths
--     is rejected by the CHECK, not trg_ac (net stricter, safe). public.file_manifest is
--     ATOMIC: one visit dated > dump+1 in the batch aborts the whole filing (fail-loud, intended).
--   * EXISTING 5 violators are untouched (guard fires on write only) — they stay
--     flagged for paper-ticket review.
--
-- ⚠ Restore/backfill gotcha (same as the cross-client guard): replaying a backup
-- containing a visit-more-than-1-day-after-dump pair now RAISES — filter those out.
--
-- Audit (Rule 8): trigger only, no column change; audit_manifest_visits unaffected.
-- @Supabase (session 1): 3rd BEFORE guard on the shared public.manifest_visits;
-- validate-and-raise only, writes nothing. Composes with your trg_ab_link_one_white.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_manifest_visit_not_after_dump()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_dump date; v_wm text; v_vdate date; v_vcid bigint; v_code text;
BEGIN
  SELECT dm.dump_ticket_date, dm.white_manifest_number INTO v_dump, v_wm
    FROM public.derm_manifests dm WHERE dm.id = NEW.manifest_id;
  IF v_dump IS NULL THEN RETURN NEW; END IF;               -- dump unknown -> allow

  SELECT v.visit_date, v.client_id INTO v_vdate, v_vcid
    FROM public.visits v WHERE v.id = NEW.visit_id;
  IF v_vdate IS NULL THEN RETURN NEW; END IF;

  IF v_vdate > v_dump + 1 THEN                              -- +1 day grace
    SELECT client_code INTO v_code FROM public.clients WHERE id = v_vcid;
    RAISE EXCEPTION USING
      errcode = 'P0001',
      message = format(
        'link rejected: visit %s (%s, serviced %s) is dated after ticket %s''s dump %s — grease is pumped before the dump, so this visit cannot be on that load',
        NEW.visit_id, coalesce(v_code, v_vcid::text), v_vdate, coalesce(v_wm, '?'), v_dump),
      hint = 'Link this visit to the client''s manifest on a LATER ticket (the first dump on/after the service date), or file that manifest.';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_ac_link_visit_not_after_dump ON public.manifest_visits;
CREATE TRIGGER trg_ac_link_visit_not_after_dump
BEFORE INSERT OR UPDATE OF manifest_id, visit_id ON public.manifest_visits
FOR EACH ROW EXECUTE FUNCTION public.fn_manifest_visit_not_after_dump();

COMMIT;
