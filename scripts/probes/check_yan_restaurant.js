// Quick probe: does Yan's Restaurant (112-YA) exist in clients?
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROJECT_ID = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;

function q(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${PROJECT_ID}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>r.statusCode<300?res(JSON.parse(d)):rej(new Error(`${r.statusCode}: ${d.slice(0,400)}`))); });
    req.on('error', rej); req.write(body); req.end();
  });
}

(async () => {
  console.log('=== Search 1: client_code or name match Yan ===');
  console.table(await q(`
    SELECT id, client_code, name, status FROM clients
    WHERE client_code ILIKE '%YA%' OR name ILIKE '%yan%' OR name ILIKE '%restaurant%'
    ORDER BY client_code NULLS LAST LIMIT 30;
  `));

  console.log('\n=== Search 2: client codes starting 112 ===');
  console.table(await q(`SELECT id, client_code, name, status FROM clients WHERE client_code ILIKE '112%' ORDER BY client_code;`));

  console.log('\n=== Search 3: look in Jobber ESL for "Yan" ===');
  console.table(await q(`
    SELECT esl.source_system, esl.source_id, c.client_code, c.name, c.status
    FROM entity_source_links esl JOIN clients c ON c.id=esl.entity_id
    WHERE esl.entity_type='client' AND (c.name ILIKE '%yan%' OR c.client_code ILIKE '%YA%')
    ORDER BY c.name LIMIT 20;
  `));

  console.log('\n=== Search 4: total clients + by status ===');
  console.table(await q(`SELECT status, COUNT(*) AS n FROM clients GROUP BY status ORDER BY n DESC;`));

  console.log('\n=== Search 5: how many clients are linked to Jobber vs Airtable ===');
  console.table(await q(`
    SELECT source_system, COUNT(DISTINCT entity_id) AS clients_linked
    FROM entity_source_links WHERE entity_type='client' GROUP BY source_system;
  `));
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
