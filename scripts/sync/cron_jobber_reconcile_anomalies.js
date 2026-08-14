// ============================================================================
// cron_jobber_reconcile_anomalies.js — nightly Jobber anomaly reconciler
// ============================================================================
//
// Closes 3 gaps left open by cron_jobber.js + cron_jobber_reconcile_completion.js:
//
//   1. ORPHAN VISITS — Jobber returns "Visit not found" for the stored GID.
//      Means the Visit was deleted or converted to a Task in Jobber. Our
//      reconcile_completion script logs but doesn't act on these.
//      Action: set public.visits.deleted_at = NOW().
//
//   2. SCHEDULED-VISIT DATE DRIFT — A Jobber user reschedules a non-completed
//      visit. cron_jobber's cursor is `completedAt`, so it never sees this.
//      reconcile_completion only checks completed visits. Result: visit sits
//      in our DB on the old date forever.
//      Action: UPDATE visit_date / start_at / end_at to Jobber's current
//      values when DB visit_status='scheduled' AND drift > 0.
//
//   3. INVERTED TIMELINE — Jobber's completedAt < startAt by more than 1 day.
//      Means someone in Jobber rescheduled an already-completed visit. The
//      future "scheduled" entry isn't a real upcoming visit.
//      Action: LOG only — surface in summary for ops review. Auto-deletion
//      requires explicit Fred sign-off per case (one such case, visit 5146
//      009-CN, was hard-deleted on 2026-05-29 by manual repair script).
//
// Audit attribution: all writes go through Management API (which lands in
// audit.logs as app_source='sql'). Read-only by default; pass --execute
// to apply mutations.
//
// CLI:
//   node scripts/sync/cron_jobber_reconcile_anomalies.js               # dry-run
//   node scripts/sync/cron_jobber_reconcile_anomalies.js --execute     # apply
//   node scripts/sync/cron_jobber_reconcile_anomalies.js --days=120    # custom window
//   node scripts/sync/cron_jobber_reconcile_anomalies.js --limit=50    # cap rows scanned
//
// Required env (set as GitHub Actions secrets when wired to a workflow):
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_PAT,
//   SUPABASE_PROJECT_ID, JOBBER_CLIENT_ID, JOBBER_CLIENT_SECRET
//
// Idempotent — running twice produces zero additional drift.
// ============================================================================

const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });
const https = require('https');
const { operatingDateET } = require('../lib/operating_date_et');

// app_source attribution (ADR 016) — so the Calendar activity feed shows this
// reconcile by name instead of the opaque "System".
const APP_SOURCE = 'jobber-daily-anomaly-reconcile';

const URL_BASE = process.env.SUPABASE_URL;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const PAT = process.env.SUPABASE_PAT;
const PROJECT = process.env.SUPABASE_PROJECT_ID;

if (!URL_BASE || !SERVICE_KEY || !PAT || !PROJECT) {
  throw new Error('Missing one of SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / SUPABASE_PAT / SUPABASE_PROJECT_ID');
}

const argv = process.argv.slice(2);
const arg = (name, def) => {
  const f = argv.find(a => a.startsWith(`--${name}=`));
  return f ? f.split('=')[1] : def;
};
const EXECUTE = argv.includes('--execute');
const DAYS = parseInt(arg('days', '90'), 10);
const LIMIT = parseInt(arg('limit', '0'), 10) || null;
const THROTTLE_MS = parseInt(arg('throttle', '80'), 10);
const INVERSION_HOURS_THRESHOLD = parseFloat(arg('inversion-hours', '24'));

// ---------------------------------------------------------------------------

function request({ host, path, method = 'GET', headers = {}, body = null }) {
  return new Promise((resolve, reject) => {
    const payload = body == null ? null : (typeof body === 'string' ? body : JSON.stringify(body));
    const req = https.request({
      hostname: host, path, method,
      headers: { ...headers, ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}) },
    }, (res) => {
      let d = ''; res.on('data', c => (d += c));
      // headers exposed so callers can tell a GraphQL reply from Jobber's HTML waiting room;
      // the status code is 200 for both, so it cannot be used to distinguish them.
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: d }));
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
      'X-App-Source': APP_SOURCE,
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
  // Read current token. If it's < 60s from expiry, refresh via OAuth
  // (same pattern as cron_jobber.js).
  const r = await rest('/webhook_tokens?source_system=eq.jobber&select=access_token,refresh_token,expires_at');
  const row = JSON.parse(r.body)[0];
  if (!row) throw new Error('No jobber row in webhook_tokens');

  const expMs = new Date(row.expires_at).getTime();
  if (expMs > Date.now() + 60_000) {
    JOBBER_TOKEN = row.access_token;
    return JOBBER_TOKEN;
  }

  const CLIENT_ID = process.env.JOBBER_CLIENT_ID;
  const CLIENT_SECRET = process.env.JOBBER_CLIENT_SECRET;
  if (!CLIENT_ID || !CLIENT_SECRET) throw new Error('Token expired and JOBBER_CLIENT_ID/SECRET not set');

  console.log('[reconcile] token expiring; refreshing');
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
  JOBBER_TOKEN = tokens.access_token;
  console.log(`[reconcile] refreshed; new exp ${new Date(newExpMs).toISOString()}`);
  return JOBBER_TOKEN;
}

