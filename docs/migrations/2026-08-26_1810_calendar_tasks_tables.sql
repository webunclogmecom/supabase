-- 2026-08-26_1810_calendar_tasks_tables.sql
--
-- WHAT: ops.calendar_tasks + ops.calendar_task_assignees.
-- (Filename stamp continues the 2026-08-26_1800 sequence; actually applied ~15:10 ET.)
--
-- NOBODY GETS A WRITE GRANT, NOT EVEN service_role. All writes go through
--    ops.fn_record_calendar_task (SECDEF, next migration), called by the save-calendar-task edge
--    function only AFTER Jobber has confirmed the change. That is what makes "no discrepancies"
--    structural rather than a convention: there is no PostgREST write path to bypass it.
--    Grant shape copied from ops.visit_requests (authenticated=r, service_role=r, yannick_readonly=r),
--    NOT from ops.calendar_day_markers, which grants authenticated 'arwd' under a FOR ALL USING(true)
--    policy and lets any signed-in browser delete any row. Both shapes measured 2026-08-26:
--      ops.visit_requests       {postgres=arwdDxtm,authenticated=r,   service_role=r,yannick_readonly=r}
--      ops.calendar_day_markers {postgres=arwdDxtm,authenticated=arwd,service_role=r,yannick_readonly=r}
--
-- CREATE TABLE HANDS OUT GRANTS BEFORE ANY GRANT STATEMENT RUNS. ALTER DEFAULT PRIVILEGES on
--    schema ops (grantor postgres) is {authenticated=r,service_role=r,yannick_readonly=r}, and anon
--    holds USAGE on ops, so REVOKE FROM PUBLIC alone would not settle it. Every role is revoked
--    explicitly and then re-granted, and the VERIFY block at the bottom reads relacl BACK and
--    compares it against ops.visit_requests rather than trusting the GRANTs that were written
--    (public.job_frequency_changes, 2026-08-07: correct GRANTs, wide-open table, and a header
--    asserting the opposite).
--
-- AUDIT (ADR 010): OPT IN, both tables. A task assigned to someone else is cross-user state on
--    day one. Precedent: client.saved_views opted out and was reversed within 24 hours.
--
-- Design: Building Apps/Visit Calendar/docs/specs/2026-08-25-calendar-tasks-design.md

BEGIN;

