// Backfill public.line_items for jobs that have visits but no invoice yet.
//
// Background: Jobber's Job has a `lineItems` field (the planned services).
// Our webhook-jobber handleJob handler doesn't pull them — only invoice
// handler does. Result: 48 completed visits with no invoice fall back to
// title parsing on the DERM Tracker, missing the real services.
//
// Example: visit 5127 (El Chaman, job 10000342) — Jobber shows
//   Camera Inspection / FOG Assessment / Grease Trap Pumping and Cleaning
//   / Hydrojet Cleaning Commercial
// but our DB shows "For service rendered" (visit-title fallback).
//
// Strategy:
//   1. Find unique job_ids needing pull (have completed visit + no invoice
//      + no line_items by job_id).
//   2. For each, query Jobber GraphQL for the job's lineItems.
//   3. INSERT into line_items keyed by job_id (idempotent on
//      (job_id, name) tuple — we delete-then-insert per job for safety).
//   4. View migration in a separate step re-adds job_id fallback after
//      invoice path is empty.
//
// 3NF/types/audit compliance:
//   - line_items table shape unchanged.
//   - INSERT triggers audit (table opted-in by default).
//   - Re-runnable; replaces job_id rows so stale items can't accumulate.
//   - No hard delete of business data — line_items are derived sync data.
//
// Run: node scripts/sync/backfill_job_line_items_from_jobber.js [--execute]
const path = require('path');
const fs = require('fs');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
// Jobber tokens rotate often. Slack/.env carries the latest because the
// jobber-token.sh helper writes back there. Read it directly so we don't
// have to keep two .env files in sync.
function readSlackEnv(key) {
  const slackEnv = path.resolve(__dirname, '../../../Slack/.env');
  if (!fs.existsSync(slackEnv)) return null;
  const lines = fs.readFileSync(slackEnv, 'utf8').split(/\r?\n/);
  for (const l of lines) {
    const m = l.match(new RegExp('^' + key + '=(.*)$'));
    if (m) return m[1].replace(/^['"]|['"]$/g, '').trim();
  }
  return null;
}
const JOBBER_TOKEN = readSlackEnv('JOBBER_ACCESS_TOKEN') || process.env.JOBBER_ACCESS_TOKEN;
if (JOBBER_TOKEN) {
  console.log('Jobber token loaded (len ' + JOBBER_TOKEN.length + ')');
}
const PROJECT = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const EXECUTE = process.argv.includes('--execute');

const JOBBER_GQL = 'https://api.getjobber.com/api/graphql';

async function rest(qs, opts = {}) {
  const r = await fetch(`${URL}/rest/v1/${qs}`, {
    ...opts,
    headers: { apikey: KEY, Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json', ...(opts.headers || {}) },
  });
  if (!r.ok) throw new Error(`REST ${r.status} ${await r.text()}`);
  const t = await r.text();
  return t ? JSON.parse(t) : null;
}
async function sql(q) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROJECT}/database/query`, {
    method: 'POST', headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: q }),
  });
  if (!r.ok) throw new Error(`SQL ${r.status} ${await r.text()}`);
  return r.json();
}
async function jobber(query, variables = {}) {
  const r = await fetch(JOBBER_GQL, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${JOBBER_TOKEN}`,
      'Content-Type': 'application/json',
      'X-JOBBER-GRAPHQL-VERSION': '2026-04-16',
    },
    body: JSON.stringify({ query, variables }),
  });
  if (!r.ok) throw new Error(`Jobber ${r.status} ${await r.text()}`);
  const j = await r.json();
  if (j.errors) throw new Error(`Jobber GQL: ${JSON.stringify(j.errors).slice(0, 300)}`);
  return j.data;
}

// Fetch Jobber GID for a job from our entity_source_links
async function gidForJob(dbJobId) {
  const r = await rest(`entity_source_links?entity_type=eq.job&source_system=eq.jobber&entity_id=eq.${dbJobId}&select=source_id`);
  return r?.[0]?.source_id || null;
}

(async () => {
  console.log(`Mode: ${EXECUTE ? 'EXECUTE' : 'DRY-RUN'}\n`);

  // Find unique jobs needing pull
  const jobs = await sql(`
    WITH need AS (
      SELECT DISTINCT v.job_id
      FROM visits v
      WHERE v.visit_status = 'completed'
        AND v.invoice_id IS NULL
        AND v.job_id IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM line_items li WHERE li.job_id = v.job_id)
    )
    SELECT n.job_id, j.job_number, j.title
    FROM need n JOIN jobs j ON j.id = n.job_id
    ORDER BY n.job_id;
  `);
  console.log(`${jobs.length} unique jobs to backfill`);

  if (jobs.length === 0) {
    console.log('Nothing to do.');
    return;
  }

  let pulled = 0, totalItems = 0, fail = 0;

  for (const j of jobs) {
    try {
      const gid = await gidForJob(j.job_id);
      if (!gid) { console.log(`  job ${j.job_id} (#${j.job_number}): no Jobber GID linked; skip`); fail++; continue; }

      // Query Jobber for the job's lineItems
      const data = await jobber(
        `query($id: EncodedId!) {
          job(id: $id) {
            id jobNumber title
            lineItems(first: 50) {
              nodes { name description quantity unitCost totalPrice }
            }
          }
        }`,
        { id: gid },
      );
      const items = data.job?.lineItems?.nodes || [];
      console.log(`  job ${j.job_id} (#${j.job_number} "${j.title?.slice(0,30)}"): ${items.length} line items`);
      totalItems += items.length;

      if (!items.length || !EXECUTE) continue;

      // Idempotency: delete any existing job-level rows for this job, re-insert
      await rest(`line_items?job_id=eq.${j.job_id}`, { method: 'DELETE', headers: { Prefer: 'return=minimal' } });
      const rows = items.map(it => ({
        job_id: j.job_id,
        name: it.name || null,
        description: it.description || null,
        quantity: it.quantity || null,
        unit_price: it.unitCost || null,
        total_price: it.totalPrice || null,
      }));
      await rest('line_items', {
        method: 'POST',
        headers: { Prefer: 'return=minimal' },
        body: JSON.stringify(rows),
      });
      pulled++;
    } catch (e) {
      console.warn(`  job ${j.job_id} FAIL:`, e.message?.slice(0, 200));
      fail++;
    }
  }

  console.log(`\n=== Summary ===`);
  console.table([
    { metric: 'jobs checked',  count: jobs.length },
    { metric: 'jobs synced',   count: pulled },
    { metric: 'failures',      count: fail },
    { metric: 'line items pulled', count: totalItems },
    { metric: 'mode',          count: EXECUTE ? 'EXECUTE' : 'DRY-RUN' },
  ]);
})().catch(err => { console.error('FATAL:', err); process.exit(1); });
