-- 2026-08-11_1900_client_create_attempts.sql
--
-- WHAT: a service-role-only ledger for in-flight create-client attempts.
--
-- WHY: Fred, 2026-08-11: "add a create client form to the app ... on the home view of the clients app
--      add a button to create a client". This is step 1 of that feature and it writes NO business
--      data. It exists to make ONE specific failure survivable.
--
-- 🛑 THE FAILURE THIS TABLE EXISTS FOR. The create flow calls Jobber's `clientCreate` and there is
--    **no `clientDelete` mutation in the Jobber API** (introspected 2026-08-11: the only client
--    mutations are clientArchive, clientCreate, clientCreateNote, clientDeleteNote, clientEdit,
--    clientEditNote, clientNoteAddAttachment, clientUnarchive, clientsCreate). So a `clientCreate`
--    that succeeds and whose response we never see is UNRECOVERABLE by retry: retrying creates a
--    SECOND real client, and we cannot delete either one through the API. This table records the
--    attempt BEFORE the mutation, so a resumed or duplicated request is recognised instead of
--    re-running the one call that cannot be undone.
--
-- ⚠ THE ARCHITECTURE, stated here because a reader of this table will wonder why it is so small.
--    The app does NOT write public.clients. It creates the client in Jobber, verifies by re-read,
--    then POSTs a SIGNED SYNTHETIC webhook to our own `webhook-jobber`, so `handleClient`
--    materialises the row exactly as it does for every other Jobber client. That keeps ONE writer of
--    client identity and reuses every guard already in that handler (the duplicate-code guards that
--    exist because of the documented 963-failure replay loop on client 153, 2026-07-02 to 07-06).
--    Consequence for this table: it never holds a local client id, only the Jobber GIDs, because our
--    row id is whatever `webhook-jobber` returns.
--
-- STATUS VALUES, and why 'unknown' is not 'failed':
--    started  - row written before the Jobber mutation. If we crash here, we do not know whether
--               Jobber has a client.
--    unknown  - the mutation was sent and the response was lost or ambiguous. **This is the state
--               that must never be auto-retried.** A human reconciles it against Jobber.
--    created  - Jobber confirmed on re-read AND webhook-jobber returned a positive entity_id.
--    failed   - we are certain no Jobber client exists (validation rejected, or the mutation
--               returned userErrors before creating anything).
--
-- GRANTS: service_role, plus `yannick_readonly` which arrives on its own. Deliberately NOT readable
--    by `anon` or `authenticated`: the payload holds a prospective client's name, address, email and
--    phone before any of it is business data.
--    ⚠ MEASURED AFTER APPLYING, because the intent above is not what the catalogue says. The final
--    ACL is `{postgres=arwdDxtm/postgres, service_role=arwdDxtm/postgres, yannick_readonly=r/postgres}`.
--    `yannick_readonly` was never granted by this file: it comes from an ALTER DEFAULT PRIVILEGES on
--    the schema, which is the "grants nobody wrote" behaviour Supabase/CLAUDE.md warns about. It is
--    ACCEPTED here rather than revoked, because that role already holds `r` on `public.clients`,
--    which carries the same fields and more, so this adds no exposure. Recorded rather than silently
--    left, so the next auditor reading "service_role only" does not flag it as a leak.
--    ⚠ CREATE TABLE hands out privileges BEFORE any GRANT statement runs, and a GRANT cannot remove
--    what it did not create (see Supabase/CLAUDE.md, the 2026-08-07 job_frequency_changes incident
--    where `authenticated` silently held SELECT/INSERT/UPDATE/DELETE/TRUNCATE on a compliance table).
--    So this file REVOKES explicitly and then ASSERTS the resulting ACL rather than trusting it.
--
-- AUDIT (ADR 010): opted OUT, deliberately. This is operational plumbing for an in-flight request,
--    not business data, and it holds no human-editable field. The business record it leads to is
--    public.clients, which IS audited (audit_clients). Documented here per the standing rule that
--    every new table states its choice.

