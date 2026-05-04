// ============================================================================
// jobber_completeness_check.js — find Jobber records missing from our DB
//
// Walks Jobber's GraphQL for clients / jobs / visits / invoices, gets every
// GID, then diffs against our entity_source_links to see what's in Jobber
// but not in our DB. Critical to run before May sunset — once Jobber's gone,
// missed records are gone with it.
//
// Read-only. Reports a CSV of gaps for manual review or automated replay.
//
// Usage:
//   node scripts/probes/jobber_completeness_check.js [--entity=visits|invoices|jobs|clients]
// ============================================================================

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const fs = require('fs');
const path = require('path');

const ENTITY_FILTER = (process.argv.find(a => a.startsWith('--entity=')) || '').split('=')[1] || null;

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej); req.setTimeout(60000, () => req.destroy(new Error('timeout')));
    if (body) req.write(body); req.end();
  });
}
async function pg(sql) {
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
  }, JSON.stringify({ query: sql }));
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.slice(0, 200)}`);
  return JSON.parse(r.body);
}
async function gql(query, variables, retries = 5) {
  const body = JSON.stringify({ query, variables });
  const r = await http({
    hostname: 'api.getjobber.com', path: '/api/graphql', method: 'POST',
    headers: {
      Authorization: `Bearer ${process.env.JOBBER_ACCESS_TOKEN}`,
      'X-JOBBER-GRAPHQL-VERSION': '2026-04-13',
      'Content-Type': 'application/json',
    },
  }, body);
  if (r.status >= 300) {
    if (retries > 0 && (r.status === 429 || r.status >= 500)) {
      await new Promise(rs => setTimeout(rs, (6 - retries) * 4000));
      return gql(query, variables, retries - 1);
    }
    throw new Error(`Jobber ${r.status}: ${r.body.slice(0, 200)}`);
  }
  const j = JSON.parse(r.body);
  if (j.errors) {
    if (j.errors.some(e => e.extensions?.code === 'THROTTLED') && retries > 0) {
      await new Promise(rs => setTimeout(rs, (6 - retries) * 5000));
      return gql(query, variables, retries - 1);
    }
    throw new Error(`Jobber GQL: ${JSON.stringify(j.errors).slice(0, 300)}`);
  }
  // Pace
  const remaining = j.extensions?.cost?.throttleStatus?.currentlyAvailable;
  if (remaining != null && remaining < 4000) {
    await new Promise(rs => setTimeout(rs, Math.ceil((4000 - remaining) / 500) * 1000));
  }
  return j.data;
}

// ---- Entity definitions: each is paginated via Jobber's connection pattern -

const ENTITIES = {
  clients: {
    query: `query Clients($after: String) { clients(first: 100, after: $after) { nodes { id } pageInfo { hasNextPage endCursor } } }`,
    pluck: d => d.clients,
    esl_type: 'client',
  },
  jobs: {
    query: `query Jobs($after: String) { jobs(first: 50, after: $after) { nodes { id } pageInfo { hasNextPage endCursor } } }`,
    pluck: d => d.jobs,
    esl_type: 'job',
  },
  invoices: {
    query: `query Invoices($after: String) { invoices(first: 50, after: $after) { nodes { id invoiceNumber } pageInfo { hasNextPage endCursor } } }`,
    pluck: d => d.invoices,
    esl_type: 'invoice',
  },
  visits: {
    query: `query Visits($after: String) { visits(first: 50, after: $after, filter: { startAt: { after: "2026-01-01T00:00:00Z" } }) { nodes { id startAt } pageInfo { hasNextPage endCursor } } }`,
    pluck: d => d.visits,
    esl_type: 'visit',
  },
};

(async () => {
  console.log(`Jobber-vs-DB completeness check — ${new Date().toISOString()}`);
  console.log(`Filter: ${ENTITY_FILTER || 'all entities'}\n`);

  const entitiesToCheck = ENTITY_FILTER ? [ENTITY_FILTER] : Object.keys(ENTITIES);
  const reports = [];

  for (const ent of entitiesToCheck) {
    const def = ENTITIES[ent];
    if (!def) { console.log(`  unknown entity: ${ent}`); continue; }

    console.log(`\n=== ${ent.toUpperCase()} ===`);

    // 1. Pull all our DB's Jobber GIDs for this entity
    const dbRows = await pg(`SELECT source_id FROM entity_source_links WHERE entity_type='${def.esl_type}' AND source_system='jobber'`);
    const dbGids = new Set(dbRows.map(r => r.source_id));
    console.log(`  DB has ${dbGids.size} ${ent} GIDs`);

    // 2. Walk Jobber's GraphQL for all GIDs
    console.log(`  Pulling Jobber pages...`);
    const jobberGids = [];
    const extras = []; // optional metadata (e.g. invoice number)
    let cursor = null, page = 0;
    do {
      page++;
      let d;
      try { d = await gql(def.query, { after: cursor }); }
      catch (e) {
        console.log(`  ERR on page ${page}: ${e.message.slice(0, 100)}`);
        break;
      }
      const conn = def.pluck(d);
      if (!conn) { console.log(`  no connection in response`); break; }
      for (const n of conn.nodes) {
        jobberGids.push(n.id);
        if (n.invoiceNumber || n.startAt) extras.push({ gid: n.id, num: n.invoiceNumber, start: n.startAt });
      }
      cursor = conn.pageInfo.hasNextPage ? conn.pageInfo.endCursor : null;
      if (page % 5 === 0) process.stdout.write(`    page ${page}, ${jobberGids.length} so far\r`);
    } while (cursor);
    console.log(`  Jobber has ${jobberGids.length} ${ent} (across ${page} pages)`);

    // 3. Diff
    const gaps = jobberGids.filter(g => !dbGids.has(g));
    const stale = [...dbGids].filter(g => !jobberGids.includes(g));
    console.log(`  ❌ ${gaps.length} in Jobber but NOT in our DB`);
    console.log(`  ⚠️  ${stale.length} in our DB but NOT in Jobber (deleted upstream — may be stale ESL)`);

    // 4. Sample gaps with context
    if (gaps.length > 0) {
      console.log(`  Sample gaps (up to 10):`);
      const extrasMap = new Map(extras.map(e => [e.gid, e]));
      for (const g of gaps.slice(0, 10)) {
        const numericId = Buffer.from(g, 'base64').toString().split('/').pop();
        const meta = extrasMap.get(g);
        const metaStr = meta?.num ? ` invoice#${meta.num}` : meta?.start ? ` startAt=${meta.start}` : '';
        console.log(`    ${g.slice(-12)} (${numericId})${metaStr}`);
      }
    }

    reports.push({ entity: ent, jobber_total: jobberGids.length, db_total: dbGids.size, gaps: gaps.length, stale: stale.length });

    // 5. Save full gap list to CSV
    if (gaps.length > 0) {
      const csv = ['jobber_gid,numeric_id,extra'];
      const extrasMap = new Map(extras.map(e => [e.gid, e]));
      for (const g of gaps) {
        const numericId = Buffer.from(g, 'base64').toString().split('/').pop();
        const meta = extrasMap.get(g);
        const extra = meta?.num || meta?.start || '';
        csv.push(`${g},${numericId},"${extra}"`);
      }
      const fname = `jobber_gaps_${ent}_${new Date().toISOString().slice(0,10)}.csv`;
      fs.writeFileSync(path.resolve(__dirname, '../..', fname), csv.join('\n'), 'utf8');
      console.log(`  → wrote ${fname}`);
    }
  }

  // Final summary
  console.log(`\n${'='.repeat(72)}\nSUMMARY\n${'='.repeat(72)}`);
  console.log(`  entity     | jobber  | db     | gaps   | stale`);
  console.log(`  -----------|---------|--------|--------|------`);
  for (const r of reports) {
    console.log(`  ${r.entity.padEnd(11)}| ${String(r.jobber_total).padStart(7)} | ${String(r.db_total).padStart(6)} | ${String(r.gaps).padStart(6)} | ${String(r.stale).padStart(5)}`);
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
