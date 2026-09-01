-- 2026-09-02_0010_zones_short_label.sql
--
-- WHAT: public.zones gains SHORT_LABEL, a 2-character display name, backfilled for all 11 zones.
--       client.zones and public.zones_with_usage are extended to serve it.
--
-- WHY:  Fred, 2026-09-01: "zones should be the same across all apps (Clients and Calendar
--       specially)". Measured across all 8 staff hosts (82 chunks, 7.5 MB), there are THREE zone
--       vocabularies in production and only two apps render a zone at all:
--
--         CODE   'PALM'        public.zones.code, served by 14 views. Every Client App chip.
--         LABEL  'Palm Beach'  public.zones.label, served by 3 objects. Calendar filter panel,
--                              Client App zone picker.
--         'PB'                 HARDCODED IN THE VISIT CALENDAR BUNDLE. In no database row.
--
--       The third one is the problem. calendar.unclogme.app/assets/index-DFOcd9-S.js @477331:
--         const Ri={"MIAMI BEACH":"MB",AVE:"AV",NMB:"NM",DOWN:"DT",MID:"ME",EDG:"ME",
--                   SF:"SF",BH:"SF",SOUTH:"SO",BRO:"BR",PALM:"PB",SUNNY:"SU",WEST:"WE"}
--       read by md() @482779 at three visit-chip call sites. Fred's decision: give the database the
--       short form and DELETE Ri.
--
-- THE REASON THIS IS WORTH A COLUMN RATHER THAN LEAVING THE MAP ALONE: md()'s last arm is
--    `return t.slice(0,2)`. A zone added through the Calendar's OWN Zone Manager (which any
--    signed-in staff browser can do: public.zones is `authenticated=arw` with three USING(true)
--    policies) renders as its first two characters, silently and with no error. Executed against
--    the live map, md('NEWZONE') returns 'NE'. That fallback is the defect; the column removes
--    the need for it.
--
-- VALUES: adopted verbatim from Ri, per Fred, so the Calendar chips do not visibly change at
--    cutover. Proven a no-op by EXECUTING the extracted md() against all 11 real codes:
--    9 resolve by exact key, and SF/BH -> SF and MID/EDG -> ME resolve through the substring arm
--    (Ri carries 13 keys for 11 zones because it splits both compound codes). Every one matches
--    the value backfilled below.
--
-- BOTH VIEWS MUST BE EXTENDED IN THIS SAME MIGRATION, or the column is invisible to the apps.
--    client.zones is an EXPLICIT COLUMN LIST, so a new base-table column does not appear in it.
--    That is the trap observed_at hit on 2026-08-03 and is_auto_retryable hit on 2026-07-29:
--    shipped, correct, and consumed by nothing. CREATE OR REPLACE VIEW can only APPEND, so
--    short_label goes LAST in both, and REPLACE (not DROP+CREATE) preserves the grants.
--
-- NULLABLE ON PURPOSE, and this is not laziness. The Calendar's Zone Manager INSERTs zones
--    (bundle @318889) and does not yet send short_label. A NOT NULL column with no default would
--    make that INSERT fail with a 400 the moment this applies, breaking a working feature to
--    protect a column nothing reads yet. Order of operations: column now, app writes it next,
--    NOT NULL last. The CHECK still binds every non-null write from today.
--
-- A NULL short_label must render as a VISIBLE placeholder in the app, never as a truncation.
--    Falling back to code.slice(0,2) would re-create the exact silent defect being removed here.
--
-- RULE 8 (audit): NO ACTION NEEDED. public.zones already carries audit_zones
--    (AFTER INSERT OR UPDATE OR DELETE -> audit.log_change), confirmed against the generated list
--    rather than a hand-maintained one. Adding a column to an already-audited table is captured
--    automatically (full-row JSONB), per ADR 010.
-- RULE 2 (3NF): short_label depends on the whole key (the zone) and on nothing else. It is an
--    authored display string, not derivable from code or label: 'MIAMI BEACH' -> 'MB' and
--    'MID/EDG' -> 'ME' are editorial choices, not a function of the source text.
-- RULE 1/3: unaffected. No source-prefixed column, nothing copied.

BEGIN;

ALTER TABLE public.zones ADD COLUMN IF NOT EXISTS short_label text;

COMMENT ON COLUMN public.zones.short_label IS
  'Two-character display name for dense chips (Visit Calendar visit chips). Authored, not derived. Replaces the hardcoded Ri map in the Calendar bundle. NULL means not yet authored: render a visible placeholder, NEVER a truncation of code.';

