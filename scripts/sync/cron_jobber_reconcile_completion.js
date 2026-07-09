// ============================================================================
// cron_jobber_reconcile_completion.js — daily Jobber visit completion drift fix
// ============================================================================
// Closes a structural blind spot in cron_jobber.js: the visits-pull cursor uses
// `completedAt`, so when a visit is un-completed in Jobber (completedAt cleared
// to NULL) it drops out of the cron's delta query forever. VISIT_UPDATE webhooks
// don't always fire for these edits either (confirmed 2026-05-27 with the
// Kendall visit — 7 days of zero webhook events for that record).
//
// Strategy: every day, scan our DB visits we have as `completed` with
// visit_date in the last 60 days, fetch each one's current state from Jobber
// GraphQL, and reconcile any drift on visit_status / completed_at / start_at /
// end_at / visit_date.
//
// Idempotent. Read-then-update only. Audit triggers fire automatically.
// Doesn't touch visits with source != 'jobber' (those don't have a Jobber GID).
//
// Run:
//   node scripts/sync/cron_jobber_reconcile_completion.js              # dry-run
//   node scripts/sync/cron_jobber_reconcile_completion.js --execute    # apply
//
// CLI flags:
//   --execute    actually update the DB; default is dry-run
//   --days=N     scan last N days of completed visits (default 60)
//   --limit=N    cap visits processed per run (default unlimited)
//
// Rate-limit budget: Jobber GraphQL gives ~10,000 cost burst + 500/sec restore.
// `visit(id:)` query costs ~14. 1800 visits × 14 = 25,200 cost. After burst we
// throttle to 500/sec → ~50 s extra wall-clock. Add 80 ms throttle between
// queries to stay comfortable.
// ============================================================================

const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });
const https = require('https');
const { operatingDateET } = require('../lib/operating_date_et');

// app_source attribution for this cron's writes (ADR 016) — so the Calendar
// activity feed shows this reconcile by name instead of the opaque "System".
const APP_SOURCE = 'jobber-daily-completion-reconcile';

const SUPABASE_URL = process.env.SUPABASE_URL;
const SERVICE_KEY  = process.env.SUPABASE_SERVICE_ROLE_KEY;
const CLIENT_ID    = process.env.JOBBER_CLIENT_ID;
const CLIENT_SECRET= process.env.JOBBER_CLIENT_SECRET;
if (!SUPABASE_URL || !SERVICE_KEY) throw new Error('SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY required');
if (!CLIENT_ID || !CLIENT_SECRET) throw new Error('JOBBER_CLIENT_ID + JOBBER_CLIENT_SECRET required');

const EXECUTE = process.argv.includes('--execute');
const DAYS = parseInt((process.argv.find(a => a.startsWith('--days=')) || '--days=60').split('=')[1], 10);
const LIMIT = parseInt((process.argv.find(a => a.startsWith('--limit=')) || '--limit=0').split('=')[1], 10) || null;

console.log('='.repeat(70));
console.log(`cron_jobber_reconcile_completion  mode=${EXECUTE ? 'EXECUTE' : 'DRY-RUN'}  days=${DAYS}  limit=${LIMIT ?? 'none'}`);
console.log('='.repeat(70));

// ---- low-level helpers --------------------------------------------------------

function request({ host, path: urlPath, method = 'GET', headers = {}, body = null }) {
  return new Promise((resolve, reject) => {
    const payload = body == null ? null : (typeof body === 'string' ? body : JSON.stringify(body));
    const req = https.request({
      hostname: host, path: urlPath, method,
      headers: { ...headers, ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}) },
    }, (res) => {
      let data = '';
      res.on('data', (c) => (data += c));
      res.on('end', () => resolve({ status: res.statusCode, body: data, headers: res.headers }));
    });
    req.on('error', reject);
    req.setTimeout(30_000, () => req.destroy(new Error('timeout')));
    if (payload) req.write(payload);
    req.end();
  });
}

async function rest(qs, opts = {}) {
  const u = new URL(`${SUPABASE_URL}/rest/v1${qs}`);
  return request({
    host: u.hostname, path: u.pathname + u.search, method: opts.method || 'GET',
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      'Content-Type': 'application/json',
      Prefer: 'return=representation',
      ...(opts.headers || {}),
    },
    body: opts.body || null,
  });
}

// ---- token + GraphQL ---------------------------------------------------------

