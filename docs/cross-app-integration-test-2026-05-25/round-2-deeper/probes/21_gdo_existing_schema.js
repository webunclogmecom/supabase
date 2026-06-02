// Best-practices check: what's already in the schema for GDOs?
const https = require('https');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../../../.env') });
const PAT = process.env.SUPABASE_PAT;
const PROD = 'wbasvhvvismukaqdnouk';
function pg(sql) { return new Promise((res, rej) => { const body = JSON.stringify({ query: sql }); const req = https.request({hostname:'api.supabase.com',path:`/v1/projects/${PROD}/database/query`,method:'POST',headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json','Content-Length':Buffer.byteLength(body)}},r=>{let d='';r.on('data',c=>d+=c);r.on('end',()=>{try{res(JSON.parse(d))}catch(_){res(d)}})});req.on('error',rej);req.write(body);req.end();}); }
(async () => {
  console.log('=== 1. Is there a public.gdos TABLE (vs derm.gdos view)? ===');
  console.log(await pg(`
    SELECT table_schema, table_name, table_type
    FROM information_schema.tables
    WHERE table_name ILIKE '%gdo%' OR table_name ILIKE '%permit%'
    ORDER BY table_schema, table_name;
  `));

  console.log('\n=== 2. public.gdos columns ===');
  console.log(await pg(`
    SELECT column_name, data_type, is_nullable, column_default
    FROM information_schema.columns
    WHERE table_schema='public' AND table_name='gdos'
    ORDER BY ordinal_position;
  `));

  console.log('\n=== 3. public.gdos row count + sample ===');
  console.log(await pg(`SELECT COUNT(*)::int AS n FROM public.gdos;`));
  console.log(await pg(`SELECT * FROM public.gdos ORDER BY id LIMIT 3;`));

  console.log('\n=== 4. Does properties already FK to gdos? ===');
  console.log(await pg(`
    SELECT
      tc.constraint_name, tc.table_name, kcu.column_name,
      ccu.table_name AS foreign_table, ccu.column_name AS foreign_column
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu
      ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
    JOIN information_schema.constraint_column_usage ccu
      ON ccu.constraint_name = tc.constraint_name AND ccu.table_schema = tc.table_schema
    WHERE tc.constraint_type='FOREIGN KEY'
      AND (tc.table_name='properties' OR ccu.table_name='gdos')
      AND tc.table_schema='public';
  `));

  console.log('\n=== 5. derm.gdos view def (to see what columns it surfaces) ===');
  console.log((await pg(`SELECT pg_get_viewdef('derm.gdos'::regclass, true) AS sql;`))[0]?.sql);

  console.log('\n=== 6. Is gdos audited? ===');
  console.log(await pg(`
    SELECT trigger_name, event_manipulation, action_statement
    FROM information_schema.triggers
    WHERE event_object_schema='public' AND event_object_table='gdos';
  `));

  console.log('\n=== 7. service_configs columns related to permits ===');
  console.log(await pg(`
    SELECT column_name, data_type
    FROM information_schema.columns
    WHERE table_schema='public' AND table_name='service_configs'
      AND (column_name ILIKE '%permit%' OR column_name ILIKE '%gdo%' OR column_name ILIKE '%frequency%')
    ORDER BY ordinal_position;
  `));

  console.log('\n=== 8. ADRs already addressing GDO design? ===');
  // Just see what ADRs exist via file listing — done outside this probe
})().catch(e => console.error('FATAL', e));
