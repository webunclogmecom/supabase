require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const PROD = process.env.SUPABASE_PROJECT_ID;
function pg(sql) { return new Promise((res, rej) => {
  const req = https.request({hostname:'api.supabase.com',path:`/v1/projects/${PROD}/database/query`,method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_PAT}`,'Content-Type':'application/json'}}, x => {let b='';x.on('data',d=>b+=d);x.on('end',()=>res(JSON.parse(b)));});
  req.on('error',rej); req.write(JSON.stringify({query:sql})); req.end();
});}
(async () => {
  // Total + status breakdown
  const total = await pg(`SELECT status, COUNT(*) AS n FROM clients GROUP BY status ORDER BY n DESC;`);
  console.log('All clients by status:');
  for (const r of total) console.log(`  ${(r.status||'NULL').padEnd(15)} ${r.n}`);

  // Commercial vs residential split
  const split = await pg(`
    SELECT status,
      COUNT(*) FILTER (WHERE client_code ~ '^[0-9]{3}-') AS commercial,
      COUNT(*) FILTER (WHERE client_code IS NULL OR client_code !~ '^[0-9]{3}-') AS residential_or_other
    FROM clients GROUP BY status ORDER BY status;`);
  console.log('\nCommercial vs residential by status:');
  console.log('  status          commercial  residential');
  for (const r of split) console.log(`  ${(r.status||'NULL').padEnd(15)} ${String(r.commercial).padStart(10)}  ${String(r.residential_or_other).padStart(11)}`);

  // Headline numbers
  const headline = await pg(`
    SELECT
      COUNT(*) AS total_all,
      COUNT(*) FILTER (WHERE status IN ('ACTIVE','Recuring')) AS active_or_recurring,
      COUNT(*) FILTER (WHERE status IN ('ACTIVE','Recuring') AND client_code ~ '^[0-9]{3}-') AS active_commercial,
      COUNT(*) FILTER (WHERE status IN ('ACTIVE','Recuring') AND (client_code IS NULL OR client_code !~ '^[0-9]{3}-')) AS active_residential
    FROM clients;`);
  console.log('\nHeadline:');
  console.log(JSON.stringify(headline[0], null, 2));
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
