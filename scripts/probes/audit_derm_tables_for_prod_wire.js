// audit_derm_tables_for_prod_wire.js
// One-shot audit before wiring DERM Tracker to Prod canonical.
// Read-only. Reports findings; doesn't mutate anything.

const https = require('https');
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });

const PAT = process.env.SUPABASE_PAT;
const ref = process.env.SUPABASE_URL.match(/https?:\/\/([^.]+)\./)[1];

function pg(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com', path: '/v1/projects/' + ref + '/database/query',
      method: 'POST',
      headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, r => { let d = ''; r.on('data', c => d += c); r.on('end', () => { if (r.statusCode >= 300) return rej(new Error('SQL ' + r.statusCode + ': ' + d.slice(0,400))); res(JSON.parse(d)); }); });
    req.on('error', rej); req.write(body); req.end();
  });
}

function H(title) { console.log('\n=== ' + title + ' ==='); }
function J(label, obj) { console.log(label + ':', JSON.stringify(obj, null, 2)); }

(async () => {
  console.log('# DERM Prod Wire — Audit ' + new Date().toISOString() + '\n');

  // ----- 1. derm_manifests health -----
  H('1. derm_manifests — health');
  J('counts', (await pg(`
    SELECT COUNT(*) AS total_rows,
      COUNT(*) FILTER (WHERE client_id IS NULL) AS null_client_id,
      COUNT(*) FILTER (WHERE white_manifest_number IS NULL) AS null_white_num,
      COUNT(*) FILTER (WHERE service_date IS NULL) AS null_service_date,
      COUNT(*) FILTER (WHERE derm_manifest_url IS NOT NULL) AS has_manifest_url,
      COUNT(*) FILTER (WHERE derm_address_url IS NOT NULL) AS has_address_url,
      COUNT(*) FILTER (WHERE disposal_facility_id IS NULL) AS null_disposal_facility
    FROM public.derm_manifests`))[0]);
  J('orphan client_id', (await pg(`SELECT COUNT(*) AS n FROM public.derm_manifests dm LEFT JOIN public.clients c ON c.id = dm.client_id WHERE dm.client_id IS NOT NULL AND c.id IS NULL`))[0]);
  J('orphan disposal_facility_id', (await pg(`SELECT COUNT(*) AS n FROM public.derm_manifests dm LEFT JOIN public.disposal_facilities df ON df.id = dm.disposal_facility_id WHERE dm.disposal_facility_id IS NOT NULL AND df.id IS NULL`))[0]);
  J('rls', (await pg(`SELECT relrowsecurity FROM pg_class WHERE oid = 'public.derm_manifests'::regclass`))[0]);
  J('policies', await pg(`SELECT polname, polcmd, polroles::regrole[]::text[] AS roles, pg_get_expr(polqual, polrelid) AS using_expr, pg_get_expr(polwithcheck, polrelid) AS check_expr FROM pg_policy WHERE polrelid = 'public.derm_manifests'::regclass`));
  J('grants', await pg(`SELECT grantee, privilege_type FROM information_schema.table_privileges WHERE table_schema = 'public' AND table_name = 'derm_manifests' ORDER BY grantee, privilege_type`));
  J('triggers', await pg(`SELECT tgname FROM pg_trigger WHERE tgrelid = 'public.derm_manifests'::regclass AND NOT tgisinternal`));
  J('indexes', await pg(`SELECT indexname FROM pg_indexes WHERE tablename = 'derm_manifests' AND schemaname = 'public'`));

  // ----- 2. manifest_visits health -----
  H('2. manifest_visits — health');
  J('counts', (await pg(`SELECT COUNT(*) AS total_rows FROM public.manifest_visits`))[0]);
  J('linkage_gap',
    (await pg(`SELECT COUNT(*) AS total_manifests,
                COUNT(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM public.manifest_visits mv WHERE mv.manifest_id = dm.id)) AS unlinked_manifests
              FROM public.derm_manifests dm`))[0]);
  J('orphan manifest_id', (await pg(`SELECT COUNT(*) AS n FROM public.manifest_visits mv LEFT JOIN public.derm_manifests dm ON dm.id = mv.manifest_id WHERE dm.id IS NULL`))[0]);
  J('orphan visit_id', (await pg(`SELECT COUNT(*) AS n FROM public.manifest_visits mv LEFT JOIN public.visits v ON v.id = mv.visit_id WHERE v.id IS NULL`))[0]);
  J('rls', (await pg(`SELECT relrowsecurity FROM pg_class WHERE oid = 'public.manifest_visits'::regclass`))[0]);
  J('policies', await pg(`SELECT polname, polcmd, polroles::regrole[]::text[] AS roles, pg_get_expr(polqual, polrelid) AS using_expr, pg_get_expr(polwithcheck, polrelid) AS check_expr FROM pg_policy WHERE polrelid = 'public.manifest_visits'::regclass`));
  J('grants', await pg(`SELECT grantee, privilege_type FROM information_schema.table_privileges WHERE table_schema = 'public' AND table_name = 'manifest_visits' ORDER BY grantee, privilege_type`));
  J('triggers', await pg(`SELECT tgname FROM pg_trigger WHERE tgrelid = 'public.manifest_visits'::regclass AND NOT tgisinternal`));
  J('pk', await pg(`SELECT conname, pg_get_constraintdef(oid) AS def FROM pg_constraint WHERE conrelid = 'public.manifest_visits'::regclass AND contype = 'p'`));
  J('indexes', await pg(`SELECT indexname FROM pg_indexes WHERE tablename = 'manifest_visits' AND schemaname = 'public'`));

  // ----- 3. disposal_facilities health -----
  H('3. disposal_facilities — health');
  J('counts', (await pg(`SELECT COUNT(*) AS total_rows,
      COUNT(*) FILTER (WHERE name IS NOT NULL) AS has_name,
      COUNT(*) FILTER (WHERE facility_type IS NOT NULL) AS has_type,
      COUNT(*) FILTER (WHERE latitude IS NOT NULL) AS has_lat,
      COUNT(*) FILTER (WHERE longitude IS NOT NULL) AS has_lon
    FROM public.disposal_facilities`))[0]);
  J('all_rows', await pg(`SELECT id, name, facility_type, latitude, longitude FROM public.disposal_facilities ORDER BY id`));
  J('rls', (await pg(`SELECT relrowsecurity FROM pg_class WHERE oid = 'public.disposal_facilities'::regclass`))[0]);
  J('policies', await pg(`SELECT polname, polcmd, polroles::regrole[]::text[] AS roles FROM pg_policy WHERE polrelid = 'public.disposal_facilities'::regclass`));
  J('grants', await pg(`SELECT grantee, privilege_type FROM information_schema.table_privileges WHERE table_schema = 'public' AND table_name = 'disposal_facilities' ORDER BY grantee, privilege_type`));
  J('triggers', await pg(`SELECT tgname FROM pg_trigger WHERE tgrelid = 'public.disposal_facilities'::regclass AND NOT tgisinternal`));
  J('status_col_exists', await pg(`SELECT column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'disposal_facilities' AND column_name = 'status'`));
  J('address_columns_exist', await pg(`SELECT column_name, data_type FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'disposal_facilities' AND column_name IN ('address', 'city', 'state', 'zip') ORDER BY column_name`));

  // ----- 4. properties — column verification -----
  H('4. properties — columns used by derm views');
  J('columns', await pg(`SELECT column_name, data_type FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'properties' AND column_name IN ('address', 'address_street', 'county', 'is_billing') ORDER BY column_name`));
  J('multi_property_clients', (await pg(`SELECT COUNT(*) FILTER (WHERE n > 1) AS multi, COUNT(*) AS total FROM (SELECT client_id, COUNT(*) AS n FROM public.properties WHERE client_id IS NOT NULL GROUP BY client_id) sub`))[0]);
  J('sample_dual_property_clients', await pg(`SELECT client_id, COUNT(*) FILTER (WHERE is_billing = true) AS billing_n, COUNT(*) FILTER (WHERE is_billing = false) AS service_n FROM public.properties GROUP BY client_id HAVING COUNT(*) FILTER (WHERE is_billing = true) > 0 AND COUNT(*) FILTER (WHERE is_billing = false) > 0 LIMIT 5`));

  // ----- 5. Storage bucket -----
  H('5. Storage bucket — GT - Visits Images');
  J('bucket', await pg(`SELECT id, name, public FROM storage.buckets WHERE name = 'GT - Visits Images'`));
  J('storage_policies_on_objects', await pg(`SELECT polname, polcmd, polroles::regrole[]::text[] AS roles, pg_get_expr(polqual, polrelid) AS using_expr, pg_get_expr(polwithcheck, polrelid) AS check_expr FROM pg_policy WHERE polrelid = 'storage.objects'::regclass`));

  // ----- 6. derm schema sanity -----
  H('6. derm schema — does it exist already?');
  J('schema_check', await pg(`SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'derm'`));

  // ----- 7. derm_manifests columns we'll alias in the view -----
  H('7. derm_manifests — full column list (for view aliasing accuracy)');
  J('columns', await pg(`SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'derm_manifests' ORDER BY ordinal_position`));

  console.log('\n--- AUDIT DONE ---');
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
