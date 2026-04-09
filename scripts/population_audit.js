// ============================================================================
// Population Dry-Run Audit
// ============================================================================
//
// Reads the OLD Supabase project (raw source mirrors) and reports on the
// 4 known population gaps WITHOUT writing anything to the NEW project.
//
// Gaps checked:
//   1. Truck name normalization — distinct airtable_visits.truck values
//      and which map to a real vehicle vs need a manual alias
//   2. airtable_clients.jobber_client_id coverage — how many AT clients
//      can link to Jobber via the manual field alone
//   3. Employee fuzzy match — airtable_drivers_team vs jobber_users
//      vs samsara_drivers (name similarity, flags non-matches for Fred)
//   4. Visit secondary match dry-run — for AT visits missing jobber_visit_id,
//      how many would merge cleanly vs stay AT-only vs be ambiguous
//      using the locked rule: client + (start_at::date OR end_at::date)
//      + service_type + EXACTLY 1 candidate
//
// Output: scripts/population_audit_report.json + console summary
//
// Usage:
//   node scripts/population_audit.js
// ============================================================================

require('dotenv').config({ path: require('path').resolve(__dirname, '../.env') });
const https = require('https');
const fs = require('fs');
const path = require('path');

const OLD_PROJECT_ID = 'infbofuilnqqviyjlwul';
const PAT = process.env.OLD_SUPABASE_PAT || process.env.SUPABASE_PAT;

if (!PAT) {
  console.error('ERROR: OLD_SUPABASE_PAT or SUPABASE_PAT required in .env');
  process.exit(1);
}

