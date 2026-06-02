// Probe derm_manifest data + AT cross-reference for visit 1619 (092-TCE 4/13)
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const PROD = process.env.SUPABASE_PROJECT_ID;
const FP = process.env.FIELD_PORTAL_SUPABASE_PROJECT_ID;

function pg(sql, project) {
  return new Promise((res, rej) => {
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${project}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
    }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res(b)); });
    req.on('error', rej);
    req.write(JSON.stringify({query: sql}));
    req.end();
  });
}

(async () => {
  console.log('=== derm_manifests columns (Prod) ===');
  console.log(await pg(`
    SELECT column_name, data_type
    FROM information_schema.columns
    WHERE table_schema='public' AND table_name='derm_manifests'
    ORDER BY ordinal_position;
  `, PROD));

  console.log('\n=== derm_manifest data for visit 1619 (092-TCE 4/13) ===');
  console.log(await pg(`
    SELECT dm.*
    FROM derm_manifests dm
    JOIN manifest_visits mv ON mv.manifest_id = dm.id
    WHERE mv.visit_id = 1619;
  `, PROD));

  console.log('\n=== customer.work_orders columns (Field Portal — what the UI consumes) ===');
  console.log(await pg(`
    SELECT column_name, data_type
    FROM information_schema.columns
    WHERE table_schema='customer' AND table_name='work_orders'
    ORDER BY ordinal_position;
  `, FP));

  console.log('\n=== customer.work_orders row for visit 1619 (Field Portal) ===');
  console.log(await pg(`SELECT * FROM customer.work_orders WHERE id = customer.uuid_from_bigint(1619);`, FP));

  // Look at the customer.work_orders view definition to see how compliance docs are exposed
  console.log('\n=== customer.work_orders view def (Field Portal) ===');
  console.log(await pg(`SELECT pg_get_viewdef('customer.work_orders'::regclass, true) AS def;`, FP));

  console.log('\n=== entity_source_links for the visit-1619 derm_manifest (to find AT record id) ===');
  console.log(await pg(`
    SELECT esl.entity_type, esl.entity_id, esl.source, esl.source_id
    FROM entity_source_links esl
    WHERE esl.entity_type = 'derm_manifest'
      AND esl.entity_id IN (SELECT manifest_id FROM manifest_visits WHERE visit_id = 1619);
  `, PROD));
})();
