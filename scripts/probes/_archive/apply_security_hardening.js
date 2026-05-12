// Apply security_hardening_2026_05_05.sql to both Prod and Sandbox.
// Order: Prod first, then Sandbox.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const fs = require('fs');
const path = require('path');
const https = require('https');

const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
const SB = process.env.SANDBOX_SUPABASE_PROJECT_ID;
const SQL = fs.readFileSync(path.resolve(__dirname, '../migrations/security_hardening_2026_05_05.sql'), 'utf8');

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej); req.setTimeout(60000, () => req.destroy(new Error('timeout')));
    if (body) req.write(body); req.end();
  });
}

async function applyTo(projectId, label) {
  console.log(`\n--- Applying to ${label} (${projectId}) ---`);
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${projectId}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' }
  }, JSON.stringify({ query: SQL }));
  if (r.status >= 300) {
    console.error(`  FAIL ${r.status}: ${r.body.slice(0, 600)}`);
    return false;
  }
  console.log(`  OK ${r.status}: ${r.body.slice(0, 200) || '(empty result, expected for DDL)'}`);
  return true;
}

async function advisorCheck(projectId, label) {
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${projectId}/advisors/security`,
    method: 'GET',
    headers: { Authorization: `Bearer ${PAT}` }
  });
  const a = JSON.parse(r.body);
  const lints = a.lints || [];
  const errors = lints.filter(l => l.level === 'ERROR').length;
  const warns  = lints.filter(l => l.level === 'WARN').length;
  console.log(`  ${label} advisor (post-apply): ${errors} ERRORs, ${warns} WARNs`);
  if (errors + warns > 0) {
    for (const l of lints.filter(l => l.level === 'ERROR' || l.level === 'WARN')) {
      console.log(`    [${l.level}] ${l.title}: ${l.metadata?.name || ''}`);
    }
  }
}

(async () => {
  const okProd = await applyTo(PROD, 'PROD');
  if (!okProd) { console.error('Prod failed — aborting before Sandbox.'); process.exit(2); }
  const okSb = await applyTo(SB, 'SANDBOX');
  if (!okSb) { console.error('Sandbox failed.'); process.exit(2); }

  console.log('\n--- Post-apply advisor check ---');
  await advisorCheck(PROD, 'PROD');
  await advisorCheck(SB, 'SANDBOX');
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
