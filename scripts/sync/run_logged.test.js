// run_logged.test.js — proves the runner logs a success, an error, and a KILLED run, against a stub sync_log.
//   node scripts/sync/run_logged.test.js        (no network: a local HTTP server stands in for PostgREST)
const http = require('http');
const { spawnSync, spawn } = require('child_process');
const fs = require('fs'), os = require('os'), path = require('path'), assert = require('assert');

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'runlogged-'));
const script = (name, body) => { const p = path.join(dir, name); fs.writeFileSync(p, body); return p; };
const okJs = script('ok.js', 'console.log("hi")');
const failJs = script('fail.js', 'console.error("boom"); process.exit(3)');
const hangJs = script('hang.js', 'setInterval(() => {}, 1000)');

const rows = [];
const server = http.createServer((req, res) => {
  let b = ''; req.on('data', c => b += c);
  req.on('end', () => { if (req.url === '/rest/v1/sync_log') rows.push(JSON.parse(b)); res.writeHead(201); res.end(); });
}).listen(0, async () => {
  const env = { ...process.env, SUPABASE_URL: `http://127.0.0.1:${server.address().port}`, SUPABASE_SERVICE_ROLE_KEY: 'x' };
  const run = (args, extra = {}) => new Promise(r => {
    const c = spawn(process.execPath, [path.join(__dirname, 'run_logged.js'), ...args], { env: { ...env, ...extra }, stdio: 'ignore' });
    c.on('close', code => r(code));
  });

  assert.strictEqual(await run(['t_ok', okJs]), 0);
  assert.strictEqual(await run(['t_fail', failJs]), 3);
  const t0 = Date.now();
  assert.notStrictEqual(await run(['t_hang', hangJs], { RUN_TIMEOUT_MIN: '0.02' }), 0);   // ~1.2 s
  assert.ok(Date.now() - t0 < 10000, 'hung child was not killed');
  assert.strictEqual(spawnSync(process.execPath, [path.join(__dirname, 'run_logged.js')], { env }).status, 2);

  const by = Object.fromEntries(rows.map(r => [r.sync_source, r]));
  assert.strictEqual(rows.length, 3);
  assert.strictEqual(by.t_ok.status, 'success');
  assert.strictEqual(by.t_ok.error_details, null);
  assert.strictEqual(by.t_fail.status, 'error');
  assert.strictEqual(by.t_fail.details.exit_code, 3);
  assert.match(by.t_fail.error_details.stderr_tail, /boom/);
  assert.strictEqual(by.t_hang.status, 'error');
  assert.strictEqual(by.t_hang.details.timed_out, true);
  console.log('run_logged: 6 checks passed');
  server.close();
});
