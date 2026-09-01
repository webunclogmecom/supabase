// Smoke-test the PostgREST API after a db_schema change, WITHOUT printing any key.
// Hits one harmless read per exposed schema and reports status codes only.
import { readFileSync } from 'node:fs';

const env = Object.fromEntries(
  readFileSync('.env', 'utf8').split(/\r?\n/).filter(l => /^[A-Z_]+=/.test(l))
    .map(l => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '').trim()])
);
const REF = env.SUPABASE_PROJECT_ID;
const KEY = env.SUPABASE_SERVICE_ROLE_KEY;
if (!KEY) throw new Error('SUPABASE_SERVICE_ROLE_KEY missing from .env');
const BASE = `https://${REF}.supabase.co/rest/v1`;

// one cheap read per schema. Accept-Profile selects the schema for the request.
const CHECKS = [
  { schema: 'public',   path: 'employees?select=id&limit=1' },
  { schema: 'client',   path: 'employees?select=id&limit=1' },
  { schema: 'ops',      path: 'properties?select=id&limit=1' },
  { schema: 'derm',     path: 'v_stamp_sheets?select=dump_folder&limit=1' },
  { schema: 'customer', path: 'clients?select=id&limit=1' },
];

// 🛑 THIS TEST ASKS "DOES POSTGREST STILL RESOLVE THIS SCHEMA", NOT "CAN service_role READ IT".
// A 403 is a PASS: it means the schema resolved and the request reached the object, and was then
// refused by the GRANT system. Measured 2026-08-31: service_role holds no SELECT on 14 derm views
// (they are granted to `authenticated`, which is what the Stamp Studio reads as), so a 403 there is
// pre-existing and correct. Only a schema that fails to resolve is a real failure.
let bad = 0;
for (const c of CHECKS) {
  const r = await fetch(`${BASE}/${c.path}`, {
    headers: { apikey: KEY, Authorization: `Bearer ${KEY}`, 'Accept-Profile': c.schema },
  });
  const body = r.status === 200 ? '' : await r.text();
  const unresolved = /must be one of|Accept-Profile/i.test(body);
  const ok = !unresolved && (r.status === 200 || r.status === 403);
  if (!ok) bad++;
  const note = r.status === 403 ? ' (schema resolves; service_role not granted, expected)' : '';
  console.log(`${ok ? 'OK ' : 'BAD'}  ${c.schema.padEnd(9)} HTTP ${r.status}${note}${ok ? '' : '  ' + body.slice(0, 160)}`);
}

// hr is exposed but empty: a request for a non-existent table should 404, NOT fail to resolve the
// schema. That is the difference between "exposed and empty" and "not exposed".
const r = await fetch(`${BASE}/does_not_exist?select=*&limit=1`, {
  headers: { apikey: KEY, Authorization: `Bearer ${KEY}`, 'Accept-Profile': 'hr' },
});
const t = await r.text();
const resolved = !/schema.*must be one of|Accept-Profile/i.test(t);
console.log(`${resolved ? 'OK ' : 'BAD'}  hr        HTTP ${r.status} (empty schema; ${resolved ? 'schema resolves' : 'SCHEMA NOT EXPOSED'})`);
if (!resolved) bad++;

console.log(bad === 0 ? '\nAll exposed schemas serving.' : `\n${bad} check(s) failed.`);
process.exit(bad === 0 ? 0 : 1);
