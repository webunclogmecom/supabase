// One-shot watcher: ensures jobber_notes_photos.js completes by auto-restarting
// on silent death, then triggers Sandbox refresh when done.
//
// Polls sync_cursors every 60s. Logic:
//   - If a node process for jobber_notes_photos.js is alive → wait
//   - If dead AND rows_pulled < total clients → restart with --resume
//   - If dead AND rows_pulled >= total clients (or status='complete') → trigger sandbox refresh + exit
//
// Total clients = count of distinct clients in our DB (loose definition; the
// migration script walks all clients with a Jobber ESL).

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const { spawn, execSync } = require('child_process');
const path = require('path');

const PROJECT_ROOT = path.resolve(__dirname, '../..');

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej); req.setTimeout(30000, () => req.destroy(new Error('timeout')));
    if (body) req.write(body); req.end();
  });
}
async function pg(sql) {
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
  }, JSON.stringify({ query: sql }));
  return JSON.parse(r.body);
}

function isAlive() {
  try {
    const out = execSync('powershell -Command "Get-CimInstance Win32_Process -Filter \\"Name=\'node.exe\'\\" | Where-Object { $_.CommandLine -like \'*jobber_notes_photos*\' } | Select-Object -First 1 ProcessId | Format-List"', { encoding: 'utf8' });
    return /ProcessId/.test(out);
  } catch (e) { return false; }
}

function startCatchup() {
  console.log(`[${new Date().toISOString()}] Starting jobber_notes_photos.js --execute --resume`);
  const fs = require('fs');
  const out = fs.openSync(path.resolve(PROJECT_ROOT, `notes_catchup_watch_${Date.now()}.log`), 'a');
  const child = spawn('node', ['scripts/migrate/jobber_notes_photos.js', '--execute', '--resume'], {
    cwd: PROJECT_ROOT, detached: true, stdio: ['ignore', out, out],
  });
  child.unref();
  console.log(`  spawned PID ${child.pid}`);
}

async function getProgress() {
  const r = await pg(`SELECT rows_pulled, last_run_status, updated_at::text AS updated FROM sync_cursors WHERE entity='jobber_notes_migration'`);
  return r[0];
}

async function getTotalClients() {
  const r = await pg(`SELECT COUNT(*) AS n FROM entity_source_links WHERE entity_type='client' AND source_system='jobber'`);
  return Number(r[0].n);
}

async function refreshJobberToken() {
  try { execSync('node scripts/sync/jobber_token.js', { cwd: PROJECT_ROOT, stdio: 'pipe' }); }
  catch (e) { console.log(`  token refresh err: ${e.message.slice(0, 100)}`); }
}

async function triggerSandboxRefresh() {
  console.log(`[${new Date().toISOString()}] Triggering sandbox-refresh workflow`);
  try {
    const out = execSync('gh workflow run sandbox-refresh.yml', { cwd: PROJECT_ROOT, encoding: 'utf8' });
    console.log(`  ${out.trim()}`);
  } catch (e) { console.log(`  err: ${e.message.slice(0, 100)}`); }
}

(async () => {
  // getTotalClients may itself fail on a transient DNS blip — retry a few times
  let total = 0;
  for (let i = 0; i < 5; i++) {
    try { total = await getTotalClients(); break; }
    catch (e) {
      console.log(`[${new Date().toISOString()}] getTotalClients err (${i+1}/5): ${e.message.slice(0, 80)}`);
      await new Promise(rs => setTimeout(rs, 10000));
    }
  }
  if (!total) { console.error('FATAL: could not fetch total client count after 5 retries'); process.exit(2); }
  console.log(`Watching catchup. Total clients to process: ${total}`);
  let lastProgress = -1;
  let stuckChecks = 0;
  let consecutiveErrors = 0;

  while (true) {
    try {
      const progress = await getProgress();
      const pulled = Number(progress?.rows_pulled || 0);
      const alive = isAlive();
      console.log(`[${new Date().toISOString()}] alive=${alive}  rows_pulled=${pulled}/${total}  status=${progress?.last_run_status}`);
      consecutiveErrors = 0;

      if (pulled >= total - 5) {
        console.log(`✅ Catchup looks complete (within 5 of total). Triggering sandbox refresh.`);
        await triggerSandboxRefresh();
        console.log('Watcher exiting.');
        process.exit(0);
      }

      if (!alive) {
        // Detect "stuck checkpoint" — same rows_pulled for 3 consecutive checks = no progress
        if (pulled === lastProgress) stuckChecks++;
        else { stuckChecks = 0; lastProgress = pulled; }

        if (stuckChecks >= 1) {
          console.log(`  catchup process is dead and checkpoint hasn't moved — restarting`);
          await refreshJobberToken();
          startCatchup();
          stuckChecks = 0;
        }
      } else {
        lastProgress = pulled;
        stuckChecks = 0;
      }
    } catch (e) {
      // Transient (DNS, timeout, etc.) — log and keep polling. Bail only if
      // we've failed many times in a row, which suggests a real outage rather
      // than network jitter.
      consecutiveErrors++;
      console.log(`[${new Date().toISOString()}] poll err (${consecutiveErrors}): ${e.message.slice(0, 100)}`);
      if (consecutiveErrors >= 20) {
        console.error('FATAL: 20 consecutive poll failures, exiting');
        process.exit(2);
      }
    }

    await new Promise(rs => setTimeout(rs, 60000)); // poll every 60s
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
