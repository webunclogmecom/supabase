// scripts/sync/backfill_clients_class.js
//
// Backfill public.clients.client_class from Jobber's Client.isCompany.
// Source of truth: Jobber GraphQL.
//   - isCompany = true  → 'commercial'
//   - isCompany = false → 'residential'
//   - errored / missing → left NULL, logged
//
// Idempotent. Re-runnable. Re-runs only touch rows whose value changed
// (no-op UPDATE skipped) so audit.logs doesn't get polluted.
//
// All writes carry X-App-Source: sql for audit attribution (ADR 016).
//
// Usage:
//   node scripts/sync/backfill_clients_class.js          # dry-run
//   node scripts/sync/backfill_clients_class.js --apply  # apply UPDATES

const fs = require('fs');
const path = require('path');
const https = require('https');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const SB_URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const PROJECT = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const APPLY = process.argv.includes('--apply');

function req({ host, path, method = 'GET', headers = {}, body = null }) {
  return new Promise((resolve, reject) => {
    const payload = body == null ? null : (typeof body === 'string' ? body : JSON.stringify(body));
    const r = https.request({ hostname: host, path, method, headers: { ...headers, ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}) } }, (res) => {
      let d = ''; res.on('data', c => (d += c));
      res.on('end', () => resolve({ status: res.statusCode, body: d }));
    });
    r.on('error', reject);
    r.setTimeout(60_000, () => r.destroy(new Error('timeout')));
    if (payload) r.write(payload);
    r.end();
  });
}

