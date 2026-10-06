// query.js: one SQL request through the Supabase Management API (reads Supabase/.env; never prints a key).
const fs = require('fs'), path = require('path');
const ENV = path.join(__dirname, '..', '..', '..', '..', '.env');
for (const line of fs.readFileSync(ENV, 'utf8').split(/\r?\n/)) {
  const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/); if (!m) continue;
  if (!(m[1] in process.env)) process.env[m[1]] = m[2].trim().replace(/^["']|["']$/g, '');
}
async function query(sql) {
  const t0 = Date.now();
  const r = await fetch(`https://api.supabase.com/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`, {
    method: 'POST', headers: { Authorization: 'Bearer ' + process.env.SUPABASE_PAT, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql }) });
  const body = await r.text(), ms = Date.now() - t0;
  if (r.status >= 300) return { error: 'HTTP ' + r.status + ': ' + body, ms };
  return { rows: JSON.parse(body), ms };
}
module.exports = { query };
