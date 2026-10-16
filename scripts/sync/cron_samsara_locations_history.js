// cron_samsara_locations_history.js: GPS history from Samsara (/fleet/vehicles/locations/history, ~30 s
// resolution) into public.vehicle_telemetry_readings, for visit, stop and time-on-site attribution.
//   node scripts/sync/run_logged.js railway_samsara_gps scripts/sync/cron_samsara_locations_history.js   (Railway, every 5 min)
//   START_TIME=2026-10-01T00:00:00Z [END_TIME=...] node scripts/sync/cron_samsara_locations_history.js     manual backfill
// The /stats poller (cron_samsara_telemetry.js) writes snapshots to the same table; both insert
// ON CONFLICT (vehicle_id, recorded_at) DO NOTHING, so overlaps cost nothing.
//
// Window (2026-10-16, Fred: "add the same retry to the GPS job too ... a fallback or restart system"):
//   start = newest GPS-only row (odometer, fuel and engine state null, latitude set, not in the future) minus
//   30 min of overlap, so a point Samsara receives a little late is fetched on the next run. Once a day (no
//   successful deep pass in 24 h) the overlap is 48 h, for a truck that uploads late after losing signal.
//   Floored at AUTO_LOOKBACK_H (default 168 = 7 days): a longer outage keeps only the last 7 days, reports the
//   lost span as dropped_span and exits 1. The span stays open until a manual run (START_TIME and END_TIME, through
//   run_logged, e.g. the GitHub "Samsara GPS (fallback)" workflow) covers it: until then
//   public.fn_samsara_data_complete_through('gps') stops at its start and the watchdog reports gps_dropped_span.
//   A cursor lookup that fails is fatal: guessing a short window after an outage loses everything before it.
// Rows are inserted in time order and the run stops at the first failed batch, so within a run the data-derived
// cursor can never move past rows that did not land. A manual window that ends at now moves the cursor too: start
// a backfill at or before the start of the gap. A failed Samsara call (after the shared client's 3 attempts) throws
// before anything is inserted. No mapped vehicle = exit 1 (a green run that stores nothing hides a dead feed).
// Output: one final stdout line `RUN_SUMMARY {json}` (run_logged.js stores it): window, deep_pass, points,
// rows_inserted (rows the DB actually took), failed_batches, dropped_span, resume_point (true = a scheduled run
// that fetched through its window end and stored everything).
// Check: scripts/sync/cron_samsara_locations_history.test.js (main() end to end on a stub fetch).
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env'), quiet: true });
const { samsaraClient } = require('../lib/samsara_client');

const SOURCE = 'railway_samsara_gps';
const HOUR = 3600e3;
const OVERLAP_MS = 30 * 60e3;
const DEEP_HOURS = 48;
const BATCH = 500;

// `io.fetch` / `io.sleep` are the real ones unless main() is handed stubs (the test does that).
const io = { fetch: (...a) => fetch(...a), sleep: ms => new Promise(r => setTimeout(r, ms)) };
const samsara = samsaraClient({ fetch: (...a) => io.fetch(...a), sleep: ms => io.sleep(ms), token: () => process.env.SAMSARA_API_TOKEN });

async function rest(path, { method = 'GET', body, prefer } = {}) {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const r = await io.fetch(process.env.SUPABASE_URL + '/rest/v1' + path, { method, signal: AbortSignal.timeout(60000),
    headers: { apikey: key, Authorization: 'Bearer ' + key, 'Content-Type': 'application/json', ...(prefer && { Prefer: prefer }) },
    body: body && JSON.stringify(body) });
  return { status: r.status, json: await r.json().catch(() => null) };
}
async function restOk(path, opts) {
  const r = await rest(path, opts);
  if (r.status >= 300) throw new Error(`PostgREST HTTP ${r.status} on ${path.split('?')[0]}: ${JSON.stringify(r.json).slice(0, 200)}`);
  return r.json;
}

function* chunkWindow(startMs, endMs, chunkMs = 24 * HOUR) {
  for (let c = startMs; c < endMs; c += chunkMs) yield { start: new Date(c).toISOString(), end: new Date(Math.min(c + chunkMs, endMs)).toISOString() };
}

