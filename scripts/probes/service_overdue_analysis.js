// For active/recurring clients with no upcoming visit, classify how overdue
// they are based on (days_since_last_visit / shortest_frequency_days).
//
// Buckets:
//   FRESH       < 0.5x of frequency → not due yet, Diego just hasn't scheduled
//   DUE_SOON    0.5x – 1.0x          → getting close, normal operational backlog
//   OVERDUE     1.0x – 2.0x          → past due, Diego dropped or recently missed
//   ABANDONED?  2.0x – 4.0x          → big gap, probably paused-but-not-marked
//   ABANDONED   > 4.0x or never      → definitely abandoned, mark INACTIVE/PAUSED

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
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
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.slice(0, 200)}`);
  return JSON.parse(r.body);
}

(async () => {
  const rows = await pg(`
    WITH client_health AS (
      SELECT
        c.id, c.client_code, c.name, c.status,
        MIN(sc.frequency_days) AS shortest_freq,
        STRING_AGG(sc.service_type || ':' || sc.frequency_days::text, '+' ORDER BY sc.service_type) AS configs
      FROM clients c
      JOIN service_configs sc ON sc.client_id = c.id
      WHERE c.status IN ('ACTIVE', 'Recuring')
        AND sc.frequency_days BETWEEN 10 AND 180
      GROUP BY c.id
    )
    SELECT
      ch.client_code, ch.name, ch.shortest_freq, ch.configs,
      lv.last_completed::text AS last_completed,
      CASE
        WHEN lv.last_completed IS NULL THEN NULL
        ELSE (CURRENT_DATE - lv.last_completed)
      END AS days_since,
      CASE
        WHEN lv.last_completed IS NULL THEN NULL
        ELSE ROUND((CURRENT_DATE - lv.last_completed)::numeric / ch.shortest_freq, 2)
      END AS overdue_ratio
    FROM client_health ch
    LEFT JOIN LATERAL (
      SELECT MAX(visit_date) AS last_completed
      FROM visits
      WHERE client_id = ch.id AND visit_status = 'completed'
    ) lv ON true
    WHERE NOT EXISTS (
      SELECT 1 FROM visits v
      WHERE v.client_id = ch.id AND v.visit_date >= CURRENT_DATE
    )
    ORDER BY
      CASE WHEN lv.last_completed IS NULL THEN 999
           ELSE (CURRENT_DATE - lv.last_completed)::numeric / ch.shortest_freq
      END DESC;
  `);

  // Bucketize
  const buckets = { ABANDONED: [], 'ABANDONED?': [], OVERDUE: [], DUE_SOON: [], FRESH: [] };
  for (const r of rows) {
    const ratio = r.overdue_ratio === null ? 999 : Number(r.overdue_ratio);
    let bucket;
    if (ratio > 4) bucket = 'ABANDONED';
    else if (ratio > 2) bucket = 'ABANDONED?';
    else if (ratio > 1) bucket = 'OVERDUE';
    else if (ratio > 0.5) bucket = 'DUE_SOON';
    else bucket = 'FRESH';
    buckets[bucket].push(r);
  }

  console.log(`Total active clients with no upcoming visit: ${rows.length}\n`);
  console.log('  Bucket      | Count | Meaning');
  console.log('  ------------|-------|---------------------------------------------');
  console.log(`  FRESH       | ${String(buckets.FRESH.length).padStart(5)} | < 0.5x freq — Diego just hasn't scheduled, normal`);
  console.log(`  DUE_SOON    | ${String(buckets.DUE_SOON.length).padStart(5)} | 0.5–1.0x — getting close, normal backlog`);
  console.log(`  OVERDUE     | ${String(buckets.OVERDUE.length).padStart(5)} | 1.0–2.0x — past due, Diego missed`);
  console.log(`  ABANDONED?  | ${String(buckets['ABANDONED?'].length).padStart(5)} | 2.0–4.0x — big gap, probably paused-not-marked`);
  console.log(`  ABANDONED   | ${String(buckets.ABANDONED.length).padStart(5)} | > 4.0x or never serviced — mark INACTIVE/PAUSED`);

  for (const bucket of ['ABANDONED', 'ABANDONED?', 'OVERDUE', 'DUE_SOON', 'FRESH']) {
    if (buckets[bucket].length === 0) continue;
    console.log(`\n${'='.repeat(72)}\n${bucket} (${buckets[bucket].length})\n${'='.repeat(72)}`);
    console.log('  client_code | freq | last_completed | days | ratio | configs');
    console.log('  ------------|------|----------------|------|-------|--------');
    for (const r of buckets[bucket]) {
      console.log('  ' + (r.client_code || '?').padEnd(11) +
        ' | ' + String(r.shortest_freq).padStart(4) +
        ' | ' + String(r.last_completed || 'never').padEnd(14) +
        ' | ' + String(r.days_since ?? '∞').padStart(4) +
        ' | ' + String(r.overdue_ratio ?? '∞').padStart(5) + 'x' +
        ' | ' + (r.configs || '').slice(0, 30));
    }
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
