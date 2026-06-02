// ============================================================================
// jobber_token_keepalive.js — proactively refresh BOTH Jobber OAuth tokens
// (source_system 'jobber' = read app, 'jobber_write' = Calendar write app) so the
// access tokens are always fresh and any refresh failure surfaces IMMEDIATELY
// (a failed cron run) instead of silently as a 500 inside a sync.
//
// Both apps have refresh-token rotation OFF, so the refresh_token is permanent and
// reusable — this just keeps the short-lived access token warm and acts as a health
// check. If a refresh ever fails, the run exits non-zero (visible alert) and a human
// re-authorizes that app once (see docs/jobber-write-oauth-setup.md).
//
// Required env: SUPABASE_URL, SUPABASE_PAT.   CLI: node scripts/sync/jobber_token_keepalive.js
// ============================================================================
const https = require('https');
try { require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env'), override: true, quiet: true }); } catch (_) {}
const PAT = process.env.SUPABASE_PAT;
const ref = process.env.SUPABASE_URL.match(/https?:\/\/([^.]+)\./)[1];
if (!PAT || !ref) throw new Error('SUPABASE_URL + SUPABASE_PAT required');

function sql(q){return new Promise((res,rej)=>{const b=JSON.stringify({query:q});const r=https.request({hostname:'api.supabase.com',path:'/v1/projects/'+ref+'/database/query',method:'POST',headers:{Authorization:'Bearer '+PAT,'Content-Type':'application/json','Content-Length':Buffer.byteLength(b)}},x=>{let d='';x.on('data',c=>d+=c);x.on('end',()=>{if(x.statusCode>=300)return rej(new Error(x.statusCode+': '+d.slice(0,150)));res(JSON.parse(d));});});r.on('error',rej);r.write(b);r.end();});}
function post(host,path,body,headers){return new Promise((res,rej)=>{const r=https.request({hostname:host,path,method:'POST',headers:{...headers,'Content-Length':Buffer.byteLength(body)}},x=>{let d='';x.on('data',c=>d+=c);x.on('end',()=>res({status:x.statusCode,body:d}));});r.on('error',rej);r.write(body);r.end();});}
const q = v => v == null ? 'NULL' : "'" + String(v).replace(/'/g, "''") + "'";

async function refreshOne(source) {
  const rows = await sql(`SELECT refresh_token, client_id, client_secret FROM public.webhook_tokens WHERE source_system='${source}'`);
  if (!rows[0]) return { source, ok: false, err: 'no webhook_tokens row' };
  const r = rows[0];
  const body = `grant_type=refresh_token&refresh_token=${encodeURIComponent(r.refresh_token)}&client_id=${encodeURIComponent(r.client_id)}&client_secret=${encodeURIComponent(r.client_secret)}`;
  const tr = await post('api.getjobber.com', '/api/oauth/token', body, { 'Content-Type': 'application/x-www-form-urlencoded' });
  if (tr.status >= 300) return { source, ok: false, err: `${tr.status}: ${tr.body.slice(0, 120)}` };
  const t = JSON.parse(tr.body);
  const exp = JSON.parse(Buffer.from(t.access_token.split('.')[1], 'base64').toString()).exp * 1000;
  await sql(`UPDATE public.webhook_tokens SET access_token=${q(t.access_token)}, refresh_token=${q(t.refresh_token || r.refresh_token)}, expires_at=${q(new Date(exp).toISOString())}, updated_at=now() WHERE source_system='${source}'`);
  return { source, ok: true, exp: new Date(exp).toISOString() };
}

(async () => {
  const started = new Date().toISOString();
  const results = [];
  for (const s of ['jobber', 'jobber_write']) results.push(await refreshOne(s));
  results.forEach(r => console.log(`[keepalive] ${r.source}: ${r.ok ? 'OK (access exp ' + r.exp + ')' : 'FAIL — ' + r.err}`));
  const failed = results.filter(r => !r.ok);
  await sql(`INSERT INTO public.sync_log (sync_source, started_at, finished_at, rows_updated, rows_errored, status, details)
    VALUES ('jobber_token_keepalive', ${q(started)}, now(), ${results.length - failed.length}, ${failed.length}, ${failed.length ? "'partial'" : "'success'"}, ${q(JSON.stringify(results))})`);
  if (failed.length) {
    console.error('[keepalive] ❌ TOKEN REFRESH FAILED — re-auth needed:', JSON.stringify(failed));
    process.exit(1);
  }
  console.log('[keepalive] both Jobber tokens fresh.');
})().catch(e => { console.error('[keepalive] FATAL:', e.message); process.exit(1); });
