// run_logged.js — the wrapper every Railway timed job runs through (timed-jobs move, plan section 3.6).
//   node scripts/sync/run_logged.js <sync_source> <script> [args...]
// Runs the script, then writes ONE public.sync_log row: status success/error, exit code, duration, stderr tail.
// RUN_TIMEOUT_MIN (default 30): Railway has no timeout, and a run that never exits blocks every later run of
// its service, so the runner kills it and logs timed_out: true. Check: scripts/sync/run_logged.test.js.
const { spawn } = require('child_process');

const [source, ...cmd] = process.argv.slice(2);
if (!source || !cmd.length) {
  console.error('usage: node scripts/sync/run_logged.js <sync_source> <script> [args...]');
  process.exit(2);
}
const limitMin = Number(process.env.RUN_TIMEOUT_MIN) || 30;
const started = new Date();
let tail = '', timedOut = false;

const child = spawn(process.execPath, cmd, { stdio: ['ignore', 'inherit', 'pipe'] });
const timer = setTimeout(() => { timedOut = true; child.kill('SIGKILL'); }, limitMin * 60000);
child.stderr.on('data', d => { process.stderr.write(d); tail = (tail + d).slice(-4000); });

child.on('close', async (code, signal) => {
  clearTimeout(timer);
  const ok = code === 0 && !timedOut;
  const finished = new Date();
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const r = await fetch(`${process.env.SUPABASE_URL}/rest/v1/sync_log`, {
    method: 'POST', signal: AbortSignal.timeout(15000),
    headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json', Prefer: 'return=minimal' },
    body: JSON.stringify({
      sync_source: source, started_at: started, finished_at: finished,
      duration_seconds: (finished - started) / 1000, status: ok ? 'success' : 'error',
      details: { host: process.env.RAILWAY_SERVICE_NAME ? 'railway' : 'local', cmd: cmd.join(' '),
                 exit_code: code, signal, timed_out: timedOut, limit_min: limitMin },
      error_details: ok ? null : { stderr_tail: tail },
    }),
  }).catch(e => ({ ok: false, status: String(e) }));
  if (!r.ok) console.error('sync_log insert failed', r.status);
  process.exit(ok ? 0 : (code || 1));
});
