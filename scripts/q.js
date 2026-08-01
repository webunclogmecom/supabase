// q.js — run a SQL file against Prod via the Management API, write JSON to a file.
// Usage: node scripts/q.js <sqlfile> <outfile>
// Windows note: results go to a FILE and are JSON.parse'd by the caller; tool-output can corrupt.
// Parse .env directly rather than requiring dotenv: this script must keep working
// when node_modules is absent (it is gitignored and gets cleaned up regularly).
const https = require('https');
const fs = require('fs');
const path = require('path');
for (const line of fs.readFileSync(path.resolve(__dirname, '../.env'), 'utf8').split(/\r?\n/)) {
  const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
  if (!m) continue;
  let v = m[2].trim();
  if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
  if (!(m[1] in process.env)) process.env[m[1]] = v;
}

function query(sql) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com',
      path: '/v1/projects/' + process.env.SUPABASE_PROJECT_ID + '/database/query',
      method: 'POST',
      headers: {
        Authorization: 'Bearer ' + process.env.SUPABASE_PAT,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
      },
    }, res => {
      let d = '';
      res.on('data', c => (d += c));
      res.on('end', () => {
        // Do NOT truncate the error body: matrix payloads are raised as exceptions
        // and a slice() here has silently eaten them before.
        if (res.statusCode >= 300) return reject(new Error('HTTP ' + res.statusCode + ': ' + d));
        try { resolve(JSON.parse(d)); } catch (e) { reject(new Error('Bad JSON: ' + d)); }
      });
    });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

(async () => {
  const sql = fs.readFileSync(process.argv[2], 'utf8');
  try {
    const rows = await query(sql);
    fs.writeFileSync(process.argv[3], JSON.stringify(rows, null, 2));
    console.log('--- query complete --- rows: ' + (Array.isArray(rows) ? rows.length : 'n/a'));
  } catch (e) {
    fs.writeFileSync(process.argv[3], JSON.stringify({ error: e.message }, null, 2));
    console.log('--- query FAILED --- see ' + process.argv[3]);
  }
})();
