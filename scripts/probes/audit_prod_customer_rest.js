require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const PROD = process.env.SUPABASE_PROJECT_ID;
const SUPABASE_URL = process.env.SUPABASE_URL;
const host = new (require('url').URL)(SUPABASE_URL).hostname;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

function rest(path, headers = {}) {
  return new Promise((res, rej) => {
    const req = https.request({
      hostname: host, path, method: 'GET',
      headers: { apikey: KEY, Authorization: 'Bearer ' + KEY, ...headers }
    }, x => {
      let b = ''; x.on('data', d => b += d); x.on('end', () => res({ s: x.statusCode, b: b.slice(0, 400) }));
    });
    req.on('error', rej); req.end();
  });
}
function pg(sql) {
  return new Promise((res, rej) => {
    const req = https.request({
      hostname: 'api.supabase.com', path: `/v1/projects/${PROD}/database/query`, method: 'POST',
      headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
    }, x => { let b = ''; x.on('data', d => b += d); x.on('end', () => res({ s: x.statusCode, b })); });
    req.on('error', rej);
    req.write(JSON.stringify({ query: sql }));
    req.end();
  });
}

(async () => {
  console.log('Forcing PostgREST reload to be safe...');
  console.log('  NOTIFY:', (await pg("NOTIFY pgrst, 'reload schema'; NOTIFY pgrst, 'reload config';")).s);

  console.log('\n=== Verify each customer.* view via REST (Accept-Profile=customer) ===');
  const views = ['work_orders','wo_photos','client_access_photos','inspection_items','permits','recommendations','scheduled_visits','clients'];
  for (const v of views) {
    const r = await rest(`/rest/v1/${v}?limit=1`, { 'Accept-Profile': 'customer' });
    const ok = r.s === 200;
    console.log(`  customer.${v}: ${ok ? '✓ 200' : '✗ ' + r.s} ${ok ? '' : ' body=' + r.b.slice(0,200)}`);
  }

  console.log('\n=== Sample customer.work_orders for visit 3915 (092-TCE 5/4) ===');
  const r = await rest('/rest/v1/work_orders?id=eq.00000000-0000-0000-0000-000000003915', { 'Accept-Profile': 'customer' });
  console.log(`  status: ${r.s}`);
  console.log(`  body: ${r.b}`);
})();
