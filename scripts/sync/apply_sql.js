// apply_sql.js <path-to-.sql> — apply a SQL file to Prod via the Supabase Management API.
// Reusable migration runner. Reads SUPABASE_PAT + SUPABASE_URL from Supabase/.env.
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
const file = process.argv[2];
if (!file) { console.error('usage: node apply_sql.js <file.sql>'); process.exit(1); }
const sql = fs.readFileSync(path.resolve(file), 'utf8');
const body = JSON.stringify({ query: sql });
const req = https.request({ hostname: 'api.supabase.com', path: '/v1/projects/' + ref + '/database/query', method: 'POST',
  headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } },
  r => { let d = ''; r.on('data', c => d += c); r.on('end', () => { console.log('HTTP ' + r.statusCode); console.log(d.slice(0, 1500)); if (r.statusCode >= 300) process.exit(1); }); });
req.on('error', e => { console.error('ERR ' + e.message); process.exit(1); });
req.write(body); req.end();
