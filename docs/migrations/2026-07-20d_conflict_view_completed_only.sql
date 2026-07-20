-- 2026-07-20d ops.v_derm_human_override_conflict: review only COMPLETED visits
--
-- WHY: the view is a human-review queue for "a person marked this not-required but the classifier says it
-- needs DERM". A visit that has not happened yet cannot be a documentation conflict: there is no service,
-- no load, and no manifest to be missing. Visit 6468 (197-BGT Bagatelle, visit_date 2026-07-17) was
-- sitting in the queue as 'scheduled', which is noise in a surface people are supposed to work through.
--
-- Scope: cosmetic and reversible. Removes exactly 1 of the current 47 rows and touches no business data.
-- A scheduled visit that is later completed re-enters the queue on its own if the conflict is real.
--
-- ⚠ This is the EXACT existing definition (pg_get_viewdef) with ONE predicate added. CREATE OR REPLACE
-- VIEW requires identical column names in identical order, and a from-scratch rewrite was rejected with
-- 42P16 because it guessed the column list wrong (it omitted has_manifest and reordered the tail). Do not
-- retype this view by hand; copy the live definition and add to the WHERE clause.
--
-- NOT CHANGED, deliberately: the rest of the predicate. In particular this does NOT narrow the classifier
-- side (no scope qualifier, no whitelist of "invoice bleed" rows). ADR 018's recorded bias is that
-- over-surfacing beats a false negative, and shrinking a compliance review surface to make a queue number
-- look better is the wrong instrument. The ~6 genuine bleed cases stay visible for a human to judge.
--
-- AUDIT (ADR 010): a view, nothing to audit.

CREATE OR REPLACE VIEW ops.v_derm_human_override_conflict AS
 SELECT v.id AS visit_id,
    c.client_code,
    c.name AS client_name,
    v.visit_date,
    v.visit_status,
    (now() AT TIME ZONE 'America/New_York'::text)::date - v.visit_date AS age_days,
    (EXISTS ( SELECT 1
           FROM manifest_visits mv
             JOIN derm_manifests dm ON dm.id = mv.manifest_id
          WHERE mv.visit_id = v.id AND dm.deleted_at IS NULL)) AS has_manifest,
    v.derm_required,
    v.derm_required_locked
   FROM visits v
     LEFT JOIN clients c ON c.id = v.client_id
  WHERE v.deleted_at IS NULL
    AND v.visit_status = 'completed'::text          -- NEW 2026-07-20: a future visit is not a doc gap
    AND v.derm_required_locked = true
    AND v.derm_required = false
    AND fn_visit_requires_derm(v.id) = true
  ORDER BY ((now() AT TIME ZONE 'America/New_York'::text)::date - v.visit_date) DESC;

COMMENT ON VIEW ops.v_derm_human_override_conflict IS
  'Human-review queue: COMPLETED visits where someone locked derm_required=false but fn_visit_requires_derm '
  'says true. Scheduled visits excluded 2026-07-20 (an unperformed visit cannot be a missing-document '
  'conflict). This queue must actually be worked; it is not self-clearing.';
