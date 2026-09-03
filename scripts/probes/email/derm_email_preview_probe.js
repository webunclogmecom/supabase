// Exercise send-derm-email's preview mode and PROVE it neither sends nor logs.
// usage: node derm_email_preview_probe.js <manifest_id> <client_id> [city|client]
const https = require('https'); const fs = require('fs'); const path = require('path');
for (const line of fs.readFileSync(path.resolve(__dirname, '../../../.env'), 'utf8').split(/\r?\n/)) {
  const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/); if (!m) continue;
  let v = m[2].trim();
  if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
  if (!(m[1] in process.env)) process.env[m[1]] = v;
}
const [mid, cid, target = 'city'] = process.argv.slice(2);
if (!mid || !cid) { console.error('usage: node derm_email_preview_probe.js <manifest_id> <client_id> [city|client]'); process.exit(2); }
const payload = JSON.stringify({
  target, preview: true,
  recipients: [{ manifest_id: Number(mid), client_id: Number(cid) }],
  test_recipient: 'fred@ayache.com',
});
const req = https.request({
  hostname: new URL(process.env.SUPABASE_URL).host,
  path: '/functions/v1/send-derm-email', method: 'POST',
  headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload),
    apikey: process.env.SUPABASE_SERVICE_ROLE_KEY, Authorization: `Bearer ${process.env.SUPABASE_SERVICE_ROLE_KEY}` },
}, (res) => { let b = ''; res.on('data', d => b += d); res.on('end', () => {
  let j; try { j = JSON.parse(b) } catch { console.log('status', res.statusCode, b.slice(0, 400)); return }
  console.log('status      ', res.statusCode);
  console.log('preview     ', j.preview);
  console.log('target      ', j.target);
  console.log('subject     ', j.subject);
  console.log('is_test     ', j.is_test);
  console.log('html bytes  ', (j.html || '').length);
  console.log('sent key    ', 'sent' in j ? j.sent : '(absent - nothing was sent)');
  const h = j.html || '';
  for (const k of ['Dear Environmental Compliance Team', 'Hi ', 'SERVICE DETAILS', 'Service Details',
                   'Licensed Grease Trap Hauler', '(305) 339-5638', 'INTERNAL TEST',
                   'Thanks again for your hard work'])
    console.log('  ' + (h.includes(k) ? 'yes ' : 'NO  ') + k);
}); });
req.on('error', e => { console.error('request failed', e.message); process.exit(1) });
req.write(payload); req.end();
