-- 2026-09-01_1600  Show the GDO permit's frequency when we have none of our own,
--                  and stop a stored ZERO passing as a real pump frequency.
--
-- Fred, looking at 117-BH on the Field Portal Service Report: the "GDO Permits &
-- Frequency" card reads "Every 0 days". His instruction: for clients that are only
-- ACTIVE (no service agreement, so no cadence of ours), show the frequency printed on
-- the GDO permit instead.
--
-- WHAT THE APP ACTUALLY RENDERS, measured against the live fp.unclogme.app bundle
-- rather than assumed: the 3-column grid in chunk `_clientSlug_.visit._visitId-*.js`
-- builds each row as `{... our_frequency_days: c.our_frequency_days ...}` and its
-- freq cell branches on `h.our_frequency_days === null`. So a NULL is handled and a
-- ZERO is not: 0 sails past the null check and prints "Every 0 days". That is why
-- this is fixable here, in the view, with NO app change and no publish.
--
-- TWO DEFECTS, and the second is the serious one.
--
-- 1. A STORED ZERO OUTRANKS A REAL FREQUENCY. `our_frequency_days` is
--    COALESCE(sc.frequency_days, jf.freq). The `jf` arm correctly requires
--    `frequency_days > 0`; the `sc` arm only required IS NOT NULL. 117-BH holds a
--    `Pumping` service_config with frequency_days = 0 sitting in front of a job
--    carrying 30, so the zero won. 4 such zero rows exist in service_configs.
--
-- 2. THOSE ROWS WERE REPORTED COMPLIANT. `compliant` is `ours <= max_frequency_days`,
--    and `0 <= 90` is true, so the Field Portal told 3 clients they meet the county's
--    maximum interval on the strength of a number that means "we do not know". That is
--    a false compliance claim on a customer-facing document.
--
-- 3. THE JOB FALLBACK ACCEPTED ANY JOB, INCLUDING ONES THAT DO NO PUMPING. It was added
--    2026-07-08 to cover service_configs rows with a NULL property_id and filters only
--    `frequency_days > 0`. Measured: 15 permits take their number from a job and 5 of
--    those jobs are not pumping work at all. **This is what fixing defect 1 exposed**:
--    with the zero gone, 117-BH resolved to 30 from a "Service Agreement - Cleaning -
--    Main Line Cleaning" job, i.e. a main-line cadence printed in a column headed PUMP
--    FREQUENCY, which is not what Fred asked for on the row he was looking at.
--    The other four are all **Warranty of Drainage**, which per the standing rule is a
--    billing subscription whose job carries NO visits (71 of 71 such jobs have none), so
--    its `frequency_days` is an INVOICING cadence. Two of them (065-TCE and 066-TCE,
--    both `max_frequency_days` 30 against a WD cadence of 60) were being shown an amber
--    NON-compliance warning derived from a billing cycle. False in the other direction.
--    ⇒ `jf` now requires the job to carry a pumping line item, decided by the estate's
--    single implementation of that question, `public.fn_line_item_requires_derm(li.name)`
--    (the same helper `fn_visit_requires_derm` uses). Do not inline a second copy of the
--    rule or a title regex: `line_items` has no FK to the catalogue, it matches by NAME,
--    and that helper is where the name handling lives.
--    ⚠ That helper is SECURITY INVOKER, so putting it inside this owner-rights view adds
--    an invoker-side privilege check to the FP's read path. Verified before use:
--    `authenticated` holds EXECUTE on it and SELECT on `service_line_items`, `line_items`
--    and `jobs`. The VERIFY below reads the view AS `authenticated` rather than trusting
--    that reasoning, because this exact asymmetry has broken four things already.
--
-- 🛑 SO THE DISPLAY FALLBACK MUST NOT FEED THE COMPLIANCE VERDICT. Adding
-- `g.max_frequency_days` to the COALESCE fixes the display and, done naively, recreates
-- defect 2 in a new costume: every fallback row would then compute `max <= max` = TRUE
-- and claim compliance from the county's own limit. The two are therefore separated:
--   * `our_frequency_days`  = COALESCE(ours, gdo)   -- what the card DISPLAYS
--   * `compliant`           = ours <= max, NULL when `ours` is unknown  -- never the gdo
-- `frequency_source` is added so a reader can tell the two apart. It is APPENDED last,
-- which is what keeps this a CREATE OR REPLACE rather than a drop and recreate (a drop
-- discards grants; `authenticated` and `service_role` hold SELECT here).
--
-- ⚠ THE DISPLAYED NUMBER NOW MEANS TWO DIFFERENT THINGS and that is Fred's explicit
-- call (2026-09-01), made after being shown the alternative of a qualifier: he chose a
-- plain "Every 90 days" for consistency with the other rows. Ours is a SCHEDULE, the
-- permit's is a county-mandated MAXIMUM INTERVAL, and `reference_gdo_frequency_vs_job_frequency`
-- exists because those are not the same fact. `frequency_source` is how anything
-- downstream can still tell which it is holding; do not drop it to tidy the view.
--
-- Scope measured before writing: 131 permits, 3 reading 0, 20 reading NULL, 108 with a
-- real frequency, and ALL 23 of the gaps have a `max_frequency_days` on file, so the
-- fallback covers every affected row. 5 permits have no GDO frequency at all and are
-- unaffected either way.
--
-- Rule 8: no new table, so no audit opt-in decision. One view.

