// Subset Prod data → Field Portal Sandbox.
//
// Picks 53 of Prod's ACTIVE/RECURRING clients (those with completed visit
// history), deterministic by id stride, then copies them + all related
// rows into Field Portal Sandbox.
//
// Field Portal Sandbox should already have the public schema applied via
// the `.github/workflows/clone-prod-to-field-portal.yml` workflow.
//
// Skips operational/audit tables (vehicle_telemetry_readings,
// webhook_events_log, sync_cursors) and the auth schema (Supabase manages it).
//
// Usage:
//   node scripts/sync/subset_prod_to_field_portal.js             # dry-run
//   node scripts/sync/subset_prod_to_field_portal.js --execute   # writes
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const EXECUTE = process.argv.includes('--execute');
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;                  // wbasvhvvismukaqdnouk
const FP   = process.env.FIELD_PORTAL_SUPABASE_PROJECT_ID;     // klgtrdwrasrlxbmfyvdh
if (!PAT || !PROD || !FP) { console.error('Missing SUPABASE_PAT / SUPABASE_PROJECT_ID / FIELD_PORTAL_SUPABASE_PROJECT_ID'); process.exit(1); }
console.log(`PROD=${PROD}   FIELD_PORTAL=${FP}   mode=${EXECUTE ? 'EXECUTE' : 'DRY-RUN'}\n`);

function http(opts, body) { return new Promise((res, rej) => {
  const req = https.request(opts, r => { const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()})); });
  req.on('error',rej); if(body) req.write(body); req.end();
});}
async function pg(project, sql) {
  const r = await http({hostname:'api.supabase.com',path:'/v1/projects/'+project+'/database/query',method:'POST',headers:{Authorization:'Bearer '+PAT,'Content-Type':'application/json'}}, JSON.stringify({query:sql}));
  if (r.status >= 300) throw new Error(`PG ${project} ${r.status}: ${r.body.slice(0,500)}`);
  return JSON.parse(r.body);
}
const prod = sql => pg(PROD, sql);
const fp   = sql => pg(FP, sql);

// --- SQL literal helpers ---
function lit(v) {
  if (v === null || v === undefined) return 'NULL';
  if (typeof v === 'number') return Number.isFinite(v) ? String(v) : 'NULL';
  if (typeof v === 'boolean') return v ? 'TRUE' : 'FALSE';
  if (Array.isArray(v)) {
    // text[] / int[]
    if (!v.length) return `'{}'`;
    if (v.every(x => typeof x === 'number')) return `'{${v.join(',')}}'`;
    return `'{${v.map(x => '"' + String(x).replace(/"/g, '\\"') + '"').join(',')}}'`;
  }
  if (typeof v === 'object') return `'${JSON.stringify(v).replace(/'/g, "''")}'::jsonb`;
  return `'${String(v).replace(/'/g, "''")}'`;
}
function valsRow(row, cols) { return '(' + cols.map(c => lit(row[c])).join(',') + ')'; }

// Build INSERT statement(s), batched. Uses OVERRIDING SYSTEM VALUE so it
// works whether the table's identity column is GENERATED ALWAYS or BY DEFAULT —
// some tables (client_contacts, entity_source_links) declare GENERATED ALWAYS,
// which rejects explicit id values without the override.
async function copyTable(name, rows, cols) {
  if (!rows.length) { console.log(`  ${name}: 0 rows (skipped)`); return 0; }
  if (!EXECUTE) { console.log(`  ${name}: would insert ${rows.length} rows`); return rows.length; }
  const colList = cols.map(c => `"${c}"`).join(',');
  const BATCH = 300;
  let inserted = 0;
  for (let i = 0; i < rows.length; i += BATCH) {
    const chunk = rows.slice(i, i+BATCH);
    const sql = `INSERT INTO public."${name}" (${colList}) OVERRIDING SYSTEM VALUE VALUES ${chunk.map(r => valsRow(r, cols)).join(',')} ON CONFLICT DO NOTHING;`;
    await fp(sql);
    inserted += chunk.length;
  }
  console.log(`  ${name}: ${inserted} rows inserted`);
  return inserted;
}

