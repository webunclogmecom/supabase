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
  console.log('=== webhook_events_log schema ===');
  console.log(await pg(`SELECT column_name, data_type FROM information_schema.columns WHERE table_schema='public' AND table_name='webhook_events_log' ORDER BY ordinal_position;`));

  console.log('\n=== Events near the break (Apr 28-30) ===');
  console.log(await pg(`
    SELECT * FROM webhook_events_log
    WHERE created_at >= '2026-04-28' AND created_at < '2026-04-30'
    ORDER BY created_at DESC LIMIT 5;
  `));

  console.log('\n=== Latest 5 webhook events ===');
  console.log(await pg(`SELECT * FROM webhook_events_log ORDER BY created_at DESC LIMIT 5;`));

  console.log('\n=== Events touching visit 2160911401 (092-TCE May 4) ===');
  console.log(await pg(`
    SELECT *
    FROM webhook_events_log
    WHERE payload::text LIKE '%2160911401%'
    LIMIT 10;
  `));
})();
