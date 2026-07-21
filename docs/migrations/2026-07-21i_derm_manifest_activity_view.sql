-- ============================================================================
-- 2026-07-21i — derm.manifest_activity: per-manifest "who did what" feed
-- ============================================================================
-- WHY (Fred 2026-07-21: "we should have an activity trail... show in the DERM
-- App which clients had the report done / who did this kind of stuff"; refined
-- with the Building Apps session, which did the read-only attribution audit):
-- the DERM Tracker needs a per-manifest Activity feed. The actor for each kind
-- of action lives in a DIFFERENT place, and both have a hard pre-cutover floor:
--   * manifest create/edit + visit link/unlink -> audit.logs (jwt_claims.email).
--     Attributed since 2026-07-10 10:35 ET; the 1078 rows before that carry no
--     identity (unrecoverable).
--   * DERM emails to client/city -> public.derm_email_sends.sent_by_email
--     (v15, migration 2026-07-21h). 0/81 existing rows are attributed only
--     because every send predates the v15 deploy; the column populates on the
--     next real signed-in send.
-- This view unions the two sources on manifest_id so the app reads ONE seam.
--
-- DECISION — read the email actor from derm_email_sends, NOT from audit.logs.
-- send-derm-email runs as service_role, so its 83 audit.logs rows have NO
-- person (jwt_claims is the service key: role=service_role, no email/sub). That
-- is unrecoverable for history and would stay NULL going forward. v15 already
-- records the human on the derm_email_sends ROW, so the feed reads it there.
-- We deliberately did NOT patch the edge function for the view's sake: the
-- only seam to also stamp the audit row (x-actor-name header, or set_config on
-- request.jwt.claims) is either an audit-only nicety we don't need, or rebinds
-- auth.uid()/auth.jwt() for the rest of the txn. Reading derm_email_sends
-- sidesteps all of it. (If an audit-ONLY consumer is ever built, the low-risk
-- x-actor-name seam mirrors webhook-jobber; documented, not applied.)
-- Bonus: reading the table (81 live rows) not the audit INSERTs (83) means two
-- since-deleted send rows correctly do NOT show as activity.
--
-- HUMAN-ACTIONS ONLY (app_source filter, load-bearing). audit.logs on these two
-- tables is dominated by ~7,000 system UPDATE rows (app_source sql / fog-backfill
-- / migrations, all actor-NULL). Without the filter every one renders as
-- "Manifest edited - Not recorded" and buries the feed. We keep only the two
-- HUMAN DERM surfaces that write these tables: 'derm-tracker' + 'derm-stamp-studio'
-- (verified live 2026-07-21: no other app writes derm_manifests/manifest_visits).
-- Pre-cutover derm-tracker rows are kept (they carry app_source='derm-tracker'
-- with NULL email) and correctly render as "Not recorded".
--
-- ATTRIBUTION DISPLAY RULES (never regress):
--   * actor_display: employee full_name, else 'Office account (contact@unclogme.com)'
--     for the shared login, else 'Not recorded'. NEVER blank, NEVER a wrong name.
--   * actor_email: exposed ONLY for a resolved actor (office or known employee);
--     an unmapped/unknown address is masked to NULL so we never leak a raw
--     identity the feed itself labels "Not recorded".
--   * PII/.gov containment: derm_email_sends.recipient_email / resend_email_id are
--     NEVER selected. City rows say only "City environmental compliance"; client
--     rows say "client contact". No client email, no city .gov address is exposed.
--
-- TIMEZONE: exposes raw timestamptz occurred_at (changed_at / sent_at); the app
-- converts to America/New_York, matching every other derm.* view (0/19 convert
-- in the DB; see project_apps_display_in_ET).
--
-- SECURITY: default (NON-security_invoker) view owned by postgres, like the rest
-- of derm.*; anon+authenticated need only SELECT on the view (the view's reads of
-- audit.logs / derm_email_sends / employees use the owner's rights). Do NOT set
-- security_invoker=true, or anon would need direct grants on audit.logs.
--
-- SCOPE: read-only surface for the DERM Tracker Activity UI (Building Apps owns
-- the app side). No table/edge-fn change. Visit FIELD edits (visits UPDATE) are
-- intentionally excluded: their record_pk is {"id": visit_id} with no manifest_id.
-- ============================================================================

CREATE OR REPLACE VIEW derm.manifest_activity AS
WITH audit_events AS (
  -- Manifest create/edit + visit link/unlink, from the audit trail.
  -- HUMAN DERM apps only; excludes sql/fog-backfill/migration noise.
  SELECT
    CASE l.table_name
      WHEN 'derm_manifests'  THEN (l.record_pk ->> 'id')::bigint
      WHEN 'manifest_visits' THEN (l.record_pk ->> 'manifest_id')::bigint
    END                                                       AS manifest_id,
    l.changed_at                                              AS occurred_at,
    CASE
      WHEN l.table_name = 'derm_manifests'  AND l.operation = 'INSERT' THEN 'Manifest created'
      WHEN l.table_name = 'derm_manifests'  AND l.operation = 'UPDATE' THEN 'Manifest edited'
      WHEN l.table_name = 'manifest_visits' AND l.operation = 'INSERT' THEN 'Visit linked'
      WHEN l.table_name = 'manifest_visits' AND l.operation = 'DELETE' THEN 'Visit unlinked'
    END                                                       AS action_type,
    l.jwt_claims ->> 'email'                                  AS actor_email_raw,
    CASE
      WHEN l.table_name = 'derm_manifests'  AND l.operation = 'INSERT'
        THEN 'Manifest #' || (l.record_pk ->> 'id') || ' created'
      WHEN l.table_name = 'derm_manifests'  AND l.operation = 'UPDATE'
        THEN 'Manifest #' || (l.record_pk ->> 'id') || ' edited'
      WHEN l.table_name = 'manifest_visits' AND l.operation = 'INSERT'
        THEN 'Visit ' || (l.record_pk ->> 'visit_id') || ' linked to manifest'
      WHEN l.table_name = 'manifest_visits' AND l.operation = 'DELETE'
        THEN 'Visit ' || (l.record_pk ->> 'visit_id') || ' unlinked from manifest'
    END                                                       AS details,
    false                                                     AS is_test,
    'audit.logs'::text                                        AS source
  FROM audit.logs l
  WHERE l.table_name IN ('derm_manifests', 'manifest_visits')
    AND l.operation  IN ('INSERT', 'UPDATE', 'DELETE')
    AND l.app_source IN ('derm-tracker', 'derm-stamp-studio')
),
email_events AS (
  -- DERM emails to client / city, from the purpose-built send log.
  -- Actor = derm_email_sends.sent_by_email (v15), NOT audit.logs (service_role).
  -- recipient_email / resend_email_id are NEVER selected: no PII, no city .gov leak.
  SELECT
    s.manifest_id                                             AS manifest_id,
    s.sent_at                                                 AS occurred_at,
    CASE s.recipient_type
      WHEN 'city'   THEN 'DERM email sent to city'
      WHEN 'client' THEN 'DERM email sent to client'
      ELSE               'DERM email sent'
    END                                                       AS action_type,
    s.sent_by_email                                           AS actor_email_raw,
    CASE s.recipient_type
      WHEN 'city'   THEN 'DERM manifest emailed to City environmental compliance ('
                         || COALESCE(s.status, 'unknown') || ')'
      WHEN 'client' THEN 'DERM manifest emailed to client contact ('
                         || COALESCE(s.status, 'unknown') || ')'
      ELSE               'DERM manifest emailed (' || COALESCE(s.status, 'unknown') || ')'
    END                                                       AS details,
    s.is_test                                                 AS is_test,
    'derm_email_sends'::text                                  AS source
  FROM public.derm_email_sends s
),
unioned AS (
  SELECT * FROM audit_events
   WHERE manifest_id IS NOT NULL AND action_type IS NOT NULL
  UNION ALL
  SELECT * FROM email_events
)
SELECT
  u.manifest_id,
  u.occurred_at,                       -- raw timestamptz; app converts to ET
  u.action_type,
  CASE
    WHEN u.actor_email_raw IS NULL                         THEN 'Not recorded'
    WHEN lower(u.actor_email_raw) = 'contact@unclogme.com' THEN 'Office account (contact@unclogme.com)'
    WHEN e.full_name IS NOT NULL                           THEN e.full_name
    ELSE 'Not recorded'
  END                                                        AS actor_display,
  CASE
    WHEN u.actor_email_raw IS NULL                         THEN NULL
    WHEN lower(u.actor_email_raw) = 'contact@unclogme.com' THEN u.actor_email_raw
    WHEN e.full_name IS NOT NULL                           THEN u.actor_email_raw
    ELSE NULL
  END                                                        AS actor_email,
  u.details,
  u.is_test,
  u.source
FROM unioned u
LEFT JOIN public.employees e
  ON lower(e.email) = lower(u.actor_email_raw)
ORDER BY u.occurred_at DESC;

GRANT SELECT ON derm.manifest_activity TO anon, authenticated;

COMMENT ON VIEW derm.manifest_activity IS
  'Per-manifest activity feed for the DERM Tracker: manifest create/edit + visit link/unlink (from audit.logs, human app_sources only) unioned with DERM email sends (from derm_email_sends). actor lives in jwt_claims.email for audit rows and sent_by_email for email rows; pre-2026-07-10 / pre-v15 actors render as "Not recorded". No client/city PII exposed. See migration 2026-07-21i.';

-- ============================================================================
-- VERIFICATION + STATE (2026-07-21) — applied + verified live
-- ============================================================================
-- APPLIED to Prod (wbasvhvvismukaqdnouk) 2026-07-21; view exists, 8 columns:
--   manifest_id bigint, occurred_at timestamptz, action_type text,
--   actor_display text, actor_email text, details text, is_test bool, source text.
-- GRANTS: anon SELECT + authenticated SELECT (matches the derm.* app-facing pattern).
-- ROW COUNTS: audit.logs source = 912 rows (97 attributed), derm_email_sends
--   source = 81 rows (0 attributed, all pre-v15 — expected). The app_source
--   filter is load-bearing: WITHOUT it the audit half is ~7,000+ system rows;
--   WITH it, 912 human rows. Action mix: Manifest edited 468, Visit linked 227,
--   Manifest created 184, Email->city 46, Email->client 35, Visit unlinked 33.
-- ACTOR RESOLUTION (live): "Not recorded" 896 (the honest pre-cutover/pre-v15
--   floor), "Office account (contact@unclogme.com)" 96, "Yannick" 1. The shared
--   login is masked to "Office account" even though employees maps it to a person.
-- HARDENING VERIFIED:
--   * leak_check = 0 — no actor_email is ever exposed that is not contact@unclogme.com
--     or a known employee (unmapped identities masked to NULL).
--   * consistency = 0 — every row whose actor_display='Not recorded' has actor_email NULL.
-- SANITY (manifest 1195, both sources): renders a coherent timeline — created ->
--   visit linked -> edited -> emails (city test is_test=true, client, city) -> edits;
--   city rows say "City environmental compliance" (no .gov), client rows "client
--   contact" (no client email). PII containment confirmed structurally (recipient_email
--   / resend_email_id are not columns of the view).
-- EDGE FN: send-derm-email deliberately NOT changed (decision above). The email
--   actor will appear the moment v15 fires on the next real signed-in send, via
--   derm_email_sends.sent_by_email -> this view, with NO further DB change.
-- APP: Building Apps / DERM Tracker will read derm.manifest_activity for the
--   per-manifest Activity UI (documented in that app's docs, same cycle).
-- ============================================================================
