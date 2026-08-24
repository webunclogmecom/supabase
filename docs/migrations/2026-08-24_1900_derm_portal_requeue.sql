-- 2026-08-24_1900_derm_portal_requeue.sql
-- ---------------------------------------------------------------------------
-- Let an operator re-open the DERM portal queue explicitly, instead of poking a
-- timestamp and hoping.
--
-- Fred: "yes build the requeue function."
--
-- THE PROBLEM, and it cost three days on 2026-08-24. v_derm_portal_queue's third gate
-- refuses to retry a non-retryable failure until something about the row CHANGES, and
-- its freshness anchor is `f.updated_at` -- a DATABASE timestamp. Jonathan fixed the
-- portal credential for GDO-11024 at the COUNTY. That is structurally invisible here,
-- so the gate stayed shut, his digests read "queue empty" on the 21st, 22nd and 23rd,
-- and no amount of hourly polling could ever have brought the row back. Un-parking it
-- meant running `update derm_manifests set updated_at = now()`, which works but is a
-- side effect standing in for an intention, leaves no reason, and names nobody.
--
-- ⚠ ANY fix made outside this database has that property. This is not a one-off.
--
-- THE FIX: a second anchor that means "a human decided to retry this, here is why".
--   gate 3 becomes  s.created_at > GREATEST(f.updated_at, <latest requeue marker>)
-- so a marker newer than the last failure re-opens the gate, and nothing else changes.
--
-- 🛑 IT RELAXES GATE 3 AND ONLY GATE 3. A requeue must NOT bypass:
--     gate 1  already SUCCESS / has a portal_confirmation  -- never re-file a filed report
--     gate 2  the 20h cooldown                             -- never hammer the portal
--     gate 4  a live dispense lease                        -- never double-serve a manifest
--   Those exist for different reasons and an operator saying "try again" is not a reason
--   to defeat any of them. Verified below by asserting the queue does not widen.
--
-- 🛑 SELF-LIMITING BY CONSTRUCTION, WHICH IS WHY THERE IS NO EXPIRY. A fresh attempt
--   writes a submission with created_at > requeued_at, so the gate closes again on its
--   own the moment the retry fails. A requeue buys exactly one more pass, not a
--   permanent exemption. Do not "improve" this into a flag that stays on.
--
-- ⚠ THE RPC RETURNS THE POST-CONDITION, NOT "OK". A requeue that inserts a row and
--   changes nothing is the worst outcome: the operator believes they acted. So it
--   re-reads the queue afterwards and, if the row is STILL absent, says WHICH gate is
--   holding it. "No false success" applies to a queue exactly as it does to a Jobber write.
--
-- Audit (Rule 8): one NEW table, public.derm_portal_requeue. It is an append-only
-- record of operator intent and is deliberately NOT audited -- the table IS the audit
-- trail (who, when, why), and an audit trigger would duplicate every row for no gain.
-- Explicit opt-OUT, recorded so the next sweep does not read the absence as an oversight.
--
-- ⚠ public.v_rpa_derm_health DEPENDS on v_derm_portal_queue (it is queue_depth), and
--   fn_record_manual_gdo_report + fn_resolve_rpa_permit reference it. The COLUMN LIST is
--   unchanged, so CREATE OR REPLACE works and no grant is lost. If you ever change the
--   columns this becomes drop-and-recreate, and DROP VIEW discards grants.
--
-- @Building Apps. Claimed in WORKING-NOW.md.

BEGIN;

CREATE TABLE IF NOT EXISTS public.derm_portal_requeue (
  id           bigserial   PRIMARY KEY,
  manifest_id  bigint      NOT NULL REFERENCES public.derm_manifests(id),
  -- NULL means every permit on this manifest. Kept deliberately: a manifest-wide
  -- re-open is occasionally what you want, and NULL is how gate 3 already spells
  -- "applies to any gdo_id".
  gdo_id       bigint,
  requeued_at  timestamptz NOT NULL DEFAULT now(),
  reason       text        NOT NULL,
  requested_by text
);

COMMENT ON TABLE public.derm_portal_requeue IS
  'Append-only record of an operator deciding to retry a DERM portal filing that gate 3 of v_derm_portal_queue is holding. Exists because that gate re-opens only when a DATABASE timestamp moves, so a fix made at the county (a portal credential, a permit registration) is structurally invisible to it. Self-limiting: a fresh failure lands with created_at > requeued_at and the gate closes again, so a requeue buys one more pass and never a standing exemption. Added 2026-08-24 after GDO-11024 sat excluded for three days.';

CREATE INDEX IF NOT EXISTS derm_portal_requeue_lookup_idx
  ON public.derm_portal_requeue (manifest_id, gdo_id, requeued_at DESC);

REVOKE ALL ON public.derm_portal_requeue FROM PUBLIC;
REVOKE ALL ON public.derm_portal_requeue FROM anon, authenticated;
GRANT SELECT, INSERT ON public.derm_portal_requeue TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.derm_portal_requeue_id_seq TO service_role;

