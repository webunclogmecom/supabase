// Pull EVERY Jobber visit with full attribution fields, then thoroughly
// cross-reference against our 2,081 AT-only visits. Writes the full pull
// to ./jobber_visits_full.json so we can reuse for the backfill step.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const fs = require('fs');

const PROJECT = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const JOBBER_TOKEN = process.env.JOBBER_ACCESS_TOKEN;
const JOBBER_API_VERSION = '2026-04-13';
const PAGE_SIZE = 25;
const BUDGET_FLOOR = 2000;  // pause when budget < this

function http(opts, body, timeoutMs = 60000) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      let d = ''; r.on('data', c => d += c);
      r.on('end', () => res({ status: r.statusCode, body: d, headers: r.headers }));
    });
    req.on('error', rej);
    req.setTimeout(timeoutMs, () => req.destroy(new Error('timeout')));
    if (body) req.write(body);
    req.end();
  });
}

async function pg(sql) {
  const body = JSON.stringify({ query: sql });
  const r = await http({
    hostname: 'api.supabase.com', path: `/v1/projects/${PROJECT}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
  }, body);
  if (r.status >= 300) throw new Error(`DB ${r.status}: ${r.body.slice(0,200)}`);
  return JSON.parse(r.body);
}

async function gql(query, variables, retries = 5) {
  const body = JSON.stringify({ query, variables });
  const r = await http({
    hostname: 'api.getjobber.com', path: '/api/graphql', method: 'POST',
    headers: {
      Authorization: `Bearer ${JOBBER_TOKEN}`,
      'X-JOBBER-GRAPHQL-VERSION': JOBBER_API_VERSION,
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
    },
  }, body);
  if (r.status >= 300) {
    if (retries > 0 && (r.status === 429 || r.status >= 500)) {
      const wait = (6 - retries) * 4000;
      process.stdout.write(`(HTTP ${r.status}, sleep ${wait}ms) `);
      await new Promise(rs => setTimeout(rs, wait));
      return gql(query, variables, retries - 1);
    }
    throw new Error(`Jobber ${r.status}: ${r.body.slice(0,300)}`);
  }
  const json = JSON.parse(r.body);
  // GraphQL-level throttle: errors[].extensions.code === 'THROTTLED'
  if (json.errors) {
    const isThrottle = json.errors.some(e => e.extensions?.code === 'THROTTLED');
    if (isThrottle && retries > 0) {
      const wait = (6 - retries) * 5000;
      process.stdout.write(`(THROTTLED, sleep ${wait}ms) `);
      await new Promise(rs => setTimeout(rs, wait));
      return gql(query, variables, retries - 1);
    }
    throw new Error(`Jobber GQL: ${JSON.stringify(json.errors).slice(0,300)}`);
  }
  // Budget pause
  const remaining = json.extensions?.cost?.throttleStatus?.currentlyAvailable;
  if (remaining != null && remaining < BUDGET_FLOOR) {
    const wait = Math.ceil((BUDGET_FLOOR - remaining) / 500) * 1000;
    process.stdout.write(`(budget low: ${remaining}, sleep ${wait}ms) `);
    await new Promise(rs => setTimeout(rs, wait));
  }
  return json.data;
}

const Q_VISITS = `
  query AllVisits($after: String, $first: Int!) {
    visits(after: $after, first: $first) {
      pageInfo { hasNextPage endCursor }
      nodes {
        id title startAt endAt completedAt visitStatus completedBy
        client { id }
        job { id }
        assignedUsers { nodes { id name { full } } }
      }
    }
  }
`;

(async () => {
  const startMs = Date.now();
  console.log('========================================================');
  console.log('  Thorough Jobber visits re-pull + cross-reference');
  console.log('========================================================');

  // ========== Phase 1: pull every Jobber visit ==========
  console.log('\n[Phase 1] Pulling all Jobber visits...');
  const all = [];
  let cursor = null, page = 0;
  while (true) {
    page++;
    const d = await gql(Q_VISITS, { after: cursor, first: PAGE_SIZE });
    const conn = d.visits;
    if (!conn) break;
    all.push(...conn.nodes);
    if (page % 20 === 0) {
      const sec = Math.round((Date.now() - startMs) / 1000);
      console.log(`  page ${page}: ${all.length} total · ${sec}s elapsed`);
    }
    if (!conn.pageInfo.hasNextPage) break;
    cursor = conn.pageInfo.endCursor;
  }
  console.log(`  ✓ Pulled ${all.length} visits in ${Math.round((Date.now() - startMs)/1000)}s`);

  fs.writeFileSync('./jobber_visits_full.json', JSON.stringify(all, null, 2));
  console.log(`  Saved to ./jobber_visits_full.json (${(JSON.stringify(all).length / 1024 / 1024).toFixed(1)} MB)`);

  // ========== Phase 2: build per-client visit index ==========
  console.log('\n[Phase 2] Building per-client visit index...');
  const byClientGid = new Map();  // jobber_client_gid → [{visit_gid, date, completedBy, assignedUsers}]
  for (const v of all) {
    const cgid = v.client?.id;
    if (!cgid) continue;
    if (!byClientGid.has(cgid)) byClientGid.set(cgid, []);
    byClientGid.get(cgid).push({
      gid: v.id,
      date: v.startAt ? v.startAt.slice(0, 10) : null,
      completedAt: v.completedAt,
      completedBy: v.completedBy,
      visitStatus: v.visitStatus,
      assignedUsers: v.assignedUsers?.nodes || [],
    });
  }
  console.log(`  ${byClientGid.size} clients have visits in Jobber`);

  // ========== Phase 3: pull AT-only visits + their client Jobber GIDs ==========
  console.log('\n[Phase 3] Pulling AT-only visits from our DB...');
  const atOnly = await pg(`
    SELECT v.id AS our_visit_id, v.visit_date::text AS visit_date,
           v.client_id, c.client_code, c.name AS client_name,
           (SELECT source_id FROM entity_source_links WHERE entity_type='client' AND source_system='jobber' AND entity_id=v.client_id LIMIT 1) AS client_jobber_gid,
           (SELECT source_id FROM entity_source_links WHERE entity_type='visit'  AND source_system='airtable' AND entity_id=v.id LIMIT 1) AS at_id
    FROM visits v
    LEFT JOIN clients c ON c.id = v.client_id
    WHERE EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='airtable')
      AND NOT EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='jobber')
    ORDER BY v.visit_date;
  `);
  console.log(`  ${atOnly.length} AT-only visits to cross-reference`);

  // ========== Phase 4: thorough match ==========
  console.log('\n[Phase 4] Cross-referencing with various date windows...');
  const windows = [0, 1, 2, 3, 7, 14, 30];
  const buckets = {};
  for (const w of windows) buckets[w] = { salvage: [], phantom: [] };

  let noClientLink = 0;
  for (const av of atOnly) {
    if (!av.client_jobber_gid) {
      for (const w of windows) buckets[w].phantom.push(av);
      noClientLink++;
      continue;
    }
    const candidates = byClientGid.get(av.client_jobber_gid) || [];
    const ourDate = new Date(av.visit_date + 'T00:00:00Z');
    let bestDelta = Infinity, bestMatch = null;
    for (const c of candidates) {
      if (!c.date) continue;
      const cDate = new Date(c.date + 'T00:00:00Z');
      const delta = Math.abs((cDate - ourDate) / (1000 * 60 * 60 * 24));
      if (delta < bestDelta) { bestDelta = delta; bestMatch = c; }
    }
    for (const w of windows) {
      if (bestMatch && bestDelta <= w) buckets[w].salvage.push({ ...av, jobber_match: bestMatch, delta: bestDelta });
      else buckets[w].phantom.push(av);
    }
  }

  console.log('\n  Match rates by date window:');
  console.table(windows.map(w => ({
    window: `±${w}d`,
    salvageable: buckets[w].salvage.length,
    phantom: buckets[w].phantom.length,
  })));
  console.log(`  AT-only visits with no Jobber-linked client: ${noClientLink}`);

  // ========== Phase 5: salvage breakdown for ±2d window ==========
  console.log('\n[Phase 5] Recommended ±2d window — salvage details');
  const salvage2 = buckets[2].salvage;
  const phantom2 = buckets[2].phantom;
  console.log(`  Salvageable: ${salvage2.length}`);
  console.log(`  Phantom:     ${phantom2.length}`);

  console.log('\n  Salvage delta distribution:');
  const deltaHist = {};
  for (const s of salvage2) {
    const d = s.delta.toFixed(0);
    deltaHist[d] = (deltaHist[d] || 0) + 1;
  }
  console.table(Object.entries(deltaHist).map(([d, n]) => ({ delta_days: d, count: n })));

  console.log('\n  Phantom by year:');
  const phantomYear = {};
  for (const p of phantom2) {
    const y = p.visit_date?.slice(0, 4) || '?';
    phantomYear[y] = (phantomYear[y] || 0) + 1;
  }
  console.table(Object.entries(phantomYear).sort().map(([y, n]) => ({ year: y, count: n })));

  // ========== Phase 6: write salvage + phantom plans for next step ==========
  fs.writeFileSync('./at_only_salvage.json', JSON.stringify(salvage2, null, 2));
  fs.writeFileSync('./at_only_phantom.json', JSON.stringify(phantom2, null, 2));
  console.log('\n  Saved ./at_only_salvage.json and ./at_only_phantom.json');

  console.log('\n========================================================');
  console.log(`  Done in ${Math.round((Date.now() - startMs) / 1000)}s`);
  console.log('========================================================');
})().catch(e => { console.error('FATAL:', e.message, e.stack); process.exit(1); });
