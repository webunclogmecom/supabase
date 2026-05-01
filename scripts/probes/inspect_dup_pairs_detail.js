// Detail inspection of the 3 duplicate-pair contents — specifically: are the
// invoices/properties on each row the SAME Jobber records (re-imported) or
// genuinely different rows we'd lose by merging?
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
  for (const [older, newer, label] of [[353, 436, 'Le Specialita'], [354, 437, 'YASU'], [376, 444, 'Tower 41']]) {
    console.log(`\n========== [${label}] older=${older} newer=${newer} ==========`);

    console.log('-- Properties on each --');
    console.table(await q(`
      SELECT id, client_id, address, is_primary
      FROM properties WHERE client_id IN (${older}, ${newer})
      ORDER BY client_id, id;
    `));

    console.log('-- Invoices on each --');
    console.table(await q(`
      SELECT i.id, i.client_id, i.invoice_number, i.total,
        (SELECT source_id FROM entity_source_links
         WHERE entity_type='invoice' AND entity_id=i.id LIMIT 1) AS jobber_id
      FROM invoices i WHERE i.client_id IN (${older}, ${newer})
      ORDER BY i.client_id, i.id;
    `));

    console.log('-- Jobs on each --');
    console.table(await q(`
      SELECT j.id, j.client_id, j.title,
        (SELECT source_id FROM entity_source_links
         WHERE entity_type='job' AND entity_id=j.id LIMIT 1) AS jobber_id
      FROM jobs j WHERE j.client_id IN (${older}, ${newer})
      ORDER BY j.client_id, j.id;
    `));

    console.log('-- Visits on each --');
    console.table(await q(`
      SELECT v.id, v.client_id, v.visit_date, v.visit_status,
        (SELECT source_id FROM entity_source_links
         WHERE entity_type='visit' AND entity_id=v.id LIMIT 1) AS jobber_id
      FROM visits v WHERE v.client_id IN (${older}, ${newer})
      ORDER BY v.client_id, v.visit_date;
    `));
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
