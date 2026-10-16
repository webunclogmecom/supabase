// cron_samsara_tank_readings.js: Samsara tank-sensor and truck engine readings into the raw tables
// (plan docs/superpowers/specs/2026-10-12-samsara-tank-sensors-db-plan.md, section 4, step J1).
//
//   node scripts/sync/run_logged.js railway_samsara_readings scripts/sync/cron_samsara_tank_readings.js
//   node scripts/sync/cron_samsara_tank_readings.js --from=2026-08-20T14:00:00Z [--window-hours=72]   backfill
//   node scripts/sync/cron_samsara_tank_readings.js --dry-run [--from=...] [--assets=...]               no DB write
//
// Streams (one readingId per /readings/history call; readingIds returns 400):
//   per linked sensor (ESL tank_sensor/samsara): remoteSensingDistance, fillPercent
//   per linked truck  (ESL vehicle/samsara):     engineRpm, ecuPowerTakeoff, addressEntry, addressExit
// Write: PostgREST POST, on_conflict = the natural key, resolution=ignore-duplicates, chunks of 1,000 with
// identical key sets, X-App-Source: samsara-tank-readings. The rows PostgREST returns are the inserted rows.
//
// Window: from started_at of the newest successful railway_samsara_readings run whose summary says
// resume_point = true, minus 30 min (none yet: 2026-08-20T14:00Z), to now, in 72 h chunks. Once a day (no
// deep-pass success in 24 h) the overlap is 48 h and rows older than the normal start count as
// deep_pass_recovered; that run also lists level assets Samsara reports that have no tank_sensor link
// (unlinked_level_assets). On every other run unlinked_level_assets is null (NOT CHECKED, never []), and it is
// null too when the discovery call fails (that failure is an error: exit 1, the run is not a resume point).
// resume_point = no stream skipped AND (no --from, or --from at or before the cursor). So a run that skipped a
// stream, or a targeted --from catch-up that started after the cursor, never moves the cursor past data it did
// not store: the next run starts from the last run that stored every stream.
// Units guard: each stream's /readings/definitions entry must match PINNED; a mismatch skips that stream only
// (skipped_streams), the run still exits 0 (but with resume_point false). Address events: value.addressEntries[]
// (the definition says addressIds; the payload does not), `addr_` stripped, resolved to a site property;
// others are counted as unresolved and not stored (re-pull them with --from once the resolver knows them).
// Geofence names are never printed (they carry client codes).
// A real run refuses to start (exit 1) when entity_source_links holds no tank_sensor or no vehicle link.
// Output: one final stdout line `RUN_SUMMARY {json}` (run_logged.js stores it). Exit 1 on any failed call or
// insert. --dry-run prints `DRY_RUN_SUMMARY {json}` instead, so a dry run can never become a resume point,
// and run_logged.js refuses --dry-run outright (a sync_log row of any kind reads as a fresh run).
// Check: scripts/sync/cron_samsara_tank_readings.test.js (pure parts AND main() end to end on a stub fetch).
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env'), quiet: true });
const { samsaraClient } = require('../lib/samsara_client');

const BACKFILL_START = '2026-08-20T14:00:00Z';
const SOURCE = 'railway_samsara_readings';
const APP_SOURCE = 'samsara-tank-readings';
const HOUR = 3600e3;