async function gqlVisit(gid) {
  const r = await request({
    host: 'api.getjobber.com', path: '/api/graphql', method: 'POST',
    headers: {
      Authorization: `Bearer ${JOBBER_TOKEN}`,
      'Content-Type': 'application/json',
      'X-JOBBER-GRAPHQL-VERSION': '2026-04-16',
    },
    body: JSON.stringify({
      query: 'query($id: EncodedId!) { visit(id: $id) { id startAt endAt completedAt visitStatus } }',
      variables: { id: gid },
    }),
  });
  if (r.status === 401) throw new Error('token-expired');
  if (r.status >= 500) throw new Error(`gql ${r.status}`);

  // 🛑 AN UNANSWERED QUESTION IS NOT AN ORPHAN (2026-08-13).
  // The orphan branch below fires on `!res.data?.visit`, which cannot distinguish
  //   "Jobber answered, and this visit is gone"      <- a real orphan, soft-delete it
  // from
  //   "Jobber did not answer"                        <- an outage, touch nothing
  // and a full run soft-deletes EVERY candidate it asks about: 756 visits at --days=90,
  // 512 of them completed history and 269 carrying manifest_visits DERM links, which would
  // drop those compliance records out of customer.work_orders and the Field Portal. There is
  // no cap: --limit bounds rows SCANNED and defaults to none. So the two cases must be
  // separated HERE, before that branch can see them. Both guards THROW, and the caller's
  // catch records the row as an error and skips it — failing closed by construction.
  //
  // (a) Jobber sheds load with an HTML "Waiting Room" page at HTTP 200 (measured live
  //     2026-08-13, ~40 min). JSON.parse already throws on that, which is protective by
  //     accident; this makes the reason legible instead of a bare SyntaxError.
  const ctype = String((r.headers && (r.headers['content-type'] || r.headers['Content-Type'])) || '');
  if (ctype && !ctype.includes('json')) {
    throw new Error(`jobber-not-json (${ctype} at HTTP ${r.status}) — Jobber is shedding load, not answering`);
  }
  const j = JSON.parse(r.body);
  // (b) THE ONE THAT ACTUALLY MATTERS. A well-formed GraphQL reply ALWAYS carries a `data`
  //     key, even when the field inside it is null. Its ABSENCE means the request never ran:
  //     a THROTTLED envelope, a JSON-shaped auth error, a 429 with a JSON body. Those PARSE
  //     FINE, so (a) does not catch them, and `!j.data?.visit` reads them as "gone".
  if (!Object.prototype.hasOwnProperty.call(j, 'data')) {
    throw new Error(`jobber-no-data (${(j.errors || []).map(e => e.message).join('; ').slice(0, 120) || 'no errors array either'})`);
  }
  return { data: j.data, errors: j.errors };
}

function isNotFound(errs) {
  return errs?.some(e => /Visit not found|does not exist/i.test(e.message || ''));
}

// ---------------------------------------------------------------------------

async function fetchCandidates() {
  // Only rows that are (a) Jobber-sourced, (b) not already soft-deleted,
  // (c) in the ±DAYS window.
  return pg(`
    SELECT v.id, v.visit_date, v.visit_status, v.title,
           v.start_at, v.end_at, v.completed_at,
           c.client_code, c.name AS client_name,
           esl.source_id AS jobber_gid
    FROM public.visits v
    JOIN public.clients c ON c.id = v.client_id
    JOIN public.entity_source_links esl
      ON esl.entity_type = 'visit' AND esl.entity_id = v.id AND esl.source_system = 'jobber'
    WHERE v.deleted_at IS NULL
      AND v.visit_date BETWEEN (CURRENT_DATE - INTERVAL '${DAYS} days')::date
                           AND (CURRENT_DATE + INTERVAL '${DAYS} days')::date
    ORDER BY v.visit_date DESC
    ${LIMIT ? `LIMIT ${LIMIT}` : ''};
  `);
}

