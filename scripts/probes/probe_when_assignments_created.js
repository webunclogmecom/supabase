require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const PROD = process.env.SUPABASE_PROJECT_ID;
function pg(sql) {
  return new Promise((res, rej) => {
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${PROD}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
    }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res(b)); });
    req.on('error', rej);
    req.write(JSON.stringify({query: sql}));
    req.end();
  });
}
(async () => {
  console.log('=== When were existing visit_assignments rows CREATED (created_at)? ===');
  console.log(await pg(`SELECT DATE(created_at) AS day, COUNT(*)::int AS n FROM visit_assignments GROUP BY DATE(created_at) ORDER BY day DESC LIMIT 20;`));

  console.log('\n=== Sample 5 EXISTING assignments — what was the visit_date vs created_at? ===');
  console.log(await pg(`
    SELECT va.visit_id, v.visit_date, va.employee_id, e.full_name, va.created_at
    FROM visit_assignments va
    JOIN visits v ON v.id = va.visit_id
    JOIN employees e ON e.id = va.employee_id
    ORDER BY va.created_at DESC LIMIT 10;
  `));
})();
