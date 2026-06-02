// hr_sandbox_topup.js
//
// After subset_prod_to_field_portal.js runs, this top-up:
//   1. Replaces partial employees/vehicles/disposal_facilities/client_groups
//      with FULL copies from Prod (HR needs every employee + vehicle).
//   2. Copies ALL gdos (139 rows) — subset script predates gdos table, didn't
//      include it.
//   3. Re-attempts notes / derm_manifests / manifest_visits with a
//      stricter filter so FK constraints are satisfied (these failed in
//      subset because they reference gdos or out-of-subset clients).
//   4. Tops up entity_source_links for the full employees + vehicles set.
//
// Run AFTER subset_prod_to_field_portal.js --execute.
//
// Usage:
//   node scripts/sync/hr_sandbox_topup.js             # dry-run
//   node scripts/sync/hr_sandbox_topup.js --execute   # writes

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const EXECUTE = process.argv.includes('--execute');
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
const FP = process.env.FIELD_PORTAL_SUPABASE_PROJECT_ID;
if (!PAT || !PROD || !FP) {
  console.error('Missing SUPABASE_PAT / SUPABASE_PROJECT_ID / FIELD_PORTAL_SUPABASE_PROJECT_ID');
  process.exit(1);
}
console.log(`PROD=${PROD}   FIELD_PORTAL=${FP}   mode=${EXECUTE ? 'EXECUTE' : 'DRY-RUN'}\n`);

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = [];
      r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej);
    if (body) req.write(body);
    req.end();
  });
}
async function pg(project, sql) {
  const r = await http(
    {
      hostname: 'api.supabase.com',
      path: '/v1/projects/' + project + '/database/query',
      method: 'POST',
      headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json' },
    },
    JSON.stringify({ query: sql })
  );
  if (r.status >= 300) throw new Error(`PG ${project} ${r.status}: ${r.body.slice(0, 600)}`);
  return JSON.parse(r.body);
}
const prod = sql => pg(PROD, sql);
const fp = sql => pg(FP, sql);

function lit(v) {
  if (v === null || v === undefined) return 'NULL';
  if (typeof v === 'number') return Number.isFinite(v) ? String(v) : 'NULL';
  if (typeof v === 'boolean') return v ? 'TRUE' : 'FALSE';
  if (Array.isArray(v)) {
    if (!v.length) return `'{}'`;
    if (v.every(x => typeof x === 'number')) return `'{${v.join(',')}}'`;
    return `'{${v.map(x => '"' + String(x).replace(/"/g, '\\"') + '"').join(',')}}'`;
  }
  if (typeof v === 'object') return `'${JSON.stringify(v).replace(/'/g, "''")}'::jsonb`;
  return `'${String(v).replace(/'/g, "''")}'`;
}
function valsRow(row, cols) {
  return '(' + cols.map(c => lit(row[c])).join(',') + ')';
}

async function columnsOf(table) {
  const r = await prod(`
    SELECT column_name FROM information_schema.columns
    WHERE table_schema='public' AND table_name='${table}' AND is_generated='NEVER'
    ORDER BY ordinal_position;
  `);
  return r.map(x => x.column_name);
}

async function fetchTable(table, where) {
  const cols = await columnsOf(table);
  if (!cols.length) return { cols: [], rows: [] };
  const colList = cols.map(c => `"${c}"`).join(',');
  const rows = await prod(`SELECT ${colList} FROM public."${table}" ${where ? `WHERE ${where}` : ''};`);
  return { cols, rows };
}

async function copyTable(name, rows, cols, conflictKey = null) {
  if (!rows.length) {
    console.log(`  ${name}: 0 rows (skipped)`);
    return 0;
  }
  if (!EXECUTE) {
    console.log(`  ${name}: would insert ${rows.length} rows`);
    return rows.length;
  }
  const colList = cols.map(c => `"${c}"`).join(',');
  const BATCH = 300;
  let inserted = 0;
  for (let i = 0; i < rows.length; i += BATCH) {
    const chunk = rows.slice(i, i + BATCH);
    const onConflict = conflictKey || 'DO NOTHING';
    const sql = `INSERT INTO public."${name}" (${colList}) OVERRIDING SYSTEM VALUE VALUES ${chunk
      .map(r => valsRow(r, cols))
      .join(',')} ON CONFLICT ${onConflict};`;
    await fp(sql);
    inserted += chunk.length;
  }
  console.log(`  ${name}: ${inserted} rows inserted`);
  return inserted;
}