const STREAMS = [
  { key: 'distance', reading: 'remoteSensingDistance', on: 'sensor', table: 'tank_sensor_distance_readings', conflict: 'tank_sensor_id,recorded_at' },
  { key: 'percent', reading: 'fillPercent', on: 'sensor', table: 'tank_sensor_fill_percent_readings', conflict: 'tank_sensor_id,recorded_at' },
  { key: 'rpm', reading: 'engineRpm', on: 'truck', table: 'vehicle_engine_rpm_readings', conflict: 'vehicle_id,recorded_at' },
  { key: 'pto', reading: 'ecuPowerTakeoff', on: 'truck', table: 'vehicle_pto_readings', conflict: 'vehicle_id,recorded_at' },
  { key: 'address_entry', reading: 'addressEntry', on: 'truck', table: 'vehicle_site_events', conflict: 'vehicle_id,recorded_at,property_id,event_kind' },
  { key: 'address_exit', reading: 'addressExit', on: 'truck', table: 'vehicle_site_events', conflict: 'vehicle_id,recorded_at,property_id,event_kind' },
];
// Read from /readings/definitions on 2026-10-12 (reference doc section 3.5).
const PINNED = { remoteSensingDistance: 'unit:meter', fillPercent: 'unit:percent', engineRpm: 'unit:rpm',
  ecuPowerTakeoff: 'enum:off=0,on=1', addressEntry: 'fields:addressIds', addressExit: 'fields:addressIds' };

// ---------- pure parts (tested) ----------
function normalizeDefinition(def) {
  const t = def?.type || {};
  if (Array.isArray(t.enumValues)) return 'enum:' + t.enumValues.map(e => `${String(e.symbol).toLowerCase()}=${e.number}`).sort().join(',');
  if (t.unit?.baseUnit) return 'unit:' + String(t.unit.baseUnit).toLowerCase();
  if (Array.isArray(t.fields)) return 'fields:' + t.fields.map(f => f.name).sort().join(',');
  return 'type:' + t.dataType;
}

// -> [{stream, reading, expected, got}] for every stream whose definition does not match PINNED
function unitsGuard(defs) {
  const got = Object.fromEntries((defs || []).filter(d => d.entityType === 'asset').map(d => [d.readingId, normalizeDefinition(d)]));
  return STREAMS.filter(s => got[s.reading] !== PINNED[s.reading])
    .map(s => ({ stream: s.key, reading: s.reading, expected: PINNED[s.reading], got: got[s.reading] ?? 'missing' }));
}

const round3 = v => Math.round(v * 1000) / 1000;
const PTO = { on: true, off: false };

// Samsara rows of ONE stream for ONE entity -> { rows, skipped, unresolved }. Rows of a table always carry the
// same keys. `now` (ms) bounds future stamps; `siteMap` maps a stripped Samsara address id -> property_id.
function transform(stream, data, entityId, { now, siteMap }) {
  const rows = []; let skipped = 0, unresolved = 0;
  for (const d of data || []) {
    const t = Date.parse(d?.happenedAtTime);
    if (!Number.isFinite(t) || t > now + 5 * 60e3) { skipped++; continue; }
    const recorded_at = new Date(t).toISOString(), v = d.value;
    if (stream.key === 'distance' || stream.key === 'percent') {
      const x = typeof v === 'number' ? round3(v) : NaN;
      const ok = stream.key === 'distance' ? x >= 0 && x < 10 : x >= 0 && x <= 100;
      if (!ok) { skipped++; continue; }
      rows.push(stream.key === 'distance' ? { tank_sensor_id: entityId, recorded_at, distance_meters: x }
                                          : { tank_sensor_id: entityId, recorded_at, fill_percent: x });
    } else if (stream.key === 'rpm') {
      const x = typeof v === 'number' ? Math.round(v) : NaN;
      if (!(x >= 0 && x <= 6000)) { skipped++; continue; }
      rows.push({ vehicle_id: entityId, recorded_at, engine_rpm: x });
    } else if (stream.key === 'pto') {
      if (!Object.hasOwn(PTO, v)) { skipped++; continue; }   // 'on'/'off' only; never a prototype key
      rows.push({ vehicle_id: entityId, recorded_at, pto_engaged: PTO[v] });
    } else {
      const entries = v?.addressEntries;   // the payload field; the definition's addressIds is not sent
      if (!Array.isArray(entries)) { skipped++; continue; }
      for (const e of entries) {
        const property_id = siteMap.get(String(e && typeof e === 'object' ? e.id : e).replace(/^addr_/, ''));
        if (!property_id) { unresolved++; continue; }
        rows.push({ vehicle_id: entityId, property_id, recorded_at, event_kind: stream.key === 'address_entry' ? 'entry' : 'exit' });
      }
    }
  }
  return { rows, skipped, unresolved };
}