async function getJobberToken() {
  const r = await rest('/webhook_tokens?source_system=eq.jobber&select=access_token,refresh_token,expires_at');
  if (r.status !== 200) throw new Error(`webhook_tokens read failed: ${r.status} ${r.body}`);
  const row = JSON.parse(r.body)[0];
  if (!row) throw new Error('No jobber webhook_tokens row');
  const expMs = new Date(row.expires_at).getTime();
  if (expMs > Date.now() + 60_000) return row.access_token;
  // Refresh
  console.log('[reconcile] access token expiring; refreshing');
  const body = `grant_type=refresh_token&refresh_token=${encodeURIComponent(row.refresh_token)}&client_id=${encodeURIComponent(CLIENT_ID)}&client_secret=${encodeURIComponent(CLIENT_SECRET)}`;
  const tr = await request({
    host: 'api.getjobber.com', path: '/api/oauth/token', method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body,
  });
  if (tr.status >= 300) throw new Error(`Refresh failed ${tr.status}: ${tr.body.slice(0, 200)}`);
  const tokens = JSON.parse(tr.body);
  const newExpMs = JSON.parse(Buffer.from(tokens.access_token.split('.')[1], 'base64').toString()).exp * 1000;
  await rest('/webhook_tokens?source_system=eq.jobber', {
    method: 'PATCH',
    body: JSON.stringify({
      access_token: tokens.access_token,
      refresh_token: tokens.refresh_token || row.refresh_token,
      expires_at: new Date(newExpMs).toISOString(),
      updated_at: new Date().toISOString(),
    }),
  });
  return tokens.access_token;
}

async function jobberVisit(token, gid) {
  const body = JSON.stringify({
    query: `query VisitState($id: EncodedId!) {
      visit(id: $id) { id startAt endAt completedAt visitStatus }
    }`,
    variables: { id: gid },
  });
  const r = await request({
    host: 'api.getjobber.com', path: '/api/graphql', method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
      'X-JOBBER-GRAPHQL-VERSION': '2026-04-16',
    },
    body,
  });
  if (r.status === 401) throw new Error('token-expired');
  if (r.status >= 300) throw new Error(`gql ${r.status}: ${r.body.slice(0, 200)}`);
  const j = JSON.parse(r.body);
  if (j.errors) throw new Error(`gql errors: ${JSON.stringify(j.errors).slice(0, 200)}`);
  return j.data.visit;
}

// ---- DB helpers (Management API for SQL) --------------------------------------

