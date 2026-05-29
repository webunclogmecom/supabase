-- 2026-05-29_zones_fk_refactor.sql
--
-- Refactor public.zones to use a BIGINT surrogate PK (zones.id) + add a real
-- FK from public.properties.zone_id → public.zones.id. Makes `code` truly
-- mutable: renames cascade automatically via trigger, no silent orphans.
--
-- BACKGROUND
--   Original 2026-05-27 migration made code the PRIMARY KEY. Joins to
--   properties.zone (TEXT, no FK) were string-based. Renaming code in zones
--   would have silently orphaned every property tagged with the old string.
--   We blocked code rename with an immutable-code trigger as a stopgap.
--   That stopgap is removed today and replaced with the textbook 3NF design:
--   surrogate bigint PK on zones + real FK from properties.
--
-- DECISIONS (Fred 2026-05-28)
--   - Code field becomes editable in the Manage Zones modal (UI follow-up).
--   - Soft-delete (is_active=false): properties stay linked. Reactivating
--     restores the relationship transparently.
--   - Hard-delete (new): unlinks properties (sets zone_id + zone to NULL)
--     then DELETEs the zones row. Exposed via SECURITY DEFINER RPC because
--     the DELETE RLS policy still blocks raw DELETEs from anon (defense
--     in depth — the RPC is the only sanctioned path).
--
-- PHASE 1 SCOPE (this migration)
--   Additive + sync. Existing readers continue to use public.properties.zone
--   (TEXT) — the 11 ops views and webhook-airtable don't change. The
--   bidirectional sync trigger keeps zone and zone_id coherent.
--
-- PHASE 2 (deferred follow-up)
--   Migrate ops views + webhook-airtable to JOIN through zone_id, then
--   drop public.properties.zone TEXT column. Not in this migration.
--
-- AUDIT (Rule 8)
--   zones + properties remain audited. The cascade UPDATE on code rename
--   will fire properties audit rows (one per linked property) — that's
--   intentional and provides full historical trace. The hard-delete RPC
--   runs under SECURITY DEFINER but the audit triggers still fire under
--   the calling role's context.

BEGIN;

-- ============================================================
-- 1. zones surrogate PK
-- ============================================================
-- Add id column. Existing rows get auto-generated IDs (start at 1).
ALTER TABLE public.zones ADD COLUMN IF NOT EXISTS id BIGINT GENERATED ALWAYS AS IDENTITY;

-- Move PK from code to id.
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'zones_pkey'
             AND conrelid = 'public.zones'::regclass) THEN
    -- Old PK might be on code; drop and recreate on id.
    ALTER TABLE public.zones DROP CONSTRAINT zones_pkey;
  END IF;
  ALTER TABLE public.zones ADD CONSTRAINT zones_pkey PRIMARY KEY (id);
EXCEPTION WHEN duplicate_object THEN
  NULL;  -- already done
END $$;

-- Keep code UNIQUE so apps can still address zones by their codename.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'zones_code_unique') THEN
    ALTER TABLE public.zones ADD CONSTRAINT zones_code_unique UNIQUE (code);
  END IF;
END $$;

-- ============================================================
-- 2. properties.zone_id FK
-- ============================================================
ALTER TABLE public.properties
  ADD COLUMN IF NOT EXISTS zone_id BIGINT REFERENCES public.zones(id) ON DELETE SET NULL;

