// scripts/sync/_phase5_reconcile_assignments.js
//
// Phase 5 of the 2026-05-29 cleanup directive (per Fred):
// "check on Jobber, all visits that have been completed, who they were
//  assigned to, and if the visits we have in the DB has the correct
//  assigned people. Remember a Visit can have multiple assigned people."
//
// Procedure:
//   1. Pre-cache: pull every employee Jobber GID from entity_source_links
//      so we can map Jobber user GIDs → employees.id locally.
//   2. Pull every completed visit (Jobber-linked) in the DB along with
//      its current set of visit_assignments rows.
//   3. For each visit, query Jobber GraphQL visit() with
//      assignedUsers { nodes { id } }.
//   4. Diff:
//        missing  — Jobber GID has no matching DB visit_assignments row → INSERT
//        extra    — DB has row for an employee Jobber didn't return → DELETE
//        unknown  — Jobber GID has no matching employee row in our DB →
//                   surface for manual review (don't auto-create employee).
//   5. Audit attribution via app_source='sql'.
//
// Samsara cross-ref (driver-by-GPS-presence-at-property) is intentionally
// LEFT FOR PHASE 5b — it requires geofence overlap math per visit and is a
// separate compute load. Today we trust Jobber's assignedUsers as canonical.
//
// CLI:
//   node scripts/sync/_phase5_reconcile_assignments.js              # dry-run
//   node scripts/sync/_phase5_reconcile_assignments.js --execute    # apply

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
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, 'Content-Type': 'application/json', 'X-App-Source': 'sql', ...(opts.headers || {}) },
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
  const body = `grant_type=refresh_token&refresh_token=${encodeURIComponent(row.refresh_token)}&client_id=${encodeURIComponent(CLIENT_ID)}&client_secret=${encodeURIComponent(CLIENT_SECRET)}`;
  const tr = await request({ host: 'api.getjobber.com', path: '/api/oauth/token', method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body });
  const tokens = JSON.parse(tr.body);
  const newExpMs = JSON.parse(Buffer.from(tokens.access_token.split('.')[1], 'base64').toString()).exp * 1000;
  await rest('/webhook_tokens?source_system=eq.jobber', { method: 'PATCH', body: JSON.stringify({ access_token: tokens.access_token, refresh_token: tokens.refresh_token || row.refresh_token, expires_at: new Date(newExpMs).toISOString(), updated_at: new Date().toISOString() }) });
  JOBBER_TOKEN = tokens.access_token;
  console.log(`[phase5] token refreshed; new exp ${new Date(newExpMs).toISOString()}`);
}

