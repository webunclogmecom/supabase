-- 2026-07-29_2242_fix_zone_rename_drop_dead_cascade.sql
--
-- FIXES A LIVE BREAK: renaming a zone code from the Visit Calendar was IMPOSSIBLE.
--
-- Symptom (reproduced on Prod before this migration):
--   ERROR: 42703: column "zone" of relation "properties" does not exist
--   QUERY:   UPDATE public.properties SET zone = NEW.code WHERE zone_id = NEW.id
--   CONTEXT: PL/pgSQL function zones_cascade_code_rename() line 4
--
-- Any UPDATE that changed zones.code aborted. Not theoretical: audit.logs shows
-- 31 real UPDATEs + 1 INSERT on public.zones with app_source='visit-calendar',
-- so staff genuinely use the Calendar's zone editor and every rename attempt
-- since the zone collapse has failed.
--
-- CAUSE: the trigger maintained a DENORMALISED copy of the zone code on
-- properties.zone. That column was deliberately dropped in the zone collapse,
-- because zones.code became the single source of truth app-wide and properties
-- reference it through the zone_id FK. The trigger was never removed with it, so
-- it kept writing to a column that no longer exists. Verified today:
--   properties.zone     -> 0 columns  (gone)
--   properties.zone_id  -> 1 column   (the FK, present)
--
-- WHY DROP RATHER THAN NO-OP: there is nothing left to cascade. A rename of
-- zones.code is immediately visible everywhere via the FK join; no second copy
-- needs updating. A no-op trigger would be dead weight that reads as intentional
-- to the next person.
--
-- SCOPE: verified this function is the ONLY database object still referencing the
-- dropped column (catalogue sweep over pg_proc + pg_class, positive-controlled --
-- see the note below). Dropping it therefore breaks nothing.
--
-- ⚠ REGEX NOTE FOR FUTURE CATALOGUE SWEEPS VIA THE MANAGEMENT API:
--   '\s' DOES NOT MATCH through the /database/query JSON round-trip -- the escape
--   is eaten, the pattern becomes 'SETs+zone', and the sweep returns 0 rows that
--   read as a clean all-clear. Measured: ~ 'SET\s+zone' => false, while
--   ~ 'SET[[:space:]]+zone' => true on the same body. USE POSIX CLASSES, and
--   always include a positive control that MUST match a known-present object.
--   Same family as the '\y' vs '\b' word-boundary trap already documented.
--
-- App-side consequence (documented in Building Apps/Visit Calendar/CLAUDE.md):
--   the zone editor's rule #3 note previously claimed this trigger "propagates a
--   code rename safely". It did not. That wording is corrected in the same cycle.
--
-- Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>

BEGIN;

DROP TRIGGER IF EXISTS zones_cascade_code_rename_trg ON public.zones;
DROP FUNCTION IF EXISTS public.zones_cascade_code_rename();

COMMIT;
