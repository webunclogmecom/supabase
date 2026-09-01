-- 2026-09-02_0110_zones_color_dot_hex.sql
--
-- WHAT: public.zones gains COLOR_DOT_HEX, and SOUTH's COLOR_HEX moves from '#2D7FF9' to '#DCEBFF'.
--       Together these move the Visit Calendar's last hardcoded zone value into the database,
--       WITHOUT changing what the Calendar renders. Both views are extended to serve it.
--
-- WHY:  Fred, 2026-09-02: "The zones should be same across all apps, make it all go with how the
--       Calendar App goes." The Calendar is the reference, so every other app must be able to
--       reproduce its rendering from data alone. Today it cannot, because of this:
--
--         const m = {};
--         for (const z of zones) m[z.code] = { bg: z.color_hex, dot: z.color_hex };
--         // SOUTH: keep light wash for chip bg, but use saturated blueBright for the dot swatch.
--         if (m["SOUTH"]) m["SOUTH"] = { bg: "#DCEBFF", dot: "#2D7FF9" };
--
--       (routes/index.tsx:6835-6842). SOUTH is the ONLY zone whose background and dot differ, and
--       the pair lives in app code. The Client App reads color_hex straight as its chip background,
--       so it shows SOUTH as saturated '#2D7FF9' while the Calendar shows the pale wash. Same row,
--       two colours, which is the divergence Fred is asking to close.
--
-- THE SWAP, and why it is a no-op for the Calendar:
--       color_hex     '#2D7FF9' -> '#DCEBFF'   (this is the BACKGROUND; the Calendar already
--                                               renders exactly this value for SOUTH)
--       color_dot_hex NEW       -> '#2D7FF9'   (this is the DOT; also exactly what it renders)
--       Every other zone: color_dot_hex = color_hex, which is what the loop above already produces.
--       So once the app reads bg=color_hex and dot=color_dot_hex and the override is deleted, the
--       Calendar's output is byte-identical to today. VERIFY 2 pins that pair explicitly.
--
-- WHY NOT THE SIMPLER OPTION: setting SOUTH's color_hex to the pale wash and dropping the dot
--       distinction altogether was considered and rejected. The dot is rendered as an 8px
--       `w-2 h-2 rounded-full` swatch in the select dropdowns and as a `borderLeftColor`, on a white
--       ground. '#DCEBFF' there is very nearly invisible. That would have been a real UX regression
--       traded for one fewer column, and it would have changed the Calendar, which is the thing
--       Fred named as the reference.
--
-- NULLABLE, and read it as COALESCE(color_dot_hex, color_hex). A zone created through the
--       Calendar's Zone Manager (which does not send this column) then behaves exactly as every
--       zone does today: dot = background. That is the correct default and it needs no app change
--       to be safe.
--
-- BOTH VIEWS EXTENDED HERE. client.zones is an explicit column list, so a new base-table column is
--       invisible to the Client App until the view carries it. That is the observed_at /
--       is_auto_retryable trap: shipped, correct, consumed by nothing. CREATE OR REPLACE can only
--       APPEND, so the column goes last in both, and REPLACE preserves grants.
--
-- RULE 8 (audit): NO ACTION NEEDED. public.zones already carries audit_zones. The colour change to
--       SOUTH is therefore recoverable from audit.logs.old_row, which is what makes it reversible.
-- RULE 2 (3NF): color_dot_hex depends on the zone and nothing else. It is an authored presentation
--       value, not derivable from color_hex: '#DCEBFF' is not a computable tint of '#2D7FF9' by any
--       rule the other ten zones follow, since for them the two are equal.
-- RULE 1/3: unaffected.

BEGIN;

ALTER TABLE public.zones ADD COLUMN IF NOT EXISTS color_dot_hex text;

COMMENT ON COLUMN public.zones.color_dot_hex IS
  'Saturated swatch colour for small dot indicators and left borders. Read as COALESCE(color_dot_hex, color_hex): NULL means the dot matches the background, which is true for every zone except SOUTH. Replaces the hardcoded SOUTH override in the Visit Calendar bundle.';

ALTER TABLE public.zones DROP CONSTRAINT IF EXISTS zones_color_dot_hex_check;
ALTER TABLE public.zones ADD CONSTRAINT zones_color_dot_hex_check
  CHECK (color_dot_hex IS NULL OR color_dot_hex ~ '^#[0-9A-Fa-f]{6}$');

