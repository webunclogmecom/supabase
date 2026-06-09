// 26_sandbox_real_tables.mjs
// Use information_schema (already exposed by Supabase) to list what
// actually exists in sandbox public.* — bypasses the service_role grant gap
// because information_schema is readable by all roles.

import 'dotenv/config';

const SBX = {
  url: process.env.FIELD_PORTAL_SUPABASE_URL,
  key: process.env.FIELD_PORTAL_SUPABASE_SERVICE_ROLE_KEY,
};

// PostgREST exposes information_schema as a virtual schema. Try directly:
async function probe(path) {
  const r = await fetch(`${SBX.url}/rest/v1/${path}`, {
    headers: { apikey: SBX.key, Authorization: `Bearer ${SBX.key}`, 'Accept-Profile': 'information_schema' },
  });
  return { status: r.status, body: r.status < 400 ? await r.json() : await r.text() };
}

// Try via information_schema accept-profile
let r = await probe('tables?table_schema=eq.public&select=table_name&order=table_name.asc');
console.log('information_schema.tables (public):', r.status);
if (Array.isArray(r.body)) {
  console.log(`  ${r.body.length} tables:`);
  for (const t of r.body) console.log('    ', t.table_name);
} else {
  console.log('  body:', String(r.body).slice(0, 300));
}

console.log();
// Try schemas list
r = await probe('schemata?select=schema_name&order=schema_name.asc');
console.log('information_schema.schemata:', r.status);
if (Array.isArray(r.body)) {
  console.log(`  ${r.body.length} schemas:`);
  for (const s of r.body) console.log('    ', s.schema_name);
} else {
  console.log('  body:', String(r.body).slice(0, 300));
}
