-- ============================================================================
-- 2026-10-15_0110 public.visit_audit_flags: visits an audit could not settle, waiting for a person
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-15, on the Samsara audit's open truck questions: "For 5 Flag them / For 6 flag them".
--   Decision 5 = four visits whose truck never went to the address but the replacement is thin (5732, 5814, 7299,
--   7319); decision 6 = three where two trucks stopped and the data cannot pick (3920, 7828, 1419). Nothing is changed
--   on those visits: a person decides.
-- WHY A TABLE (and not an existing one)
--   visit_sync_flags drives Jobber sync retries (auto_retry_state), and visit_reviews.quality_flag_note is Admin
--   Review's note about the crew's work. Neither means "the audit could not tell which truck or time is right".
-- DESIGN
--   One row per visit (PK visit_id), the plain-language question in `reason`, who raised it, and resolved_at /
--   resolved_note when a person answers. 3NF: every column depends on the visit's flag and nothing else.
--   Rule 8: audited (opt-in, a person resolves rows). service_role only: no app reads it yet; the HTML time-on-site
--   report (scripts/checks/time_on_site_report.mjs) lists the open ones. Revoked by name from anon/authenticated,
--   because Supabase's default privileges grant every new public table to both.
-- ROLLBACK: drop table public.visit_audit_flags (its rows are in audit.logs).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

CREATE TABLE public.visit_audit_flags (
  visit_id      bigint PRIMARY KEY REFERENCES public.visits(id),
  reason        text NOT NULL CHECK (btrim(reason) <> ''),
  raised_by     text NOT NULL CHECK (btrim(raised_by) <> ''),
  raised_at     timestamptz NOT NULL DEFAULT now(),
  resolved_at   timestamptz,
  resolved_note text,
  CHECK (resolved_at IS NULL OR btrim(coalesce(resolved_note, '')) <> '')
);
COMMENT ON TABLE public.visit_audit_flags IS
  'Visits an audit could not settle (which truck, which stay), waiting for a person. One row per visit; resolved_at + resolved_note when answered. service_role only. 2026-10-15 (Fred: "flag them").';
ALTER TABLE public.visit_audit_flags ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.visit_audit_flags FROM public, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.visit_audit_flags TO service_role;
CREATE TRIGGER audit_visit_audit_flags AFTER INSERT OR UPDATE OR DELETE ON public.visit_audit_flags
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

DO $s$ DECLARE v_hdr text := current_setting('request.headers', true); BEGIN
  PERFORM set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
    || jsonb_build_object('x-app-source', 'samsara-audit',
         'x-change-reason', 'Samsara audit 2026-10-15: questions the data cannot settle, flagged for a person (Fred: "flag them").'))::text, true);
  INSERT INTO public.visit_audit_flags (visit_id, reason, raised_by) VALUES
    (5732, 'Which truck? Cloggy (on the visit) never stopped there on Jun 3 (closest 343 m). The only truck parked near it was Moises, Jun 4 2:02 to 2:57 AM, 194 m from our map point. Check with the driver whether Moises did this cleaning.', 'samsara-audit 2026-10-15'),
    (5814, 'Which truck? Cloggy (on the visit) never stopped there on Jun 18 (closest 333 m). Moises parked there Jun 19 4:13 to 4:52 AM, but that stop belongs to visit 5812 (same client, same date). Check whether 5814 was done in the same stop or on another day.', 'samsara-audit 2026-10-15'),
    (7299, 'Which truck and which day? It was marked complete Jul 23 at 4:12 PM, the day BEFORE its date (Jul 24), with no truck within 1.7 km. The only stop there is David, Jul 25 8:52 to 9:25 AM, which belongs to visit 6993. Check whether this visit happened.', 'samsara-audit 2026-10-15'),
    (7319, 'Which truck? Cloggy (on the visit) never came within 3.3 km. David idled with the engine running 11 m from the address, Jul 24 11:54 AM to 12:01 PM, and it was marked complete at 12:15 PM. Only 6 minutes, so check with the driver before setting David.', 'samsara-audit 2026-10-15'),
    (3920, 'Which truck? Two trucks stopped there: Moises May 4 11:02 PM to 12:02 AM (61 min, on the visit), and Cloggy May 5 10:18 to 10:34 AM (16 min), when it was marked complete. Check which one did this cleaning.', 'samsara-audit 2026-10-15'),
    (7828, 'Which truck? Moises (on the visit) stopped twice (Aug 19 10:38 PM to 1:51 AM, and Aug 20 6:22 to 10:39 AM) and David once (Aug 20 3:09 to 3:56 PM, when it was marked complete). DERM-filed. Check which truck pumped it.', 'samsara-audit 2026-10-15'),
    (1419, 'Which truck? Cloggy (on the visit) stopped there Feb 25 1:36 to 1:42 PM, on the visit date; Moises stopped Feb 26 6:11 to 6:18 AM, when it was marked complete. Check which one did this cleaning.', 'samsara-audit 2026-10-15');
  PERFORM set_config('request.headers', coalesce(v_hdr, ''), true);
END $s$;

DO $v$ DECLARE n int; BEGIN
  IF (SELECT count(*) FROM public.visit_audit_flags WHERE resolved_at IS NULL) <> 7 THEN RAISE EXCEPTION 'VERIFY: expected 7 open flags'; END IF;
  SELECT count(*) INTO n FROM audit.logs WHERE table_name = 'visit_audit_flags' AND operation = 'INSERT' AND app_source = 'samsara-audit';
  IF n <> 7 THEN RAISE EXCEPTION 'VERIFY: % of 7 inserts audited', n; END IF;
  IF has_table_privilege('authenticated', 'public.visit_audit_flags', 'SELECT')
     OR has_table_privilege('anon', 'public.visit_audit_flags', 'SELECT')
     OR has_table_privilege('authenticated', 'public.visit_audit_flags', 'INSERT') THEN
    RAISE EXCEPTION 'VERIFY: anon/authenticated still hold a grant'; END IF;
  -- a resolved row needs a note
  BEGIN
    UPDATE public.visit_audit_flags SET resolved_at = now() WHERE visit_id = 5732;
    RAISE EXCEPTION 'VERIFY: resolving without a note was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
END $v$;

COMMIT;
