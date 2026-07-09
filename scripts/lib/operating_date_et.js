// ============================================================================
// operating_date_et.js — the ONE canonical visit_date derivation for the
// Jobber reconcile scripts.
// ============================================================================
// visit_date = the ET CLOCK date of start_at (America/New_York), per
// docs/reference/operating-date-rule.md (revised 2026-07-02: the "operating-night"
// shift was REMOVED — visit_date is the plain ET clock date, NOT a 06:00-ET-cutoff
// operating night).
//
// This mirrors EXACTLY the two other implementations it must agree with:
//   - supabase/functions/webhook-jobber/index.ts  operatingDateET() = etParts(new Date(iso)).date
//   - the DB BEFORE trigger public.fn_reconcile_visit_operating_date, Branch 3:
//       NEW.visit_date := (NEW.start_at AT TIME ZONE 'America/New_York')::date;
//
// WHY it must match the trigger exactly: the trigger runs BEFORE every visits
// write and re-derives visit_date from start_at. If a reconcile computes a
// DIFFERENT date, the trigger overwrites it and the two fight once per day — that
// is the ±1-day visit_date oscillation bug (2026-07-09 hand-off). The old writers
// used `startAt.slice(0,10)` = the raw UTC date, which is +1 day for evening-ET
// visits (20:00–23:59 ET → 00:00–03:59 Z next day). Do NOT reintroduce a 06:00
// cutoff here either: it would re-break the early-AM (00:00–05:59 ET) visits the
// trigger keeps on their clock date.
//
// Returns 'YYYY-MM-DD' (the ET calendar date) or null when the timestamp is null
// (all-day visit — visit_date is authoritative and must not be derived).
// ============================================================================

const ET_FMT = new Intl.DateTimeFormat('en-CA', {
  timeZone: 'America/New_York',
  year: 'numeric',
  month: '2-digit',
  day: '2-digit',
});

function operatingDateET(iso) {
  if (!iso) return null;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  const p = {};
  for (const part of ET_FMT.formatToParts(d)) p[part.type] = part.value;
  return `${p.year}-${p.month}-${p.day}`;
}

module.exports = { operatingDateET };
