require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const PROD = process.env.SUPABASE_PROJECT_ID;
const FP = process.env.FIELD_PORTAL_SUPABASE_PROJECT_ID;
function pg(sql, project) {
  return new Promise((res, rej) => {
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${project}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
    }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res(b)); });
    req.on('error', rej);
    req.write(JSON.stringify({query: sql}));
    req.end();
  });
}
(async () => {
  console.log('=== Visit 3915 (092-TCE May 4) on Prod ===');
  console.log(await pg(`SELECT v.id, v.visit_date, (SELECT string_agg(e.full_name, ', ') FROM visit_assignments va JOIN employees e ON e.id=va.employee_id WHERE va.visit_id=v.id) AS drivers FROM visits v WHERE v.id=3915;`, PROD));

  console.log('\n=== Visit 3915 on Field Portal Sandbox ===');
  console.log(await pg(`SELECT v.id, v.visit_date, (SELECT string_agg(e.full_name, ', ') FROM visit_assignments va JOIN employees e ON e.id=va.employee_id WHERE va.visit_id=v.id) AS drivers FROM visits v WHERE v.id=3915;`, FP));

  console.log('\n=== visit_assignments coverage delta ===');
  for (const [name, id] of [['Prod', PROD], ['Field Portal', FP]]) {
    const r = await pg(`SELECT COUNT(*)::int AS rows FROM visit_assignments;`, id);
    console.log(`  ${name}:`, r);
  }

  console.log('\n=== photo_classifications coverage delta + recent activity ===');
  for (const [name, id] of [['Prod', PROD], ['Field Portal', FP]]) {
    const r = await pg(`SELECT COUNT(*)::int AS rows, MAX(updated_at) AS most_recent FROM photo_classifications;`, id);
    console.log(`  ${name}:`, r);
  }

  console.log('\n=== Of Prod\'s 41 backfilled assignments, how many are on visits that ALSO exist in Field Portal subset? ===');
  console.log(await pg(`
    SELECT COUNT(DISTINCT va.visit_id)::int AS in_fp_subset
    FROM visit_assignments va
    WHERE va.visit_id IN (SELECT id FROM visits);
  `, FP));
})();