-- ---------------------------------------------------------------------------
-- Gate 3 gains a second anchor. Everything else in this view is byte-identical to
-- what was live on 2026-08-24; it was produced by substituting exactly one clause
-- into pg_get_viewdef output rather than retyped, so no other gate could drift.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_derm_portal_queue AS
 SELECT DISTINCT ON (manifest_id) visit_id,
    visit_date,
    client_id,
    client_code,
    client_name,
    client_email,
    address,
    city,
    zip,
    county,
    gdo_number,
    manifest_id,
    white_manifest_number,
    dump_ticket_date,
    disposal_facility,
    derm_address_url,
    derm_address_extra_urls,
    derm_manifest_url,
    derm_manifest_extra_urls,
    updated_at,
    linked_at,
    ticket_number,
    jurisdiction,
    gdo_id
   FROM v_derm_portal_fields f
  WHERE visit_date >= rpa_launch_cutoff() AND NOT (EXISTS ( SELECT 1
           FROM derm_portal_submissions s
             JOIN manifest_visits smv ON smv.visit_id = s.visit_id
          WHERE smv.manifest_id = f.manifest_id AND NOT s.dry_run AND (s.gdo_id IS NULL OR NOT s.gdo_id IS DISTINCT FROM f.gdo_id) AND (s.status = 'SUCCESS'::text OR s.portal_confirmation IS NOT NULL))) AND NOT (EXISTS ( SELECT 1
           FROM derm_portal_submissions s
             JOIN manifest_visits smv ON smv.visit_id = s.visit_id
          WHERE smv.manifest_id = f.manifest_id AND NOT s.dry_run AND (s.gdo_id IS NULL OR NOT s.gdo_id IS DISTINCT FROM f.gdo_id) AND s.created_at > (now() - '20:00:00'::interval))) AND NOT (EXISTS ( SELECT 1
           FROM derm_portal_submissions s
             JOIN manifest_visits smv ON smv.visit_id = s.visit_id
          WHERE smv.manifest_id = f.manifest_id AND NOT s.dry_run AND (s.gdo_id IS NULL OR NOT s.gdo_id IS DISTINCT FROM f.gdo_id) AND NOT s.retryable AND s.status <> 'SUCCESS'::text AND s.created_at > GREATEST(f.updated_at, COALESCE((
             SELECT max(rq.requeued_at) FROM public.derm_portal_requeue rq
              WHERE rq.manifest_id = f.manifest_id
                AND (rq.gdo_id IS NULL OR NOT rq.gdo_id IS DISTINCT FROM f.gdo_id)
            ), '-infinity'::timestamptz)))) AND NOT (EXISTS ( SELECT 1
           FROM derm_portal_leases l
             JOIN manifest_visits lmv ON lmv.visit_id = l.visit_id
          WHERE lmv.manifest_id = f.manifest_id AND l.leased_at > (now() - '20:00:00'::interval)))
  ORDER BY manifest_id, gdo_id, (abs(visit_date - dump_ticket_date)), visit_id;;

