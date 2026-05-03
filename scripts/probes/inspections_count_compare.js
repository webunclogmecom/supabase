require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c) }));
    });
    req.on('error', rej); if (body) req.write(body); req.end();
  });
}
async function pg(projectId, sql) {
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${projectId}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
  }, JSON.stringify({ query: sql }));
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.toString().slice(0, 200)}`);
  return JSON.parse(r.body.toString());
}

(async () => {
  const Q1 = `SELECT COUNT(*) AS n, MAX(submitted_at)::text AS last_submitted FROM inspections;`;
  const Q2 = `SELECT id, inspection_type, submitted_at::text FROM inspections WHERE submitted_at >= '2026-04-29' ORDER BY submitted_at DESC LIMIT 12;`;

  console.log('=== PRODUCTION ===');
  console.log('count+max:', (await pg(process.env.SUPABASE_PROJECT_ID, Q1))[0]);
  console.log('recent rows:');
  for (const r of await pg(process.env.SUPABASE_PROJECT_ID, Q2)) console.log(' ', r);

  console.log('\n=== SANDBOX ===');
  console.log('count+max:', (await pg(process.env.SANDBOX_SUPABASE_PROJECT_ID, Q1))[0]);
  console.log('recent rows:');
  for (const r of await pg(process.env.SANDBOX_SUPABASE_PROJECT_ID, Q2)) console.log(' ', r);
})();
