// Audit the DB population pipelines — webhooks, crons, sync scripts.
// Are they alive? Recent? Any failures piling up?
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const H = { apikey: KEY, Authorization: `Bearer ${KEY}` };

async function rest(qs, opts = {}) {
  const r = await fetch(`${URL}/rest/v1/${qs}`, { ...opts, headers: { ...H, ...(opts.headers || {}) } });
  const text = await r.text();
  const body = text ? JSON.parse(text) : null;
  return { ok: r.ok, status: r.status, body, contentRange: r.headers.get('content-range') };
}

(async () => {
  console.log('═══ DB POPULATION PIPELINE AUDIT ═══\n');

  // ============================================================
  // 1) Webhook events — last 24h, success vs failure
  // ============================================================
  console.log('1) WEBHOOK EVENTS — last 24h');
  const since24 = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
  const since1h = new Date(Date.now() - 3600 * 1000).toISOString();

  const recent = await rest(`webhook_events_log?created_at=gte.${since24}&select=source_system,status,event_type,error_message&limit=5000`);
  const bySrc = {};
  for (const e of recent.body) {
    const k = `${e.source_system}/${e.status}`;
    bySrc[k] = (bySrc[k] || 0) + 1;
  }
  console.table(Object.entries(bySrc).map(([k, n]) => ({ bucket: k, count: n })));

  // Last hour activity (is it currently firing?)
  const lastHour = await rest(`webhook_events_log?created_at=gte.${since1h}&select=source_system,status&limit=500`);
  const lastHourBySrc = {};
  for (const e of lastHour.body) {
    const k = `${e.source_system}/${e.status}`;
    lastHourBySrc[k] = (lastHourBySrc[k] || 0) + 1;
  }
  console.log('  last hour:', JSON.stringify(lastHourBySrc));

  // Recent failures — top 5 error patterns
  const fails = await rest(`webhook_events_log?status=eq.failed&created_at=gte.${since24}&select=source_system,event_type,error_message,created_at&order=created_at.desc&limit=10`);
  if (fails.body.length) {
    console.log(`\n  ⚠ ${fails.body.length} recent failures (last 24h, top 10):`);
    for (const f of fails.body) {
      console.log(`    [${f.created_at?.slice(11,16)}] ${f.source_system}/${f.event_type}: ${(f.error_message || '').slice(0, 120)}`);
    }
  }

  // ============================================================
  // 2) Data freshness — when did each main table last receive data?
  // ============================================================
  console.log('\n2) TABLE FRESHNESS — most recent INSERT/UPDATE per table');
  const tables = ['clients', 'properties', 'visits', 'jobs', 'invoices', 'derm_manifests', 'manifest_visits', 'photo_classifications', 'vehicle_telemetry_readings'];
  const freshness = [];
  for (const t of tables) {
    // Try updated_at first, fall back to created_at
    const col = t === 'manifest_visits' || t === 'vehicle_telemetry_readings' ? 'created_at' : 'updated_at';
    const r = await rest(`${t}?select=${col}&order=${col}.desc&limit=1`);
    const last = r.body?.[0]?.[col];
    if (!last) { freshness.push({ table: t, last_change: '(none)' }); continue; }
    const ageHrs = ((Date.now() - new Date(last).getTime()) / 3600000).toFixed(1);
    freshness.push({ table: t, last_change: last.slice(0, 19), hrs_ago: ageHrs });
  }
  console.table(freshness);

  // ============================================================
  // 3) Today's INSERTs per table (volume sanity)
  // ============================================================
  console.log('3) TODAY\'S INSERTS — created_at >= last 24h');
  const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
  const inserts = [];
  for (const t of tables) {
    const r = await rest(`${t}?created_at=gte.${since}&select=id`, { headers: { Prefer: 'count=exact', Range: '0-0' } });
    const n = Number(r.contentRange?.split('/')[1] || 0);
    inserts.push({ table: t, inserts_24h: n });
  }
  console.table(inserts);

  // ============================================================
  // 4) Samsara telemetry — last GPS reading per vehicle
  // ============================================================
  console.log('4) SAMSARA TELEMETRY — last reading per active vehicle');
  const vehicles = await rest('vehicles?status=eq.ACTIVE&select=id,name&limit=10');
  const tel = [];
  for (const v of vehicles.body) {
    const r = await rest(`vehicle_telemetry_readings?vehicle_id=eq.${v.id}&select=recorded_at&order=recorded_at.desc&limit=1`);
    const last = r.body?.[0]?.recorded_at;
    const ageMin = last ? Math.round((Date.now() - new Date(last).getTime()) / 60000) : null;
    tel.push({ vehicle: v.name, last_seen_at: last?.slice(0, 19), min_ago: ageMin });
  }
  console.table(tel);
})().catch(err => { console.error(err); process.exit(1); });