const rowKey = (stream, r) => stream.conflict.split(',').map(c => r[c]).join('|');
const chunks = (a, n) => Array.from({ length: Math.ceil(a.length / n) }, (_, i) => a.slice(i * n, i * n + n));

function parseArgs(argv) {
  // every argument must look like --name or --name=value: a mistyped '-dry-run' or 'dry-run' would otherwise be
  // dropped silently and the run would WRITE
  const stray = argv.filter(x => !/^--[a-z-]+(=.*)?$/.test(x));
  if (stray.length) throw new Error('unknown argument(s): ' + stray.join(' '));
  const a = Object.fromEntries(argv.map(x => { const [k, ...v] = x.slice(2).split('='); return [k, v.length ? v.join('=') : true]; }));
  const known = ['dry-run', 'from', 'window-hours', 'assets'];
  const bad = Object.keys(a).filter(k => !known.includes(k));
  if (bad.length) throw new Error('unknown option(s): ' + bad.join(', '));
  if (a.assets && !a['dry-run']) throw new Error('--assets is for --dry-run only (the real run resolves assets through entity_source_links)');
  if (a.from && !Number.isFinite(Date.parse(a.from))) throw new Error('--from is not a date');
  const windowHours = a['window-hours'] ? Number(a['window-hours']) : 72;
  if (!(windowHours > 0)) throw new Error('--window-hours must be a positive number');
  // --assets=sensor:<samsara id>=<tank_sensors.id>,truck:<samsara id>=<vehicles.id>,...  (dry run only)
  let assets = null;
  if (a.assets) {
    assets = { sensor: new Map(), truck: new Map() };
    for (const p of String(a.assets).split(',')) {
      const m = p.match(/^(sensor|truck):(\d+)=(\d+)$/);
      if (!m) throw new Error('bad --assets entry: ' + p);
      assets[m[1]].set(m[2], Number(m[3]));
    }
  }
  return { dryRun: !!a['dry-run'], from: a.from || null, windowHours, assets };
}

// ---------- I/O ----------
// `io.fetch` / `io.sleep` are the real ones unless main() is handed stubs (the end-to-end test does that).
const io = { fetch: (...a) => fetch(...a), sleep: ms => new Promise(r => setTimeout(r, ms)) };
// Retries 429, any 5xx and a network error or timeout (scripts/lib/samsara_client.js).
const client = samsaraClient({ fetch: (...a) => io.fetch(...a), sleep: ms => io.sleep(ms), token: () => process.env.SAMSARA_API_TOKEN });
const samsaraPaged = (path, pauseMs) => client.paged(path, { pauseMs });

async function rest(path, { method = 'GET', body, prefer, profile } = {}) {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const r = await io.fetch(process.env.SUPABASE_URL + '/rest/v1' + path, { method, signal: AbortSignal.timeout(60000),
    headers: { apikey: key, Authorization: 'Bearer ' + key, 'Content-Type': 'application/json', 'X-App-Source': APP_SOURCE,
      ...(prefer && { Prefer: prefer }), ...(profile && { 'Accept-Profile': profile }) },
    body: body && JSON.stringify(body) });
  return { status: r.status, json: await r.json().catch(() => null) };
}
async function restOk(path, opts) {
  const r = await rest(path, opts);
  if (r.status >= 300) throw new Error(`PostgREST HTTP ${r.status} on ${path.split('?')[0]}: ${JSON.stringify(r.json).slice(0, 200)}`);
  return r.json;
}

async function eslMap(entityType) {
  const rows = await restOk(`/entity_source_links?entity_type=eq.${entityType}&source_system=eq.samsara&select=entity_id,source_id`);
  return new Map(rows.map(r => [String(r.source_id), Number(r.entity_id)]));
}

