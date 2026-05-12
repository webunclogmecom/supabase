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
(async () => {
  const cols = await r(`SELECT column_name, data_type FROM information_schema.columns WHERE table_schema='public' AND table_name='inspections' ORDER BY ordinal_position`);
  console.log('inspections columns:'); for (const c of cols) console.log(`  ${c.column_name} ${c.data_type}`);
  const samp = await r(`SELECT id, employee_id, submitted_at, inspection_type FROM inspections ORDER BY id LIMIT 5`);
  console.log('\nsample rows:'); for (const s of samp) console.log(`  ${JSON.stringify(s)}`);
}) ().catch(e => { console.error(e.message); process.exit(2); });
