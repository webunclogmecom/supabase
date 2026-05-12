// Drill-down for the 10 overdue clients: is there a future scheduled visit
// at all? At what cadence? Compare actual_scheduled vs expected (last + freq).
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

async function pg(sql) {
  for (let i = 0; i < 3; i++) {
    const out = await new Promise((res, rej) => {
      const req = https.request({
        hostname: 'api.supabase.com',
        path: `/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`,
        method: 'POST',
        headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
      }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res({ status: x.statusCode, body: b })); });
      req.on('error', rej); req.write(JSON.stringify({ query: sql })); req.end();
    });
    if (out.status < 300) return JSON.parse(out.body);
    await new Promise(rs => setTimeout(rs, 4000));
  }
  throw new Error('5xx');
}

const CLIENTS = [
  ['013-DIM',  'CL',  30],
  ['026-HAP',  'CL',  60],
  ['172-NU',   'GT',  60],
  ['174-VIN',  'GT',  30],
  ['029-JOS',  'GT',  30],
  ['069-TCE',  'GT',  30],
  ['070-TCE',  'CL', 120],
  ['089-COW',  'GT',  40],
  ['083-SHUL', 'CL',  60],
  ['112-YA',   'GT',  10],
];

(async () => {
  for (const [code, svc, freq] of CLIENTS) {
    console.log(`\n=== ${code} (${svc}, freq ${freq}d) ===`);

    // Last completed of this type
    const last = await pg(`
      SELECT MAX(visit_date)::text AS d
      FROM visits v
      JOIN clients c ON c.id = v.client_id
      WHERE c.client_code = '${code}'
        AND v.service_type = '${svc}'
        AND v.visit_status = 'completed'
    `);
    const lastDone = last[0]?.d;
    if (!lastDone) { console.log('  no completed visits of this type'); continue; }
    const expectedNext = new Date(new Date(lastDone).getTime() + freq * 86400000)
      .toISOString().slice(0, 10);
    console.log(`  last completed: ${lastDone}  → expected next: ${expectedNext}`);

    // ALL future visits (any service_type, any status), sorted by date
    const future = await pg(`
      SELECT visit_date::text AS d, service_type, visit_status, title
      FROM visits v
      JOIN clients c ON c.id = v.client_id
      WHERE c.client_code = '${code}'
        AND v.visit_date >= '${lastDone}'
        AND v.visit_status <> 'completed'
      ORDER BY visit_date
      LIMIT 12
    `);
    if (!future.length) {
      console.log(`  ❌ NO future visits scheduled at all`);
    } else {
      console.log(`  upcoming visits (any service_type, any status):`);
      for (const v of future) {
        const slip = Math.round((new Date(v.d) - new Date(expectedNext)) / 86400000);
        const match = v.service_type === svc;
        const flag = match
          ? (slip > 14 ? '⚠️ ' : '   ')
          : '   ';
        const slipStr = slip > 0 ? `+${slip}d past expected` : `${slip}d before expected`;
        console.log(`    ${flag}${v.d}  ${(v.service_type || '?').padEnd(4)} ${(v.visit_status || '?').padEnd(11)} | ${match ? slipStr : '(different service_type)'} | ${(v.title || '').slice(0, 50)}`);
      }
    }
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
