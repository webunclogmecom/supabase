// q_project.js <projectRef> "<SQL>" — run a read query against ANY Supabase project
// in the org via the Management API (reads SUPABASE_PAT from Supabase/.env). Useful for
// cross-project audits (Sandbox #1 ubtlwpcyntelgbykdatn, Field Portal Sandbox, etc.).
// Prints the raw JSON response. SELECT-only by convention.
const https = require('https');
const fs = require('fs');
const path = require('path');
function readEnv(k) {
  const p = path.resolve(__dirname, '../../.env');
  const l = fs.readFileSync(p, 'utf8').split(/\r?\n/).find(x => x.startsWith(k + '='));
  return l ? l.slice(k.length + 1).trim() : null;
}
const PAT = readEnv('SUPABASE_PAT');
const ref = process.argv[2];
const sql = process.argv[3];
if (!ref || !sql) { console.error('usage: node q_project.js <projectRef> "<SQL>"'); process.exit(1); }
const body = JSON.stringify({ query: sql });
const req = https.request({ hostname: 'api.supabase.com', path: '/v1/projects/' + ref + '/database/query', method: 'POST',
  headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } },
  r => { let d = ''; r.on('data', c => d += c); r.on('end', () => { console.log(d); if (r.statusCode >= 300) process.exit(1); }); });
req.on('error', e => { console.error('ERR ' + e.message); process.exit(1); });
req.write(body); req.end();