// ----------------------------------------------------------------------------
// Supabase Management API helper — executes SQL via /database/query
// ----------------------------------------------------------------------------
function runSql(projectId, sql) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request(
      {
        hostname: 'api.supabase.com',
        path: `/v1/projects/${projectId}/database/query`,
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${PAT}`,
          'Content-Length': Buffer.byteLength(body),
        },
      },
      (res) => {
        let data = '';
        res.on('data', (c) => (data += c));
        res.on('end', () => {
          if (res.statusCode >= 200 && res.statusCode < 300) {
            try { resolve(JSON.parse(data)); }
            catch { reject(new Error('Bad JSON: ' + data.slice(0, 500))); }
          } else {
            reject(new Error(`HTTP ${res.statusCode}: ${data.slice(0, 500)}`));
          }
        });
      }
    );
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

// ----------------------------------------------------------------------------
// Levenshtein-based similarity for fuzzy name matching
// ----------------------------------------------------------------------------
function normalize(s) {
  return String(s || '').toLowerCase().trim().replace(/\s+/g, ' ');
}
function levenshtein(a, b) {
  const m = a.length, n = b.length;
  if (!m) return n; if (!n) return m;
  const dp = Array.from({ length: m + 1 }, () => new Array(n + 1).fill(0));
  for (let i = 0; i <= m; i++) dp[i][0] = i;
  for (let j = 0; j <= n; j++) dp[0][j] = j;
  for (let i = 1; i <= m; i++)
    for (let j = 1; j <= n; j++)
      dp[i][j] = a[i-1] === b[j-1]
        ? dp[i-1][j-1]
        : 1 + Math.min(dp[i-1][j], dp[i][j-1], dp[i-1][j-1]);
  return dp[m][n];
}
function similarity(a, b) {
  a = normalize(a); b = normalize(b);
  if (!a || !b) return 0;
  const d = levenshtein(a, b);
  return 1 - d / Math.max(a.length, b.length);
}

// ----------------------------------------------------------------------------
// CHECK 1 — Truck name normalization
// ----------------------------------------------------------------------------
async function checkTrucks() {
  console.log('\n[1/4] Checking truck name variants...');
  const r = await runSql(OLD_PROJECT_ID, `
    SELECT DISTINCT trim(truck) AS truck, count(*) AS visit_count
    FROM airtable_visits
    WHERE truck IS NOT NULL AND trim(truck) <> ''
    GROUP BY trim(truck)
    ORDER BY visit_count DESC;
  `);

  const canonicalTrucks = ['cloggy', 'david', 'goliath', 'moise'];
  const aliases = {
    'big one': 'david', 'the big one': 'david', 'big-one': 'david',
  };

  const report = r.map(row => {
    const norm = normalize(row.truck);
    let mapped = null, method = null;
    if (canonicalTrucks.includes(norm)) { mapped = norm; method = 'exact'; }
    else if (aliases[norm]) { mapped = aliases[norm]; method = 'alias'; }
    else {
      for (const t of canonicalTrucks) {
        if (similarity(norm, t) >= 0.8) { mapped = t; method = 'fuzzy'; break; }
      }
    }
    return {
      raw: row.truck,
      visit_count: Number(row.visit_count),
      mapped_to: mapped,
      method: method || 'UNMATCHED',
    };
  });

  const unmatched = report.filter(x => !x.mapped_to);
  console.log(`  Distinct truck values: ${report.length}`);
  console.log(`  Unmatched (need manual alias): ${unmatched.length}`);
  if (unmatched.length) console.log('  ->', unmatched.map(x => `"${x.raw}" (${x.visit_count})`).join(', '));
  return report;
}

// ----------------------------------------------------------------------------
// CHECK 2 — airtable_clients jobber_client_id coverage
// ----------------------------------------------------------------------------
async function checkClientCoverage() {
  console.log('\n[2/4] Checking Airtable -> Jobber client ID coverage...');
  const r = await runSql(OLD_PROJECT_ID, `
    SELECT
      count(*) AS total_airtable,
      count(*) FILTER (WHERE jobber_client_id IS NOT NULL AND jobber_client_id <> '') AS has_jobber_id,
      count(*) FILTER (WHERE jobber_client_id IS NULL OR jobber_client_id = '') AS missing_jobber_id
    FROM airtable_clients;
  `);
  const stats = r[0];
  const pct = ((stats.has_jobber_id / stats.total_airtable) * 100).toFixed(1);
  console.log(`  Total AT clients: ${stats.total_airtable}`);
  console.log(`  With jobber_client_id: ${stats.has_jobber_id} (${pct}%)`);
  console.log(`  Missing jobber_client_id: ${stats.missing_jobber_id} (need name fallback)`);
  return stats;
}

// ----------------------------------------------------------------------------
// CHECK 3 — Employee fuzzy match (Airtable <-> Jobber <-> Samsara)
// ----------------------------------------------------------------------------
async function checkEmployeeMerge() {
  console.log('\n[3/4] Checking employee merge candidates...');
  const [at, jb, sm] = await Promise.all([
    runSql(OLD_PROJECT_ID, `SELECT id, name, role FROM airtable_drivers_team;`),
    runSql(OLD_PROJECT_ID, `SELECT id, name, email FROM jobber_users;`),
    runSql(OLD_PROJECT_ID, `SELECT id, name FROM samsara_drivers;`),
  ]).catch(err => {
    console.log(`  WARNING: ${err.message.slice(0, 200)}`);
    console.log('  Likely table name mismatch — skipping check 3.');
    return [null, null, null];
  });

  if (!at) return { skipped: true };

  const report = at.map(a => {
    const jbScored = jb.map(j => ({ ...j, sim: similarity(a.name, j.name) }))
                       .sort((x, y) => y.sim - x.sim);
    const smScored = sm.map(s => ({ ...s, sim: similarity(a.name, s.name) }))
                       .sort((x, y) => y.sim - x.sim);
    const bestJ = jbScored[0];
    const bestS = smScored[0];
    return {
      airtable_name: a.name,
      role: a.role,
      jobber_best: bestJ ? `${bestJ.name} (${bestJ.sim.toFixed(2)})` : null,
      samsara_best: bestS ? `${bestS.name} (${bestS.sim.toFixed(2)})` : null,
      action: (bestJ && bestJ.sim >= 0.9) ? 'AUTO_MERGE'
            : (bestJ && bestJ.sim >= 0.7) ? 'REVIEW'
            : 'FIELD_ONLY',
    };
  });

  const counts = report.reduce((acc, r) => { acc[r.action] = (acc[r.action] || 0) + 1; return acc; }, {});
  console.log(`  Airtable drivers: ${at.length} | Jobber users: ${jb.length} | Samsara: ${sm.length}`);
  console.log(`  Auto-merge: ${counts.AUTO_MERGE || 0} | Review needed: ${counts.REVIEW || 0} | Field-only: ${counts.FIELD_ONLY || 0}`);
  return report;
}

// ----------------------------------------------------------------------------
// CHECK 4 — Visit secondary match dry-run
// ----------------------------------------------------------------------------
async function checkVisitMerge() {
  console.log('\n[4/4] Checking visit secondary match (dry-run)...');

  // We need to evaluate: for each AT visit with NULL jobber_visit_id,
  // how many Jobber visits match on
  //   client (via airtable_clients.jobber_client_id -> jobber_visits.client_id)
  //   + (visit_date = start_at::date OR end_at::date)
  //   + service_type
  // EXACTLY 1 candidate -> clean merge
  // 0 candidates -> AT-only
  // 2+ candidates -> ambiguous (stay AT-only per rule)

  const sql = `
    WITH at AS (
      SELECT
        av.id AS at_id,
        av.jobber_visit_id,
        av.visit_date,
        av.service_type,
        ac.jobber_client_id
      FROM airtable_visits av
      LEFT JOIN airtable_clients ac ON av.client_record_id = ac.airtable_record_id
      WHERE (av.jobber_visit_id IS NULL OR av.jobber_visit_id = '')
        AND av.visit_date IS NOT NULL
    ),
    matched AS (
      SELECT
        at.at_id,
        count(jv.id) AS candidate_count
      FROM at
      LEFT JOIN jobber_visits jv
        ON jv.client_id = at.jobber_client_id
       AND (jv.start_at::date = at.visit_date OR jv.end_at::date = at.visit_date)
       AND coalesce(jv.service_type, '') = coalesce(at.service_type, '')
      WHERE at.jobber_client_id IS NOT NULL
      GROUP BY at.at_id
    )
    SELECT
      (SELECT count(*) FROM at) AS total_at_missing_id,
      (SELECT count(*) FROM at WHERE jobber_client_id IS NULL) AS no_jobber_client_link,
      count(*) FILTER (WHERE candidate_count = 0) AS no_candidate,
      count(*) FILTER (WHERE candidate_count = 1) AS clean_merge,
      count(*) FILTER (WHERE candidate_count >= 2) AS ambiguous
    FROM matched;
  `;

  try {
    const r = await runSql(OLD_PROJECT_ID, sql);
    const s = r[0];
    console.log(`  AT visits missing jobber_visit_id: ${s.total_at_missing_id}`);
    console.log(`  No jobber_client_id link:          ${s.no_jobber_client_link} (stay AT-only)`);
    console.log(`  No candidate in Jobber:            ${s.no_candidate} (stay AT-only, historical)`);
    console.log(`  CLEAN merge (exactly 1 match):     ${s.clean_merge}`);
    console.log(`  AMBIGUOUS (2+ matches):            ${s.ambiguous} (stay AT-only per rule)`);
    return s;
  } catch (err) {
    console.log(`  WARNING: ${err.message.slice(0, 300)}`);
    console.log('  Likely column name mismatch — verify airtable_visits / jobber_visits schema.');
    return { error: err.message };
  }
}

// ----------------------------------------------------------------------------
// Main
// ----------------------------------------------------------------------------
(async () => {
  console.log('Population Dry-Run Audit');
  console.log('Target: OLD project (' + OLD_PROJECT_ID + ') — read only');

  const report = {
    generated_at: new Date().toISOString(),
    source_project: OLD_PROJECT_ID,
    checks: {},
  };

  try {
    report.checks.trucks = await checkTrucks();
    report.checks.client_coverage = await checkClientCoverage();
    report.checks.employees = await checkEmployeeMerge();
    report.checks.visits = await checkVisitMerge();
  } catch (err) {
    console.error('\nFATAL:', err.message);
    process.exit(1);
  }

  const outPath = path.resolve(__dirname, 'population_audit_report.json');
  fs.writeFileSync(outPath, JSON.stringify(report, null, 2));
  console.log(`\nFull report written to: ${outPath}`);
})();
