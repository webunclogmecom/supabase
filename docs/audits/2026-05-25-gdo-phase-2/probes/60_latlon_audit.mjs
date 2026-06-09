// 60_latlon_audit.mjs
// Check how many May 2026 visits have null lat/lon — those would still need address-fallback for Maps URL.
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

console.log('=== May 2026 lat/lon coverage in calendar view ===');
console.log(await pg(`
  SELECT
    COUNT(*)::int AS total,
    COUNT(*) FILTER (WHERE latitude IS NOT NULL AND longitude IS NOT NULL)::int AS has_latlon,
    COUNT(*) FILTER (WHERE latitude IS NULL OR longitude IS NULL)::int AS missing_latlon,
    COUNT(*) FILTER (WHERE address IS NULL OR address = '')::int AS missing_address
  FROM ops.v_calendar_visit
  WHERE visit_date >= '2026-05-01' AND visit_date < '2026-06-01';
`));

console.log('\n=== Sample of visits missing lat/lon ===');
console.log(await pg(`
  SELECT id, visit_date, client_name, address, city, latitude, longitude
  FROM ops.v_calendar_visit
  WHERE visit_date >= '2026-05-01' AND visit_date < '2026-06-01'
    AND (latitude IS NULL OR longitude IS NULL)
  ORDER BY visit_date
  LIMIT 10;
`));
