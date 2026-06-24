-- 2026-06-24  DERM-required, derived from a visit's line items (not the blunt service_type)
-- ============================================================================================
-- WHY: Canonical rule (Fred's Google Sheet "Requires DERM reporting" col): a visit needs a DERM
-- manifest IFF it has a *Pumping* line item (taxonomy codes 01-04, 09-11). service_type='GT' is
-- wrong both ways: handleVisit DEFAULTS to GT (481 GT visits had derm_required NULL; 41 GT visits
-- are actually cleaning), and grey-water pumping is coded CL but DOES need DERM (18 such visits).
-- This populates visits.derm_required from each visit's actual line items.
--
-- DESIGN INVARIANTS (validated by adversarial review 2026-06-24):
--  * UNION across sources for the TRUE signal: a visit is DERM-required if ANY line item in ANY
--    of its sources (visit-scoped, invoice-scoped, job-scoped) is a pumping item. (Priority-only
--    resolution could hide pumping carried on the job while the invoice shows only cleaning.)
--  * NULL = "unknown" and is SAFE: every consumer treats `derm_required IS NULL OR = true` as
--    still-needs-review (manifest_pickable_visits, derm.visits.needs_manifest, customer.work_orders,
--    ops.v_derm_compliance). False negatives (hiding a real DERM visit) are worse than noise.
--  * MONOTONIC unattended writers: the nightly cron / handleVisit NEVER demote a stored TRUE to
--    false/null and never write NULL. They only promote NULL->{true,false} and false->true. A
--    genuine TRUE->false demotion (or a human override) is out of scope for automation. This both
--    prevents an arriving non-pump invoice from hiding a pumping visit AND protects a human's
--    NULL->true reclassification from being reverted overnight.
--
-- AUDIT (ADR 010): functions only (no new business table; the snapshot table is one-time scratch,
-- audit opt-OUT). visits is audited; the backfill UPDATEs it, but the IS DISTINCT FROM + monotonic
-- guards mean only genuinely-changed rows are written (no no-op churn, no updated_at flap that could
-- poison self-healing-lookback sync cursors). After steady state the nightly job writes ~0 rows.
--
-- ROLLBACK: derm_required_backfill_snapshot_2026_06_24 holds (visit_id, service_type, prior value).
-- The cron is independently removable via cron.unschedule('derm-required-rederive'). The previous
-- ops.v_derm_compliance definition is in git history.
--
-- SCOPE NOTE: ops.v_derm_compliance stays GT-config-roster-scoped (it joins service_configs on
-- service_type='GT' for equipment/frequency); its missing-manifest COUNT now uses derm_required
-- (catching a GT client's grey-water/LS pumping visits). Grey-water/lift-station-ONLY clients
-- (no GT config) are tracked via derm.visits, not this ops dashboard. Full per-service rebuild deferred.
-- ============================================================================================

-- 1) Per-line-item classifier: true=pumping(DERM), false=recognized non-pumping, NULL=unknown.
--    PUMP_RE is evaluated BEFORE NONPUMP so a pumping name can never be downgraded by a co-occurring
--    non-pump token. Tolerant of word-forms (pumped/pumping/pumps out), reverse order (pump ... trap),
--    typos (Tap, Lyft), and the "interceptor" synonym for grease trap.
CREATE OR REPLACE FUNCTION public.fn_line_item_requires_derm(p_name text)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT CASE
    WHEN p_name IS NULL OR btrim(p_name) = '' THEN NULL
    -- (a) taxonomy-formatted "NN - ..." -> authoritative flag by code
    WHEN substring(btrim(p_name) from '^([0-9]{1,2})\s*-\s') IS NOT NULL THEN
      (SELECT s.requires_derm FROM public.service_line_items s
        WHERE s.code = lpad(substring(btrim(p_name) from '^([0-9]{1,2})\s*-\s'), 2, '0'))
    -- (b) free-text PUMPING: a regulated vessel (grease trap/interceptor, grey water, lift station)
    --     near a pump word (either order), or an explicit pump-out (any word-form).
    WHEN btrim(p_name) ~* '(grease\s*tr?ap|grease\s*interceptor|interceptor|grey\s*water|greywater|(lift|lyft)\s*station)[^,]*pump'
      OR btrim(p_name) ~* 'pump[a-z]*[^,]*(grease\s*tr?ap|grease\s*interceptor|interceptor|grey\s*water|greywater|(lift|lyft)\s*station)'
      OR btrim(p_name) ~* 'pump(ed|ing|s)?\s*[- ]?out'
      THEN true
    -- (c) free-text recognized NON-pumping services / parts / fees
    WHEN btrim(p_name) ~* '(clean|hydrojet|unclog|camera|dye|assess|inspect|labou?r|\mpart|warrant|fee|tax|gdo|manifest|report|faucet|toilet|pipe|drain|install|repair|replace|locator|leak|smell|pictur|material|supply|\mdig|concret|cover|barrier|discount|credit|tip|commissary|ceiling|sump|plumb|cancel|removal|sample|mop|connection|brass|tapcon|union|p-?trap|reconnect|reinstal|drill|valve|emergency\s*visit|manhole|driver)'
      THEN false
    ELSE NULL
  END
$$;

-- 2) Per-visit derivation. UNION of all sources' line items (visit-scoped, invoice-scoped,
--    job-scoped). Aggregate:
--      any item TRUE                              -> true
--      has items, all classified, none TRUE       -> false
--      otherwise (some unknown, or no items)      -> NULL
CREATE OR REPLACE FUNCTION public.fn_visit_requires_derm(p_visit_id bigint)
RETURNS boolean
LANGUAGE plpgsql
STABLE
AS $$
DECLARE v_any boolean; v_all boolean; v_cnt integer;
BEGIN
  SELECT bool_or(d IS TRUE), bool_and(d IS NOT NULL), count(*)
    INTO v_any, v_all, v_cnt
  FROM (
    SELECT public.fn_line_item_requires_derm(li.name) AS d
    FROM public.visits v
    JOIN public.line_items li
      ON  li.name IS NOT NULL
      AND ( li.visit_id = v.id
            OR (v.invoice_id IS NOT NULL AND li.invoice_id = v.invoice_id)
            OR (v.job_id     IS NOT NULL AND li.job_id     = v.job_id) )
    WHERE v.id = p_visit_id
  ) q;

  IF v_cnt = 0 OR v_cnt IS NULL THEN RETURN NULL; END IF;
  IF v_any THEN RETURN true; END IF;
  IF v_all THEN RETURN false; END IF;
  RETURN NULL;
