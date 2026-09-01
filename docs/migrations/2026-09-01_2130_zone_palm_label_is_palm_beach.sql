-- 2026-09-01_2130_zone_palm_label_is_palm_beach.sql
--
-- WHAT: public.zones code 'PALM' is relabelled from 'Palmetto Bay' to 'Palm Beach'. One row, one
--       column. No code, colour, sort order, property assignment or app is changed.
--
-- WHY:  Fred, 2026-09-01, on the Client App: "there is one called Palm but it should be Palm Beach".
--       He is right, and this is a seed error rather than a preference. Three independent facts:
--
--       1. THE ZONE CONTAINS NO PALMETTO BAY. Its 11 live properties are Boca Raton (6),
--          Delray Beach (3), Coconut Creek (1) and Jupiter (1).
--          county: Palm Beach 6, Broward 5, Dade 0. Properties whose city is Palmetto Bay: 0.
--       2. PALMETTO BAY BELONGS TO A DIFFERENT ZONE. docs/research/unclogme-design-system.md maps
--          SOUTH to "Homestead, Cutler Bay, Palmetto Bay, Pinecrest, Kendall south", and maps
--          PALM to "Palm Beach County" in as many words. The abbreviation PALM was expanded wrongly
--          when the table was seeded.
--       3. THE TWO REAL PALMETTO BAY PROPERTIES ARE NOT IN THIS ZONE. Both have zone_id IS NULL,
--          so nothing anywhere is relying on this label to describe them.
--
--       Origin: docs/migrations/2026-05-27_zones_reference_table.sql line 105 seeded
--       ('PALM', 'Palmetto Bay', ...). audit.logs id 8989 records that INSERT on 2026-05-28 01:18 ET
--       as app_source='sql'. The only later edits (9383, 9384, visit-calendar) were a typo and its
--       repair within eight seconds, so the value has never been deliberately reconsidered.
--
-- 🛑 THE 2026-05-27 SEED WOULD REVERT THIS. It is written
--    ON CONFLICT (code) DO UPDATE SET label = EXCLUDED.label, and its own comment calls it
--    "idempotent", which invites a re-run. Re-running that file today restores 'Palmetto Bay'
--    silently, with an audit row and no error. A header note has been added to that file pointing
--    here. Nothing re-runs it on a schedule, so this is a trap for a person, not a live regression.
--
-- RULE 8 (audit): NO CHANGE NEEDED. public.zones already carries the audit_zones trigger
--    (AFTER INSERT OR UPDATE OR DELETE -> audit.log_change). Verified against the generated list, not
--    a hand-maintained one. The old value is therefore recoverable from audit.logs.old_row, which is
--    what makes this a reversible edit rather than a destructive one.
--
-- RULE 1/2/3 (source-agnostic, 3NF, reference): unaffected. This is a text correction to a reference
--    table; no column is added, copied or derived.
--
-- NOT IN SCOPE, deliberately, and each is recorded so it is not lost:
--   a) The zone CODE stays 'PALM'. It is UNIQUE and is a stable key; renaming a key to fix a display
--      string is the wrong lever. If an app renders the code to a user, that is an app bug.
--   b) FOUR BOCA RATON PROPERTIES CARRY county='Broward' AND THAT IS FACTUALLY WRONG (ids 62, 68,
--      53, 4). Boca Raton is in Palm Beach County. Coconut Creek (149) genuinely is Broward.
--      properties.county feeds derm.v_lwt_monthly_rows, whose scope predicate keys on 'Dade', so
--      neither value changes any filing today. Left for a person.
--   c) The design-system doc gives PALM the colour #14b8a6; the table holds #ECECEC. Every one of the
--      11 colours differs from that doc, so the doc records an older palette, not a drift. The live
--      palette is what the Visit Calendar renders. Not touched.

BEGIN;

-- Pinned to BOTH the key and the value being corrected, so it cannot fire if the world moved
-- between the measurement above and this statement.
UPDATE public.zones
   SET label = 'Palm Beach'
 WHERE code  = 'PALM'
   AND label = 'Palmetto Bay';

DO $$
DECLARE
  v_label       text;
  v_others      int;
  v_palmetto    int;
  v_dade        int;
  v_code_count  int;
BEGIN
  -- 1. the row moved, and to exactly the intended value
  SELECT label INTO v_label FROM public.zones WHERE code = 'PALM';
  IF v_label IS DISTINCT FROM 'Palm Beach' THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: PALM label is %, expected Palm Beach', v_label;
  END IF;

  -- 2. CONTROL: nothing else moved. The other ten labels must still read exactly as seeded.
  --    Without this, a botched UPDATE that rewrote every row would pass VERIFY 1.
  SELECT count(*) INTO v_others
    FROM public.zones
   WHERE (code, label) NOT IN (
     ('SOUTH','South Dade'), ('AVE','Aventura'), ('NMB','North Miami Beach'),
     ('BRO','Broward'), ('SF/BH','Surfside / Bal Harbour'), ('DOWN','Downtown Miami'),
     ('MIAMI BEACH','Miami Beach'), ('SUNNY','Sunny Isles'), ('PALM','Palm Beach'),
     ('MID/EDG','Midtown / Edgewater'), ('WEST','West Miami'));
  IF v_others <> 0 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: % zone row(s) do not match the expected vocabulary', v_others;
  END IF;

  SELECT count(*) INTO v_code_count FROM public.zones;
  IF v_code_count <> 11 THEN
    RAISE EXCEPTION 'VERIFY 2b FAILED: % zones, expected 11', v_code_count;
  END IF;

  -- 3. the justification still holds at commit time: this zone is not Palmetto Bay and not Dade
  SELECT count(*) FILTER (WHERE p.city ILIKE '%palmetto%'),
         count(*) FILTER (WHERE p.county = 'Dade')
    INTO v_palmetto, v_dade
    FROM public.properties p
    JOIN public.zones z ON z.id = p.zone_id
   WHERE z.code = 'PALM' AND p.deleted_at IS NULL;
  IF v_palmetto <> 0 OR v_dade <> 0 THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: PALM zone holds % Palmetto Bay and % Dade properties; the '
                    'premise for this rename no longer holds', v_palmetto, v_dade;
  END IF;

  RAISE NOTICE 'OK: PALM relabelled to Palm Beach; 10 other zones unchanged; 11 zones total.';
END $$;

COMMIT;

-- POST-MIGRATION
--   select code, label from public.zones order by sort_order;
--   -- and the revert, if ever needed, is recorded by the audit trigger:
--   select old_row->>'label', new_row->>'label', changed_at
--     from audit.logs where table_name='zones' and new_row->>'code'='PALM' order by changed_at desc;
