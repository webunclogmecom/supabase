// 123_audit_zones_state.mjs
// Read-only audit of "zone" usage across the DB before designing public.zones.
import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;

async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'},
    body:JSON.stringify({query:sql}),
  });
  const body = await r.text();
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${body.slice(0, 800)}`);
  return JSON.parse(body);
}

console.log('=== 1. Columns named "zone" anywhere ===');
console.log(await pg(`
  SELECT table_schema, table_name, column_name, data_type
  FROM information_schema.columns
  WHERE column_name ILIKE '%zone%'
  ORDER BY table_schema, table_name, column_name;
`));

console.log('\n=== 2. Distinct zone values on public.properties (per-property) ===');
console.log(await pg(`
  SELECT zone, COUNT(*)::int AS n_properties
  FROM public.properties
  GROUP BY zone
  ORDER BY n_properties DESC NULLS LAST;
`));

console.log('\n=== 3. Distinct zone values on ops.v_calendar_visit (per-visit, last 60d) ===');
console.log(await pg(`
  SELECT zone, COUNT(*)::int AS n_visits
  FROM ops.v_calendar_visit
  WHERE visit_date >= CURRENT_DATE - INTERVAL '60 days'
  GROUP BY zone
  ORDER BY n_visits DESC NULLS LAST;
`));

console.log('\n=== 4. Does ops.v_calendar_visit exist + does it surface zone? ===');
console.log(await pg(`
  SELECT column_name FROM information_schema.columns
  WHERE table_schema='ops' AND table_name='v_calendar_visit'
  ORDER BY ordinal_position;
`));

console.log('\n=== 5. Are there already any color-related columns or tables? ===');
console.log(await pg(`
  SELECT table_schema, table_name, column_name
  FROM information_schema.columns
  WHERE column_name ILIKE '%color%' OR column_name ILIKE '%hex%'
  ORDER BY table_schema, table_name;
`));

console.log('\n=== 6. Existing reference tables pattern (look for status/lookup tables) ===');
console.log(await pg(`
  SELECT table_name FROM information_schema.tables
  WHERE table_schema='public' AND (table_name ILIKE '%lookup%' OR table_name ILIKE '%ref%' OR table_name = 'zones')
  ORDER BY table_name;
`));
