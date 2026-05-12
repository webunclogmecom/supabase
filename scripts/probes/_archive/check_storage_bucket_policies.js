// Compare Prod vs Sandbox storage bucket configs + RLS policies.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
const SB = process.env.SANDBOX_SUPABASE_PROJECT_ID;

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej); if (body) req.write(body); req.end();
  });
}
async function pg(project, sql) {
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${project}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' }
  }, JSON.stringify({ query: sql }));
  return JSON.parse(r.body);
}

(async () => {
  for (const [name, p] of [['PROD', PROD], ['SANDBOX', SB]]) {
    console.log(`\n=== ${name} (${p}) ===`);

    // Buckets
    const buckets = await pg(p, `SELECT id, name, public, avif_autodetection, file_size_limit FROM storage.buckets ORDER BY name;`);
    console.log(`  Storage buckets:`);
    for (const b of buckets) console.log(`    ${b.public ? '🟠 PUBLIC' : '🟢 private'}  ${b.name}  size_limit=${b.file_size_limit || '∞'}`);

    // Policies on storage.objects
    const pols = await pg(p, `
      SELECT polname, polcmd, polroles::regrole[]::text[] AS roles,
             pg_get_expr(polqual, polrelid) AS using_expr,
             pg_get_expr(polwithcheck, polrelid) AS check_expr
      FROM pg_policy
      WHERE polrelid = 'storage.objects'::regclass
      ORDER BY polname;
    `);
    console.log(`  storage.objects policies (${pols.length}):`);
    for (const pol of pols) {
      const cmd = ({r:'SELECT',a:'INSERT',w:'UPDATE',d:'DELETE','*':'ALL'})[pol.polcmd] || pol.polcmd;
      console.log(`    ${pol.polname.padEnd(45)}  ${cmd.padEnd(7)}  roles=${pol.roles.join(',')}  using=${(pol.using_expr || '').slice(0, 70)}`);
    }

    // RLS on key tables: visits, vehicles, photo_links, properties
    for (const tbl of ['visits', 'vehicles', 'photo_links', 'properties', 'app_visit_reviews', 'app_shift_reviews']) {
      const r = await pg(p, `
        SELECT
          (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.' || $1)::regclass) AS rls_enabled,
          (SELECT json_agg(row_to_json(t)) FROM (
            SELECT polname, polcmd::text, polroles::regrole[]::text[] AS roles,
              pg_get_expr(polqual, polrelid) AS using_expr,
              pg_get_expr(polwithcheck, polrelid) AS check_expr
            FROM pg_policy WHERE polrelid = ('public.' || $1)::regclass
          ) t) AS policies
      `.replace(/\$1/g, `'${tbl}'`));
      const row = Array.isArray(r) ? r[0] : null;
      if (!row) { console.log(`  ${tbl}: (no result)`); continue; }
      if (row.rls_enabled === null) { console.log(`  ${tbl}: (table doesn't exist)`); continue; }
      console.log(`  ${tbl}: RLS=${row.rls_enabled ? 'ON' : 'OFF'}`);
      const ps = row.policies || [];
      for (const pol of ps) {
        const cmd = ({r:'SELECT',a:'INSERT',w:'UPDATE',d:'DELETE','*':'ALL'})[pol.polcmd] || pol.polcmd;
        const u = (pol.using_expr || '').slice(0, 60);
        const c = (pol.check_expr || '').slice(0, 30);
        console.log(`    ${pol.polname.padEnd(45)}  ${cmd.padEnd(7)}  roles=${pol.roles.join(',')}  using=${u}  check=${c}`);
      }
    }
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