// main({ fetch, sleep, now, log, error }) -> exit code (0 or 1). Throws on a setup or Samsara failure (FATAL).
async function main(deps = {}) {
  if (deps.fetch) io.fetch = deps.fetch;
  if (deps.sleep) io.sleep = deps.sleep;
  const log = deps.log || console.log, logErr = deps.error || console.error;
  for (const k of ['SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY', 'SAMSARA_API_TOKEN'])
    if (!process.env[k]) throw new Error('missing ' + k);
  const now = deps.now ?? Date.now();
  const iso = ms => new Date(ms).toISOString();
  if (process.env.END_TIME && !process.env.START_TIME) throw new Error('END_TIME needs START_TIME (a backfill window has both)');
  const manual = !!process.env.START_TIME;
  const end = process.env.END_TIME ? Date.parse(process.env.END_TIME) : now;
  const lookbackH = Number(process.env.AUTO_LOOKBACK_H) || 168;
  const summary = { window_start: null, window_end: iso(end), manual, deep_pass: false, vehicles: 0, points: 0,
    rows_inserted: 0, failed_batches: 0, dropped_span: null, resume_point: false };

  let start;
  if (manual) {
    start = Date.parse(process.env.START_TIME);
    if (!(start < end)) throw new Error('START_TIME must be before END_TIME');
  } else {
    const last = await restOk('/vehicle_telemetry_readings?select=recorded_at&odometer_meters=is.null&fuel_percent=is.null' +
      `&engine_state=is.null&latitude=not.is.null&recorded_at=lte.${iso(now)}&order=recorded_at.desc&limit=1`);
    const lastMs = last[0] ? Date.parse(last[0].recorded_at) : null;
    const recentDeep = await restOk(`/sync_log?sync_source=eq.${SOURCE}&status=eq.success&started_at=gte.${iso(now - 24 * HOUR)}` +
      '&details->summary->>deep_pass=eq.true&select=id&limit=1');
    summary.deep_pass = !recentDeep.length;
    const resume = lastMs ? lastMs - OVERLAP_MS : now - 90 * 60e3;   // no GPS row at all: an empty table, nothing to lose
    const floor = now - lookbackH * HOUR;
    if (resume < floor) summary.dropped_span = { from: iso(resume), to: iso(floor) };   // the deep pass never counts as dropped
    start = Math.max(summary.deep_pass ? Math.min(resume, now - DEEP_HOURS * HOUR) : resume, floor);
  }
  summary.window_start = iso(start);

  const links = await restOk('/entity_source_links?entity_type=eq.vehicle&source_system=eq.samsara&select=entity_id,source_id');
  const idMap = new Map(links.map(l => [String(l.source_id), Number(l.entity_id)]));
  summary.vehicles = idMap.size;
  if (!idMap.size) throw new Error('entity_source_links holds no samsara vehicle link: refusing to run (a green run storing nothing would hide a dead feed)');

  const rows = [];
  for (const c of chunkWindow(start, end)) {
    const data = await samsara.paged(`/fleet/vehicles/locations/history?vehicleIds=${[...idMap.keys()].join(',')}` +
      `&startTime=${encodeURIComponent(c.start)}&endTime=${encodeURIComponent(c.end)}&limit=100`);
    for (const v of data) {
      const vehicleId = idMap.get(String(v.id));
      if (!vehicleId) continue;
      for (const loc of v.locations || []) rows.push({
        vehicle_id: vehicleId, latitude: loc.latitude ?? null, longitude: loc.longitude ?? null,
        speed_meters_per_sec: loc.speedMilesPerHour != null ? Number((loc.speedMilesPerHour * 0.44704).toFixed(2)) : null,
        heading_degrees: loc.headingDegrees ?? null, recorded_at: loc.time });
    }
  }
  summary.points = rows.length;

  rows.sort((a, b) => Date.parse(a.recorded_at) - Date.parse(b.recorded_at));
  for (let i = 0; i < rows.length; i += BATCH) {
    const r = await rest('/vehicle_telemetry_readings?on_conflict=vehicle_id,recorded_at&select=recorded_at',
      { method: 'POST', body: rows.slice(i, i + BATCH), prefer: 'resolution=ignore-duplicates,return=representation' });
    if (r.status >= 300) {   // stop: a later batch would move the cursor past these rows
      summary.failed_batches = 1;
      logErr(`insert batch ${i / BATCH + 1} failed HTTP ${r.status}: ${JSON.stringify(r.json).slice(0, 200)}; stopped, the next run re-fetches from here`);
      break;
    }
    summary.rows_inserted += Array.isArray(r.json) ? r.json.length : 0;
  }
  if (summary.dropped_span) logErr(`GPS older than ${lookbackH} h was not fetched: ${summary.dropped_span.from} to ${summary.dropped_span.to} (re-pull with START_TIME/END_TIME)`);
  summary.resume_point = !manual && !summary.failed_batches && !summary.dropped_span;
  log('RUN_SUMMARY ' + JSON.stringify(summary));
  return summary.failed_batches || summary.dropped_span ? 1 : 0;
}

module.exports = { chunkWindow, main };

if (require.main === module) main().then(c => { process.exitCode = c; }, e => { console.error('FATAL: ' + e.message); process.exit(1); });
