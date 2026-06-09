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

console.log('=== Find smoke test visits (source=visit-calendar from today) ===');
const found = await pg(`
  SELECT id, public_id, visit_date, service_type, visit_status, title, source,
         created_at, client_id
  FROM public.visits
  WHERE source = 'visit-calendar'
  ORDER BY created_at DESC
  LIMIT 5;
`);
console.log(found);

console.log('\n=== Verify audit.logs has the INSERT row ===');
if (found.length) {
  const ids = found.map(v => v.id).join(',');
  console.log(await pg(`
    SELECT id, operation, table_name, app_source, changed_at,
           jwt_claims->>'role' AS role,
           new_row->>'title' AS title
    FROM audit.logs
    WHERE table_name='visits'
      AND operation='INSERT'
      AND (new_row->>'id')::int IN (${ids})
    ORDER BY changed_at DESC;
  `));
}

console.log('\n=== Clean up: DELETE smoke test visits ===');
const deleted = await pg(`
  DELETE FROM public.visits
  WHERE source='visit-calendar'
  RETURNING id, title;
`);
console.log(`Deleted ${deleted.length} rows:`, deleted);

console.log('\n=== Final state — confirm no orphans ===');
console.log(await pg(`SELECT count(*)::int AS remaining_visit_calendar_rows FROM public.visits WHERE source='visit-calendar';`));
console.log(await pg(`SELECT count(*)::int AS prod_total_visits FROM public.visits;`));
