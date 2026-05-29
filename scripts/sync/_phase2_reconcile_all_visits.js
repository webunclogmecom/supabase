// scripts/sync/_phase2_reconcile_all_visits.js
//
// Phase 2 of the 2026-05-29 cleanup directive (per Fred):
// "update all visits"
//
// For every Jobber-linked visit remaining in the DB (after Phase 1's orphan
// hard-delete), pull Jobber's current state and reconcile drift on:
//   - visit_status     (Jobber's visitStatus mapped to lowercase canonical)
//   - completed_at     (timestamptz)
//   - completed_by     (text — driver name; Jobber returns user name)
//   - start_at         (timestamptz)
//   - end_at           (timestamptz)
//   - visit_date       (= start_at::date)
//   - title            (text)
//
// CLI:
//   node scripts/sync/_phase2_reconcile_all_visits.js              # dry-run
//   node scripts/sync/_phase2_reconcile_all_visits.js --execute    # apply
//   node scripts/sync/_phase2_reconcile_all_visits.js --limit=50   # cap

const path = require('path');
const https = require('https');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const URL_BASE = process.env.SUPABASE_URL;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const PAT = process.env.SUPABASE_PAT;
const PROJECT = process.env.SUPABASE_PROJECT_ID;
const EXECUTE = process.argv.includes('--execute');
const LIMIT_ARG = process.argv.find(a => a.startsWith('--limit='));
const LIMIT = LIMIT_ARG ? parseInt(LIMIT_ARG.split('=')[1], 10) : null;
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
    host: u.hostname, path: u.pathname + u.search, method: opts.method || 'GET',
    headers: {
      apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`,
      'Content-Type': 'application/json', 'X-App-Source': 'sql', ...(opts.headers || {}),
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
  console.log(`[phase2] token refreshed; new exp ${new Date(newExpMs).toISOString()}`);
}

async function jobberVisit(gid) {
  const r = await request({
    host: 'api.getjobber.com', path: '/api/graphql', method: 'POST',
    headers: { Authorization: `Bearer ${JOBBER_TOKEN}`, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16' },
    body: JSON.stringify({
      query: 'query($id: EncodedId!) { visit(id: $id) { id title startAt endAt completedAt completedBy visitStatus } }',
      variables: { id: gid },
    }),
  });
  if (r.status === 401) throw new Error('token-expired');
  const j = JSON.parse(r.body);
  if (j.errors?.some(e => /Visit not found|does not exist/i.test(e.message || ''))) return { orphan: true };
  if (j.errors?.length) return { error: j.errors[0].message };
  return { visit: j.data?.visit || null };
}

function mapStatus(jb) {
  if (!jb) return 'scheduled';
  return String(jb).toUpperCase() === 'COMPLETED' ? 'completed' : 'scheduled';
}

function isoEq(a, b) {
  if (!a && !b) return true;
  if (!a || !b) return false;
  return new Date(a).getTime() === new Date(b).getTime();
}

function dateEq(a, b) {
  if (!a && !b) return true;
  if (!a || !b) return false;
  return String(a).slice(0, 10) === String(b).slice(0, 10);
}

function strEq(a, b) {
  return (a || null) === (b || null);
}

(async () => {
  const t0 = Date.now();
  console.log(`\n=== PHASE 2: reconcile all visit fields from Jobber (${EXECUTE ? 'EXECUTE' : 'DRY-RUN'}) ===\n`);
  await getJobberToken();

  const rows = await pg(`
    SELECT v.id, v.visit_status, v.visit_date, v.start_at, v.end_at,
           v.completed_at, v.completed_by, v.title,
           esl.source_id AS jobber_gid
    FROM public.visits v
    JOIN public.entity_source_links esl
      ON esl.entity_type = 'visit' AND esl.entity_id = v.id AND esl.source_system = 'jobber'
    ${LIMIT ? `ORDER BY v.visit_date DESC LIMIT ${LIMIT}` : 'ORDER BY v.visit_date DESC'};
  `);
  console.log(`Universe: ${rows.length} Jobber-linked visits.\n`);

  const drift = [], orphans = [], errors = [];
  let processed = 0, updated = 0, lastTokenRefresh = Date.now();

  for (const v of rows) {
    processed++;
    if (Date.now() - lastTokenRefresh > 5 * 60_000) {
      await getJobberToken();
      lastTokenRefresh = Date.now();
    }
    if (processed % 100 === 0) {
      console.log(`  [${processed}/${rows.length}] drift=${drift.length} orphans=${orphans.length} updated=${updated}`);
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
    if (res.orphan) { orphans.push(v); continue; }
    if (res.error) { errors.push({ id: v.id, err: res.error }); continue; }
    const j = res.visit;
    if (!j) { orphans.push(v); continue; }

    // Compute drift
    const newStatus = mapStatus(j.visitStatus);
    const newDate = j.startAt ? j.startAt.slice(0, 10) : null;
    const updates = {};
    if (!strEq(v.visit_status, newStatus)) updates.visit_status = newStatus;
    if (!isoEq(v.completed_at, j.completedAt)) updates.completed_at = j.completedAt || null;
    if (!strEq(v.completed_by, j.completedBy)) updates.completed_by = j.completedBy || null;
    if (!isoEq(v.start_at, j.startAt)) updates.start_at = j.startAt || null;
    if (!isoEq(v.end_at, j.endAt)) updates.end_at = j.endAt || null;
    if (newDate && !dateEq(v.visit_date, newDate)) updates.visit_date = newDate;
    if (!strEq(v.title, j.title)) updates.title = j.title || null;

    if (Object.keys(updates).length > 0) {
      drift.push({ id: v.id, gid: v.jobber_gid.slice(-12), updates });
      if (EXECUTE) {
        try {
          const r = await rest(`/visits?id=eq.${v.id}`, {
            method: 'PATCH', body: JSON.stringify(updates), headers: { Prefer: 'return=minimal' },
          });
          if (r.status >= 300) { errors.push({ id: v.id, err: `update ${r.status}: ${r.body.slice(0, 200)}` }); }
          else updated++;
        } catch (e) {
          errors.push({ id: v.id, err: `update failed: ${e.message}` });
        }
      }
    }
    if (THROTTLE_MS) await new Promise(r => setTimeout(r, THROTTLE_MS));
  }

  const elapsed = Math.round((Date.now() - t0) / 1000);
  console.log(`\nScanned ${processed} visits in ${elapsed}s.`);
  console.log(`\n=== Summary =================================================`);
  console.log(`  DRIFT fields detected: ${drift.length}`);
  console.log(`  UPDATED: ${updated}`);
  console.log(`  ORPHANS (still): ${orphans.length}`);
  console.log(`  ERRORS: ${errors.length}`);

  if (drift.length > 0 && drift.length <= 30) {
    console.log('\n  Drift detail:');
    for (const d of drift) console.log(`    id=${d.id} gid=…${d.gid} updates=${JSON.stringify(d.updates)}`);
  } else if (drift.length > 30) {
    console.log(`\n  (drift detail suppressed — ${drift.length} > 30 rows; see returned JSON in fix log)`);
  }

  if (orphans.length > 0) {
    console.log('\n  Orphans (unexpected — should have been cleared by Phase 1):');
    for (const o of orphans) console.log(`    id=${o.id} gid=…${o.jobber_gid.slice(-12)}`);
  }
  if (errors.length > 0 && errors.length <= 20) {
    console.log('\n  Errors:');
    for (const e of errors) console.log(`    id=${e.id}: ${e.err}`);
  }

  console.log('--- audit complete --- {"probe":"phase2_reconcile_all_visits","scanned":' + processed + ',"drift":' + drift.length + ',"updated":' + updated + ',"orphans":' + orphans.length + '}');
})().catch(e => { console.error(e); process.exit(1); });
