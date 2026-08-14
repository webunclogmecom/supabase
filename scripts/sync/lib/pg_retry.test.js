// Failing test FIRST, per superpowers:systematic-debugging Phase 4.
// Proves the defect that killed daily-jobber-anomaly-reconcile on 2026-08-11:
//   cron_jobber_reconcile_anomalies.js:123  ->  if (r.status >= 300) throw new Error(`PG ...`)
// A transient 502 from the Supabase Management API aborts the whole nightly run.
//
//   node scripts/sync/lib/pg_retry.test.js
const http = require('http');
const assert = require('assert');
const { pgFactory } = require('./pg_retry');

let attempts = 0, plan = [];
const server = http.createServer((req, res) => {
  attempts++;
  const code = plan.shift() ?? 200;
  res.writeHead(code, { 'content-type': 'application/json' });
  res.end(code === 200 ? JSON.stringify([{ ok: true }]) : 'error code: ' + code);
});

// the OLD behaviour, reproduced exactly, as the discriminating control
function legacyPg(url) {
  return new Promise((resolve, reject) => {
    http.get(url, r => {
      const ch = []; r.on('data', d => ch.push(d));
      r.on('end', () => {
        if (r.statusCode >= 300) return reject(new Error(`PG ${r.statusCode}: ` + Buffer.concat(ch)));
        resolve(JSON.parse(Buffer.concat(ch).toString()));
      });
    }).on('error', reject);
  });
}

(async () => {
  await new Promise(r => server.listen(0, r));
  const port = server.address().port;
  const url = `http://127.0.0.1:${port}/`;
  let pass = 0, fail = 0;
  const check = (name, cond) => { if (cond) { pass++; console.log('  PASS  ' + name); } else { fail++; console.log('  FAIL  ' + name); } };

  // ---- 1. CONTROL: the legacy helper dies on a single transient 502 (the 08-11 failure)
  attempts = 0; plan = [502, 200];
  let legacyThrew = false;
  try { await legacyPg(url); } catch (e) { legacyThrew = /PG 502/.test(e.message); }
  check('legacy helper ABORTS on one transient 502 (reproduces the outage)', legacyThrew && attempts === 1);

  // ---- 2. the fixed helper rides through the same 502 and returns the real answer
  attempts = 0; plan = [502, 200];
  const pg = pgFactory({ endpoint: url, backoffMs: 5 });
  const out = await pg('select 1');
  check('retrying helper survives one 502 and returns the body', out[0].ok === true && attempts === 2);

  // ---- 3. it survives a burst, and stops at the cap rather than looping forever
  attempts = 0; plan = [500, 502, 503, 200];
  const out2 = await pg('select 1');
  check('survives three consecutive 5xx', out2[0].ok === true && attempts === 4);

  // ---- 4. NEGATIVE CONTROL: a permanent error must NOT be retried forever, and must throw
  attempts = 0; plan = [400, 400, 400, 400, 400, 400];
  let threw400 = false;
  try { await pg('select 1'); } catch (e) { threw400 = /PG 400/.test(e.message); }
  check('a 4xx is NOT retried and throws (retry must not mask a real bug)', threw400 && attempts === 1);

  // ---- 5. gives up after the cap on unending 5xx, rather than hanging the cron
  attempts = 0; plan = [502, 502, 502, 502, 502, 502, 502, 502];
  let gaveUp = false;
  try { await pg('select 1'); } catch (e) { gaveUp = /PG 502/.test(e.message); }
  check('gives up after the retry cap instead of hanging', gaveUp && attempts === 5);

  // ---- 6. TRANSPORT REJECTION. The reason this file grew (2026-08-14, @Building Apps).
  // Cases 1-5 all exercise the STATUS-CODE arm. The `catch (e)` arm — ECONNRESET / ENOTFOUND /
  // timeout — was implemented and never executed by a test, and it is the arm that
  // cron_jobber_reconcile_anomalies.js was missing entirely in its inlined copy.
  // The server destroys the socket mid-flight, which is what a dropped connection looks like.
  {
    let hits = 0;
    const flaky = http.createServer((req, res) => {
      hits++;
      if (hits === 1) return req.socket.destroy();          // ECONNRESET on attempt 1
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify([{ ok: true }]));
    });
    await new Promise(r => flaky.listen(0, r));
    const fUrl = `http://127.0.0.1:${flaky.address().port}/`;

    // CONTROL first: the legacy helper dies on that same dropped socket.
    let legacyDied = false;
    try { await legacyPg(fUrl); } catch (e) { legacyDied = true; }
    check('CONTROL: legacy helper dies on a dropped socket', legacyDied && hits === 1);

    hits = 0;
    const pgT = pgFactory({ endpoint: fUrl, backoffMs: 5 });
    const okT = await pgT('select 1');
    check('a dropped socket is retried, then succeeds', okT[0].ok === true && hits === 2);
    flaky.close();
  }

  // ---- 7. SOCKET TIMEOUT. Guards the regression that adopting this lib would otherwise have
  // caused: the reconciler's own helper had req.setTimeout(60_000) and the lib had none, so a
  // half-open socket would have hung to the workflow cap instead of failing and retrying.
  {
    let hits = 0;
    const hung = http.createServer((req) => { hits++; /* never respond, never close */ });
    await new Promise(r => hung.listen(0, r));
    const hUrl = `http://127.0.0.1:${hung.address().port}/`;

    const t0 = Date.now();
    const pgH = pgFactory({ endpoint: hUrl, backoffMs: 5, attempts: 2, timeoutMs: 150 });
    let timedOut = false;
    try { await pgH('select 1'); } catch (e) { timedOut = /socket timeout/.test(e.message); }
    const elapsed = Date.now() - t0;
    check('a hung server trips the socket timeout instead of hanging', timedOut && hits === 2);
    // must be bounded by the timeout, not by the OS default (which is minutes)
    check('it gives up in ~2 timeouts, not minutes', elapsed < 3000);
    hung.close();
  }

  server.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
