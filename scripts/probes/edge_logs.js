// edge_logs.js - read Supabase platform logs through the Management API.
//   node scripts/probes/edge_logs.js "<sql>" <outfile> <isoStart> <isoEnd>
//   node scripts/probes/edge_logs.js --selftest
// Bounds need Z or an offset (2026-09-30T19:25:00Z, 2026-09-30T15:25:00-04:00) and must sit on a
// whole minute. A range over 24 h (max 31 days) runs as consecutive 24 h windows, 6.5 s apart, one
// file each: x.json becomes x.0.json, x.1.json ... (old x.json / x.N.json are removed first, so a
// stale result can never pass for a new one). Merge them yourself, and only merge values that add
// (counts, sums, max, buckets): a p95 of daily p95s is wrong.
// Exit codes: 0 ok, 1 query/API error (or our own 60 s timeout: shrink the window), 2 usage or setup,
// 3 hit the 1000-row cap (TRUNCATED), 4 gave up after 3 attempts. Every attempt overwrites the file
// with the raw body, or with {"error": ...} when no body arrived, so the file is always this run's.
//
// Written 2026-08-25 (WORKER_RESOURCE_LIMIT on send-visit-photos-email). Ported 2026-09-24 when
// Supabase removed `logs.all` (410). Hardened 2026-09-30 after an audit found it exiting 0 on
// error bodies. Facts below were MEASURED on this endpoint on 2026-09-30, where they contradict
// the vendor text, the measurement is recorded (sources: Supabase OpenAPI v1-get-project-logs,
// supabase.com/docs/guides/observability/advanced-log-filtering, supabase/cli compute-logs-api.ts,
// supabase-mcp debugging-tools.ts, Logflare query_error_helpers.ex):
// - SQL is ClickHouse over ONE table `logs`, filtered on the column `source` (NOT `source_name`, which
//   the migration changelog names and the API rejects): edge_logs (API gateway), postgres_logs,
//   postgrest_logs, auth_logs, storage_logs, function_edge_logs (one row per invocation),
//   function_logs (console.* inside a function), realtime_logs, supavisor_logs, pgbouncer_logs.
//   Nested fields are map keys: log_attributes['request.path']. Every value in the map is a string.
// - Both bounds are REQUIRED here. Without them the endpoint answered "Backend error" 6 of 6 times;
//   with only a start it silently used 1 minute. A span over 24 h is silently CLIPPED to start+24h
//   (the newest hours vanish), which is why this reader splits instead. A WHERE on `timestamp` only
//   narrows inside the window; it cannot widen it.
// - Results stop at 1000 rows with no flag in the body. This reader exits 3 at the cap: aggregate or
//   narrow the window. Aggregate with count(); select * is refused.
// - A missing COLUMN is an error, but a missing log_attributes KEY silently returns '' on every row.
//   Discover keys with: select arrayJoin(mapKeys(log_attributes)) k, count() n from logs
//   where source = 'edge_logs' group by k order by n desc limit 200
//   Cast with toFloat64OrNull and count the nulls. toInt32OrZero turns "no value" into a real-looking 0.
// - Errors come back INSIDE an HTTP 200 as {"error": ...}. "Backend error! Retry your query" is
//   Logflare's catch-all: sometimes transient (a retry works), sometimes a bad query (select *, a
//   non-aggregated column), so it is retried a bounded number of times, never forever.
// - Rate limit, measured 2026-09-30 from the response headers: x-ratelimit-limit 10 per 60 s,
//   x-ratelimit-reset = seconds until the window resets. It is PER TOKEN, so every session on the same
//   PAT shares it; beyond it: 429 "ThrottlerException: Too Many Requests". Printed to stderr each call.
// - Result timestamps are UTC with no zone suffix: append Z before parsing them in JavaScript.
// - A clean zero is only evidence after a positive control: return count() as scanned plus
//   min(timestamp) and max(timestamp) in the same query.
const fs = require('fs');
const path = require('path');

const MAX_ROWS = 1000, DAY = 864e5, ATTEMPTS = 3;
const sleep = ms => new Promise(r => setTimeout(r, ms));
const iso = d => d.toISOString().replace('.000Z', 'Z');

function parseBound(s) {
  if (!/(Z|[+-]\d\d:\d\d)$/.test(s || '')) return null; // a bare time would be read as LOCAL time
  const d = new Date(s);
  return isNaN(d) || d.getUTCSeconds() || d.getUTCMilliseconds() ? null : d; // the API rounds to the minute
}

function windows(s, e) {
  const w = [];
  for (let t = s.getTime(); t < e.getTime(); t += DAY) w.push([new Date(t), new Date(Math.min(e.getTime(), t + DAY))]);
  return w;
}

