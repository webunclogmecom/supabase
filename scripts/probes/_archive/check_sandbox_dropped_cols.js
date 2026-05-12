// After sandbox refresh, find all columns/views the Lovable app might still
// be querying that no longer exist. Compare expected (Lovable example queries)
// vs actual (Sandbox schema).
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const r = (project, sql) => new Promise((res, rej) => {
  const req = https.request({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${project}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
  }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res(JSON.parse(b))); });
  req.on('error', rej); req.write(JSON.stringify({query: sql})); req.end();
});

const SB = process.env.SANDBOX_SUPABASE_PROJECT_ID;
const PROD = process.env.SUPABASE_PROJECT_ID;

(async () => {
  // 1. Are key views present in both?
  console.log('=== Views in Prod vs Sandbox ===');
  for (const proj of [PROD, SB]) {
    const v = await r(proj, `SELECT viewname FROM pg_views WHERE schemaname='public' ORDER BY viewname`);
    const label = proj === PROD ? 'PROD' : 'SANDBOX';
    console.log(`  ${label}: ${v.map(x => x.viewname).join(', ') || '(none)'}`);
  }

  // 2. Recently dropped columns Lovable might still query
  console.log('\n=== Recently dropped Prod canonical columns (2026-05-04) ===');
  const dropped = [
    ['visits', 'truck', 'use vehicles.name JOIN or visits_with_status view'],
    ['derm_manifests', 'manifest_images', 'use photo_links entity_type=derm_manifest role=manifest'],
    ['derm_manifests', 'address_images', 'use photo_links entity_type=derm_manifest role=address']
  ];
  for (const [tbl, col, fix] of dropped) {
    const inProd = await r(PROD, `SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='${tbl}' AND column_name='${col}' LIMIT 1`);
    const inSb = await r(SB, `SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='${tbl}' AND column_name='${col}' LIMIT 1`);
    console.log(`  ${tbl}.${col}: prod=${inProd.length ? 'YES' : 'NO'} sandbox=${inSb.length ? 'YES' : 'NO'}  →  ${fix}`);
  }

  // 3. Schema diff between Sandbox and Prod (Sandbox-only / Prod-only columns)
  console.log('\n=== Schema diff between Sandbox and Prod ===');
  for (const tbl of ['visits', 'derm_manifests', 'photo_links', 'properties', 'photos', 'vehicles']) {
    const p = await r(PROD, `SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='${tbl}' ORDER BY ordinal_position`);
    const s = await r(SB, `SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='${tbl}' ORDER BY ordinal_position`);
    const pSet = new Set(p.map(x => x.column_name));
    const sSet = new Set(s.map(x => x.column_name));
    const sandboxOnly = [...sSet].filter(x => !pSet.has(x));
    const prodOnly = [...pSet].filter(x => !sSet.has(x));
    if (sandboxOnly.length || prodOnly.length) {
      console.log(`  ${tbl}: sandbox-only=[${sandboxOnly.join(',')}]  prod-only=[${prodOnly.join(',')}]`);
    } else {
      console.log(`  ${tbl}: ✓ in sync`);
    }
  }

  // 4. Sandbox refresh flow: did it propagate the drops? (Yannick visit cols expected gone too)
  console.log('\n=== Yannick review/bonus columns on Sandbox visits ===');
  const ycols = await r(SB, `SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='visits' AND (column_name LIKE 'review_%' OR column_name LIKE 'bonus_%' OR column_name = 'quality_flag_note' OR column_name = 'reviewed_at' OR column_name = 'reviewed_by')`);
  console.log(`  Yannick cols still on Sandbox visits: ${ycols.map(x=>x.column_name).join(', ') || '(none)'}`);
})().catch(e => { console.error(e.message); process.exit(2); });
