// 81_visit_4326_notes.mjs
// Visit 4326 has notes referencing it — investigate before deleting.
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

console.log('=== notes table columns ===');
console.log(await pg(`
  SELECT column_name, data_type
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name='notes'
  ORDER BY ordinal_position;
`));

console.log('\n=== Notes attached to visit 4326 ===');
console.log(await pg(`
  SELECT * FROM public.notes WHERE visit_id = 4326;
`));

console.log('\n=== Notes attached to visit 5138 ===');
console.log(await pg(`
  SELECT * FROM public.notes WHERE visit_id = 5138;
`));

console.log('\n=== Any other table referencing visits.id without CASCADE? ===');
console.log(await pg(`
  SELECT con.conname, cls.relname AS table_name,
         a.attname AS column_name, con.confdeltype AS on_delete
  FROM pg_constraint con
  JOIN pg_class cls ON cls.oid = con.conrelid
  JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = ANY(con.conkey)
  WHERE con.contype='f'
    AND con.confrelid = 'public.visits'::regclass
  ORDER BY cls.relname;
`));
