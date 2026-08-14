// For each SUSPECT zero-photo visit: a note within +/-2 days DOES carry photos,
// yet the visit ended with none. Two very different explanations:
//   (A) those in-window attachments were NEVER in our DB -> pre-existing import gap,
//       benign, and the FIXED sync will import them on its next run.
//   (B) the cleanup soft-deleted an in-window link -> a bug in the cleanup.
// This decides which, per visit, by checking whether each in-window attachment gid
// exists in photo_links for that visit at all (alive OR soft-deleted).
const https = require('https');
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
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
  if (r.status < 300 && !ct.includes('json')) throw new Error('Jobber busy');
  if (r.status >= 300) throw new Error('Jobber ' + r.status);
  const j = JSON.parse(r.body.toString());
  if (j.errors) throw new Error(JSON.stringify(j.errors).slice(0, 150));
  return j.data;
}
const Q = `query($id:EncodedId!){ visit(id:$id){ notes(first:30){ nodes{ __typename
  ... on JobNote { id createdAt fileAttachments(first:100){ nodes{ id } } }
  ... on ClientNote { id createdAt fileAttachments(first:100){ nodes{ id } } } } } } }`;

const SUSPECTS = (process.argv[2] || '7417,6856,6592,1302,5820,1454,1518,7299').split(',').map(Number);

(async () => {
  TOK = await token();
  let gapOnly = 0, cleanupBug = 0;
  for (const vid of SUSPECTS) {
    const row = (await pg(`SELECT v.id, v.visit_date::text vd, c.client_code, esl.source_id gid
      FROM visits v JOIN entity_source_links esl ON esl.entity_type='visit' AND esl.entity_id=v.id AND esl.source_system='jobber'
      JOIN clients c ON c.id=v.client_id WHERE v.id=${vid}`))[0];
    if (!row) { console.log(`v${vid} not found`); continue; }
    let notes = [];
    try { notes = (await gql(Q, { id: row.gid })).visit?.notes?.nodes || []; }
    catch (e) { console.log(`v${vid} ERR ${e.message.slice(0, 40)}`); continue; }
    const vms = Date.parse(row.vd + 'T12:00:00Z');
    const inWin = [];
    for (const n of notes) {
      const d = Date.parse(n.createdAt || '');
      if (!Number.isFinite(d)) continue;
      if (Math.abs(d - vms) <= 2 * 86400000) (n.fileAttachments?.nodes || []).forEach(f => inWin.push(f.id));
    }
    if (!inWin.length) { console.log(`v${vid} ${row.client_code}: no in-window attachments after all`); continue; }
    // do we hold those attachment gids for THIS visit, in any state?
    const held = await pg(`
      SELECT pl.id, (pl.deleted_at IS NOT NULL) AS deleted, esl.source_id AS att
      FROM photo_links pl
      JOIN entity_source_links esl ON esl.entity_type='photo' AND esl.source_system='jobber' AND esl.entity_id=pl.photo_id
      WHERE pl.entity_type='visit' AND pl.entity_id=${vid}
        AND esl.source_id IN (${inWin.map(esc).join(',')})`);
    const deletedInWindow = held.filter(h => h.deleted === true || h.deleted === 't');
    const verdict = deletedInWindow.length > 0
      ? `*** CLEANUP BUG: ${deletedInWindow.length} in-window link(s) were soft-deleted`
      : (held.length === 0
          ? `benign: those ${inWin.length} in-window photo(s) were NEVER imported (pre-existing gap; the fixed sync will add them)`
          : `benign: ${held.length} in-window link(s) still ALIVE`);
    if (deletedInWindow.length > 0) cleanupBug++; else gapOnly++;
    console.log(`v${String(vid).padEnd(5)} ${String(row.client_code).padEnd(9)} ${row.vd}  in-window atts ${String(inWin.length).padStart(2)}  we hold ${String(held.length).padStart(2)}  -> ${verdict}`);
    await sleep(350);
  }
  console.log(`\nbenign (import gap): ${gapOnly}   CLEANUP BUG: ${cleanupBug}`);
})().catch(e => { console.error('FATAL', e.message); process.exit(1); });
