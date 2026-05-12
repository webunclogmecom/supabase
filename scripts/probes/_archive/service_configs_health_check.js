// Apply Fred's 2026-05-04 criteria for "broken" service_configs:
//   A. ANY declared service has a broken frequency (0, <10, or >90 days)
//   B. Active client + valid frequencies + no upcoming visit generated
//
// Active = clients.status IN ('ACTIVE', 'Recuring').
// "Broken" frequency = frequency_days IS NULL OR =0 OR <10 OR >90.
// "No upcoming visit" = NOT EXISTS visits with visit_date >= today.
//
// Outputs two lists for Fred to review with Yan.

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

const SECTION = (t) => console.log(`\n${'='.repeat(72)}\n${t}\n${'='.repeat(72)}`);

(async () => {
  // First check what service_type values actually exist
  console.log('=== Service type values currently in service_configs ===');
  const types = await pg(`SELECT DISTINCT service_type, COUNT(*) AS n FROM service_configs GROUP BY 1 ORDER BY n DESC`);
  for (const t of types) console.log(`  ${(t.service_type || '(null)').padEnd(40)} ${t.n}`);

  // ==========================================================================
  // CRITERION A — broken frequency, two tiers
  // ==========================================================================
  SECTION('A1. CRITICAL: NULL, 0, <10, or >180 days');
  console.log('   These are almost certainly bugs requiring Yan to fix in Airtable\n');

  const critical = await pg(`
    SELECT c.client_code, c.name, c.status, sc.service_type, sc.frequency_days,
      CASE WHEN sc.frequency_days IS NULL THEN 'NULL'
           WHEN sc.frequency_days = 0     THEN 'zero'
           WHEN sc.frequency_days < 10    THEN 'too_frequent'
           WHEN sc.frequency_days > 180   THEN 'over_6_months' END AS issue
    FROM clients c
    JOIN service_configs sc ON sc.client_id = c.id
    WHERE c.status IN ('ACTIVE', 'Recuring')  -- excludes PAUSED + INACTIVE
      AND (sc.frequency_days IS NULL OR sc.frequency_days = 0 OR sc.frequency_days < 10 OR sc.frequency_days > 180)
    ORDER BY c.client_code, sc.service_type;
  `);

  console.log(`Found ${critical.length} critical broken rows\n`);
  console.log('  client_code | type | freq_days | issue');
  console.log('  ------------|------|-----------|---------------');
  for (const r of critical) {
    console.log('  ' + (r.client_code || '?').padEnd(11) + ' | ' +
      (r.service_type || '?').padEnd(4) + ' | ' +
      String(r.frequency_days ?? 'NULL').padStart(9) + ' | ' + r.issue);
  }

  SECTION('A2. SUSPECT: 91–180 days (mostly intentional chain frequencies, but verify)');
  console.log('   These are likely fine (e.g. TCE chain runs CL=120) but worth confirming\n');

  const suspect = await pg(`
    SELECT c.client_code, c.name, sc.service_type, sc.frequency_days
    FROM clients c
    JOIN service_configs sc ON sc.client_id = c.id
    WHERE c.status IN ('ACTIVE', 'Recuring')
      AND sc.frequency_days BETWEEN 91 AND 180
    ORDER BY sc.frequency_days DESC, c.client_code;
  `);

  console.log(`Found ${suspect.length} suspect rows (range)\n`);
  // Group by frequency
  const byFreq = {};
  for (const r of suspect) {
    if (!byFreq[r.frequency_days]) byFreq[r.frequency_days] = [];
    byFreq[r.frequency_days].push(`${r.client_code} ${r.service_type}`);
  }
  for (const freq of Object.keys(byFreq).sort((a,b) => Number(b) - Number(a))) {
    console.log(`  ${freq} days (${byFreq[freq].length} rows):`);
    console.log(`    ${byFreq[freq].slice(0, 8).join(', ')}${byFreq[freq].length > 8 ? '...' : ''}`);
  }

  // ==========================================================================
  // CRITERION B — active client + valid configs + no upcoming visit
  // ==========================================================================
  SECTION('B. Active clients with VALID frequencies but NO upcoming visit');
  console.log("   Means scheduling layer hasn't generated next visit\n");

  const noUpcoming = await pg(`
    WITH client_health AS (
      SELECT
        c.id, c.client_code, c.name, c.status,
        COUNT(*) AS service_count,
        BOOL_AND(sc.frequency_days BETWEEN 10 AND 90) AS all_freq_valid,
        STRING_AGG(sc.service_type || ':' || sc.frequency_days::text, ', ' ORDER BY sc.service_type) AS configs
      FROM clients c
      JOIN service_configs sc ON sc.client_id = c.id
      WHERE c.status IN ('ACTIVE', 'Recuring')  -- excludes PAUSED + INACTIVE
      GROUP BY c.id, c.client_code, c.name, c.status
    )
    SELECT ch.client_code, ch.name, ch.configs,
      (SELECT MAX(visit_date)::text FROM visits WHERE client_id = ch.id AND visit_status = 'completed') AS last_completed,
      (SELECT MIN(visit_date)::text FROM visits WHERE client_id = ch.id AND visit_date >= CURRENT_DATE) AS next_scheduled
    FROM client_health ch
    WHERE ch.all_freq_valid = true
      AND NOT EXISTS (
        SELECT 1 FROM visits v
        WHERE v.client_id = ch.id AND v.visit_date >= CURRENT_DATE
      )
    ORDER BY ch.client_code;
  `);

  console.log(`Found ${noUpcoming.length} active clients with valid configs but no upcoming visit\n`);
  console.log('  client_code | last_completed | configs');
  console.log('  ------------|----------------|------------------------------------------');
  for (const r of noUpcoming) {
    console.log('  ' + (r.client_code || '?').padEnd(11) + ' | ' +
      (r.last_completed || 'never'.padEnd(14)).padEnd(14) + ' | ' +
      (r.configs || '').slice(0, 60));
  }

  // ==========================================================================
  // SUMMARY
  // ==========================================================================
  SECTION('SUMMARY');
  // Distinct clients across both lists
  const brokenClients = new Set(broken.map(r => r.client_code).filter(Boolean));
  const noUpcomingClients = new Set(noUpcoming.map(r => r.client_code).filter(Boolean));
  const both = [...brokenClients].filter(c => noUpcomingClients.has(c));
  console.log(`  Broken-frequency rows:                 ${broken.length}`);
  console.log(`  Distinct clients with broken configs:  ${brokenClients.size}`);
  console.log(`  Active clients with no upcoming visit: ${noUpcoming.length}`);
  console.log(`  Clients in BOTH lists (worst case):    ${both.length}`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