// Samsara address id -> site property. Prefers public.v_vehicle_site_addresses (plan section 6, dump sites AND the
// yard); until that view exists, falls back to the existing ESL property links of the dump-site properties
// listed in ops.v_dump_sites (today: address 322485232 -> property 98). The fallback knows no yard.
// ponytail: delete the fallback once the view is applied (M6).
async function siteAddressMap() {
  const v = await rest('/v_vehicle_site_addresses?select=property_id,samsara_address_id');
  if (v.status === 200) return { resolver: 'v_vehicle_site_addresses',
    map: new Map(v.json.map(r => [String(r.samsara_address_id).replace(/^addr_/, ''), Number(r.property_id)])) };
  if (v.status !== 404) throw new Error(`v_vehicle_site_addresses HTTP ${v.status}`);
  const sites = await restOk('/v_dump_sites?select=property_id', { profile: 'ops' });
  const ids = sites.map(s => Number(s.property_id)).filter(Number.isInteger);
  const links = ids.length ? await restOk(`/entity_source_links?entity_type=eq.property&source_system=eq.samsara&entity_id=in.(${ids.join(',')})&select=entity_id,source_id`) : [];
  return { resolver: 'esl_dump_site_properties', map: new Map(links.map(l => [String(l.source_id).replace(/^addr_/, ''), Number(l.entity_id)])) };
}

