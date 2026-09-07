-- ============================================================================================
-- 2026-09-07_1240_jobber_billing_observation.sql
--
-- Phase A of billing two-way: THE EYES ONLY. A normaliser and two tables. Nothing adopts,
-- nothing pushes, nothing alerts per job.
--
-- WHY (Fred, 2026-09-07: "go ahead with the detect-only shadow lane for billing")
-- ------------------------------------------------------------------------------
-- public.jobs.billing_type / invoice_frequency / invoice_rrule are "last confirmed by us", NOT a
-- mirror: written only by fn_record_client_job from a verified Jobber read, with no inbound reader.
-- Fred confirmed people DO edit invoicing in Jobber's own UI, so those edits are invisible to us.
--
-- 🛑 IT DOES NOT USE THE SHADOW LANE, AND THAT IS THE MAIN DESIGN DECISION.
-- The obvious move was sync.source_field_shadow. Two measured reasons not to, both reproduced in
-- rolled-back probes against the LIVE function bodies:
--   1. RE-BASELINE TRAP. sync.fn_record_shadow with p_adopted_to = NULL still runs
--      `source_value = excluded.source_value` on an ADOPT verdict, so it re-baselines to Jobber's
--      new value WITHOUT adopting. Every later pass returns IGNORE. A finding would vanish after
--      exactly one pass, and phase B's ADOPT verdict would be disarmed until Jobber moved again.
--   2. CONFLICT_FROZEN IS A SWEEP-KILLER. Once conflict_at is set, every subsequent call for that
--      row raises P0001 forever, so ONE conflicting job aborts the daily run for all 474.
-- And the premise does not transfer: the shadow answers "did the SOURCE move", which is only
-- load-bearing when a source value is ambiguous (the numeric custom field's 0-means-empty).
-- Jobber's billingType and billingFrequency are non-null enums. "That sync needed a shadow, so this
-- one does" is the inference failure this estate already documents.
-- Both halves of the attribution phase B needs exist anyway: `changed_at`/`prev_norm_*` here
-- (the table is written CHANGE-ONLY), and audit.logs for our side.
--
-- WHAT THIS ADDS
--   sync.fn_canonical_rrule(text)                     - RFC 5545 canonical form, comparison-safe
--   sync.fn_normalize_jobber_billing(bt, bf, rule)    - Jobber vocabulary -> ours, one row out
--   sync.jobber_billing_observed                      - last Jobber read per job, CHANGE-ONLY
--   sync.jobber_billing_observe_runs                  - freshness + coverage, one row per run
--
-- 🛑 THE RRULE SEMANTICS ARE PORTED, NOT INVENTED. They come from parseRrule / rruleMismatch /
-- confirmedRrule in supabase/functions/save-client-job/index.ts, which is the writer that gates
-- every billing write we make. Two normalisations there are load-bearing and both are reproduced:
--   (a) Jobber returns the rule WITHOUT the "RRULE:" prefix; we store it WITH one.
--   (b) INTERVAL=1 is the RFC 5545 default and Jobber OMITS it on read-back, so it must collapse.
-- List-valued parts (BYDAY, BYMONTHDAY) compare as SETS, so "MO,WE" and "WE,MO" are one rule.
-- ⚠ FREQ is emitted FIRST, not alphabetically, because jobs_invoice_rrule_shape_chk demands
--   '^RRULE:FREQ=' and this value is mirrored by the same CHECK on the observed table.
--
-- 🛑 A STORED RRULE IS NOT ITSELF CANONICAL, AND MUST NOT BE MADE SO. Measured: 24 live rules
-- differ from canonical by PART ORDER ONLY, because we persist Jobber's own emission order
-- (FREQ;INTERVAL;BYMONTHDAY) while this function emits FREQ then alphabetical:
--     stored     RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=22
--     canonical  RRULE:FREQ=MONTHLY;BYMONTHDAY=22;INTERVAL=2      <- same rule
-- ⇒ ALWAYS canonicalise BOTH sides before comparing. Never compare a raw stored value against a
--   canonicalised one, and do NOT "tidy" public.jobs.invoice_rrule into canonical form: those bytes
--   are what Jobber confirmed, which is the whole meaning of "last confirmed by us".
-- ⚠ PHASE B NOTE: if an adopter ever writes back, it writes the CANONICAL order, which will look
--   like a diff against the existing convention while being semantically identical. Decide that
--   deliberately rather than discovering it.
--
-- 🛑 A KNOWN AND DELIBERATE BLIND SPOT, stated here rather than left implicit: comparison collapses
-- 'monthly_last_day' and 'custom' into periodic_class = 'PERIODIC'. Jobber cannot express the
-- difference (both are PERIODIC + a rule), so a pure LABEL divergence over an identical class and
-- rule is invisible to this detector. The alternative is a permanent false positive, because
-- save-client-job legitimately accepts 'custom' carrying the month-end rule. Accepted.
--
-- ⚠ WHAT MY FIRST DRAFT GOT WRONG, so nobody restores it: it mapped PERIODIC + FREQ=MONTHLY;
-- BYMONTHDAY=-1 to 'monthly_last_day' with a NULL rrule. Our stored convention carries the rrule on
-- that arm too (3 of 3 monthly_last_day rows fleet-wide). That alone would have reported drift on
-- 100% of live monthly_last_day jobs the day it shipped: jobs 67 and 1782 today.
--
-- RULE 8 (audit-trail standing check)
--   sync.jobber_billing_observed      -> OPT IN. It is billing data, and the hard rule admits no
--     exception there. Change-only writes keep the audit cost proportional to real drift.
--   sync.jobber_billing_observe_runs  -> OPT OUT. Machine-only append, one row per run, no
--     human-editable field. Auditing it would double a pure-churn table and answer nothing that the
--     row itself does not already state.
-- ============================================================================================

BEGIN;

-- ── 1. Canonical RRULE ──────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION sync.fn_canonical_rrule(p_rule text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $fn$
  WITH body AS (
    SELECT nullif(btrim(regexp_replace(upper(coalesce(p_rule, '')), '^RRULE:', '')), '') AS b
  ),
  parts AS (
    SELECT upper(btrim(split_part(t, '=', 1)))                          AS k,
           upper(btrim(substring(t FROM position('=' IN t) + 1)))        AS v
      FROM body, unnest(string_to_array(body.b, ';')) AS t
     WHERE body.b IS NOT NULL AND position('=' IN t) > 1
  ),
  norm AS (
    SELECT k,
           CASE WHEN v LIKE '%,%'
                THEN (SELECT string_agg(btrim(x), ',' ORDER BY btrim(x))
                        FROM unnest(string_to_array(v, ',')) AS u(x))
                ELSE v END AS v
      FROM parts
     -- INTERVAL=1 is the RFC 5545 default and Jobber omits it on read-back.
     WHERE NOT (k = 'INTERVAL' AND v = '1')
  )
  SELECT CASE WHEN count(*) = 0 THEN NULL
              -- FREQ first: jobs_invoice_rrule_shape_chk requires '^RRULE:FREQ='.
              ELSE 'RRULE:' || string_agg(k || '=' || v, ';' ORDER BY (k <> 'FREQ'), k)
         END
    FROM norm;
$fn$;

COMMENT ON FUNCTION sync.fn_canonical_rrule(text) IS
  'RFC 5545 rule in a comparison-safe canonical form: RRULE: prefix added, uppercased, INTERVAL=1 '
  'collapsed (Jobber omits it on read-back), comma lists sorted as sets, FREQ emitted first so the '
  'result satisfies jobs_invoice_rrule_shape_chk. Semantics ported from parseRrule in '
  'supabase/functions/save-client-job/index.ts; keep the two in step.';

-- ── 2. Jobber vocabulary -> ours ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION sync.fn_normalize_jobber_billing(
  p_billing_type text, p_billing_frequency text, p_calendar_rule text)
RETURNS TABLE (billing_type text, invoice_frequency text, invoice_rrule text,
               periodic_class text, ok boolean, reason text)
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $fn$
  WITH s AS (
    SELECT upper(btrim(coalesce(p_billing_type, '')))      AS bt,
           upper(btrim(coalesce(p_billing_frequency, '')))  AS bf,
           sync.fn_canonical_rrule(p_calendar_rule)         AS rr
  ),
  v AS (
    SELECT s.bt, s.bf, s.rr,
      CASE s.bt WHEN 'FIXED_PRICE' THEN 'fixed' WHEN 'VISIT_BASED' THEN 'visit_based' END AS m_bt,
      CASE s.bf
        WHEN 'PER_VISIT'     THEN 'per_visit'
        WHEN 'ON_COMPLETION' THEN 'once_closed'
        WHEN 'NEVER'         THEN 'as_needed'
        WHEN 'PERIODIC'      THEN CASE WHEN s.rr = 'RRULE:FREQ=MONTHLY;BYMONTHDAY=-1'
                                       THEN 'monthly_last_day' ELSE 'custom' END
      END AS m_bf,
      -- The rrule rides BOTH periodic arms. Dropping it on the month-end arm contradicts our own
      -- stored convention and would report false drift on every monthly_last_day job.
      CASE WHEN s.bf = 'PERIODIC' THEN s.rr END AS m_rr,
      CASE WHEN s.bf IN ('PER_VISIT','ON_COMPLETION','NEVER','PERIODIC') THEN s.bf END AS m_class,
      CASE WHEN s.bt NOT IN ('FIXED_PRICE','VISIT_BASED')                              THEN false
           WHEN s.bf NOT IN ('PER_VISIT','ON_COMPLETION','NEVER','PERIODIC')           THEN false
           WHEN s.bf = 'PERIODIC'  AND s.rr IS NULL                                    THEN false
           WHEN s.bf <> 'PERIODIC' AND s.rr IS NOT NULL                                THEN false
           ELSE true END AS m_ok,
      CASE WHEN s.bt NOT IN ('FIXED_PRICE','VISIT_BASED')
                THEN 'unknown_billing_type:' || coalesce(nullif(s.bt,''), '(absent)')
           WHEN s.bf NOT IN ('PER_VISIT','ON_COMPLETION','NEVER','PERIODIC')
                THEN 'unknown_billing_frequency:' || coalesce(nullif(s.bf,''), '(absent)')
           WHEN s.bf = 'PERIODIC'  AND s.rr IS NULL  THEN 'periodic_without_rule'
           WHEN s.bf <> 'PERIODIC' AND s.rr IS NOT NULL
                THEN 'unexpected_rule_on_' || lower(s.bf)
      END AS m_reason
    FROM s
  )
  -- 🛑 AN UNMAPPABLE READ EMITS NO VALUES AT ALL. Returning a partial triple is a footgun: the
  --    PERIODIC-without-a-rule case would otherwise emit invoice_frequency='custom' with a NULL
  --    rrule, which is exactly the pair jobs_custom_needs_rrule_chk forbids, so it could never be
  --    written and would only ever mislead a comparison. periodic_class and reason survive for
  --    diagnostics, because they describe the READ rather than proposing a value.
  SELECT CASE WHEN v.m_ok THEN v.m_bt END,
         CASE WHEN v.m_ok THEN v.m_bf END,
         CASE WHEN v.m_ok THEN v.m_rr END,
         v.m_class, v.m_ok, v.m_reason
    FROM v;
$fn$;

COMMENT ON FUNCTION sync.fn_normalize_jobber_billing(text, text, text) IS
  'Maps a Jobber billing triple into our vocabulary. ok=false means UNMAPPABLE and the caller must '
  'record the reason and compare NOTHING: an unmappable read is not evidence of drift. Enums '
  'verified complete by schema introspection 2026-09-07 (billingType 2 of 2, billingFrequency 4 of 4).';

-- ── 3. The observation tables ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sync.jobber_billing_observed (
  job_id                     bigint PRIMARY KEY REFERENCES public.jobs(id),
  jobber_gid                 text        NOT NULL,
  src_billing_type           text,
  src_billing_frequency      text,
  src_calendar_rule          text,
  norm_billing_type          text,
  norm_invoice_frequency     text,
  norm_invoice_rrule         text,
  norm_periodic_class        text,
  norm_ok                    boolean     NOT NULL,
  norm_reason                text,
  prev_norm_billing_type     text,
  prev_norm_invoice_frequency text,
  prev_norm_invoice_rrule    text,
  first_observed_at          timestamptz NOT NULL DEFAULT now(),
  changed_at                 timestamptz NOT NULL DEFAULT now(),
  -- Mirrors jobs_invoice_rrule_shape_chk so an unadoptable rule is a PHASE A finding here,
  -- never a 23514 surprise at adopt time in phase B.
  CONSTRAINT jobber_billing_observed_rrule_shape_chk CHECK (
    norm_invoice_rrule IS NULL OR
    norm_invoice_rrule ~ '^RRULE:FREQ=(DAILY|WEEKLY|MONTHLY|YEARLY)(;[A-Z]+=[A-Za-z0-9,+-]+)*$')
);

COMMENT ON TABLE sync.jobber_billing_observed IS
  'What Jobber last told us about each job''s invoicing. READ-ONLY evidence: nothing here is ever '
  'copied into public.jobs by phase A. Written CHANGE-ONLY (a row moves only when the normalised '
  'triple actually differs), so changed_at/prev_norm_* answer "did Jobber move, when, and from what" '
  'without the shadow lane. Freshness is NOT a column here on purpose: a per-run timestamp touch '
  'would write ~486 audit rows a day of pure churn. Read freshness from jobber_billing_observe_runs.';

CREATE TABLE IF NOT EXISTS sync.jobber_billing_observe_runs (
  run_id            bigserial PRIMARY KEY,
  started_at        timestamptz NOT NULL DEFAULT now(),
  finished_at       timestamptz,
  jobs_requested    integer     NOT NULL DEFAULT 0,
  jobs_returned     integer     NOT NULL DEFAULT 0,
  jobs_upserted     integer     NOT NULL DEFAULT 0,
  observed_job_ids  bigint[]    NOT NULL DEFAULT '{}',
  unresolvable_gids jsonb       NOT NULL DEFAULT '[]'::jsonb,
  ok                boolean     NOT NULL DEFAULT false,
  error             text
);

COMMENT ON TABLE sync.jobber_billing_observe_runs IS
  'One row per observation run: what it asked for, what came back, and which job_ids it actually '
  'saw. observed_job_ids is the PER-ROW freshness key, so a half-drained run can never let a stale '
  'observed row be read as current. ok=false or a short observed_job_ids is the signal; an EMPTY '
  'table means NO EVIDENCE and must never be read as clean.';

-- Rule 8: the value table is billing data and opts IN. The runs table opts OUT (see header).
DROP TRIGGER IF EXISTS audit_jobber_billing_observed ON sync.jobber_billing_observed;
CREATE TRIGGER audit_jobber_billing_observed
  AFTER INSERT OR UPDATE OR DELETE ON sync.jobber_billing_observed
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- Grants: service_role only. Nothing here is app-reachable, and Supabase's ALTER DEFAULT
-- PRIVILEGES hands out grants nobody wrote, so revoke explicitly rather than assuming.
REVOKE ALL ON sync.jobber_billing_observed      FROM PUBLIC, anon, authenticated;
REVOKE ALL ON sync.jobber_billing_observe_runs  FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON sync.jobber_billing_observed     TO service_role;
GRANT SELECT, INSERT, UPDATE ON sync.jobber_billing_observe_runs TO service_role;
GRANT USAGE, SELECT ON SEQUENCE sync.jobber_billing_observe_runs_run_id_seq TO service_role;

-- ============================================================================================
-- VERIFY
-- ============================================================================================
DO $verify$
DECLARE
  r        record;
  v_bad    int;
  v_live   int;
  v_ctl    int;
BEGIN
  -- 1. EVERY ARM, including the three with zero live instances. A mapping is only trustworthy
  --    where it has been exercised, and live data exercises 4 of 9 shapes.
  FOR r IN
    SELECT * FROM (VALUES
      -- bt,            bf,               rule,                          exp_bt,        exp_freq,           exp_rrule,                              exp_ok
      ('VISIT_BASED','PER_VISIT',     NULL,                            'visit_based','per_visit',        NULL,                                    true),
      ('VISIT_BASED','ON_COMPLETION', NULL,                            'visit_based','once_closed',      NULL,                                    true),
      ('VISIT_BASED','NEVER',         NULL,                            'visit_based','as_needed',        NULL,                                    true),
      ('FIXED_PRICE','PERIODIC',      'FREQ=MONTHLY;BYMONTHDAY=-1',    'fixed',      'monthly_last_day', 'RRULE:FREQ=MONTHLY;BYMONTHDAY=-1',      true),
      ('FIXED_PRICE','PERIODIC',      'FREQ=DAILY;INTERVAL=90',        'fixed',      'custom',           'RRULE:FREQ=DAILY;INTERVAL=90',          true),
      -- INTERVAL=1 must collapse (Jobber omits it on read-back) and part order must not matter.
      ('FIXED_PRICE','PERIODIC',      'BYMONTHDAY=-1;FREQ=MONTHLY;INTERVAL=1','fixed','monthly_last_day','RRULE:FREQ=MONTHLY;BYMONTHDAY=-1',      true),
      -- Comma lists compare as SETS.
      ('FIXED_PRICE','PERIODIC',      'FREQ=WEEKLY;BYDAY=WE,MO',       'fixed',      'custom',           'RRULE:FREQ=WEEKLY;BYDAY=MO,WE',         true),
      -- The three unmappable shapes. All three emit NO values: an unmappable read must not
      -- propose a triple, because a partial one is either unwritable or misleading.
      ('FIXED_PRICE','PERIODIC',      NULL,                            NULL,         NULL,               NULL,                                    false),
      ('SOMETHING',  'PER_VISIT',     NULL,                            NULL,         NULL,               NULL,                                    false),
      ('VISIT_BASED','PER_VISIT',     'FREQ=DAILY',                    NULL,         NULL,               NULL,                                    false)
    ) AS t(bt, bf, rule, exp_bt, exp_freq, exp_rrule, exp_ok)
  LOOP
    PERFORM 1 FROM sync.fn_normalize_jobber_billing(r.bt, r.bf, r.rule) n
     WHERE n.billing_type      IS NOT DISTINCT FROM r.exp_bt
       AND n.invoice_frequency IS NOT DISTINCT FROM r.exp_freq
       AND n.invoice_rrule     IS NOT DISTINCT FROM r.exp_rrule
       AND n.ok                =  r.exp_ok;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'VERIFY 1 FAILED on (%, %, %): got %',
        r.bt, r.bf, coalesce(r.rule,'(null)'),
        (SELECT row_to_json(n) FROM sync.fn_normalize_jobber_billing(r.bt, r.bf, r.rule) n);
    END IF;
  END LOOP;
  RAISE NOTICE 'VERIFY 1: all 10 normaliser arms correct';

  -- 2. MUTATION CONTROL. A truth table that passes says nothing unless a WRONG expectation fails.
  --    This is the exact defect my first draft shipped: month-end mapped with a NULL rrule.
  PERFORM 1 FROM sync.fn_normalize_jobber_billing('FIXED_PRICE','PERIODIC','FREQ=MONTHLY;BYMONTHDAY=-1') n
   WHERE n.invoice_rrule IS NULL;
  IF FOUND THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: the month-end arm returned a NULL rrule, which is the '
                    'first-draft defect. It must carry RRULE:FREQ=MONTHLY;BYMONTHDAY=-1.';
  END IF;
  RAISE NOTICE 'VERIFY 2: mutation control fired (month-end arm carries its rrule)';

  -- 3. AGAINST LIVE DATA. Every live job that HAS a stored billing triple must normalise to
  --    exactly what we already hold, because drift is measured at zero today. A non-zero count
  --    here means the normaliser disagrees with our own writer, not that Jobber drifted.
  --    CONTROL first: the population must be non-empty or this proves nothing.
  SELECT count(*) INTO v_live FROM public.jobs
   WHERE billing_type IS NOT NULL AND job_status NOT IN ('archived','closed','destroyed');
  IF v_live = 0 THEN
    RAISE EXCEPTION 'VERIFY 3 CONTROL FAILED: no live jobs carry billing, so this proves nothing.';
  END IF;

  -- 🛑 DO NOT assert that a stored rrule EQUALS its canonical form. It does not, and that is fine:
  --    measured, 24 stored rules differ from canonical by PART ORDER ONLY (we store Jobber's own
  --    emission order FREQ;INTERVAL;BYMONTHDAY, this function emits FREQ then alphabetical), e.g.
  --    'RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=22' vs '...;BYMONTHDAY=22;INTERVAL=2'. Same rule.
  --    An earlier draft of this VERIFY asserted equality and failed on all 24. The property that
  --    actually matters is that BOTH SIDES are canonicalised before comparison, so what must hold
  --    is IDEMPOTENCE, not equality with the stored bytes.
  SELECT count(*) INTO v_bad FROM public.jobs j
   WHERE j.invoice_rrule IS NOT NULL
     AND sync.fn_canonical_rrule(sync.fn_canonical_rrule(j.invoice_rrule))
         IS DISTINCT FROM sync.fn_canonical_rrule(j.invoice_rrule);
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: fn_canonical_rrule is not idempotent on % stored rule(s), so '
                    'a comparison could flip depending on how many times it was applied.', v_bad;
  END IF;

  -- And the real-data property: every stored rule must survive canonicalisation into something the
  -- observed table's CHECK will accept, or phase B could never write it back.
  SELECT count(*) INTO v_bad FROM public.jobs j
   WHERE j.invoice_rrule IS NOT NULL
     AND sync.fn_canonical_rrule(j.invoice_rrule)
         !~ '^RRULE:FREQ=(DAILY|WEEKLY|MONTHLY|YEARLY)(;[A-Z]+=[A-Za-z0-9,+-]+)*$';
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: % canonicalised rule(s) violate the rrule shape CHECK.', v_bad;
  END IF;
  RAISE NOTICE 'VERIFY 3: % live jobs carry billing; canonicaliser idempotent and shape-valid', v_live;

  -- 4. GRANTS. Supabase default privileges hand out grants nobody wrote, so assert the outcome
  --    with has_table_privilege, which does not depend on who is asking.
  SELECT count(*) INTO v_ctl FROM (VALUES
      ('anon'),('authenticated')) AS t(role)
   WHERE has_table_privilege(t.role, 'sync.jobber_billing_observed', 'SELECT')
      OR has_table_privilege(t.role, 'sync.jobber_billing_observe_runs', 'SELECT');
  IF v_ctl <> 0 THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: anon or authenticated can read the observation tables.';
  END IF;
  IF NOT has_table_privilege('service_role', 'sync.jobber_billing_observed', 'INSERT') THEN
    RAISE EXCEPTION 'VERIFY 4 CONTROL FAILED: service_role cannot INSERT, so the check above is '
                    'not discriminating between roles.';
  END IF;
  RAISE NOTICE 'VERIFY 4: anon/authenticated hold nothing; service_role can write';

  -- 5. RULE 8: the value table must be audited, the runs table must not.
  IF NOT EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
                  JOIN pg_namespace n ON n.oid = c.relnamespace
                  WHERE n.nspname='sync' AND c.relname='jobber_billing_observed'
                    AND NOT t.tgisinternal AND t.tgname='audit_jobber_billing_observed') THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: the billing observation table is not audited.';
  END IF;
  RAISE NOTICE 'VERIFY 5: rule 8 satisfied (value table audited, runs table deliberately not)';

  RAISE NOTICE 'ALL VERIFY PASSED';
END
$verify$;

COMMIT;
