// 35_post_amount_fix_check.mjs
// After dropping the line-items sum from v_calendar_visit, re-check:
//   - Aromas del Peru 3 visits (formerly $5,149 each)
//   - Top amounts in May 2026 are now realistic
//   - Daily totals sane

import 'dotenv/config';

const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;

async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql }),
  });
  const body = await r.text();
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${body.slice(0, 600)}`);
  return JSON.parse(body);
}

console.log('=== Aromas del Peru visits (was all $5,149) ===');
console.log(await pg(`
  SELECT id, visit_date, service_type, amount
  FROM ops.v_calendar_visit
  WHERE client_name = 'Aromas del Peru'
    AND visit_date BETWEEN '2026-05-01' AND '2026-05-31'
  ORDER BY visit_date, service_type;
`));

console.log('\n=== Top amounts in May 2026 (post-fix) ===');
console.log(await pg(`
  SELECT visit_date, client_name, service_type, amount, frequency_days
  FROM ops.v_calendar_visit
  WHERE visit_date BETWEEN '2026-05-01' AND '2026-05-31'
    AND amount IS NOT NULL
  ORDER BY amount DESC NULLS LAST
  LIMIT 12;
`));

console.log('\n=== Daily totals for May (sanity check) ===');
console.log(await pg(`
  SELECT visit_date, count(*)::int AS visits,
         SUM(amount) FILTER (WHERE amount IS NOT NULL)::numeric(12,2) AS daily_total,
         count(*) FILTER (WHERE amount IS NULL)::int AS null_amount_visits
  FROM ops.v_calendar_visit
  WHERE visit_date BETWEEN '2026-05-01' AND '2026-05-31'
  GROUP BY visit_date
  ORDER BY visit_date;
`));

console.log('\n=== Clients with ZERO service_configs but visits in May 2026 ===');
console.log(await pg(`
  SELECT v.client_id, v.client_code, v.client_name, count(*)::int AS visits_in_may
  FROM ops.v_calendar_visit v
  WHERE visit_date BETWEEN '2026-05-01' AND '2026-05-31'
    AND v.frequency_days IS NULL
  GROUP BY v.client_id, v.client_code, v.client_name
  ORDER BY visits_in_may DESC
  LIMIT 20;
`));
