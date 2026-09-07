-- ============================================================================================
-- 2026-09-07_1520_non_customer_clients.sql
--
-- One place that answers "is this a real customer?". Additive only: nothing is repointed here.
--
-- WHY (Fred, 2026-09-07)
-- ---------------------
-- Asked for "a really good systematic way to set an exclude list ... for both 000 clients, which
-- are dumps", then when put the framing question chose **"not a real customer"** over "dump site".
-- That choice decides the design, because the two are different sets.
--
-- Measured: FIVE divergent exclusion predicates exist in production and no two agree.
--   public.fn_generate_sa_visits   client_code not in ('112-YA','777-YA','000-DH','000-HS')
--   public.v_sa_schedule_gaps      client_code <> ALL (ARRAY['112-YA','777-YA','000-DH'])
--   public.dump_route_today        client_code NOT LIKE '000%'
--   derm.visits, public.manifest_pickable_visits   client_code = ANY (ARRAY['000-DH','000-DP'])
--   sync-jobber-billing-observe    two hardcoded job ids (removed 2026-09-07, commit 08b7ac4)
-- Plus 2 CHECK constraints pinning display strings and a dump_key.
--
-- 🛑 WHY THE '000-' PREFIX CANNOT BE THE MODEL FOR THIS CONCEPT.
-- The prefix is a genuine reserved namespace (clients_active_client_number_uniq excludes it,
-- webhook-jobber calls it "the 000 dump band (which shares a number by design)"), and it correctly
-- models DUMPS. It cannot model "not a real customer":
--   * 112-YA and 777-YA are test accounts and carry ordinary client codes.
--   * "Doug Test" (id 2) has client_code **NULL**, so no prefix test can ever reach it, and
--     `NULL NOT LIKE '000%'` evaluates to NULL, which DROPS the row rather than keeping it.
-- ⚠ That NULL behaviour is a live latent defect in the prefix-based predicates: 175 of 475 clients
--   carry a NULL client_code, and 4 live completed visits on real ACTIVE clients are silently
--   dropped from dump_route_today and derm.visits today. 0 are DERM-required, which is why nobody
--   has noticed. NOT fixed here (those objects are untouched); recorded so it is not re-discovered.
--
-- 🛑 THE TABLE ACCEPTS A CODE WITHOUT A CLIENT, AND THAT IS LOAD-BEARING, NOT SLOPPY.
-- `000-HS` is in fn_generate_sa_visits' exclusion list and matches NO client row. Four reviewers
-- called it a phantom to clean up. It is not: commit bb3ce7d (2026-08-03), Fred verbatim,
-- "Also add 000-HS to that guard of exclusion list", staged deliberately BEFORE the account exists
-- so the guard predates it. A table keyed only on client_id could not hold it, and repointing any
-- consumer at such a table would SILENTLY DELETE a guard Fred asked for. So membership resolves by
-- client_id OR by client_code, and a code-only row is the supported way to pre-stage.
--
-- KINDS, and why not one boolean: different consumers exclude different subsets. Revenue excludes
-- all of them; SA generation excludes test and dump; DERM and route planning SELECT dumps rather
-- than excluding them. A boolean cannot express that, so callers filter on kind.
--
-- SEEDED POPULATION (7 clients + 1 pre-staged code), measured 2026-09-07:
--   dump_site  365 000-DH Homestead Dump (0 invoices ever), 76 000-DP DUMP Pompano (0 invoices)
--   dump_site  000-HS  pre-staged, no client row yet
--   test       381 112-YA, 47 777-YA (Fred's sanctioned test clients), 2 "Doug Test" (NULL code)
--   fixture    561 311-ZMS, 562 312-ZMS (both INACTIVE)
-- ⚠ Note the dumps have ZERO invoices while the TEST clients hold 20 between them. So "is a dump"
--   and "exclude from revenue" genuinely point at different rows, which is the whole reason this
--   is a kinded list and not a dump flag.
--
-- RULE 8: OPT IN. This classifies clients for billing and revenue purposes and is human-edited, so
-- the hard rule ("no table that touches billing ... may skip audit") applies squarely.
--
-- NOTHING IS REPOINTED IN THIS MIGRATION. The five predicates above are untouched. Repointing
-- fn_generate_sa_visits is a separate, reviewed change (2026-09-07_1540) because it is visit
-- generation.
-- ============================================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.non_customer_clients (
  id          bigserial PRIMARY KEY,
  client_id   bigint REFERENCES public.clients(id),
  client_code text,
  kind        text        NOT NULL,
  reason      text        NOT NULL,
  added_at    timestamptz NOT NULL DEFAULT now(),
  added_by    text,
  CONSTRAINT non_customer_clients_kind_chk
    CHECK (kind IN ('dump_site','test','fixture')),
  -- At least one identifier. A code-only row is how a client is excluded BEFORE it exists.
  CONSTRAINT non_customer_clients_identified_chk
    CHECK (client_id IS NOT NULL OR client_code IS NOT NULL),
  CONSTRAINT non_customer_clients_reason_chk
    CHECK (btrim(reason) <> '')
);

CREATE UNIQUE INDEX IF NOT EXISTS non_customer_clients_client_id_uniq
  ON public.non_customer_clients (client_id) WHERE client_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS non_customer_clients_client_code_uniq
  ON public.non_customer_clients (client_code) WHERE client_code IS NOT NULL;

COMMENT ON TABLE public.non_customer_clients IS
  'Clients that are NOT real customers: our own dump sites, test accounts and fixtures. One place '
  'that answers "should this be excluded", replacing five divergent hardcoded predicates. Rows may '
  'be keyed by client_id OR by client_code; a code-only row PRE-STAGES an exclusion for a client '
  'that does not exist yet (000-HS is exactly that, on Fred''s instruction). Consumers filter on '
  'kind: revenue excludes all, SA generation excludes test and dump, DERM and route planning SELECT '
  'dumps rather than excluding them.';

-- Rule 8: billing-relevant classification, human-edited, opts IN.
DROP TRIGGER IF EXISTS audit_non_customer_clients ON public.non_customer_clients;
CREATE TRIGGER audit_non_customer_clients
  AFTER INSERT OR UPDATE OR DELETE ON public.non_customer_clients
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- ── Membership, resolved both ways ──────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW public.v_non_customer_clients AS
SELECT c.id            AS client_id,
       c.client_code,
       c.name,
       c.status,
       n.kind,
       n.reason
  FROM public.clients c
  JOIN public.non_customer_clients n
    ON n.client_id = c.id
    OR (n.client_id IS NULL AND n.client_code IS NOT NULL AND n.client_code = c.client_code);

COMMENT ON VIEW public.v_non_customer_clients IS
  'Resolved membership: the clients that actually exist and are not real customers. A pre-staged '
  'code-only row contributes nothing here until its client appears, which is correct, because there '
  'is nothing to exclude until then.';

CREATE OR REPLACE FUNCTION public.fn_is_non_customer(p_client_id bigint, p_kinds text[] DEFAULT NULL)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $fn$
  SELECT EXISTS (
    SELECT 1 FROM public.v_non_customer_clients v
     WHERE v.client_id = p_client_id
       AND (p_kinds IS NULL OR v.kind = ANY (p_kinds)));
$fn$;

COMMENT ON FUNCTION public.fn_is_non_customer(bigint, text[]) IS
  'Is this client one we should exclude? Pass p_kinds to narrow (e.g. ARRAY[''test'',''dump_site'']); '
  'NULL means any kind. SECURITY DEFINER with a pinned search_path because it is called from '
  'owner-rights views read by authenticated: a SECURITY INVOKER function there adds an invoker-side '
  'EXECUTE check to the view''s read path, which has produced a 42501 five times in this estate.';

-- Grants. Supabase default privileges hand out grants nobody wrote, so be explicit.
REVOKE ALL ON public.non_customer_clients FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.non_customer_clients TO service_role;
REVOKE ALL ON public.v_non_customer_clients FROM PUBLIC, anon;
GRANT SELECT ON public.v_non_customer_clients TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fn_is_non_customer(bigint, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_is_non_customer(bigint, text[])
  TO authenticated, service_role, pg_read_all_data;

-- ── Seed ────────────────────────────────────────────────────────────────────────────────────
INSERT INTO public.non_customer_clients (client_id, client_code, kind, reason, added_by) VALUES
  (365,  '000-DH', 'dump_site', 'Our own dump site (Homestead). Never invoiced: 0 invoices ever.', 'claude/2026-09-07'),
  (76,   '000-DP', 'dump_site', 'Our own dump site (Pompano). Never invoiced: 0 invoices ever.',   'claude/2026-09-07'),
  (NULL, '000-HS', 'dump_site', 'Pre-staged on Fred''s instruction (commit bb3ce7d, 2026-08-03): '
                                'the guard exists before the account does. Do NOT delete as a phantom.', 'claude/2026-09-07'),
  (381,  '112-YA', 'test',      'Fred''s sanctioned test client (Yan''s Restaurant).',              'claude/2026-09-07'),
  (47,   '777-YA', 'test',      'Test client (Yan''s Restaurant, second account).',                 'claude/2026-09-07'),
  (2,    NULL,     'test',      'Test account "Doug Test". client_code is NULL, so no prefix rule '
                                'can ever reach it: this row is the only way to exclude it.',        'claude/2026-09-07'),
  (561,  '311-ZMS', 'fixture',  'Mode fixture "ZZ Mode Separate" (INACTIVE).',                      'claude/2026-09-07'),
  (562,  '312-ZMS', 'fixture',  'Mode fixture "ZZ Mode None" (INACTIVE).',                          'claude/2026-09-07')
ON CONFLICT DO NOTHING;

-- ============================================================================================
-- VERIFY
-- ============================================================================================
DO $verify$
DECLARE
  v_rows int; v_resolved int; v_real int; v_ctl int;
BEGIN
  -- 1. All eight rows seeded, seven resolving to a live client and one pre-staged.
  SELECT count(*) INTO v_rows     FROM public.non_customer_clients;
  SELECT count(*) INTO v_resolved FROM public.v_non_customer_clients;
  IF v_rows <> 8 THEN RAISE EXCEPTION 'VERIFY 1 FAILED: % seed rows, expected 8', v_rows; END IF;
  IF v_resolved <> 7 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: % resolve, expected 7 (000-HS must resolve to nothing today)',
      v_resolved;
  END IF;

  -- 2. The pre-staged row is PRESENT but unresolved. If it ever resolves, the client appeared and
  --    the guard starts working, which is the entire point of allowing a code-only row.
  IF NOT EXISTS (SELECT 1 FROM public.non_customer_clients
                  WHERE client_code = '000-HS' AND client_id IS NULL) THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: the pre-staged 000-HS row is missing.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.v_non_customer_clients WHERE client_code = '000-HS') THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: 000-HS resolved, but no such client should exist.';
  END IF;

  -- 3. The NULL-client_code case is reachable, which no prefix predicate can do. This is the row
  --    that justifies the table over a naming convention.
  IF NOT public.fn_is_non_customer(2) THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: "Doug Test" (id 2, NULL client_code) is not matched.';
  END IF;

  -- 4. Kind filtering works in both directions.
  IF NOT public.fn_is_non_customer(365, ARRAY['dump_site']) THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: 365 is not matched as a dump_site.';
  END IF;
  IF public.fn_is_non_customer(365, ARRAY['test']) THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: 365 matched as a test client, so the kind filter is inert.';
  END IF;

  -- 5. NEGATIVE CONTROL. A real customer must NOT match, or every assertion above is vacuous.
  SELECT id INTO v_real FROM public.clients
   WHERE id NOT IN (365,76,381,47,2,561,562) AND status IN ('ACTIVE','RECURRING')
   ORDER BY id LIMIT 1;
  IF v_real IS NULL THEN
    RAISE EXCEPTION 'VERIFY 5 CONTROL FAILED: no real customer to test against.';
  END IF;
  IF public.fn_is_non_customer(v_real) THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: real customer % matched as a non-customer.', v_real;
  END IF;

  -- 6. Grants, asserted by outcome. anon must hold nothing; authenticated may READ the view but
  --    must NOT reach the base table.
  IF has_table_privilege('anon', 'public.v_non_customer_clients', 'SELECT')
  OR has_table_privilege('authenticated', 'public.non_customer_clients', 'SELECT') THEN
    RAISE EXCEPTION 'VERIFY 6 FAILED: anon can read the view, or authenticated can read the table.';
  END IF;
  IF NOT has_table_privilege('authenticated', 'public.v_non_customer_clients', 'SELECT') THEN
    RAISE EXCEPTION 'VERIFY 6 CONTROL FAILED: authenticated cannot read the view either, so the '
                    'check above is not discriminating.';
  END IF;

  -- 7. Rule 8.
  IF NOT EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
                  JOIN pg_namespace n ON n.oid = c.relnamespace
                  WHERE n.nspname='public' AND c.relname='non_customer_clients'
                    AND NOT t.tgisinternal AND t.tgname='audit_non_customer_clients') THEN
    RAISE EXCEPTION 'VERIFY 7 FAILED: the table is not audited.';
  END IF;

  RAISE NOTICE 'ALL VERIFY PASSED (% rows, % resolved, control client %)', v_rows, v_resolved, v_real;
END
$verify$;

COMMIT;
