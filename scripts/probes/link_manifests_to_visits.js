// Phase 3 — Link existing derm_manifests to completed visits by
// client_id + service_date match (±0 or ±1 day).
//
// Tight window to avoid mismatches. Visits with no nearby manifest stay
// unlinked (those are separate "orphan" cases needing investigation).
//
// Idempotent: INSERT INTO manifest_visits ON CONFLICT DO NOTHING.
//
// Usage:
//   node scripts/probes/link_manifests_to_visits.js              # dry-run
//   node scripts/probes/link_manifests_to_visits.js --execute    # writes
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const EXECUTE = process.argv.includes('--execute');
const PROD = process.env.SUPABASE_PROJECT_ID;
const PAT  = process.env.SUPABASE_PAT;

function http(opts, body) { return new Promise((res, rej) => {
  const req = https.request(opts, r => { const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()})); });
  req.on('error',rej); if(body) req.write(body); req.end();
});}
async function pg(sql) {
  const r = await http({hostname:'api.supabase.com',path:'/v1/projects/'+PROD+'/database/query',method:'POST',headers:{Authorization:'Bearer '+PAT,'Content-Type':'application/json'}}, JSON.stringify({query:sql}));
  if (r.status >= 300) throw new Error('PG '+r.status+': '+r.body.slice(0,400));
  return r.body ? JSON.parse(r.body) : [];
}

(async () => {
  console.log('Mode: ' + (EXECUTE ? 'EXECUTE' : 'DRY-RUN') + '\n');

  // Single LATERAL match — closest service_date per visit, ±1 day tolerance.
  const candidates = await pg(`
    SELECT v.id AS visit_id, v.visit_date::text, v.client_id, c.client_code,
      m.id AS manifest_id, m.service_date::text AS manifest_date, m.day_diff
    FROM visits v
    LEFT JOIN clients c ON c.id = v.client_id
    LEFT JOIN LATERAL (
      SELECT dm.id, dm.service_date, ABS(dm.service_date - v.visit_date) AS day_diff
      FROM derm_manifests dm
      WHERE dm.client_id = v.client_id
        AND dm.service_date BETWEEN v.visit_date - INTERVAL '1 day' AND v.visit_date + INTERVAL '1 day'
      ORDER BY day_diff, dm.id
      LIMIT 1
    ) m ON TRUE
    WHERE v.visit_status = 'completed'
      AND v.client_id IS NOT NULL
      AND v.visit_date >= '2026-01-01'
      AND NOT EXISTS (SELECT 1 FROM manifest_visits mv WHERE mv.visit_id = v.id);
  `);

  const linkable   = candidates.filter(c => c.manifest_id != null);
  const unmatched  = candidates.filter(c => c.manifest_id == null);
  const sameDay    = linkable.filter(c => c.day_diff === 0);
  const oneDayOff  = linkable.filter(c => c.day_diff === 1);

  console.log('Total completed visits without manifest_visits link: ' + candidates.length);
  console.log('  Linkable (±1 day):     ' + linkable.length);
  console.log('    same-day:            ' + sameDay.length);
  console.log('    ±1 day:              ' + oneDayOff.length);
  console.log('  Unmatched (no nearby manifest): ' + unmatched.length);

  console.log('\nSample of linkable visits (first 10):');
  console.table(linkable.slice(0, 10).map(c => ({
    visit_id: c.visit_id,
    visit_date: c.visit_date,
    client: c.client_code,
    manifest_date: c.manifest_date,
    day_diff: c.day_diff,
  })));

  console.log('\nSample of unmatched (first 5) — these stay AWAITING PAPERWORK:');
  console.table(unmatched.slice(0, 5).map(c => ({
    visit_id: c.visit_id, visit_date: c.visit_date, client: c.client_code,
  })));

  if (!EXECUTE) {
    console.log('\n[DRY-RUN] Would INSERT ' + linkable.length + ' rows into manifest_visits. Re-run with --execute.');
    return;
  }

  console.log('\nApplying inserts (batched)...');
  const BATCH = 200;
  let inserted = 0;
  for (let i = 0; i < linkable.length; i += BATCH) {
    const chunk = linkable.slice(i, i+BATCH);
    const values = chunk.map(c => '(' + c.manifest_id + ',' + c.visit_id + ')').join(',');
    await pg('INSERT INTO manifest_visits (manifest_id, visit_id) VALUES ' + values + ' ON CONFLICT DO NOTHING;');
    inserted += chunk.length;
  }
  console.log('Inserted ' + inserted + ' manifest_visits rows.');

  // Verify
  const post = await pg(`
    SELECT to_char(date_trunc('month', v.visit_date), 'YYYY-MM') AS month,
      COUNT(*)::int AS completed,
      COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM manifest_visits mv WHERE mv.visit_id = v.id))::int AS with_manifest,
      ROUND(100.0 * COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM manifest_visits mv WHERE mv.visit_id = v.id)) / COUNT(*))::int AS pct
    FROM visits v WHERE v.visit_status='completed' AND v.visit_date >= '2026-01-01'
    GROUP BY 1 ORDER BY 1 DESC;
  `);
  console.log('\nPost-state — visits with manifest link by month:');
  console.table(post);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
