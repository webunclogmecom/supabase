import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, { method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'}, body:JSON.stringify({query:sql})});
  return JSON.parse(await r.text());
}

const targets = [
  { id: 316, code: '174-17', current_name: '17 Restaurant and Sushi Bar' },
  { id: 360, code: '205-SAS', current_name: '205- SAS Signor SASSI' },
];

for (const t of targets) {
  console.log(`\n${'='.repeat(70)}\n${t.code}  →  current canonical name: "${t.current_name}"`);
  console.log('='.repeat(70));

  console.log('\n--- Cross-source names (entity_source_links) ---');
  console.log(await pg(`
    SELECT source_system, source_name, source_id, match_method, synced_at
    FROM public.entity_source_links
    WHERE entity_type='client' AND entity_id=${t.id}
    ORDER BY source_system;
  `));

  console.log('\n--- Properties + addresses ---');
  console.log(await pg(`
    SELECT id, name, address, city, county, zone, is_primary, is_billing
    FROM public.properties
    WHERE client_id=${t.id}
    ORDER BY is_primary DESC NULLS LAST;
  `));

  console.log('\n--- GDOs (DERM permits) ---');
  console.log(await pg(`
    SELECT id, gdo_number, location_label, permit_expiration, status, permit_document_path
    FROM public.gdos
    WHERE client_id=${t.id};
  `));

  console.log('\n--- DERM manifests (most recent — disposal-facility names hint at real generator) ---');
  console.log(await pg(`
    SELECT dm.id, dm.service_date, dm.white_manifest_number, dm.derm_manifest_url, dm.derm_address_url, df.name AS disposal_facility
    FROM public.derm_manifests dm
    LEFT JOIN public.disposal_facilities df ON df.id=dm.disposal_facility_id
    WHERE dm.client_id=${t.id}
    ORDER BY dm.service_date DESC NULLS LAST
    LIMIT 3;
  `));
}
