// run_logged.js — the wrapper every Railway timed job runs through (timed-jobs move, plan section 3.6).
//   node scripts/sync/run_logged.js <sync_source> <script> [args...]
// Runs the script, then writes ONE public.sync_log row: status success/error, exit code, duration, stderr tail.
// RUN_TIMEOUT_MIN (default 30): Railway has no timeout, and a run that never exits blocks every later run of
// its service, so the runner kills it and logs timed_out: true. Check: scripts/sync/run_logged.test.js.
// RUN_SUMMARY: a child may print a final stdout line `RUN_SUMMARY {json}`; the last valid one is stored in
// details.summary, and its rows_inserted (an integer) in the row's rows_inserted. No such line = the row is
// exactly as before; a line that is not a JSON object is ignored. The child's stdout is still passed through.
// --dry-run is refused (exit 2, no row): any sync_log row, even one without a summary, counts as a fresh run for
// the staleness check, so a local dry run through this wrapper would hide a dead Railway service.
const { spawn } = require('child_process');

const [source, ...cmd] = process.argv.slice(2);
if (!source || !cmd.length) {
  console.error('usage: node scripts/sync/run_logged.js <sync_source> <script> [args...]');
  process.exit(2);
}
if (cmd.some(a => a === '--dry-run' || a.startsWith('--dry-run='))) {
  console.error('run_logged.js: refusing --dry-run (it would write a sync_log row); run the script directly');
  process.exit(2);
}
const limitMin = Number(process.env.RUN_TIMEOUT_MIN) || 30;
const started = new Date();
let tail = '', timedOut = false, partial = '', summary = null;

const takeLine = line => {
  if (!line.startsWith('RUN_SUMMARY ')) return;
  try { const s = JSON.parse(line.slice(12)); if (s && typeof s === 'object' && !Array.isArray(s)) summary = s; } catch {}
};

const child = spawn(process.execPath, cmd, { stdio: ['ignore', 'pipe', 'pipe'] });
const timer = setTimeout(() => { timedOut = true; child.kill('SIGKILL'); }, limitMin * 60000);
child.stdout.on('data', d => {
  process.stdout.write(d);
  const lines = (partial + d).split(/\r?\n/);
  partial = lines.pop();
  lines.forEach(takeLine);
});
child.stderr.on('data', d => { process.stderr.write(d); tail = (tail + d).slice(-4000); });

child.on('close', async (code, signal) => {
  clearTimeout(timer);
  takeLine(partial);
  const ok = code === 0 && !timedOut;
  const finished = new Date();
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const r = await fetch(`${process.env.SUPABASE_URL}/rest/v1/sync_log`, {
    method: 'POST', signal: AbortSignal.timeout(15000),
    headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json', Prefer: 'return=minimal' },
    body: JSON.stringify({
      sync_source: source, started_at: started, finished_at: finished,
      duration_seconds: (finished - started) / 1000, status: ok ? 'success' : 'error',
      details: { host: process.env.RAILWAY_SERVICE_NAME ? 'railway' : process.env.GITHUB_ACTIONS ? 'github' : 'local', cmd: cmd.join(' '),
                 exit_code: code, signal, timed_out: timedOut, limit_min: limitMin, ...(summary && { summary }) },
      error_details: ok ? null : { stderr_tail: tail },
      ...(Number.isInteger(summary?.rows_inserted) && { rows_inserted: summary.rows_inserted }),
    }),
  }).catch(e => ({ ok: false, status: String(e) }));
  if (!r.ok) console.error('sync_log insert failed', r.status);
  process.exit(ok ? 0 : (code || 1));
});