// main(argv, { fetch, now, log, error }) -> exit code (0 or 1). Throws on a setup failure (FATAL, exit 1).
async function main(argv = process.argv.slice(2), deps = {}) {
  const opt = parseArgs(argv);
  if (deps.fetch) io.fetch = deps.fetch;
  if (deps.sleep) io.sleep = deps.sleep;
  const log = deps.log || console.log, logErr = deps.error || console.error;
  for (const k of ['SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY', 'SAMSARA_API_TOKEN'])
    if (!process.env[k]) throw new Error('missing ' + k);
  const now = deps.now ?? Date.now();
  const errors = [];
  const summary = { dry_run: opt.dryRun || undefined, window_start: null, window_end: new Date(now).toISOString(), chunks: 0,
    deep_pass: false, deep_pass_recovered: 0, streams: {}, skipped_streams: [], unlinked_level_assets: null, site_resolver: null,
    resume_point: false, errors: 0, rows_inserted: 0 };
  for (const s of STREAMS) summary.streams[s.key] = { received: 0, rows: 0, inserted: 0, skipped: 0, unresolved: 0 };

  const entities = opt.assets || { sensor: await eslMap('tank_sensor'), truck: await eslMap('vehicle') };
  // a real run with nothing linked would succeed while storing nothing, and move the cursor past that history
  if (!opt.dryRun && (!entities.sensor.size || !entities.truck.size))
    throw new Error(`entity_source_links holds ${entities.sensor.size} tank_sensor and ${entities.truck.size} vehicle samsara links: refusing to run (apply M2 first)`);
  const site = await siteAddressMap();
  summary.site_resolver = site.resolver;

  // window. The cursor is the newest successful run that stored every stream (resume_point true).
  const last = (await restOk(`/sync_log?sync_source=eq.${SOURCE}&status=eq.success&details->summary->>resume_point=eq.true&select=started_at&order=started_at.desc&limit=1`))[0];
  const lastMs = last && Date.parse(last.started_at);
  const cursor = lastMs ? lastMs - 30 * 60e3 : Date.parse(BACKFILL_START);
  let start, normalStart;
  if (opt.from) start = normalStart = Date.parse(opt.from);
  else {
    normalStart = cursor;
    const recentDeep = await restOk(`/sync_log?sync_source=eq.${SOURCE}&status=eq.success&started_at=gte.${new Date(now - 24 * HOUR).toISOString()}&details->summary->>deep_pass=eq.true&select=id&limit=1`);
    summary.deep_pass = !recentDeep.length;
    start = summary.deep_pass && lastMs ? Math.min(normalStart, lastMs - 48 * HOUR) : normalStart;
  }
  summary.window_start = new Date(start).toISOString();

  // units guard
  const defs = await samsaraPaged(`/readings/definitions?ids=${STREAMS.map(s => s.reading).join(',')}`);
  summary.skipped_streams = unitsGuard(defs);
  const skip = new Set(summary.skipped_streams.map(s => s.stream));
  summary.resume_point = !opt.dryRun && !skip.size && start <= cursor;

  // discovery (advisory): its failure is an error, never a reason to skip ingestion
  if (summary.deep_pass) {
    try {
      const latest = await samsaraPaged('/readings/latest?readingIds=remoteSensingDistance&entityType=asset');
      summary.unlinked_level_assets = [...new Set(latest.map(r => String(r.entityId)))].filter(id => !entities.sensor.has(id));
    } catch (e) { errors.push(`discovery: ${e.message}`); }
  }

  const pauseMs = opt.from ? 500 : 0;
  const seen = Object.fromEntries(STREAMS.map(s => [s.key, new Set()]));
  const byDay = Object.fromEntries(STREAMS.map(s => [s.key, {}]));
  for (let c = start; c < now; c += opt.windowHours * HOUR) {
    const cEnd = Math.min(c + opt.windowHours * HOUR, now);
    summary.chunks++;
    for (const s of STREAMS) {
      if (skip.has(s.key)) continue;
      const st = summary.streams[s.key];
      for (const [samsaraId, entityId] of entities[s.on]) {
        let data;
        try {
          data = await samsaraPaged(`/readings/history?readingId=${s.reading}&entityType=asset&entityIds=${samsaraId}` +
            `&startTime=${encodeURIComponent(new Date(c).toISOString())}&endTime=${encodeURIComponent(new Date(cEnd).toISOString())}`, pauseMs);
        } catch (e) { errors.push(`${s.key} ${entityId}: ${e.message}`); continue; }
        st.received += data.length;
        const t = transform(s, data, entityId, { now, siteMap: site.map });
        st.skipped += t.skipped; st.unresolved += t.unresolved;
        const rows = t.rows.filter(r => { const k = rowKey(s, r); return !seen[s.key].has(k) && seen[s.key].add(k); });
        st.rows += rows.length;
        for (const r of rows) { const d = `${r.recorded_at.slice(0, 10)} id${entityId}`; byDay[s.key][d] = (byDay[s.key][d] || 0) + 1; }
        if (opt.dryRun || !rows.length) continue;
        for (const ch of chunks(rows, 1000)) {
          try {
            const ins = await restOk(`/${s.table}?on_conflict=${s.conflict}&select=recorded_at`,
              { method: 'POST', body: ch, prefer: 'resolution=ignore-duplicates,return=representation' });
            st.inserted += ins.length;
            if (summary.deep_pass) summary.deep_pass_recovered += ins.filter(r => Date.parse(r.recorded_at) < normalStart).length;
          } catch (e) { errors.push(`${s.key} ${entityId} insert: ${e.message}`); }
        }
      }
    }
  }
  summary.rows_inserted = Object.values(summary.streams).reduce((n, s) => n + s.inserted, 0);
  summary.errors = errors.length;
  for (const e of errors) logErr(e);
  if (opt.dryRun) {
    for (const s of STREAMS) log(`${s.key.padEnd(14)} rows by UTC day and internal id: ${JSON.stringify(byDay[s.key])}`);
    log('DRY_RUN_SUMMARY ' + JSON.stringify(summary));
  } else log('RUN_SUMMARY ' + JSON.stringify(summary));
  return errors.length ? 1 : 0;
}

module.exports = { STREAMS, PINNED, normalizeDefinition, unitsGuard, transform, rowKey, chunks, parseArgs, main };

if (require.main === module) main().then(c => { process.exitCode = c; }, e => { console.error('FATAL: ' + e.message); process.exit(1); });
