// audit_photo_classifications_status.js
// Snapshot across Prod, Sandbox #1, Field Portal Sandbox to answer:
//   - Is public.photo_classifications canonical yet in Prod? (migration 14d applied?)
//   - Is it in Field Portal Sandbox?
//   - Where does the data physically live right now?
//   - Does customer.wo_photos exist + reference service_phase?

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const SBX1 = process.env.SANDBOX_SUPABASE_PROJECT_ID;
const FP   = process.env.FIELD_PORTAL_SUPABASE_PROJECT_ID;

function pg(sql, projectId) {
  return new Promise((res, rej) => {
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${projectId}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
    }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res({status: x.statusCode, body: b})); });
    req.on('error', rej); req.write(JSON.stringify({query: sql})); req.end();
  });
}
async function q(sql, project, label) {
  const r = await pg(sql, project);
  if (r.status >= 300) return { error: `${label}: PG ${r.status} ${r.body.slice(0, 200)}` };
  try { return JSON.parse(r.body); } catch { return { error: `${label}: parse fail ${r.body.slice(0,200)}` }; }
}

const projects = [
  { id: PROD, label: 'Prod',                ref: 'wbasvhvvismukaqdnouk' },
  { id: SBX1, label: 'Sandbox #1',          ref: 'ubtlwpcyntelgbykdatn' },
  { id: FP,   label: 'Field Portal Sandbox', ref: 'klgtrdwrasrlxbmfyvdh' },
];

(async () => {
  console.log('=== photo_classifications status across 3 projects ===\n');

  const rows = [];
  for (const p of projects) {
    const tableExists = await q(`
      SELECT
        (SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name='photo_classifications') AS canonical_exists,
        (SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name='app_photo_classifications') AS app_exists,
        (SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name='photos') AS photos_exists,
        (SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name='photo_links') AS photo_links_exists,
        (SELECT count(*) FROM information_schema.views  WHERE table_schema='customer' AND table_name='wo_photos') AS customer_wo_photos_exists
    `, p.id, p.label);

    if (tableExists.error) {
      rows.push({ project: p.label, error: tableExists.error });
      continue;
    }
    const t = tableExists[0];

    // counts (only if tables exist)
    const counts = await q(`
      SELECT
        ${t.canonical_exists ? '(SELECT count(*)::int FROM public.photo_classifications)' : 'NULL'} AS pc_rows,
        ${t.app_exists ? '(SELECT count(*)::int FROM public.app_photo_classifications)' : 'NULL'} AS apc_rows,
        ${t.photos_exists ? '(SELECT count(*)::int FROM public.photos)' : 'NULL'} AS photos_rows,
        ${t.photo_links_exists ? '(SELECT count(*)::int FROM public.photo_links)' : 'NULL'} AS pl_rows
    `, p.id, p.label);
    const c = counts.error ? {} : counts[0];

    rows.push({
      project: p.label,
      'public.photo_classifications': t.canonical_exists ? `EXISTS (${c.pc_rows ?? '?'} rows)` : 'missing',
      'public.app_photo_classifications': t.app_exists ? `EXISTS (${c.apc_rows ?? '?'} rows)` : 'missing',
      'public.photos': t.photos_exists ? `EXISTS (${c.photos_rows ?? '?'} rows)` : 'missing',
      'public.photo_links': t.photo_links_exists ? `EXISTS (${c.pl_rows ?? '?'} rows)` : 'missing',
      'customer.wo_photos view': t.customer_wo_photos_exists ? 'EXISTS' : 'missing',
    });
  }

  console.table(rows);

  // If Prod has photo_classifications, sanity-check its columns vs the migration 14d spec
  console.log('\n=== Prod public.photo_classifications columns (if it exists) ===');
  const cols = await q(`
    SELECT column_name, data_type, is_nullable, column_default
    FROM information_schema.columns
    WHERE table_schema='public' AND table_name='photo_classifications'
    ORDER BY ordinal_position
  `, PROD, 'Prod cols');
  if (cols.error) console.log('  ', cols.error);
  else if (cols.length === 0) console.log('  (table does not exist in Prod)');
  else console.table(cols);

  // Check customer.wo_photos definition (does it reference service_phase yet?)
  console.log('\n=== Prod customer.wo_photos view definition (service_phase mention?) ===');
  const viewDef = await q(`
    SELECT pg_get_viewdef('customer.wo_photos'::regclass, true) AS def
  `, PROD, 'Prod view');
  if (viewDef.error) console.log('  view missing or error:', viewDef.error);
  else if (viewDef[0]?.def) {
    const def = viewDef[0].def;
    console.log('  has service_phase reference:', def.includes('service_phase'));
    console.log('  has photo_classifications reference:', def.includes('photo_classifications'));
  }

  // Sandbox #1: confirm app_photo_classifications shape so we know exactly what to backfill
  console.log('\n=== Sandbox #1 app_photo_classifications columns ===');
  const sbxCols = await q(`
    SELECT column_name, data_type
    FROM information_schema.columns
    WHERE table_schema='public' AND table_name='app_photo_classifications'
    ORDER BY ordinal_position
  `, SBX1, 'Sbx#1 cols');
  if (sbxCols.error) console.log('  ', sbxCols.error);
  else console.table(sbxCols);

  console.log('\nDone.');
})();
