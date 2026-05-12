require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const fs = require('fs'); const path = require('path'); const https = require('https');
const sql = fs.readFileSync(path.resolve(__dirname, '../migrations/yannick_app_tables_check_constraints_2026_05_07.sql'), 'utf8');

async function pg(query) {
  const r = await new Promise((res, rej) => {
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
    }, x => { let b = ''; x.on('data', d => b += d); x.on('end', () => res({ status: x.statusCode, body: b })); });
    req.on('error', rej);
    req.write(JSON.stringify({ query }));
    req.end();
  });
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.slice(0, 400)}`);
  return JSON.parse(r.body);
}

(async () => {
  await pg(sql);
  console.log('✓ CHECK constraints migration applied to Prod');
  const checks = await pg(`
    SELECT conrelid::regclass::text AS tbl, conname, pg_get_constraintdef(oid) AS def
    FROM pg_constraint
    WHERE conrelid IN ('public.app_visit_reviews'::regclass, 'public.app_shift_reviews'::regclass)
      AND contype = 'c'
    ORDER BY 1, 2;
  `);
  console.log('\nVerified CHECK constraints:');
  for (const c of checks) console.log(`  ${c.tbl.padEnd(28)} ${c.conname.padEnd(50)} ${c.def}`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
