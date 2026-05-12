require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const PROD = process.env.SUPABASE_PROJECT_ID;
function pg(sql) { return new Promise((res, rej) => {
  const req = https.request({hostname:'api.supabase.com',path:`/v1/projects/${PROD}/database/query`,method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_PAT}`,'Content-Type':'application/json'}}, x => {let b='';x.on('data',d=>b+=d);x.on('end',()=>res({status:x.statusCode,body:b}));});
  req.on('error',rej); req.write(JSON.stringify({query:sql})); req.end();
});}
async function q(sql) { const r = await pg(sql); if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.slice(0,300)}`); return JSON.parse(r.body); }
(async () => {
  console.log('=== properties columns (lat/lng + geofence?) ===');
  const cols = await q(`SELECT column_name, data_type FROM information_schema.columns WHERE table_schema='public' AND table_name='properties' ORDER BY ordinal_position;`);
  for (const c of cols) console.log(`  ${c.column_name.padEnd(30)} ${c.data_type}`);

  console.log('\n=== entity_source_links — are properties linked to Samsara? ===');
  const esl = await q(`
    SELECT source_system, COUNT(*) AS n
    FROM entity_source_links
    WHERE entity_type='property'
    GROUP BY source_system ORDER BY n DESC;`);
  for (const r of esl) console.log(`  ${r.source_system}: ${r.n}`);

  console.log('\n=== Other tables that might hold geofences (samsara_*, geofence_*, etc.) ===');
  const tbls = await q(`SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND (table_name ILIKE '%geofence%' OR table_name ILIKE '%samsara%') ORDER BY 1;`);
  console.log('  ', tbls.map(t => t.table_name).join(', ') || '(none)');

  console.log('\n=== webhook_events_log — today\'s Samsara events ===');
  const wel = await q(`
    SELECT source_system, event_type, COUNT(*) AS n
    FROM webhook_events_log
    WHERE source_system='samsara'
      AND created_at >= (NOW() AT TIME ZONE 'America/New_York')::date AT TIME ZONE 'America/New_York'
    GROUP BY source_system, event_type ORDER BY n DESC;`);
  for (const r of wel) console.log(`  ${r.event_type}: ${r.n}`);
  if (wel.length === 0) console.log('  (no Samsara webhook events today in ET)');

  console.log('\n=== Per-column "updated today" detection — which property cols changed today? ===');
  console.log('  Note: properties has an updated_at trigger — we can see WHICH rows changed but not which columns.');
  const updatedToday = await q(`
    SELECT
      COUNT(*) AS rows_updated_today,
      MIN(updated_at AT TIME ZONE 'America/New_York') AS earliest_update_et,
      MAX(updated_at AT TIME ZONE 'America/New_York') AS latest_update_et
    FROM properties
    WHERE updated_at >= (CURRENT_DATE AT TIME ZONE 'America/New_York');`);
  console.log(JSON.stringify(updatedToday, null, 2));
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
