// Audit current Prod state for Odoo bidirectional sync planning.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const { execSync } = require('child_process');

const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej); if (body) req.write(body); req.end();
  });
}
async function pg(sql) {
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${PROD}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' }
  }, JSON.stringify({ query: sql }));
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.slice(0, 200)}`);
  return JSON.parse(r.body);
}

(async () => {
  // 1. Odoo-domain tables — row counts + RLS status
  console.log('=== 1. Schema snapshot (Odoo-domain) ===');
  const tables = ['clients','client_contacts','properties','jobs','visits','visit_assignments',
                  'invoices','line_items','quotes','employees','vehicles',
                  'inspections','derm_manifests','manifest_visits',
                  'notes','photos','photo_links','vehicle_telemetry_readings',
                  'service_configs','entity_source_links'];
  const tlist = tables.map(t => `'${t}'`).join(',');
  const counts = await pg(`
    SELECT c.relname AS table_name,
           c.reltuples::bigint AS approx_rows,
           c.relrowsecurity AS rls_enabled,
           (SELECT COUNT(*) FROM pg_policy WHERE polrelid = c.oid) AS policy_count
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname='public' AND c.relkind='r' AND c.relname IN (${tlist})
    ORDER BY c.relname;
  `);
  // Real counts (exact) — only for the ones we care about most
  const exact = await pg(`
    SELECT 'clients' AS t, (SELECT COUNT(*) FROM clients) AS n UNION ALL
    SELECT 'client_contacts', (SELECT COUNT(*) FROM client_contacts) UNION ALL
    SELECT 'properties', (SELECT COUNT(*) FROM properties) UNION ALL
    SELECT 'jobs', (SELECT COUNT(*) FROM jobs) UNION ALL
    SELECT 'visits', (SELECT COUNT(*) FROM visits) UNION ALL
    SELECT 'visit_assignments', (SELECT COUNT(*) FROM visit_assignments) UNION ALL
    SELECT 'invoices', (SELECT COUNT(*) FROM invoices) UNION ALL
    SELECT 'line_items', (SELECT COUNT(*) FROM line_items) UNION ALL
    SELECT 'quotes', (SELECT COUNT(*) FROM quotes) UNION ALL
    SELECT 'employees', (SELECT COUNT(*) FROM employees) UNION ALL
    SELECT 'vehicles', (SELECT COUNT(*) FROM vehicles) UNION ALL
    SELECT 'inspections', (SELECT COUNT(*) FROM inspections) UNION ALL
    SELECT 'derm_manifests', (SELECT COUNT(*) FROM derm_manifests) UNION ALL
    SELECT 'manifest_visits', (SELECT COUNT(*) FROM manifest_visits) UNION ALL
    SELECT 'notes', (SELECT COUNT(*) FROM notes) UNION ALL
    SELECT 'photos', (SELECT COUNT(*) FROM photos) UNION ALL
    SELECT 'photo_links', (SELECT COUNT(*) FROM photo_links) UNION ALL
    SELECT 'vehicle_telemetry_readings', (SELECT COUNT(*) FROM vehicle_telemetry_readings) UNION ALL
    SELECT 'service_configs', (SELECT COUNT(*) FROM service_configs) UNION ALL
    SELECT 'entity_source_links', (SELECT COUNT(*) FROM entity_source_links);
  `);
  const rmap = Object.fromEntries(exact.map(r => [r.t, r.n]));
  console.log('  table                       | rows  | RLS | policies');
  console.log('  ----------------------------|-------|-----|----------');
  for (const t of counts) {
    console.log(`  ${t.table_name.padEnd(28)}| ${String(rmap[t.table_name] || 0).padStart(5)} |  ${t.rls_enabled ? '✅' : '❌'} | ${t.policy_count}`);
  }

  // 2. RPC / functions — what's exposed via PostgREST?
  console.log('\n=== 2. Custom RPC / functions exposed via PostgREST ===');
  const fns = await pg(`
    SELECT n.nspname AS schema, p.proname AS func, pg_get_function_arguments(p.oid) AS args
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname IN ('public') AND p.prokind='f'
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid=p.oid AND d.deptype='e')
    ORDER BY p.proname;
  `);
  console.log(`  ${fns.length} public functions:`);
  for (const f of fns) console.log(`    ${f.schema}.${f.func}(${f.args || ''})`);

  // 3. Edge functions
  console.log('\n=== 3. Edge functions ===');
  const ef = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${PROD}/functions`,
    method: 'GET',
    headers: { Authorization: `Bearer ${PAT}` }
  });
  const fnList = JSON.parse(ef.body);
  for (const f of fnList) {
    const upd = f.updated_at ? new Date(f.updated_at).toISOString().slice(0,10) : '?';
    console.log(`    ${(f.slug || f.name || '?').padEnd(30)} status=${f.status || '?'}  updated=${upd}`);
  }

  // 4. Outbound webhooks (pg_net, hooks)
  console.log('\n=== 4. Outbound webhooks (DB triggers calling external APIs) ===');
  const webhooks = await pg(`
    SELECT t.tgname AS trigger_name, c.relname AS table_name,
           pg_get_triggerdef(t.oid) AS def
    FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND NOT t.tgisinternal
      AND (pg_get_triggerdef(t.oid) ILIKE '%http%' OR pg_get_triggerdef(t.oid) ILIKE '%webhook%' OR pg_get_triggerdef(t.oid) ILIKE '%pg_net%')
    ORDER BY c.relname;
  `).catch(() => []);
  console.log(`  ${webhooks.length} outbound-webhook-style triggers (HTTP/pg_net/webhook):`);
  for (const w of webhooks) console.log(`    ${w.trigger_name} on ${w.table_name}`);

  // 5. Sensitive PII / regulated data candidates
  console.log('\n=== 5. Sensitive columns (PII, payment, DERM-restricted) ===');
  const sens = await pg(`
    SELECT table_name, column_name, data_type
    FROM information_schema.columns
    WHERE table_schema='public'
      AND (column_name ILIKE '%email%' OR column_name ILIKE '%phone%' OR column_name ILIKE '%ssn%'
        OR column_name ILIKE '%bank%' OR column_name ILIKE '%card%' OR column_name ILIKE '%payment%'
        OR column_name ILIKE '%license%' OR column_name ILIKE '%vin%' OR column_name ILIKE '%token%'
        OR column_name ILIKE '%pay_rate%' OR column_name ILIKE '%salary%' OR column_name ILIKE '%bonus%'
        OR column_name ILIKE '%password%' OR column_name ILIKE '%secret%')
    ORDER BY table_name, column_name;
  `);
  for (const s of sens) console.log(`    ${s.table_name}.${s.column_name} (${s.data_type})`);

})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
