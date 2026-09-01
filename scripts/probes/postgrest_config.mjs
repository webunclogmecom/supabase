// Read (and optionally update) the project's PostgREST config via the Management API.
//
// 🛑 db_schema is a COMMA-SEPARATED LIST that every app depends on. This script NEVER replaces it
// blind: --add <schema> reads the current value, appends only if absent, and prints before/after.
// Overwriting it with a single schema would take every app in the estate offline at once.
//
// Usage:
//   node scripts/probes/postgrest_config.mjs                 # read only
//   node scripts/probes/postgrest_config.mjs --add hr        # append one schema
import { readFileSync } from 'node:fs';

const env = Object.fromEntries(
  readFileSync('.env', 'utf8').split(/\r?\n/).filter(l => /^[A-Z_]+=/.test(l))
    .map(l => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '').trim()])
);
const REF = env.SUPABASE_PROJECT_ID;
const H = { Authorization: `Bearer ${env.SUPABASE_PAT}`, 'Content-Type': 'application/json' };
const URL_ = `https://api.supabase.com/v1/projects/${REF}/postgrest`;

const get = async () => {
  const r = await fetch(URL_, { headers: H });
  if (!r.ok) throw new Error(`GET ${r.status}: ${(await r.text()).slice(0, 300)}`);
  return r.json();
};

const before = await get();
console.log('CURRENT CONFIG');
console.log('  db_schema            :', JSON.stringify(before.db_schema));
console.log('  db_extra_search_path :', JSON.stringify(before.db_extra_search_path));
console.log('  max_rows             :', before.max_rows);

const addIdx = process.argv.indexOf('--add');
if (addIdx === -1) { console.log('\n(read-only run; pass --add <schema> to append)'); process.exit(0); }

const schema = process.argv[addIdx + 1];
if (!schema || !/^[a-z_][a-z0-9_]*$/.test(schema)) throw new Error(`bad schema name: ${schema}`);

const list = String(before.db_schema).split(',').map(s => s.trim()).filter(Boolean);
if (list.includes(schema)) {
  console.log(`\n"${schema}" is ALREADY exposed. Nothing to do.`);
  process.exit(0);
}
const next = [...list, schema].join(', ');

// the control: we must be adding exactly one entry and keeping every existing one
const nextList = next.split(',').map(s => s.trim());
if (nextList.length !== list.length + 1) throw new Error('refusing: entry count is not +1');
for (const s of list) if (!nextList.includes(s)) throw new Error(`refusing: would drop "${s}"`);

console.log(`\nAPPENDING "${schema}"`);
console.log('  before:', JSON.stringify(before.db_schema));
console.log('  after :', JSON.stringify(next));

const r = await fetch(URL_, { method: 'PATCH', headers: H, body: JSON.stringify({ db_schema: next }) });
const body = await r.text();
console.log('PATCH', r.status);
if (!r.ok) { console.log(body.slice(0, 500)); process.exit(1); }

const after = await get();
console.log('\nVERIFIED db_schema now:', JSON.stringify(after.db_schema));
const afterList = String(after.db_schema).split(',').map(s => s.trim());
if (!afterList.includes(schema)) { console.log('FAILED: schema not present after write'); process.exit(1); }
for (const s of list) if (!afterList.includes(s)) { console.log(`FAILED: lost "${s}"`); process.exit(1); }
console.log('OK: every previously exposed schema survived, and', schema, 'was added.');
