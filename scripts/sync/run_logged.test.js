// run_logged.test.js: proves the runner logs a success, an error, and a KILLED run, against a stub sync_log,
// and that a RUN_SUMMARY line lands in details.summary + rows_inserted (absent or malformed = row unchanged),
// and that --dry-run is refused before anything runs or is logged.
//   node scripts/sync/run_logged.test.js        (no network: a local HTTP server stands in for PostgREST)
const http = require('http');
const { spawnSync, spawn } = require('child_process');
const fs = require('fs'), os = require('os'), path = require('path'), assert = require('assert');

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'runlogged-'));
const script = (name, body) => { const p = path.join(dir, name); fs.writeFileSync(p, body); return p; };
const okJs = script('ok.js', 'console.log("hi")');
const failJs = script('fail.js', 'console.error("boom"); process.exit(3)');
const hangJs = script('hang.js', 'setInterval(() => {}, 1000)');
const sumJs = script('sum.js', 'console.log("RUN_SUMMARY {\\"rows_inserted\\":1}"); console.log("work"); process.stdout.write("RUN_SUMMARY {\\"rows_inserted\\":42,\\"deep_pass\\":true}")');
const badJs = script('bad.js', 'console.log("RUN_SUMMARY {not json"); console.log("RUN_SUMMARY [1,2]")');

const rows = [];
const server = http.createServer((req, res) => {
  let b = ''; req.on('data', c => b += c);
  req.on('end', () => { if (req.url === '/rest/v1/sync_log') rows.push(JSON.parse(b)); res.writeHead(201); res.end(); });
}).listen(0, async () => {
  const env = { ...process.env, SUPABASE_URL: `http://127.0.0.1:${server.address().port}`, SUPABASE_SERVICE_ROLE_KEY: 'x' };
  const run = (args, extra = {}) => new Promise(r => {
    const c = spawn(process.execPath, [path.join(__dirname, 'run_logged.js'), ...args], { env: { ...env, ...extra }, stdio: ['ignore', 'pipe', 'ignore'] });
    let out = ''; c.stdout.on('data', d => out += d);
    c.on('close', code => r({ code, out }));
  });

  assert.strictEqual((await run(['t_ok', okJs])).code, 0);
  assert.strictEqual((await run(['t_fail', failJs])).code, 3);
  const t0 = Date.now();
  assert.notStrictEqual((await run(['t_hang', hangJs], { RUN_TIMEOUT_MIN: '0.02' })).code, 0);   // ~1.2 s
  assert.ok(Date.now() - t0 < 10000, 'hung child was not killed');
  assert.strictEqual(spawnSync(process.execPath, [path.join(__dirname, 'run_logged.js')], { env }).status, 2);
  assert.strictEqual(spawnSync(process.execPath, [path.join(__dirname, 'run_logged.js'), 't_dry', okJs, '--dry-run'], { env }).status, 2, '--dry-run must be refused');
  const sum = await run(['t_sum', sumJs]);
  assert.strictEqual(sum.code, 0);
  assert.match(sum.out, /work/, 'child stdout is not passed through');
  assert.match(sum.out, /RUN_SUMMARY \{"rows_inserted":42/, 'summary line is not passed through');
  assert.strictEqual((await run(['t_bad', badJs])).code, 0);

  const by = Object.fromEntries(rows.map(r => [r.sync_source, r]));
  assert.strictEqual(rows.length, 5, 'a refused --dry-run must write no row');
  assert.ok(!rows.some(r => r.sync_source === 't_dry'), 'a refused --dry-run must write no row');
  assert.strictEqual(by.t_ok.status, 'success');
  assert.strictEqual(by.t_ok.error_details, null);
  assert.ok(!('summary' in by.t_ok.details) && !('rows_inserted' in by.t_ok), 'no summary must leave the row shape unchanged');
  assert.deepStrictEqual(Object.keys(by.t_ok.details), ['host', 'cmd', 'exit_code', 'signal', 'timed_out', 'limit_min']);
  assert.strictEqual(by.t_fail.status, 'error');
  assert.strictEqual(by.t_fail.details.exit_code, 3);
  assert.match(by.t_fail.error_details.stderr_tail, /boom/);
  assert.strictEqual(by.t_hang.status, 'error');
  assert.strictEqual(by.t_hang.details.timed_out, true);
  assert.deepStrictEqual(by.t_sum.details.summary, { rows_inserted: 42, deep_pass: true }, 'last summary (no trailing newline) wins');
  assert.strictEqual(by.t_sum.rows_inserted, 42);
  assert.strictEqual(by.t_bad.status, 'success', 'a malformed summary must not fail the run');
  assert.ok(!('summary' in by.t_bad.details) && !('rows_inserted' in by.t_bad), 'a malformed summary must be ignored');
  console.log('run_logged: 17 checks passed');
  server.close();
});
