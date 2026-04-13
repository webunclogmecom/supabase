// ============================================================================
// sourceLinks.js — Centralized entity_source_links helpers for v2 schema
// ============================================================================
// Replaces all direct source FK writes (jobber_client_id, airtable_record_id, etc.)
// with centralized entity_source_links rows.
//
// Entity types: client|property|visit|job|invoice|quote|employee|vehicle|
//               inspection|expense|derm_manifest|route|receivable|lead
// Source systems: jobber|airtable|samsara|fillout|manual
//
// Uses the same Management API pattern as db.js (no Supabase JS client needed).
// ============================================================================

const { newQuery, sqlEscape } = require('./db');

// -----------------------------------------------------------------------
// linkEntities — bulk upsert source links (batched at 500)
// -----------------------------------------------------------------------
async function linkEntities(links, { dryRun = false } = {}) {
  if (!links.length) return { inserted: 0 };
  const now = new Date().toISOString();
  const BATCH = 500;
  let inserted = 0;

  for (let i = 0; i < links.length; i += BATCH) {
    const batch = links.slice(i, i + BATCH);
    const values = batch.map(l => {
      return `(${sqlEscape(l.entity_type)}, ${sqlEscape(l.entity_id)}, ${sqlEscape(l.source_system)}, ` +
        `${sqlEscape(String(l.source_id))}, ${sqlEscape(l.source_name || null)}, ` +
        `${sqlEscape(l.match_method || 'direct_id')}, ${sqlEscape(l.match_confidence ?? 1.0)}, ` +
        `${sqlEscape(now)})`;
    }).join(',\n  ');

    const sql = `INSERT INTO entity_source_links (entity_type, entity_id, source_system, source_id, source_name, match_method, match_confidence, synced_at)
VALUES
  ${values}
ON CONFLICT (entity_type, entity_id, source_system)
DO UPDATE SET source_id = EXCLUDED.source_id, source_name = EXCLUDED.source_name,
  match_method = EXCLUDED.match_method, match_confidence = EXCLUDED.match_confidence,
  synced_at = EXCLUDED.synced_at;`;

    if (dryRun) {
      console.log(`  [dry-run] would link ${batch.length} entity_source_links`);
    } else {
      await newQuery(sql);
      inserted += batch.length;
    }
  }
  return { inserted };
}

// -----------------------------------------------------------------------
// buildLookupMap — load Map<source_id, entity_id> for one entity+system
// Call ONCE at top of each step to avoid N+1 queries.
// -----------------------------------------------------------------------
async function buildLookupMap(entity_type, source_system) {
  const rows = await newQuery(
    `SELECT source_id, entity_id FROM entity_source_links WHERE entity_type = ${sqlEscape(entity_type)} AND source_system = ${sqlEscape(source_system)};`
  );
  const map = new Map();
  for (const row of rows) map.set(String(row.source_id), row.entity_id);
  return map;
}

// -----------------------------------------------------------------------
// findBySourceId — single reverse lookup: source_id → entity_id
// -----------------------------------------------------------------------
async function findBySourceId(entity_type, source_system, source_id) {
  const rows = await newQuery(
    `SELECT entity_id FROM entity_source_links WHERE entity_type = ${sqlEscape(entity_type)} AND source_system = ${sqlEscape(source_system)} AND source_id = ${sqlEscape(String(source_id))} LIMIT 1;`
  );
  return rows.length ? rows[0].entity_id : null;
}

// -----------------------------------------------------------------------
// getEntityLinks — all source links for one entity (debug/audit)
// -----------------------------------------------------------------------
async function getEntityLinks(entity_type, entity_id) {
  return newQuery(
    `SELECT * FROM entity_source_links WHERE entity_type = ${sqlEscape(entity_type)} AND entity_id = ${sqlEscape(entity_id)};`
  );
}

module.exports = { linkEntities, buildLookupMap, findBySourceId, getEntityLinks };
