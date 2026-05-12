// Compare configured service frequency (service_configs.frequency_days) against
// the ACTUAL median gap between completed visits per client+service_type.
// Flags where actual cadence ≥ 1.5× configured (driver doing visits less often
// than promised) OR ≤ 0.5× (more often than necessary).
//
// First confirm 069-TCE specifically, then run the sweep.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

async function pg(sql) {
  for (let i = 0; i < 4; i++) {
    const out = await new Promise((res, rej) => {
      const req = https.request({
        hostname: 'api.supabase.com',
        path: `/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`,
        method: 'POST',
        headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
      }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res({ status: x.statusCode, body: b })); });
      req.on('error', rej); req.write(JSON.stringify({ query: sql })); req.end();
    });
    if (out.status < 300) return JSON.parse(out.body);
    if (out.status >= 500) { await new Promise(r => setTimeout(r, 4000 * (i + 1))); continue; }
    throw new Error(`PG ${out.status}: ${out.body.slice(0, 200)}`);
  }
  throw new Error('5xx exhausted');
}

(async () => {
  // ===== 1. 069-TCE detail =====
  console.log('=== 069-TCE detail ===');
  const detail = await pg(`
    WITH c AS (
      SELECT id, client_code, name FROM clients WHERE client_code = '069-TCE'
    ),
    config AS (
      SELECT service_type, frequency_days
      FROM service_configs WHERE client_id = (SELECT id FROM c)
    ),
    completed AS (
      SELECT visit_date, service_type
      FROM visits
      WHERE client_id = (SELECT id FROM c) AND visit_status = 'completed'
      ORDER BY visit_date DESC
    )
    SELECT
      (SELECT json_agg(config) FROM config) AS configs,
      (SELECT json_agg(completed ORDER BY visit_date DESC) FROM completed) AS visits;
  `);
  const r = detail[0];
  console.log('  configs:', JSON.stringify(r.configs));
  console.log('  recent completed visits:');
  for (const v of (r.visits || []).slice(0, 8)) console.log(`    ${v.visit_date}  ${v.service_type}`);

  // Compute gaps
  const visits = r.visits || [];
  const gtVisits = visits.filter(v => v.service_type === 'GT' || v.service_type === 'grease_trap').sort((a, b) => a.visit_date.localeCompare(b.visit_date));
  if (gtVisits.length > 1) {
    const gaps = [];
    for (let i = 1; i < gtVisits.length; i++) {
      const days = Math.round((new Date(gtVisits[i].visit_date) - new Date(gtVisits[i - 1].visit_date)) / 86400000);
      gaps.push(days);
    }
    gaps.sort((a, b) => a - b);
    const median = gaps[Math.floor(gaps.length / 2)];
    console.log(`  GT gaps (days): [${gaps.join(', ')}]  median=${median}`);
  }

  // ===== 2. Sweep all clients =====
  console.log('\n=== Sweep: configured vs actual GT/CL cadence (last 1y of completed visits) ===');
  console.log('  Threshold: actual ≥ 1.5× configured = ⚠️ under-served; actual ≤ 0.5× = ⚠️ over-served');
  console.log();

  const sweep = await pg(`
    WITH active_configs AS (
      SELECT sc.client_id, c.client_code, c.name, sc.service_type, sc.frequency_days
      FROM service_configs sc
      JOIN clients c ON c.id = sc.client_id
      WHERE c.status IN ('ACTIVE','Recuring','recuring')
        AND sc.frequency_days > 0
        AND sc.service_type IN ('GT','CL','grease_trap','clog')
    ),
    visit_pairs AS (
      SELECT
        v.client_id,
        v.service_type,
        v.visit_date,
        LAG(v.visit_date) OVER (PARTITION BY v.client_id, v.service_type ORDER BY v.visit_date) AS prev_visit
      FROM visits v
      WHERE v.visit_status = 'completed'
        AND v.visit_date >= CURRENT_DATE - INTERVAL '365 days'
        AND v.service_type IS NOT NULL
    ),
    gaps AS (
      SELECT client_id, service_type,
        (visit_date - prev_visit) AS days
      FROM visit_pairs
      WHERE prev_visit IS NOT NULL
    ),
    median_gap AS (
      SELECT client_id, service_type,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY days) AS median_days,
        COUNT(*) AS n_gaps
      FROM gaps
      GROUP BY client_id, service_type
    )
    SELECT
      ac.client_code,
      ac.name,
      ac.service_type,
      ac.frequency_days AS configured,
      mg.median_days::int AS actual,
      mg.n_gaps,
      ROUND((mg.median_days / ac.frequency_days)::numeric, 2) AS ratio
    FROM active_configs ac
    LEFT JOIN median_gap mg
      ON mg.client_id = ac.client_id AND mg.service_type = ac.service_type
    WHERE mg.n_gaps >= 2  -- need at least 3 visits to compute meaningful median
      AND (mg.median_days / ac.frequency_days >= 1.5
        OR mg.median_days / ac.frequency_days <= 0.5)
    ORDER BY (mg.median_days / ac.frequency_days) DESC, ac.client_code;
  `);

  console.log(`  Clients flagged: ${sweep.length}`);
  console.log('  client_code | service | configured | actual | ratio | n_gaps | name');
  console.log('  ------------|---------|------------|--------|-------|--------|--------------------------------');
  for (const row of sweep) {
    const dir = Number(row.ratio) >= 1.5 ? 'UNDER' : 'OVER';
    console.log(`  ${row.client_code.padEnd(11)} | ${row.service_type.padEnd(7)} | ${String(row.configured).padStart(10)} | ${String(row.actual).padStart(6)} | ${row.ratio.padStart(5)} | ${String(row.n_gaps).padStart(6)} | ${dir}: ${row.name.slice(0, 40)}`);
  }

  // ===== 3. Sanity stats =====
  console.log('\n=== Sanity: how many active GT/CL configs are computed at all? ===');
  const stats = await pg(`
    SELECT
      (SELECT COUNT(*) FROM service_configs sc JOIN clients c ON c.id = sc.client_id
        WHERE c.status IN ('ACTIVE','Recuring','recuring') AND sc.frequency_days > 0
          AND sc.service_type IN ('GT','CL','grease_trap','clog')) AS active_configs,
      (SELECT COUNT(DISTINCT (v.client_id, v.service_type)) FROM visits v
        WHERE v.visit_status='completed' AND v.visit_date >= CURRENT_DATE - INTERVAL '365 days'
          AND v.service_type IN ('GT','CL','grease_trap','clog')) AS pairs_with_visits;
  `);
  console.log(' ', JSON.stringify(stats[0]));
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
