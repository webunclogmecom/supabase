// q.js "<sql>" — run a read query via the Supabase Management API, print JSON rows.
// Quick inline verification helper. For multi-statement / complex SQL use apply_sql.js with a file.
const https = require('https');
const fs = require('fs');
const path = require('path');
function readEnv(k) {
  const p = path.resolve(__dirname, '../../.env');
  const l = fs.readFileSync(p, 'utf8').split(/\r?\n/).find(x => x.startsWith(k + '='));
  return l ? l.slice(k.length + 1).trim() : null;
}
const PAT = readEnv('SUPABASE_PAT');
const ref = (readEnv('SUPABASE_URL') || '').match(/https?:\/\/([^.]+)\./)[1];
const sql = process.argv[2];
if (!sql) { console.error('usage: node q.js "<sql>"'); process.exit(1); }
const body = JSON.stringify({ query: sql });
const req = https.request({ hostname: 'api.supabase.com', path: '/v1/projects/' + ref + '/database/query', method: 'POST',
  headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } },
  r => { let d = ''; r.on('data', c => d += c); r.on('end', () => { if (r.statusCode >= 300) { console.error('HTTP ' + r.statusCode + ' ' + d.slice(0, 600)); process.exit(1); } console.log(d); }); });
req.on('error', e => { console.error('ERR ' + e.message); process.exit(1); });
req.write(body); req.end();
