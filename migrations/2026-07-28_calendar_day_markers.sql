-- 2026-07-28 — ops.calendar_day_markers: SHARED Day Start/End/Dump route markers for the Visit Calendar
--
-- Fred: "make the day start/end points shared for everyone, not just my browser."
-- Replaces the Calendar's localStorage-only persistence (shipped earlier the same day) with a real
-- table so every browser/user sees the same route anchors.
--
-- ⚠ APP-WRITE FEATURE (WORKING-NOW §5 rule): the Visit Calendar (Lovable 6533c3ee,
-- calendar.unclogme.app) reads AND writes this table DIRECTLY via REST with the ANON key +
-- Accept-Profile: ops — the Calendar's data layer is anon by design (its login is an app gate,
-- not RLS; documented in Building Apps/Visit Calendar/CLAUDE.md). Do NOT revoke the anon grants
-- as "unused" — the app is the user. There is NO audit trigger on this table, so audit.logs
-- silence proves nothing about usage.
--
-- Semantics: one 'start' and one 'end' marker max per calendar day (partial unique index —
-- re-dropping replaces via delete+insert in the app); 'dump' repeatable, must carry a dump_site
-- (the two real dump-site clients). minutes = minute-of-day 0..1439 in ET (matches the grid).
-- Markers are per-DAY (not per-truck) — v1 scope agreed with Fred 2026-07-28.

CREATE TABLE ops.calendar_day_markers (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  marker_date date NOT NULL,
  marker_type text NOT NULL CHECK (marker_type IN ('start','end','dump')),
  minutes smallint NOT NULL CHECK (minutes >= 0 AND minutes < 1440),
  dump_site text CHECK (dump_site IN ('Homestead (000-DH)','Pompano (000-DP)')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT dump_site_iff_dump CHECK ((marker_type = 'dump') = (dump_site IS NOT NULL))
);

CREATE UNIQUE INDEX calendar_day_markers_start_end_uniq
  ON ops.calendar_day_markers (marker_date, marker_type)
  WHERE marker_type IN ('start','end');

ALTER TABLE ops.calendar_day_markers ENABLE ROW LEVEL SECURITY;

CREATE POLICY calendar_day_markers_rw ON ops.calendar_day_markers
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

GRANT SELECT, INSERT, UPDATE, DELETE ON ops.calendar_day_markers TO anon, authenticated;
GRANT USAGE, SELECT ON SEQUENCE ops.calendar_day_markers_id_seq TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- Applied to Prod wbasvhvvismukaqdnouk 2026-07-28 via Management API (201).
-- Verified with the ANON key + ops profile (the app's real auth state):
--   INSERT 201 · duplicate same-day start 409 (unique idx) · dump without site 400 (CHECK) ·
--   DELETE 204 · 0 residue.