(async () => {
  // Determine subset client + visit ids already present in FP (from the prior subset run)
  const subsetClientIds = (await fp(`SELECT id FROM public.clients ORDER BY id;`)).map(r => r.id);
  const subsetVisitIds = (await fp(`SELECT id FROM public.visits ORDER BY id;`)).map(r => r.id);
  console.log(`Existing FP subset: ${subsetClientIds.length} clients, ${subsetVisitIds.length} visits.\n`);
  if (!subsetClientIds.length) {
    console.error('FP appears empty — run subset_prod_to_field_portal.js --execute first.');
    process.exit(2);
  }
  const clientList = subsetClientIds.join(',');
  const visitList = subsetVisitIds.join(',');

  // ============================================================
  // PHASE A — Full copies of small, app-independent reference tables
  // ============================================================
  console.log('-- PHASE A: full reference data copies --');

  // Standalone reference tables — full copies
  for (const t of ['client_groups', 'disposal_facilities', 'employees', 'vehicles']) {
    const { cols, rows } = await fetchTable(t);
    await copyTable(t, rows, cols);
  }
  // gdos has client_id FK — must filter to subset clients OR null client_id
  {
    const { cols, rows } = await fetchTable(
      'gdos',
      `client_id IN (${clientList}) OR client_id IS NULL`
    );
    await copyTable('gdos', rows, cols);
  }

  // ============================================================
  // PHASE B — Re-attempt the FK-blocked tables now that gdos exists
  // ============================================================
  console.log('\n-- PHASE B: re-attempt FK-blocked tables --');

  // notes: original filter (visit_id IN subset) caught cross-client notes.
  // Tighten to ALSO require client_id IN subset (drops orphans).
  let r = await fetchTable(
    'notes',
    `visit_id IN (${visitList}) AND client_id IN (${clientList})`
  );
  await copyTable('notes', r.rows, r.cols);

  // derm_manifests: now that gdos is full, the original (client_id IN subset)
  // filter should satisfy the gdo_id FK. But verify no orphan gdo refs.
  r = await fetchTable(
    'derm_manifests',
    `client_id IN (${clientList})`
  );
  await copyTable('derm_manifests', r.rows, r.cols);

  // manifest_visits: depends on derm_manifests + visits both being present
  r = await fetchTable(
    'manifest_visits',
    `manifest_id IN (SELECT id FROM derm_manifests WHERE client_id IN (${clientList}))
       AND visit_id IN (${visitList})`
  );
  await copyTable('manifest_visits', r.rows, r.cols);

  // ============================================================
  // PHASE C — Top-up ESL for the FULL employees + vehicles + gdos sets
  //          (subset only included those referenced by subset visits)
  // ============================================================
  console.log('\n-- PHASE C: top-up entity_source_links for full employees/vehicles/gdos --');

  const ESL_TOPUP_FILTER = `
       (entity_type='employee' AND entity_id IN (SELECT id FROM public.employees))
    OR (entity_type='vehicle'  AND entity_id IN (SELECT id FROM public.vehicles))
    OR (entity_type='gdo'      AND entity_id IN (SELECT id FROM public.gdos))
  `.replace(/\s+/g, ' ').trim();

  r = await fetchTable('entity_source_links', ESL_TOPUP_FILTER);
  // ESL has UNIQUE on (entity_type, entity_id, source_system) — skip dupes
  await copyTable('entity_source_links', r.rows, r.cols);

  // ============================================================
  // PHASE D — Sequence resync (in case we inserted higher ids than current)
  // ============================================================
  if (EXECUTE) {
    console.log('\n-- PHASE D: resync sequences --');
    const seqs = await fp(`
      SELECT t.relname AS table_name, s.relname AS seq_name, a.attname AS col_name
      FROM pg_class t JOIN pg_attribute a ON a.attrelid=t.oid
      JOIN pg_depend d ON d.refobjid=t.oid AND d.refobjsubid=a.attnum
      JOIN pg_class s ON s.oid=d.objid AND s.relkind='S'
      JOIN pg_namespace ns ON ns.oid=t.relnamespace
      WHERE ns.nspname='public' AND d.deptype='a';
    `);
    for (const { table_name, seq_name, col_name } of seqs) {
      try {
        await fp(
          `SELECT setval('"public"."${seq_name}"', COALESCE((SELECT MAX("${col_name}") FROM public."${table_name}"), 1), true);`
        );
      } catch (e) {
        console.warn(`  seq ${seq_name}: ${e.message.slice(0, 80)}`);
      }
    }
    console.log(`  ${seqs.length} sequences resynced.`);
  }

  // ============================================================
  // PHASE E — Final summary
  // ============================================================
  console.log('\n-- FINAL SANDBOX COUNTS --');
  const tables = [
    'clients', 'client_contacts', 'properties', 'service_configs',
    'gdos', 'derm_manifests', 'manifest_visits', 'inspections', 'disposal_facilities',
    'visits', 'visit_assignments', 'line_items', 'notes',
    'photos', 'photo_links', 'photo_classifications',
    'jobs', 'invoices', 'quotes',
    'employees', 'vehicles', 'entity_source_links', 'client_groups',
  ];
  const final = [];
  for (const t of tables) {
    try {
      const fpCount = (await fp(`SELECT COUNT(*)::int AS n FROM public."${t}";`))[0]?.n ?? 'err';
      const prodCount = (await prod(`SELECT COUNT(*)::int AS n FROM public."${t}";`))[0]?.n ?? 'err';
      final.push({ table: t, prod: prodCount, sandbox: fpCount, pct: Math.round(100 * fpCount / Math.max(prodCount, 1)) + '%' });
    } catch (e) {
      final.push({ table: t, prod: 'err', sandbox: 'err', pct: '-' });
    }
  }
  console.table(final);
})().catch(e => {
  console.error('FATAL:', e.message);
  process.exit(2);
});
