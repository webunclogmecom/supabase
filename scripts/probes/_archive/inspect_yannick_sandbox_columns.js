// Inspects Yannick's Sandbox schema additions: which columns exist beyond the
// Prod baseline on (visits, photo_links, properties) so we can mirror the
// exact names + types into app_* tables in Prod.

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const SANDBOX = process.env.SANDBOX_SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej);
    if (body) req.write(body); req.end();
  });
}
async function pg(project, sql) {
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${project}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' }
  }, JSON.stringify({ query: sql }));
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.slice(0,200)}`);
  return JSON.parse(r.body);
}

async function colsOf(project, table) {
  const r = await pg(project, `
    SELECT column_name, data_type, is_nullable, column_default
    FROM information_schema.columns
    WHERE table_schema='public' AND table_name='${table}'
    ORDER BY ordinal_position;
  `);
  return r.map(c => ({ n: c.column_name, t: c.data_type, nu: c.is_nullable, d: c.column_default }));
}

async function indexesOf(project, table) {
  const r = await pg(project, `
    SELECT indexname, indexdef FROM pg_indexes
    WHERE schemaname='public' AND tablename='${table}'
    ORDER BY indexname;
  `);
  return r;
}

(async () => {
  for (const tbl of ['visits', 'photo_links', 'properties', 'inspections']) {
    const [prod, sb] = await Promise.all([colsOf(PROD, tbl), colsOf(SANDBOX, tbl)]);
    const prodNames = new Set(prod.map(c => c.n));
    const onlyInSandbox = sb.filter(c => !prodNames.has(c.n));
    console.log(`\n=== ${tbl} ===`);
    console.log(`  prod cols: ${prod.length}   sandbox cols: ${sb.length}   sandbox-only: ${onlyInSandbox.length}`);
    for (const c of onlyInSandbox) {
      console.log(`    + ${c.n.padEnd(40)} ${c.t.padEnd(28)} ${c.nu === 'YES' ? 'NULL' : 'NOT NULL'}  default=${c.d || '∅'}`);
    }
    const [pIdx, sIdx] = await Promise.all([indexesOf(PROD, tbl), indexesOf(SANDBOX, tbl)]);
    const prodIdx = new Set(pIdx.map(i => i.indexname));
    const onlyInSbIdx = sIdx.filter(i => !prodIdx.has(i.indexname));
    if (onlyInSbIdx.length) {
      console.log(`  sandbox-only indexes:`);
      for (const i of onlyInSbIdx) console.log(`    + ${i.indexname}: ${i.indexdef}`);
    }
  }

  // Inspections: Lovable wants inspections_with_review for shift screen.
  // Confirm `external_employee_id` field name in inspections (the join key for shift form).
  const insp = await colsOf(PROD, 'inspections');
  console.log(`\n=== inspections employee key ===`);
  for (const c of insp) {
    if (/employee|staff|driver|technician|user/i.test(c.n)) console.log(`  ${c.n} ${c.t}`);
  }

  // Same for visits — what's the external_visit_id surface?
  const v = await colsOf(PROD, 'visits');
  console.log(`\n=== visits identity columns ===`);
  for (const c of v) {
    if (/^(id|external_)/i.test(c.n)) console.log(`  ${c.n} ${c.t}`);
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
