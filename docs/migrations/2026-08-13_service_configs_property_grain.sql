-- ============================================================================
-- 2026-08-13: service_configs -- make the UNIQUENESS KEY equal the LOOKUP KEY
-- ============================================================================
-- 🛑 DO NOT APPLY THIS FILE ON ITS OWN. It has a PREREQUISITE (PART -1 below).
--    PART 5(A) is a hard gate that WILL refuse the migration until that
--    prerequisite has shipped. That refusal is the file working, not failing.
--
-- VERIFICATION STATE OF THIS FILE (2026-08-13, NOT APPLIED):
--   Executed end to end against live Prod inside a transaction that was rolled
--   back, twice: once as written (PART 5(A) fired and named all seven views),
--   and once with the gate's RAISE downgraded to a NOTICE so PARTS 3-6 could
--   run. The second pass reached the end with every assertion passing, so the
--   file is known to parse, to apply, and to be satisfied by the current data.
--   Prod re-checked afterwards and is byte-identical: old constraint present,
--   0 new indexes, 264 rows, config 714 back at 1200 gal, 0 rows on property
--   659, function body unchanged, relacl unchanged.
--
--   🛑 AND THE ASSERTIONS WERE MUTATION-TESTED, because a suite that reports
--   zero failures is an untested instrument. Five deliberate breakages, five
--   distinct catches:
--     leave the old constraint in place      -> 23505 at the gate's twin insert
--                                               (the reported bug, reproduced)
--     omit service_configs_property_service_uniq
--                                            -> (C) "a second Pumping config was
--                                               accepted on property 659"
--     point the gate's twin at a missing row -> "GATE SETUP FAILED"
--     GRANT UPDATE to authenticated          -> (F) "ACL wrong ... authenticated:UPDATE"
--     delete the range check from the body   -> (G4) "the 0..20000 range check
--                                               was lost in the rewrite"
--
-- WHAT SERENA HIT (2026-08-12, Client App, client 450 "Aromas del Peru" 227-PER):
--   editing the grease-trap capacity on a property returned
--     duplicate key value violates unique constraint
--       "service_configs_client_id_service_type_key"
--
-- ROOT CAUSE, in one sentence: client.update_property_capacity LOOKS UP by
--   (property_id, service_type) and the table is UNIQUE on (client_id,
--   service_type). The two keys disagree, so on any property whose client
--   already holds a Pumping config attached to a DIFFERENT property the lookup
--   finds nothing, falls through to INSERT, and the client-scoped constraint
--   rejects it.
--
--   Reproduced exactly, rolled back, 2026-08-13:
--     insert into public.service_configs
--       (client_id, service_type, property_id, equipment_size_gallons)
--     values (450,'Pumping',659,1500);
--     -> 23505 duplicate key ... "service_configs_client_id_service_type_key"
--   Client 450 owns properties 521 (primary) and 659; its only Pumping config
--   (id 714) is pinned to 521 at 1200 gal. Serena was editing 659.
--
-- MEASURED BLAST RADIUS (2026-08-13, live Prod):
--   264 service_configs rows / 195 distinct clients / 227 carry a property_id
--   184 clients are multi-property AND hold a Pumping config
--   209 properties would fail this way on the next capacity save
--   121 rows carry equipment_size_gallons, all of them service_type='Pumping',
--       across 121 distinct clients; 6 of those have property_id IS NULL and are
--       therefore INVISIBLE in the Client App today (client.properties reads the
--       capacity property-scoped: 115 of 893 properties surface one).
--
-- ⚠ AND A NUMBER THAT CHANGES HOW THIS SHOULD BE READ. Of those 209 failing
--   properties, only 48 sit at an address DIFFERENT from the property that
--   already holds the client's Pumping config. The other 161 share the address
--   string exactly. Client 450 is one of the 161: properties 521 and 659 are
--   both "13823 Southwest 88th Street". That is the known service-vs-billing
--   property duplicate pattern, not two sites.
--
--   So this migration unblocks Serena's save, and for 77% of the affected
--   properties what it unblocks is recording a SECOND trap capacity at an
--   address that already has one, silently, with the two values free to
--   diverge. The constraint still has to change (the 48 are real, and a hard
--   failure is not an acceptable answer for the 161 either), but nobody should
--   read "209 properties fixed" as "209 properties were wrong". The property
--   duplication is its own problem and is NOT addressed here.
--
-- ============================================================================
-- (a) WHAT THE INTENDED GRAIN IS -- evidence, not assumption
-- ============================================================================
-- The evidence says PER PROPERTY, and it is not close:
--
--   1. WRITE SIDE. client.update_property_capacity takes p_property_id, looks up
--      by property_id, and INSERTs property_id. It has never been a client-level
--      writer. (Shipped 2026-07-30_2103.)
--   2. READ SIDE. client.properties -- the view the Client App reads back --
--      resolves capacity property-scoped:
--        ( SELECT sc.equipment_size_gallons FROM service_configs sc
--           WHERE sc.property_id = p.id AND sc.service_type = 'Pumping'
--           ORDER BY sc.id LIMIT 1) AS grease_capacity_gallons
--      A client-grain column could not be exposed this way.
--   3. SCHEMA. service_configs.property_id exists, is FK'd to properties, and is
--      populated on 227 of 264 rows. A column that is set on 86% of rows is the
--      grain, whatever the constraint says.
--   4. UI COPY. The Client App form reads "The trap capacity at this property."
--   5. SIBLINGS. public.properties already carries grease_trap_manhole_count and
--      sample_port_count -- the same class of per-property physical fact, written
--      by the same app through client.update_property_operational.
--   6. PHYSICS. A grease trap is a physical vessel at an address. Two sites of
--      one brand routinely have different traps.
--
--   ⚠ THE ONE PIECE OF EVIDENCE POINTING THE OTHER WAY, stated honestly:
--      ADR 003 (docs/decisions/003-service-configs-3nf.md, Accepted 2026-04)
--      writes "One row per (client_id, service_type)" and lists
--      UNIQUE (client_id, service_type) in the decision itself, with
--      equipment_size_gallons already in the column list. So the client-grain
--      constraint is DELIBERATE, not an accident -- it just predates property_id
--      and predates a per-property capacity editor. This migration does not
--      overrule ADR 003 by stealth: it narrows the grain of ONE table from
--      (client, service) to (property, service) with a client-scope fallback,
--      and ADR 003 should be superseded in the same cycle.
--
--   ⚠ AND THE ALTERNATIVE FRED SHOULD GET TO RULE ON, because it is genuinely
--      lower-risk than this file. By rule #2 (3NF standing check),
--      equipment_size_gallons does NOT depend on the whole key of a table keyed
--      (client_id, service_type) -- it depends on the property. The properly
--      normalised answer is a column on public.properties, next to
--      grease_trap_manhole_count and sample_port_count. That option changes NO
--      constraint, multiplies NO view, needs no gate, and its migration is a
--      121-row backfill plus repointing 10 read sites. It is more work on the
--      read side and less risk everywhere else. This file implements the
--      constraint change as scoped; it is not a claim that the constraint
--      change is the best available fix.
--
-- ============================================================================
-- (b) WHY TWO PARTIAL UNIQUES AND NOT A COMPOSITE -- compared honestly
-- ============================================================================
-- OPTION A -- UNIQUE (client_id, service_type, property_id)
--   + one object, trivially applies (measured: 0 duplicate groups)
--   - DOES NOT prevent two DIFFERENT clients claiming the same property for the
--     same service. That is not hypothetical: service_configs id 1053 already
--     points client 343 at property 353, which belongs to client 469. (Measured;
--     it is a Cleaning row, so the Pumping path is clean today: 0 mismatches.)
--   - with the DEFAULT NULLS DISTINCT it puts NO limit on client-scope rows: a
--     client could accumulate unlimited property_id-NULL Pumping rows. That is
--     precisely the shape ADR 003 exists to prevent. PG 17.6 is running here so
--     NULLS NOT DISTINCT is available and would close that half -- but it is a
--     quiet, easily-missed keyword that changes the meaning of the whole index.
--   - CRITICALLY: it still does not equal the writer's lookup key, so the class
--     of bug being fixed (lookup key <> uniqueness key) survives intact.
--
-- OPTION B -- two partial uniques  ← CHOSEN
--     (property_id, service_type) WHERE property_id IS NOT NULL
--     (client_id,   service_type) WHERE property_id IS NULL
--   + the first index IS the writer's lookup key, byte for byte. That is the
--     actual defect, and this is the only option that closes it rather than
--     working around it.
--   + one config per property per service, regardless of which client claims it
--     -- so the id-1053 shape can never be created again.
--   + exactly one client-scope fallback row per (client, service), which is what
--     the 37 legacy property_id-NULL rows are and what customer.permits'
--     address-fallback assumes. No NULLS NOT DISTINCT needed.
--   - two objects instead of one, and "partial unique" cannot be a table
--     CONSTRAINT in Postgres, only a UNIQUE INDEX. Consequence for callers:
--     ON CONFLICT must now spell the predicate,
--       ON CONFLICT (property_id, service_type) WHERE property_id IS NOT NULL
--     or it raises 42P10. See PART -1 note 3.
--
-- BOTH options relax client-grain uniqueness identically, so NEITHER is safer on
-- the consumer axis. The gate in PART 5(A) applies to either.
--
-- ============================================================================
-- PART -1. 🛑 PREREQUISITE. SEVEN LIVE VIEWS MULTIPLY ROWS THE MOMENT A CLIENT
--          HOLDS TWO CONFIGS OF ONE TYPE. THIS IS MEASURED, NOT PREDICTED.
-- ============================================================================
-- The constraint being dropped is not only a uniqueness rule. It is the ONLY
-- thing guaranteeing "at most one service_configs row per (client, service)",
-- and seven views join on exactly that assumption with no LIMIT and no
-- aggregate. Rolled-back probe, 2026-08-13: drop the constraint, add ONE second
-- Pumping config for client 450 on property 659, count rows.
--
--   view                          client 450      whole view        verdict
--   ops.v_calendar_visit            7 ->  12      1769 -> 1774      MULTIPLIES
--   public.visits_with_status         (n/a)       1769 -> 1774      MULTIPLIES
--   customer.clients                1 ->   2       444 ->  445      MULTIPLIES
--   ops.v_derm_compliance           1 ->   2       178 ->  179      MULTIPLIES
--   ops.v_gdo_expiry                1 ->   2         -              MULTIPLIES
--   ops.v_service_due               1 ->   2       178 ->  179      MULTIPLIES
--   public.clients_due_service      1 ->   2       147 ->  148      MULTIPLIES
--   ----------------------------------------------------------------------
--   client.properties               2 ->   2                        safe (LIMIT 1)
--   public.client_services_flat     1 ->   1       444 ->  444      safe (max())
--   customer.work_orders              -            646 ->  646      safe (LIMIT 1)
--   customer.permits                  -            132 ->  132      safe (LATERAL)
--   ops.v_route_today               0 ->   0                        NOT MEASURED
--
-- ⚠ TWO OF THOSE "safe" READINGS WERE DEAD INSTRUMENTS ON THE FIRST PASS, and
--   saying so is the point. ops.v_service_due and public.clients_due_service
--   both showed delta 0 until I noticed each filters on last_visit /
--   frequency_days being non-null, and my twin row carried neither. Re-run with
--   a FULLY POPULATED twin (frequency, last_visit, first_visit, price copied
--   from the real row) and both multiply. A zero from a filtered view is not a
--   pass; it is a row that never entered the view.
--
-- ⚠ ops.v_route_today IS STILL UNMEASURED AND MUST NOT BE READ AS SAFE. The view
--   returns 0 rows in total today (it is scoped to visit_date = CURRENT_DATE),
--   so the probe had nothing to multiply. Its join is
--     LEFT JOIN service_configs sc ON sc.client_id = c.id
--                                 AND sc.service_type = v.service_type
--   which is structurally identical to ops.v_calendar_visit's, and its GROUP BY
--   list includes sc.equipment_size_gallons -- so two configs carrying DIFFERENT
--   capacities split into two rows. INFERRED from the definition; harden it with
--   the other six.
--
-- USAGE, so nobody dismisses this as theoretical (pg_stat_statements):
--   ops.v_calendar_visit 43,010 calls · ops.v_service_due 3,650 ·
--   public.client_services_flat 3,281 · the customer.* client surface ~101k.
--   ops.v_calendar_visit is the most-read view in the warehouse and it feeds the
--   Visit Calendar chip grid. A duplicated visit chip is a visible ops incident.
--
-- ---------------------------------------------------------------------------
-- PREREQUISITE MIGRATION A -- harden the seven consumers FIRST, then apply this.
-- ---------------------------------------------------------------------------
-- The transformation is mechanical: replace the plain join with a LATERAL that
-- returns at most one config, preferring the contextual property, then the
-- client-scope fallback, then lowest id:
--
--   LEFT JOIN LATERAL (
--     SELECT sc.*
--       FROM public.service_configs sc
--      WHERE sc.client_id    = <client>
--        AND sc.service_type = <type>
--      ORDER BY (sc.property_id = <contextual property>) DESC NULLS LAST,
--               (sc.property_id IS NULL)                 DESC,
--               sc.id
--      LIMIT 1
--   ) sc ON true
--
--   view                        <contextual property>   join kind to preserve
--   ops.v_calendar_visit        v.property_id           LEFT
--   public.visits_with_status   v.property_id           LEFT
--   ops.v_route_today           v.property_id           LEFT
--   customer.clients            p.id (primary property) LEFT
--   ops.v_gdo_expiry            g.property_id           LEFT
--   ops.v_derm_compliance       p.id (primary property) INNER  -> CROSS JOIN LATERAL
--   ops.v_service_due           p.id (primary property) INNER  -> CROSS JOIN LATERAL
--
--   🛑 ops.v_derm_compliance and ops.v_service_due are INNER joins today: a
--      client with no Pumping config is CORRECTLY absent. Use CROSS JOIN LATERAL
--      (or JOIN LATERAL ... ON true), never LEFT, or 250-odd clients appear that
--      never did. ops.v_service_due additionally emits one row per service_type
--      by design -- collapse WITHIN a type, never across.
--
--   🛑 COPY EACH VIEW BODY, DO NOT RETYPE IT (CLAUDE.md, 2026-08-06). Canonical
--      sources: scripts/ops_views/{v_calendar_visit,02_v_service_due,
--      03_v_route_today,05_v_gdo_expiry,06_v_derm_compliance}.sql; the other two
--      from pg_get_viewdef. Use CREATE OR REPLACE VIEW, never DROP + CREATE --
--      a DROP discards the grants.
--
--   ✅ EACH VIEW CHANGE IS PROVABLY A NO-OP TODAY, and the prerequisite migration
--      should assert it: with at most one config per (client, service) today, a
--      LIMIT 1 cannot change any row. Snapshot
--        md5(array_agg(t::text ORDER BY <pk>)) FROM <view> t
--      before and after, in the same transaction, and require equality.
--
-- NOTE 2 -- TWO WRITERS STILL SPELL ON CONFLICT (client_id, service_type). Both
--   are dead today; neither is deleted here, and both raise 42P10 the moment
--   they run after this migration:
--     supabase/functions/webhook-airtable/index.ts:293
--       .upsert(row, { onConflict: 'client_id,service_type' })
--       -- Airtable is fully retired (2026-07-24) and this path is doubly dead:
--         it writes service_type 'GT'/'CL'/'WD', which
--         service_configs_service_type_chk has REJECTED (23514) since the
--         2026-08-03 rename.
--     scripts/populate/populate.js:763
--       bulkUpsert('service_configs', rows, cols, ['client_id','service_type'])
--       -- manual only; it appears in no workflow. Measured, not assumed.
--   Fix when either is next touched: ON CONFLICT (property_id, service_type)
--   WHERE property_id IS NOT NULL.
--
-- NOTE 3 -- scripts/sync/cron_generate_recurring_visits.js:276 iterates
--   (client x service_config) pairs on a bare client_id join. Two Pumping
--   configs would process a client twice. Its schedule has been commented out
--   since 2026-06-02 and SA generation now runs in Postgres via
--   public.fn_generate_sa_visits (which does not read service_configs at all --
--   measured: client.update_property_capacity is the ONLY pg_proc in the
--   database whose body mentions service_configs). Latent, recorded, not fixed.
--
-- ============================================================================
-- AUDIT-TRAIL STANDING CHECK (rule 8 / ADR 010): OPT-IN, ALREADY IN PLACE,
--   UNCHANGED BY THIS FILE.
--   public.service_configs already carries the trigger `audit_service_configs`
--   -> audit.log_change (generated from pg_trigger, not read off a list --
--   CLAUDE.md rule 8 says never trust the hand-maintained list). No table is
--   added, renamed, or dropped here; no trigger is touched. Dropping and adding
--   constraints/indexes does not affect triggers. PART 6 re-asserts the trigger
--   is still attached after the fact rather than assuming it.
--   Live evidence the trail works: audit.logs holds 4 rows for this table from
--   app_source='client-app' (2026-07-31 x2 by fred@ayache.com, 2026-08-12 x2 by
--   contact@unclogme.com -- the second of those is Serena's session, one INSERT
--   and one UPDATE that DID land, on clients that happened to dodge the bug).
--
-- GRANTS: unchanged in effect, re-asserted explicitly in PART 4. Measured
--   BEFORE: {postgres=arwdDxtm/postgres, service_role=arwdDxtm/postgres,
--            authenticated=r/postgres, yannick_readonly=r/postgres}
--   i.e. authenticated holds SELECT only and anon holds nothing -- already
--   correct. The REVOKE below is therefore a NO-OP today and is written anyway,
--   because 2026-08-07_1420 is the precedent: a migration that only verifies the
--   GRANT statements it wrote passes while the object stays open. The assertion
--   that matters is the one that reads the catalogue AFTER the fact.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 1. Pre-flight. Can the two new indexes actually be built on the 264 live
--         rows? Refuse loudly rather than half-applying.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  n_prop_dup   int;
  n_client_dup int;
  n_control    int;
  detail       text;