async function pg(sql) {
  const r = await req({
    host: 'api.supabase.com', path: `/v1/projects/${PROJECT}/database/query`, method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql }),
  });
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.slice(0, 300)}`);
  return JSON.parse(r.body);
}

let JOBBER_TOKEN = null;
async function getToken() {
  const r = await req({ host: SB_URL.replace('https://', '').split('/')[0], path: '/rest/v1/webhook_tokens?source_system=eq.jobber&select=access_token,refresh_token,expires_at', headers: { apikey: KEY, Authorization: `Bearer ${KEY}` } });
  const row = JSON.parse(r.body)[0];
  const expMs = new Date(row.expires_at).getTime();
  if (expMs > Date.now() + 60_000) { JOBBER_TOKEN = row.access_token; return; }
  const CLIENT_ID = process.env.JOBBER_CLIENT_ID, CLIENT_SECRET = process.env.JOBBER_CLIENT_SECRET;
  const body = `grant_type=refresh_token&refresh_token=${encodeURIComponent(row.refresh_token)}&client_id=${encodeURIComponent(CLIENT_ID)}&client_secret=${encodeURIComponent(CLIENT_SECRET)}`;
  const tr = await req({ host: 'api.getjobber.com', path: '/api/oauth/token', method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body });
  const tokens = JSON.parse(tr.body);
  const newExpMs = JSON.parse(Buffer.from(tokens.access_token.split('.')[1], 'base64').toString()).exp * 1000;
  await req({ host: SB_URL.replace('https://', '').split('/')[0], path: '/rest/v1/webhook_tokens?source_system=eq.jobber', method: 'PATCH', headers: { apikey: KEY, Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ access_token: tokens.access_token, refresh_token: tokens.refresh_token || row.refresh_token, expires_at: new Date(newExpMs).toISOString(), updated_at: new Date().toISOString() }) });
  JOBBER_TOKEN = tokens.access_token;
}

async function jobberIsCompany(gid) {
  const r = await req({
    host: 'api.getjobber.com', path: '/api/graphql', method: 'POST',
    headers: { Authorization: `Bearer ${JOBBER_TOKEN}`, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16' },
    body: JSON.stringify({
      query: `query($id: EncodedId!) { client(id: $id) { id isCompany } }`,
      variables: { id: gid },
    }),
  });
  if (r.status === 401) throw new Error('token-expired');
  const j = JSON.parse(r.body);
  if (j.errors) return { error: j.errors[0].message };
  if (!j.data?.client) return { error: 'no client returned' };
  return { isCompany: j.data.client.isCompany };
}

(async () => {
  console.log(`Mode: ${APPLY ? 'APPLY' : 'DRY-RUN'}`);
  console.log('Loading Jobber-linked clients…');
  await getToken();

  const rows = await pg(`
    SELECT c.id, c.name, c.client_class AS current_class,
           c.client_class_source AS class_source,
           esl.source_id AS jobber_gid
    FROM public.clients c
    JOIN public.entity_source_links esl
      ON esl.entity_type='client' AND esl.entity_id=c.id AND esl.source_system='jobber'
    ORDER BY c.id;
  `);
  console.log(`${rows.length} Jobber-linked clients to inspect.\n`);

  const willUpdate = [], unchanged = [], errors = [];
  let lastRefresh = Date.now();
  for (let i = 0; i < rows.length; i++) {
    const r = rows[i];
    // Skip manual overrides — a hand-set client_class (e.g. residential clients
    // Jobber reports isCompany=true) must not be re-derived. The DB trigger
    // trg_clients_protect_manual_class would silently revert it anyway, but
    // skipping here keeps the report accurate (no phantom willUpdate). See
    // docs/migrations/2026-06-24_clients_class_source.sql.
    if (r.class_source === 'manual') { unchanged.push({ id: r.id, class: r.current_class, manual: true }); continue; }
    if (Date.now() - lastRefresh > 5 * 60_000) { await getToken(); lastRefresh = Date.now(); }
    if (i > 0 && i % 50 === 0) console.log(`  ${i}/${rows.length}  upd=${willUpdate.length} same=${unchanged.length} err=${errors.length}`);

    let res;
    try { res = await jobberIsCompany(r.jobber_gid); }
    catch (e) {
      if (e.message === 'token-expired') {
        await getToken(); lastRefresh = Date.now();
        try { res = await jobberIsCompany(r.jobber_gid); }
        catch (e2) { errors.push({ id: r.id, name: r.name, err: e2.message }); continue; }
      } else { errors.push({ id: r.id, name: r.name, err: e.message }); continue; }
    }
    if (res.error) { errors.push({ id: r.id, name: r.name, err: res.error }); continue; }

    const newClass = res.isCompany ? 'commercial' : 'residential';
    if (r.current_class === newClass) { unchanged.push({ id: r.id, class: newClass }); }
    else { willUpdate.push({ id: r.id, name: r.name, from: r.current_class, to: newClass }); }

    await new Promise(s => setTimeout(s, 60));
  }

  const commercial = [...willUpdate, ...unchanged].filter(x => x.to === 'commercial' || x.class === 'commercial').length;
  const residential = [...willUpdate, ...unchanged].filter(x => x.to === 'residential' || x.class === 'residential').length;
  console.log(`\nSurveyed:    ${rows.length}`);
  console.log(`Commercial:  ${commercial}`);
  console.log(`Residential: ${residential}`);
  console.log(`Errors:      ${errors.length}`);
  console.log(`Will UPDATE: ${willUpdate.length}  (unchanged: ${unchanged.length})`);

  if (errors.length > 0) {
    console.log(`\nErrors (first 10):`);
    for (const e of errors.slice(0, 10)) console.log(`  id=${e.id} ${e.name}: ${e.err}`);
  }

  if (!APPLY) { console.log('\n(dry-run; pass --apply to write)'); return; }

  // Apply UPDATEs in batches via PostgREST (PATCH per row to keep audit attribution simple)
  console.log(`\nApplying ${willUpdate.length} UPDATEs…`);
  const H = {
    apikey: KEY, Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json',
    'X-App-Source': 'sql', Prefer: 'return=minimal',
  };
  let ok = 0, fail = 0;
  for (const u of willUpdate) {
    const pr = await req({
      host: SB_URL.replace('https://', '').split('/')[0],
      path: `/rest/v1/clients?id=eq.${u.id}`, method: 'PATCH',
      headers: H, body: JSON.stringify({ client_class: u.to }),
    });
    if (pr.status < 300) ok++;
    else { fail++; console.log(`  FAIL id=${u.id}: ${pr.status} ${pr.body.slice(0,200)}`); }
  }
  console.log(`UPDATE results: ok=${ok} fail=${fail}`);

  // Report
  const dateStr = new Date().toISOString().slice(0, 10);
  const out = path.resolve(__dirname, `../../reports/clients_class_backfill_${dateStr}.json`);
  try { fs.mkdirSync(path.dirname(out), { recursive: true }); } catch {}
  fs.writeFileSync(out, JSON.stringify({
    ran_at: new Date().toISOString(),
    mode: APPLY ? 'apply' : 'dry-run',
    universe: rows.length,
    will_update_count: willUpdate.length,
    unchanged_count: unchanged.length,
    errors_count: errors.length,
    updates: willUpdate,
    errors,
  }, null, 2));
  console.log(`Wrote: ${out}`);
})().catch(e => { console.error('FAILED:', e.message); process.exit(1); });