CREATE TABLE ops.calendar_tasks (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  title            text        NOT NULL CHECK (btrim(title) <> ''),
  instructions     text,
  task_date        date        NOT NULL,
  minutes          smallint    CHECK (minutes BETWEEN 0 AND 1439),
  duration_minutes smallint    NOT NULL DEFAULT 30 CHECK (duration_minutes BETWEEN 1 AND 1440),
  all_day          boolean     NOT NULL DEFAULT false,
  client_id        bigint      REFERENCES public.clients(id),
  property_id      bigint      REFERENCES public.properties(id),
  visit_id         bigint      REFERENCES public.visits(id),
  is_complete      boolean     NOT NULL DEFAULT false,
  completed_at     timestamptz,
  completed_source text        CHECK (completed_source IN ('calendar','jobber')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT calendar_tasks_allday_chk CHECK (all_day = (minutes IS NULL)),
  CONSTRAINT calendar_tasks_completion_chk
    CHECK ((is_complete AND completed_at IS NOT NULL AND completed_source IS NOT NULL)
        OR (NOT is_complete AND completed_at IS NULL AND completed_source IS NULL))
);

CREATE INDEX calendar_tasks_task_date_idx ON ops.calendar_tasks (task_date);
CREATE INDEX calendar_tasks_visit_id_idx  ON ops.calendar_tasks (visit_id) WHERE visit_id IS NOT NULL;
CREATE INDEX calendar_tasks_open_idx      ON ops.calendar_tasks (id) WHERE NOT is_complete;

CREATE TABLE ops.calendar_task_assignees (
  task_id     bigint NOT NULL REFERENCES ops.calendar_tasks(id) ON DELETE CASCADE,
  employee_id bigint NOT NULL REFERENCES public.employees(id),
  PRIMARY KEY (task_id, employee_id)
);

-- updated_at: a REAL trigger. ops.calendar_day_markers has DEFAULT now() and NO trigger, so its
-- updated_at freezes at insert. Do not copy that. public.set_updated_at is the estate's real one
-- (30 trigger uses; ops.visit_requests carries it as trg_visit_requests_updated_at). Three other
-- similarly-named functions exist -- public.tg_set_updated_at, public.trg_set_updated_at,
-- public.touch_updated_at -- with 1, 1 and 3 uses. Verified against pg_trigger 2026-08-26.
CREATE TRIGGER trg_calendar_tasks_updated_at
  BEFORE UPDATE ON ops.calendar_tasks
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER audit_calendar_tasks
  AFTER INSERT OR UPDATE OR DELETE ON ops.calendar_tasks
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();
CREATE TRIGGER audit_calendar_task_assignees
  AFTER INSERT OR UPDATE OR DELETE ON ops.calendar_task_assignees
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- Grants: READ ONLY for everyone. CREATE TABLE has already handed out grants nobody wrote, so
-- revoke explicitly rather than assuming a new table starts empty.
REVOKE ALL ON ops.calendar_tasks           FROM PUBLIC, anon, authenticated, service_role, yannick_readonly;
REVOKE ALL ON ops.calendar_task_assignees  FROM PUBLIC, anon, authenticated, service_role, yannick_readonly;

GRANT SELECT ON ops.calendar_tasks          TO authenticated, service_role, yannick_readonly;
GRANT SELECT ON ops.calendar_task_assignees TO authenticated, service_role, yannick_readonly;

ALTER TABLE ops.calendar_tasks          ENABLE ROW LEVEL SECURITY;
ALTER TABLE ops.calendar_task_assignees ENABLE ROW LEVEL SECURITY;

CREATE POLICY calendar_tasks_read ON ops.calendar_tasks
  FOR SELECT TO authenticated, service_role USING (true);
CREATE POLICY calendar_task_assignees_read ON ops.calendar_task_assignees
  FOR SELECT TO authenticated, service_role USING (true);

COMMENT ON TABLE ops.calendar_tasks IS
  'Office tasks created in the Visit Calendar and mirrored to Jobber as Jobber Tasks. MASTER copy. '
  'No role holds a write grant: all writes go through ops.fn_record_calendar_task after Jobber has '
  'confirmed the change. See Building Apps/Visit Calendar/docs/specs/2026-08-25-calendar-tasks-design.md';

COMMENT ON TABLE ops.calendar_task_assignees IS
  'Which employees a calendar task is assigned to. A child table, not an array column (rule 2 / 3NF); '
  'public.visit_team is the precedent. Same read-only grant shape as ops.calendar_tasks.';

-- VERIFY: read the ACL BACK and compare it against a sibling, instead of trusting the GRANTs above.
DO $verify$
DECLARE
  v_control text[];
  v_acl     text[];
  t         text;
BEGIN
  SELECT array(SELECT unnest(c.relacl)::text ORDER BY 1) INTO v_control
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'ops' AND c.relname = 'visit_requests';

  -- CONTROL 1: the sibling must exist and must itself be SELECT-only. Without it the comparison
  -- below would run against NULL and would pass on anything.
  IF v_control IS NULL THEN
    RAISE EXCEPTION 'CONTROL MISSING: ops.visit_requests has no relacl, the comparison proves nothing';
  END IF;
  IF has_table_privilege('authenticated','ops.visit_requests','INSERT') THEN
    RAISE EXCEPTION 'CONTROL WRONG: ops.visit_requests is not SELECT-only, it is the wrong template';
  END IF;

  -- CONTROL 2: the instrument must be able to SEE a write grant where one exists.
  -- ops.calendar_day_markers grants authenticated INSERT. If this stops firing, every negative
  -- assertion below is worthless.
  IF NOT has_table_privilege('authenticated','ops.calendar_day_markers','INSERT') THEN
    RAISE EXCEPTION 'CONTROL WRONG: has_table_privilege cannot see a known INSERT grant';
  END IF;

  FOREACH t IN ARRAY ARRAY['calendar_tasks','calendar_task_assignees'] LOOP
    SELECT array(SELECT unnest(c.relacl)::text ORDER BY 1) INTO v_acl
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'ops' AND c.relname = t;

    IF v_acl IS DISTINCT FROM v_control THEN
      RAISE EXCEPTION 'ACL MISMATCH on ops.%: got % want %', t, v_acl, v_control;
    END IF;

    IF NOT has_table_privilege('authenticated','ops.'||t,'SELECT') THEN
      RAISE EXCEPTION 'ops.%: authenticated lost SELECT', t;
    END IF;
    IF has_table_privilege('authenticated','ops.'||t,'INSERT')
    OR has_table_privilege('authenticated','ops.'||t,'UPDATE')
    OR has_table_privilege('authenticated','ops.'||t,'DELETE')
    OR has_table_privilege('authenticated','ops.'||t,'TRUNCATE') THEN
      RAISE EXCEPTION 'ops.%: authenticated holds a WRITE privilege', t;
    END IF;
    IF has_table_privilege('service_role','ops.'||t,'INSERT')
    OR has_table_privilege('service_role','ops.'||t,'UPDATE')
    OR has_table_privilege('service_role','ops.'||t,'DELETE') THEN
      RAISE EXCEPTION 'ops.%: service_role holds a WRITE privilege', t;
    END IF;
    IF has_table_privilege('anon','ops.'||t,'SELECT') THEN
      RAISE EXCEPTION 'ops.%: anon can read it', t;
    END IF;
    IF NOT (SELECT c.relrowsecurity FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = 'ops' AND c.relname = t) THEN
      RAISE EXCEPTION 'ops.%: RLS is not enabled', t;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger tr
                     JOIN pg_class c ON c.oid = tr.tgrelid
                     JOIN pg_namespace n ON n.oid = c.relnamespace
                     JOIN pg_proc p ON p.oid = tr.tgfoid
                     JOIN pg_namespace pn ON pn.oid = p.pronamespace
                    WHERE n.nspname = 'ops' AND c.relname = t
                      AND pn.nspname = 'audit' AND p.proname = 'log_change'
                      AND NOT tr.tgisinternal) THEN
      RAISE EXCEPTION 'ops.%: audit trigger missing (rule 8)', t;
    END IF;
  END LOOP;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger tr
                   JOIN pg_class c ON c.oid = tr.tgrelid
                   JOIN pg_namespace n ON n.oid = c.relnamespace
                   JOIN pg_proc p ON p.oid = tr.tgfoid
                  WHERE n.nspname = 'ops' AND c.relname = 'calendar_tasks'
                    AND p.proname = 'set_updated_at' AND NOT tr.tgisinternal) THEN
    RAISE EXCEPTION 'ops.calendar_tasks: updated_at trigger missing';
  END IF;

  RAISE NOTICE 'VERIFY OK: both tables match ops.visit_requests, RLS on, audit on, no write grants';
END
$verify$;

COMMIT;
