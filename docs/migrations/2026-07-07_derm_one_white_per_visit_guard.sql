-- 2026-07-07_derm_one_white_per_visit_guard.sql
-- Fred's invariant: ONE visit = ONE dump = ONE white_manifest_number.
-- A DERM visit page must never show 2+ manifest numbers (reported on 034-LG "La Granja
-- Calle 8", visit 4/20/2026, linked to both #822919 and #823469).
--
-- ROOT CAUSE (4-agent audit, adversarially CONFIRMED): nothing enforced a one-white#-per-visit
-- invariant, while THREE independent date-window auto-linkers each match a single visit to
-- MULTIPLE nearby dumps (dump/manifest dates lag the service date by a variable # of days, and a
-- client is often dumped twice within ~2 weeks, so >1 same-client derm_manifests row falls inside a
-- linker's window around one visit):
--   1. webhook-airtable DERM handler (functions/webhook-airtable/index.ts ~660-683): links every
--      completed GT visit within GT-Last-Visit +/-2 days; upsert onConflict:'manifest_id,visit_id'.
--      (This AT->manifest_visits path is now DORMANT: 0 writes in 30d; AT DERM automation retired 2026-06-26.)
--   2. scripts/sync/backfill_manifest_visits_via_at_visits_field.js: client+date +/-1 day matcher.
--   3. public.file_manifest RPC (DERM Tracker): INSERT ... ON CONFLICT (manifest_id,visit_id) DO NOTHING.
-- Every writer dedups ONLY on (manifest_id, visit_id) — never on "does this visit already carry a
-- DIFFERENT white#" — so the 2nd (different-white#) link is never blocked. The 2026-07-07
-- trg_aa_link_same_client (Supabase 2) only rejects CROSS-CLIENT links; all offenders here are
-- WITHIN-CLIENT, so it does not catch this class. This migration closes that gap.
--
-- DATA FIX (already applied 2026-07-07; backup backups/2026-07-07_manifest_visits_multiwhite_dedup.json):
-- Exactly 9 live visits were linked to 2 distinct white#s, ALL within-client. Kept the manifest whose
-- dump_ticket_date is the FIRST dump on/after the visit's service date; removed the other (each removal
-- FORCED: the wrong link's dump predates the service = physically impossible, or is a clearly later
-- dump owned by an identified sibling visit). Deleted (visit_id, manifest_id):
--   (1370,300)=815710  (1438,408)=817533  (1478,923)=000388  (1736,961)=823469  (1785,988)=823726
--   (3891,101)=822919  (3913,52)=822919   (3922,1016)=305031 (5089,1200)=306859
-- Post-fix: all 9 visits = 1 white#; fleet multi-manifest visits 9 -> 0.
-- (Follow-up, out of scope here: 3 removed manifests now orphaned (0 visits) — 815710, 000388/->v1454,
--  306859 — need re-link to their true owner visit; and m787/#444980 is co-linked to v1438+v1439 (both
--  177-PV 3/4) — verify second same-day visit vs over-attach.)
--
-- PERMANENT GUARD: BEFORE INSERT/UPDATE trigger keyed on DISTINCT white_manifest_number (NOT
-- manifest_id, NOT client_id). Verified live: blocks a 2nd different-white# link (tested: re-adding
-- (1736,961) RAISEs), ALLOWS same-white re-add / same-white sibling rows / consolidated dumps (1 white#
-- many client rows) / NULL-white# / soft-deleted manifests excluded. Orthogonal to and composes with
-- trg_aa_link_same_client (client-keyed) + trg_zz_card_from_link (AFTER; never runs when this aborts).
-- Coordinated with Supabase 2 (owner of the manifest_visits write lane) via WORKING-NOW.md.

CREATE OR REPLACE FUNCTION public.fn_manifest_visit_one_white()
RETURNS trigger LANGUAGE plpgsql AS $BODY$
DECLARE
  v_new_wm   text;   -- incoming manifest's white#
  v_other_wm text;   -- a DIFFERENT live white# already linked to this visit
  v_vcode    text;
BEGIN
  SELECT dm.white_manifest_number INTO v_new_wm
    FROM public.derm_manifests dm
   WHERE dm.id = NEW.manifest_id AND dm.deleted_at IS NULL;
  IF v_new_wm IS NULL THEN RETURN NEW; END IF;   -- unknown/absent white# => allow

  SELECT dm.white_manifest_number INTO v_other_wm
    FROM public.manifest_visits mv
    JOIN public.derm_manifests dm
      ON dm.id = mv.manifest_id AND dm.deleted_at IS NULL AND dm.white_manifest_number IS NOT NULL
   WHERE mv.visit_id = NEW.visit_id
     AND mv.manifest_id <> NEW.manifest_id          -- self-exclude => idempotent re-add ok
     AND dm.white_manifest_number <> v_new_wm        -- only a DIFFERENT white# is a violation
   LIMIT 1;
  IF v_other_wm IS NULL THEN RETURN NEW; END IF;     -- no conflicting white# => allow

  SELECT client_code INTO v_vcode FROM public.clients
   WHERE id = (SELECT client_id FROM public.visits WHERE id = NEW.visit_id);

  RAISE EXCEPTION USING errcode = 'P0001',
    message = format(
      'one-white-per-visit violated: visit %s (%s) is already linked to manifest # %s; refusing to also link manifest # %s (manifest_id %s). One visit = one dump = one white manifest number.',
      NEW.visit_id, coalesce(v_vcode, '?'), v_other_wm, v_new_wm, NEW.manifest_id),
    hint = 'If mis-linked, unlink the wrong manifest first (Stamp Studio unlink / DERM Tracker). If two nights were genuinely dumped, they are two separate visits, each linked to its own manifest number.';
END $BODY$;

DROP TRIGGER IF EXISTS trg_ab_link_one_white ON public.manifest_visits;
CREATE TRIGGER trg_ab_link_one_white
BEFORE INSERT OR UPDATE OF manifest_id, visit_id ON public.manifest_visits
FOR EACH ROW EXECUTE FUNCTION public.fn_manifest_visit_one_white();

-- Escape hatch (if a sanctioned multi-white link is ever needed): DROP TRIGGER trg_ab_link_one_white
-- ON public.manifest_visits; (document in WORKING-NOW). Filter multi-white pairs out of backup replays
-- (BEFORE fires before ON CONFLICT), same caveat as trg_aa_link_same_client.
