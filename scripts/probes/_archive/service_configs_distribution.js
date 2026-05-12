// Sanity-check service_configs distribution post freqMul fix.
// Expect: most clients at 30/60/90/120 days; 4 outliers >180; possibly some 0s.

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const { newQuery } = require('../populate/lib/db');

(async () => {
  const dist = await newQuery(`
    SELECT
      service_type,
      frequency_days,
      COUNT(*)::int AS count
    FROM service_configs
    WHERE frequency_days IS NOT NULL
    GROUP BY service_type, frequency_days
    ORDER BY service_type, frequency_days;
  `);

  console.log('Frequency distribution per service_type:\n');
  let lastType = null;
  for (const r of dist) {
    if (r.service_type !== lastType) { console.log(`\n--- ${r.service_type} ---`); lastType = r.service_type; }
    const bar = '█'.repeat(Math.min(r.count, 60));
    const interp = r.frequency_days === 0 ? 'ZERO/INVALID' :
                   r.frequency_days < 10 ? 'unusually short' :
                   r.frequency_days <= 180 ? `every ${(r.frequency_days/30).toFixed(1)}mo` :
                   `outlier ${(r.frequency_days/30).toFixed(1)}mo`;
    console.log(`  ${String(r.frequency_days).padStart(4)}d  ${String(r.count).padStart(3)}× ${bar}  (${interp})`);
  }

  // Count nulls + zeros
  const issues = await newQuery(`
    SELECT
      COUNT(*) FILTER (WHERE frequency_days IS NULL)::int AS null_count,
      COUNT(*) FILTER (WHERE frequency_days = 0)::int AS zero_count,
      COUNT(*)::int AS total
    FROM service_configs;
  `);
  console.log(`\nTotal configs: ${issues[0].total}`);
  console.log(`  NULL frequency_days: ${issues[0].null_count}`);
  console.log(`  ZERO frequency_days: ${issues[0].zero_count}`);

  // List zero-freq configs (Airtable data errors)
  if (issues[0].zero_count > 0) {
    const zeros = await newQuery(`
      SELECT c.client_code, c.name, sc.service_type
      FROM service_configs sc JOIN clients c ON c.id=sc.client_id
      WHERE sc.frequency_days = 0
      ORDER BY c.client_code;
    `);
    console.log('\nClients with ZERO frequency (Airtable data error):');
    for (const z of zeros) console.log(`  ${z.client_code} ${z.service_type}: ${z.name}`);
  }

  process.exit(0);
})().catch(e => { console.error(e); process.exit(1); });
