// probe_112ya_db_state.js — 112-YA current DB state: visits history (anchor),
// jobs (is the SA job synced?), line_items (present for the SA job?), service_configs.
const https = require('https');
const fs = require('fs');
const path = require('path');
function readEnv(k) {
  const p = path.resolve(__dirname, '../../.env');
  const line = fs.readFileSync(p, 'utf8').split(/\r?\n/).find(l => l.startsWith(k + '='));
  return line ? line.slice(k.length + 1).trim() : null;
}
const PAT = readEnv('SUPABASE_PAT');
const ref = (readEnv('SUPABASE_URL') || '').match(/https?:\/\/([^.]+)\./)[1];
function pg(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({ hostname: 'api.supabase.com', path: '/v1/projects/' + ref + '/database/query', method: 'POST', headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } },
      r => { let d = ''; r.on('data', c => d += c); r.on('end', () => { if (r.statusCode >= 300) return rej(new Error(r.statusCode + ': ' + d.slice(0, 400))); res(JSON.parse(d)); }); });
    req.on('error', rej); req.write(body); req.end();
  });
}
(async () => {
  const out = {};
  out.client = await pg(`SELECT id, client_code, name, status FROM clients WHERE client_code='112-YA';`);
  const cid = out.client[0] && out.client[0].id;
  out.visits = await pg(`SELECT id, visit_date, visit_status, source, title, service_type, derm_required, job_id FROM visits WHERE client_id=${cid} AND deleted_at IS NULL ORDER BY visit_date DESC NULLS LAST LIMIT 25;`);
  out.jobs = await pg(`SELECT j.id, j.job_number, j.title, j.job_status, esl.source_id FROM jobs j LEFT JOIN entity_source_links esl ON esl.entity_id=j.id AND esl.entity_type='job' AND esl.source_system='jobber' WHERE j.client_id=${cid} ORDER BY j.job_number;`);
  out.line_items = await pg(`SELECT job_id, name FROM line_items WHERE job_id IN (SELECT id FROM jobs WHERE client_id=${cid}) ORDER BY job_id;`);
  out.service_configs = await pg(`SELECT service_type, frequency_days, first_visit, last_visit FROM service_configs WHERE client_id=${cid};`);
  fs.writeFileSync(path.resolve(__dirname, '../../docs/audits/2026-06-03/112ya_db_state.json'), JSON.stringify(out, null, 2));

  console.log('client ' + JSON.stringify(out.client));
  console.log('visits ' + out.visits.length + ':');
  out.visits.slice(0, 14).forEach(v => console.log(`  ${v.visit_date} [${v.visit_status}/${v.source}] st=${v.service_type} job=${v.job_id} derm=${v.derm_required} "${(v.title || '').slice(0, 42)}"`));
  console.log('jobs:');
  out.jobs.forEach(j => console.log(`  db#${j.id} jobNo=${j.job_number} [${j.job_status}] "${(j.title || '').slice(0, 38)}" gid=${j.source_id ? j.source_id.slice(-14) : 'NONE'}`));
  console.log('line_items ' + JSON.stringify(out.line_items));
  console.log('service_configs ' + JSON.stringify(out.service_configs));
})().catch(e => { console.error('FATAL ' + e.message); process.exit(1); });