END;
$$;

-- 3) Single-visit setter (called by webhook-jobber.handleVisit). MONOTONIC + idempotent:
--    never writes NULL, never demotes a stored TRUE.
CREATE OR REPLACE FUNCTION public.set_visit_derm_required(p_visit_id bigint)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE v_d boolean;
BEGIN
  v_d := public.fn_visit_requires_derm(p_visit_id);
  IF v_d IS NOT NULL THEN
    UPDATE public.visits
       SET derm_required = v_d
     WHERE id = p_visit_id
       AND derm_required IS NOT TRUE              -- never demote a known TRUE
       AND derm_required IS DISTINCT FROM v_d;    -- idempotent (no audit/updated_at churn)
  END IF;
  RETURN v_d;
END;
$$;

-- 4) Set-based re-derive over all LIVE visits (backfill now + nightly catch-up). Same monotonic
--    + idempotent guards. Returns rows actually changed.
CREATE OR REPLACE FUNCTION public.rederive_visits_derm_required()
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE n integer;
BEGIN
  WITH d AS (
    SELECT id, public.fn_visit_requires_derm(id) AS derived
    FROM public.visits
    WHERE deleted_at IS NULL
  )
  UPDATE public.visits v
     SET derm_required = d.derived
    FROM d
   WHERE d.id = v.id
     AND d.derived IS NOT NULL
     AND v.derm_required IS NOT TRUE
     AND v.derm_required IS DISTINCT FROM d.derived;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_visit_derm_required(bigint) TO service_role;

-- 5) One-time rollback snapshot (audit opt-out: plain scratch table, dropped after a safe window).
CREATE TABLE IF NOT EXISTS public.derm_required_backfill_snapshot_2026_06_24 AS
  SELECT id AS visit_id, service_type, derm_required AS prior_derm_required, now() AS snapshot_at
  FROM public.visits WHERE deleted_at IS NULL;

-- 6) One-time AUTHORITATIVE backfill: store the function's verdict for every live visit, protecting
--    only an existing TRUE (never auto-demote a known DERM obligation). Ambiguous -> NULL (surfaced
--    for review), which is the design's safe default. This differs from rederive_visits_derm_required()
--    (the MONOTONIC nightly path, which never writes NULL) on purpose: the baseline is an attended,
--    one-time authoritative set, so a stale prior FALSE on a now-ambiguous visit is re-surfaced to NULL
--    rather than silently inherited; the nightly cron then protects this baseline + future overrides.
UPDATE public.visits v
   SET derm_required = public.fn_visit_requires_derm(v.id)
 WHERE v.deleted_at IS NULL
   AND v.derm_required IS NOT TRUE
   AND v.derm_required IS DISTINCT FROM public.fn_visit_requires_derm(v.id);

