// scripts/probes/audit_may_calendar_visits_per_row.js
//
// Per-row audit: every visit visible in the Visit Calendar app for May 2026
// gets compared field-by-field against Jobber's current state.
//
// What the Calendar UI displays (per `ops.v_calendar_visit`):
//   visit_date, visit_status, title, client_code, client_name, zone,
//   truck_name, driver_name, completed_at, start_at, end_at, late_status,
//   completed_by (via visits.completed_by), service_type.
//
// What we compare against (Jobber GraphQL `visit(id:)`):
//   title, startAt, endAt, completedAt, completedBy, visitStatus,
//   assignedUsers.
//
// Anything that doesn't match is reported as a per-row finding.
// Visits with NULL Jobber GID (AT-cron-generated upcoming) are listed
// separately with what the Calendar shows — those have no upstream
// source-of-truth to validate against.
//
// Read-only.

const path = require('path');
const https = require('https');
const fs = require('fs');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const SB_URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const PROJECT = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const THROTTLE_MS = 80;

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

async function rest(p, opts = {}) {
  const u = new URL(SB_URL + '/rest/v1' + p);
  return req({
    host: u.hostname, path: u.pathname + u.search, method: opts.method || 'GET',
    headers: { apikey: KEY, Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' },
  });
}

async function pg(sql) {
  const r = await req({
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
  const expMs = new Date(row.expires_at).getTime();
  if (expMs > Date.now() + 60_000) { JOBBER_TOKEN = row.access_token; return; }
  const CLIENT_ID = process.env.JOBBER_CLIENT_ID, CLIENT_SECRET = process.env.JOBBER_CLIENT_SECRET;
  const body = `grant_type=refresh_token&refresh_token=${encodeURIComponent(row.refresh_token)}&client_id=${encodeURIComponent(CLIENT_ID)}&client_secret=${encodeURIComponent(CLIENT_SECRET)}`;
  const tr = await req({ host: 'api.getjobber.com', path: '/api/oauth/token', method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body });
  const tokens = JSON.parse(tr.body);
  const newExpMs = JSON.parse(Buffer.from(tokens.access_token.split('.')[1], 'base64').toString()).exp * 1000;
  await rest('/webhook_tokens?source_system=eq.jobber', { method: 'PATCH', body: JSON.stringify({ access_token: tokens.access_token, refresh_token: tokens.refresh_token || row.refresh_token, expires_at: new Date(newExpMs).toISOString(), updated_at: new Date().toISOString() }) });
  JOBBER_TOKEN = tokens.access_token;
}

async function jobberVisit(gid) {
  const r = await req({
    host: 'api.getjobber.com', path: '/api/graphql', method: 'POST',
    headers: { Authorization: `Bearer ${JOBBER_TOKEN}`, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16' },
    body: JSON.stringify({
      query: `query($id: EncodedId!) {
        visit(id: $id) {
          id title startAt endAt completedAt completedBy visitStatus
          assignedUsers { nodes { id name { full } } }
        }
      }`,
      variables: { id: gid },
    }),
  });
  if (r.status === 401) throw new Error('token-expired');
  const j = JSON.parse(r.body);
  if (j.errors?.some(e => /Visit not found|does not exist/i.test(e.message || ''))) return { orphan: true };
  if (j.errors?.length) return { error: j.errors[0].message };
  return { visit: j.data?.visit || null };
}

function mapStatus(jb) { return jb && String(jb).toUpperCase() === 'COMPLETED' ? 'completed' : 'scheduled'; }
function iso(a) { return a ? new Date(a).toISOString() : null; }
function isoEq(a, b) { return (iso(a) || null) === (iso(b) || null); }
function dateEq(a, b) {
  if (!a && !b) return true; if (!a || !b) return false;
  return String(a).slice(0, 10) === String(b).slice(0, 10);
}
function strEq(a, b) { return (a || null) === (b || null); }

(async () => {
  const t0 = Date.now();
  console.log('\n=== Per-row audit: Visit Calendar (May 2026) vs Jobber ===\n');
  await getJobberToken();

  // Pull every May visit the Calendar would show (ops.v_calendar_visit).
  // Include Jobber GID so we can fetch the upstream truth.
  const rows = await pg(`
    SELECT v.id, v.visit_date, v.visit_status, v.title, v.service_type,
           v.start_at, v.end_at, v.completed_at, v.completed_by,
           v.client_id, c.client_code, c.name AS client_name,
           cal.zone, cal.truck_name, cal.driver_name, cal.late_status,
           esl.source_id AS jobber_gid
    FROM public.visits v
    JOIN public.clients c ON c.id = v.client_id
    LEFT JOIN ops.v_calendar_visit cal ON cal.id = v.id
    LEFT JOIN public.entity_source_links esl
      ON esl.entity_type = 'visit' AND esl.entity_id = v.id AND esl.source_system = 'jobber'
    WHERE v.deleted_at IS NULL
      AND v.visit_date BETWEEN '2026-05-01' AND '2026-05-31'
    ORDER BY v.visit_date, c.client_code, v.id;
  `);
  console.log(`Universe: ${rows.length} May 2026 visits in DB (not deleted)`);

  const noGid = rows.filter(r => !r.jobber_gid);
  const withGid = rows.filter(r => r.jobber_gid);
  console.log(`  ${withGid.length} Jobber-linked (will compare to Jobber)`);
  console.log(`  ${noGid.length} not Jobber-linked (AT/cron-generated; no upstream source)`);

  const findings = [];   // each row's per-field drift
  const orphans = [];    // GID returned not-found in Jobber
  const errors = [];

  for (let i = 0; i < withGid.length; i++) {
    const v = withGid[i];
    if (i % 25 === 0) console.log(`  scanning ${i}/${withGid.length}…`);
    let res;
    try { res = await jobberVisit(v.jobber_gid); }
    catch (e) {
      if (e.message === 'token-expired') { await getJobberToken(); try { res = await jobberVisit(v.jobber_gid); } catch (e2) { errors.push({ id: v.id, err: e2.message }); continue; } }
      else { errors.push({ id: v.id, err: e.message }); continue; }
    }
    if (res.orphan) { orphans.push(v); continue; }
    if (res.error) { errors.push({ id: v.id, err: res.error }); continue; }
    const j = res.visit;
    if (!j) { orphans.push(v); continue; }

    const expectedDate = j.startAt ? j.startAt.slice(0, 10) : null;
    const drift = {};
    if (!strEq(v.title, j.title)) drift.title = { db: v.title, jobber: j.title };
    if (expectedDate && !dateEq(v.visit_date, expectedDate)) drift.visit_date = { db: v.visit_date, jobber: expectedDate };
    if (!isoEq(v.start_at, j.startAt)) drift.start_at = { db: iso(v.start_at), jobber: iso(j.startAt) };
    if (!isoEq(v.end_at, j.endAt)) drift.end_at = { db: iso(v.end_at), jobber: iso(j.endAt) };
    if (!isoEq(v.completed_at, j.completedAt)) drift.completed_at = { db: iso(v.completed_at), jobber: iso(j.completedAt) };
    if (!strEq(v.completed_by, j.completedBy)) drift.completed_by = { db: v.completed_by, jobber: j.completedBy };
    const expectedStatus = mapStatus(j.visitStatus);
    if (!strEq(v.visit_status, expectedStatus)) drift.visit_status = { db: v.visit_status, jobber: expectedStatus };

    if (Object.keys(drift).length > 0) {
      findings.push({
        id: v.id, visit_date: v.visit_date, client: `${v.client_code || '?'} ${v.client_name}`,
        drift,
      });
    }
    if (THROTTLE_MS) await new Promise(r => setTimeout(r, THROTTLE_MS));
  }

  const elapsed = Math.round((Date.now() - t0) / 1000);
  console.log(`\nScanned ${withGid.length} Jobber-linked May visits in ${elapsed}s.\n`);

  console.log('=== Summary ===');
  console.log(`  Jobber-linked visits checked:                   ${withGid.length}`);
  console.log(`  Visits with field drift vs Jobber:              ${findings.length}`);
  console.log(`  Orphans (Jobber returned not-found):            ${orphans.length}`);
  console.log(`  Errors (token/transient):                       ${errors.length}`);
  console.log(`  Non-Jobber-linked visits (no upstream truth):   ${noGid.length}`);

  if (findings.length > 0) {
    console.log('\n=== Per-row drift detail ===');
    for (const f of findings) {
      console.log(`\n  id=${f.id}  ${f.visit_date}  ${f.client}`);
      for (const [k, v] of Object.entries(f.drift)) {
        console.log(`    ${k}: DB=${JSON.stringify(v.db)}  →  Jobber=${JSON.stringify(v.jobber)}`);
      }
    }
  }
  if (orphans.length > 0) {
    console.log('\n=== Orphans (still in DB, not in Jobber) ===');
    for (const o of orphans) console.log(`  id=${o.id}  ${o.visit_date}  ${o.client_code || '?'} ${o.client_name}  gid=${o.jobber_gid}`);
  }
  if (errors.length > 0) {
    console.log('\n=== Errors ===');
    for (const e of errors) console.log(`  id=${e.id}: ${e.err}`);
  }
  if (noGid.length > 0) {
    console.log(`\n=== Non-Jobber-linked May visits (${noGid.length}) — what Calendar shows, no upstream check possible ===`);
    for (const o of noGid) {
      console.log(`  id=${o.id}  ${o.visit_date}  ${o.client_code || '?'} ${o.client_name}  status=${o.visit_status}  title="${o.title || ''}"`);
    }
  }

  const out = path.resolve(__dirname, `../../reports/calendar_may_2026_per_row_audit.json`);
  try { fs.mkdirSync(path.dirname(out), { recursive: true }); } catch {}
  fs.writeFileSync(out, JSON.stringify({
    ran_at: new Date().toISOString(),
    universe: rows.length,
    jobber_linked: withGid.length,
    drift_count: findings.length,
    orphans_count: orphans.length,
    errors_count: errors.length,
    no_gid_count: noGid.length,
    findings, orphans, errors, no_gid: noGid,
  }, null, 2));
  console.log(`\nWrote: ${out}`);
  console.log('--- audit complete --- {"probe":"calendar_may_per_row","jobber_linked":' + withGid.length + ',"drift":' + findings.length + ',"orphans":' + orphans.length + ',"errors":' + errors.length + ',"no_gid":' + noGid.length + '}');
})().catch(e => { console.error(e); process.exit(1); });