// ok | retry | fatal, from one HTTP status + body
function classify(status, body) {
  let j = null;
  try { j = JSON.parse(body); } catch (e) { /* not JSON */ }
  if (status === 200 && j && Array.isArray(j.result) && !j.error) return { kind: 'ok', rows: j.result.length };
  const err = String((j && ((status !== 200 && j.message) ||
    (typeof j.error === 'string' ? j.error : (j.error && j.error.message)) || j.message)) ||
    (body ? String(body).slice(0, 300) : 'HTTP ' + status));
  const transient = status === 429 || status >= 500 || /^Backend error! Retry/.test(err);
  return { kind: transient ? 'retry' : 'fatal', err };
}

// how long to wait before the next attempt (RFC 9110 Retry-After: seconds or an HTTP date)
function backoff(status, headers, now) {
  if (status !== 429) return 5000 + Math.floor(Math.random() * 1000);
  const ra = headers && headers.get('retry-after'), rs = headers && headers.get('x-ratelimit-reset');
  let ms = 60000;
  if (ra) ms = /^\d+$/.test(ra) ? ra * 1000 : Date.parse(ra) - now;
  else if (rs && /^\d+$/.test(rs)) ms = rs > 1e9 ? rs * 1000 - now : rs * 1000; // epoch or seconds-to-reset
  if (!Number.isFinite(ms)) ms = 60000;
  return Math.min(Math.max(ms, 1000), 90000);
}

async function run(sql, s, e, file) {
  const url = `https://api.supabase.com/v1/projects/${process.env.SUPABASE_PROJECT_ID}/analytics/endpoints/logs?` +
    new URLSearchParams({ sql, iso_timestamp_start: iso(s), iso_timestamp_end: iso(e) });
  for (let attempt = 1; ; attempt++) {
    let status = 0, headers = null, body = null, c;
    try {
      const res = await fetch(url, { headers: { Authorization: 'Bearer ' + process.env.SUPABASE_PAT }, signal: AbortSignal.timeout(60000) });
      status = res.status; headers = res.headers;
      body = await res.text();
    } catch (err) {
      // our own 60 s timeout means a heavy query: retrying only repeats it, so it is fatal
      const why = err.name + ': ' + err.message + (err.cause && err.cause.code ? ' (' + err.cause.code + ')' : '');
      c = { kind: err.name === 'TimeoutError' ? 'fatal' : 'retry', err: why };
    }
    fs.writeFileSync(file, body !== null ? body : JSON.stringify({ error: c.err }));
    if (body !== null) {
      c = classify(status, body);
      const rl = ['x-ratelimit-limit', 'x-ratelimit-remaining', 'x-ratelimit-reset', 'retry-after'].filter(h => headers.get(h));
      if (rl.length) console.error('  ' + rl.map(h => h.replace('x-ratelimit-', '') + '=' + headers.get(h)).join(' '));
    }
    if (c.kind !== 'retry' || attempt === ATTEMPTS) return { ...c, status, attempt };
    const ms = backoff(status, headers, Date.now());
    console.error(`  attempt ${attempt} failed (${c.err.slice(0, 120)}), retrying in ${Math.round(ms / 1000)} s`);
    await sleep(ms);
  }
}