BEGIN
  SELECT count(*) INTO n_prop_dup FROM (
    SELECT 1 FROM public.service_configs
     WHERE property_id IS NOT NULL
     GROUP BY property_id, service_type HAVING count(*) > 1) z;

  SELECT count(*) INTO n_client_dup FROM (
    SELECT 1 FROM public.service_configs
     WHERE property_id IS NULL
     GROUP BY client_id, service_type HAVING count(*) > 1) z;

  -- 🛑 POSITIVE CONTROL. Two zeros above are only meaningful if this GROUP BY /
  --    HAVING instrument can find a duplicate group at all. Grouping the same
  --    264 rows by service_type alone MUST return 3 groups (Pumping 184,
  --    Cleaning 32, Warranty of Drainage 48, measured 2026-08-13). A zero here
  --    means the query is broken, not that the data is clean.
  SELECT count(*) INTO n_control FROM (
    SELECT 1 FROM public.service_configs GROUP BY service_type HAVING count(*) > 1) z;

  IF n_control < 1 THEN
    RAISE EXCEPTION 'CONTROL FAILED: the duplicate-group probe found no duplicate service_type groups in % rows. The instrument is broken; the two zeros below prove nothing.',
      (SELECT count(*) FROM public.service_configs);
  END IF;

  IF n_prop_dup > 0 THEN
    SELECT string_agg(format('property %s / %s x%s', property_id, service_type, c), '; ')
      INTO detail
      FROM (SELECT property_id, service_type, count(*) c FROM public.service_configs
             WHERE property_id IS NOT NULL GROUP BY 1,2 HAVING count(*) > 1) d;
    RAISE EXCEPTION 'BLOCKED: % (property_id, service_type) duplicate group(s) would break service_configs_property_service_uniq: %', n_prop_dup, detail;
  END IF;

  IF n_client_dup > 0 THEN
    SELECT string_agg(format('client %s / %s x%s', client_id, service_type, c), '; ')
      INTO detail
      FROM (SELECT client_id, service_type, count(*) c FROM public.service_configs
             WHERE property_id IS NULL GROUP BY 1,2 HAVING count(*) > 1) d;
    RAISE EXCEPTION 'BLOCKED: % (client_id, service_type) duplicate group(s) among property-less rows would break service_configs_client_service_nullprop_uniq: %', n_client_dup, detail;
  END IF;

  RAISE NOTICE 'pre-flight OK: 0 blocking duplicate groups, control fired with % service_type group(s)', n_control;
