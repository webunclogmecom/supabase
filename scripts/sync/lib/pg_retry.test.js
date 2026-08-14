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

  server.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
