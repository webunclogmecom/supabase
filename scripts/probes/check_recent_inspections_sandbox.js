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

const SQL = `
  SELECT
    (i.submitted_at AT TIME ZONE 'America/New_York')::date AS et_date,
    i.inspection_type,
    COUNT(*) AS n,
    MIN(i.submitted_at AT TIME ZONE 'America/New_York')::text AS first_et
  FROM inspections i
  WHERE i.submitted_at >= now() - interval '7 days'
  GROUP BY 1, 2
  ORDER BY 1 DESC, 2;
`;

(async () => {
  console.log('=== PRODUCTION ===');
  for (const r of await pg(process.env.SUPABASE_PROJECT_ID, SQL)) {
    console.log(' ', r.et_date, r.inspection_type, '×', r.n, '|', r.first_et);
  }
  console.log('\n=== SANDBOX ===');
  for (const r of await pg(process.env.SANDBOX_SUPABASE_PROJECT_ID, SQL)) {
    console.log(' ', r.et_date, r.inspection_type, '×', r.n, '|', r.first_et);
  }
})();
