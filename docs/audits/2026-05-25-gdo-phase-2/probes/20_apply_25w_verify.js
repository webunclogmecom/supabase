// Apply 25w + verify all 4 merges.
const https = require('https');
const fs = require('fs');
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
      r.on('end', () => { try { res({ status: r.statusCode, body: JSON.parse(d) }); } catch (_) { res({ status: r.statusCode, body: d }); } });
    });
    req.on('error', rej);
    req.write(body);
    req.end();
  });
}

(async () => {
  const sql = fs.readFileSync(path.resolve(__dirname, '../../migrations/2026-05-25w_merge_duplicate_clients.sql'), 'utf8');
  console.log('=== Applying 2026-05-25w ===');
  const r = await pg(sql);
  console.log('HTTP', r.status, JSON.stringify(r.body).slice(0, 500));
  if (r.status !== 201 && r.status !== 200) process.exit(1);

  console.log('\n--- 1. Loser clients should all be INACTIVE ---');
  console.log(JSON.stringify((await pg(`SELECT id, client_code, name, status FROM public.clients WHERE id IN (336, 224, 41, 147) ORDER BY id;`)).body, null, 2));

  console.log('\n--- 2. No residual rows in any FK table for loser client_ids ---');
  console.log(JSON.stringify((await pg(`
    SELECT 'visits' AS t, COUNT(*)::int AS n FROM public.visits WHERE client_id IN (336,224,41,147)
    UNION ALL SELECT 'service_configs', COUNT(*)::int FROM public.service_configs WHERE client_id IN (336,224,41,147)
    UNION ALL SELECT 'gdos', COUNT(*)::int FROM public.gdos WHERE client_id IN (336,224,41,147)
    UNION ALL SELECT 'derm_manifests', COUNT(*)::int FROM public.derm_manifests WHERE client_id IN (336,224,41,147)
    UNION ALL SELECT 'properties', COUNT(*)::int FROM public.properties WHERE client_id IN (336,224,41,147)
    UNION ALL SELECT 'client_contacts', COUNT(*)::int FROM public.client_contacts WHERE client_id IN (336,224,41,147)
    UNION ALL SELECT 'notes', COUNT(*)::int FROM public.notes WHERE client_id IN (336,224,41,147)
    UNION ALL SELECT 'invoices', COUNT(*)::int FROM public.invoices WHERE client_id IN (336,224,41,147)
    UNION ALL SELECT 'quotes', COUNT(*)::int FROM public.quotes WHERE client_id IN (336,224,41,147)
    UNION ALL SELECT 'jobs', COUNT(*)::int FROM public.jobs WHERE client_id IN (336,224,41,147)
    UNION ALL SELECT 'jobber_oversized_attachments', COUNT(*)::int FROM public.jobber_oversized_attachments WHERE client_id IN (336,224,41,147)
    UNION ALL SELECT 'entity_source_links', COUNT(*)::int FROM public.entity_source_links WHERE entity_type='client' AND entity_id IN (336,224,41,147)
    ORDER BY t;
  `)).body, null, 2));

  console.log('\n--- 3. Survivor clients now have inherited data ---');
  console.log(JSON.stringify((await pg(`
    SELECT id, client_code, name, status,
      (SELECT COUNT(*)::int FROM public.visits WHERE client_id = c.id) AS visits,
      (SELECT COUNT(*)::int FROM public.gdos WHERE client_id = c.id AND status='ACTIVE') AS active_gdos,
      (SELECT COUNT(*)::int FROM public.derm_manifests WHERE client_id = c.id) AS manifests,
      (SELECT COUNT(*)::int FROM public.properties WHERE client_id = c.id) AS properties
    FROM public.clients c
    WHERE id IN (384, 371, 343, 5)
    ORDER BY id;
  `)).body, null, 2));

  console.log('\n--- 4. Remaining duplicate ACTIVE gdo_numbers ---');
  console.log(JSON.stringify((await pg(`SELECT gdo_number, COUNT(*)::int AS n, array_agg(id) AS ids FROM public.gdos WHERE status='ACTIVE' GROUP BY gdo_number HAVING COUNT(*) > 1;`)).body, null, 2));

  console.log('\n--- 5. ACTIVE/RECURRING clients count ---');
  console.log(JSON.stringify((await pg(`SELECT status, COUNT(*)::int AS n FROM public.clients GROUP BY status ORDER BY status;`)).body, null, 2));

  console.log('\n--- 6. Audit rows generated ---');
  console.log(JSON.stringify((await pg(`SELECT table_name, operation, COUNT(*)::int AS n FROM audit.logs WHERE changed_at > now() - interval '2 minutes' AND app_source='sql' GROUP BY table_name, operation ORDER BY table_name, operation;`)).body, null, 2));

  console.log('\n=== DONE ===');
})().catch(e => { console.error('FATAL', e); process.exit(1); });
