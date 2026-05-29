-- 2026-05-29_zones_cascade_security_definer.sql
--
-- Hot-fix for the editable-code save path. When anon (the Calendar app)
-- UPDATEs public.zones to rename code, the AFTER UPDATE cascade trigger
-- runs `UPDATE properties SET zone = NEW.code WHERE zone_id = NEW.id`.
-- That UPDATE runs as anon, which has no UPDATE privilege on properties,
-- so the cascade fails with `permission denied for table properties` and
-- the entire zones UPDATE rolls back (single transaction).
--
-- Fix: mark the cascade function SECURITY DEFINER so it executes as the
-- function owner (postgres) and can update properties without needing
-- anon to hold that privilege.
--
-- Audit attribution (ADR 016) is unaffected — the audit trigger reads
-- app_source from request headers (Origin / X-App-Source), not from the
-- session role. Properties cascade rows will still attribute to
-- app_source='visit-calendar' when the rename is initiated from the
-- Calendar app.
--
-- `SET search_path = public` defends against search_path hijacking.

BEGIN;

CREATE OR REPLACE FUNCTION public.zones_cascade_code_rename()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.code IS DISTINCT FROM OLD.code THEN
    UPDATE public.properties
    SET zone = NEW.code
    WHERE zone_id = NEW.id;
  END IF;
  RETURN NEW;
END $$;

-- Also patch the bidirectional sync trigger on properties. It fires when
-- properties.zone or zone_id changes, looking up the other column from
-- public.zones. anon doesn't read public.zones (RLS-policy permits SELECT
-- via the grant, but be defensive). SECURITY DEFINER prevents any future
-- RLS hardening on zones from silently breaking this trigger.
CREATE OR REPLACE FUNCTION public.properties_sync_zone_columns()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.zone IS NOT NULL AND NEW.zone_id IS NULL THEN
      SELECT id INTO NEW.zone_id FROM public.zones WHERE code = NEW.zone;
    ELSIF NEW.zone_id IS NOT NULL AND NEW.zone IS NULL THEN
      SELECT code INTO NEW.zone FROM public.zones WHERE id = NEW.zone_id;
    END IF;
  ELSIF TG_OP = 'UPDATE' THEN
    IF NEW.zone IS DISTINCT FROM OLD.zone
       AND NEW.zone_id IS NOT DISTINCT FROM OLD.zone_id THEN
      IF NEW.zone IS NULL THEN
        NEW.zone_id := NULL;
      ELSE
        SELECT id INTO NEW.zone_id FROM public.zones WHERE code = NEW.zone;
      END IF;
    ELSIF NEW.zone_id IS DISTINCT FROM OLD.zone_id
          AND NEW.zone IS NOT DISTINCT FROM OLD.zone THEN
      IF NEW.zone_id IS NULL THEN
        NEW.zone := NULL;
      ELSE
        SELECT code INTO NEW.zone FROM public.zones WHERE id = NEW.zone_id;
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END $$;

COMMIT;