UPDATE public.zones SET short_label = v.s
FROM (VALUES
  ('SOUTH','SO'), ('AVE','AV'), ('NMB','NM'), ('BRO','BR'), ('SF/BH','SF'),
  ('DOWN','DT'), ('MIAMI BEACH','MB'), ('SUNNY','SU'), ('PALM','PB'),
  ('MID/EDG','ME'), ('WEST','WE')
) AS v(c, s)
WHERE public.zones.code = v.c
  AND public.zones.short_label IS DISTINCT FROM v.s;

ALTER TABLE public.zones DROP CONSTRAINT IF EXISTS zones_short_label_shape_chk;
ALTER TABLE public.zones ADD CONSTRAINT zones_short_label_shape_chk
  CHECK (short_label IS NULL OR short_label ~ '^[A-Z0-9]{2}$');

-- Append short_label LAST in both views. REPLACE preserves grants; the column order is fixed.
CREATE OR REPLACE VIEW client.zones AS
  SELECT code, label, color_hex, color_token, sort_order, is_active, created_at, updated_at, id,
         short_label
    FROM public.zones;

CREATE OR REPLACE VIEW public.zones_with_usage AS
  SELECT z.id, z.code, z.label, z.color_hex, z.color_token, z.sort_order, z.is_active,
         z.created_at, z.updated_at,
         COALESCE(p.n_properties, 0) AS n_properties,
         z.short_label
    FROM public.zones z
    LEFT JOIN ( SELECT properties.zone_id,
                       count(*)::integer AS n_properties
                  FROM public.properties
                 WHERE properties.zone_id IS NOT NULL AND properties.deleted_at IS NULL
                 GROUP BY properties.zone_id) p ON p.zone_id = z.id;

DO $$
DECLARE
  v_null int; v_bad int; v_total int; v_mismatch int;
  v_cz int; v_zu int; v_auth boolean; v_label text;
BEGIN
  SELECT count(*) FILTER (WHERE short_label IS NULL),
         count(*) FILTER (WHERE short_label !~ '^[A-Z0-9]{2}$'),
         count(*)
    INTO v_null, v_bad, v_total FROM public.zones;
  IF v_total <> 11 OR v_null <> 0 OR v_bad <> 0 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: % zones, % null short_label, % malformed', v_total, v_null, v_bad;
  END IF;

  -- 2. CONTROL: every value must equal what the LIVE Calendar map produces today, so this is a
  --    visual no-op. Hardcoded here from executing the extracted md(); if a value ever drifts from
  --    the bundle this assertion is what catches it.
  SELECT count(*) INTO v_mismatch FROM public.zones z
   WHERE (z.code, z.short_label) NOT IN (
     ('SOUTH','SO'), ('AVE','AV'), ('NMB','NM'), ('BRO','BR'), ('SF/BH','SF'),
     ('DOWN','DT'), ('MIAMI BEACH','MB'), ('SUNNY','SU'), ('PALM','PB'),
     ('MID/EDG','ME'), ('WEST','WE'));
  IF v_mismatch <> 0 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: % zone(s) do not match the Calendar current rendering', v_mismatch;
  END IF;

  -- 3. the column actually REACHES both views. This is the observed_at trap; without it the
  --    migration can be perfectly correct and still be invisible to every app.
  SELECT count(*) INTO v_cz FROM information_schema.columns
   WHERE table_schema='client' AND table_name='zones' AND column_name='short_label';
  SELECT count(*) INTO v_zu FROM information_schema.columns
   WHERE table_schema='public' AND table_name='zones_with_usage' AND column_name='short_label';
  IF v_cz <> 1 OR v_zu <> 1 THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: short_label reaches client.zones=% zones_with_usage=%', v_cz, v_zu;
  END IF;

  -- 4. grants survived the REPLACE (they would not have survived DROP+CREATE)
  SELECT has_table_privilege('authenticated','client.zones','SELECT') INTO v_auth;
  IF NOT v_auth THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: authenticated lost SELECT on client.zones';
  END IF;

  -- 5. the label correction from 2026-09-01_2130 is still in place and was not disturbed
  SELECT label INTO v_label FROM public.zones WHERE code='PALM';
  IF v_label IS DISTINCT FROM 'Palm Beach' THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: PALM label is %, expected Palm Beach', v_label;
  END IF;

  RAISE NOTICE 'OK: 11 zones carry a 2-char short_label; both views serve it; grants intact.';
END $$;

COMMIT;
