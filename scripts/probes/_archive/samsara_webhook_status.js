// Investigate why vehicle_telemetry_readings is empty.
// Check: (1) any Samsara entries in webhook_events_log, (2) Samsara webhook
// registration status via API, (3) Samsara API token scope.

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const { newQuery } = require('../populate/lib/db');

function httpsGet(host, path, headers) {
  return new Promise((res, rej) => {
    https.request({ hostname: host, path, headers }, r => {
      let d = '';
      r.on('data', c => d += c);
      r.on('end', () => {
        if (r.statusCode >= 200 && r.statusCode < 300) {
          try { res(JSON.parse(d)); } catch (e) { res({ rawBody: d, statusCode: r.statusCode }); }
        } else res({ statusCode: r.statusCode, error: d.slice(0, 500) });
      });
    }).on('error', e => res({ error: e.message })).end();
  });
}

(async () => {
  console.log('=== SAMSARA WEBHOOK INVESTIGATION ===\n');

  // 1. webhook_events_log entries
  console.log('--- 1. webhook_events_log entries from source=samsara ---');
  try {
    const total = await newQuery(`SELECT COUNT(*)::int AS n FROM webhook_events_log WHERE source_system='samsara';`);
    console.log(`Total Samsara webhook events ever logged: ${total[0].n}`);

    if (total[0].n > 0) {
      const recent = await newQuery(`
        SELECT created_at, status, event_type, error_message
        FROM webhook_events_log WHERE source_system='samsara'
        ORDER BY created_at DESC LIMIT 5;
      `);
      console.log('Most recent 5:');
      for (const r of recent) console.log(`  ${r.created_at}  status=${r.status}  event_type=${r.event_type}  err=${(r.error_message || '').slice(0,60)}`);
    } else {
      console.log('Zero Samsara webhook events have EVER reached our endpoint.');
    }
  } catch (e) { console.log(`  err: ${e.message.slice(0,80)}`); }

  // 2. Samsara webhook list
  console.log('\n--- 2. Samsara registered webhooks (list via API) ---');
  const SAM = process.env.SAMSARA_API_TOKEN;
  if (!SAM) { console.log('  SAMSARA_API_TOKEN not in .env — cannot check'); }
  else {
    const r = await httpsGet('api.samsara.com', '/webhooks', { Authorization: `Bearer ${SAM}` });
    if (r.error) {
      console.log(`  HTTP ${r.statusCode}: ${r.error.slice(0, 200)}`);
      if (r.statusCode === 403) console.log('  → 403 means token lacks "Webhooks read" scope. Per CLAUDE.md known blockers, scope was suspected.');
    } else if (r.data && Array.isArray(r.data)) {
      console.log(`  ${r.data.length} webhook(s) registered:`);
      for (const w of r.data) {
        console.log(`    name="${w.name}"  url=${w.url}  events=${(w.eventTypes || []).slice(0,5).join(',')}${(w.eventTypes||[]).length>5?'...':''}`);
      }
      if (r.data.length === 0) console.log('  → ZERO webhooks registered. Samsara has nothing to send to us.');
    } else {
      console.log(`  Unexpected response: ${JSON.stringify(r).slice(0, 300)}`);
    }
  }

  // 3. Token scope check via /me endpoint or similar
  console.log('\n--- 3. Samsara token introspection ---');
  const me = await httpsGet('api.samsara.com', '/me', { Authorization: `Bearer ${SAM}` });
  if (me.error) console.log(`  /me HTTP ${me.statusCode}: ${me.error.slice(0,200)}`);
  else if (me.data) console.log(`  organization=${me.data.organizations?.[0]?.name || me.data.name || '?'}, type=${me.data.type || '?'}`);
  else console.log(`  /me response: ${JSON.stringify(me).slice(0,200)}`);

  // 4. Most recent telemetry from API (sanity — does the data even exist on Samsara's side?)
  console.log('\n--- 4. Most recent vehicle stats via /fleet/vehicles/stats ---');
  const stats = await httpsGet('api.samsara.com', '/fleet/vehicles/stats?types=engineStates,fuelPercents&limit=3', { Authorization: `Bearer ${SAM}` });
  if (stats.error) console.log(`  HTTP ${stats.statusCode}: ${stats.error.slice(0, 200)}`);
  else if (stats.data) {
    for (const v of (stats.data || []).slice(0,3)) {
      const fuel = v.fuelPercent?.value;
      const engine = v.engineState?.value;
      const time = v.fuelPercent?.time || v.engineState?.time;
      console.log(`  vehicle id=${v.id} name="${v.name}"  fuel=${fuel}%  engine=${engine}  recorded=${time}`);
    }
    console.log('  → Stats API works. Data exists; the gap is purely the webhook delivery path.');
  }

  process.exit(0);
})().catch(e => { console.error(e); process.exit(1); });
