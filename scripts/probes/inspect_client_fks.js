// Find every table that FKs client_id (we need this map to safely merge dup rows)
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
  console.log('=== Tables FK-referencing clients.id ===');
  console.table(await q(`
    SELECT
      tc.table_name AS child_table,
      kcu.column_name AS child_column,
      rc.update_rule, rc.delete_rule
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu USING (constraint_name, table_schema)
    JOIN information_schema.referential_constraints rc USING (constraint_name)
    JOIN information_schema.constraint_column_usage ccu USING (constraint_name)
    WHERE tc.constraint_type='FOREIGN KEY'
      AND ccu.table_name='clients'
      AND ccu.column_name='id'
      AND tc.table_schema='public'
    ORDER BY tc.table_name;
  `));

  console.log('\n=== clients table — does it have a notes column? ===');
  console.table(await q(`
    SELECT column_name, data_type FROM information_schema.columns
    WHERE table_schema='public' AND table_name='clients' ORDER BY ordinal_position;
  `));

  console.log('\n=== row counts on each duplicate pair ===');
  for (const [older, newer, label] of [[353, 436, 'Le Specialita'], [354, 437, 'YASU'], [376, 444, 'Tower 41']]) {
    console.log(`\n[${label}] older=${older} newer=${newer}`);
    console.table(await q(`
      SELECT 'properties' AS tbl, client_id, COUNT(*) AS n FROM properties WHERE client_id IN (${older}, ${newer}) GROUP BY client_id
      UNION ALL SELECT 'visits', client_id, COUNT(*) FROM visits WHERE client_id IN (${older}, ${newer}) GROUP BY client_id
      UNION ALL SELECT 'jobs', client_id, COUNT(*) FROM jobs WHERE client_id IN (${older}, ${newer}) GROUP BY client_id
      UNION ALL SELECT 'invoices', client_id, COUNT(*) FROM invoices WHERE client_id IN (${older}, ${newer}) GROUP BY client_id
      UNION ALL SELECT 'service_configs', client_id, COUNT(*) FROM service_configs WHERE client_id IN (${older}, ${newer}) GROUP BY client_id
      UNION ALL SELECT 'quotes', client_id, COUNT(*) FROM quotes WHERE client_id IN (${older}, ${newer}) GROUP BY client_id
      ORDER BY tbl, client_id;
    `));
    console.table(await q(`
      SELECT entity_id, source_system, source_id FROM entity_source_links
      WHERE entity_type='client' AND entity_id IN (${older}, ${newer})
      ORDER BY entity_id, source_system;
    `));
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
