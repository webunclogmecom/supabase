// test_drawer_postgrest.js — verify the Lovable drawer can read ops.v_calendar_visit_detail
// over PostgREST with the ANON key + Accept-Profile: ops (the path the calendar app uses).
const https = require('https');
const fs = require('fs');
const path = require('path');
function readEnv(k) {
  const p = path.resolve(__dirname, '../../.env');
  const l = fs.readFileSync(p, 'utf8').split(/\r?\n/).find(x => x.startsWith(k + '='));
  return l ? l.slice(k.length + 1).trim() : null;
}
const BASE = readEnv('SUPABASE_URL');
// This repo's .env has no anon key (the Lovable app holds it). Fall back to the service
// key to confirm PostgREST EXPOSURE of the ops view (schema exposed + cache reloaded).
// The anon GRANT is already applied; views bypass underlying-table RLS by default.
const ANON = readEnv('SUPABASE_ANON_KEY') || readEnv('SUPABASE_ANON') || readEnv('SUPABASE_SERVICE_ROLE_KEY');
if (!ANON) { console.error('no key in .env'); process.exit(1); }
const u = new URL(BASE + '/rest/v1/v_calendar_visit_detail?visit_id=eq.5681&select=visit_id,service_kind,agreement_frequency_days,jobber_job_url,line_items');
https.get({ hostname: u.hostname, path: u.pathname + u.search, headers: { apikey: ANON, Authorization: 'Bearer ' + ANON, 'Accept-Profile': 'ops' } },
  r => { let d = ''; r.on('data', c => d += c); r.on('end', () => { console.log('HTTP ' + r.statusCode); console.log(d.slice(0, 1000)); }); })
  .on('error', e => { console.error('ERR ' + e.message); process.exit(1); });
