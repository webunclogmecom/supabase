// apply_field_portal_migrations_to_prod.js
// One-shot: apply the 5 Field Portal migrations to Prod and backfill 103 photo_classifications from Sandbox #1.
// All migrations are idempotent (IF NOT EXISTS / CREATE OR REPLACE / DROP IF EXISTS).
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const fs = require('fs');
const path = require('path');
const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const SBX1 = process.env.SANDBOX_SUPABASE_PROJECT_ID;
const PAT  = process.env.SUPABASE_PAT;

function pg(sql, project) {
  return new Promise((res, rej) => {
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${project}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' }
    }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res({ s: x.statusCode, b })); });
    req.on('error', rej);
    req.write(JSON.stringify({ query: sql }));
    req.end();
  });
}

const FILES = [
  '2026-05-14_field_portal_canonical_additions.sql',
  '2026-05-14b_field_portal_normalize_lookups.sql',
  '2026-05-14c_customer_schema.sql',
  '2026-05-14d_photo_classifications.sql',
  '2026-05-14e_customer_wo_photos_service_phase.sql',
];

(async () => {
  // 1) Apply migrations in order
  for (const f of FILES) {
    const sql = fs.readFileSync(path.resolve(__dirname, '../../docs/migrations', f), 'utf8');
    console.log(`\n=== Applying ${f} to Prod ===`);
    const r = await pg(sql, PROD);
    if (r.s >= 300) {
      console.error('FAILED:', r.s, r.b.slice(0, 500));
      process.exit(2);
    }
    console.log('OK:', r.s);
  }

  // 2) Backfill photo_classifications from Sandbox #1 → Prod
  console.log('\n=== Backfilling photo_classifications: Sandbox #1 → Prod ===');
  const srcRes = await pg('SELECT external_photo_link_id, service_phase, classified_by_user_id, created_at FROM app_photo_classifications;', SBX1);
  const src = JSON.parse(srcRes.b);
  console.log(`Read ${src.length} from Sandbox #1`);

  // Filter to those whose photo_link_id exists in Prod
  const idList = src.map(r => r.external_photo_link_id).join(',');
  const validRes = await pg(`SELECT id FROM photo_links WHERE id IN (${idList});`, PROD);
  const validIds = new Set(JSON.parse(validRes.b).map(r => r.id));
  const eligible = src.filter(r => validIds.has(r.external_photo_link_id));
  console.log(`${eligible.length} target valid Prod photo_links`);

  if (eligible.length === 0) {
    console.log('Nothing to insert.');
  } else {
    const values = eligible.map(r => {
      const sp = r.service_phase.replace(/'/g, "''");
      const cb = r.classified_by_user_id ? `'${r.classified_by_user_id}'` : 'NULL';
      const ca = r.created_at ? `'${r.created_at}'` : 'now()';
      return `(${r.external_photo_link_id}, '${sp}', ${cb}, ${ca})`;
    }).join(',');
    const insSql = `INSERT INTO public.photo_classifications (photo_link_id, service_phase, classified_by_user_id, created_at) VALUES ${values} ON CONFLICT (photo_link_id) DO NOTHING;`;
    const r = await pg(insSql, PROD);
    if (r.s >= 300) { console.error('Backfill failed:', r.s, r.b.slice(0,400)); process.exit(2); }
    console.log('Insert OK:', r.s);
  }

  // 3) Verify
  console.log('\n=== Verify Prod state ===');
  const t = await pg(`
    SELECT
      (SELECT COUNT(*)::int FROM public.photo_classifications) AS pc_rows,
      (SELECT COUNT(*)::int FROM information_schema.views WHERE table_schema='customer' AND table_name='wo_photos') AS customer_view_exists,
      (SELECT COUNT(*)::int FROM information_schema.tables WHERE table_schema='public' AND table_name='photo_classifications') AS pc_table_exists,
      (SELECT COUNT(*)::int FROM information_schema.tables WHERE table_schema='public' AND table_name='disposal_facilities') AS df_table_exists,
      (SELECT COUNT(*)::int FROM information_schema.tables WHERE table_schema='public' AND table_name='client_groups') AS cg_table_exists,
      (SELECT COUNT(*)::int FROM information_schema.columns WHERE table_schema='public' AND table_name='visits' AND column_name='manhole_count') AS manhole_col_exists
  `, PROD);
  console.log(t.b);

  console.log('\n=== Verify customer.wo_photos for visit 1619 (092-TCE 2026-04-13) on PROD ===');
  const v = await pg(`SELECT variant, COUNT(*)::int AS n FROM customer.wo_photos WHERE work_order_id = customer.uuid_from_bigint(1619) GROUP BY variant ORDER BY n DESC;`, PROD);
  console.log(v.b);

  console.log('\nDone.');
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
