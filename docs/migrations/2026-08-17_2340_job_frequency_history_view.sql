-- 2026-08-17_2340_job_frequency_history_view.sql
--
-- WHAT: client.job_frequency_changes — the Client App's read surface for a job's cadence history,
--       including how many approval-proof images each change carries.
--
-- WHY: the approval-proof upload shipped earlier today (2026-08-17_2210). Its spec §5 says that when
--      Jobber commits a cadence change and the image upload then fails, the change "can never be
--      proven" unless there is a way to attach proof AFTERWARDS. That remedy needs two things: a
--      surface that LISTS past changes, and an edge-fn action that attaches to one. This file is the
--      first half. Spec: docs/superpowers/specs/2026-08-17-frequency-change-proof-upload-design.md
--
-- 🛑 THE APP CANNOT READ public.job_frequency_changes AT ALL, AND THAT IS DELIBERATE.
--      Measured: its grants go to service_role ONLY. That is the state left by 2026-08-07_1420, which
--      cleaned up a CREATE TABLE that had handed `authenticated` SELECT/INSERT/UPDATE/DELETE/TRUNCATE
--      on a compliance-history table. **Do not "fix" the app's read by granting on the base table.**
--      This view is an OWNER-RIGHTS view (postgres-owned, reloptions NULL, i.e. NOT security_invoker),
--      so it launders the SELECT the same way every other client.* view does, while INSERT/UPDATE/
--      DELETE on the history stay impossible for a browser.
--
-- ⚠ MIRRORS client.status_changes ON PURPOSE. That is the sibling surface for client STATUS changes
--      and its ACL is exactly {postgres=arwdDxtm, authenticated=r} — note NO service_role and NO anon.
--      A new view here inherits `authenticated=r` automatically from the schema's default privileges
--      (pg_default_acl for schema `client` is {authenticated=r/postgres}), so this file writes no
--      GRANT at all. **But it ASSERTS the resulting relacl**, because the lesson from 2026-08-07 is
--      that a migration which verifies only the grants it WROTE passes while the object is wide open.
--
-- ⚠ NO FILTER BY CLIENT, matching client.status_changes. Every user of this app is UnclogMe staff and
--      the app scopes by client_id in its query. This view adds no row the app could not already
--      reach through client.jobs; it adds the REASON text and the proof count.
--
-- AUDIT (ADR 010): a view carries no triggers and this file creates no table, so there is nothing to
--      opt in or out of. public.job_frequency_changes itself is unaudited BY DESIGN — it IS the audit
--      record for a cadence change, and public.jobs (audited) already captures the value change.

BEGIN;

CREATE OR REPLACE VIEW client.job_frequency_changes AS
SELECT
  c.id,
  c.job_id,
  c.client_id,
  c.old_frequency_days,
  c.new_frequency_days,
  c.reason,
  c.changed_by_email,
  c.changed_at,
  -- Live proofs only. A removed proof soft-deletes the LINK (photos has neither deleted_at nor an
  -- audit trigger, so deleting there would be an untraceable hard delete that CASCADEs).
  -- client.photo_links already filters deleted_at IS NULL; this counts the base table directly so the
  -- count cannot drift from the view's own filter.
  (
    SELECT count(*)
      FROM public.photo_links pl
     WHERE pl.entity_type = 'job_frequency_change'
       AND pl.entity_id   = c.id
       AND pl.role        = 'approval_proof'
       AND pl.deleted_at IS NULL
  )::int AS proof_count
FROM public.job_frequency_changes c;

COMMENT ON VIEW client.job_frequency_changes IS
  'Client App read surface for job cadence history + approval-proof counts. Owner-rights on purpose: '
  'public.job_frequency_changes grants to service_role only, so a browser can read history here but '
  'can never write it. Sibling of client.status_changes. Attaching proof goes through the '
  'save-client-job edge function (action=attach_proof), never through PostgREST.';

-- ---------------------------------------------------------------------------
-- assertions. Two-sided where a one-sided check would pass on a broken object.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_acl text; v_sibling_acl text; v_opts text[]; n int; v_live int; v_dead int;
BEGIN
  -- (A) OWNER-RIGHTS, not security_invoker. If this ever flips, the app silently loses history,
  --     because `authenticated` holds nothing on the base table.
  SELECT reloptions INTO v_opts FROM pg_class WHERE oid = 'client.job_frequency_changes'::regclass;
  IF v_opts IS NOT NULL AND array_to_string(v_opts, ',') ILIKE '%security_invoker%' THEN
    RAISE EXCEPTION 'the view is security_invoker; it will return zero rows for the app';
  END IF;

  -- (B) 🛑 READ THE ACL THAT LANDED, do not trust the default privilege. Compare against the
  --     sibling, and require anon to be absent in BOTH — a control, so "anon is absent" cannot be
  --     an artifact of this database simply having no anon role.
  SELECT relacl::text INTO v_acl FROM pg_class WHERE oid = 'client.job_frequency_changes'::regclass;
  SELECT relacl::text INTO v_sibling_acl FROM pg_class WHERE oid = 'client.status_changes'::regclass;
  IF v_acl IS DISTINCT FROM v_sibling_acl THEN
    RAISE EXCEPTION 'ACL % does not match the sibling client.status_changes %', v_acl, v_sibling_acl;
  END IF;
  IF has_table_privilege('anon', 'client.job_frequency_changes', 'SELECT') THEN
    RAISE EXCEPTION 'anon can read the cadence history';
  END IF;
  IF has_table_privilege('anon', 'client.status_changes', 'SELECT') THEN
    RAISE EXCEPTION 'CONTROL FAILED: anon can read the SIBLING too, so this database does not '
                    'distinguish anon the way this test assumes';
  END IF;
  IF NOT has_table_privilege('authenticated', 'client.job_frequency_changes', 'SELECT') THEN
    RAISE EXCEPTION 'authenticated cannot read the view, so the app gets nothing';
  END IF;

  -- (C) The base table must STAY unreachable for the browser. This is the thing the view exists to
  --     avoid needing.
  IF has_table_privilege('authenticated', 'public.job_frequency_changes', 'SELECT') THEN
    RAISE EXCEPTION 'authenticated can now read the BASE table; the 2026-08-07_1420 cleanup regressed';
  END IF;

  -- (D) proof_count is TWO-SIDED against real rows: change 305 carries one LIVE proof, change 303's
  --     proof was soft-deleted. A count that reads the link table without the deleted_at filter
  --     returns 1 for both and passes a one-sided test.
  SELECT proof_count INTO v_live FROM client.job_frequency_changes WHERE id = 305;
  SELECT proof_count INTO v_dead FROM client.job_frequency_changes WHERE id = 303;
  IF v_live IS NULL OR v_dead IS NULL THEN
    RAISE NOTICE 'skipping proof_count assertion: fixture changes 303/305 are absent';
  ELSE
    IF v_live <> 1 THEN RAISE EXCEPTION 'change 305 should show exactly 1 live proof, got %', v_live; END IF;
    IF v_dead <> 0 THEN RAISE EXCEPTION 'change 303 soft-deleted its proof and must show 0, got %', v_dead; END IF;
  END IF;

  -- (E) The view returns the whole history, not a filtered slice.
  SELECT count(*) INTO n FROM client.job_frequency_changes;
  IF n <> (SELECT count(*) FROM public.job_frequency_changes) THEN
    RAISE EXCEPTION 'the view drops rows relative to the base table';
  END IF;

  RAISE NOTICE 'OK: owner-rights, ACL matches sibling, anon excluded (with control), base table still closed, proof_count two-sided';
END $$;

COMMIT;
