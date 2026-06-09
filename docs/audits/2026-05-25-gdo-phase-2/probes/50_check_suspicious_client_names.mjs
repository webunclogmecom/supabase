// 50_check_suspicious_client_names.mjs
// Cross-check 2 clients whose names look like they have their client_code
// embedded:
//   - "17 Restaurant and Sushi Bar" (code 174-17)
//   - "205- SAS Signor SASSI"       (code 205-SAS)
//
// Pull from: clients + properties + gdos + entity_source_links to compare
// names across canonical fields + GDO permit + Jobber + AT.

import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;

async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method:'POST',
    headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'},
    body:JSON.stringify({query:sql}),
  });
  const body = await r.text();
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${body.slice(0, 500)}`);
  return JSON.parse(body);
}

const codes = ['174-17', '205-SAS'];

for (const code of codes) {
  console.log(`\n============================================================`);
  console.log(`Investigating client_code = ${code}`);
  console.log(`============================================================`);

  console.log('\n--- public.clients ---');
  console.log(await pg(`
    SELECT id, client_code, name, status, notes
    FROM public.clients
    WHERE client_code = '${code}';
  `));

  const clientIdRow = await pg(`SELECT id FROM public.clients WHERE client_code='${code}';`);
  if (!clientIdRow.length) { console.log('  (client not found)'); continue; }
  const clientId = clientIdRow[0].id;

  console.log('\n--- public.properties (this client) ---');
  console.log(await pg(`
    SELECT id, name, address, city, county, zone, is_primary, is_billing
    FROM public.properties
    WHERE client_id = ${clientId};
  `));

  console.log('\n--- public.gdos (this client) ---');
  console.log(await pg(`
    SELECT id, gdo_number, location_label, permit_expiration, status,
           max_frequency_days, permit_document_path
    FROM public.gdos
    WHERE client_id = ${clientId};
  `));

  console.log('\n--- entity_source_links (cross-system IDs) ---');
  console.log(await pg(`
    SELECT entity_type, source_system, source_id, source_name, match_method, synced_at
    FROM public.entity_source_links
    WHERE entity_type='client' AND entity_id = ${clientId}
    UNION ALL
    SELECT entity_type, source_system, source_id, source_name, match_method, synced_at
    FROM public.entity_source_links
    WHERE entity_type='property' AND entity_id IN (SELECT id FROM public.properties WHERE client_id=${clientId})
    ORDER BY 1, 2;
  `));

  console.log('\n--- public.derm_manifests (recent) ---');
  console.log(await pg(`
    SELECT id, white_manifest_number, dump_date, hauler_name, generator_name
    FROM public.derm_manifests
    WHERE client_id = ${clientId}
    ORDER BY dump_date DESC NULLS LAST
    LIMIT 3;
  `));
}
