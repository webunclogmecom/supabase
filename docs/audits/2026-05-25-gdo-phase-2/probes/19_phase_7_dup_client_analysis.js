// Phase 7 analysis: count dependent rows per duplicate-client pair so we
// can pick a survivor for each merge.
//
// Pairs (from Phase 2 findings):
//   1. Kosh (150-KOS) vs Grove Kosher LLC (Harding Ave) (025-GRO)
//   2. Nu Real food - Coral gables (172-NU) vs Nu Real Food (045-NU)
//   3. Pura Vida Brickell 701 (175-PV) vs Pura Vida Brickell (050-PV)
//   4. Lettuce and Tomato (139-LTG) vs (Bakery) Lettuce and Tomato (144-LTG)
//
// Output: for each pair, ids + counts (visits, properties, gdos, manifests,
// service_configs) on each side. We pick the survivor = client with more
// total ACTIVE data; demote the other.

const https = require('https');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../../.env') });
const PAT = process.env.SUPABASE_PAT;

function pg(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com',
      path: '/v1/projects/wbasvhvvismukaqdnouk/database/query',
      method: 'POST',
      headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, r => {
      let d = '';
      r.on('data', c => (d += c));
      r.on('end', () => { try { res(JSON.parse(d)); } catch (_) { res(d); } });
    });
    req.on('error', rej);
    req.write(body);
    req.end();
  });
}

const PAIRS = [
  ['150-KOS', '025-GRO'],
  ['172-NU', '045-NU'],
  ['175-PV', '050-PV'],
  ['139-LTG', '144-LTG'],
];

(async () => {
  for (const [a, b] of PAIRS) {
    console.log(`\n=== ${a} vs ${b} ===`);
    const rows = await pg(`
      WITH targets AS (
        SELECT id, client_code, name, status
        FROM public.clients
        WHERE client_code IN ('${a}', '${b}')
      )
      SELECT
        t.id, t.client_code, t.name, t.status,
        (SELECT COUNT(*)::int FROM public.visits           WHERE client_id = t.id) AS visits,
        (SELECT COUNT(*)::int FROM public.visits           WHERE client_id = t.id AND visit_status='completed') AS completed_visits,
        (SELECT COUNT(*)::int FROM public.properties       WHERE client_id = t.id) AS properties,
        (SELECT COUNT(*)::int FROM public.gdos             WHERE client_id = t.id AND status='ACTIVE') AS active_gdos,
        (SELECT COUNT(*)::int FROM public.gdos             WHERE client_id = t.id) AS all_gdos,
        (SELECT COUNT(*)::int FROM public.service_configs  WHERE client_id = t.id) AS service_configs,
        (SELECT COUNT(*)::int FROM public.derm_manifests   WHERE client_id = t.id) AS derm_manifests,
        (SELECT COUNT(*)::int FROM public.entity_source_links WHERE entity_type='client' AND entity_id = t.id) AS source_links,
        (SELECT MAX(visit_date)::text FROM public.visits   WHERE client_id = t.id AND visit_status='completed') AS last_visit
      FROM targets t
      ORDER BY t.client_code;
    `);
    console.log(JSON.stringify(rows, null, 2));
  }

  // Also pull all FK references TO clients so we know what tables need rewiring on merge.
  console.log('\n=== FK references TO clients.id ===');
  console.log(JSON.stringify(await pg(`
    SELECT tc.table_schema, tc.table_name, kcu.column_name
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu ON kcu.constraint_name = tc.constraint_name
    JOIN information_schema.constraint_column_usage ccu ON ccu.constraint_name = tc.constraint_name
    WHERE tc.constraint_type = 'FOREIGN KEY'
      AND ccu.table_schema = 'public' AND ccu.table_name = 'clients' AND ccu.column_name = 'id'
    ORDER BY tc.table_schema, tc.table_name, kcu.column_name;
  `), null, 2));
})().catch(e => console.error('FATAL', e));