BEGIN;

CREATE TABLE IF NOT EXISTS public.client_create_attempts (
  idempotency_key     uuid PRIMARY KEY,
  requested_by        text        NOT NULL,
  payload             jsonb       NOT NULL,
  jobber_client_gid   text,
  jobber_property_gid text,
  status              text        NOT NULL
                        CHECK (status IN ('started','unknown','created','failed')),
  failure_reason      text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.client_create_attempts IS
  'Service-role-only ledger of create-client attempts. Written BEFORE the Jobber clientCreate so a '
  'lost response is recognised rather than retried: Jobber has no clientDelete, so a duplicate '
  'create cannot be undone. status=unknown must never be auto-retried.';

CREATE INDEX IF NOT EXISTS client_create_attempts_status_idx
  ON public.client_create_attempts (status, created_at DESC);

-- reuse the standing updated_at trigger rather than inventing one
DROP TRIGGER IF EXISTS trg_client_create_attempts_updated_at ON public.client_create_attempts;
CREATE TRIGGER trg_client_create_attempts_updated_at
  BEFORE UPDATE ON public.client_create_attempts
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.client_create_attempts ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.client_create_attempts FROM PUBLIC;
REVOKE ALL ON public.client_create_attempts FROM anon;
REVOKE ALL ON public.client_create_attempts FROM authenticated;
GRANT ALL ON public.client_create_attempts TO service_role;

DO $$
DECLARE acl text; n int;
BEGIN
  -- (a) the table exists with the shape we asked for
  SELECT count(*) INTO n FROM information_schema.columns
   WHERE table_schema='public' AND table_name='client_create_attempts';
  IF n <> 9 THEN RAISE EXCEPTION 'expected 9 columns, got %', n; END IF;

  -- (b) 🛑 READ THE ACL AFTER THE FACT. GRANT statements verifying themselves is the 2026-08-07 trap.
  IF has_table_privilege('authenticated','public.client_create_attempts','SELECT') THEN
    RAISE EXCEPTION 'authenticated can SELECT the attempts table; the REVOKE did not hold';
  END IF;
  IF has_table_privilege('authenticated','public.client_create_attempts','INSERT') THEN
    RAISE EXCEPTION 'authenticated can INSERT into the attempts table'; END IF;
  IF has_table_privilege('anon','public.client_create_attempts','SELECT') THEN
    RAISE EXCEPTION 'anon can SELECT the attempts table'; END IF;
  IF NOT has_table_privilege('service_role','public.client_create_attempts','INSERT') THEN
    RAISE EXCEPTION 'service_role cannot INSERT; the function will not work'; END IF;

  -- (c) POSITIVE CONTROL: the same probe must return TRUE for a table authenticated really can read.
  --     Without this, all four checks above would also pass if has_table_privilege were broken.
  IF NOT has_table_privilege('authenticated','public.clients','SELECT') THEN
    RAISE EXCEPTION 'CONTROL FAILED: authenticated cannot SELECT public.clients, so the privilege '
                    'probe is not discriminating and the four assertions above prove nothing';
  END IF;

  -- (d) the status CHECK actually constrains
  BEGIN
    INSERT INTO public.client_create_attempts (idempotency_key, requested_by, payload, status)
    VALUES ('00000000-0000-0000-0000-000000000000','probe','{}'::jsonb,'not_a_status');
    RAISE EXCEPTION 'GUARD FAILED: the status CHECK accepted an invalid value';
  EXCEPTION
    WHEN check_violation THEN NULL;
    WHEN OTHERS THEN
      IF SQLERRM LIKE 'GUARD FAILED%' THEN RAISE; END IF;
      RAISE EXCEPTION 'status CHECK raised an unexpected error: % / %', SQLSTATE, SQLERRM;
  END;

  RAISE NOTICE 'OK: client_create_attempts created, service_role only, status CHECK enforced';
END $$;

COMMIT;