function selftest() {
  const a = require('assert');
  a.deepStrictEqual(classify(200, '{"result":[{"n":1}]}'), { kind: 'ok', rows: 1 });
  a.strictEqual(classify(200, '{"error":"Field \\"source_name\\" does not exist."}').kind, 'fatal');
  a.strictEqual(classify(200, '{"error":"Backend error! Retry your query. Please contact support if this continues."}').kind, 'retry');
  a.strictEqual(classify(200, '{"result":[],"error":{"message":"Query timed out","code":400}}').kind, 'fatal');
  a.strictEqual(classify(400, '{"message":"iso_timestamp_start: Invalid ISO datetime"}').err, 'iso_timestamp_start: Invalid ISO datetime');
  a.strictEqual(classify(429, '{"message":"ThrottlerException: Too Many Requests"}').kind, 'retry');
  a.strictEqual(classify(502, '<html>bad gateway</html>').kind, 'retry');
  a.strictEqual(classify(410, '{"message":"The logs.all endpoint has been removed"}').kind, 'fatal');
  a.strictEqual(classify(200, '{"result":[]}').rows, 0);
  a.strictEqual(classify(500, '{"message":{"detail":"x"}}').err, '[object Object]', 'err is always a string');
  a.strictEqual(classify(400, '{"statusCode":400,"message":"bad bound","error":"Bad Request"}').err, 'bad bound');
  a.strictEqual(backoff(429, new Map([['retry-after', 'soon']]), 0), 60000, 'unparseable Retry-After');
  a.strictEqual(parseBound('2026-09-30T19:25:00'), null, 'bare time is local time: refuse');
  a.strictEqual(parseBound('2026-09-30T19:25:30Z'), null, 'not on a minute: refuse');
  a.strictEqual(parseBound('2026-09-30T15:25:00-04:00').getTime(), parseBound('2026-09-30T19:25:00Z').getTime());
  const w = windows(parseBound('2026-09-01T00:00:00Z'), parseBound('2026-09-03T06:00:00Z'));
  a.deepStrictEqual(w.map(([x, y]) => iso(x) + '/' + iso(y)), [
    '2026-09-01T00:00:00Z/2026-09-02T00:00:00Z', '2026-09-02T00:00:00Z/2026-09-03T00:00:00Z', '2026-09-03T00:00:00Z/2026-09-03T06:00:00Z']);
  a.strictEqual(windows(parseBound('2026-09-01T00:00:00Z'), parseBound('2026-09-02T00:00:00Z')).length, 1, 'exactly 24 h is one window');
  const h = new Map([['retry-after', '7']]);
  a.strictEqual(backoff(429, h, 0), 7000);
  a.strictEqual(backoff(429, new Map([['retry-after', '600']]), 0), 90000, 'capped');
  a.strictEqual(backoff(429, new Map(), 0), 60000);
  a.ok(backoff(200, null, 0) >= 5000 && backoff(200, null, 0) < 6000);
  console.log('selftest OK');
}

(async () => {
  if (process.argv[2] === '--selftest') return selftest();
  const [sql, out, a, b] = process.argv.slice(2);
  const s = parseBound(a), e = parseBound(b);
  if (!sql || !out || !s || !e || e <= s) {
    console.error('usage: node edge_logs.js "<sql>" <outfile> <isoStart> <isoEnd>\n' +
      '  both bounds required, with Z or an offset, on a whole minute, end after start');
    process.exitCode = 2;
    return;
  }
  const envFile = path.resolve(__dirname, '../../.env');
  for (const line of (fs.existsSync(envFile) ? fs.readFileSync(envFile, 'utf8') : '').split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
    if (!m) continue;
    let v = m[2].trim();
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
    if (!(m[1] in process.env)) process.env[m[1]] = v;
  }
  const ws = windows(s, e), dir = path.dirname(out), base = path.basename(out);
  const setup = !process.env.SUPABASE_PAT || !process.env.SUPABASE_PROJECT_ID ? 'SUPABASE_PAT / SUPABASE_PROJECT_ID not set (Supabase/.env)'
    : !fs.existsSync(dir) ? 'output folder does not exist: ' + dir
    : ws.length > 31 ? `${ws.length} windows requested, max 31 (check the year)` : null;
  if (setup) { console.error(setup); process.exitCode = 2; return; }
  const stem = base.replace(/\.json$/, '') + '.';
  if (ws.length > 1) for (const f of fs.readdirSync(dir)) // never leave a stale result that looks like this run's
    if (f === base || (f.startsWith(stem) && /^\d+\.json$/.test(f.slice(stem.length)))) fs.rmSync(path.join(dir, f));
  const rank = { 0: 0, 3: 1, 1: 2, 4: 3 };
  let code = 0;
  for (const [k, [ws0, ws1]] of ws.entries()) {
    if (k) await sleep(6500); // shared per-token rate limit: never run windows in parallel
    const file = ws.length > 1 ? out.replace(/(\.json)?$/, `.${k}.json`) : out;
    const r = await run(sql, ws0, ws1, file);
    const tag = `${iso(ws0)}..${iso(ws1)}`;
    let c = 0;
    if (r.kind === 'ok') {
      c = r.rows >= MAX_ROWS ? 3 : 0;
      console.log(`${tag} HTTP ${r.status} rows=${r.rows}${c ? ' TRUNCATED (server cap 1000): aggregate or narrow the window' : ''} -> ${file}`);
    } else {
      c = r.kind === 'fatal' ? 1 : 4;
      console.log(`${tag} status=error after ${r.attempt} attempt(s): ${r.err}` +
        (/timed out|TimeoutError/i.test(r.err) ? ' (shrink the window)' : '') +
        (/^Backend error/.test(r.err) ? ' (this text also means: select *, or a column neither grouped nor aggregated)' : ''));
    }
    if (rank[c] > rank[code]) code = c;
    if (c === 1 || c === 4) break; // the same query will fail the same way in the next window
  }
  if (ws.length > 1 && code) console.log('PARTIAL: do not add these windows up');
  process.exitCode = code;
})();
