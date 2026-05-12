// Replay the 32 inspection webhook events that processed with entity_id=null
// (Airtable single-select payload bug). The webhook-airtable function was
// redeployed; replay sends each stored payload back to the function, which
// will now extract Pre/Post correctly and INSERT/UPDATE inspections.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
const SUPABASE_URL = process.env.SUPABASE_URL;
const ANON = process.env.SUPABASE_ANON_KEY || '';
const SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY;
const AIRTABLE_TOKEN = process.env.AIRTABLE_WEBHOOK_TOKEN;
if (!AIRTABLE_TOKEN) { console.error('AIRTABLE_WEBHOOK_TOKEN missing'); process.exit(1); }

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej); if (body) req.write(body); req.end();
  });
}
async function pg(sql) {
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${PROD}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' }
  }, JSON.stringify({ query: sql }));
  return JSON.parse(r.body);
}

(async () => {
  // Pull all inspection events with entity_id=null (the broken ones)
  const evs = await pg(`
    SELECT id, payload::text AS payload_text
    FROM webhook_events_log
    WHERE source_system = 'airtable' AND event_type = 'automation_inspection'
      AND entity_id IS NULL
      AND created_at >= now() - interval '14 days'
    ORDER BY created_at;
  `);
  console.log(`Replaying ${evs.length} inspection events…`);

  const url = new URL(SUPABASE_URL);
  let ok = 0, fail = 0;
  for (const ev of evs) {
    const r = await http({
      hostname: url.hostname,
      path: '/functions/v1/webhook-airtable',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        // webhook-airtable expects AIRTABLE_WEBHOOK_TOKEN (Path B bearer auth),
        // not the Supabase service role key.
        'Authorization': `Bearer ${AIRTABLE_TOKEN}`,
      },
    }, ev.payload_text);
    if (r.status >= 200 && r.status < 300) {
      ok++;
    } else {
      fail++;
      if (fail <= 3) console.log(`  fail ${ev.id}: HTTP ${r.status}: ${r.body.slice(0, 120)}`);
    }
  }
  console.log(`\n✅ Replayed: ${ok} OK, ${fail} failed`);

  // Check the result
  const post = await pg(`SELECT COUNT(*) AS n, MAX(submitted_at)::text AS latest FROM inspections WHERE updated_at >= now() - interval '5 minutes'`);
  console.log(`Inspections updated in last 5 min: ${post[0].n}, latest submitted=${post[0].latest}`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