END $$;

-- ---------------------------------------------------------------------------
-- PART 2. Swap the key.
-- ---------------------------------------------------------------------------
-- Dropping the constraint drops its backing index of the same name. Nothing
-- else depends on it: pg_depend shows no FK, no view and no function
-- referencing service_configs_client_id_service_type_key (measured 2026-08-13).
ALTER TABLE public.service_configs
  DROP CONSTRAINT service_configs_client_id_service_type_key;

-- THE grain. This index IS the lookup key client.update_property_capacity uses,
-- which is the whole fix: the writer can no longer look one thing up and be
-- rejected by another.
CREATE UNIQUE INDEX service_configs_property_service_uniq
  ON public.service_configs (property_id, service_type)
  WHERE property_id IS NOT NULL;

-- The legacy client-scope fallback. 37 rows carry no property_id (19 Pumping,
-- 16 Cleaning, 2 Warranty of Drainage -- measured). Every one of the 19 Pumping
-- ones belongs to a MULTI-property client, which is why this migration does not
-- try to auto-attach them to a primary property: there is no correct property to
-- pick. They stay client-scoped and remain exactly one per (client, service).
CREATE UNIQUE INDEX service_configs_client_service_nullprop_uniq
  ON public.service_configs (client_id, service_type)
  WHERE property_id IS NULL;

