// Comprehensive schema audit post-2026-04-29 redo.
// Lists every table in `public`, classifies it (active / dormant / deprecated /
// system), and flags drift between v2_schema.sql, migrations, and live DB.

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const { newQuery } = require('../populate/lib/db');

const CLASSIFICATION = {
  // Business tables — actively populated post-redo
  clients:                       { kind: 'BUSINESS', source: 'Jobber+AT+Samsara', notes: 'canonical client identity' },
  client_contacts:               { kind: 'BUSINESS', source: 'Jobber+AT', notes: 'multi-role contacts' },
  properties:                    { kind: 'BUSINESS', source: 'Jobber+AT+Samsara', notes: 'addresses + geofence' },
  service_configs:               { kind: 'BUSINESS', source: 'Airtable (UNPIVOT)', notes: 'GT/CL/WD frequencies, prices, GDO' },
  employees:                     { kind: 'BUSINESS', source: 'Jobber+Samsara', notes: 'AT drivers DROPPED' },
  vehicles:                      { kind: 'BUSINESS', source: 'Samsara + manual', notes: '3 Samsara + Goliath manual' },
  vehicle_telemetry_readings:    { kind: 'BUSINESS', source: 'Samsara webhook', notes: 'fuel/odometer/engine — no GPS yet' },
  quotes:                        { kind: 'BUSINESS', source: 'Jobber', notes: '' },
  jobs:                          { kind: 'BUSINESS', source: 'Jobber', notes: '' },
  invoices:                      { kind: 'BUSINESS', source: 'Jobber', notes: 'covers Past Due (replaces receivables)' },
  line_items:                    { kind: 'BUSINESS', source: 'Jobber', notes: 'invoice/quote line items' },
  visits:                        { kind: 'BUSINESS', source: 'Jobber+AT (enriched)', notes: 'cross-source dedup live' },
  visit_assignments:             { kind: 'BUSINESS', source: 'Jobber assignedUsers', notes: '' },
  inspections:                   { kind: 'BUSINESS', source: 'Airtable PRE-POST', notes: 'Fillout source DROPPED 2026-04-29' },
  derm_manifests:                { kind: 'BUSINESS', source: 'Airtable', notes: '' },
  manifest_visits:               { kind: 'BUSINESS', source: 'derived (client+date join)', notes: '' },
  notes:                         { kind: 'BUSINESS', source: 'Jobber notes API', notes: 'one-shot migration; no live webhook yet' },
  photos:                        { kind: 'BUSINESS', source: 'Jobber attachments', notes: 'unified photo storage (ADR 009)' },
  photo_links:                   { kind: 'BUSINESS', source: 'derived (polymorphic)', notes: 'unified link table' },
  jobber_oversized_attachments:  { kind: 'BUSINESS', source: 'jobber_notes_photos.js (skipped)', notes: 'tracking 50MB+ files' },

  // Dormant — kept in schema, not populated
  expenses:                      { kind: 'DORMANT',  source: '(none — Ramp owns)', notes: 'DROPPED 2026-04-29; Ramp tracks expenses' },
  receivables:                   { kind: 'DORMANT',  source: '(none — Jobber invoices)', notes: 'DROPPED 2026-04-29; query invoices for past-due' },
  routes:                        { kind: 'DORMANT',  source: '(none — Viktor skill)', notes: 'DROPPED 2026-04-29; routing in Viktor Slack skill' },
  route_stops:                   { kind: 'DORMANT',  source: '(none — Viktor skill)', notes: 'DROPPED 2026-04-29' },
  leads:                         { kind: 'DORMANT',  source: '(none — Odoo)', notes: 'DROPPED 2026-04-29; Odoo CRM owns leads' },

  // Deprecated — schema drift (in v2_schema.sql baseline but replaced by migrations)
  inspection_photos:             { kind: 'DEPRECATED', source: '(replaced)', notes: 'replaced by photos+photo_links per ADR 009' },
  visit_photos:                  { kind: 'DEPRECATED', source: '(replaced)', notes: 'replaced by photos+photo_links per ADR 009' },

  // System / ops
  entity_source_links:           { kind: 'SYSTEM', source: 'all', notes: 'polymorphic cross-system ID bridge (ADR 002)' },
  sync_cursors:                  { kind: 'SYSTEM', source: 'cron jobs', notes: 'incremental sync state' },
  sync_log:                      { kind: 'SYSTEM', source: 'cron jobs', notes: 'sync run log' },
  webhook_events_log:            { kind: 'SYSTEM', source: 'edge functions', notes: 'every webhook logged here' },
  webhook_tokens:                { kind: 'SYSTEM', source: 'OAuth flows', notes: 'NEVER WIPE — OAuth credentials' },
};

(async () => {
  console.log('=== SCHEMA AUDIT (post-2026-04-29 redo) ===\n');

  // Single query — pg_stat_user_tables has all schemas including public
  const tables = await newQuery(`
    SELECT
      relname AS table_name,
      n_live_tup::bigint AS row_estimate,
      pg_size_pretty(pg_total_relation_size(relid)) AS size
    FROM pg_stat_user_tables
    WHERE schemaname = 'public'
    ORDER BY relname;
  `);

  const exactCounts = {};
  for (const t of tables) exactCounts[t.table_name] = t.row_estimate;

  // Group by classification
  const byKind = { BUSINESS: [], DORMANT: [], DEPRECATED: [], SYSTEM: [], UNCLASSIFIED: [] };
  for (const t of tables) {
    const cls = CLASSIFICATION[t.table_name];
    const row = { ...t, count: exactCounts[t.table_name], cls };
    if (!cls) byKind.UNCLASSIFIED.push(row);
    else byKind[cls.kind].push(row);
  }

  for (const kind of ['BUSINESS', 'DORMANT', 'DEPRECATED', 'SYSTEM', 'UNCLASSIFIED']) {
    if (!byKind[kind].length) continue;
    console.log(`\n[${kind}] ${byKind[kind].length} table(s):`);
    for (const t of byKind[kind]) {
      const cls = t.cls || { source: '?', notes: 'NOT IN AUDIT MAP — unclassified' };
      const countStr = String(t.count).padStart(5);
      const sizeStr = (t.size || '').padStart(8);
      console.log(`  ${countStr} rows  ${sizeStr}  ${t.table_name.padEnd(32)}  source: ${cls.source}`);
      if (cls.notes) console.log(`                                    ${' '.repeat(32)}  → ${cls.notes}`);
    }
  }

  // Drift checks
  console.log('\n\n=== DRIFT CHECKS ===');

  // Are deprecated tables actually present in DB?
  const present = new Set(tables.map(t => t.table_name));
  const deprecated = ['inspection_photos', 'visit_photos'];
  for (const d of deprecated) {
    if (present.has(d)) console.log(`  ⚠️  ${d} still exists in DB (should have been dropped per ADR 009)`);
    else console.log(`  ✅ ${d} not in DB (correctly dropped)`);
  }

  // Dormant tables — confirm they're empty
  const dormant = ['expenses', 'receivables', 'routes', 'route_stops', 'leads'];
  for (const d of dormant) {
    if (!present.has(d)) { console.log(`  ⚠️  ${d} not in DB (should exist as empty table until Odoo cutover)`); continue; }
    const c = exactCounts[d];
    if (c === 0) console.log(`  ✅ ${d} present and empty`);
    else console.log(`  ⚠️  ${d} present but has ${c} rows — should be 0`);
  }

  process.exit(0);
})().catch(e => { console.error(e); process.exit(1); });
