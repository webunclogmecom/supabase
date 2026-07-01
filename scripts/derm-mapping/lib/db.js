// Shared: parse Supabase/.env and expose q(sql) against the Management API.
const https = require('https');
const fs = require('fs');
const path = require('path');
const ENV = path.resolve(__dirname, '../../../.env'); // -> Supabase/.env
for (const line of fs.readFileSync(ENV, 'utf8').split(/\r?\n/)) {
  const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
  if (m) process.env[m[1]] = m[2].replace(/^["']|["']$/g, '');
}
function q(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com',
      path: '/v1/projects/' + process.env.SUPABASE_PROJECT_ID + '/database/query',
      method: 'POST',
      headers: { Authorization: 'Bearer ' + process.env.SUPABASE_PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, r => { let d = ''; r.on('data', c => d += c); r.on('end', () => {
      let j; try { j = JSON.parse(d); } catch (e) { return rej(new Error('non-JSON: ' + d.slice(0, 300))); }
      if (Array.isArray(j)) return res(j);
      if (j && (j.message || j.error)) return rej(new Error(String(j.message || j.error || JSON.stringify(j)).slice(0, 400)));
      res(j); // DDL returns {} or []
    }); });
    req.on('error', rej); req.write(body); req.end();
  });
}
module.exports = { q };
