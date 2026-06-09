import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, { method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'}, body:JSON.stringify({query:sql})});
  return JSON.parse(await r.text());
}
console.log('Myka Brickell FT LLC (client_id=348) service_configs:');
console.log(await pg(`SELECT id, service_type, frequency_days, equipment_size_gallons, price_per_visit, first_visit, last_visit FROM public.service_configs WHERE client_id=348;`));
console.log('\nAromas del Peru (client_id=450) service_configs:');
console.log(await pg(`SELECT id, service_type, frequency_days, equipment_size_gallons, price_per_visit, first_visit, last_visit FROM public.service_configs WHERE client_id=450;`));

console.log('\nObserved cadence between completed visits (real gap in days) for clients without freq:');
console.log(await pg(`
  WITH consecutive AS (
    SELECT v.client_id, v.service_type, v.visit_date,
           v.visit_date - LAG(v.visit_date) OVER (PARTITION BY v.client_id, v.service_type ORDER BY v.visit_date) AS days_since_prev,
           c.name AS client_name
    FROM public.visits v
    JOIN public.clients c ON c.id=v.client_id
    WHERE v.visit_status='completed' AND v.service_type IN ('GT','CL')
  )
  SELECT client_name, service_type,
         count(*) AS gaps,
         round(avg(days_since_prev)::numeric, 1) AS avg_gap_days,
         round(percentile_cont(0.5) WITHIN GROUP (ORDER BY days_since_prev)::numeric, 1) AS median_gap
  FROM consecutive
  WHERE days_since_prev BETWEEN 5 AND 200
    AND client_id IN (450, 348, 209, 322, 372, 280, 289)
  GROUP BY client_name, service_type
  ORDER BY client_name, service_type;
`));
