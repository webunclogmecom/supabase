import 'dotenv/config';
import { readFile } from 'node:fs/promises';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
const PROD_URL = process.env.SUPABASE_URL;

async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, { method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'}, body:JSON.stringify({query:sql})});
  const body = await r.text();
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${body.slice(0,400)}`);
  return JSON.parse(body);
}

const keys = await (await fetch(`https://api.supabase.com/v1/projects/${PROD}/api-keys`, { headers: { Authorization: `Bearer ${PAT}` } })).json();
const ANON = keys.find(k => k.name === 'anon')?.api_key;

const sql = await readFile('C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase/docs/migrations/2026-05-26_visits_source_add_visit_calendar.sql','utf8');
console.log('=== APPLY constraint extension ===');
console.log(await pg(sql));

console.log('\n=== Confirm new constraint ===');
console.log(await pg(`SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname='visits_source_chk';`));

console.log('\n=== Smoke INSERT with source=visit-calendar (should NOW succeed) ===');
const goodPayload = {
  client_id: 51,
  visit_date: '2027-01-15',
  service_type: 'GT',
  visit_status: 'scheduled',
  source: 'visit-calendar',
  title: 'SMOKE TEST — delete after verification',
};
let r = await fetch(`${PROD_URL}/rest/v1/visits`, {
  method:'POST',
  headers:{
    apikey:ANON, Authorization:`Bearer ${ANON}`,
    'Content-Type':'application/json',
    Prefer:'return=representation',
    'X-App-Source':'visit-calendar',
  },
  body:JSON.stringify(goodPayload),
});
const body = await r.text();
console.log(`  HTTP ${r.status}`);
console.log(`  body: ${body.slice(0,600)}`);

let createdId=null;
try { const parsed=JSON.parse(body); if (Array.isArray(parsed)&&parsed[0]?.id) createdId=parsed[0].id; } catch {}

console.log('\n=== audit.logs verification ===');
if (createdId) {
  console.log(await pg(`SELECT id, operation, app_source, jwt_claims->>'role' AS role FROM audit.logs WHERE table_name='visits' AND (new_row->>'id')::int=${createdId} ORDER BY id DESC LIMIT 2;`));
}

console.log('\n=== CLEAN UP smoke row ===');
if (createdId) {
  console.log(await pg(`DELETE FROM public.visits WHERE id=${createdId} RETURNING id, title;`));
}

console.log('\nDONE.');