async function jobberVisitAssignees(gid) {
  const r = await request({
    host: 'api.getjobber.com', path: '/api/graphql', method: 'POST',
    headers: { Authorization: `Bearer ${JOBBER_TOKEN}`, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16' },
    body: JSON.stringify({
      query: 'query($id: EncodedId!) { visit(id: $id) { id visitStatus assignedUsers { nodes { id } } } }',
      variables: { id: gid },
    }),
  });
  if (r.status === 401) throw new Error('token-expired');
  const j = JSON.parse(r.body);
  if (j.errors?.some(e => /Visit not found|does not exist/i.test(e.message || ''))) return { orphan: true };
  if (j.errors?.length) return { error: j.errors[0].message };
  return { visit: j.data?.visit || null };
}

(async () => {
  const t0 = Date.now();
  console.log(`\n=== PHASE 5: reconcile visit assignments (${EXECUTE ? 'EXECUTE' : 'DRY-RUN'}) ===\n`);
  await getJobberToken();

  // 1. Pre-cache employee Jobber GID → employee.id
  const empLinks = await pg(`
    SELECT esl.source_id AS jobber_gid, esl.entity_id AS employee_id, e.full_name
    FROM public.entity_source_links esl
    JOIN public.employees e ON e.id = esl.entity_id
    WHERE esl.entity_type = 'employee' AND esl.source_system = 'jobber';
  `);
  const empMap = new Map();
  for (const e of empLinks) empMap.set(e.jobber_gid, { id: e.employee_id, name: e.full_name });
  console.log(`Loaded ${empMap.size} employee Jobber GID → DB employee mappings.\n`);

  // 2. Pull every completed Jobber-linked visit + its current DB assignments
  const visits = await pg(`
    SELECT v.id, v.visit_date, v.title, v.completed_at,
           c.client_code, c.name AS client_name,
           esl.source_id AS jobber_gid,
           COALESCE(
             (SELECT array_agg(va.employee_id) FROM public.visit_assignments va WHERE va.visit_id = v.id),
             ARRAY[]::bigint[]
           ) AS db_employee_ids
    FROM public.visits v
    JOIN public.clients c ON c.id = v.client_id
    JOIN public.entity_source_links esl
      ON esl.entity_type = 'visit' AND esl.entity_id = v.id AND esl.source_system = 'jobber'
    WHERE v.visit_status = 'completed'
    ORDER BY v.visit_date DESC
    ${LIMIT ? `LIMIT ${LIMIT}` : ''};
  `);
  console.log(`Universe: ${visits.length} completed Jobber-linked visits.\n`);

  let processed = 0, lastTokenRefresh = Date.now();
  const missing = [], extra = [], unknownJobberUser = [], errors = [], orphans = [];

  for (const v of visits) {
    processed++;
    if (Date.now() - lastTokenRefresh > 5 * 60_000) {
      await getJobberToken();
      lastTokenRefresh = Date.now();
    }
    if (processed % 100 === 0) {
      console.log(`  [${processed}/${visits.length}] missing=${missing.length} extra=${extra.length} unknown=${unknownJobberUser.length}`);
    }
    let res;
    try {
      res = await jobberVisitAssignees(v.jobber_gid);
    } catch (e) {
      if (e.message === 'token-expired') {
        await getJobberToken();
        lastTokenRefresh = Date.now();
        try { res = await jobberVisitAssignees(v.jobber_gid); } catch (e2) { errors.push({ id: v.id, err: e2.message }); continue; }
      } else { errors.push({ id: v.id, err: e.message }); continue; }
    }
    if (res.orphan) { orphans.push(v); continue; }
    if (res.error) { errors.push({ id: v.id, err: res.error }); continue; }
    if (!res.visit) { orphans.push(v); continue; }

    const jbUserGids = (res.visit.assignedUsers?.nodes || []).map(n => n.id);
    const jbEmpIds = new Set();
    const unmapped = [];
    for (const gid of jbUserGids) {
      const e = empMap.get(gid);
      if (e) jbEmpIds.add(e.id);
      else unmapped.push(gid);
    }
    if (unmapped.length > 0) unknownJobberUser.push({ visit_id: v.id, jobber_gid_tail: v.jobber_gid.slice(-12), unmapped });

    const dbEmpIds = new Set((v.db_employee_ids || []).map(x => Number(x)));
    const toAdd = [...jbEmpIds].filter(id => !dbEmpIds.has(id));
    const toRemove = [...dbEmpIds].filter(id => !jbEmpIds.has(id));

    for (const empId of toAdd) missing.push({ visit_id: v.id, employee_id: empId, visit_date: v.visit_date, client_code: v.client_code });
    for (const empId of toRemove) extra.push({ visit_id: v.id, employee_id: empId, visit_date: v.visit_date, client_code: v.client_code });

    if (EXECUTE && (toAdd.length > 0 || toRemove.length > 0)) {
      if (toAdd.length > 0) {
        const rows = toAdd.map(empId => ({ visit_id: v.id, employee_id: empId }));
        const r = await rest('/visit_assignments?on_conflict=visit_id,employee_id', {
          method: 'POST',
          body: JSON.stringify(rows),
          headers: { Prefer: 'resolution=ignore-duplicates,return=minimal' },
        });
        if (r.status >= 300) errors.push({ id: v.id, err: `insert ${r.status}: ${r.body.slice(0, 200)}` });
      }
      if (toRemove.length > 0) {
        for (const empId of toRemove) {
          const r = await rest(`/visit_assignments?visit_id=eq.${v.id}&employee_id=eq.${empId}`, {
            method: 'DELETE', headers: { Prefer: 'return=minimal' },
          });
          if (r.status >= 300) errors.push({ id: v.id, err: `delete ${r.status}: ${r.body.slice(0, 200)}` });
        }
      }
    }
    if (THROTTLE_MS) await new Promise(r => setTimeout(r, THROTTLE_MS));
  }

  const elapsed = Math.round((Date.now() - t0) / 1000);
  console.log(`\nScanned ${processed} visits in ${elapsed}s.\n`);
  console.log(`=== Summary =================================================`);
  console.log(`  Missing assignments (Jobber has, DB doesn't) — would INSERT: ${missing.length}`);
  console.log(`  Extra assignments (DB has, Jobber doesn't)  — would DELETE: ${extra.length}`);
  console.log(`  Unknown Jobber user GIDs (not in our employees table): ${unknownJobberUser.length}`);
  console.log(`  Orphan visits (no longer in Jobber): ${orphans.length}`);
  console.log(`  Errors: ${errors.length}`);

  if (missing.length > 0 && missing.length <= 30) {
    console.log('\n  Missing detail:');
    for (const m of missing) console.log(`    visit_id=${m.visit_id} (${m.client_code} ${m.visit_date}) ← employee_id=${m.employee_id}`);
  } else if (missing.length > 30) {
    console.log(`\n  (${missing.length} missing rows — suppressed)`);
  }
  if (extra.length > 0 && extra.length <= 30) {
    console.log('\n  Extra detail (DB has but Jobber doesn\'t):');
    for (const e of extra) console.log(`    visit_id=${e.visit_id} (${e.client_code} ${e.visit_date}) employee_id=${e.employee_id}`);
  } else if (extra.length > 30) {
    console.log(`\n  (${extra.length} extra rows — suppressed)`);
  }
  if (unknownJobberUser.length > 0 && unknownJobberUser.length <= 10) {
    console.log('\n  Unknown Jobber users (need to seed employee + ESL link):');
    for (const u of unknownJobberUser) console.log(`    visit ${u.visit_id} (gid …${u.jobber_gid_tail}) → ${u.unmapped.join(', ')}`);
  }

  console.log('--- audit complete --- {"probe":"phase5_reconcile_assignments","scanned":' + processed + ',"missing":' + missing.length + ',"extra":' + extra.length + ',"unknown":' + unknownJobberUser.length + '}');
})().catch(e => { console.error(e); process.exit(1); });
