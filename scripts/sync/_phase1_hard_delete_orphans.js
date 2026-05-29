// scripts/sync/_phase1_hard_delete_orphans.js
//
// Phase 1 of the 2026-05-29 cleanup directive (per Fred):
// "if we have visits that are not in Jobber, delete them — and I mean hard delete."
//
// Procedure:
//   1. Pull every public.visits row joined to entity_source_links
//      (entity_type='visit', source_system='jobber') — the "Jobber universe".
//   2. For each, query Jobber GraphQL visit(id:) and classify:
//        - OK              → leave alone
//        - Visit not found → ORPHAN, hard-delete
//        - other error     → log + skip
//   3. For each ORPHAN, detach soft refs (notes, jobber_oversized_attachments),
//      delete the ESL row, then DELETE the visit. CASCADE handles
//      visit_assignments / manifest_visits / visit_recommendations.
//   4. Audit trigger on public.visits captures the full row JSONB on DELETE,
//      so the history is preserved in audit.logs with app_source='sql'.
//
// CLI:
//   node scripts/sync/_phase1_hard_delete_orphans.js              # dry-run
//   node scripts/sync/_phase1_hard_delete_orphans.js --execute    # apply

const path = require('path');
const https = require('https');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const URL_BASE = process.env.SUPABASE_URL;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const PAT = process.env.SUPABASE_PAT;
const PROJECT = process.env.SUPABASE_PROJECT_ID;
const EXECUTE = process.argv.includes('--execute');
const THROTTLE_MS = 80;

function request({ host, path, method = 'GET', headers = {}, body = null }) {
  return new Promise((resolve, reject) => {
    const payload = body == null ? null : (typeof body === 'string' ? body : JSON.stringify(body));
    const req = https.request({ hostname: host, path, method, headers: { ...headers, ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}) } }, (res) => {
      let d = ''; res.on('data', c => (d += c));
      res.on('end', () => resolve({ status: res.statusCode, body: d }));
    });
    req.on('error', reject);
    req.setTimeout(60_000, () => req.destroy(new Error('timeout')));
    if (payload) req.write(payload);
    req.end();
  });
}

async function rest(p, opts = {}) {
  const u = new URL(URL_BASE + '/rest/v1' + p);
  return request({
    host: u.hostname,
    path: u.pathname + u.search,
    method: opts.method || 'GET',
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      'Content-Type': 'application/json',
      'X-App-Source': 'sql',
      ...(opts.headers || {}),
    },
    body: opts.body,
  });
}

