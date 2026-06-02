import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, { method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'}, body:JSON.stringify({query:sql})});
  return JSON.parse(await r.text());
}

console.log('=== Missing data counts in May 2026 — BEFORE vs AFTER observed-cadence fallback ===');
console.log(await pg(`
  SELECT
    count(*)::int AS total,
    sum(CASE WHEN frequency_days IS NULL THEN 1 ELSE 0 END)::int AS missing_freq,
    sum(CASE WHEN equipment_size_gallons IS NULL THEN 1 ELSE 0 END)::int AS missing_size,
    sum(CASE WHEN amount IS NULL THEN 1 ELSE 0 END)::int AS missing_amount
  FROM ops.v_calendar_visit
  WHERE visit_date BETWEEN '2026-05-01' AND '2026-05-31';
`));

console.log('\n=== Previously-blank clients — now filled from observed history ===');
console.log(await pg(`
  SELECT v.client_name, v.service_type,
         v.frequency_days, v.amount,
         CASE WHEN sc.frequency_days IS NULL AND v.frequency_days IS NOT NULL THEN 'observed' ELSE 'contract' END AS freq_source
  FROM ops.v_calendar_visit v
  LEFT JOIN public.service_configs sc ON sc.client_id=v.client_id AND sc.service_type=v.service_type
  WHERE v.client_name IN ('Aromas del Peru','Myka Brickell FT LLC','Claudie','G7 Kitchen 34','Casa Neos','Mila','The carrot express Boca Raton')
    AND v.visit_date BETWEEN '2026-05-01' AND '2026-05-31'
  ORDER BY v.client_name, v.service_type, v.visit_date;
`));

console.log('\n=== Late_status counts (sanity check) ===');
console.log(await pg(`
  SELECT late_status, count(*)::int FROM ops.v_calendar_visit
  WHERE visit_date BETWEEN '2026-05-01' AND '2026-05-31'
  GROUP BY late_status ORDER BY 1;
`));