async function pg(sql) {
  const PAT = process.env.SUPABASE_PAT;
  const PROD = process.env.SUPABASE_PROJECT_ID;
  if (!PAT || !PROD) throw new Error('SUPABASE_PAT + SUPABASE_PROJECT_ID required for raw SQL');
  const r = await request({
    host: 'api.supabase.com', path: `/v1/projects/${PROD}/database/query`, method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql }),
  });
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.slice(0, 400)}`);
  return JSON.parse(r.body);
}

// ---- reconciliation core -----------------------------------------------------

// Map Jobber visitStatus → our visit_status column. We use lowercase.
function mapStatus(jb) {
  if (!jb) return 'scheduled';
  const s = String(jb).toUpperCase();
  if (s === 'COMPLETED') return 'completed';
  // Everything else (SCHEDULED, LATE, ACTIVE, etc.) maps to 'scheduled' in our model.
  return 'scheduled';
}

async function fetchDbCandidates() {
  return pg(`
    SELECT v.id, v.visit_status, v.completed_at, v.visit_date,
           v.start_at, v.end_at,
           esl.source_id AS jobber_gid
    FROM public.visits v
    JOIN public.entity_source_links esl
      ON esl.entity_type = 'visit' AND esl.entity_id = v.id AND esl.source_system = 'jobber'
    WHERE v.visit_status = 'completed'
      AND v.visit_date >= CURRENT_DATE - INTERVAL '${DAYS} days'
    ORDER BY v.visit_date DESC
    ${LIMIT ? `LIMIT ${LIMIT}` : ''};
  `);
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

(async () => {
  const t0 = Date.now();
  let token = await getJobberToken();

  const candidates = await fetchDbCandidates();
  console.log(`Candidates to check: ${candidates.length}`);

  const drift = [];
  const tokenExpired = [];
  let processed = 0;

  for (const v of candidates) {
    processed++;
    if (processed % 100 === 0) {
      console.log(`  [${processed}/${candidates.length}]  drift so far=${drift.length}`);
    }

    let jbVisit;
    try {
      jbVisit = await jobberVisit(token, v.jobber_gid);
    } catch (e) {
      if (e.message === 'token-expired') {
        token = await getJobberToken();
        jbVisit = await jobberVisit(token, v.jobber_gid);
      } else {
        console.log(`  visit ${v.id} (${v.jobber_gid.slice(0, 20)}…) FAILED: ${e.message}`);
        continue;
      }
    }
    if (!jbVisit) {
      // Could be deleted in Jobber. We don't auto-delete; just log.
      console.log(`  visit ${v.id} not found in Jobber (possibly deleted upstream)`);
      continue;
    }

    const newStatus = mapStatus(jbVisit.visitStatus);
    const statusDrift = newStatus !== v.visit_status;
    const completedDrift = !isoEq(v.completed_at, jbVisit.completedAt);
    const startDrift = !isoEq(v.start_at, jbVisit.startAt);
    const endDrift = !isoEq(v.end_at, jbVisit.endAt);
    // visit_date = the ET CLOCK date of start_at (operatingDateET), matching the DB
    // trigger. NOT startAt.slice(0,10) (raw UTC = +1 day for evening-ET visits, which
    // the trigger flips back → the ±1-day oscillation bug, 2026-07-09).
    const newVisitDate = operatingDateET(jbVisit.startAt);
    const dateDrift = newVisitDate && !dateEq(v.visit_date, newVisitDate);

    if (statusDrift || completedDrift || startDrift || endDrift || dateDrift) {
      drift.push({
        id: v.id,
        gid_tail: v.jobber_gid.slice(-12),
        status: statusDrift ? `${v.visit_status}→${newStatus}` : v.visit_status,
        completed_at: completedDrift ? `${v.completed_at}→${jbVisit.completedAt}` : '·',
        visit_date: dateDrift ? `${v.visit_date}→${newVisitDate}` : '·',
        start_at: startDrift ? `${v.start_at}→${jbVisit.startAt}` : '·',
        jbStatus: jbVisit.visitStatus,
      });

      if (EXECUTE) {
        // Build patch
        const updates = [];
        if (statusDrift) updates.push(`visit_status='${newStatus}'`);
        if (completedDrift) updates.push(`completed_at=${jbVisit.completedAt ? `'${jbVisit.completedAt}'::timestamptz` : 'NULL'}`);
        if (startDrift) updates.push(`start_at=${jbVisit.startAt ? `'${jbVisit.startAt}'::timestamptz` : 'NULL'}`);
        if (endDrift) updates.push(`end_at=${jbVisit.endAt ? `'${jbVisit.endAt}'::timestamptz` : 'NULL'}`);
        // visit_date is derived from start_at by trg_aa_reconcile_operating_date.
        // Only ever CO-WRITE it with a start_at change (keeps the pair consistent in one
        // write). NEVER write visit_date standalone: that fires the trigger's date-drag
        // branch and shoves start_at ±1 day — the oscillation root cause.
        if (dateDrift && startDrift) updates.push(`visit_date='${newVisitDate}'::date`);
        else if (dateDrift && !startDrift) {
          console.log(`  visit ${v.id} date-only drift (DB ${v.visit_date} vs ET ${newVisitDate}) with matching start_at — SKIPPED (trigger owns visit_date; a standalone write would date-drag start_at)`);
        }
        if (updates.length) {
          try {
            // Two transaction-local settings prefix the UPDATE (same Management-API query):
            //  - "request.headers" carries X-App-Source (audit attribution; else 'sql' = "System").
            //  - "app.suppress_jobber_push"='on' stops the echo: this is a MATCH-JOBBER reconcile
            //    (read Jobber → write DB), so it must NEVER push back. Without it, a write to a
            //    Calendar/cron-mastered row (source in visit-calendar/supabase_cron) fires
            //    trg_push_visit_update ~1-2s later — the exact path that ratcheted the pre-fix
            //    UTC-date bug INTO Jobber and can revert a dispatch edit made in that window.
            // The schedule UPDATE flips sync_state->'pending' (trg_mark_visit_sync_pending is NOT
            // GUC-gated), which the */3-min resolve-stale cron would then re-push — defeating the
            // suppress. A sync_state-only finisher back to 'confirmed' (DB now == Jobber, nothing to
            // push) closes that, same pattern adopt_visit_schedule_from_jobber uses (07-08). A
            // sync_state-only UPDATE trips neither the mark diff nor the push WHEN.
            await pg(`SET LOCAL "request.headers" = '{"x-app-source":"${APP_SOURCE}"}'; SET LOCAL "app.suppress_jobber_push" = 'on'; UPDATE public.visits SET ${updates.join(', ')} WHERE id = ${v.id}; UPDATE public.visits SET sync_state='confirmed' WHERE id = ${v.id} AND sync_state='pending';`);
          } catch (e) {
            console.log(`  visit ${v.id} UPDATE FAILED: ${e.message}`);
          }
        }
      }
    }

    // Throttle: 80 ms between queries → ~12 req/s → comfortable under burst.
    await new Promise((r) => setTimeout(r, 80));
  }

  console.log('');
  console.log('='.repeat(70));
  console.log(`Drift found: ${drift.length} / ${processed} visits checked`);
  if (drift.length > 0) {
    console.table(drift.slice(0, 50));
    if (drift.length > 50) console.log(`...and ${drift.length - 50} more`);
  }
  console.log(`Wall time: ${((Date.now() - t0) / 1000).toFixed(1)}s`);
  console.log(EXECUTE ? '(EXECUTE) updates applied' : '(DRY-RUN) re-run with --execute to apply');
})().catch((e) => { console.error('FATAL:', e); process.exit(1); });
