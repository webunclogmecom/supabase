import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, { method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'}, body:JSON.stringify({query:sql})});
  return JSON.parse(await r.text());
}
console.log('=== Clients whose canonical name STARTS WITH a NNN- or NNN-XX prefix (likely code-in-name pollution) ===');
console.log(await pg(`
  SELECT id, client_code, name, status
  FROM public.clients
  WHERE status IN ('ACTIVE','RECURRING')
    AND name ~ '^[0-9]{3}-'
  ORDER BY name
  LIMIT 30;
`));
