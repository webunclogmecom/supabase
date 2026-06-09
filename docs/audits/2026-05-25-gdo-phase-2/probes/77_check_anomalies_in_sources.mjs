// 77_check_anomalies_in_sources.mjs
// Verify each anomaly visit against upstream sources (Jobber + Airtable):
//   - Visits 5081, 5082: Casa Neos May 12 (likely duplicate)
//   - Visits 5125, 5127: El Chaman May 20 (possible duplicate)
//   - Visit  4326:       Mila May 13 (missing Jobber link)
//   - Visit  5138:       17 Restaurant May 27 (test residue, cancelled)
//
// Use raw.jobber_pull_visits as canonical Jobber-side state.
// AT: look for legacy visits table if it exists.

import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'},
    body:JSON.stringify({query:sql}),
  });
  const body = await r.text();
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${body.slice(0, 600)}`);
  return JSON.parse(body);
}
const banner = (s) => console.log(`\n${'='.repeat(70)}\n${s}\n${'='.repeat(70)}`);

const TARGET_IDS = [5081, 5082, 5125, 5127, 4326, 5138];

banner('1. entity_source_links for the 6 candidate visits');
console.log(await pg(`
  SELECT esl.entity_id AS visit_id, esl.source_system, esl.source_id,
         esl.source_name, esl.synced_at, esl.match_method
  FROM public.entity_source_links esl
  WHERE esl.entity_type='visit'
    AND esl.entity_id = ANY(ARRAY[${TARGET_IDS.join(',')}])
  ORDER BY esl.entity_id, esl.source_system;
`));

banner('2. Discover raw / staging tables for Jobber and AT visits');
console.log(await pg(`
  SELECT table_schema, table_name
  FROM information_schema.tables
  WHERE (table_name ILIKE '%visit%' AND (table_schema='raw' OR table_schema='staging'))
     OR (table_schema='raw' AND table_name ILIKE '%jobber%')
     OR (table_schema='raw' AND table_name ILIKE '%airtable%')
  ORDER BY table_schema, table_name;
`));
