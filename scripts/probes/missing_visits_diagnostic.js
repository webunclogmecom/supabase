// Quick diagnostic: what upcoming visits exist? Which RECURRING clients have none?
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
if (!PROD || !PAT) { console.error('Missing SUPABASE_PROJECT_ID or SUPABASE_PAT'); process.exit(1); }

function http(opts, body) { return new Promise((res, rej) => {
  const req = https.request(opts, r => { const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()})); });
  req.on('error',rej); if(body) req.write(body); req.end();
});}
async function pg(sql) {
  const r = await http({hostname:'api.supabase.com',path:'/v1/projects/'+PROD+'/database/query',method:'POST',headers:{Authorization:'Bearer '+PAT,'Content-Type':'application/json'}}, JSON.stringify({query:sql}));
  if(r.status>=300) throw new Error('PG '+r.status+': '+r.body.slice(0,300));
  return JSON.parse(r.body);
}

(async () => {
  console.log('==== Upcoming visit inventory by month + source + status (next 90d) ====');
  const inventory = await pg(`
    SELECT
      to_char(visit_date, 'YYYY-MM') AS month,
      COALESCE(source, '(null)') AS source,
      visit_status,
      COUNT(*)::int AS n
    FROM visits
    WHERE visit_date >= CURRENT_DATE
      AND visit_date <= CURRENT_DATE + INTERVAL '90 days'
    GROUP BY 1, 2, 3
    ORDER BY 1, 2, 3;
  `);
  console.table(inventory);

  console.log('\n==== Latest visit_date in DB, per source ====');
  const latestBySource = await pg(`
    SELECT COALESCE(source, '(null)') AS source, MAX(visit_date)::text AS latest_visit_date, COUNT(*)::int AS total_rows
    FROM visits
    GROUP BY 1
    ORDER BY 1;
  `);
  console.table(latestBySource);

  console.log('\n==== RECURRING clients with NO upcoming visit (next 60d) ====');
  const missingClients = await pg(`
    SELECT c.client_code, c.name, c.status,
      (SELECT MAX(visit_date)::text FROM visits v WHERE v.client_id = c.id) AS last_visit_in_db
    FROM clients c
    WHERE c.status = 'RECURRING'
      AND NOT EXISTS (
        SELECT 1 FROM visits v
        WHERE v.client_id = c.id
          AND v.visit_date >= CURRENT_DATE
          AND v.visit_date <= CURRENT_DATE + INTERVAL '60 days'
      )
    ORDER BY c.client_code NULLS LAST;
  `);
  console.log('count:', missingClients.length);
  if (missingClients.length > 0) {
    console.table(missingClients.slice(0, 40));
    if (missingClients.length > 40) console.log(`  ... and ${missingClients.length - 40} more`);
  }

  console.log('\n==== Totals ====');
  const totals = await pg(`
    SELECT
      (SELECT COUNT(*)::int FROM clients WHERE status = 'RECURRING') AS recurring_clients,
      (SELECT COUNT(*)::int FROM clients WHERE status = 'ACTIVE') AS active_clients,
      (SELECT COUNT(*)::int FROM service_configs WHERE frequency_days IS NOT NULL AND frequency_days > 0) AS recurring_service_configs,
      (SELECT COUNT(*)::int FROM visits WHERE visit_date >= CURRENT_DATE) AS total_upcoming_visits,
      (SELECT COUNT(*)::int FROM visits WHERE visit_date >= CURRENT_DATE - INTERVAL '30 days' AND visit_date < CURRENT_DATE) AS last_30d_visits,
      CURRENT_DATE::text AS today;
  `);
  console.table(totals);
})().catch(e => { console.error(e); process.exit(1); });
