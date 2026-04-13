// ============================================================================
// incremental_sync.js — Phase 5 delta ingestion loop
// ============================================================================
// For each entity in sync_cursors:
//   1. Read last_synced_at from public.sync_cursors
//   2. Pull updatedAt > last_synced_at from Jobber GraphQL
//   3. Upsert each node into raw.jobber_pull_<entity> with needs_populate=true
//   4. Advance cursor to max(updatedAt) of the delta (or now() on empty delta)
//   5. Record per-entity success/failure independently (no cross-entity coupling)
//
// Flags:
//   --dry-run    (default) prints what would happen, no API calls, no writes
//   --execute    actually hits Jobber API and writes raw.*
//   --entity=X   run only one entity
//   --since=ISO  override last_synced_at for this run (test full backfill)
// ============================================================================

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const { newQuery } = require('../populate/lib/db');

const args = process.argv.slice(2);
const DRY_RUN = !args.includes('--execute');
const ONLY_ENTITY = (args.find(a => a.startsWith('--entity=')) || '').split('=')[1] || null;
const SINCE_OVERRIDE = (args.find(a => a.startsWith('--since=')) || '').split('=')[1] || null;

console.log('='.repeat(70));
console.log('incremental_sync.js');
console.log(`Mode:   ${DRY_RUN ? 'DRY-RUN (no API, no writes)' : 'EXECUTE'}`);
console.log(`Entity: ${ONLY_ENTITY || 'all 8'}`);
if (SINCE_OVERRIDE) console.log(`Since:  ${SINCE_OVERRIDE} (override)`);
console.log('='.repeat(70));

// ----------------------------------------------------------------------------
// Entity definitions: graphql field, raw table, Jobber id key
// ----------------------------------------------------------------------------
// nodeFields is the GraphQL fragment for each entity. Keep minimal but enough
// for populate.js to reconstruct the current normalized columns.
// ----------------------------------------------------------------------------
const ENTITIES = [
  {
    name: 'clients',
    gqlField: 'clients',
    rawTable: 'jobber_pull_clients',
    nodeFields: `
      id
      firstName lastName companyName
      emails { address description }
      phones { number description }
      billingAddress { street city province postalCode country }
      balance
      updatedAt
    `,
  },
  {
    name: 'properties',
    gqlField: 'properties',
    rawTable: 'jobber_pull_properties',
    nodeFields: `
      id
      client { id }
      address { street city province postalCode country }
    `,
  },
  {
    name: 'jobs',
    gqlField: 'jobs',
    rawTable: 'jobber_pull_jobs',
    nodeFields: `
      id jobNumber title
      client { id }
      property { id }
      jobStatus
      startAt endAt
      total
      updatedAt
    `,
  },
  {
    name: 'visits',
    gqlField: 'visits',
    rawTable: 'jobber_pull_visits',
    nodeFields: `
      id
      title
      startAt endAt completedAt
      visitStatus
      client { id }
      job { id }
      invoice { id }
      createdAt
    `,
  },
  {
    name: 'invoices',
    gqlField: 'invoices',
    rawTable: 'jobber_pull_invoices',
    nodeFields: `
      id
      invoiceNumber
      invoiceStatus
      issuedDate dueDate
      subject
      amounts { subtotal total invoiceBalance depositAmount }
      client { id }
      updatedAt
    `,
  },
  {
    name: 'quotes',
    gqlField: 'quotes',
    rawTable: 'jobber_pull_quotes',
    nodeFields: `
      id
      quoteNumber
      quoteStatus
      amounts { subtotal total depositAmount }
      client { id }
      updatedAt
    `,
  },
  {
    name: 'users',
    gqlField: 'users',
    rawTable: 'jobber_pull_users',
    nodeFields: `
      id
      name { first last full }
      email { raw }
      isAccountOwner isAccountAdmin
      createdAt
    `,
  },
  // line_items is special: Jobber exposes it only under jobs / quotes (no
  // top-level connection). Phase 5 handles it by flagging the parent job/quote
  // for re-population rather than a separate pull. Placeholder for later.
  {
    name: 'line_items',
    gqlField: null,
    rawTable: 'jobber_pull_line_items',
    skipReason: 'line items are pulled via parent jobs/quotes; cursor advances via parents',
  },
];

