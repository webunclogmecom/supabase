// edge_deployed_body.js - assert against the DEPLOYED edge function body, not the git tree.
// Usage: node scripts/probes/edge_deployed_body.js <slug> "<needle>" ["<needle>" ...]
//
// Why this exists (2026-08-25): "a commit is not a deploy". After fixing the base64 OOM in
// send-visit-photos-email it would have been easy to verify the repo and call it done. This
// reads what Supabase is actually running.
//
// ⚠ ALWAYS PASS A CONTROL NEEDLE you know is present (e.g. api.resend.com/emails). A needle
// reported absent by a broken reader looks identical to a needle that is genuinely absent,
// and that is the false all-clear this estate keeps paying for.
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

const slug = process.argv[2];
const needles = process.argv.slice(3);
if (!slug || !needles.length) { console.error('usage: node edge_deployed_body.js <slug> "<needle>" ...'); process.exit(2); }

function get(p) {
  return new Promise((resolve, reject) => {
    https.get({ hostname: 'api.supabase.com', path: p,
      headers: { Authorization: 'Bearer ' + process.env.SUPABASE_PAT } }, res => {
      let d = ''; res.on('data', c => (d += c));
      res.on('end', () => resolve({ status: res.statusCode, body: d }));
    }).on('error', reject);
  });
}

(async () => {
  const ref = process.env.SUPABASE_PROJECT_ID;
  const meta = await get(`/v1/projects/${ref}/functions/${slug}`);
  let version = '?', updated = '?';
  try { const j = JSON.parse(meta.body); version = j.version; updated = new Date(j.updated_at).toISOString(); } catch (e) {}
  const r = await get(`/v1/projects/${ref}/functions/${slug}/body`);
  if (r.status !== 200) { console.error(`HTTP ${r.status} fetching body: ${r.body.slice(0, 200)}`); process.exit(1); }
  console.log(`${slug}  version=${version}  updated=${updated}  bodyBytes=${r.body.length}`);
  let bad = 0;
  for (const n of needles) {
    const neg = n.startsWith('!');
    const needle = neg ? n.slice(1) : n;
    const present = r.body.includes(needle);
    const ok = neg ? !present : present;
    if (!ok) bad++;
    console.log(`  ${ok ? 'OK  ' : 'FAIL'}  ${neg ? 'ABSENT' : 'PRESENT'}: ${JSON.stringify(needle).slice(0, 80)}`);
  }
  process.exit(bad ? 1 : 0);
})();
