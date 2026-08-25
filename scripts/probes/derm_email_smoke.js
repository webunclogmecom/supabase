// derm_email_smoke.js - exercise send-derm-email's attachment path after the base64 port.
//
// 🛑 TEST-ONLY BY CONSTRUCTION. It always sends `test_recipient`, and the function's own
// code makes that decisive (verified by reading it, 2026-08-25):
//     line 395  const toList = testRecipient ? [testRecipient] : cityEmails
//     line 497  const cityBcc = [...(!testRecipient ? [CITY_BCC] : []), ...]
// so with test_recipient set the ONLY recipient is the address below and CITY_BCC is
// dropped. A municipality cannot receive anything from this script.
//
// Called server-side because the function is origin-restricted to derm.unclogme.app and a
// browser call from anywhere else dies at the preflight. CORS is browser-enforced only.
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

const TEST_TO = 'fred@ayache.com';
const manifestId = Number(process.argv[2]);
const clientId = Number(process.argv[3]);
const target = process.argv[4] || 'city';
if (!manifestId || !clientId) { console.error('usage: node derm_email_smoke.js <manifest_id> <client_id> [city|client]'); process.exit(2); }

const payload = JSON.stringify({
  target,
  recipients: [{ manifest_id: manifestId, client_id: clientId }],
  test_recipient: TEST_TO,
});

const host = new URL(process.env.SUPABASE_URL).host;
const t0 = Date.now();
const req = https.request({
  hostname: host,
  path: '/functions/v1/send-derm-email',
  method: 'POST',
  headers: {
    Authorization: 'Bearer ' + process.env.SUPABASE_SERVICE_ROLE_KEY,
    apikey: process.env.SUPABASE_SERVICE_ROLE_KEY,
    'Content-Type': 'application/json',
    Origin: 'https://derm.unclogme.app',
    'Content-Length': Buffer.byteLength(payload),
  },
}, res => {
  let d = '';
  res.on('data', c => (d += c));
  res.on('end', () => {
    console.log(`HTTP ${res.statusCode} in ${Date.now() - t0}ms`);
    try { console.log(JSON.stringify(JSON.parse(d), null, 1).slice(0, 1800)); }
    catch (e) { console.log(d.slice(0, 800)); }
  });
});
req.on('error', e => { console.error('ERR', e.message); process.exit(1); });
req.write(payload);
req.end();
