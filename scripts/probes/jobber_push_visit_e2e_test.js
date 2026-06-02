// ============================================================================
// jobber_push_visit_e2e_test.js — exercise the deployed jobber-push-visit Edge
// Function through the real DB path on 112-YA (client_id=381, job_id=159).
// create -> push -> verify in Jobber -> move date -> push -> verify -> soft-delete
// -> push -> verify gone -> clean up everything. Safe: 112-YA test account.
// ============================================================================
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env'), override: true, quiet: true });
const https = require('https');
const SUPABASE_URL = process.env.SUPABASE_URL;
const SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY;
const PAT = process.env.SUPABASE_PAT;
const ref = SUPABASE_URL.match(/https?:\/\/([^.]+)\./)[1];
const fnHost = SUPABASE_URL.replace(/https?:\/\//, '').replace(/\/$/, '');

function sql(q) { return new Promise((res, rej) => { const b = JSON.stringify({ query: q }); const r = https.request({ hostname: 'api.supabase.com', path: '/v1/projects/' + ref + '/database/query', method: 'POST', headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(b) } }, x => { let d = ''; x.on('data', c => d += c); x.on('end', () => { if (x.statusCode >= 300) return rej(new Error(x.statusCode + ': ' + d.slice(0, 200))); res(JSON.parse(d)); }); }); r.on('error', rej); r.write(b); r.end(); }); }
function post(host, path, body, headers) { return new Promise((res, rej) => { const r = https.request({ hostname: host, path, method: 'POST', headers: { ...headers, 'Content-Length': Buffer.byteLength(body) } }, x => { let d = ''; x.on('data', c => d += c); x.on('end', () => res({ status: x.statusCode, body: d })); }); r.on('error', rej); r.write(body); r.end(); }); }
function callFn(op, visit_id, extra) { return post(fnHost, '/functions/v1/jobber-push-visit', JSON.stringify({ op, visit_id, ...extra }), { Authorization: 'Bearer ' + SERVICE, 'Content-Type': 'application/json' }); }
async function jtok() { const row = (await sql("SELECT access_token,refresh_token,client_id,client_secret,expires_at::text e FROM public.webhook_tokens WHERE source_system='jobber_write'"))[0]; if (new Date(row.e).getTime() > Date.now() + 120000) return row.access_token; const b = 'grant_type=refresh_token&refresh_token=' + encodeURIComponent(row.refresh_token) + '&client_id=' + encodeURIComponent(row.client_id) + '&client_secret=' + encodeURIComponent(row.client_secret); const tr = await post('api.getjobber.com', '/api/oauth/token', b, { 'Content-Type': 'application/x-www-form-urlencoded' }); const t = JSON.parse(tr.body); const exp = JSON.parse(Buffer.from(t.access_token.split('.')[1], 'base64').toString()).exp * 1000; await sql("UPDATE public.webhook_tokens SET access_token='" + t.access_token + "',refresh_token='" + (t.refresh_token || row.refresh_token) + "',expires_at='" + new Date(exp).toISOString() + "',updated_at=now() WHERE source_system='jobber_write'"); return t.access_token; }
async function jvisit(tok, gid) { const r = await post('api.getjobber.com', '/api/graphql', JSON.stringify({ query: 'query($id:EncodedId!){ visit(id:$id){ id title startAt endAt allDay } }', variables: { id: gid } }), { Authorization: 'Bearer ' + tok, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16' }); return JSON.parse(r.body).data?.visit ?? null; }
async function linkGid(vid) { const l = await sql("SELECT source_id FROM public.entity_source_links WHERE entity_type='visit' AND entity_id=" + vid + " AND source_system='jobber'"); return l[0]?.source_id ?? null; }

(async () => {
  const tok = await jtok();
  let vid;
  try {
    // 1) create a DATE-ONLY / Anytime calendar visit on 112-YA job 159 (no start_at)
    vid = (await sql("INSERT INTO public.visits (client_id, job_id, visit_date, title, service_type, visit_status, source) VALUES (381, 159, '2026-06-25', '01 - Service Agreement - Pumping - Grease Trap & Tank Cleaning', 'GT', 'scheduled', 'visit-calendar') RETURNING id"))[0].id;
    console.log('[e2e] inserted DATE-ONLY (Anytime) calendar visit id=' + vid);

    // 2) push CREATE
    let r = await callFn('upsert', vid);
    console.log('[e2e] CREATE push ->', r.status, r.body);
    let gid = await linkGid(vid);
    console.log('[e2e] linked jobber gid:', gid);
    if (gid) console.log('[e2e]   jobber visit:', JSON.stringify(await jvisit(tok, gid)), '(expect allDay=true on 2026-06-25)');

    // 3) MOVE DATE -> 06-26 (still Anytime)
    await sql("UPDATE public.visits SET visit_date='2026-06-26' WHERE id=" + vid);
    r = await callFn('upsert', vid);
    console.log('[e2e] UPDATE push ->', r.status, r.body);
    if (gid) console.log('[e2e]   jobber visit after move:', JSON.stringify(await jvisit(tok, gid)), '(expect allDay=true on 2026-06-26)');

    // 4) SOFT-DELETE
    await sql("UPDATE public.visits SET deleted_at=now() WHERE id=" + vid);
    r = await callFn('delete', vid);
    console.log('[e2e] DELETE push ->', r.status, r.body);
    if (gid) console.log('[e2e]   jobber visit after delete (expect null):', JSON.stringify(await jvisit(tok, gid)));

  } finally {
    // 5) cleanup — ensure no test data remains anywhere
    if (vid) {
      const gid = await linkGid(vid);
      if (gid && await jvisit(tok, gid)) { await post('api.getjobber.com', '/api/graphql', JSON.stringify({ query: 'mutation($ids:[EncodedId!]!){ visitDelete(visitIds:$ids){ userErrors{ message } } }', variables: { ids: [gid] } }), { Authorization: 'Bearer ' + tok, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16' }); console.log('[e2e] safety-deleted lingering jobber visit', gid); }
      await sql("DELETE FROM public.entity_source_links WHERE entity_type='visit' AND entity_id=" + vid);
      await sql("DELETE FROM public.visit_sync_flags WHERE visit_id=" + vid);
      await sql("DELETE FROM public.visits WHERE id=" + vid);
      console.log('[e2e] cleaned up test visit', vid, '(DB + link + flag + jobber)');
    }
  }
})().catch(e => { console.error('[e2e] FATAL:', e.message); process.exit(1); });