-- Index for the FK (Postgres doesn't auto-index FKs).
CREATE INDEX IF NOT EXISTS properties_zone_id_idx ON public.properties(zone_id);

-- Backfill from existing string mapping. Idempotent.
UPDATE public.properties p
SET zone_id = z.id
FROM public.zones z
WHERE p.zone = z.code
  AND p.zone IS NOT NULL
  AND p.zone_id IS NULL;

-- Coverage check (will be visible in verification probe).
DO $$
DECLARE
  _orphans INT;
BEGIN
  SELECT COUNT(*) INTO _orphans
  FROM public.properties
  WHERE zone IS NOT NULL AND zone_id IS NULL;
  IF _orphans > 0 THEN
    RAISE NOTICE 'Backfill: % properties have a zone string with no matching zones.code', _orphans;
  END IF;
END $$;

-- ============================================================
-- 3. Drop the immutable-code stopgap trigger
-- ============================================================
DROP TRIGGER IF EXISTS zones_lock_code_trg ON public.zones;
DROP FUNCTION IF EXISTS public.zones_lock_code() CASCADE;

-- ============================================================
-- 4. Cascade trigger: zones.code rename → properties.zone text
-- ============================================================
CREATE OR REPLACE FUNCTION public.zones_cascade_code_rename()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.code IS DISTINCT FROM OLD.code THEN
    UPDATE public.properties
    SET zone = NEW.code
    WHERE zone_id = NEW.id;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS zones_cascade_code_rename_trg ON public.zones;
CREATE TRIGGER zones_cascade_code_rename_trg
  AFTER UPDATE OF code ON public.zones
  FOR EACH ROW EXECUTE FUNCTION public.zones_cascade_code_rename();

-- ============================================================
-- 5. Bidirectional sync trigger on properties
-- ============================================================
-- Keeps zone (TEXT) and zone_id (BIGINT) coherent regardless of which one
-- writers touch. Single trigger handles INSERT + UPDATE to avoid trigger-
-- ordering ambiguity.
CREATE OR REPLACE FUNCTION public.properties_sync_zone_columns()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- zone set, zone_id unset → lookup zone_id
    IF NEW.zone IS NOT NULL AND NEW.zone_id IS NULL THEN
      SELECT id INTO NEW.zone_id FROM public.zones WHERE code = NEW.zone;
    -- zone_id set, zone unset → lookup zone
    ELSIF NEW.zone_id IS NOT NULL AND NEW.zone IS NULL THEN
      SELECT code INTO NEW.zone FROM public.zones WHERE id = NEW.zone_id;
    END IF;

  ELSIF TG_OP = 'UPDATE' THEN
    -- Only zone (TEXT) changed
    IF NEW.zone IS DISTINCT FROM OLD.zone
       AND NEW.zone_id IS NOT DISTINCT FROM OLD.zone_id THEN
      IF NEW.zone IS NULL THEN
        NEW.zone_id := NULL;
      ELSE
        SELECT id INTO NEW.zone_id FROM public.zones WHERE code = NEW.zone;
      END IF;
    -- Only zone_id (BIGINT) changed
    ELSIF NEW.zone_id IS DISTINCT FROM OLD.zone_id
          AND NEW.zone IS NOT DISTINCT FROM OLD.zone THEN
      IF NEW.zone_id IS NULL THEN
        NEW.zone := NULL;
      ELSE
        SELECT code INTO NEW.zone FROM public.zones WHERE id = NEW.zone_id;
      END IF;
    END IF;
    -- If both changed in same UPDATE, trust the author (no sync).
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS properties_sync_zone_columns_trg ON public.properties;
CREATE TRIGGER properties_sync_zone_columns_trg
  BEFORE INSERT OR UPDATE ON public.properties
  FOR EACH ROW EXECUTE FUNCTION public.properties_sync_zone_columns();

-- ============================================================
-- 6. Update zones_with_usage to use FK
-- ============================================================
CREATE OR REPLACE VIEW public.zones_with_usage AS
  SELECT
    z.code,
    z.label,
    z.color_hex,
    z.color_token,
    z.sort_order,
    z.is_active,
    z.created_at,
    z.updated_at,
    COALESCE(p.n_properties, 0)::int AS n_properties
  FROM public.zones z
  LEFT JOIN (
    SELECT zone_id, COUNT(*)::int AS n_properties
    FROM public.properties
    WHERE zone_id IS NOT NULL
    GROUP BY zone_id
  ) p ON p.zone_id = z.id;

GRANT SELECT ON public.zones_with_usage TO anon, authenticated;

-- ============================================================
-- 7. zones_hard_delete RPC
-- ============================================================
-- SECURITY DEFINER so it can bypass the DELETE RLS block. Only callable
-- via PostgREST RPC (the UI gates with a scary confirm dialog). Returns
-- the unlinked-properties count so the UI can show a useful toast.
CREATE OR REPLACE FUNCTION public.zones_hard_delete(_code TEXT)
RETURNS TABLE(deleted_zone_code TEXT, unlinked_properties INT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _zone_id BIGINT;
  _unlinked INT;
BEGIN
  SELECT id INTO _zone_id FROM public.zones WHERE code = _code;
  IF _zone_id IS NULL THEN
    RAISE EXCEPTION 'Zone with code % not found', _code USING ERRCODE = 'no_data_found';
  END IF;

  -- Unlink properties. Both zone_id AND zone (TEXT) get NULLed via sync trigger.
  UPDATE public.properties SET zone_id = NULL WHERE zone_id = _zone_id;
  GET DIAGNOSTICS _unlinked = ROW_COUNT;

  -- Hard delete the zone row. Audit captures the DELETE.
  DELETE FROM public.zones WHERE id = _zone_id;

  RETURN QUERY SELECT _code, _unlinked;
END $$;

REVOKE ALL ON FUNCTION public.zones_hard_delete(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.zones_hard_delete(TEXT) TO anon, authenticated;

COMMENT ON FUNCTION public.zones_hard_delete(TEXT) IS
  'Hard-delete a zone after unlinking its properties. SECURITY DEFINER to bypass RLS DELETE block. Audit triggers fire under the caller''s role context so app_source attribution is preserved (ADR 016).';

COMMIT;

-- ============================================================
-- POST-MIGRATION VERIFICATION
-- ============================================================
-- 1. Surrogate PK present + code unique:
--    SELECT column_name, data_type FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='zones' AND column_name='id';
--    SELECT conname FROM pg_constraint WHERE conrelid='public.zones'::regclass
--    ORDER BY conname;
--
-- 2. properties.zone_id populated:
--    SELECT (zone IS NOT NULL) AS has_zone, (zone_id IS NOT NULL) AS has_zone_id, COUNT(*)
--    FROM public.properties GROUP BY 1, 2 ORDER BY 1 DESC, 2 DESC;
--    Expected: rows where has_zone=true should also have has_zone_id=true.
--
-- 3. Rename works (and cascades):
--    UPDATE public.zones SET code='SOUTH_TEST' WHERE code='SOUTH';
--    SELECT zone, zone_id FROM public.properties WHERE zone_id =
--      (SELECT id FROM public.zones WHERE code='SOUTH_TEST') LIMIT 3;
--    -- Expected: all rows show zone='SOUTH_TEST'.
--    UPDATE public.zones SET code='SOUTH' WHERE code='SOUTH_TEST';
--
-- 4. Hard-delete RPC works:
--    INSERT INTO public.zones (code, label, color_hex) VALUES ('TEST_HD', 'Test Hard Delete', '#999999');
--    SELECT * FROM public.zones_hard_delete('TEST_HD');
--    -- Expected: returns ('TEST_HD', 0). Zone is gone.
