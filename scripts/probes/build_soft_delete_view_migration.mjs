// Generates docs/migrations/2026-08-21_1200_properties_soft_delete_readers.sql
//
// 🛑 WHY A GENERATOR AND NOT A HAND-WRITTEN MIGRATION.
//    CREATE OR REPLACE takes the ENTIRE body, so anything not reproduced is silently deleted, and
//    the header still reads as if only one clause changed. Supabase/CLAUDE.md records what that cost
//    on 2026-08-06. So every body here is the LIVE pg_get_viewdef / pg_get_functiondef output, and
//    the only edit is one anchored replacement per object, asserted to match EXACTLY ONCE.
//
// Run: node scripts/probes/build_soft_delete_view_migration.mjs
import { readFileSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const env = Object.fromEntries(readFileSync(join(ROOT, '.env'), 'utf8').split(/\r?\n/)
  .filter(l => /^[A-Z_]+=/.test(l))
  .map(l => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '').trim()]));

async function sql(q) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_ID}/database/query`, {
    method: 'POST', headers: { Authorization: `Bearer ${env.SUPABASE_PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: q }) });
  const t = await r.text(); const j = JSON.parse(t);
  if (!Array.isArray(j)) throw new Error(`SQL: ${t.slice(0, 300)}`);
  return j;
}

// [object, anchor, replacement] — one anchored edit each, all asserted to match exactly once.
const VIEWS = [
  ['client.properties',
   '   FROM properties p;',
   '   FROM properties p\n  WHERE p.deleted_at IS NULL;'],

  ['ops.properties',
   '   FROM properties p\n     LEFT JOIN zones z ON z.id = p.zone_id;',
   '   FROM properties p\n     LEFT JOIN zones z ON z.id = p.zone_id\n  WHERE p.deleted_at IS NULL;'],

  // Two aggregates over the client\'s properties. Filtering removes a retired property\'s
  // CONTRIBUTION; the client row itself is untouched because both are LEFT JOIN LATERAL.
  ['client.clients',
   'WHERE p.client_id = c.id AND p.zone_id IS NOT NULL) dz ON true',
   'WHERE p.client_id = c.id AND p.zone_id IS NOT NULL AND p.deleted_at IS NULL) dz ON true'],
  ['client.clients',
   'WHERE p.client_id = c.id AND p.grease_trap_size_gallons IS NOT NULL) gt ON true',
   'WHERE p.client_id = c.id AND p.grease_trap_size_gallons IS NOT NULL AND p.deleted_at IS NULL) gt ON true'],

  // ON-clause, NOT a WHERE. The client row survives and the address goes NULL, which is the honest
  // answer for a client whose primary property no longer exists. A WHERE here would delete clients.
  ['customer.clients',
   'LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true',
   'LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true AND p.deleted_at IS NULL'],

  ['public.zones_with_usage',
   'WHERE properties.zone_id IS NOT NULL',
   'WHERE properties.zone_id IS NOT NULL AND properties.deleted_at IS NULL'],

  // The address is picked by ORDER BY p.id LIMIT 1, so a retired property that happens to sort
  // first would supply a dead address to the Stamp Studio client picker.
  ['derm.v_stamp_clients',
   'WHERE p.client_id = c.id\n          ORDER BY p.id',
   'WHERE p.client_id = c.id AND p.deleted_at IS NULL\n          ORDER BY p.id'],
];

const FUNCS = [
  ['client.global_search',
   '    from public.properties pr cross join want w\n   where w.g_properties\n',
   '    from public.properties pr cross join want w\n   where w.g_properties\n     and pr.deleted_at is null\n'],
];

let body = '';
const edited = new Map();

for (const [obj, anchor, repl] of VIEWS) {
  if (!edited.has(obj)) {
    const d = await sql(`select pg_get_viewdef('${obj}'::regclass, true) def`);
    edited.set(obj, d[0].def);
  }
  const cur = edited.get(obj);
  const n = cur.split(anchor).length - 1;
  if (n !== 1) throw new Error(`ANCHOR MATCHED ${n} TIMES in ${obj}: ${anchor.slice(0, 60)}`);
  edited.set(obj, cur.replace(anchor, repl));
  console.log(`  ok  ${obj.padEnd(26)} anchor matched exactly once`);
}

for (const [obj, def] of edited) {
  body += `\n-- ${'-'.repeat(94)}\n-- ${obj}\n-- ${'-'.repeat(94)}\nCREATE OR REPLACE VIEW ${obj} AS\n${def.trim().replace(/;$/, '')};\n`;
}

for (const [obj, anchor, repl] of FUNCS) {
  const [schema, name] = obj.split('.');
  const d = await sql(`select pg_get_functiondef(p.oid) def from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='${schema}' and p.proname='${name}'`);
  if (d.length !== 1) throw new Error(`${obj} has ${d.length} overloads, expected 1`);
  const cur = d[0].def;
  const n = cur.split(anchor).length - 1;
  if (n !== 1) throw new Error(`ANCHOR MATCHED ${n} TIMES in ${obj}`);
  console.log(`  ok  ${obj.padEnd(26)} anchor matched exactly once`);
  // pg_get_functiondef returns the body with NO trailing semicolon, so without this the
  // next statement in the migration runs straight into $function$ and the file will not parse.
  body += `\n-- ${'-'.repeat(94)}\n-- ${obj}\n-- ${'-'.repeat(94)}\n${cur.replace(anchor, repl).trimEnd()};\n`;
}

const rd = f => readFileSync(join(ROOT, 'scripts', 'probes', f), 'utf8');
const header = rd('soft_delete_readers_header.sql');
const pre    = rd('soft_delete_readers_pre.sql');
const verify = rd('soft_delete_readers_verify.sql');
const out = join(ROOT, 'docs', 'migrations', '2026-08-21_1200_properties_soft_delete_readers.sql');
writeFileSync(out, `${header}
begin;

${pre}
${body}
${verify}
commit;
`);
console.log(`\nwrote ${out}`);