begin;

-- Snapshot BEFORE, so the assertions below compare against the real prior state rather
-- than against my expectations of it.
create temp table _permits_before on commit drop as
select permit_number, client_id, our_frequency_days, compliant, max_frequency_days
  from customer.permits;

create or replace view customer.permits as
 SELECT customer.uuid_from_bigint(g.id) AS id,
    customer.uuid_from_bigint(g.client_id) AS client_id,
    g.gdo_number AS permit_number,
    'Grease Trap'::text AS area,
        CASE
            WHEN g.max_frequency_days IS NULL THEN NULL::text
            WHEN g.max_frequency_days <= 35 THEN 'Monthly'::text
            WHEN g.max_frequency_days <= 95 THEN 'Quarterly'::text
            WHEN g.max_frequency_days <= 185 THEN 'Semi-annually'::text
            WHEN g.max_frequency_days <= 380 THEN 'Annually'::text
            ELSE ('Every '::text || g.max_frequency_days) || ' days'::text
        END AS frequency,
    g.permit_document_path AS permit_url,
    (row_number() OVER (PARTITION BY g.client_id ORDER BY g.property_id, g.gdo_number) - 1)::integer AS "position",
    customer.uuid_from_bigint(g.property_id) AS property_id,
    g.location_label,
    g.permit_expiration,
    g.max_frequency_days,
        CASE
            WHEN g.max_frequency_days IS NULL THEN NULL::boolean
            ELSE COALESCE((CURRENT_DATE - (( SELECT max(v.visit_date) AS max
               FROM visits v
                 JOIN properties vp ON vp.id = v.property_id
              WHERE v.client_id = g.client_id AND v.visit_status = 'completed'::text AND v.deleted_at IS NULL AND (v.property_id = g.property_id OR lower(btrim(vp.address)) = lower(btrim(gp.address)))))) > g.max_frequency_days, true)
        END AS over_gdo_max,
    -- DISPLAY value: ours if we have one, else the permit's printed interval.
    COALESCE(sc.frequency_days, jf.freq, g.max_frequency_days) AS our_frequency_days,
    -- VERDICT: computed ONLY from a frequency of OURS. Never from the fallback, or it
    -- would compare the county's limit against itself and always say yes.
        CASE
            WHEN COALESCE(sc.frequency_days, jf.freq) IS NULL OR g.max_frequency_days IS NULL THEN NULL::boolean
            ELSE COALESCE(sc.frequency_days, jf.freq) <= g.max_frequency_days
        END AS compliant,
    -- Which of the three the displayed number came from.
        CASE
            WHEN sc.frequency_days IS NOT NULL THEN 'service_config'::text
            WHEN jf.freq IS NOT NULL THEN 'job'::text
            WHEN g.max_frequency_days IS NOT NULL THEN 'gdo_permit'::text
            ELSE NULL::text
        END AS frequency_source
   FROM gdos g
     JOIN clients c ON c.id = g.client_id
     LEFT JOIN properties gp ON gp.id = g.property_id
     LEFT JOIN LATERAL ( SELECT s.frequency_days
           FROM service_configs s
             JOIN properties sp ON sp.id = s.property_id
          WHERE s.client_id = g.client_id AND s.service_type = 'Pumping'::text AND s.frequency_days > 0 AND (s.property_id = g.property_id OR lower(btrim(sp.address)) = lower(btrim(gp.address)))
          ORDER BY (s.property_id = g.property_id) DESC, s.id
         LIMIT 1) sc ON true
     LEFT JOIN LATERAL ( SELECT j.frequency_days AS freq
           FROM jobs j
          WHERE j.client_id = g.client_id AND j.frequency_days > 0
            AND EXISTS (SELECT 1 FROM line_items li
                         WHERE li.job_id = j.id AND li.name IS NOT NULL
                           AND public.fn_line_item_requires_derm(li.name) IS TRUE)
          ORDER BY (j.property_id = g.property_id) DESC NULLS LAST, j.id DESC
         LIMIT 1) jf ON true
  WHERE g.status = 'ACTIVE'::text AND (c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text]));