// Both writes go through the Management-API (pg) with two transaction-local settings:
//  - "request.headers" → X-App-Source attribution (else audit shows 'sql' = "System").
//  - "app.suppress_jobber_push"='on' → no echo back to Jobber. This is a MATCH-JOBBER
//    reconcile (read Jobber → write DB); pushing back is never needed. Without it, a
//    write to a Calendar/cron-mastered row echoes via trg_push_visit_update — the path
//    that ratcheted the pre-fix UTC-date bug INTO Jobber (e.g. 6860 07-02→03→04) and can
//    revert a dispatch edit made in the ~1-2s window. Orphan soft-deletes suppress too
//    (the visit is already gone from Jobber — no delete to push).
const GUC_PREFIX = `SET LOCAL "request.headers" = '{"x-app-source":"${APP_SOURCE}"}'; SET LOCAL "app.suppress_jobber_push" = 'on'; `;
const pgLit = v => (v == null ? 'NULL' : "'" + String(v).replace(/'/g, "''") + "'");

async function softDelete(id) {
  if (!EXECUTE) return;
  await pg(`${GUC_PREFIX}UPDATE public.visits SET deleted_at=now() WHERE id=${id} AND deleted_at IS NULL;`);
}

async function updateDate(id, startAt, endAt) {
  if (!EXECUTE) return;
  // ET clock date of start_at (matches the DB trigger), NOT startAt.slice(0,10) (raw
  // UTC = +1 day for evening-ET visits → the ±1-day oscillation). Co-written WITH
  // start_at here, so the trigger derives the same date; never written standalone.
  const newDate = operatingDateET(startAt);
  // + sync_state finisher: the schedule write flips sync_state->'pending', which the */3-min
  // resolve-stale cron would re-push (defeating suppress). DB now == Jobber, so confirm it.
  await pg(`${GUC_PREFIX}UPDATE public.visits SET visit_date=${pgLit(newDate)}::date, start_at=${pgLit(startAt)}::timestamptz, end_at=${endAt ? `${pgLit(endAt)}::timestamptz` : 'NULL'} WHERE id=${id}; UPDATE public.visits SET sync_state='confirmed' WHERE id=${id} AND sync_state='pending';`);
}

// ---------------------------------------------------------------------------

(async () => {
  const t0 = Date.now();
  console.log(`cron_jobber_reconcile_anomalies — ${EXECUTE ? 'EXECUTE' : 'DRY-RUN'}`);
  console.log(`  window: ±${DAYS} days   throttle: ${THROTTLE_MS}ms   inversion threshold: ${INVERSION_HOURS_THRESHOLD}h\n`);

  await getJobberToken();

  const rows = await fetchCandidates();
  console.log(`Universe: ${rows.length} Jobber-linked visits to reconcile.\n`);

  const orphans = [], dateDrift = [], inversions = [], errors = [];
  // 🛑 CIRCUIT BREAKER. The guards in gqlVisit already make an outage harmless (every row
  // errors and is skipped), but without this the run still fires up to 756 sequential Jobber
  // requests at ~80ms spacing with no backoff — which is itself a plausible way to CAUSE the
  // throttling it cannot interpret. Consecutive, so a handful of genuinely bad GIDs scattered
  // through the set never trips it; only a sustained wall of failures does.
  let consecutiveJobberFailures = 0;
  const MAX_CONSECUTIVE_FAILURES = 10;
  let abortedEarly = null;
  let processed = 0, lastTokenRefresh = Date.now();

  for (const v of rows) {
    processed++;
    if (Date.now() - lastTokenRefresh > 5 * 60_000) {
      await getJobberToken();
      lastTokenRefresh = Date.now();
    }
    if (processed % 100 === 0) {
      console.log(`  [${processed}/${rows.length}] orphans=${orphans.length} dateDrift=${dateDrift.length} inversions=${inversions.length}`);
    }

    let res;
    try {
      res = await gqlVisit(v.jobber_gid);
    } catch (e) {
      if (e.message === 'token-expired') {
        await getJobberToken();
        lastTokenRefresh = Date.now();
        try { res = await gqlVisit(v.jobber_gid); }
        catch (e2) {
          errors.push({ id: v.id, err: e2.message });
          if (++consecutiveJobberFailures >= MAX_CONSECUTIVE_FAILURES) { abortedEarly = e2.message; break; }
          continue;
        }
      } else {
        errors.push({ id: v.id, err: e.message });
        if (++consecutiveJobberFailures >= MAX_CONSECUTIVE_FAILURES) { abortedEarly = e.message; break; }
        continue;
      }
    }
    consecutiveJobberFailures = 0;   // Jobber answered; the streak is broken

    // (1) Orphan: Jobber ANSWERED and said this visit is not found / is null.
    //     Reaching here means gqlVisit returned, so `data` was present — an unanswered
    //     request threw above and never gets this far. See the guards in gqlVisit.
    if (isNotFound(res.errors) || !res.data?.visit) {
      orphans.push(v);
      try {
        await softDelete(v.id);
      } catch (e) {
        errors.push({ id: v.id, err: `softDelete failed: ${e.message}` });
      }
      continue;
    }

    const j = res.data.visit;
    // ET clock date of Jobber's start (matches the DB trigger), NOT j.startAt.slice(0,10)
    // (raw UTC = +1 for evening-ET visits → a phantom drift that the trigger reverts daily).
    const jDate = operatingDateET(j.startAt);

    // (2) Scheduled-visit date drift
    if (
      v.visit_status === 'scheduled' &&
      jDate && jDate !== v.visit_date &&
      j.startAt && j.endAt
    ) {
      dateDrift.push({ id: v.id, code: v.client_code, dbDate: v.visit_date, jDate, jStartAt: j.startAt, jEndAt: j.endAt });
      try {
        await updateDate(v.id, j.startAt, j.endAt);
      } catch (e) {
        errors.push({ id: v.id, err: `updateDate failed: ${e.message}` });
      }
    }

    // (3) Inverted timeline detection (informational only)
    if (j.completedAt && j.startAt) {
      const completedDate = new Date(j.completedAt).getTime();
      const startDate = new Date(j.startAt).getTime();
      const hoursDelta = (startDate - completedDate) / 36e5;
      if (hoursDelta > INVERSION_HOURS_THRESHOLD) {
        inversions.push({ id: v.id, code: v.client_code, client_name: v.client_name, startAt: j.startAt, completedAt: j.completedAt, hours_inverted: Math.round(hoursDelta) });
      }
    }

    if (THROTTLE_MS) await new Promise(r => setTimeout(r, THROTTLE_MS));
  }

  const elapsed = Math.round((Date.now() - t0) / 1000);
  console.log(`\nScanned ${processed} visits in ${elapsed}s.`);
  console.log('\n=== Summary =================================================');
  if (abortedEarly) {
    // Loud, and ABOVE the counts: a partial run whose numbers look small must never be
    // mistaken for a clean run that found little.
    console.log(`  🛑 ABORTED EARLY after ${MAX_CONSECUTIVE_FAILURES} consecutive Jobber failures: ${abortedEarly}`);
    console.log(`     Jobber was not answering, so the remaining visits were NOT checked and NOTHING`);
    console.log(`     was soft-deleted on their behalf. Re-run once Jobber is healthy.`);
  }
  console.log(`  ORPHANS soft-deleted${EXECUTE ? '' : ' (would be)'}: ${orphans.length}`);
  for (const o of orphans) console.log(`    id=${o.id} ${o.client_code || '?'} ${o.client_name} visit_date=${o.visit_date}`);
  console.log(`\n  DATE DRIFT updated${EXECUTE ? '' : ' (would be)'}: ${dateDrift.length}`);
  for (const d of dateDrift) console.log(`    id=${d.id} ${d.code}: DB=${d.dbDate} → JOBBER=${d.jDate}`);
  console.log(`\n  INVERSIONS flagged (no auto-action): ${inversions.length}`);
  for (const i of inversions) console.log(`    id=${i.id} ${i.code} ${i.client_name}: scheduled=${i.startAt} completed=${i.completedAt} (${i.hours_inverted}h inversion)`);
  console.log(`\n  ERRORS: ${errors.length}`);
  for (const e of errors) console.log(`    id=${e.id}: ${e.err}`);

  // Emit JSON for downstream alerting (OPS_LIST builder reads ./reports/)
  const fs = require('fs');
  const today = new Date().toISOString().slice(0, 10);
  const out = path.resolve(__dirname, '../../reports/jobber_anomalies_' + today + '.json');
  try { fs.mkdirSync(path.dirname(out), { recursive: true }); } catch {}
  fs.writeFileSync(out, JSON.stringify({
    ran_at: new Date().toISOString(),
    execute: EXECUTE,
    window_days: DAYS,
    universe: rows.length,
    scanned: processed,
    elapsed_seconds: elapsed,
    orphans, dateDrift, inversions, errors,
  }, null, 2));
  console.log(`\nWrote: ${out}`);

  if (inversions.length > 0) {
    console.log('\n⚠ Inversions flagged but not auto-mutated. Review in OPS_LIST_YAN or address per-case via:');
    console.log('  - SQL hard-delete (Fred-approved) for genuine reschedule-after-completion cases');
    console.log('  - Leave alone if the inversion is < 24h (likely TZ artifact)');
  }
})().catch(e => { console.error(e); process.exit(1); });
