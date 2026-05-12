// Retrospective analysis on the 3 open items, using only data already in DB.
// (1) Inspection sync lag: WHERE is the delay (source vs webhook vs DB)?
// (2) inspections_with_truck: would the JOIN actually resolve for most rows?
// (3) Pinned-note photos: how many clients, how many photos, distribution?

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c) }));
    });
    req.on('error', rej); if (body) req.write(body); req.end();
  });
}
async function pg(sql) {
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
  }, JSON.stringify({ query: sql }));
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.toString().slice(0, 300)}`);
  return JSON.parse(r.body.toString());
}
async function pgRetry(sql, retries = 3) {
  for (let i = 0; i < retries; i++) {
    try { return await pg(sql); }
    catch (e) {
      if (i === retries - 1) throw e;
      console.log(`  (retry ${i+1}/${retries-1} after error: ${e.message.slice(0, 80)})`);
      await new Promise(r => setTimeout(r, 2000));
    }
  }
}
async function safeSection(name, fn) {
  try { await fn(); }
  catch (e) { console.log(`\n[${name}] FAILED: ${e.message.slice(0, 200)}\n`); }
}

(async () => {
  console.log('=================================================================');
  console.log('RETRO #1 — Inspection sync lag analysis');
  console.log('=================================================================\n');

  // 1a. Distribution of (created_at - submitted_at) lag
  const lagDist = await pgRetry(`
    SELECT
      CASE
        WHEN diff_h < 1     THEN 'A: <1h'
        WHEN diff_h < 6     THEN 'B: 1-6h'
        WHEN diff_h < 12    THEN 'C: 6-12h'
        WHEN diff_h < 24    THEN 'D: 12-24h'
        WHEN diff_h < 48    THEN 'E: 24-48h'
        WHEN diff_h < 168   THEN 'F: 2-7d'
        ELSE                     'G: 7d+'
      END AS bucket,
      COUNT(*) AS n
    FROM (
      SELECT EXTRACT(EPOCH FROM (created_at - submitted_at)) / 3600.0 AS diff_h
      FROM inspections
      WHERE submitted_at IS NOT NULL AND created_at IS NOT NULL
    ) t
    GROUP BY bucket ORDER BY bucket;
  `);
  console.log('Lag distribution (created_at − submitted_at):');
  for (const r of lagDist) console.log(`  ${r.bucket.padEnd(10)} → ${r.n} inspections`);

  // 1b. Last 14 days — are recent ones getting better or worse?
  const recent = await pgRetry(`
    SELECT
      submitted_at::date AS submitted_date,
      COUNT(*) AS n,
      ROUND(AVG(EXTRACT(EPOCH FROM (created_at - submitted_at)) / 3600.0)::numeric, 1) AS avg_lag_h,
      ROUND(MIN(EXTRACT(EPOCH FROM (created_at - submitted_at)) / 3600.0)::numeric, 1) AS min_lag_h,
      ROUND(MAX(EXTRACT(EPOCH FROM (created_at - submitted_at)) / 3600.0)::numeric, 1) AS max_lag_h
    FROM inspections
    WHERE submitted_at >= now() - interval '14 days'
    GROUP BY 1 ORDER BY 1 DESC;
  `);
  console.log('\nLast 14 days, lag per submission day (hours):');
  console.log('  submitted_date  n   avg_lag   min   max');
  for (const r of recent) {
    console.log(`  ${r.submitted_date}    ${String(r.n).padStart(2)}  ${String(r.avg_lag_h).padStart(6)}    ${String(r.min_lag_h).padStart(4)}  ${String(r.max_lag_h).padStart(4)}`);
  }

  // 1c. webhook_events_log timing — when did the webhook fire vs when did row land?
  const wh = await pgRetry(`
    SELECT
      i.id AS insp_id,
      i.submitted_at::text AS submitted,
      i.created_at::text AS row_created,
      wel.created_at::text AS webhook_received,
      ROUND(EXTRACT(EPOCH FROM (i.created_at - wel.created_at))::numeric, 1) AS row_after_webhook_sec,
      ROUND(EXTRACT(EPOCH FROM (wel.created_at - i.submitted_at)) / 3600.0::numeric, 1) AS webhook_after_submitted_h
    FROM inspections i
    LEFT JOIN webhook_events_log wel
      ON wel.source_system = 'airtable'
      AND wel.entity_type = 'inspection'
      AND wel.entity_id::bigint = i.id
    WHERE i.submitted_at >= now() - interval '5 days'
      AND wel.id IS NOT NULL
    ORDER BY i.submitted_at DESC LIMIT 20;
  `);
  console.log('\nWebhook timing per recent inspection (hours from submission to webhook receipt):');
  if (wh.length === 0) {
    console.log('  (no webhook_events_log rows linked to inspections — webhook may not record entity_id, or sync uses polling)');
  } else {
    for (const r of wh) {
      console.log(`  insp ${r.insp_id}: submitted=${r.submitted.slice(0,16)}  webhook=${r.webhook_received?.slice(0,16) || '?'}  row+webhook_lag=${r.row_after_webhook_sec}s  webhook_after_submit=${r.webhook_after_submitted_h}h`);
    }
  }

  // 1d. ALL airtable webhook events recently — see if they're firing at all
  const whAir = await pgRetry(`
    SELECT
      DATE_TRUNC('hour', created_at) AS hour,
      COUNT(*) AS n
    FROM webhook_events_log
    WHERE source_system = 'airtable'
      AND created_at >= now() - interval '48 hours'
    GROUP BY 1 ORDER BY 1 DESC LIMIT 20;
  `);
  console.log('\nAirtable webhook events per hour (last 48h):');
  for (const r of whAir) console.log(`  ${r.hour}  ×${r.n}`);

  console.log('\n=================================================================');
  console.log('RETRO #2 — inspections_with_truck JOIN coverage');
  console.log('=================================================================\n');

  // inspections has employee_id + shift_date but NO visit_id. Truck attribution
  // path: inspection → visit_assignments(employee_id, visit on shift_date) → visits.vehicle_id → vehicles.
  const coverage = await pgRetry(`
    WITH per_inspection AS (
      SELECT
        i.id AS inspection_id,
        COUNT(DISTINCT v.vehicle_id) FILTER (WHERE v.vehicle_id IS NOT NULL) AS distinct_trucks
      FROM inspections i
      LEFT JOIN visit_assignments va ON va.employee_id = i.employee_id
      LEFT JOIN visits v ON v.id = va.visit_id AND v.visit_date = i.shift_date
      GROUP BY i.id
    )
    SELECT
      COUNT(*) AS total_inspections,
      COUNT(*) FILTER (WHERE distinct_trucks >= 1) AS truck_resolves_at_least_one,
      COUNT(*) FILTER (WHERE distinct_trucks = 1) AS truck_resolves_unambiguously,
      COUNT(*) FILTER (WHERE distinct_trucks > 1) AS multiple_trucks_same_shift,
      COUNT(*) FILTER (WHERE distinct_trucks = 0) AS no_match_at_all
    FROM per_inspection;
  `);
  const c = coverage[0];
  console.log(`Total inspections:                ${c.total_inspections}`);
  console.log(`  Truck resolves (any match):     ${c.truck_resolves_at_least_one}`);
  console.log(`  Truck resolves unambiguously:   ${c.truck_resolves_unambiguously}  ← safe to auto-attribute`);
  console.log(`  Multiple trucks same shift:     ${c.multiple_trucks_same_shift}  ← ambiguous (review)`);
  console.log(`  No matching visit at all:       ${c.no_match_at_all}  ← no attribution possible`);
  const safePct = (c.truck_resolves_unambiguously / c.total_inspections * 100).toFixed(1);
  console.log(`  → ${safePct}% can show a truck name with confidence`);

  console.log('\n=================================================================');
  console.log('RETRO #3 — Pinned-note photo distribution');
  console.log('=================================================================\n');

  // Note: our DB doesn't store pinned flag (we rely on Jobber's), so we can't
  // count pinned vs unpinned in our DB. Instead, count notes that are linked
  // to MULTIPLE visits — those are likely pinned (Jobber attaches them to
  // every visit on the job).
  const pinnedProxy = await pgRetry(`
    WITH note_visit_counts AS (
      SELECT n.id AS note_id, COUNT(DISTINCT v.id) AS visits_linked
      FROM notes n
      LEFT JOIN photo_links plv ON plv.entity_type='visit' AND plv.entity_id IN (
        SELECT pl.entity_id FROM photo_links pl
        WHERE pl.entity_type='note' AND pl.entity_id = n.id
      )
      LEFT JOIN visits v ON v.id = plv.entity_id
      GROUP BY n.id
    )
    SELECT
      CASE WHEN visits_linked >= 3 THEN '3+ (very likely pinned/location)'
           WHEN visits_linked = 2  THEN '2 (possibly pinned)'
           WHEN visits_linked = 1  THEN '1 (visit-specific)'
           ELSE '0 (no visit link)'
      END AS bucket,
      COUNT(*) AS n_notes
    FROM note_visit_counts
    GROUP BY bucket ORDER BY bucket;
  `);
  console.log('Notes by visit-link count (proxy for pinned/location-level):');
  for (const r of pinnedProxy) console.log(`  ${r.bucket.padEnd(40)} ${r.n_notes}`);

  // Top clients with the most likely-pinned photos
  const topClients = await pgRetry(`
    SELECT
      c.client_code,
      c.name,
      COUNT(DISTINCT p.id) AS distinct_photos,
      COUNT(DISTINCT n.id) AS distinct_notes
    FROM photo_links pl_n
    JOIN notes n ON n.id = pl_n.entity_id AND pl_n.entity_type = 'note'
    JOIN photos p ON p.id = pl_n.photo_id
    JOIN photo_links pl_v ON pl_v.photo_id = p.id AND pl_v.entity_type = 'visit'
    JOIN visits v ON v.id = pl_v.entity_id
    JOIN clients c ON c.id = v.client_id
    WHERE EXISTS (
      SELECT 1 FROM photo_links pl_v2 WHERE pl_v2.photo_id = p.id AND pl_v2.entity_type = 'visit'
      GROUP BY pl_v2.photo_id HAVING COUNT(*) >= 3
    )
    GROUP BY c.client_code, c.name
    ORDER BY distinct_photos DESC
    LIMIT 15;
  `);
  console.log('\nTop 15 clients with photos linked to 3+ visits (likely location-level):');
  for (const r of topClients) {
    console.log(`  ${(r.client_code || '?').padEnd(8)} ${(r.name || '').slice(0, 30).padEnd(32)} photos=${r.distinct_photos}  notes=${r.distinct_notes}`);
  }
})();
