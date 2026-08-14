// Verify the visits left with zero photos: ask Jobber what notes that visit
// actually has, and how far each is from the visit date. If every note is far
// outside +/-2 days, zero is the CORRECT answer.
const https = require('https');
require('dotenv').config({ path: require('path').resolve(__dirname,'../../.env') });
const PAT = process.env.SUPABASE_PAT;
const PROJECT = (process.env.SUPABASE_URL || '').match(/https?:\/\/([^.]+)\./)?.[1];
let TOK = null;
const sleep = ms => new Promise(r => setTimeout(r, ms));
function http(o, b) { return new Promise((res, rej) => { const r = https.request(o, x => { const c = []; x.on('data', d => c.push(d)); x.on('end', () => res({ status: x.statusCode, headers: x.headers, body: Buffer.concat(c) })); }); r.on('error', rej); if (b) r.write(b); r.end(); }); }
async function pg(sql) { const b = JSON.stringify({ query: sql }); const r = await http({ hostname: 'api.supabase.com', path: `/v1/projects/${PROJECT}/database/query`, method: 'POST', headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(b) } }, b); if (r.status >= 300) throw new Error('DB ' + r.status + ' ' + r.body.toString().slice(0, 200)); return JSON.parse(r.body.toString()); }
const esc = v => v == null ? 'NULL' : "'" + String(v).replace(/'/g, "''") + "'";
async function token() {
  const t = (await pg(`SELECT access_token,refresh_token,client_id,client_secret,expires_at FROM public.webhook_tokens WHERE source_system='jobber'`))[0];
  if (new Date(t.expires_at).getTime() > Date.now() + 120000) return t.access_token;
  const b = `grant_type=refresh_token&refresh_token=${encodeURIComponent(t.refresh_token)}&client_id=${encodeURIComponent(t.client_id)}&client_secret=${encodeURIComponent(t.client_secret)}`;
  const r = await http({ hostname: 'api.getjobber.com', path: '/api/oauth/token', method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': Buffer.byteLength(b) } }, b);
  const j = JSON.parse(r.body.toString());
  const exp = JSON.parse(Buffer.from(j.access_token.split('.')[1], 'base64').toString()).exp * 1000;
  await pg(`UPDATE public.webhook_tokens SET access_token=${esc(j.access_token)}, refresh_token=${esc(j.refresh_token || t.refresh_token)}, expires_at=${esc(new Date(exp).toISOString())}, updated_at=now() WHERE source_system='jobber'`);
  return j.access_token;
}
async function gql(q, v) {
  const b = JSON.stringify({ query: q, variables: v });
  const r = await http({ hostname: 'api.getjobber.com', path: '/api/graphql', method: 'POST', headers: { Authorization: `Bearer ${TOK}`, 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16', 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(b) } }, b);
  const ct = String(r.headers['content-type'] || '');
  if (r.status < 300 && !ct.includes('json')) throw new Error('Jobber busy (' + ct + ')');
  if (r.status >= 300) throw new Error('Jobber ' + r.status);
  const j = JSON.parse(r.body.toString());
  if (j.errors) throw new Error(JSON.stringify(j.errors).slice(0, 150));
  return j.data;
}
const Q = `query($id:EncodedId!){ visit(id:$id){ id notes(first:30){ nodes{ __typename
  ... on JobNote { id createdAt fileAttachments(first:100){ nodes{ id } } }
  ... on ClientNote { id createdAt fileAttachments(first:100){ nodes{ id } } } } } } }`;

(async () => {
  TOK = await token();
  const rows = await pg(`
    SELECT v.id, v.visit_date::text AS vd, c.client_code, esl.source_id AS gid,
           (SELECT count(*) FROM photo_links pl WHERE pl.entity_type='visit' AND pl.entity_id=v.id AND pl.deleted_at IS NOT NULL) AS removed,
           (SELECT count(*) FROM photo_links pl WHERE pl.entity_type='visit' AND pl.entity_id=v.id AND pl.deleted_at IS NULL) AS kept
    FROM visits v
    JOIN entity_source_links esl ON esl.entity_type='visit' AND esl.entity_id=v.id AND esl.source_system='jobber'
    JOIN clients c ON c.id=v.client_id
    WHERE v.deleted_at IS NULL
      AND EXISTS (SELECT 1 FROM photo_links pl WHERE pl.entity_type='visit' AND pl.entity_id=v.id)
    GROUP BY v.id, v.visit_date, c.client_code, esl.source_id
    HAVING (SELECT count(*) FROM photo_links pl WHERE pl.entity_type='visit' AND pl.entity_id=v.id AND pl.deleted_at IS NULL) = 0
    ORDER BY (SELECT count(*) FROM photo_links pl WHERE pl.entity_type='visit' AND pl.entity_id=v.id AND pl.deleted_at IS NOT NULL) DESC
    LIMIT ${Number(process.argv[2] || 8)}`);

  console.log(`Checking ${rows.length} zero-photo visits against Jobber\n`);
  let correct = 0, suspect = 0;
  for (const r of rows) {
    let notes = [];
    try { const d = await gql(Q, { id: r.gid }); notes = d.visit?.notes?.nodes || []; }
    catch (e) { console.log(`v${r.id} ${r.client_code} ERR ${e.message.slice(0, 50)}`); continue; }
    const vms = Date.parse(r.vd + 'T12:00:00Z');
    const withAtt = notes.filter(n => (n.fileAttachments?.nodes || []).length > 0);
    const deltas = withAtt.map(n => Math.round((Date.parse(n.createdAt) - vms) / 86400000)).sort((a, b) => Math.abs(a) - Math.abs(b));
    const near = deltas.filter(d => Math.abs(d) <= 2);
    const verdict = near.length === 0 ? 'CORRECT (no note within 2d has photos)' : 'SUSPECT (' + near.length + ' note(s) within 2d HAVE photos)';
    if (near.length === 0) correct++; else suspect++;
    console.log(`v${String(r.id).padEnd(5)} ${String(r.client_code).padEnd(9)} ${r.vd}  removed ${String(r.removed).padStart(3)}  notes-with-photos ${String(withAtt.length).padStart(2)}  nearest note ${deltas.length ? deltas[0] + 'd' : 'n/a'}  -> ${verdict}`);
    await sleep(350);
  }
  console.log(`\nCORRECT: ${correct}   SUSPECT: ${suspect}`);
})().catch(e => { console.error('FATAL', e.message); process.exit(1); });
