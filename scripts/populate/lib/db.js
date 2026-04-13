// ============================================================================
// db.js — Thin wrapper for Supabase Management API SQL queries
// ============================================================================
// Single-project architecture (post-collapse 2026-04-09):
//   - raw.jobber_pull_*  → JSONB cache (was OLD project, now same project under raw schema)
//   - public.*           → canonical 3NF normalized tables
//   - ops.*              → operational views
// oldQuery() is kept as a compatibility alias → newQuery for any legacy callers.
//
// Why Management API instead of postgres-js? Service-role bypasses RLS, no
// extra dep, and we already have the PAT in .env.
// ============================================================================

require('dotenv').config({ path: require('path').resolve(__dirname, '../../../.env') });
const https = require('https');

const PAT = process.env.SUPABASE_PAT;
const NEW_PROJECT = 'wbasvhvvismukaqdnouk';
// Legacy reference retained only for explicit emergency rollback — not used in normal operation.
const OLD_PROJECT_LEGACY = 'infbofuilnqqviyjlwul';

if (!PAT) throw new Error('SUPABASE_PAT missing in .env');

function rawQuery(projectId, sql) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request(
      {
        hostname: 'api.supabase.com',
        path: `/v1/projects/${projectId}/database/query`,
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${PAT}`,
          'Content-Length': Buffer.byteLength(body),
        },
      },
      (res) => {
        let data = '';
        res.on('data', (c) => (data += c));
        res.on('end', () => {
          if (res.statusCode >= 200 && res.statusCode < 300) {
            try { resolve(JSON.parse(data)); } catch (e) { reject(new Error('Bad JSON: ' + data.slice(0, 500))); }
          } else {
            reject(new Error(`HTTP ${res.statusCode}: ${data.slice(0, 800)}`));
          }
        });
      }
    );
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

const newQuery = (sql) => rawQuery(NEW_PROJECT, sql);
// Compatibility alias: historically routed to OLD_PROJECT; now reads raw.* on the main project.
const oldQuery = (sql) => rawQuery(NEW_PROJECT, sql);

// ----------------------------------------------------------------------------
// SQL helpers
// ----------------------------------------------------------------------------
function sqlEscape(v) {
  if (v === null || v === undefined) return 'NULL';
  if (typeof v === 'boolean') return v ? 'TRUE' : 'FALSE';
  if (typeof v === 'number') {
    if (!isFinite(v)) return 'NULL';
    return String(v);
  }
  if (v instanceof Date) return `'${v.toISOString()}'`;
  if (Array.isArray(v)) {
    // PG array literal — text[]
    const parts = v.map(x => {
      if (x === null || x === undefined) return 'NULL';
      return '"' + String(x).replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
    });
    return `'{${parts.join(',')}}'`;
  }
  if (typeof v === 'object') {
    return `'${JSON.stringify(v).replace(/'/g, "''")}'::jsonb`;
  }
  return `'${String(v).replace(/'/g, "''")}'`;
}

// Build a multi-row INSERT ... ON CONFLICT statement.
// Splits into batches of `batchSize` to avoid SQL size limits.
async function bulkUpsert(table, rows, columns, conflictTarget, options = {}) {
  if (!rows.length) return { inserted: 0, batches: 0 };
  const { batchSize = 500, dryRun = false, updateColumns = null } = options;

  const updateCols = (updateColumns || columns).filter(c => c !== conflictTarget && (Array.isArray(conflictTarget) ? !conflictTarget.includes(c) : true));
  const updateClause = updateCols.length
    ? `DO UPDATE SET ${updateCols.map(c => `${c} = EXCLUDED.${c}`).join(', ')}`
    : 'DO NOTHING';

  const conflictCols = Array.isArray(conflictTarget) ? conflictTarget.join(', ') : conflictTarget;

  let inserted = 0;
  let batches = 0;
  for (let i = 0; i < rows.length; i += batchSize) {
    const batch = rows.slice(i, i + batchSize);
    const values = batch.map(row => '(' + columns.map(c => sqlEscape(row[c])).join(', ') + ')').join(',\n  ');
    const sql = `INSERT INTO ${table} (${columns.join(', ')}) VALUES\n  ${values}\nON CONFLICT (${conflictCols}) ${updateClause};`;

    if (dryRun) {
      console.log(`[dry-run] would upsert ${batch.length} rows into ${table} (batch ${batches + 1})`);
    } else {
      await newQuery(sql);
      inserted += batch.length;
    }
    batches++;
  }
  return { inserted: dryRun ? 0 : inserted, batches };
}

// Streamed read of all rows from a JSONB cache table
async function fetchJsonbCache(table) {
  // Fetch in chunks of 500 to avoid timeouts on big tables
  const all = [];
  let offset = 0;
  while (true) {
    // table arg may be 'jobber_pull_foo'; route to raw schema unconditionally.
    const schemaTable = table.startsWith('raw.') ? table : `raw.${table}`;
    const r = await oldQuery(`SELECT data FROM ${schemaTable} ORDER BY id LIMIT 500 OFFSET ${offset};`);
    if (!r.length) break;
    all.push(...r.map(x => x.data));
    if (r.length < 500) break;
    offset += 500;
  }
  return all;
}

// INSERT ... RETURNING id — returns array of generated PKs in insert order.
// Used by v2 populate pattern: insert business rows, get back PKs, then write entity_source_links.
async function bulkInsertReturning(table, rows, columns, options = {}) {
  if (!rows.length) return [];
  const { batchSize = 500, dryRun = false } = options;
  const allIds = [];

  for (let i = 0; i < rows.length; i += batchSize) {
    const batch = rows.slice(i, i + batchSize);
    const values = batch.map(row => '(' + columns.map(c => sqlEscape(row[c])).join(', ') + ')').join(',\n  ');
    const sql = `INSERT INTO ${table} (${columns.join(', ')}) VALUES\n  ${values}\nRETURNING id;`;

    if (dryRun) {
      console.log(`[dry-run] would insert ${batch.length} rows into ${table} (batch ${Math.floor(i / batchSize) + 1})`);
      // Return placeholder IDs for dry-run so downstream code can build links
      allIds.push(...batch.map((_, idx) => -(i + idx + 1)));
    } else {
      const result = await newQuery(sql);
      allIds.push(...result.map(r => r.id));
    }
  }
  return allIds;
}

module.exports = { oldQuery, newQuery, bulkUpsert, bulkInsertReturning, fetchJsonbCache, sqlEscape };
