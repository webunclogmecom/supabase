// Runs the HR App probes against Prod inside a transaction that always rolls back (each probe ends by
// RAISE-ing its results), and prints PASS / FAIL per probe. Nothing is ever committed.
// usage: node scripts/checks/hr_app/run.js            (both files)
//        node scripts/checks/hr_app/run.js probe_edit.sql
const fs = require('fs');
const path = require('path');
const https = require('https');
for (const line of fs.readFileSync(path.resolve(__dirname, '../../../.env'), 'utf8').split(/\r?\n/)) {
  const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
  if (m && !(m[1] in process.env)) process.env[m[1]] = m[2].trim().replace(/^["']|["']$/g, '');
}
function query(sql) {
  return new Promise((resolve) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({ hostname: 'api.supabase.com', method: 'POST',
      path: '/v1/projects/' + process.env.SUPABASE_PROJECT_ID + '/database/query',
      headers: { Authorization: 'Bearer ' + process.env.SUPABASE_PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } },
      (res) => { let d = ''; res.on('data', (c) => (d += c)); res.on('end', () => resolve({ status: res.statusCode, body: d })); });
    req.write(body); req.end();
  });
}
(async () => {
  const files = process.argv.slice(2).length ? process.argv.slice(2) : ['probe_edit.sql', 'probe_pay_bonus.sql', 'probe_bonus_amounts.sql', 'probe_health.sql'];
  let failed = 0;
  for (const f of files) {
    const sql = 'BEGIN;\n' + fs.readFileSync(path.resolve(__dirname, f), 'utf8') + '\nROLLBACK;\n';
    const r = await query(sql);
    let msg = r.body;
    try { msg = JSON.parse(r.body).message || r.body; } catch (e) { /* raw */ }
    const m = String(msg).match(/PROBE_RESULT (\[.*\])/s);
    if (!m) { console.log(f, 'did not report:', String(msg).slice(0, 800)); failed++; continue; }
    for (const x of JSON.parse(m[1])) { if (!x.ok) failed++; console.log(x.ok ? 'PASS' : 'FAIL', f, x.t, x.ok ? '' : JSON.stringify(x).slice(0, 400)); }
  }
  console.log(failed ? failed + ' failed' : 'all passed');
  process.exit(failed ? 1 : 0);
})();