-- 7) ops.v_derm_compliance: count "missing manifests" by derived derm_required (NULL-safe) instead
--    of service_type='GT'; add the deleted_at filter (CLAUDE.md rule). View stays GT-roster-scoped
--    (service_configs GT join drives equipment/frequency) -- see SCOPE NOTE above.
CREATE OR REPLACE VIEW ops.v_derm_compliance AS
 WITH last_manifest AS (
         SELECT derm_manifests.client_id,
            max(derm_manifests.service_date) AS last_manifest_date,
            count(*) AS total_manifests
           FROM derm_manifests
          GROUP BY derm_manifests.client_id
        ), unmatched_visits AS (
         SELECT v.client_id,
            count(*) AS missing_manifests
           FROM visits v
          WHERE (v.derm_required IS NULL OR v.derm_required = true)
            AND v.visit_status = 'completed'::text
            AND v.deleted_at IS NULL
            AND v.visit_date >= (CURRENT_DATE - '120 days'::interval)
            AND NOT (EXISTS ( SELECT 1
                   FROM derm_manifests dm
                  WHERE dm.client_id = v.client_id AND dm.service_date = v.visit_date))
          GROUP BY v.client_id
        )
 SELECT c.id,
    c.client_code,
    c.name AS client_name,
    c.status AS client_status,
    p.zone,
    p.address,
    p.city,
    p.county,
    cc.name AS contact_name,
    cc.email,
    cc.phone,
    ( SELECT g.gdo_number FROM gdos g
       WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text ORDER BY g.id LIMIT 1) AS permit_number,
    ( SELECT g.permit_expiration FROM gdos g
       WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text ORDER BY g.id LIMIT 1) AS permit_expiration,
    sc.equipment_size_gallons,
    sc.frequency_days,
    lm.last_manifest_date,
    lm.total_manifests,
    COALESCE(uv.missing_manifests, 0::bigint) AS missing_manifest_count,
        CASE WHEN COALESCE(uv.missing_manifests, 0::bigint) > 0 THEN true ELSE false END AS has_missing_manifests,
    CURRENT_DATE - lm.last_manifest_date AS days_since_last_manifest,
        CASE
            WHEN lm.last_manifest_date IS NULL THEN 'no_service_record'::text
            WHEN (CURRENT_DATE - lm.last_manifest_date) > 90 THEN 'derm_violation'::text
            WHEN (CURRENT_DATE - lm.last_manifest_date) > COALESCE(sc.frequency_days, 90) THEN 'overdue'::text
            WHEN (CURRENT_DATE - lm.last_manifest_date) > (COALESCE(sc.frequency_days, 90) - 14) THEN 'due_soon'::text
            ELSE 'compliant'::text
        END AS compliance_status
   FROM clients c
     JOIN service_configs sc ON sc.client_id = c.id AND sc.service_type = 'GT'::text
     LEFT JOIN client_contacts cc ON cc.client_id = c.id AND cc.contact_role = 'primary'::text
     LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
     LEFT JOIN last_manifest lm ON lm.client_id = c.id
     LEFT JOIN unmatched_visits uv ON uv.client_id = c.id
  WHERE c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text])
  ORDER BY (
        CASE
            WHEN (CURRENT_DATE - lm.last_manifest_date) > 90 THEN 1
            WHEN lm.last_manifest_date IS NULL THEN 2
            WHEN (CURRENT_DATE - lm.last_manifest_date) > COALESCE(sc.frequency_days, 90) THEN 3
            WHEN (CURRENT_DATE - lm.last_manifest_date) > (COALESCE(sc.frequency_days, 90) - 14) THEN 4
            ELSE 5
        END), (COALESCE(uv.missing_manifests, 0::bigint)) DESC, (CURRENT_DATE - lm.last_manifest_date) DESC NULLS LAST;

-- 8) Nightly catch-up (invoice line items often arrive after the visit). pg_cron, ~3:20am ET.
SELECT cron.schedule('derm-required-rederive', '20 7 * * *',
  $$SELECT public.rederive_visits_derm_required();$$);
