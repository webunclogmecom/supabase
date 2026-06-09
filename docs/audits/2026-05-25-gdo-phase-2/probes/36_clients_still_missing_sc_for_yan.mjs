// 36_clients_still_missing_sc_for_yan.mjs
// After the AT INSERT backfill, list the clients that STILL have visits in
// May-Sep 2026 but no service_config — so Yan can fill in Airtable.
//
// Splits into two buckets:
//   A. Has AT link but AT row is empty for the frequency/price fields
//   B. No AT link at all (client created from Jobber, never linked to AT)

import 'dotenv/config';

const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;

async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql }),
  });
  const body = await r.text();
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${body.slice(0, 600)}`);
  return JSON.parse(body);
}

console.log('=== Clients still missing service_configs (Yan AT cleanup list) ===\n');

const missing = await pg(`
  WITH gap AS (
    SELECT DISTINCT v.client_id, v.service_type, c.name AS client_name, c.client_code
    FROM public.visits v
    JOIN public.clients c ON c.id = v.client_id
    WHERE v.visit_date BETWEEN '2026-05-01' AND '2026-09-30'
      AND v.service_type IN ('GT','CL','WD')
      AND NOT EXISTS (
        SELECT 1 FROM public.service_configs sc
        WHERE sc.client_id = v.client_id AND sc.service_type = v.service_type
      )
  )
  SELECT g.client_id, g.client_code, g.client_name, g.service_type,
         (SELECT source_id FROM public.entity_source_links
          WHERE entity_type='client' AND source_system='airtable'
            AND entity_id = g.client_id) AS at_id,
         (SELECT count(*) FROM public.visits
          WHERE client_id=g.client_id AND service_type=g.service_type
            AND visit_date BETWEEN '2026-05-01' AND '2026-09-30') AS upcoming_visits
  FROM gap g
  ORDER BY g.client_name, g.service_type;
`);

console.log(`Total: ${missing.length} (client, service_type) pairs still unbacked\n`);

const noAt = missing.filter(m => !m.at_id);
const withAt = missing.filter(m => m.at_id);

console.log(`\n--- BUCKET A: ${withAt.length} pairs WITH AT link but AT data missing ---`);
console.log('Action: Yan adds Frequency/Price/Size to Airtable Clients table for these:');
for (const m of withAt) {
  console.log(`  ${(m.client_name || '').padEnd(40)} ${(m.client_code || '—').padEnd(12)} ${m.service_type}  AT=${m.at_id}  upcoming=${m.upcoming_visits}`);
}

console.log(`\n--- BUCKET B: ${noAt.length} pairs WITH NO AT link (Jobber-only clients) ---`);
console.log('Action: Yan either creates the AT row + links via entity_source_links,');
console.log('  OR Fred adds service_configs directly via SQL based on Yan input:');
for (const m of noAt) {
  console.log(`  ${(m.client_name || '').padEnd(40)} ${(m.client_code || '—').padEnd(12)} ${m.service_type}  client_id=${m.client_id}  upcoming=${m.upcoming_visits}`);
}
