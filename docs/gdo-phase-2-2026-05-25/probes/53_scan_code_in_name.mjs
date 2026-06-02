import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, { method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'}, body:JSON.stringify({query:sql})});
  return JSON.parse(await r.text());
}
console.log('=== Clients whose canonical name STARTS WITH their client_code or a prefix that looks like a code ===');
console.log(await pg(`
  SELECT id, client_code, name, status
  FROM public.clients
  WHERE client_code IS NOT NULL
    AND (
      name ILIKE client_code || '%'                     -- name starts with exact code
      OR name ~ '^\d{2,3}-?\s'                        -- name starts with 2-3 digit prefix + space/dash
      OR name ~ '^\d{2,3}-[A-Z]+\s'                   -- name starts with code-pattern
    )
  ORDER BY name
  LIMIT 30;
`));