// Get column list (excluding generated cols, which can't be inserted)
async function columnsOf(table) {
  const r = await prod(`
    SELECT column_name FROM information_schema.columns
    WHERE table_schema='public' AND table_name='${table}'
      AND is_generated='NEVER'
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

(async () => {
  // 1) Pick deterministic subset of clients
  const idsRes = await prod(`
    WITH eligible AS (
      SELECT id, ROW_NUMBER() OVER (ORDER BY id) AS rn,
             COUNT(*) OVER () AS total
      FROM clients
      WHERE status IN ('ACTIVE','RECURRING')
        AND id IN (SELECT DISTINCT client_id FROM visits WHERE visit_status='completed' AND client_id IS NOT NULL)
    )
    SELECT id FROM eligible
    WHERE rn % CEIL(total / 53.0)::int = 0
    ORDER BY id;
  `);
  const clientIds = idsRes.map(r => r.id);
  const clientList = clientIds.join(',');
  console.log(`Subset clients: ${clientIds.length} ids → ${clientIds.slice(0,5)}..${clientIds.slice(-3)}\n`);
  if (!clientIds.length) { console.error('No clients picked. Aborting.'); process.exit(2); }

  // 2) Build the table copy plan (order matters for FK satisfaction)
  // ESL rows are kept only for entities ACTUALLY in the subset. Strict scope.
  const VEHICLES_SUB  = `SELECT DISTINCT vehicle_id FROM visits WHERE client_id IN (${clientList}) AND vehicle_id IS NOT NULL`;
  // Employees referenced by our subset can show up in TWO places:
  //   - visit_assignments.employee_id  (the drivers / techs on the visit)
  //   - notes.author_employee_id       (whoever wrote a note on the visit)
  // Union both, drop nulls.
  const EMPLOYEES_SUB = `
    SELECT employee_id AS id FROM visit_assignments
      WHERE visit_id IN (SELECT id FROM visits WHERE client_id IN (${clientList}))
        AND employee_id IS NOT NULL
    UNION
    SELECT author_employee_id AS id FROM notes
      WHERE visit_id IN (SELECT id FROM visits WHERE client_id IN (${clientList}))
        AND author_employee_id IS NOT NULL
  `.replace(/\s+/g,' ').trim();
  const ESL_FILTER = `
       (entity_type='client'        AND entity_id IN (${clientList}))
    OR (entity_type='property'      AND entity_id IN (SELECT id FROM properties     WHERE client_id IN (${clientList})))
    OR (entity_type='visit'         AND entity_id IN (SELECT id FROM visits         WHERE client_id IN (${clientList})))
    OR (entity_type='job'           AND entity_id IN (SELECT id FROM jobs           WHERE client_id IN (${clientList})))
    OR (entity_type='invoice'       AND entity_id IN (SELECT id FROM invoices       WHERE client_id IN (${clientList})))
    OR (entity_type='quote'         AND entity_id IN (SELECT id FROM quotes         WHERE client_id IN (${clientList})))
    OR (entity_type='vehicle'       AND entity_id IN (${VEHICLES_SUB}))
    OR (entity_type='employee'      AND entity_id IN (${EMPLOYEES_SUB}))
    OR (entity_type='derm_manifest' AND entity_id IN (SELECT id FROM derm_manifests WHERE client_id IN (${clientList})))
  `.replace(/\s+/g, ' ').trim();

  // Per Fred 2026-05-14: only data strictly linked to the subset clients.
  // Skip photos, photo_links, inspections (shift-based, not client-linked),
  // webhook_tokens (global ops), and any other non-linked global tables.
  // Vehicles + employees: only those REFERENCED by subset visits/assignments.
  const plan = [
    // Reference data, scoped to what's actually used by subset visits.
    { table: 'vehicles',  where: `id IN (SELECT DISTINCT vehicle_id FROM visits WHERE client_id IN (${clientList}) AND vehicle_id IS NOT NULL)` },
    { table: 'employees', where: `id IN (${EMPLOYEES_SUB})` },
    // Client-anchored
    { table: 'clients',             where: `id IN (${clientList})` },
    { table: 'client_contacts',     where: `client_id IN (${clientList})` },
    { table: 'properties',          where: `client_id IN (${clientList})` },
    { table: 'service_configs',     where: `client_id IN (${clientList})` },
    { table: 'jobs',                where: `client_id IN (${clientList})` },
    { table: 'invoices',            where: `client_id IN (${clientList})` },
    { table: 'quotes',              where: `client_id IN (${clientList})` },
    { table: 'visits',              where: `client_id IN (${clientList})` },
    { table: 'visit_assignments',   where: `visit_id IN (SELECT id FROM visits WHERE client_id IN (${clientList}))` },
    { table: 'line_items',          where: `invoice_id IN (SELECT id FROM invoices WHERE client_id IN (${clientList}))` },
    { table: 'notes',               where: `visit_id IN (SELECT id FROM visits WHERE client_id IN (${clientList}))` },
    { table: 'derm_manifests',      where: `client_id IN (${clientList})` },
    // Intersection: only manifest_visits where BOTH ends are in subset
    { table: 'manifest_visits',     where: `
        manifest_id IN (SELECT id FROM derm_manifests WHERE client_id IN (${clientList}))
        AND visit_id IN (SELECT id FROM visits WHERE client_id IN (${clientList}))
      `.replace(/\s+/g,' ').trim() },
    { table: 'entity_source_links', where: ESL_FILTER },
  ];

  // 3) Copy each table
  console.log('Copying tables...');
  const stats = {};
  for (const step of plan) {
    try {
      const { cols, rows } = await fetchTable(step.table, step.where);
      stats[step.table] = rows.length;
      if (!cols.length) { console.log(`  ${step.table}: SKIP (table not in Prod public schema)`); continue; }
      await copyTable(step.table, rows, cols);
    } catch (e) {
      console.error(`  ${step.table}: FAILED — ${e.message}`);
      stats[step.table] = `ERROR: ${e.message.slice(0, 100)}`;
    }
  }

  // 4) Resync sequences to MAX(id) for each table that has serial PK
  if (EXECUTE) {
    console.log('\nResyncing sequences...');
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
        await fp(`SELECT setval('"public"."${seq_name}"', COALESCE((SELECT MAX("${col_name}") FROM public."${table_name}"), 1), true);`);
      } catch (e) {
        console.warn(`  seq ${seq_name}: ${e.message.slice(0,80)}`);
      }
    }
    console.log(`  ${seqs.length} sequences resynced.`);
  }

  // 5) Final per-table counts in Field Portal
  console.log('\nFinal Field Portal row counts:');
  const finals = [];
  for (const step of plan) {
    try {
      const r = await fp(`SELECT COUNT(*)::int AS n FROM public."${step.table}";`);
      finals.push({ table: step.table, prod_planned: stats[step.table], field_portal_now: r[0]?.n });
    } catch (e) {
      finals.push({ table: step.table, prod_planned: stats[step.table], field_portal_now: 'ERROR' });
    }
  }
  console.table(finals);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
