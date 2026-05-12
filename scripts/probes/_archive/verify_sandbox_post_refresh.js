require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const SBX = process.env.SANDBOX_SUPABASE_PROJECT_ID;
function pg(sql, project) { return new Promise((res, rej) => {
  const req = https.request({hostname:'api.supabase.com',path:`/v1/projects/${project}/database/query`,method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_PAT}`,'Content-Type':'application/json'}}, x => {let b='';x.on('data',d=>b+=d);x.on('end',()=>res(JSON.parse(b)));});
  req.on('error',rej); req.write(JSON.stringify({query:sql})); req.end();
});}
(async () => {
  // Check Sandbox now has the same property update count Prod had
  const counts = await pg(`
    SELECT
      COUNT(*) AS total_props,
      COUNT(*) FILTER (WHERE updated_at >= '2026-05-11 04:00:00+00') AS updated_today
    FROM properties;`, SBX);
  console.log('Sandbox properties post-refresh:');
  console.log(JSON.stringify(counts, null, 2));

  // Also confirm Yannick's tables survived
  const yannick = await pg(`
    SELECT
      (SELECT COUNT(*) FROM app_visit_reviews) AS visit_reviews,
      (SELECT COUNT(*) FROM app_shift_reviews) AS shift_reviews,
      (SELECT COUNT(*) FROM app_photo_classifications) AS photo_classifications,
      (SELECT COUNT(*) FROM app_property_overrides) AS property_overrides;`, SBX);
  console.log('\nYannick app_* table rows (should match pre-refresh counts):');
  console.log(JSON.stringify(yannick, null, 2));

  // Spot-check the JZ Steak House override survived
  const override = await pg(`
    SELECT external_property_id, grease_trap_manhole_count,
      updated_at AT TIME ZONE 'America/New_York' AS updated_et
    FROM app_property_overrides WHERE external_property_id = 117;`, SBX);
  console.log('\nJZ Steak House manhole override (the row Fred wrote earlier):');
  console.log(JSON.stringify(override, null, 2));
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
