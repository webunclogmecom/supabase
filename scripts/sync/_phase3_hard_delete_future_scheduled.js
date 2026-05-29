// scripts/sync/_phase3_hard_delete_future_scheduled.js
//
// Phase 3 of the 2026-05-29 cleanup directive (per Fred):
// "remove all upcoming visits that are scheduled from Monday 6/1 onwards.
//  Keep the scheduled visits from Sunday 5/31 and older."
//
// Hard-deletes every row in public.visits where:
//   visit_date >= '2026-06-01' AND visit_status = 'scheduled'
//
// Procedure:
//   1. Count target rows + show breakdown by source (jobber-linked vs not)
//   2. Detach soft refs (notes, jobber_oversized_attachments → set visit_id=NULL)
//   3. Delete entity_source_links rows for those visits
//   4. Bulk DELETE the visit rows (CASCADE clears visit_assignments,
//      manifest_visits, visit_recommendations)
//   5. Audit trigger captures every deletion (full-row JSONB) with
//      app_source='sql' attribution.
//
// CLI:
//   node scripts/sync/_phase3_hard_delete_future_scheduled.js              # dry-run
//   node scripts/sync/_phase3_hard_delete_future_scheduled.js --execute    # apply

const path = require('path');
const https = require('https');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const PAT = process.env.SUPABASE_PAT;
const PROJECT = process.env.SUPABASE_PROJECT_ID;
const EXECUTE = process.argv.includes('--execute');

const CUTOFF = '2026-06-01';  // visit_date >= this AND visit_status='scheduled' gets deleted

function request({ host, path, method = 'GET', headers = {}, body = null }) {
  return new Promise((resolve, reject) => {
    const payload = body == null ? null : (typeof body === 'string' ? body : JSON.stringify(body));
    const req = https.request({ hostname: host, path, method, headers: { ...headers, ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}) } }, (res) => {
      let d = ''; res.on('data', c => (d += c));
      res.on('end', () => resolve({ status: res.statusCode, body: d }));
    });
    req.on('error', reject);
    req.setTimeout(120_000, () => req.destroy(new Error('timeout')));
    if (payload) req.write(payload);
    req.end();
  });
}

async function pg(sql) {
  const r = await request({
    host: 'api.supabase.com', path: `/v1/projects/${PROJECT}/database/query`, method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql }),
  });
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.slice(0, 400)}`);
  return JSON.parse(r.body);
}

(async () => {
  console.log(`\n=== PHASE 3: hard-delete scheduled visits >= ${CUTOFF} (${EXECUTE ? 'EXECUTE' : 'DRY-RUN'}) ===\n`);

  // 1. Count + breakdown
  const counts = await pg(`
    SELECT
      COUNT(*)::int AS total,
      COUNT(*) FILTER (WHERE id IN (SELECT entity_id FROM public.entity_source_links WHERE entity_type='visit' AND source_system='jobber'))::int AS jobber_linked,
      COUNT(*) FILTER (WHERE source = 'jobber')::int AS source_jobber,
      COUNT(*) FILTER (WHERE source = 'supabase_cron')::int AS source_cron,
      COUNT(*) FILTER (WHERE source = 'airtable')::int AS source_at,
      COUNT(*) FILTER (WHERE source = 'manual')::int AS source_manual,
      MIN(visit_date) AS first_date,
      MAX(visit_date) AS last_date
    FROM public.visits
    WHERE visit_date >= '${CUTOFF}' AND visit_status = 'scheduled';
  `);
  const c = counts[0];
  console.log(`Target rows: ${c.total}`);
  console.log(`  jobber-linked (ESL): ${c.jobber_linked}`);
  console.log(`  by source: jobber=${c.source_jobber}, supabase_cron=${c.source_cron}, airtable=${c.source_at}, manual=${c.source_manual}`);
  console.log(`  date range: ${c.first_date} → ${c.last_date}\n`);

  // 2. Check soft-ref counts
  const softRefs = await pg(`
    SELECT
      (SELECT COUNT(*)::int FROM public.notes WHERE visit_id IN (SELECT id FROM public.visits WHERE visit_date >= '${CUTOFF}' AND visit_status='scheduled')) AS notes,
      (SELECT COUNT(*)::int FROM public.jobber_oversized_attachments WHERE visit_id IN (SELECT id FROM public.visits WHERE visit_date >= '${CUTOFF}' AND visit_status='scheduled')) AS oversized;
  `);
  console.log(`Soft refs to detach: notes=${softRefs[0].notes}, oversized_attachments=${softRefs[0].oversized}\n`);

  // 3. Show breakdown by client
  const byClient = await pg(`
    SELECT c.client_code, c.name, COUNT(*)::int AS n
    FROM public.visits v
    JOIN public.clients c ON c.id = v.client_id
    WHERE v.visit_date >= '${CUTOFF}' AND v.visit_status = 'scheduled'
    GROUP BY c.client_code, c.name
    ORDER BY n DESC
    LIMIT 15;
  `);
  console.log('Top 15 clients by impact:');
  for (const r of byClient) console.log(`  ${r.client_code || '?'}: ${r.name} (${r.n} visits)`);

  if (!EXECUTE) {
    console.log(`\n(dry-run; pass --execute to hard-delete ${c.total} row(s))`);
    return;
  }

  console.log(`\n=== Executing hard-delete ===`);

  // 4. Detach soft refs
  if (softRefs[0].notes > 0) {
    await pg(`UPDATE public.notes SET visit_id = NULL WHERE visit_id IN (SELECT id FROM public.visits WHERE visit_date >= '${CUTOFF}' AND visit_status='scheduled');`);
    console.log(`  Detached ${softRefs[0].notes} notes from target visits`);
  }
  if (softRefs[0].oversized > 0) {
    await pg(`UPDATE public.jobber_oversized_attachments SET visit_id = NULL WHERE visit_id IN (SELECT id FROM public.visits WHERE visit_date >= '${CUTOFF}' AND visit_status='scheduled');`);
    console.log(`  Detached ${softRefs[0].oversized} oversized attachments from target visits`);
  }

  // 5. Drop ESL rows for those visits
  const eslDel = await pg(`DELETE FROM public.entity_source_links WHERE entity_type='visit' AND entity_id IN (SELECT id FROM public.visits WHERE visit_date >= '${CUTOFF}' AND visit_status='scheduled') RETURNING id;`);
  console.log(`  Deleted ${eslDel.length} entity_source_links rows`);

  // 6. Bulk DELETE visits (CASCADE clears child rows)
  const visitDel = await pg(`DELETE FROM public.visits WHERE visit_date >= '${CUTOFF}' AND visit_status='scheduled' RETURNING id, visit_date, title;`);
  console.log(`  Deleted ${visitDel.length} visits`);

  console.log(`\nDone. Removed ${visitDel.length} future-scheduled visits.`);
  console.log('--- audit complete --- {"probe":"phase3_hard_delete_future_scheduled","target_count":' + c.total + ',"deleted":' + visitDel.length + '}');
})().catch(e => { console.error(e); process.exit(1); });
