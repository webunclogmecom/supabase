// check_calendar_jobber_divergence.js — TRIPWIRE for calendar visits that diverged from Jobber.
// Read-only. Catches the exact class Fred hit with visit 7013: a Calendar CRUD that FAILED to reach
// Jobber but is still shown locally (kept in our DB), and pushes that are stuck.
//
// It flags any LIVE (deleted_at IS NULL) visit that is:
//   (A) sync_state='failed'            -> changed locally, push to Jobber failed, row still showing.
//   (B) sync_state='pending' & stale   -> push never confirmed (cron-9 should have settled it; >30 min
//                                         and still pending = stuck/failing silently).
// With --verify-jobber it additionally checks each flagged visit's stored Jobber visit GID against live
// Jobber, so you can tell an ORPHAN (Jobber visit deleted -> "Visit not found", soft-delete it) from a
// TRANSIENT push error (retryable).
//
// Exit code 1 if anything is flagged (so it can gate CI / a scheduled check). Does NOT write anything.
//   node scripts/probes/check_calendar_jobber_divergence.js
//   node scripts/probes/check_calendar_jobber_divergence.js --verify-jobber   # + confirm each GID in Jobber
const https = require('https'); const fs = require('fs'); const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true, quiet: true });
const PAT = process.env.SUPABASE_PAT; const ref = process.env.SUPABASE_URL.match(/https?:\/\/([^.]+)\./)[1];
const VERIFY = process.argv.includes('--verify-jobber');
const STALE_MIN = 30;

function pg(sql) { return new Promise((res, rej) => { const b = JSON.stringify({ query: sql }); const r = https.request({ hostname: 'api.supabase.com', path: '/v1/projects/' + ref + '/database/query', method: 'POST', headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(b) } }, x => { let d = ''; x.on('data', c => d += c); x.on('end', () => { if (x.statusCode >= 300) return rej(new Error(x.statusCode + ': ' + d.slice(0, 300))); res(JSON.parse(d)); }); }); r.on('error', rej); r.write(b); r.end(); }); }
function jobber(token, q) { return new Promise((res, rej) => { const b = JSON.stringify({ query: q }); const r = https.request({ hostname: 'api.getjobber.com', path: '/api/graphql', method: 'POST', headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16', 'Content-Length': Buffer.byteLength(b) } }, x => { let d = ''; x.on('data', c => d += c); x.on('end', () => { try { res(JSON.parse(d)); } catch (e) { res({ raw: d.slice(0, 120) }); } }); }); r.on('error', rej); r.write(b); r.end(); }); }
async function writeToken() { const rows = await pg("SELECT access_token FROM public.webhook_tokens WHERE source_system='jobber'"); return rows[0] && rows[0].access_token; }

(async () => {
  const rows = await pg(`
    SELECT v.id, c.client_code, v.visit_date, v.visit_status, v.sync_state, v.source,
           v.updated_at, round(extract(epoch FROM now()-v.updated_at)/60)::int AS mins_since_update,
           (SELECT source_id FROM entity_source_links e WHERE e.entity_type='visit' AND e.source_system='jobber' AND e.entity_id=v.id LIMIT 1) AS visit_gid
    FROM visits v LEFT JOIN clients c ON c.id=v.client_id
    WHERE v.deleted_at IS NULL
      AND ( v.sync_state='failed'
         OR (v.sync_state='pending' AND v.source IN ('visit-calendar','supabase_cron')
             AND v.visit_status='scheduled' AND v.updated_at < now() - interval '${STALE_MIN} minutes') )
    ORDER BY v.sync_state, v.visit_date`);

  const failed = rows.filter(r => r.sync_state === 'failed');
  const stuck = rows.filter(r => r.sync_state === 'pending');
  console.log(`Calendar↔Jobber divergence tripwire  (${new Date().toISOString()})`);
  console.log(`  live sync_state='failed'          : ${failed.length}`);
  console.log(`  live 'pending' > ${STALE_MIN}min (stuck) : ${stuck.length}`);

  if (VERIFY && rows.length) {
    const tok = await writeToken();
    for (const r of rows) {
      if (!r.visit_gid) { r.jobber = 'NO_GID'; continue; }
      const jr = await jobber(tok, `{ visit(id:"${r.visit_gid}"){ id visitStatus } }`);
      r.jobber = jr.errors ? (JSON.stringify(jr.errors).includes('not found') ? 'MISSING_IN_JOBBER' : 'ERR') : 'EXISTS';
      await new Promise(s => setTimeout(s, 700));
    }
  }
  const line = r => `  visit ${r.id}  ${(r.client_code || '?').padEnd(8)} ${r.visit_date}  ${r.visit_status.padEnd(9)} ${r.sync_state.padEnd(8)} ${r.mins_since_update}m ago${VERIFY ? '  jobber=' + r.jobber : ''}${r.visit_gid ? '' : '  (no jobber gid)'}`;
  if (failed.length) { console.log('\n[A] FAILED pushes still shown locally (changed here, not in Jobber):'); failed.forEach(r => console.log(line(r))); }
  if (stuck.length) { console.log('\n[B] STUCK pending (push never confirmed):'); stuck.forEach(r => console.log(line(r))); }
  if (VERIFY) { const orphans = rows.filter(r => r.jobber === 'MISSING_IN_JOBBER'); if (orphans.length) console.log(`\n  → ${orphans.length} are ORPHANS (Jobber visit deleted) — candidates to soft-delete: ${orphans.map(o => o.id).join(', ')}`); }

  if (rows.length) { console.log(`\nRESULT: ${rows.length} divergent visit(s) — investigate (orphan → soft-delete; transient → let cron-9 retry or re-push).`); process.exit(1); }
  console.log('\nRESULT: clean — every live calendar visit is confirmed-synced with Jobber.');
})().catch(e => { console.error('ERR', e.message); process.exit(2); });
