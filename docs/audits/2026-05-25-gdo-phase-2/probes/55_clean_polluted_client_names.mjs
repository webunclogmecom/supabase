// 55_clean_polluted_client_names.mjs
// Update canonical client names to strip the code-in-name pollution.
//   id 223: "000- Kaffe"            → "Kaffe"
//   id 360: "205- SAS Signor SASSI" → "Signor SASSI"
//
// NOTE: cron_jobber.js polls Jobber every 2 minutes and re-upserts client
// names from source. Until Fred renames in Jobber itself, these updates
// will revert on the next poll. After Fred renames in Jobber, the clean
// names stick.

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
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${body.slice(0, 500)}`);
  return JSON.parse(body);
}

console.log('=== Before ===');
console.log(await pg(`
  SELECT id, client_code, name FROM public.clients WHERE id IN (223, 360);
`));

console.log('\n=== UPDATE ===');
console.log(await pg(`
  UPDATE public.clients
  SET name = CASE id
    WHEN 223 THEN 'Kaffe'
    WHEN 360 THEN 'Signor SASSI'
  END
  WHERE id IN (223, 360)
  RETURNING id, client_code, name;
`));

console.log('\n=== audit.logs entries for the UPDATEs ===');
console.log(await pg(`
  SELECT id, operation, app_source, changed_at,
         old_row->>'name' AS old_name,
         new_row->>'name' AS new_name
  FROM audit.logs
  WHERE table_name='clients'
    AND (new_row->>'id')::int IN (223, 360)
    AND operation='UPDATE'
  ORDER BY changed_at DESC
  LIMIT 2;
`));

console.log('\nNote: cron_jobber.js will revert these in ~2 min if Jobber names are not cleaned.');
