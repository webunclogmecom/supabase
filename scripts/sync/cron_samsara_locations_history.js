// Pulls high-frequency GPS history from Samsara
// (/fleet/vehicles/locations/history) into vehicle_telemetry_readings.
//
// Complements cron_samsara_telemetry.js which pulls /stats every 10 min
// (snapshots with engine, fuel, odometer at low frequency). This one is
// GPS-only at ~30-second resolution for precise visit-window attribution.
//
// Both write to vehicle_telemetry_readings with
//   ON CONFLICT (vehicle_id, recorded_at) DO NOTHING
// so dedup is automatic across the two sources.
//
// Schedule: every 15 min via .github/workflows/samsara-locations-history.yml
//   pulls the last 90 minutes (50% overlap with prior run — ON CONFLICT
//   absorbs duplicates).
//
// Manual backfill: workflow_dispatch with start_time / end_time inputs,
// OR `START_TIME=... END_TIME=... node cron_samsara_locations_history.js`.

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const SUPABASE_URL = process.env.SUPABASE_URL;
const SVC = process.env.SUPABASE_SERVICE_ROLE_KEY;
const SAMSARA_TOKEN = process.env.SAMSARA_API_TOKEN;
if (!SUPABASE_URL || !SVC || !SAMSARA_TOKEN) {
  console.error('Missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / SAMSARA_API_TOKEN');
  process.exit(1);
}

// Window. END defaults to now. START is SELF-HEALING: when not overridden it
// resumes from the most recent telemetry we already have, so a throttled/skipped
// GitHub run backfills the whole gap instead of permanently losing any span
// longer than a fixed lookback (the */15 schedule gets throttled past 90 min,
// which silently dropped ~70-79% of overnight GPS in June 2026). It is floored
// to AUTO_LOOKBACK_H so an auto-run never pulls an unbounded span. Manual
// backfill: set START_TIME / END_TIME env (ISO-8601 UTC).
const END_TIME = process.env.END_TIME || new Date().toISOString();
const ENV_START = process.env.START_TIME || null;
const AUTO_LOOKBACK_H = Number(process.env.AUTO_LOOKBACK_H || 24); // max lookback cap for auto-runs (6->24 2026-07-14: an overnight run-gap >6h was silently dropping GPS beyond 6h; Samsara retains history + ON CONFLICT dedups, so a generous cap is cheap and only bites on long stalls)
let START_TIME = ENV_START; // resolved in main() when null (self-heal)

function http(opts, body) { return new Promise((res, rej) => {
  const payload = body == null ? null : (typeof body === 'string' ? body : JSON.stringify(body));
  const req = https.request({...opts, headers:{...(opts.headers||{}), ...(payload?{'Content-Length':Buffer.byteLength(payload)}:{})}}, r => {
    const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()}));
  });
  req.on('error',rej); if(payload) req.write(payload); req.end();
});}
async function rest(path, opts = {}) {
  const u = new URL(SUPABASE_URL + '/rest/v1' + path);
  return http({hostname:u.hostname, path:u.pathname+u.search, method:opts.method||'GET',
    headers:{apikey:SVC, Authorization:'Bearer '+SVC, 'Content-Type':'application/json',
      ...(opts.prefer?{Prefer:opts.prefer}:{})}}, opts.body);
}
async function samsara(path) {
  const r = await http({hostname:'api.samsara.com', path, method:'GET',
    headers:{Authorization:'Bearer '+SAMSARA_TOKEN, Accept:'application/json'}}, null);
  if (r.status >= 300) throw new Error('Samsara '+r.status+': '+r.body.slice(0,300));
  return JSON.parse(r.body);
}

async function loadVehicleIdMap() {
  const r = await rest('/entity_source_links?entity_type=eq.vehicle&source_system=eq.samsara&select=entity_id,source_id');
  if (r.status !== 200) throw new Error('vehicle ID map fetch failed: HTTP '+r.status);
  const links = JSON.parse(r.body);
  return new Map(links.map(l => [String(l.source_id), l.entity_id]));
}

// Samsara /locations/history can require chunking by time window when the
// requested span is large. We chunk into 24h chunks for safety + clearer
// progress logging.
function* chunkWindow(startISO, endISO, chunkMinutes = 24*60) {
  const start = new Date(startISO).getTime();
  const end   = new Date(endISO).getTime();
  let cursor = start;
  while (cursor < end) {
    const chunkEnd = Math.min(cursor + chunkMinutes*60*1000, end);
    yield { start: new Date(cursor).toISOString(), end: new Date(chunkEnd).toISOString() };
    cursor = chunkEnd;
  }
}

