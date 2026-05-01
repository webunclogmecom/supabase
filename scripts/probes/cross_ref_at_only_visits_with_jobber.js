// Step 1 — read-only audit. For the 2,081 Airtable-only visits, decide which
// have a Jobber counterpart we can salvage by linking, vs which are pure
// phantoms from Airtable's projection logic.
//
// Strategy:
//   1. Bucket all 2,081 by sanity:
//        - junk: visit_date = '1970-01-01' (NULL → epoch)
//        - future: visit_date >= today  (Airtable's auto-generated projections)
//        - past:  visit_date in [Jobber-go-live, today]  (worth checking)
//   2. For past visits only, query Jobber per-client and try to match by
//      (client + date ±2 days).
//   3. Output: counts per bucket + a CSV-able sample for follow-up.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROJECT = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const JOBBER_TOKEN = process.env.JOBBER_ACCESS_TOKEN;
const JOBBER_API_VERSION = '2026-04-13';
const DATE_WINDOW_DAYS = 2;     // visit can match if Jobber visit is within ±N days

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      let d = ''; r.on('data', c => d += c);
      r.on('end', () => res({ status: r.statusCode, body: d }));
    });
    req.on('error', rej);
    req.setTimeout(30000, () => req.destroy(new Error('timeout')));
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

async function jobberGQL(query, variables) {
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
  if (r.status >= 300) throw new Error(`Jobber ${r.status}: ${r.body.slice(0,200)}`);
  const json = JSON.parse(r.body);
  if (json.errors) throw new Error(`Jobber: ${JSON.stringify(json.errors).slice(0,200)}`);
  return json.data;
}

const Q_CLIENT_VISITS = `
  query ClientVisits($id: EncodedId!, $after: String) {
    client(id: $id) {
      visits(first: 50, after: $after) {
        nodes { id startAt endAt visitStatus }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
`;

(async () => {
  console.log('=== Bucketing 2,081 Airtable-only visits by date sanity ===\n');
  const buckets = await pg(`
    WITH at_only AS (
      SELECT v.id, v.visit_date, v.client_id
      FROM visits v
      WHERE EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='airtable')
        AND NOT EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='jobber')
    )
    SELECT
      CASE
        WHEN visit_date < '2023-01-01'           THEN '1.junk_pre_jobber_or_epoch'
        WHEN visit_date < CURRENT_DATE - INTERVAL '14 days' THEN '2.past_old (>14d ago)'
        WHEN visit_date < CURRENT_DATE           THEN '3.past_recent (last 14d)'
        WHEN visit_date <= CURRENT_DATE + INTERVAL '14 days' THEN '4.near_future (next 14d)'
        ELSE                                          '5.far_future (>14d ahead)'
      END AS bucket,
      COUNT(*) AS n
    FROM at_only
    GROUP BY bucket ORDER BY bucket;
  `);
  console.table(buckets);

  // Past visits — these are the only ones where a Jobber match is possible
  console.log('\n=== Pulling distinct (client_id, visit_date) for PAST Airtable-only visits ===');
  const pastVisits = await pg(`
    SELECT v.id, v.visit_date::text AS visit_date, v.client_id, c.client_code, c.name AS client_name,
           (SELECT source_id FROM entity_source_links
            WHERE entity_type='client' AND source_system='jobber' AND entity_id=v.client_id LIMIT 1) AS client_jobber_gid
    FROM visits v
    JOIN clients c ON c.id = v.client_id
    WHERE EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='airtable')
      AND NOT EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='jobber')
      AND v.visit_date >= '2023-01-01'
      AND v.visit_date < CURRENT_DATE
    ORDER BY v.client_id, v.visit_date;
  `);
  console.log(`  ${pastVisits.length} past visits to cross-reference\n`);

  // Group by client
  const byClient = new Map();
  for (const v of pastVisits) {
    if (!v.client_jobber_gid) continue;
    if (!byClient.has(v.client_jobber_gid)) byClient.set(v.client_jobber_gid, { code: v.client_code, name: v.client_name, visits: [] });
    byClient.get(v.client_jobber_gid).visits.push(v);
  }
  console.log(`  Clients with Jobber link: ${byClient.size}`);
  console.log(`  Past visits without client_jobber_gid (un-checkable): ${pastVisits.filter(v => !v.client_jobber_gid).length}\n`);

  // For each client, fetch all their Jobber visits and try to match
  let salvageable = 0, true_phantom_past = 0, errors = 0;
  const salvageSamples = [];
  const phantomSamples = [];
  let i = 0;
  for (const [gid, data] of byClient) {
    i++;
    const ourVisits = data.visits;
    let jobberVisits = [];
    let cursor = null;
    try {
      do {
        const d = await jobberGQL(Q_CLIENT_VISITS, { id: gid, after: cursor });
        const page = d.client?.visits;
        if (!page) break;
        jobberVisits.push(...page.nodes);
        cursor = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : null;
      } while (cursor);
    } catch (e) {
      errors++;
      if (errors <= 3) console.log(`  [${i}/${byClient.size}] ${data.code} ERR: ${e.message.slice(0,80)}`);
      continue;
    }

    // Match each AT visit by date proximity
    for (const ov of ourVisits) {
      const ourDate = new Date(ov.visit_date);
      const match = jobberVisits.find(jv => {
        const jvDate = new Date(jv.startAt);
        const diff = Math.abs((jvDate - ourDate) / (1000 * 60 * 60 * 24));
        return diff <= DATE_WINDOW_DAYS;
      });
      if (match) {
        salvageable++;
        if (salvageSamples.length < 8) {
          salvageSamples.push({
            our_id: ov.id, our_date: ov.visit_date, code: data.code,
            jobber_gid: match.id, jobber_start: match.startAt?.slice(0,10),
            jobber_status: match.visitStatus,
          });
        }
      } else {
        true_phantom_past++;
        if (phantomSamples.length < 8) {
          phantomSamples.push({
            our_id: ov.id, our_date: ov.visit_date, code: data.code,
            jobber_visit_count: jobberVisits.length,
          });
        }
      }
    }

    if (i % 25 === 0) console.log(`  ...${i}/${byClient.size} clients checked`);
    await new Promise(r => setTimeout(r, 150));
  }

  console.log('\n=== Cross-reference results ===');
  console.log(`  Salvageable (has Jobber match within ±${DATE_WINDOW_DAYS}d):  ${salvageable}`);
  console.log(`  True phantom (no Jobber match for that date): ${true_phantom_past}`);
  console.log(`  Clients we couldn't query (no client_jobber_gid): ${pastVisits.filter(v => !v.client_jobber_gid).length}`);
  console.log(`  Per-client query errors: ${errors}`);

  console.log('\n=== Sample of SALVAGEABLE (link to Jobber GID) ===');
  console.table(salvageSamples);

  console.log('\n=== Sample of TRUE PHANTOM (Jobber has no visit for that date) ===');
  console.table(phantomSamples);
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