comment on view customer.permits is
  'One row per ACTIVE GDO permit for an ACTIVE/RECURRING client. our_frequency_days is a DISPLAY value: our pumping cadence if we have one, else the permit''s county-mandated maximum interval, so the Field Portal never renders "Every 0 days". Read frequency_source to tell which. compliant is computed ONLY from a frequency of ours and is NULL when we have none: it must never be derived from the fallback, which would compare the county limit against itself.';

do $$
declare
  v_before_zero    int;
  v_before_falsecomp int;
  v_before_null    int;
  v_before_real    int;
  v_moved          int;
  v_verdict_moved  int;
  v_gaps_now       int;
  v_gaps_sourced   int;
  v_gdo_compliant  int;
  v_117_freq       int;
  v_117_src        text;
  v_117_comp       boolean;
  v_nonpumping_job int;
  v_wd_still_job   int;
  v_authn_rows     int;
  v_acl            text;
begin
  -- 0. CONTROLS ON THE PRIOR STATE. If the defect was not there to begin with, every
  --    assertion below is vacuous and this migration proves nothing.
  select count(*) into v_before_zero from _permits_before where our_frequency_days = 0;
  select count(*) into v_before_falsecomp from _permits_before where our_frequency_days = 0 and compliant is true;
  select count(*) into v_before_null from _permits_before where our_frequency_days is null;
  select count(*) into v_before_real from _permits_before where our_frequency_days > 0;
  if v_before_zero = 0 then
    raise exception 'control failed: no permit read 0 before this change, so the defect being fixed was not present';
  end if;
  if v_before_falsecomp <> v_before_zero then
    raise exception 'control failed: expected every zero row to be falsely compliant, got % of %', v_before_falsecomp, v_before_zero;
  end if;
  if v_before_real = 0 then
    raise exception 'control failed: no permit had a real frequency before, so the regression check below is vacuous';
  end if;

  -- 1. POSITIVE CONTROL, the row Fred is looking at.
  select p.our_frequency_days, p.frequency_source, p.compliant
    into v_117_freq, v_117_src, v_117_comp
    from customer.permits p where p.permit_number = 'GDO-02591';
  if v_117_freq is distinct from 90 then
    raise exception '117-BH GDO-02591 should now display 90, got %', v_117_freq;
  end if;
  if v_117_src is distinct from 'gdo_permit' then
    raise exception '117-BH GDO-02591 source should be gdo_permit, got %', v_117_src;
  end if;
  if v_117_comp is not null then
    raise exception '117-BH GDO-02591 must no longer claim compliance, got %', v_117_comp;
  end if;

  -- 2. REGRESSION, stated as the invariant rather than as "nothing may move".
  --    ⚠ An earlier draft asserted that no permit with a non-zero value may change, and
  --    its own VERIFY rejected it: the pumping restriction is SUPPOSED to move the
  --    Warranty of Drainage rows, which held a real 60. A regression check that forbids
  --    the intended change is not a safety net, it is a broken instrument.
  --    The true invariant: A ROW MAY ONLY MOVE BY FALLING BACK TO THE PERMIT. Anything
  --    still sourced from a frequency of ours must be byte-identical to before.
  select count(*) into v_moved
    from _permits_before b join customer.permits a on a.permit_number = b.permit_number and a.client_id = b.client_id
   where (a.our_frequency_days is distinct from b.our_frequency_days
          or a.compliant is distinct from b.compliant)
     and a.frequency_source is distinct from 'gdo_permit';
  if v_moved <> 0 then
    raise exception 'regression: % permits moved while still sourced from our own frequency', v_moved;
  end if;

  -- 2b. And the mirror of it: a row sourced from OUR frequency must be untouched, in
  --     value and in verdict. Stated separately so a bug in `frequency_source` itself
  --     cannot make check 2 pass vacuously.
  select count(*) into v_verdict_moved
    from _permits_before b join customer.permits a on a.permit_number = b.permit_number and a.client_id = b.client_id
   where a.frequency_source in ('service_config','job')
     and (a.our_frequency_days is distinct from b.our_frequency_days
          or a.compliant is distinct from b.compliant);
  if v_verdict_moved <> 0 then
    raise exception 'regression: % permits sourced from our own frequency changed value or verdict', v_verdict_moved;
  end if;

  -- 3. Every previously-blank row now displays something, and it came from the permit.
  select count(*) into v_gaps_now
    from _permits_before b join customer.permits a on a.permit_number = b.permit_number and a.client_id = b.client_id
   where (b.our_frequency_days = 0 or b.our_frequency_days is null)
     and b.max_frequency_days is not null
     and a.our_frequency_days is null;
  if v_gaps_now <> 0 then
    raise exception '% previously-blank permits still display nothing', v_gaps_now;
  end if;
  select count(*) into v_gaps_sourced
    from _permits_before b join customer.permits a on a.permit_number = b.permit_number and a.client_id = b.client_id
   where (b.our_frequency_days = 0 or b.our_frequency_days is null)
     and b.max_frequency_days is not null
     and (a.frequency_source is distinct from 'gdo_permit' or a.our_frequency_days is distinct from a.max_frequency_days);
  if v_gaps_sourced <> 0 then
    raise exception '% previously-blank permits are not sourced from the permit', v_gaps_sourced;
  end if;

  -- 4. THE ONE THAT MATTERS: a displayed value taken from the permit must never carry
  --    a compliance verdict.
  select count(*) into v_gdo_compliant
    from customer.permits where frequency_source = 'gdo_permit' and compliant is not null;
  if v_gdo_compliant <> 0 then
    raise exception '% permits claim compliance from the fallback, which compares the county limit against itself', v_gdo_compliant;
  end if;

  -- 4b. Every row still sourced from a JOB must be sourced from a job that actually
  --     pumps. Without this the Warranty of Drainage billing cadence comes back.
  select count(*) into v_nonpumping_job
    from customer.permits p
    join public.gdos g2 on customer.uuid_from_bigint(g2.id) = p.id
   where p.frequency_source = 'job'
     and not exists (select 1 from public.jobs j
                      join public.line_items li on li.job_id = j.id and li.name is not null
                     where j.client_id = g2.client_id and j.frequency_days > 0
                       and public.fn_line_item_requires_derm(li.name) is true);
  if v_nonpumping_job <> 0 then
    raise exception '% permits still take their pump frequency from a job that does no pumping', v_nonpumping_job;
  end if;

  -- 4c. The four Warranty of Drainage rows must have left the job source. Named
  --     explicitly, because a count alone would pass if some OTHER row moved instead.
  select count(*) into v_wd_still_job
    from customer.permits
   where permit_number in ('GDO-06012','GDO-13822','GDO-11170','GDO-14514')
     and frequency_source <> 'gdo_permit';
  if v_wd_still_job <> 0 then
    raise exception '% of the 4 Warranty of Drainage permits still take a billing cadence as their pump frequency', v_wd_still_job;
  end if;

  -- 4d. THE PRIVILEGE PROBE, and it is the reason this block exists rather than an
  --     argument in the header. The view now calls a SECURITY INVOKER function, so the
  --     only way to know the Field Portal will not get 42501 is to read it AS the role
  --     the Field Portal uses.
  begin
    execute 'set local role authenticated';
    execute 'select count(*) from customer.permits' into v_authn_rows;
    execute 'reset role';
  exception when others then
    execute 'reset role';
    raise exception 'authenticated cannot read customer.permits after this change: % (%)', sqlerrm, sqlstate;
  end;
  if v_authn_rows is null or v_authn_rows = 0 then
    raise exception 'authenticated read customer.permits but saw % rows, expected the full set', v_authn_rows;
  end if;

  -- 5. Grants survived the replace (a DROP would have discarded them).
  select c.relacl::text into v_acl from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'customer' and c.relname = 'permits';
  if not has_table_privilege('authenticated','customer.permits','SELECT')
     or not has_table_privilege('service_role','customer.permits','SELECT') then
    raise exception 'grant FAILED after replace (acl %)', v_acl;
  end if;
  if has_table_privilege('anon','customer.permits','SELECT') then
    raise exception 'anon gained SELECT on customer.permits (acl %)', v_acl;
  end if;

  raise notice 'VERIFY OK: before = % zero / % null / % real; 117-BH now 90 from gdo_permit with NULL verdict; 0 moved, 0 verdicts moved, 0 fallback rows claim compliance; acl %',
               v_before_zero, v_before_null, v_before_real, v_acl;
end $$;

commit;
