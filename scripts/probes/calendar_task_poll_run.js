// ============================================================================
// calendar_task_poll_run.js — invoke poll-calendar-tasks once, as the cron does (service_role
// bearer), and print its result body. Read-only from this script's point of view: the function
// itself adopts/discovers exactly as a scheduled run would.
//   node scripts/probes/calendar_task_poll_run.js
// ============================================================================
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env'), override: true });
const https = require('https');
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const URL = process.env.SUPABASE_URL;
if (!KEY || !URL) { console.error('missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY in .env'); process.exit(1); }
const host = URL.replace(/^https?:\/\//, '').replace(/\/.*$/, '');
const body = JSON.stringify({});
const r = https.request({ hostname: host, path: '/functions/v1/poll-calendar-tasks', method: 'POST',
  headers: { Authorization: 'Bearer ' + KEY, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } }, (x) => {
  let d = ''; x.on('data', (c) => d += c); x.on('end', () => {
    let j; try { j = JSON.parse(d); } catch { j = { raw: d.slice(0, 500) }; }
    const scrub = (s) => JSON.stringify(s, null, 1).replace(/Z2lk[A-Za-z0-9+\/=]{20,}/g, '<gid>');
    console.log('HTTP', x.statusCode); console.log(scrub(j));
  });
});
r.on('error', (e) => { console.error(e.message); process.exit(1); });
r.setTimeout(150000, () => { console.error('timeout'); process.exit(1); });
r.write(body); r.end();
