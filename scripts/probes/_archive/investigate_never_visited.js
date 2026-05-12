// Why are these clients showing "last_visit=never" if Diego/Yan say they're active?
// Hypothesis A: Visits exist in Jobber but not yet pulled into our DB.
// Hypothesis B: Visits exist in our DB but linked to a different client_id.
// Hypothesis C: Client was created recently (new account), genuinely no visits yet.
// Hypothesis D: Client_code mismatch — same business known under different code in Jobber.

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const r = (sql) => new Promise((res, rej) => {
  const req = https.request({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
  }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res(JSON.parse(b))); });
  req.on('error', rej); req.write(JSON.stringify({query: sql})); req.end();
});

const CODES = ['066-TCE','073-TCE','074-TCE','079-TCE','080-TCE','107-PV','134-SC','138-ASW','142-57','145-NON','174-VIN','180-PV','201-ALA'];

(async () => {
  for (const code of CODES) {
    console.log(`\n=== ${code} ===`);
    // 1. Direct lookup
    const c = await r(`
      SELECT id, client_code, name, status, created_at::date AS created
      FROM clients
      WHERE client_code = '${code}' OR name ILIKE '${code}%'
      ORDER BY id
    `);
    if (!c.length) { console.log('  (no match in clients table)'); continue; }
    for (const row of c) {
      console.log(`  client #${row.id}  code=${row.client_code}  status=${row.status}  created=${row.created}  name="${row.name}"`);

      // 2. Visit count via direct client_id
      const v = await r(`SELECT COUNT(*) AS n, MAX(visit_date)::text AS last FROM visits WHERE client_id = ${row.id}`);
      console.log(`    visits via client_id: ${v[0].n}, last=${v[0].last || 'never'}`);

      // 3. Visit count via property
      const vp = await r(`
        SELECT COUNT(DISTINCT v.id) AS n, MAX(v.visit_date)::text AS last
        FROM visits v
        JOIN properties p ON p.id = v.property_id
        WHERE p.client_id = ${row.id}
      `);
      console.log(`    visits via property:  ${vp[0].n}, last=${vp[0].last || 'never'}`);

      // 4. Properties for this client
      const props = await r(`SELECT id, line1 FROM properties WHERE client_id = ${row.id} ORDER BY id`).catch(() => []);
      const propsArr = Array.isArray(props) ? props : [];
      console.log(`    properties: ${propsArr.length} (${propsArr.slice(0,2).map(p=>p.line1?.slice(0,40)||'(no addr)').join('; ')})`);

      // 5. Service configs
      const sc = await r(`SELECT service_type, frequency_days FROM service_configs WHERE client_id = ${row.id}`);
      console.log(`    service_configs: ${sc.map(s => `${s.service_type}=${s.frequency_days}`).join(', ') || '(none)'}`);

      // 6. ESL coverage (Jobber + Airtable presence)
      const esl = await r(`SELECT source_system, source_id FROM entity_source_links WHERE entity_type='client' AND entity_id = ${row.id} ORDER BY source_system`);
      console.log(`    ESL: ${esl.map(e => `${e.source_system}:${e.source_id.slice(0, 30)}`).join(' | ') || '(none)'}`);
    }
  }
})().catch(e => { console.error(e.message); process.exit(2); });
