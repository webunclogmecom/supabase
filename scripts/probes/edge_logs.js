// edge_logs.js - read Supabase log sources via the Management API analytics endpoint.
// Usage: node scripts/probes/edge_logs.js "<sql>" <outfile>
//
// Written 2026-08-25 to diagnose WORKER_RESOURCE_LIMIT on send-visit-photos-email.
// The 546 body literally says "please check logs" and nothing else in this repo could read them.
//
// Log sources are BigQuery-ish, NOT Postgres:
//   function_edge_logs  - one row per edge function invocation (status, execution time)
//   function_logs       - console.* output from inside a function
//   edge_logs           - the API gateway in front of everything
// metadata is a REPEATED field: reach its children with `cross join unnest(metadata) as m`.
// A field that does not exist is a hard ERROR rather than a null, which makes a failed
// query a usable way to discover the schema.
const https = require('https');
const fs = require('fs');
const path = require('path');
for (const line of fs.readFileSync(path.resolve(__dirname, '../../.env'), 'utf8').split(/\r?\n/)) {
  const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
  if (!m) continue;
  let v = m[2].trim();
  if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
  if (!(m[1] in process.env)) process.env[m[1]] = v;
}

const sql = process.argv[2];
const out = process.argv[3] || 'edge_logs.out.json';
if (!sql) { console.error('usage: node edge_logs.js "<sql>" <outfile>'); process.exit(2); }

const qs = new URLSearchParams({ sql }).toString();
const req = https.request({
  hostname: 'api.supabase.com',
  path: `/v1/projects/${process.env.SUPABASE_PROJECT_ID}/analytics/endpoints/logs.all?${qs}`,
  method: 'GET',
  headers: { Authorization: 'Bearer ' + process.env.SUPABASE_PAT },
}, res => {
  let d = '';
  res.on('data', c => (d += c));
  res.on('end', () => {
    fs.writeFileSync(out, d);
    let n = 'n/a';
    try { const j = JSON.parse(d); n = Array.isArray(j.result) ? j.result.length : 'ERROR'; } catch (e) { /* raw */ }
    console.log(`HTTP ${res.statusCode} rows=${n} -> ${out} (${d.length} bytes)`);
  });
});
req.on('error', e => { console.error('ERR', e.message); process.exit(1); });
req.end();
