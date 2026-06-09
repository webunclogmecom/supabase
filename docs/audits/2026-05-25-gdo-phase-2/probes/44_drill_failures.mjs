import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, { method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'}, body:JSON.stringify({query:sql})});
  return JSON.parse(await r.text());
}

console.log('=== webhook_events_log columns ===');
console.log(await pg(`SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='webhook_events_log' ORDER BY ordinal_position;`));

console.log('\n=== properties.is_primary column default ===');
console.log(await pg(`SELECT column_name, column_default, is_nullable FROM information_schema.columns WHERE table_schema='public' AND table_name='properties' AND column_name='is_primary';`));

console.log('\n=== a sample failing payload (try common column names) ===');
const cols = await pg(`SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='webhook_events_log' ORDER BY ordinal_position;`);
const colList = cols.map(c => `"${c.column_name}"`).join(', ');
console.log(await pg(`
  SELECT ${colList}
  FROM public.webhook_events_log
  WHERE source_system='jobber' AND status='failed'
    AND created_at >= '2026-05-26T17:57:00Z'
  ORDER BY created_at DESC LIMIT 1;
`));
