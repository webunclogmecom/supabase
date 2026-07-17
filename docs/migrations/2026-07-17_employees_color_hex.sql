-- 2026-07-17_employees_color_hex.sql
-- Canonical per-driver identity colour on public.employees.
--
-- WHY (Fred, 2026-07-17, on the DUMP Schedule driver list): "put the names with colors like we have
-- in the Calendar App for when they're assigned a visit." The Calendar has NO canonical colour map —
-- it hashes the driver name into a Tailwind palette at RUNTIME, so there is nothing to copy and every
-- app would drift. Fred chose (explicitly, over "hex lives in the app") to make the driver colour
-- CANONICAL in the DB so every app reads ONE source of truth.
--
-- Precedent: public.zones already carries color_hex + color_token as a canonical identity colour
-- shared across the Calendar + the Internal Portal TerritoryMap. A driver's identity colour is the
-- same shape of thing (an attribute of the person, shared cross-app), so it lives the same way.
--
-- SCOPE: nullable column, set only for the 5 people who appear in the DUMP driver picker (they are the
-- ones actually assigned dump visits). Others stay NULL — a colour is meaningful only for a field
-- crew, and NULL is the app's "no colour" signal. Fred can colour anyone else with one UPDATE.
--
-- Colours: distinct Tailwind-500 hues on the blue->magenta arc, chosen to avoid the DUMP app's
-- load-bearing hues — Homestead amber #F59E0B, Pompano cyan #22D3EE, GO green #16A34A, and the
-- selection orange #f14714 (which renders ON the driver row, so a driver colour must never be orange).
--   Aaron 26 -> #3B82F6 blue · Anthony 37 -> #8B5CF6 violet · Diego 28 -> #D946EF fuchsia ·
--   Grecia 1 -> #EC4899 pink · Mark 35 -> #F43F5E rose.
--
-- SAFE/ADDITIVE: new nullable column; the Calendar and every other reader ignores it until updated.
-- AUDIT (ADR 010): this is business-data DML on employees -> the audit trigger fires on the UPDATE
-- (intended; it is a real attribute change).
-- REVERSIBLE: ALTER TABLE public.employees DROP COLUMN color_hex;

ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS color_hex text;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'employees_color_hex_chk') THEN
    ALTER TABLE public.employees
      ADD CONSTRAINT employees_color_hex_chk CHECK (color_hex IS NULL OR color_hex ~ '^#[0-9A-Fa-f]{6}$');
  END IF;
END $$;

UPDATE public.employees SET color_hex = v.hex
FROM (VALUES (26,'#3B82F6'),(37,'#8B5CF6'),(28,'#D946EF'),(1,'#EC4899'),(35,'#F43F5E')) AS v(id,hex)
WHERE public.employees.id = v.id;

COMMENT ON COLUMN public.employees.color_hex IS
  'Canonical per-person identity colour (hex). Shared cross-app so a driver is the same colour everywhere. Set for field crews in the DUMP picker; NULL = no colour. Mirrors zones.color_hex.';