-- ---------------------------------------------------------------------------
-- The operator-facing call.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_requeue_derm_portal(
  p_visit_id bigint,
  p_gdo_id   bigint,
  p_reason   text,
  p_by       text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_manifest_id bigint;
  v_blocked     boolean;
  v_queued      boolean;
  v_why         text;
BEGIN
  IF coalesce(btrim(p_reason),'') = '' THEN
    RAISE EXCEPTION 'fn_requeue_derm_portal: a reason is required - the next person to read this row has to know why somebody overrode the gate'
      USING ERRCODE = '22023';
  END IF;

  SELECT mv.manifest_id INTO v_manifest_id
    FROM public.manifest_visits mv
    JOIN public.derm_manifests m ON m.id = mv.manifest_id AND m.deleted_at IS NULL
   WHERE mv.visit_id = p_visit_id
   LIMIT 1;
  IF v_manifest_id IS NULL THEN
    RAISE EXCEPTION 'fn_requeue_derm_portal: visit % has no live manifest link, so there is nothing for the portal queue to serve', p_visit_id
      USING ERRCODE = 'P0002';
  END IF;

  -- Is gate 3 actually what is holding it? If not, a requeue is a no-op, and saying so
  -- is more useful than inserting a row and letting the operator believe they acted.
  SELECT EXISTS (
    SELECT 1 FROM public.derm_portal_submissions s
      JOIN public.manifest_visits smv ON smv.visit_id = s.visit_id
     WHERE smv.manifest_id = v_manifest_id AND NOT s.dry_run
       AND (s.gdo_id IS NULL OR NOT s.gdo_id IS DISTINCT FROM p_gdo_id)
       AND NOT s.retryable AND s.status <> 'SUCCESS')
  INTO v_blocked;

  INSERT INTO public.derm_portal_requeue (manifest_id, gdo_id, reason, requested_by)
  VALUES (v_manifest_id, p_gdo_id, btrim(p_reason),
          coalesce(p_by, current_setting('request.jwt.claims', true)::jsonb->>'email', session_user));

  -- VERIFY, do not assume. A requeue that changes nothing is the failure mode.
  SELECT EXISTS (SELECT 1 FROM public.v_derm_portal_queue qq
                  WHERE qq.visit_id = p_visit_id
                    AND NOT qq.gdo_id IS DISTINCT FROM p_gdo_id)
    INTO v_queued;

  IF NOT v_queued THEN
    -- name the gate that is still holding it, in the order the view applies them
    SELECT CASE
      WHEN EXISTS (SELECT 1 FROM public.derm_portal_submissions s
                     JOIN public.manifest_visits smv ON smv.visit_id = s.visit_id
                    WHERE smv.manifest_id = v_manifest_id AND NOT s.dry_run
                      AND (s.gdo_id IS NULL OR NOT s.gdo_id IS DISTINCT FROM p_gdo_id)
                      AND (s.status = 'SUCCESS' OR s.portal_confirmation IS NOT NULL))
        THEN 'gate 1: this permit has already filed successfully - nothing to retry'
      WHEN EXISTS (SELECT 1 FROM public.derm_portal_submissions s
                     JOIN public.manifest_visits smv ON smv.visit_id = s.visit_id
                    WHERE smv.manifest_id = v_manifest_id AND NOT s.dry_run
                      AND (s.gdo_id IS NULL OR NOT s.gdo_id IS DISTINCT FROM p_gdo_id)
                      AND s.created_at > now() - interval '20 hours')
        THEN 'gate 2: a 20h cooldown is running after the last attempt - it will serve once that expires'
      WHEN EXISTS (SELECT 1 FROM public.derm_portal_leases l
                     JOIN public.manifest_visits lmv ON lmv.visit_id = l.visit_id
                    WHERE lmv.manifest_id = v_manifest_id AND l.leased_at > now() - interval '20 hours')
        THEN 'gate 4: the manifest is under a dispense lease - the bot already holds it'
      ELSE 'not gate 1/2/3/4 - the row may be before rpa_launch_cutoff(), or the (visit, gdo) pair does not appear in v_derm_portal_fields'
    END INTO v_why;
  END IF;

  RETURN jsonb_build_object(
    'manifest_id', v_manifest_id,
    'visit_id', p_visit_id,
    'gdo_id', p_gdo_id,
    'was_blocked_by_gate3', v_blocked,
    'queued_now', v_queued,
    'still_blocked_by', v_why);
END $fn$;

COMMENT ON FUNCTION public.fn_requeue_derm_portal(bigint,bigint,text,text) IS
  'Explicitly re-open the DERM portal queue for one (visit, permit) after a fix made OUTSIDE this database - a county portal credential, a permit registration. Relaxes ONLY gate 3 (non-retryable data error); gates 1, 2 and 4 still apply and the return value names whichever one is still holding the row. Self-limiting: a fresh failure closes the gate again. Requires a reason. Added 2026-08-24.';

REVOKE ALL ON FUNCTION public.fn_requeue_derm_portal(bigint,bigint,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_requeue_derm_portal(bigint,bigint,text,text) TO service_role;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- VERIFY (run after applying)
--
-- 1. 🛑 THE QUEUE MUST NOT WIDEN. This is the primary safety check: a gate edit that
--    lets extra rows through hands the bot filings that should not go out, on a
--    REGULATOR-FACING queue.
--    select count(*) from public.v_derm_portal_queue;
--    -- expect 1, exactly as before the change (visit 6617 / gdo 230)
--
-- 2. the dependent view survived CREATE OR REPLACE
--    select queue_depth from public.v_rpa_derm_health;   -- expect 1, not an error
--
-- 3. MUTATION TEST: an empty reason must RAISE
--    do $$ begin perform public.fn_requeue_derm_portal(6617, 230, '   ');
--      raise exception 'FAILTEST'; exception when others then
--      if sqlerrm like 'FAILTEST%' then raise; end if; raise notice 'ok: %', sqlerrm; end $$;
--
-- 4. POSITIVE CONTROL that the marker actually re-opens gate 3. Pick a row that IS
--    blocked by gate 3, requeue it, and assert it appears:
--    select public.fn_requeue_derm_portal(<visit>, <gdo>, 'control');
--    -- expect queued_now=true, still_blocked_by=null
--    ⚠ If queued_now is FALSE, read still_blocked_by before assuming the marker failed -
--      gates 1, 2 and 4 are untouched by design and any of them can be the reason.
--
-- 5. NEGATIVE CONTROL that it does NOT defeat gate 1. Requeue a permit that has already
--    filed successfully; it must stay out and say so:
--    select public.fn_requeue_derm_portal(6617, 156, 'must not re-file');
--    -- expect queued_now=false and still_blocked_by naming gate 1
--    -- (gdo 156 = GDO-14117, filed 2026-08-07)
--
-- 6. grants: no anon, no authenticated on either object
