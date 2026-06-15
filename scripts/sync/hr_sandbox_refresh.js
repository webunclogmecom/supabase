// ============================================================================
// hr_sandbox_refresh.js
// ============================================================================
// Keep Yannick's HR Sandbox (klgtrdwrasrlxbmfyvdh) stocked with FRESH Prod data
// WITHOUT touching its (legacy April-clone) schema. Schema-preserving by design:
//   - Only ever writes COLUMNS THAT EXIST IN BOTH Prod and HR (intersection) →
//     Prod schema drift (new columns/tables) is silently skipped, never applied.
//   - Reference tables (employees/vehicles/clients-subset/groups/facilities) are
//     UPSERTed so existing rows get refreshed values + new rows arrive.
//   - Event tables (inspections/visits/jobs/invoices/properties/gdos/ESL) are
//     ADDITIVE (ON CONFLICT DO NOTHING) — never deletes, never mutates Yannick's rows.
//   - Sequences resynced after.
// NEVER touches: the `frozen_leads` schema, the app_* tables, any view/policy, or
//   anything Yannick adds. See docs/hr-sandbox.md.
//
// Usage:
//   node scripts/sync/hr_sandbox_refresh.js            # dry-run
//   node scripts/sync/hr_sandbox_refresh.js --execute  # writes
// ============================================================================
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const EXECUTE = process.argv.includes('--execute');
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID || 'wbasvhvvismukaqdnouk';
const HR = process.env.HR_SANDBOX_PROJECT_ID || 'klgtrdwrasrlxbmfyvdh';
if (!PAT) { console.error('SUPABASE_PAT required'); process.exit(1); }

const pg = (project, sql) => new Promise((res, rej) => {
  const b = JSON.stringify({ query: sql });
  const r = https.request({ hostname: 'api.supabase.com', path: '/v1/projects/' + project + '/database/query', method: 'POST', headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(b) } },
    rs => { let d = ''; rs.on('data', c => d += c); rs.on('end', () => rs.statusCode < 300 ? res(JSON.parse(d)) : rej(new Error('HTTP ' + rs.statusCode + ' ' + d.slice(0, 300)))); });
  r.on('error', rej); r.write(b); r.end();
});
const prod = sql => pg(PROD, sql), hr = sql => pg(HR, sql);

const lit = v => {
  if (v === null || v === undefined) return 'NULL';
  if (typeof v === 'number') return Number.isFinite(v) ? String(v) : 'NULL';
  if (typeof v === 'boolean') return v ? 'TRUE' : 'FALSE';
  if (Array.isArray(v)) { if (!v.length) return `'{}'`; return `'{${v.map(x => '"' + String(x).replace(/"/g, '\\"') + '"').join(',')}}'`; }
  if (typeof v === 'object') return `'${JSON.stringify(v).replace(/'/g, "''")}'::jsonb`;
  return `'${String(v).replace(/'/g, "''")}'`;
};

async function sharedCols(table) {
  const q = p => pg(p, `SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='${table}' AND is_generated='NEVER' ORDER BY ordinal_position;`);
  const [pc, hc] = await Promise.all([q(PROD), q(HR)]);
  const hset = new Set(hc.map(x => x.column_name));
  return pc.map(x => x.column_name).filter(c => hset.has(c)); // Prod ∩ HR
}

