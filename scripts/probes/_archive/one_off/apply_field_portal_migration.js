// Apply docs/migrations/2026-05-14_field_portal_canonical_additions.sql to
// Field Portal Sandbox (klgtrdwrasrlxbmfyvdh) via the Management API.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const fs = require('fs');
const path = require('path');
const https = require('https');

const PROJECT = process.env.FIELD_PORTAL_SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
if (!PROJECT || !PAT) { console.error('Missing FIELD_PORTAL_SUPABASE_PROJECT_ID or SUPABASE_PAT'); process.exit(1); }

const SQL_PATH = path.resolve(__dirname, '../../docs/migrations/2026-05-14_field_portal_canonical_additions.sql');
const sql = fs.readFileSync(SQL_PATH, 'utf8');

function http(opts, body) { return new Promise((res, rej) => {
  const req = https.request(opts, r => { const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()})); });
  req.on('error',rej); if(body) req.write(body); req.end();
});}
async function pg(query) {
  const r = await http({hostname:'api.supabase.com',path:'/v1/projects/'+PROJECT+'/database/query',method:'POST',headers:{Authorization:'Bearer '+PAT,'Content-Type':'application/json'}}, JSON.stringify({query}));
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.slice(0,800)}`);
  return r.body ? JSON.parse(r.body) : [];
}

(async () => {
  console.log(`Applying migration to ${PROJECT}...`);
  console.log(`  SQL: ${SQL_PATH}`);
  console.log(`  size: ${sql.length} chars\n`);

  await pg(sql);
  console.log('✓ Migration applied.\n');

  // Verify
  console.log('Verifying ...');
  const v = await pg(`
    SELECT 'columns added' AS what,
      (SELECT COUNT(*)::int FROM information_schema.columns
        WHERE table_schema='public' AND (
          (table_name='clients' AND column_name='group_name')
       OR (table_name='properties' AND column_name IN ('default_disposal_facility','access_notes'))
       OR (table_name='service_configs' AND column_name IN ('material_type','permit_document_path'))
       OR (table_name='vehicles' AND column_name='decal_number')
       OR (table_name='visits' AND column_name IN ('manhole_count','manhole_breakdown','ticket_number','trap_condition_notes'))
       OR (table_name='derm_manifests' AND column_name IN ('wwtp_receipt_number','wwtp_receipt_document_path','wwtp_ticket_number','disposal_facility'))
        )) AS n,
      '14 expected' AS expected
    UNION ALL
    SELECT 'new table',
      (SELECT COUNT(*)::int FROM information_schema.tables WHERE table_schema='public' AND table_name='visit_recommendations'),
      '1 expected'
    UNION ALL
    SELECT 'views',
      (SELECT COUNT(*)::int FROM information_schema.views WHERE table_schema='public' AND table_name IN ('vw_client_work_orders','vw_client_permits')),
      '2 expected'
    UNION ALL
    SELECT 'vw_client_work_orders rows',
      (SELECT COUNT(*)::int FROM public.vw_client_work_orders),
      'should be > 0'
    UNION ALL
    SELECT 'vw_client_permits rows',
      (SELECT COUNT(*)::int FROM public.vw_client_permits),
      'should be > 0'
    UNION ALL
    SELECT 'public_read RLS policies',
      (SELECT COUNT(*)::int FROM pg_policies WHERE schemaname='public' AND policyname='portal_public_read'),
      '14 expected';
  `);
  console.table(v);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
