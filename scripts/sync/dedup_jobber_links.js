// ============================================================================
// dedup_jobber_links.js — merge webhook-created duplicates into populate-era rows
// ============================================================================
// Problem: entity_source_links has two formats for source_system='jobber':
//   - old (populate.js):   source_id = base64 GID   'Z2lk...'
//   - new (webhook-jobber): source_id = numeric     '96018133'
// When webhook ran, findEntityBySourceId(numeric) missed the old GID-formatted
// row → inserted a duplicate entity + a new ESL row.
//
// This script:
//   1. Finds pairs (old_id, new_id) that both map to the same Jobber numeric.
//   2. For each FK table referencing that entity type, UPDATEs new_id → old_id.
//   3. DELETEs the new entity row and its ESL row.
//   4. UPDATEs the kept ESL row's source_id from GID → numeric.
//
// Flags:
//   --dry-run (default) — prints the plan
//   --execute           — applies changes in a single SQL batch per entity type
// ============================================================================

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const { newQuery } = require('../populate/lib/db');

const DRY = !process.argv.includes('--execute');

// entity_type -> { table, fk_columns: [[table, col], ...] }
const FK_MAP = {
  client: {
    table: 'clients',
    fks: [
      ['client_contacts', 'client_id'],
      ['properties', 'client_id'],
      ['service_configs', 'client_id'],
      ['jobs', 'client_id'],
      ['quotes', 'client_id'],
      ['visits', 'client_id'],
      ['invoices', 'client_id'],
      ['receivables', 'client_id'],
      ['leads', 'client_id'],
    ],
  },
  job: {
    table: 'jobs',
    fks: [
      ['visits', 'job_id'],
      ['invoices', 'job_id'],
      ['line_items', 'job_id'],
    ],
  },
  visit: {
    table: 'visits',
    fks: [
      ['visit_assignments', 'visit_id'],
      ['manifest_visits', 'visit_id'],
    ],
  },
  invoice: {
    table: 'invoices',
    fks: [],
  },
  quote: {
    table: 'quotes',
    fks: [
      ['jobs', 'quote_id'],
    ],
  },
  property: {
    table: 'properties',
    fks: [
      ['jobs', 'property_id'],
      ['visits', 'property_id'],
      ['service_configs', 'property_id'],
    ],
  },
};

async function findPairs(entity_type) {
  // Pairs where GID row and numeric row both exist for same Jobber numeric id.
  const rows = await newQuery(`
    WITH old_gid AS (
      SELECT entity_id,
             (regexp_match(convert_from(decode(source_id, 'base64'), 'UTF8'), '([0-9]+)$'))[1] AS num
      FROM entity_source_links
      WHERE source_system='jobber' AND entity_type='${entity_type}' AND source_id LIKE 'Z2lk%'
    ),
    new_num AS (
      SELECT entity_id, source_id AS num
      FROM entity_source_links
      WHERE source_system='jobber' AND entity_type='${entity_type}' AND source_id NOT LIKE 'Z2lk%'
    )
    SELECT o.entity_id AS keep_id,
           n.entity_id AS drop_id,
           o.num AS jobber_numeric
    FROM old_gid o
    JOIN new_num n USING (num)
    WHERE o.entity_id <> n.entity_id;
  `);
  return rows;
}

function buildCaseWhen(pairs, column) {
  const whens = pairs.map(p => `WHEN ${column}=${p.drop_id} THEN ${p.keep_id}`).join(' ');
  const ids = pairs.map(p => p.drop_id).join(',');
  return { whens, ids };
}

async function dedupeEntity(entity_type) {
  const cfg = FK_MAP[entity_type];
  if (!cfg) throw new Error(`no FK_MAP entry for ${entity_type}`);
  const pairs = await findPairs(entity_type);
  if (!pairs.length) { console.log(`[${entity_type}] no collisions`); return; }
  console.log(`[${entity_type}] ${pairs.length} collision pair(s)`);

  if (DRY) { console.log(`  DRY-RUN — would remap FKs and delete drop_ids`); return; }

  // 1. For each FK, UPDATE column set to keep_id where column in (drop_ids)
  for (const [ftable, fcol] of cfg.fks) {
    const { whens, ids } = buildCaseWhen(pairs, fcol);
    const sql = `UPDATE ${ftable} SET ${fcol} = CASE ${whens} ELSE ${fcol} END WHERE ${fcol} IN (${ids});`;
    const r = await newQuery(sql).catch(e => ({ error: e.message }));
    if (r.error) console.log(`  WARN ${ftable}.${fcol}: ${r.error.slice(0,120)}`);
    else console.log(`  remapped ${ftable}.${fcol}`);
  }

  // 2. Also remap polymorphic photo_links (entity_type column)
  const { whens: phWhens, ids: phIds } = buildCaseWhen(pairs, 'entity_id');
  const phSql = `UPDATE photo_links SET entity_id = CASE ${phWhens} ELSE entity_id END WHERE entity_type='${entity_type}' AND entity_id IN (${phIds});`;
  const phR = await newQuery(phSql).catch(e => ({ error: e.message }));
  if (phR.error) console.log(`  WARN photo_links: ${phR.error.slice(0,120)}`);
  else console.log(`  remapped photo_links`);

  // 3. DELETE the ESL rows for drop_ids (webhook-created, numeric format).
  //    Keep the old GID row; we normalize it next.
  const dropIds = pairs.map(p => p.drop_id).join(',');
  await newQuery(`DELETE FROM entity_source_links WHERE entity_type='${entity_type}' AND source_system='jobber' AND entity_id IN (${dropIds});`);
  console.log(`  deleted ${pairs.length} new ESL rows`);

  // 4. DELETE the duplicate entity rows.
  await newQuery(`DELETE FROM ${cfg.table} WHERE id IN (${dropIds});`);
  console.log(`  deleted ${pairs.length} duplicate ${cfg.table} rows`);

  // 5. Normalize old (kept) ESL source_id from GID → numeric.
  const keepIds = pairs.map(p => p.keep_id).join(',');
  const normSql = `
    UPDATE entity_source_links
    SET source_id = (regexp_match(convert_from(decode(source_id, 'base64'), 'UTF8'), '([0-9]+)$'))[1]
    WHERE entity_type='${entity_type}' AND source_system='jobber'
      AND entity_id IN (${keepIds}) AND source_id LIKE 'Z2lk%';
  `;
  await newQuery(normSql);
  console.log(`  normalized ${pairs.length} old source_ids to numeric`);
}

(async () => {
  console.log('='.repeat(60));
  console.log('dedup_jobber_links.js');
  console.log(`Mode: ${DRY ? 'DRY-RUN' : 'EXECUTE'}`);
  console.log('='.repeat(60));

  // Order matters: do clients last so child FKs are already cleaned up.
  for (const et of ['invoice', 'quote', 'visit', 'job', 'property', 'client']) {
    await dedupeEntity(et);
  }

  // After all collisions handled, any remaining GID-format source_ids have no
  // numeric collision — normalize them to numeric too, for consistency.
  if (!DRY) {
    const r = await newQuery(`
      UPDATE entity_source_links
      SET source_id = (regexp_match(convert_from(decode(source_id, 'base64'), 'UTF8'), '([0-9]+)$'))[1]
      WHERE source_system='jobber' AND source_id LIKE 'Z2lk%'
      RETURNING 1;
    `);
    console.log(`\nfinal pass: normalized ${r.length} non-colliding GIDs to numeric`);
  }
  console.log('\nDone.');
})();