async function copy(table, where, mode /* 'upsert'|'insert' */, pkCols = ['id']) {
  const cols = await sharedCols(table);
  if (!cols.length) { console.log(`  ${table}: no shared cols, skipped`); return; }
  const colList = cols.map(c => `"${c}"`).join(',');
  const rows = await prod(`SELECT ${colList} FROM public."${table}" ${where ? 'WHERE ' + where : ''};`);
  if (!rows.length) { console.log(`  ${table}: 0 source rows`); return; }
  if (!EXECUTE) { console.log(`  ${table}: would ${mode} ${rows.length} rows (${cols.length} shared cols)`); return; }
  const nonPk = cols.filter(c => !pkCols.includes(c) && c !== 'created_at');
  const conflict = mode === 'upsert'
    ? `(${pkCols.map(c => `"${c}"`).join(',')}) DO UPDATE SET ${nonPk.map(c => `"${c}"=EXCLUDED."${c}"`).join(',')}`
    : 'DO NOTHING';
  const BATCH = 200; let n = 0, failed = 0, lastErr = '';
  for (let i = 0; i < rows.length; i += BATCH) {
    const chunk = rows.slice(i, i + BATCH);
    try {
      await hr(`INSERT INTO public."${table}" (${colList}) OVERRIDING SYSTEM VALUE VALUES ${chunk.map(r => '(' + cols.map(c => lit(r[c])).join(',') + ')').join(',')} ON CONFLICT ${conflict};`);
      n += chunk.length;
    } catch (e) { failed += chunk.length; lastErr = e.message.slice(0, 160); }
  }
  console.log(`  ${table}: ${mode} ${n} rows OK${failed ? ` (${failed} FAILED: ${lastErr})` : ''}`);
}

(async () => {
  console.log(`HR Sandbox refresh — PROD=${PROD} HR=${HR} — mode=${EXECUTE ? 'EXECUTE' : 'DRY-RUN'}\n`);
  const hrClients = (await hr(`SELECT id FROM public.clients;`)).map(r => r.id);
  if (!hrClients.length) { console.error('HR has 0 clients — seed it first (clone-prod) before top-up.'); process.exit(2); }
  const clientList = hrClients.join(',');
  console.log(`HR holds ${hrClients.length} subset clients.\n`);

  console.log('-- reference tables (upsert = refresh values + new rows) --');
  await copy('client_groups', null, 'upsert');
  await copy('disposal_facilities', null, 'upsert');
  await copy('vehicles', null, 'upsert');
  await copy('employees', null, 'upsert');
  await copy('clients', `id IN (${clientList})`, 'upsert');

  console.log('\n-- event tables (additive only; FK parents first) --');
  await copy('properties', `client_id IN (${clientList})`, 'insert');
  await copy('jobs', `client_id IN (${clientList})`, 'insert');
  await copy('invoices', `client_id IN (${clientList})`, 'insert');
  await copy('gdos', `client_id IN (${clientList}) OR client_id IS NULL`, 'insert');
  await copy('inspections', null, 'insert'); // full history (FKs only employees+vehicles, both full)
  await copy('visits', `client_id IN (${clientList}) AND deleted_at IS NULL`, 'insert');
  await copy('visit_assignments', `visit_id IN (SELECT id FROM visits WHERE client_id IN (${clientList}) AND deleted_at IS NULL)`, 'insert');
  await copy('entity_source_links', `entity_type IN ('employee','vehicle','gdo')`, 'insert');

  if (EXECUTE) {
    console.log('\n-- sequence resync --');
    const seqs = await hr(`SELECT t.relname AS tbl, s.relname AS seq, a.attname AS col FROM pg_class t JOIN pg_attribute a ON a.attrelid=t.oid JOIN pg_depend d ON d.refobjid=t.oid AND d.refobjsubid=a.attnum JOIN pg_class s ON s.oid=d.objid AND s.relkind='S' JOIN pg_namespace ns ON ns.oid=t.relnamespace WHERE ns.nspname='public' AND d.deptype IN ('a','i');`);
    for (const { tbl, seq, col } of seqs) {
      try { await hr(`SELECT setval('"public"."${seq}"', COALESCE((SELECT MAX("${col}") FROM public."${tbl}"), 1), true);`); } catch (e) { /* skip */ }
    }
    console.log(`  ${seqs.length} sequences resynced.`);
  }

  console.log('\n-- counts (prod vs HR) --');
  for (const t of ['employees', 'vehicles', 'inspections', 'visits', 'visit_assignments', 'clients', 'gdos', 'jobs', 'invoices']) {
    const a = (await prod(`SELECT count(*)::int AS n FROM public."${t}";`).catch(() => [{ n: '-' }]))[0].n;
    const b = (await hr(`SELECT count(*)::int AS n FROM public."${t}";`).catch(() => [{ n: '-' }]))[0].n;
    console.log(`  ${t}: prod=${a} hr=${b}`);
  }
  console.log('\n--- hr-refresh complete ---');
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
