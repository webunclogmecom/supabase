// Drill into the 23 "no-upcoming-in-60d" clients: do they have service_configs?
// Are their cadences long enough that next-visit > 60d is correct?
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;

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
  console.log('==== Service configs for the 23 "no upcoming in 60d" clients ====');
  const drill = await pg(`
    SELECT
      c.client_code, c.name, c.status,
      sc.service_type,
      sc.frequency_days,
      sc.last_visit::text AS last_visit_in_sc,
      sc.price_per_visit,
      (SELECT MAX(visit_date)::text FROM visits v
         WHERE v.client_id=c.id AND v.service_type=sc.service_type AND v.visit_date >= CURRENT_DATE
      ) AS next_in_db_for_this_service,
      (SELECT MAX(visit_date)::text FROM visits v
         WHERE v.client_id=c.id AND v.service_type=sc.service_type AND v.visit_date < CURRENT_DATE
      ) AS last_in_db_for_this_service
    FROM clients c
    LEFT JOIN service_configs sc ON sc.client_id = c.id
    WHERE c.status = 'RECURRING'
      AND NOT EXISTS (
        SELECT 1 FROM visits v
        WHERE v.client_id = c.id
          AND v.visit_date >= CURRENT_DATE
          AND v.visit_date <= CURRENT_DATE + INTERVAL '60 days'
      )
    ORDER BY c.client_code, sc.service_type;
  `);
  console.table(drill);

  console.log('\n==== ANY RECURRING client without any service_config at all ====');
  const noConfig = await pg(`
    SELECT c.client_code, c.name, c.status
    FROM clients c
    WHERE c.status = 'RECURRING'
      AND NOT EXISTS (SELECT 1 FROM service_configs sc WHERE sc.client_id = c.id)
    ORDER BY c.client_code;
  `);
  console.log('count:', noConfig.length);
  if (noConfig.length > 0) console.table(noConfig);

  console.log('\n==== service_configs with frequency_days=NULL on RECURRING clients ====');
  const noFreq = await pg(`
    SELECT c.client_code, c.name, sc.service_type, sc.frequency_days, sc.price_per_visit, sc.last_visit::text
    FROM service_configs sc JOIN clients c ON c.id = sc.client_id
    WHERE c.status = 'RECURRING' AND (sc.frequency_days IS NULL OR sc.frequency_days = 0)
    ORDER BY c.client_code, sc.service_type;
  `);
  console.log('count:', noFreq.length);
  if (noFreq.length > 0) console.table(noFreq);

  console.log('\n==== Visits per status (full DB snapshot) ====');
  const snapshot = await pg(`
    SELECT visit_status, COALESCE(source,'(null)') AS source, COUNT(*)::int AS n
    FROM visits
    GROUP BY 1, 2
    ORDER BY 1, 2;
  `);
  console.table(snapshot);
})().catch(e => { console.error(e); process.exit(1); });
