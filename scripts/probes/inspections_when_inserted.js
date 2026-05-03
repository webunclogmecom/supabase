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
  const sql = `
    SELECT id, inspection_type,
      submitted_at::text AS submitted,
      created_at::text   AS created,
      updated_at::text   AS updated
    FROM inspections
    WHERE id IN (106, 6, 255, 249, 256)
    ORDER BY id;
  `;
  console.log('=== PRODUCTION ===');
  for (const r of await pg(process.env.SUPABASE_PROJECT_ID, sql)) console.log(' ', r);
})();