async function pullChunk(vehicleIds, startTime, endTime) {
  const out = [];
  let after = null, pages = 0;
  do {
    const sep = '?';
    const cursor = after ? '&after='+encodeURIComponent(after) : '';
    const path = '/fleet/vehicles/locations/history' + sep +
      'vehicleIds=' + vehicleIds.join(',') +
      '&startTime=' + encodeURIComponent(startTime) +
      '&endTime='   + encodeURIComponent(endTime) +
      '&limit=100' + cursor;
    const r = await samsara(path);
    out.push(...(r.data || []));
    after = r.pagination?.hasNextPage ? r.pagination.endCursor : null;
    pages++;
    if (pages > 500) { console.warn('  hit page cap at '+pages); break; }
  } while (after);
  return out;
}

(async () => {
  const t0 = Date.now();
  console.log('[samsara-locations-history] start ' + new Date().toISOString());
  if (!START_TIME) {
    // Self-heal: resume from the latest reading we already have, floored to
    // AUTO_LOOKBACK_H so a long stall doesn't trigger an unbounded pull.
    let lastTs = null;
    try {
      // Resume from the last GPS-ONLY reading (all three stats fields null), NOT the global max.
      // The /stats cron (cron_samsara_telemetry, every 10 min) writes to the SAME table and keeps the
      // global-max recorded_at recent, so resuming from the global max made this self-heal under-reach
      // and silently drop ~40% of active-truck GPS between runs (root-caused 2026-07-14: David overnight
      // = 41% captured vs Samsara's true feed; idle trucks fine). GPS-only rows = odometer/fuel/engine all NULL.
      const r = await rest('/vehicle_telemetry_readings?select=recorded_at&odometer_meters=is.null&fuel_percent=is.null&engine_state=is.null&order=recorded_at.desc&limit=1');
      if (r.status === 200) { const j = JSON.parse(r.body); if (j.length) lastTs = new Date(j[0].recorded_at).getTime(); }
    } catch (e) { console.warn('  [self-heal] last-reading lookup failed: ' + e.message); }
    const floorMs = Date.now() - AUTO_LOOKBACK_H * 60 * 60 * 1000;
    const startMs = lastTs ? Math.max(lastTs, floorMs) : (Date.now() - 90 * 60 * 1000);
    START_TIME = new Date(startMs).toISOString();
    console.log('  [self-heal] auto START_TIME=' + START_TIME +
      (lastTs ? ' (resume from last reading ' + new Date(lastTs).toISOString() + ', floored to ' + AUTO_LOOKBACK_H + 'h)' : ' (no prior reading; 90m default)'));
  }
  console.log('  window: ' + START_TIME + ' → ' + END_TIME);

  const idMap = await loadVehicleIdMap();
  const samsaraIds = [...idMap.keys()];
  console.log('  ' + idMap.size + ' Samsara vehicles mapped');
  if (!idMap.size) { console.log('  nothing to do'); return; }

  let allRows = [];
  for (const chunk of chunkWindow(START_TIME, END_TIME)) {
    console.log('  chunk ' + chunk.start + ' → ' + chunk.end);
    const data = await pullChunk(samsaraIds, chunk.start, chunk.end);
    for (const v of data) {
      const our_id = idMap.get(String(v.id));
      if (!our_id) continue;
      for (const loc of (v.locations || [])) {
        allRows.push({
          vehicle_id: our_id,
          latitude:  loc.latitude  ?? null,
          longitude: loc.longitude ?? null,
          speed_meters_per_sec: loc.speedMilesPerHour != null
            ? Number((loc.speedMilesPerHour * 0.44704).toFixed(2))
            : null,
          heading_degrees: loc.headingDegrees ?? null,
          recorded_at: loc.time,
        });
      }
    }
    console.log('    cumulative rows: ' + allRows.length);
  }

  if (!allRows.length) {
    console.log('  no rows returned by Samsara for this window. Done.');
    return;
  }

  console.log('Inserting ' + allRows.length + ' rows (batched, ON CONFLICT skips dupes)...');
  const BATCH = 500;
  let inserted = 0, failedBatches = 0;
  for (let i = 0; i < allRows.length; i += BATCH) {
    const chunk = allRows.slice(i, i+BATCH);
    const r = await rest('/vehicle_telemetry_readings?on_conflict=vehicle_id,recorded_at', {
      method: 'POST', body: chunk, prefer: 'resolution=ignore-duplicates,return=minimal',
    });
    if (r.status >= 200 && r.status < 300) inserted += chunk.length;
    else { failedBatches++; console.warn('  batch fail HTTP ' + r.status + ': ' + r.body.slice(0,200)); }
    if ((i / BATCH) % 20 === 0 && i > 0) console.log('    ' + i + '/' + allRows.length);
  }
  const dt = ((Date.now() - t0) / 1000).toFixed(1);
  console.log('Done in ' + dt + 's. Submitted ' + inserted + ' rows (DB will dedup). Failed batches: ' + failedBatches);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
