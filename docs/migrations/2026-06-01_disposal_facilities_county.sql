-- 2026-06-01_disposal_facilities_county.sql
--
-- Add `county` to disposal_facilities so DERM Tracker's /upload facility dropdown can
-- label each option "{name} ({county})" and auto-match the facility to the form's
-- jurisdiction lock. Values are EXACTLY 'Miami-Dade' or 'Broward' (Broward covers Palm
-- Beach too) per the app contract. Also adds the Broward WWTP ('Water and Wastewater
-- Services'), which was missing.
--
-- county is set ONLY on the two DERM WWTP filing facilities so the app's auto-match
-- (county = jurisdiction) returns exactly one facility per jurisdiction. Homestead Dump
-- (facility_type DUMP, not a DERM WWTP) stays county=NULL.
-- Idempotent: ADD COLUMN IF NOT EXISTS; INSERT guarded by NOT EXISTS; UPDATEs guarded.

BEGIN;

ALTER TABLE public.disposal_facilities
  ADD COLUMN IF NOT EXISTS county TEXT
  CHECK (county IS NULL OR county IN ('Miami-Dade', 'Broward'));

COMMENT ON COLUMN public.disposal_facilities.county IS
  'DERM jurisdiction of the facility: Miami-Dade or Broward (Broward covers Palm Beach). NULL for non-DERM-WWTP facilities (e.g. dump sites). Drives DERM Tracker /upload facility auto-match. Exactly these two string values.';

-- South District WWTP = the Miami-Dade DERM WWTP
UPDATE public.disposal_facilities
  SET county = 'Miami-Dade'
  WHERE name = 'South District WWTP' AND county IS DISTINCT FROM 'Miami-Dade';

-- Broward DERM WWTP — add if missing (Palm Beach/PBC files here too)
INSERT INTO public.disposal_facilities (name, facility_type, state, status, county, notes)
SELECT 'Water and Wastewater Services', 'WWTP', 'FL', 'ACTIVE', 'Broward',
       'Broward County septage receiving (DERM WWTP). Palm Beach / PBC visits also file here. Added 2026-06-01 for the DERM Tracker /upload facility dropdown.'
WHERE NOT EXISTS (SELECT 1 FROM public.disposal_facilities WHERE name = 'Water and Wastewater Services');

UPDATE public.disposal_facilities
  SET county = 'Broward'
  WHERE name = 'Water and Wastewater Services' AND county IS DISTINCT FROM 'Broward';

COMMIT;

-- VERIFY:
-- SELECT id, name, facility_type, county FROM public.disposal_facilities ORDER BY id;
--   -> Homestead Dump (DUMP, NULL) · South District WWTP (WWTP, Miami-Dade) · Water and Wastewater Services (WWTP, Broward)