COMMENT ON INDEX public.service_configs_property_service_uniq IS
  'THE grain of service_configs as of 2026-08-13: one config per (property, service). '
  'Replaces UNIQUE (client_id, service_type), which disagreed with the lookup key used by '
  'client.update_property_capacity and rejected every capacity save on the 209 properties '
  'whose client already held a config on a different property. Also blocks two clients '
  'claiming one property (service_configs id 1053 is a pre-existing example, Cleaning).';

COMMENT ON INDEX public.service_configs_client_service_nullprop_uniq IS
  'Client-scope fallback: at most one property-less config per (client, service). Preserves '
  'the ADR 003 guarantee for the 37 rows that predate property_id, and is what '
  'customer.permits'' address-fallback assumes.';

-- ---------------------------------------------------------------------------
-- PART 3. The writer. COPIED from pg_get_functiondef(client.update_property_capacity)
--         as it stood on 2026-08-13, then edited. Everything outside the block
--         marked CHANGED is byte-identical to the live body -- the auth gate, the
--         staff-domain gate, the 0..20000 range check, the property lookup and
--         the P0002, all unmodified.
-- ---------------------------------------------------------------------------
-- DIFF, stated so it can be checked rather than trusted:
--   1. + v_owner bigint   (new local)
--   2. lookup now reads client_id alongside id, so a cross-client config can be
--      detected instead of silently written to. There are 0 Pumping mismatches
--      today (measured) and 1 Cleaning one (id 1053), so this guard is latent --
--      but without it the RPC would, on the day one appears, edit another
--      client's capacity and report success.
--   3. `order by id limit 1` KEPT. It is now redundant (the new partial unique
--      makes the lookup return at most one row) and is kept precisely because it
--      is redundant: if the index is ever dropped the RPC still behaves.
--   4. + property_id and action in the returned jsonb. ADDITIVE only -- the app
--      reads service_config_id and gallons, both unchanged in name and meaning.
--      This follows the Client App "report what LANDED, not what was requested"
--      rule: the caller can now see which config row its save actually hit.
--   NOT changed, deliberately: there is no "adopt the client-scope row" branch.
--   It would have been dead code -- all 19 property-less Pumping rows belong to
--   multi-property clients (measured), so a single-property adopt case does not
--   exist to be exercised.
CREATE OR REPLACE FUNCTION client.update_property_capacity(p_property_id bigint, p_gallons integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_client bigint;
  v_id     bigint;
  v_owner  bigint;                                            -- CHANGED (1)
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_gallons is not null and (p_gallons < 0 or p_gallons > 20000) then
    raise exception 'Capacity must be between 0 and 20,000 gallons.' using errcode = '22023';
  end if;
  select client_id into v_client from public.properties where id = p_property_id;
  if v_client is null then
    raise exception 'property % not found', p_property_id using errcode = 'P0002';
  end if;

  -- Prefer the property-scoped Pumping config; update in place. If none exists,
  -- create a minimal Pumping row (frequency NULL -- inert to the legacy
  -- due-service logic, which keys on frequency). service_configs is audited,
  -- so the edit is captured with app_source. (Was GT before 2026-08-03.)
  --
  -- CHANGED (2)(3), 2026-08-13: the lookup key below is now the UNIQUENESS key
  -- (service_configs_property_service_uniq). Before this pair of changes the
  -- INSERT below could be rejected by a constraint the SELECT could not see,
  -- which is exactly the 23505 Serena reported on 227-PER.
  select id, client_id into v_id, v_owner from public.service_configs
   where property_id = p_property_id and service_type = 'Pumping'
   order by id limit 1;
  if v_id is not null and v_owner is distinct from v_client then
    raise exception 'service config % is attached to property % but belongs to client %, not client %; fix the ownership before editing capacity',
      v_id, p_property_id, v_owner, v_client using errcode = '22023';
  end if;
  if v_id is not null then
    update public.service_configs set equipment_size_gallons = p_gallons where id = v_id;
  else
    insert into public.service_configs (client_id, service_type, property_id, equipment_size_gallons)
    values (v_client, 'Pumping', p_property_id, p_gallons)
    returning id into v_id;
  end if;
  return jsonb_build_object('service_config_id', v_id, 'gallons', p_gallons,
                            'property_id', p_property_id,                    -- CHANGED (4)
                            'action', case when v_owner is null then 'created' else 'updated' end);
end
$function$;

-- ---------------------------------------------------------------------------
-- PART 4. ACL. Explicit REVOKE, then re-assert the intended set. A no-op today
--         (measured) and written anyway -- see the GRANTS note in the header.
-- ---------------------------------------------------------------------------
REVOKE ALL ON public.service_configs FROM anon;
REVOKE ALL ON public.service_configs FROM authenticated;

GRANT SELECT ON public.service_configs TO authenticated;
GRANT SELECT ON public.service_configs TO yannick_readonly;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.service_configs TO service_role;

-- CREATE OR REPLACE FUNCTION preserves proacl, but Supabase's ALTER DEFAULT
-- PRIVILEGES has handed out EXECUTE nobody wrote before now. Re-assert rather
-- than assume; PART 5(F) reads it back.
REVOKE ALL ON FUNCTION client.update_property_capacity(bigint, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION client.update_property_capacity(bigint, integer) FROM anon;
GRANT EXECUTE ON FUNCTION client.update_property_capacity(bigint, integer) TO authenticated;

-- ---------------------------------------------------------------------------
-- PART 5. Assertions that EXERCISE the change. An index that exists is not an
--         index that bites, and a grant statement that ran is not an ACL.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_twin   bigint;
  v_new    bigint;
  v_before jsonb := '{}'::jsonb;
  v_after  jsonb := '{}'::jsonb;
  v_bad    text[] := array[]::text[];
  v_obj    text;
  v_n      bigint;
  v_seen   bigint;
  v_cnt    int;
BEGIN
  -- =========================================================================
  -- (A) 🛑 CONSUMER SAFETY GATE. This is the reason the file cannot be applied
  --     before PREREQUISITE MIGRATION A. It inserts one extra Pumping config
  --     for client 450 on property 659 -- the exact row Serena's save would
  --     create -- and requires that no client-grain view grows.
  -- =========================================================================
  FOR v_obj, v_n IN
    SELECT 'ops.v_calendar_visit',       count(*) FROM ops.v_calendar_visit       WHERE client_id = 450
    UNION ALL SELECT 'public.visits_with_status',  count(*) FROM public.visits_with_status  WHERE client_id = 450
    UNION ALL SELECT 'customer.clients',           count(*) FROM customer.clients           WHERE client_code = '227-PER'
    UNION ALL SELECT 'ops.v_derm_compliance',      count(*) FROM ops.v_derm_compliance      WHERE client_code = '227-PER'
    UNION ALL SELECT 'ops.v_gdo_expiry',           count(*) FROM ops.v_gdo_expiry           WHERE client_code = '227-PER'
    UNION ALL SELECT 'ops.v_service_due',          count(*) FROM ops.v_service_due          WHERE client_code = '227-PER'
    UNION ALL SELECT 'public.clients_due_service', count(*) FROM public.clients_due_service WHERE client_code = '227-PER'
    UNION ALL SELECT 'ops.v_route_today',          count(*) FROM ops.v_route_today          WHERE client_id = 450
    UNION ALL SELECT 'client.properties',          count(*) FROM client.properties          WHERE client_id = 450
    UNION ALL SELECT 'public.client_services_flat',count(*) FROM public.client_services_flat WHERE client_code = '227-PER'
  LOOP
    v_before := v_before || jsonb_build_object(v_obj, v_n);
  END LOOP;

  -- The twin is FULLY POPULATED (frequency, last_visit, first_visit, price copied
  -- from the live row). 🛑 DO NOT SIMPLIFY THIS TO A BARE (client, type, property,
  -- gallons) INSERT. ops.v_service_due and public.clients_due_service both filter
  -- on frequency_days / last_visit, so a sparse twin never enters those views and
  -- they report a FALSE PASS. That happened on the first run of this probe.
  INSERT INTO public.service_configs
    (client_id, service_type, property_id, equipment_size_gallons,
     frequency_days, last_visit, first_visit, price_per_visit)
  SELECT 450, 'Pumping', 659, 999,
         sc.frequency_days, sc.last_visit, sc.first_visit, sc.price_per_visit
    FROM public.service_configs sc
   WHERE sc.client_id = 450 AND sc.service_type = 'Pumping' AND sc.property_id = 521
  RETURNING id INTO v_twin;

  IF v_twin IS NULL THEN
    RAISE EXCEPTION 'GATE SETUP FAILED: the twin row was not inserted, so nothing below measured anything. Has client 450 / property 521 changed?';
  END IF;

  -- 🛑 CONTROL FOR THE GATE ITSELF. A gate that reports "nothing multiplied" is
  --    worthless unless the twin is actually visible to the read layer. The
  --    passthrough view MUST see one more row. If it does not, every zero below
  --    is an untested instrument, not an all-clear.
  SELECT count(*) INTO v_seen FROM client.service_configs WHERE client_id = 450 AND service_type = 'Pumping';
  IF v_seen < 2 THEN
    RAISE EXCEPTION 'GATE CONTROL FAILED: client.service_configs shows % Pumping row(s) for client 450 after inserting a twin. The probe is not observing the insert, so the view checks below prove nothing.', v_seen;
  END IF;

  FOR v_obj, v_n IN
    SELECT 'ops.v_calendar_visit',       count(*) FROM ops.v_calendar_visit       WHERE client_id = 450
    UNION ALL SELECT 'public.visits_with_status',  count(*) FROM public.visits_with_status  WHERE client_id = 450
    UNION ALL SELECT 'customer.clients',           count(*) FROM customer.clients           WHERE client_code = '227-PER'
    UNION ALL SELECT 'ops.v_derm_compliance',      count(*) FROM ops.v_derm_compliance      WHERE client_code = '227-PER'
    UNION ALL SELECT 'ops.v_gdo_expiry',           count(*) FROM ops.v_gdo_expiry           WHERE client_code = '227-PER'
    UNION ALL SELECT 'ops.v_service_due',          count(*) FROM ops.v_service_due          WHERE client_code = '227-PER'
    UNION ALL SELECT 'public.clients_due_service', count(*) FROM public.clients_due_service WHERE client_code = '227-PER'
    UNION ALL SELECT 'ops.v_route_today',          count(*) FROM ops.v_route_today          WHERE client_id = 450
    UNION ALL SELECT 'client.properties',          count(*) FROM client.properties          WHERE client_id = 450
    UNION ALL SELECT 'public.client_services_flat',count(*) FROM public.client_services_flat WHERE client_code = '227-PER'
  LOOP
    v_after := v_after || jsonb_build_object(v_obj, v_n);
  END LOOP;

  FOR v_obj IN SELECT jsonb_object_keys(v_before) LOOP
    IF (v_after ->> v_obj)::bigint > (v_before ->> v_obj)::bigint THEN
      v_bad := v_bad || format('%s %s->%s', v_obj, v_before ->> v_obj, v_after ->> v_obj);
    END IF;
  END LOOP;

  DELETE FROM public.service_configs WHERE id = v_twin;

  IF array_length(v_bad, 1) IS NOT NULL THEN
    RAISE EXCEPTION E'GATE FAILED -- PREREQUISITE MIGRATION A HAS NOT SHIPPED.\n'
      'Relaxing the client-grain uniqueness multiplies rows in: %\n'
      'Harden those consumers with the LATERAL ... LIMIT 1 transformation in PART -1 first. '
      'ops.v_route_today returns 0 rows outside service hours, so a clean result for it here is '
      'NOT evidence -- check it by definition, not by count.', array_to_string(v_bad, ', ');
  END IF;

  -- =========================================================================
  -- (B) THE FIX ITSELF. The exact statement that raised 23505 on 2026-08-12
  --     must now succeed.
  -- =========================================================================
  BEGIN
    INSERT INTO public.service_configs (client_id, service_type, property_id, equipment_size_gallons)
    VALUES (450, 'Pumping', 659, 1500)
    RETURNING id INTO v_new;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'FIX FAILED: the insert that broke Serena''s save still fails: % / %', SQLSTATE, SQLERRM;
  END;

  -- ...and it must COEXIST with the existing config on property 521, or the
  -- rejection tested in (C) would just be "everything is rejected".
  SELECT count(*) INTO v_cnt FROM public.service_configs
   WHERE client_id = 450 AND service_type = 'Pumping';
  IF v_cnt <> 2 THEN
    RAISE EXCEPTION 'FIX FAILED: expected 2 Pumping configs for client 450 (properties 521 and 659), found %', v_cnt;
  END IF;

  -- =========================================================================
  -- (C) A GENUINE DUPLICATE IS STILL REJECTED -- same property, same service.
  -- =========================================================================
  BEGIN
    INSERT INTO public.service_configs (client_id, service_type, property_id, equipment_size_gallons)
    VALUES (450, 'Pumping', 659, 1600);
    RAISE EXCEPTION 'GUARD FAILED: a second Pumping config was accepted on property 659; service_configs_property_service_uniq does not bite';
  EXCEPTION
    WHEN unique_violation THEN NULL;
    WHEN OTHERS THEN
      IF SQLERRM LIKE 'GUARD FAILED%' THEN RAISE; END IF;
      RAISE EXCEPTION 'property uniqueness raised an unexpected error: % / %', SQLSTATE, SQLERRM;
  END;

  -- ...including from a DIFFERENT client, which UNIQUE (client_id, service_type,
  -- property_id) would have allowed. This is the concrete advantage of Option B.
  BEGIN
    INSERT INTO public.service_configs (client_id, service_type, property_id, equipment_size_gallons)
    VALUES (449, 'Pumping', 659, 1700);
    RAISE EXCEPTION 'GUARD FAILED: a second client took property 659 for Pumping; the property index is not client-agnostic as intended';
  EXCEPTION
    WHEN unique_violation THEN NULL;
    WHEN foreign_key_violation THEN
      RAISE EXCEPTION 'CONTROL FAILED: client 449 does not exist, so this assertion tested nothing. Pick a live client id.';
    WHEN OTHERS THEN
      IF SQLERRM LIKE 'GUARD FAILED%' OR SQLERRM LIKE 'CONTROL FAILED%' THEN RAISE; END IF;
      RAISE EXCEPTION 'cross-client property uniqueness raised an unexpected error: % / %', SQLSTATE, SQLERRM;
  END;

  -- =========================================================================
  -- (D) THE CLIENT-SCOPE FALLBACK IS STILL EXACTLY ONE PER (client, service).
  --     Two property-less Warranty rows for one client must be rejected.
  -- =========================================================================
  DECLARE v_wd_client bigint;
  BEGIN
    SELECT client_id INTO v_wd_client FROM public.service_configs
     WHERE property_id IS NULL AND service_type = 'Warranty of Drainage' LIMIT 1;
    IF v_wd_client IS NULL THEN
      RAISE EXCEPTION 'CONTROL FAILED: no property-less Warranty of Drainage row exists, so the client-scope index was never exercised. Measured 2 on 2026-08-13.';
    END IF;
    BEGIN
      INSERT INTO public.service_configs (client_id, service_type, property_id)
      VALUES (v_wd_client, 'Warranty of Drainage', NULL);
      RAISE EXCEPTION 'GUARD FAILED: a second property-less Warranty of Drainage config was accepted for client %; service_configs_client_service_nullprop_uniq does not bite', v_wd_client;
    EXCEPTION
      WHEN unique_violation THEN NULL;
      WHEN OTHERS THEN
        IF SQLERRM LIKE 'GUARD FAILED%' THEN RAISE; END IF;
        RAISE EXCEPTION 'client-scope uniqueness raised an unexpected error: % / %', SQLSTATE, SQLERRM;
    END;
  END;

  -- =========================================================================
  -- (E) NEGATIVE CONTROL FOR THE INDEXES: the same client may still hold a
  --     DIFFERENT service on the same property. If this is rejected, the
  --     indexes are over-blocking and (C)/(D) proved nothing.
  -- =========================================================================
  BEGIN
    INSERT INTO public.service_configs (client_id, service_type, property_id)
    VALUES (450, 'Cleaning', 659);
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'CONTROL FAILED: a Cleaning config on property 659 was rejected, so the property index is blocking across service types: % / %', SQLSTATE, SQLERRM;
  END;

  -- undo everything (B)-(E) created, so (G) meets a clean property 659.
  DELETE FROM public.service_configs
   WHERE client_id = 450 AND property_id = 659;

  -- =========================================================================
  -- (G) 🛑 EXERCISE THE NEW FUNCTION BODY. PL/pgSQL IS NOT PARSED AT CREATION
  --     TIME, so PART 3 applying cleanly says nothing about whether the
  --     function runs. This is the 2026-08-06 lesson: a 42803 sailed straight
  --     through CREATE OR REPLACE and raised for 3.5 hours on live traffic.
  --     A staff JWT is simulated locally so both branches really execute.
  -- =========================================================================
  DECLARE
    v_res      jsonb;
    v_orig_gal numeric;
    v_readback numeric;
  BEGIN
    SELECT equipment_size_gallons INTO v_orig_gal
      FROM public.service_configs WHERE id = 714;

    PERFORM set_config('request.jwt.claims',
      '{"sub":"00000000-0000-4000-8000-000000000001","email":"probe@unclogme.com"}', true);

    -- G1: UPDATE branch. Property 521 already has config 714.
    v_res := client.update_property_capacity(521, 1234);
    IF (v_res ->> 'action') <> 'updated' OR (v_res ->> 'service_config_id')::bigint <> 714
       OR (v_res ->> 'property_id')::bigint <> 521 THEN
      RAISE EXCEPTION 'RPC UPDATE branch returned the wrong shape: %', v_res;
    END IF;

    -- G2: INSERT branch on property 659. THIS IS THE BUG. It raised 23505 on
    --     2026-08-12 and must now create a second config for the same client.
    v_res := client.update_property_capacity(659, 1500);
    IF (v_res ->> 'action') <> 'created' THEN
      RAISE EXCEPTION 'RPC INSERT branch did not create a row on property 659: %', v_res;
    END IF;

    -- G3: THE READ-BACK. A write nobody can see is not a fix. client.properties
    --     is the exact view the Client App reads, so assert there, not on the
    --     base table.
    SELECT grease_capacity_gallons INTO v_readback
      FROM client.properties WHERE id = 659;
    IF v_readback IS DISTINCT FROM 1500 THEN
      RAISE EXCEPTION 'read-back failed: client.properties.grease_capacity_gallons for property 659 is %, expected 1500', v_readback;
    END IF;

    -- G4: the COPIED range guard must have survived the CREATE OR REPLACE.
    --     This is the retype check: if the body had been retyped from memory
    --     rather than copied, guards like this are what silently vanish.
    BEGIN
      PERFORM client.update_property_capacity(521, 25000);
      RAISE EXCEPTION 'GUARD FAILED: the 0..20000 range check was lost in the rewrite';
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLERRM LIKE 'GUARD FAILED%' THEN RAISE; END IF;
        IF SQLSTATE <> '22023' THEN
          RAISE EXCEPTION 'range check raised % instead of 22023: %', SQLSTATE, SQLERRM;
        END IF;
    END;

    -- G5: the COPIED auth gate must also have survived. With no JWT the
    --     function must refuse, or the SECDEF wrapper is an open door.
    PERFORM set_config('request.jwt.claims', '', true);
    BEGIN
      PERFORM client.update_property_capacity(521, 100);
      RAISE EXCEPTION 'GUARD FAILED: the auth gate was lost; update_property_capacity ran with no JWT';
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLERRM LIKE 'GUARD FAILED%' THEN RAISE; END IF;
        IF SQLSTATE <> '28000' THEN
          RAISE EXCEPTION 'auth gate raised % instead of 28000: %', SQLSTATE, SQLERRM;
        END IF;
    END;

    -- revert the test mutations (standing rule: probes leave no trace)
    DELETE FROM public.service_configs WHERE client_id = 450 AND property_id = 659;
    UPDATE public.service_configs SET equipment_size_gallons = v_orig_gal WHERE id = 714;
    IF (SELECT equipment_size_gallons FROM public.service_configs WHERE id = 714)
       IS DISTINCT FROM v_orig_gal THEN
      RAISE EXCEPTION 'failed to restore config 714 capacity to %', v_orig_gal;
    END IF;
  END;

  SELECT count(*) INTO v_cnt FROM public.service_configs;
  IF v_cnt <> 264 THEN
    RAISE NOTICE 'row count is % (was 264 at authoring time on 2026-08-13) -- verify no probe row survived', v_cnt;
  END IF;

  -- =========================================================================
  -- (F) ACL, read back from the catalogue. Never trust the GRANT statements.
  -- =========================================================================
  IF has_table_privilege('anon', 'public.service_configs', 'SELECT') THEN
    v_bad := v_bad || 'anon:SELECT'; END IF;
  FOREACH v_obj IN ARRAY ARRAY['INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'] LOOP
    IF has_table_privilege('authenticated', 'public.service_configs', v_obj) THEN
      v_bad := v_bad || ('authenticated:' || v_obj); END IF;
    IF has_table_privilege('anon', 'public.service_configs', v_obj) THEN
      v_bad := v_bad || ('anon:' || v_obj); END IF;
  END LOOP;
  IF array_length(v_bad, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'ACL wrong on public.service_configs: % still granted', array_to_string(v_bad, ', ');
  END IF;

  IF NOT has_table_privilege('authenticated', 'public.service_configs', 'SELECT') THEN
    RAISE EXCEPTION 'authenticated lost SELECT; every client/ops/customer view that reads this table would 42501';
  END IF;
  IF NOT has_table_privilege('service_role', 'public.service_configs', 'INSERT') THEN
    RAISE EXCEPTION 'service_role lost INSERT'; END IF;
  IF NOT has_table_privilege('yannick_readonly', 'public.service_configs', 'SELECT') THEN
    RAISE EXCEPTION 'yannick_readonly lost SELECT'; END IF;

  -- SIBLING CONTROL, same intended model (authenticated = SELECT only, anon =
  -- nothing). Measured identical on 2026-08-13 for public.clients, public.gdos,
  -- public.jobs and public.properties.
  IF has_table_privilege('authenticated', 'public.clients', 'UPDATE')
     OR NOT has_table_privilege('authenticated', 'public.clients', 'SELECT') THEN
    RAISE EXCEPTION 'SIBLING CONTROL FAILED: public.clients does not match the intended model, so the assertions above are measuring against a premise that has expired';
  END IF;

  -- 🛑 DISCRIMINATING CONTROL. has_table_privilege must be capable of returning
  --    TRUE for a write. public.zones deliberately grants authenticated
  --    INSERT+UPDATE (the Visit Calendar zone editor). If this reads false the
  --    probe is stuck on "no" and every clean result above is meaningless.
  IF NOT has_table_privilege('authenticated', 'public.zones', 'UPDATE') THEN
    RAISE EXCEPTION 'DISCRIMINATING CONTROL FAILED: authenticated cannot UPDATE public.zones, which it must (zone editor). The privilege probe is not discriminating.';
  END IF;

  -- function EXECUTE: authenticated yes, anon and PUBLIC no
  IF NOT has_function_privilege('authenticated', 'client.update_property_capacity(bigint,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated lost EXECUTE on client.update_property_capacity; the Edit-property dialog would 42501';
  END IF;
  IF has_function_privilege('anon', 'client.update_property_capacity(bigint,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon can EXECUTE client.update_property_capacity';
  END IF;

  RAISE NOTICE 'OK: property grain bites, client-scope fallback intact, cross-service still allowed, ACL asserted, 7-view gate passed';
END $$;

-- ---------------------------------------------------------------------------
-- PART 6. Catalogue assertions. Read the objects back; do not trust PART 2.
-- ---------------------------------------------------------------------------
DO $$
DECLARE n int;
BEGIN
  -- the old constraint is gone
  SELECT count(*) INTO n FROM pg_constraint
   WHERE conrelid = 'public.service_configs'::regclass
     AND conname = 'service_configs_client_id_service_type_key';
  IF n <> 0 THEN RAISE EXCEPTION 'the old client-grain constraint survived'; END IF;

  -- both new indexes exist, are UNIQUE and are PARTIAL
  SELECT count(*) INTO n FROM pg_indexes
   WHERE schemaname = 'public' AND tablename = 'service_configs'
     AND indexname IN ('service_configs_property_service_uniq',
                       'service_configs_client_service_nullprop_uniq')
     AND indexdef ILIKE '%UNIQUE%' AND indexdef ILIKE '%WHERE%';
  IF n <> 2 THEN RAISE EXCEPTION 'expected 2 partial unique indexes, found %', n; END IF;

  -- ADR 010 / rule 8: the audit trigger is still attached. Generated, not
  -- read off a list.
  SELECT count(*) INTO n
    FROM pg_trigger t
    JOIN pg_proc p ON p.oid = t.tgfoid
    JOIN pg_namespace pn ON pn.oid = p.pronamespace
   WHERE t.tgrelid = 'public.service_configs'::regclass
     AND NOT t.tgisinternal
     AND pn.nspname = 'audit' AND p.proname = 'log_change';
  IF n <> 1 THEN
    RAISE EXCEPTION 'ADR 010: audit.log_change trigger on public.service_configs is missing (found %)', n;
  END IF;

  -- RLS is still enabled AND forced (it was true/true before this file)
  SELECT count(*) INTO n FROM pg_class
   WHERE oid = 'public.service_configs'::regclass
     AND relrowsecurity AND relforcerowsecurity;
  IF n <> 1 THEN RAISE EXCEPTION 'RLS on public.service_configs is no longer enabled+forced'; END IF;

  RAISE NOTICE 'catalogue OK: old constraint gone, 2 partial uniques present, audit trigger attached, RLS enabled+forced';
END $$;

COMMIT;

-- ============================================================================
-- SAME-CYCLE DOCUMENTATION (CLAUDE.md §4b -- an app-visible change is documented
-- in the app's own folder, by whoever ships it):
--   Building Apps/Client App/docs/08-changelog.md   dated entry: the capacity
--     save now works on every property; the RPC returns property_id + action.
--   Supabase/docs/decisions/003-service-configs-3nf.md  supersede the
--     "one row per (client_id, service_type)" line; the grain is now
--     (property_id, service_type) with a client-scope fallback.
--   Supabase/CLAUDE.md  column-name gotchas / the grants-and-views section:
--     record that seven client-grain views depended on the dropped constraint
--     for their cardinality, since that is the non-obvious hazard here.
-- ============================================================================