async function pg(sql) {
  const r = await request({
    host: 'api.supabase.com', path: `/v1/projects/${PROJECT}/database/query`, method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql }),
  });
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.slice(0, 400)}`);
  return JSON.parse(r.body);
}

let JOBBER_TOKEN = null;
async function getJobberToken() {
  const r = await rest('/webhook_tokens?source_system=eq.jobber&select=access_token,refresh_token,expires_at');
  const row = JSON.parse(r.body)[0];
  if (!row) throw new Error('No jobber row in webhook_tokens');
  const expMs = new Date(row.expires_at).getTime();
  if (expMs > Date.now() + 60_000) { JOBBER_TOKEN = row.access_token; return; }
  const CLIENT_ID = process.env.JOBBER_CLIENT_ID, CLIENT_SECRET = process.env.JOBBER_CLIENT_SECRET;
  if (!CLIENT_ID || !CLIENT_SECRET) throw new Error('Token expired and JOBBER_CLIENT_ID/SECRET not set');
  const body = `grant_type=refresh_token&refresh_token=${encodeURIComponent(row.refresh_token)}&client_id=${encodeURIComponent(CLIENT_ID)}&client_secret=${encodeURIComponent(CLIENT_SECRET)}`;
  const tr = await request({ host: 'api.getjobber.com', path: '/api/oauth/token', method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body });
  if (tr.status >= 300) throw new Error(`Refresh failed ${tr.status}`);
  const tokens = JSON.parse(tr.body);
  const newExpMs = JSON.parse(Buffer.from(tokens.access_token.split('.')[1], 'base64').toString()).exp * 1000;
  await rest('/webhook_tokens?source_system=eq.jobber', { method: 'PATCH', body: JSON.stringify({ access_token: tokens.access_token, refresh_token: tokens.refresh_token || row.refresh_token, expires_at: new Date(newExpMs).toISOString(), updated_at: new Date().toISOString() }) });
  JOBBER_TOKEN = tokens.access_token;
  console.log(`[phase1] token refreshed; new exp ${new Date(newExpMs).toISOString()}`);
}

async function jobberVisit(gid) {
  const r = await request({
    host: 'api.getjobber.com', path: '/api/graphql', method: 'POST',
    headers: { Authorization: `Bearer ${JOBBER_TOKEN}`, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16' },
    body: JSON.stringify({ query: 'query($id: EncodedId!) { visit(id: $id) { id } }', variables: { id: gid } }),
  });
  if (r.status === 401) throw new Error('token-expired');
  const j = JSON.parse(r.body);
  if (j.errors?.some(e => /Visit not found|does not exist/i.test(e.message || ''))) return { orphan: true };
  if (j.errors?.length) return { error: j.errors[0].message };
  if (!j.data?.visit) return { orphan: true };
  return { ok: true };
}

async function hardDeleteVisit(id) {
  // Detach soft refs
  await pg(`UPDATE public.notes SET visit_id = NULL WHERE visit_id = ${id};`);
  await pg(`UPDATE public.jobber_oversized_attachments SET visit_id = NULL WHERE visit_id = ${id};`);
  // Drop ESL row(s) for this visit (no FK, manual)
  await pg(`DELETE FROM public.entity_source_links WHERE entity_type='visit' AND entity_id = ${id};`);
  // Drop the visit (CASCADE on visit_assignments, manifest_visits, visit_recommendations)
  const r = await pg(`DELETE FROM public.visits WHERE id = ${id} RETURNING id;`);
  return r;
}

(async () => {
  const t0 = Date.now();
  console.log(`\n=== PHASE 1: orphan visit sweep (${EXECUTE ? 'EXECUTE' : 'DRY-RUN'}) ===`);
  await getJobberToken();

  const rows = await pg(`
    SELECT v.id, v.visit_date, v.visit_status, v.deleted_at,
           c.client_code, c.name AS client_name,
           esl.source_id AS jobber_gid
    FROM public.visits v
    JOIN public.clients c ON c.id = v.client_id
    JOIN public.entity_source_links esl
      ON esl.entity_type = 'visit' AND esl.entity_id = v.id AND esl.source_system = 'jobber'
    ORDER BY v.visit_date DESC;
  `);
  console.log(`Universe: ${rows.length} Jobber-linked visits.\n`);

  const orphans = [], errors = [];
  let processed = 0, lastTokenRefresh = Date.now();

  for (const v of rows) {
    processed++;
    if (Date.now() - lastTokenRefresh > 5 * 60_000) {
      await getJobberToken();
      lastTokenRefresh = Date.now();
    }
    if (processed % 100 === 0) {
      console.log(`  [${processed}/${rows.length}] orphans=${orphans.length} errors=${errors.length}`);
    }
    let res;
    try {
      res = await jobberVisit(v.jobber_gid);
    } catch (e) {
      if (e.message === 'token-expired') {
        await getJobberToken();
        lastTokenRefresh = Date.now();
        try { res = await jobberVisit(v.jobber_gid); } catch (e2) { errors.push({ id: v.id, err: e2.message }); continue; }
      } else {
        errors.push({ id: v.id, err: e.message });
        continue;
      }
    }
    if (res.orphan) {
      orphans.push(v);
    } else if (res.error) {
      errors.push({ id: v.id, err: res.error });
    }
    if (THROTTLE_MS) await new Promise(r => setTimeout(r, THROTTLE_MS));
  }

  const elapsed = Math.round((Date.now() - t0) / 1000);
  console.log(`\nScanned ${processed} visits in ${elapsed}s.`);
  console.log(`\n=== Orphans found: ${orphans.length} ===`);
  for (const o of orphans) {
    console.log(`  id=${o.id} ${o.client_code || '?'} ${o.client_name} visit_date=${o.visit_date} status=${o.visit_status} deleted_at=${o.deleted_at || 'null'}`);
  }
  if (errors.length) {
    console.log(`\n=== Errors: ${errors.length} ===`);
    for (const e of errors.slice(0, 20)) console.log(`  id=${e.id}: ${e.err}`);
  }

  if (!EXECUTE) {
    console.log(`\n(dry-run; pass --execute to hard-delete the ${orphans.length} orphan(s))`);
    return;
  }

  console.log(`\n=== Hard-deleting ${orphans.length} orphan(s) ===`);
  let deleted = 0, failed = 0;
  for (const o of orphans) {
    try {
      const r = await hardDeleteVisit(o.id);
      console.log(`  ✓ deleted id=${o.id} (${o.client_code || '?'} ${o.client_name} ${o.visit_date})`);
      deleted++;
    } catch (e) {
      console.error(`  ✗ FAILED id=${o.id}: ${e.message}`);
      failed++;
    }
  }
  console.log(`\nDone. Deleted=${deleted}, Failed=${failed}.`);
  console.log('--- audit complete --- {"probe":"phase1_hard_delete_orphans","scanned":' + processed + ',"orphans":' + orphans.length + ',"deleted":' + deleted + '}');
})().catch(e => { console.error(e); process.exit(1); });
