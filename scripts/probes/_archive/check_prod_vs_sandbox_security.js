// Compare Prod vs Sandbox Supabase security advisor findings.
// Sandbox shows 4 errors + 2 warnings (some "outdated" — stale results from
// before the recent app changes). Verify which apply to Prod.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
const SB = process.env.SANDBOX_SUPABASE_PROJECT_ID;

function http(opts) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej); req.setTimeout(60000, () => req.destroy(new Error('timeout')));
    req.end();
  });
}

async function advisors(project) {
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${project}/advisors/security`,
    method: 'GET',
    headers: { Authorization: `Bearer ${PAT}` }
  });
  if (r.status >= 300) throw new Error(`advisor ${r.status}: ${r.body.slice(0, 200)}`);
  return JSON.parse(r.body);
}

async function pg(project, sql) {
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${project}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' }
  });
  // Need to send body
}

(async () => {
  // 1. Supabase security advisor lints
  for (const [name, p] of [['PROD', PROD], ['SANDBOX', SB]]) {
    console.log(`\n=== ${name} (${p}) — Supabase security advisor ===`);
    try {
      const a = await advisors(p);
      const lints = a.lints || [];
      const errors = lints.filter(l => l.level === 'ERROR');
      const warns  = lints.filter(l => l.level === 'WARN');
      const infos  = lints.filter(l => l.level === 'INFO');
      console.log(`  ${errors.length} ERRORs, ${warns.length} WARNs, ${infos.length} INFOs`);
      for (const l of [...errors, ...warns]) {
        const desc = (l.description || '').slice(0, 100);
        const cat = l.categories?.join(',') || '';
        const meta = l.metadata ? `${l.metadata.schema || ''}.${l.metadata.name || ''}` : '';
        console.log(`  [${l.level}] ${l.title}: ${meta}  (${cat})`);
        if (desc) console.log(`           ${desc}`);
      }
    } catch (e) { console.log(`  ERR: ${e.message.slice(0, 200)}`); }
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
