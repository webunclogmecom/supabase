-- 2026-08-24_1215_gdo_correct_report_per_run.sql
--
-- WHAT: make a GDO report correction target ONE submission instead of "whatever the visit filed
--       most recently".
--         - public.fn_correct_gdo_report(visit_id, run_id, confirmation, failure)  <- NEW, targeted
--         - public.fn_correct_gdo_report(visit_id, confirmation, failure)          <- becomes a
--           HARD REFUSAL naming the new signature (rule: never leave a silently-wrong overload)
--
-- WHY (Fred, 2026-08-24, on visit 6617 / 043-MIL Mila, 1636 Meridian Avenue):
--       *"The `Our record` is not next to the image, so i don't [know] which `our record` belongs to
--       which one. And this is also a problem with others, is that i can't edit."*
--
-- 🛑 THE TWO COMPLAINTS ARE ONE BUG, AND THE UI WAS RIGHT TO REFUSE.
--       Everything the user sees is PER GDO PERMIT. `derm_portal_submissions` even carries `gdo_id`
--       and a unique `run_id` (measured: 11 live rows, 11 distinct run_ids, 0 null). But the old
--       correction function keyed on the VISIT and then picked a row by recency:
--
--           SELECT s.id FROM derm_portal_submissions s
--            WHERE s.visit_id = p_visit_id AND s.dry_run IS NOT TRUE
--            ORDER BY s.attempted_at DESC NULLS LAST, s.id DESC
--            LIMIT 1;
--
--       On visit 6617 that resolves to GDO-11024's failed attempt of 08-19 14:10, because it is the
--       newest. The SUCCESS the user is actually looking at belongs to GDO-14117 and was filed
--       08-07. **A correction typed into the GDO-14117 block would have silently landed on
--       GDO-11024's row.** The app therefore gated editing on `reportRows.length === 1`, which is why
--       every multi-permit visit is read-only. That gate was a correct guard around an ambiguous
--       function, not a UI oversight - do not simply remove it without this migration.
--
-- ⚠ KEYED ON `run_id`, NOT `gdo_id`, ON PURPOSE. A permit can have many attempts (GDO-11024 has 4),
--       and the user corrects the ONE row shown. `run_id` identifies exactly that row, and it is
--       already the key `fn_set_gdo_evidence_ext(visit_id, run_id, ext)` uses, so both write paths
--       now agree. `gdo_id` would still be ambiguous across a permit's attempts.
--
-- ⚠ THE OLD 3-ARG SIGNATURE IS REPLACED BY A RAISE, NOT DROPPED. This estate has been bitten three
--       times by a stale overload that kept "working" (client.create_property,
--       client.update_client_status). `update_client_status` set the precedent: the superseded arity
--       becomes a hard refusal naming its replacement, so a caller that misses the change fails
--       LOUDLY at the first call instead of writing to the wrong permit. Dropping it instead would
--       make PostgREST answer PGRST202 "function not found", which reads like a deploy problem
--       rather than a contract change.
--
-- ⚠ NOT CHANGED, deliberately:
--       - The success_confirmed CHECK still fires when a SUCCESS row's confirmation is emptied. That
--         rejection is the point and the app already translates it.
--       - Dry-run rows are still never corrected.
--       - `fn_set_gdo_evidence_ext` is untouched. It already accepts a row whose screenshot_path is
--         NULL and derives '<visit_id>/<run_id>.<ext>', and fn_is_gdo_evidence_path already permits
--         that path, so attaching evidence to a filing that has no photo needs NO database change.
--         The blocker there is client-side only and is fixed in the app.
--
-- AUDIT (ADR 010): public.derm_portal_submissions already carries its audit trigger; this migration
--       changes only functions, so no trigger work is required.

BEGIN;

SET LOCAL search_path = public;

-- ---------------------------------------------------------------------------
-- 1. the targeted correction
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_correct_gdo_report(
  p_visit_id            bigint,
  p_run_id              text,
  p_portal_confirmation text,
  p_failure_reason      text)
 RETURNS TABLE(visit_id bigint, run_id text, gdo_id bigint, status text,
               portal_confirmation text, failure_reason text,
               screenshot_path text, attempted_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_id bigint;
  v_n  integer;
BEGIN
  IF p_visit_id IS NULL THEN
    RAISE EXCEPTION 'visit id is required' USING ERRCODE = '22023';
  END IF;
  IF p_run_id IS NULL OR btrim(p_run_id) = '' THEN
    RAISE EXCEPTION 'run id is required: a visit can hold reports for several GDO permits, and without it the correction cannot say which one'
      USING ERRCODE = '22023';
  END IF;

  -- Exactly ONE live row. run_id is unique, so this cannot pick a neighbour the way the old
  -- ORDER BY attempted_at DESC LIMIT 1 could.
  SELECT s.id INTO v_id
    FROM public.derm_portal_submissions s
   WHERE s.visit_id = p_visit_id
     AND s.run_id   = p_run_id
     AND s.dry_run IS NOT TRUE;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'no live GDO report for visit % run % - nothing to correct', p_visit_id, p_run_id
      USING ERRCODE = '22023';
  END IF;

  -- Trim to NULL so an emptied box does not store ''. On a SUCCESS row this makes the existing
  -- success_confirmed CHECK fire (23514) rather than silently clearing the field that holds the
  -- visit out of the queue. That rejection is CORRECT and is the point.
  UPDATE public.derm_portal_submissions s
     SET portal_confirmation = NULLIF(btrim(coalesce(p_portal_confirmation, '')), ''),
         failure_reason      = NULLIF(btrim(coalesce(p_failure_reason, '')), '')
   WHERE s.id = v_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'expected to correct exactly 1 row, touched %', v_n USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  SELECT s.visit_id, s.run_id, s.gdo_id, s.status, s.portal_confirmation, s.failure_reason,
         s.screenshot_path, s.attempted_at
    FROM public.derm_portal_submissions s
   WHERE s.id = v_id;
END
$function$;

-- ---------------------------------------------------------------------------
-- 2. the superseded arity: refuse loudly, name the replacement
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_correct_gdo_report(
  p_visit_id            bigint,
  p_portal_confirmation text,
  p_failure_reason      text)
 RETURNS TABLE(visit_id bigint, status text, portal_confirmation text, failure_reason text,
               screenshot_path text, attempted_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  RAISE EXCEPTION 'a run id is now required: call fn_correct_gdo_report(visit_id, run_id, portal_confirmation, failure_reason). The 3-argument form corrected whichever submission was most recent for the visit, which is the wrong permit whenever a visit has more than one GDO.'
    USING ERRCODE = '22023';
END
$function$;

REVOKE ALL ON FUNCTION public.fn_correct_gdo_report(bigint, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_correct_gdo_report(bigint, text, text)       FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_correct_gdo_report(bigint, text, text, text)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.fn_correct_gdo_report(bigint, text, text)
  TO authenticated, service_role;

COMMIT;
