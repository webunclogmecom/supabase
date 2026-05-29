// scripts/probes/full_jobber_drift_sweep.js
//
// Full-DB sweep: for every public.visits row with a Jobber GID and
// visit_date between (today - 90 days) and (today + 90 days), query
// Jobber's current state and report 3 anomaly classes:
//   - DATE_DRIFT     — DB.visit_date != Jobber.startAt::date
//   - ORPHAN_VISIT   — GID exists in our entity_source_links but Jobber's
//                      visit() returns null (visit deleted or converted)
//   - INVERTED       — Jobber's completedAt < Jobber's startAt
//
// Read-only. Outputs JSON to stdout, also writes audit-results to
// reports/jobber_drift_<date>.json.

const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const PROJECT = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;

const H = { apikey: KEY, Authorization: `Bearer ${KEY}` };

async function sql(q) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROJECT}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: q }),
  });
  if (!r.ok) throw new Error(`SQL ${r.status} ${await r.text()}`);
  return r.json();
}

let JOBBER_TOKEN = process.env.JOBBER_ACCESS_TOKEN;
async function refreshToken() {
  const r = await fetch(`${URL}/rest/v1/webhook_tokens?source_system=eq.jobber&select=access_token`, { headers: H });
  JOBBER_TOKEN = (await r.json())[0]?.access_token;
}

