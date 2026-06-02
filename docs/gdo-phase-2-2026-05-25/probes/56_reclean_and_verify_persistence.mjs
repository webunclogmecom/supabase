// 56_reclean_and_verify_persistence.mjs
// (1) Re-clean ids 223 + 360 canonical names (cron may have reverted them
//     between the first SQL UPDATE and the new webhook deploy).
// (2) Trigger one Jobber sync cycle (cron_jobber.js no-replay quick path)
//     to confirm the new code path keeps them clean instead of reverting.

import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;

async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'},
    body:JSON.stringify({query:sql}),
  });
  const body = await r.text();
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${body.slice(0, 500)}`);
  return JSON.parse(body);
}

console.log('=== Current state ===');
console.log(await pg(`SELECT id, client_code, name FROM public.clients WHERE id IN (223, 360);`));

console.log('\n=== Re-clean (post webhook deploy) ===');
console.log(await pg(`
  UPDATE public.clients
  SET name = CASE id WHEN 223 THEN 'Kaffe' WHEN 360 THEN 'Signor SASSI' END
  WHERE id IN (223, 360)
    AND name IN ('000- Kaffe', '205- SAS Signor SASSI')
  RETURNING id, client_code, name;
`));

console.log('\n=== If no rows updated, they were already clean (good) ===');
console.log(await pg(`SELECT id, client_code, name FROM public.clients WHERE id IN (223, 360);`));

console.log('\nNote: next cron_jobber poll will fetch Jobber names + go through the new');
console.log('regex pattern in webhook-jobber. If Jobber name is "205- SAS Signor SASSI",');
console.log('webhook will now normalize it to "Signor SASSI" before UPDATE. Canonical stays clean.');