// ----------------------------------------------------------------------------
function sqlEscape(v) {
  if (v === null || v === undefined) return 'NULL';
  if (typeof v === 'number') return String(v);
  if (typeof v === 'boolean') return v ? 'TRUE' : 'FALSE';
  return "'" + String(v).replace(/'/g, "''") + "'";
}

async function getCursor(entity) {
  const r = await newQuery(`SELECT last_synced_at FROM public.sync_cursors WHERE entity='${entity}';`);
  if (!r.length) throw new Error(`cursor row missing for ${entity}`);
  return r[0].last_synced_at;
}

async function markRunning(entity) {
  await newQuery(`
    UPDATE public.sync_cursors
    SET last_run_started=now(), last_run_status='running', last_error=NULL, updated_at=now()
    WHERE entity='${entity}';
  `);
}

async function markSuccess(entity, newCursor, rowsPulled) {
  await newQuery(`
    UPDATE public.sync_cursors
    SET last_synced_at=${sqlEscape(newCursor)},
        last_run_finished=now(),
        last_run_status='success',
        last_error=NULL,
        rows_pulled=${rowsPulled},
        updated_at=now()
    WHERE entity='${sqlEscape(entity).slice(1, -1)}';
  `);
}

async function markFailed(entity, errMsg) {
  await newQuery(`
    UPDATE public.sync_cursors
    SET last_run_finished=now(),
        last_run_status='failed',
        last_error=${sqlEscape(errMsg.slice(0, 1000))},
        updated_at=now()
    WHERE entity='${entity}';
  `);
}

// Batch upsert: DELETE existing by jobber ID, then bulk INSERT
// Splits into batches of 50 to keep SQL payload under Supabase Management API limits
async function batchUpsertRawNodes(rawTable, nodes) {
  const BATCH = 50;
  for (let i = 0; i < nodes.length; i += BATCH) {
    const batch = nodes.slice(i, i + BATCH);
    // DELETE all matching IDs in one call
    const ids = batch.map(n => sqlEscape(n.id)).join(', ');
    await newQuery(`DELETE FROM raw.${rawTable} WHERE data->>'id' IN (${ids});`);
    // INSERT all in one call
    const values = batch.map(n =>
      `(${sqlEscape(JSON.stringify(n))}::jsonb, now(), TRUE)`
    ).join(',\n  ');
    await newQuery(`INSERT INTO raw.${rawTable} (data, ingested_at, needs_populate) VALUES\n  ${values};`);
    if (i + BATCH < nodes.length) {
      console.log(`    batch ${Math.floor(i / BATCH) + 1}/${Math.ceil(nodes.length / BATCH)} (${Math.min(i + BATCH, nodes.length)}/${nodes.length})`);
    }
  }
}

// ----------------------------------------------------------------------------
async function syncEntity(entity) {
  if (entity.skipReason) {
    console.log(`\n[${entity.name}] SKIP — ${entity.skipReason}`);
    return { entity: entity.name, skipped: true, pulled: 0 };
  }

  console.log(`\n[${entity.name}] start`);
  const cursor = SINCE_OVERRIDE || await getCursor(entity.name);
  console.log(`  last_synced_at: ${cursor}`);

  if (DRY_RUN) {
    console.log(`  DRY-RUN: would pull ${entity.gqlField} where updatedAt > ${cursor}`);
    console.log(`  DRY-RUN: would upsert into raw.${entity.rawTable} with needs_populate=TRUE`);
    console.log(`  DRY-RUN: would advance cursor on success`);
    return { entity: entity.name, dryRun: true, pulled: 0 };
  }

  // EXECUTE path — lazy-load jobber client so DRY-RUN never touches the API
  const { pullDelta } = require('./lib/jobber');

  await markRunning(entity.name);
  try {
    const nodes = await pullDelta({
      entityField: entity.gqlField,
      nodeFields: entity.nodeFields,
      updatedAfter: cursor,
    });
    console.log(`  pulled ${nodes.length} delta nodes`);

    // Batch upsert all nodes (50 per API call instead of 1)
    await batchUpsertRawNodes(entity.rawTable, nodes);

    let newCursor = cursor;
    for (const n of nodes) {
      const ts = n._cursorTime || n.updatedAt || n.createdAt;
      if (ts && ts > newCursor) newCursor = ts;
    }
    // If no delta, still advance to now() so we don't re-query the same window forever
    if (nodes.length === 0) newCursor = new Date().toISOString();

    await markSuccess(entity.name, newCursor, nodes.length);
    console.log(`  advanced cursor -> ${newCursor}`);
    return { entity: entity.name, pulled: nodes.length, newCursor };
  } catch (err) {
    console.error(`  FAILED: ${err.message}`);
    await markFailed(entity.name, err.message);
    return { entity: entity.name, failed: true, error: err.message };
  }
}

// ----------------------------------------------------------------------------
(async () => {
  const targets = ONLY_ENTITY
    ? ENTITIES.filter(e => e.name === ONLY_ENTITY)
    : ENTITIES;
  if (!targets.length) {
    console.error(`No entity matches --entity=${ONLY_ENTITY}`);
    process.exit(1);
  }

  const results = [];
  for (const e of targets) {
    results.push(await syncEntity(e));
  }

  console.log('\n' + '='.repeat(70));
  console.log('SUMMARY');
  console.table(results);

  // Downstream: count flagged rows across raw.* so Fred can see what populate would process
  if (!DRY_RUN) {
    const flagged = await newQuery(`
      SELECT 'jobber_pull_clients'    AS t, COUNT(*) FILTER (WHERE needs_populate) AS pending FROM raw.jobber_pull_clients
      UNION ALL SELECT 'jobber_pull_properties', COUNT(*) FILTER (WHERE needs_populate) FROM raw.jobber_pull_properties
      UNION ALL SELECT 'jobber_pull_jobs',       COUNT(*) FILTER (WHERE needs_populate) FROM raw.jobber_pull_jobs
      UNION ALL SELECT 'jobber_pull_visits',     COUNT(*) FILTER (WHERE needs_populate) FROM raw.jobber_pull_visits
      UNION ALL SELECT 'jobber_pull_invoices',   COUNT(*) FILTER (WHERE needs_populate) FROM raw.jobber_pull_invoices
      UNION ALL SELECT 'jobber_pull_quotes',     COUNT(*) FILTER (WHERE needs_populate) FROM raw.jobber_pull_quotes
      UNION ALL SELECT 'jobber_pull_users',      COUNT(*) FILTER (WHERE needs_populate) FROM raw.jobber_pull_users;
    `);
    console.log('\nFlagged for populate:');
    console.table(flagged);
  }

  const failed = results.filter(r => r.failed).length;
  process.exit(failed > 0 ? 1 : 0);
})();