async function gql(query, variables = {}) {
  const r = await fetch('https://api.getjobber.com/api/graphql', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${JOBBER_TOKEN}`,
      'Content-Type': 'application/json',
      'X-JOBBER-GRAPHQL-VERSION': '2026-04-16',
    },
    body: JSON.stringify({ query, variables }),
  });
  const j = await r.json();
  return { status: r.status, data: j.data, errors: j.errors };
}

async function main() {
  await refreshToken();
  const today = new Date().toISOString().slice(0, 10);
  console.log(`Today: ${today}`);

  const rows = await sql(`
    SELECT v.id, v.visit_date, v.visit_status, v.title,
           v.start_at, v.completed_at,
           c.client_code, c.name AS client_name,
           esl.source_id AS jobber_gid
    FROM public.visits v
    JOIN public.clients c ON c.id = v.client_id
    JOIN public.entity_source_links esl
      ON esl.entity_type = 'visit' AND esl.entity_id = v.id AND esl.source_system = 'jobber'
    WHERE v.visit_date BETWEEN ('${today}'::date - INTERVAL '90 days')::date
                           AND ('${today}'::date + INTERVAL '90 days')::date
    ORDER BY v.visit_date DESC;
  `);
  console.log(`Universe: ${rows.length} Jobber-linked visits in ±90-day window.`);

  const drift = [], orphan = [], inverted = [], errors = [];
  let scanned = 0, lastLog = Date.now(), lastTokenRefresh = Date.now();
  for (const r of rows) {
    scanned++;
    // Refresh token every 5 min to ride out expiration mid-sweep
    if (Date.now() - lastTokenRefresh > 5 * 60 * 1000) {
      await refreshToken();
      lastTokenRefresh = Date.now();
    }
    if (Date.now() - lastLog > 5000) {
      console.log(`  ... scanned ${scanned}/${rows.length} (drift=${drift.length} orphan=${orphan.length} inverted=${inverted.length} err=${errors.length})`);
      lastLog = Date.now();
    }
    try {
      const res = await gql(
        `query($id: EncodedId!) { visit(id: $id) { id startAt endAt completedAt visitStatus } }`,
        { id: r.jobber_gid }
      );
      // "Visit not found" classifies as ORPHAN, not error
      if (res.errors?.some(e => /Visit not found|does not exist/i.test(e.message || ''))) {
        orphan.push({ ...r, jobber_status: 'NOT_FOUND' });
        continue;
      }
      if (res.errors?.length) {
        errors.push({ id: r.id, gid: r.jobber_gid, errs: res.errors });
        continue;
      }
      const v = res.data?.visit;
      if (!v) { orphan.push({ ...r, jobber_status: 'NULL' }); continue; }
      const jDate = v.startAt?.slice(0, 10) || null;
      if (jDate && jDate !== r.visit_date) {
        drift.push({ ...r, jobber_startAt: v.startAt, jobber_completedAt: v.completedAt, jobber_date: jDate, jobber_status: v.visitStatus });
      }
      if (v.completedAt && v.startAt && v.completedAt.slice(0, 10) < v.startAt.slice(0, 10)) {
        inverted.push({ ...r, jobber_startAt: v.startAt, jobber_completedAt: v.completedAt, jobber_status: v.visitStatus });
      }
    } catch (e) {
      // network error — retry once after token refresh
      try {
        await refreshToken();
        lastTokenRefresh = Date.now();
        const res = await gql(
          `query($id: EncodedId!) { visit(id: $id) { id startAt endAt completedAt visitStatus } }`,
          { id: r.jobber_gid }
        );
        if (res.errors?.some(e => /Visit not found|does not exist/i.test(e.message || ''))) {
          orphan.push({ ...r, jobber_status: 'NOT_FOUND' });
        } else if (res.errors?.length) {
          errors.push({ id: r.id, gid: r.jobber_gid, errs: res.errors });
        } else if (!res.data?.visit) {
          orphan.push({ ...r, jobber_status: 'NULL' });
        } else {
          const v = res.data.visit;
          const jDate = v.startAt?.slice(0, 10) || null;
          if (jDate && jDate !== r.visit_date) drift.push({ ...r, jobber_startAt: v.startAt, jobber_completedAt: v.completedAt, jobber_date: jDate, jobber_status: v.visitStatus });
          if (v.completedAt && v.startAt && v.completedAt.slice(0, 10) < v.startAt.slice(0, 10)) inverted.push({ ...r, jobber_startAt: v.startAt, jobber_completedAt: v.completedAt, jobber_status: v.visitStatus });
        }
      } catch (e2) {
        errors.push({ id: r.id, gid: r.jobber_gid, error: `retry failed: ${e2.message}` });
      }
    }
  }
  console.log(`\nDone scanning ${scanned} visits.`);

  const summary = {
    today,
    universe: rows.length,
    drift_count: drift.length,
    orphan_count: orphan.length,
    inverted_count: inverted.length,
    errors_count: errors.length,
    drift,
    orphan,
    inverted,
    errors,
  };
  const out = path.resolve(__dirname, `../../reports/jobber_drift_${today}.json`);
  try { fs.mkdirSync(path.dirname(out), { recursive: true }); } catch {}
  fs.writeFileSync(out, JSON.stringify(summary, null, 2));
  console.log(`Wrote: ${out}\n`);

  console.log('=== Summary =================================================');
  console.log(`  Universe (Jobber-linked, ±90d):          ${rows.length}`);
  console.log(`  DATE_DRIFT (DB ≠ Jobber.startAt):        ${drift.length}`);
  console.log(`  ORPHAN_VISIT (Jobber returns null):      ${orphan.length}`);
  console.log(`  INVERTED (Jobber completedAt < startAt): ${inverted.length}`);
  console.log(`  GraphQL errors:                          ${errors.length}`);

  if (drift.length) {
    console.log('\n  --- Date drift cases ---');
    for (const d of drift) console.log(`    ${d.client_code || '?'} ${d.client_name}: DB=${d.visit_date} JOBBER=${d.jobber_date} (id=${d.id})`);
  }
  if (orphan.length) {
    console.log('\n  --- Orphan visits (not in Jobber as Visit) ---');
    for (const o of orphan) console.log(`    ${o.client_code || '?'} ${o.client_name}: DB=${o.visit_date} (id=${o.id} gid=${o.jobber_gid})`);
  }
  if (inverted.length) {
    console.log('\n  --- Inverted timelines (rescheduled after completion) ---');
    for (const i of inverted) console.log(`    ${i.client_code || '?'} ${i.client_name}: scheduled=${i.jobber_startAt} completed=${i.jobber_completedAt} (id=${i.id})`);
  }
}

main().catch(e => { console.error(e); process.exit(1); });
