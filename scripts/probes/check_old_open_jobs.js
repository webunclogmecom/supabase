// check_old_open_jobs.js — find every Jobber job whose title contains "[OLD]" and report its LIVE
// Jobber status (the DB job_status is a synced snapshot; this verifies against Jobber directly).
// "Open" = not archived and not complete. Read-only.
const https = require('https');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const TOK = (process.env.JOBBER_TOKEN_FRESH || process.env.JOBBER_ACCESS_TOKEN || '').trim();
const PAT = process.env.SUPABASE_PAT;
const ref = process.env.SUPABASE_URL.match(/https?:\/\/([^.]+)\./)[1];

function pg(sql) {
  return new Promise((res, rej) => { const b = JSON.stringify({ query: sql }); const r = https.request({ hostname: 'api.supabase.com', path: '/v1/projects/' + ref + '/database/query', method: 'POST', headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(b) } }, x => { let d = ''; x.on('data', c => d += c); x.on('end', () => { if (x.statusCode >= 300) return rej(new Error(x.statusCode + ': ' + d.slice(0, 300))); res(JSON.parse(d)); }); }); r.on('error', rej); r.write(b); r.end(); });
}
function jobber(query) {
  return new Promise((res, rej) => { const b = JSON.stringify({ query }); const r = https.request({ hostname: 'api.getjobber.com', path: '/api/graphql', method: 'POST', headers: { Authorization: 'Bearer ' + TOK, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16', 'Content-Length': Buffer.byteLength(b) } }, x => { let d = ''; x.on('data', c => d += c); x.on('end', () => { if (x.statusCode >= 300) return rej(new Error(x.statusCode + ': ' + d.slice(0, 400))); res(JSON.parse(d)); }); }); r.on('error', rej); r.write(b); r.end(); });
}

(async () => {
  // 1. [OLD] jobs in DB with their Jobber GID
  const rows = await pg(`
    SELECT j.id, j.title, j.job_status, esl.source_id AS gid,
           c.client_code, c.name AS client_name
    FROM public.jobs j
    JOIN public.entity_source_links esl ON esl.entity_type='job' AND esl.source_system='jobber' AND esl.entity_id=j.id
    LEFT JOIN public.clients c ON c.id = j.client_id
    WHERE j.title ILIKE '%[OLD]%'
    ORDER BY j.title`);
  console.log(`DB: ${rows.length} jobs titled [OLD] with a Jobber GID`);

  // 2. batch live status from Jobber (aliased job() queries, 20 per request)
  const live = {};
  const missing = [];
  for (let i = 0; i < rows.length; i += 20) {
    const batch = rows.slice(i, i + 20);
    const q = '{' + batch.map((r, k) => `j${k}: job(id: "${r.gid}") { id jobNumber title jobStatus jobType client { name companyName } }`).join('\n') + '}';
    let r;
    for (let attempt = 1; attempt <= 4; attempt++) {
      r = await jobber(q);
      if (r.errors && r.errors.some(e => e.extensions?.code === 'THROTTLED')) { await new Promise(s => setTimeout(s, 3000 * attempt)); continue; }
      break;
    }
    if (r.errors) console.error('  jobber errors (batch ' + i + '):', JSON.stringify(r.errors).slice(0, 300));
    for (let k = 0; k < batch.length; k++) {
      const node = r.data && r.data['j' + k];
      if (!node) { missing.push(batch[k]); continue; }
      live[batch[k].gid] = node;
    }
    await new Promise(s => setTimeout(s, 1500));
  }

  // 3. classify: OPEN = not archived, not complete, not deleted
  const OPEN_EXCLUDE = new Set(['archived', 'complete']);
  const open = [], closed = [];
  for (const r of rows) {
    const node = live[r.gid];
    if (!node) continue;
    const st = String(node.jobStatus || '').toLowerCase();
    const rec = { code: r.client_code, client: node.client?.companyName || node.client?.name || r.client_name, jobNumber: node.jobNumber, title: node.title, liveStatus: node.jobStatus, dbStatus: r.job_status };
    if (OPEN_EXCLUDE.has(st)) closed.push(rec); else open.push(rec);
  }

  const out = { checked_at_utc: new Date().toISOString(), total_old_titled: rows.length, resolved_in_jobber: Object.keys(live).length, gid_not_found_in_jobber: missing.map(m => ({ id: m.id, title: m.title, gid: m.gid })), open_count: open.length, closed_count: closed.length, open, closed };
  fs.writeFileSync(path.resolve(__dirname, '../../old_open_jobs_result.json'), JSON.stringify(out, null, 2));

  console.log(`\nResolved in Jobber: ${Object.keys(live).length} / ${rows.length}  (GID not found: ${missing.length})`);
  console.log(`\n=== [OLD] jobs still OPEN in Jobber: ${open.length} ===`);
  const byStatus = {};
  for (const o of open) (byStatus[o.liveStatus] ||= []).push(o);
  for (const st of Object.keys(byStatus).sort()) {
    console.log(`\n-- ${st} (${byStatus[st].length}) --`);
    for (const o of byStatus[st]) console.log(`  #${o.jobNumber}  ${(o.code || '?').padEnd(8)} ${String(o.client || '').slice(0, 22).padEnd(22)}  ${o.title}`);
  }
  console.log(`\n=== [OLD] jobs already closed/archived in Jobber: ${closed.length} ===`);
  if (missing.length) { console.log(`\n=== [OLD] DB jobs whose Jobber GID no longer resolves (deleted upstream?): ${missing.length} ===`); for (const m of missing) console.log(`  db#${m.id}  ${m.title}  (${m.gid})`); }
  console.log('\nFull result -> old_open_jobs_result.json');
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