-- SOUTH only: color_hex becomes the wash the Calendar already draws, and the saturated value it
-- already draws for the dot moves into its own column. Pinned to both the code and the value being
-- replaced, so this cannot fire if the row moved since it was measured.
UPDATE public.zones
   SET color_hex     = '#DCEBFF',
       color_dot_hex = '#2D7FF9'
 WHERE code = 'SOUTH'
   AND color_hex = '#2D7FF9';

-- Append color_dot_hex LAST in both views (after short_label, added by 2026-09-02_0010).
-- REPLACE preserves grants; the existing column order is fixed and must not be disturbed.
CREATE OR REPLACE VIEW client.zones AS
  SELECT code, label, color_hex, color_token, sort_order, is_active, created_at, updated_at, id,
         short_label, color_dot_hex
    FROM public.zones;

CREATE OR REPLACE VIEW public.zones_with_usage AS
  SELECT z.id, z.code, z.label, z.color_hex, z.color_token, z.sort_order, z.is_active,
         z.created_at, z.updated_at,
         COALESCE(p.n_properties, 0) AS n_properties,
         z.short_label, z.color_dot_hex
    FROM public.zones z
    LEFT JOIN ( SELECT properties.zone_id,
                       count(*)::integer AS n_properties
                  FROM public.properties
                 WHERE properties.zone_id IS NOT NULL AND properties.deleted_at IS NULL
                 GROUP BY properties.zone_id) p ON p.zone_id = z.id;

DO $$
DECLARE
  v_bg text; v_dot text; v_others int; v_total int; v_cz int; v_zu int; v_auth boolean;
BEGIN
  -- 1. SOUTH now holds the exact pair the Calendar hardcodes today
  SELECT color_hex, color_dot_hex INTO v_bg, v_dot FROM public.zones WHERE code = 'SOUTH';
  IF v_bg IS DISTINCT FROM '#DCEBFF' OR v_dot IS DISTINCT FROM '#2D7FF9' THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: SOUTH is bg=% dot=%, expected #DCEBFF / #2D7FF9', v_bg, v_dot;
  END IF;

  -- 2. CONTROL: no other zone moved, and no other zone gained a dot colour. Without this, an
  --    UPDATE that rewrote every row would satisfy VERIFY 1 and silently repaint the whole estate.
  SELECT count(*) INTO v_others
    FROM public.zones
   WHERE code <> 'SOUTH'
     AND (color_dot_hex IS NOT NULL
          OR (code, color_hex) NOT IN (
            ('AVE','#C0F0F0'), ('NMB','#D1F7C4'), ('BRO','#FFEAB6'), ('SF/BH','#FEE2D5'),
            ('DOWN','#FFDCE5'), ('MIAMI BEACH','#FFDAF6'), ('SUNNY','#EDE2FE'), ('PALM','#ECECEC'),
            ('MID/EDG','#9CC7FF'), ('WEST','#77D1F3')));
  IF v_others <> 0 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: % non-SOUTH zone(s) changed colour', v_others;
  END IF;

  SELECT count(*) INTO v_total FROM public.zones;
  IF v_total <> 11 THEN
    RAISE EXCEPTION 'VERIFY 2b FAILED: % zones, expected 11', v_total;
  END IF;

  -- 3. the column reaches BOTH views, or the apps cannot see it
  SELECT count(*) INTO v_cz FROM information_schema.columns
   WHERE table_schema='client' AND table_name='zones' AND column_name='color_dot_hex';
  SELECT count(*) INTO v_zu FROM information_schema.columns
   WHERE table_schema='public' AND table_name='zones_with_usage' AND column_name='color_dot_hex';
  IF v_cz <> 1 OR v_zu <> 1 THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: color_dot_hex reaches client.zones=% zones_with_usage=%', v_cz, v_zu;
  END IF;

  SELECT has_table_privilege('authenticated','client.zones','SELECT') INTO v_auth;
  IF NOT v_auth THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: authenticated lost SELECT on client.zones';
  END IF;

  RAISE NOTICE 'OK: SOUTH bg/dot split into data; 10 other zones untouched; both views serve it.';
END $$;

COMMIT;
