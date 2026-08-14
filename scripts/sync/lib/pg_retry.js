// ============================================================================
// pg_retry.js — Supabase Management API query helper that survives a transient blip
// ============================================================================
// WHY THIS EXISTS, with the receipt:
// `daily-jobber-anomaly-reconcile` FAILED on 2026-08-11 (run 31481104974). The whole
// error was:
//     Error: PG 502: error code: 502
//     Process completed with exit code 1
// One transient 502 from api.supabase.com killed the entire nightly reconcile, because
// the helper in cron_jobber_reconcile_anomalies.js:123 is:
//     if (r.status >= 300) throw new Error(`PG ${r.status}: ...`);
// No retry. That script is the one that soft-deletes visits Jobber no longer returns,
// so an abort mid-run is worse than a clean skip.
//
// Measured 2026-08-14: **10 of 18 scheduled scripts** abort the same way. The lone
// script clean on every axis is sync_jobber_note_photos.js, whose pg() this generalises.
//
// 🛑 RETRY 5xx AND 429 ONLY. A 4xx is a real bug in our SQL or auth and retrying it
// just hides it four times more slowly. The test asserts that explicitly.
//
//   const { pgFactory } = require('./lib/pg_retry');
//   const pg = pgFactory({ project: PROJECT, pat: PAT });
//   const rows = await pg('select 1');
//
// Tests: node scripts/sync/lib/pg_retry.test.js
// ============================================================================
const https = require('https');
const http = require('http');

const sleep = ms => new Promise(r => setTimeout(r, ms));

function request(urlStr, body, headers, timeoutMs) {
  const u = new URL(urlStr);
  const mod = u.protocol === 'https:' ? https : http;
  const opts = {
    hostname: u.hostname,
    port: u.port || undefined,
    path: u.pathname + u.search,
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body), ...headers },
  };
  return new Promise((res, rej) => {
    const r = mod.request(opts, x => {
      const ch = [];
      x.on('data', d => ch.push(d));
      // headers are propagated deliberately: a caller that wants to detect an HTML
      // "waiting room" body at HTTP 200 cannot do it without them, and a guard that
      // reads undefined is decoration. That exact bug shipped once already.
      x.on('end', () => res({ status: x.statusCode, headers: x.headers, body: Buffer.concat(ch).toString() }));
    });
    // 🛑 SOCKET TIMEOUT (added 2026-08-14). Without it a half-open connection hangs until the OS
    // gives up, and the retry loop above never gets a turn — the run stalls to the workflow's
    // `timeout-minutes: 30` instead of failing in 60s and retrying.
    // ⚠ This is NOT a nicety: cron_jobber_reconcile_anomalies.js carried `req.setTimeout(60_000)`
    // in its own inlined helper, so adopting this lib WITHOUT a timeout would have been a straight
    // regression for that caller. It lands here rather than at the call site so every script that
    // adopts pgFactory gets it — none of them has a timeout today.
    // `destroy(err)` surfaces through 'error' -> rej, i.e. as a RETRYABLE transport failure, which
    // is the correct classification: a timeout is exactly the transient blip this file exists for.
    if (timeoutMs) {
      r.setTimeout(timeoutMs, () => r.destroy(new Error(`socket timeout after ${timeoutMs}ms`)));
    }
    r.on('error', rej);
    r.write(body);
    r.end();
  });
}

/**
 * @param {object} o
 * @param {string} [o.project] Supabase project ref (builds the real endpoint)
 * @param {string} [o.pat]     Management API PAT
 * @param {string} [o.endpoint] full URL override, for tests
 * @param {number} [o.attempts=5] total attempts including the first
 * @param {number} [o.backoffMs=2000] base backoff, multiplied by attempt number
 * @param {number} [o.timeoutMs=60000] per-attempt socket timeout; 0 disables it
 */
function pgFactory(o = {}) {
  const endpoint = o.endpoint || `https://api.supabase.com/v1/projects/${o.project}/database/query`;
  const maxAttempts = o.attempts ?? 5;
  const backoffMs = o.backoffMs ?? 2000;
  // Matches the 60s that cron_jobber_reconcile_anomalies.js applied in its own helper before it
  // adopted this lib. Per ATTEMPT, not per call: 5 attempts can still span several minutes, which
  // the workflow's timeout-minutes: 30 bounds.
  const timeoutMs = o.timeoutMs ?? 60000;
  const headers = o.pat ? { Authorization: `Bearer ${o.pat}` } : {};

  return async function pg(sql) {
    const body = JSON.stringify({ query: sql });
    let last;
    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
      let r;
      try {
        r = await request(endpoint, body, headers, timeoutMs);
      } catch (e) {
        // transport-level blip (ENOTFOUND, ECONNRESET) is retryable too
        last = e;
        if (attempt === maxAttempts) throw e;
        await sleep(backoffMs * attempt);
        continue;
      }
      if (r.status < 300) return JSON.parse(r.body);

      const retryable = r.status === 429 || r.status >= 500;
      last = new Error(`PG ${r.status}: ${r.body.slice(0, 300)}`);
      if (!retryable || attempt === maxAttempts) throw last;
      await sleep(backoffMs * attempt);
    }
    throw last;
  };
}

module.exports = { pgFactory };
