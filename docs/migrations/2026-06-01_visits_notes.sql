-- 2026-06-01_visits_notes.sql
-- The Calendar form has a Notes field but public.visits had no general notes column
-- (only trap_condition_notes). Add visits.notes TEXT; the Calendar->Jobber push sends
-- it as the Jobber visit's `instructions` (crew-facing notes). visits is audited
-- (column add auto-captured). 3NF: notes depends on the visit. OK.
ALTER TABLE public.visits ADD COLUMN IF NOT EXISTS notes TEXT;
