// Replay missing Jobber records into our DB by POSTing each GID to
// webhook-jobber as if it were a CREATE event. Reads gap CSVs produced by
// scripts/probes/jobber_completeness_check.js.
//
// Usage:
//   node scripts/sync/replay_jobber_gaps.js --csv=jobber_gaps_invoices_2026-05-04.csv --topic=INVOICE_CREATE
//   node scripts/sync/replay_jobber_gaps.js --csv=jobber_gaps_jobs_2026-05-04.csv     --topic=JOB_CREATE
//   node scripts/sync/replay_jobber_gaps.js --csv=jobber_gaps_clients_2026-05-04.csv  --topic=CLIENT_CREATE
//
// Idempotent — webhook-jobber UPSERTs by Jobber GID, so re-running won't duplicate.

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const fs = require('fs');
const path = require('path');
const https = require('https');
const crypto = require('crypto');

const csvArg = (process.argv.find(a => a.startsWith('--csv=')) || '').split('=')[1];
const topicArg = (process.argv.find(a => a.startsWith('--topic=')) || '').split('=')[1];
if (!csvArg || !topicArg) {
  console.error('Usage: node replay_jobber_gaps.js --csv=<file> --topic=<TOPIC>');
  process.exit(2);
}

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej); req.setTimeout(60000, () => req.destroy(new Error('timeout')));
    if (body) req.write(body); req.end();
  });
}

const csvPath = path.resolve(__dirname, '../..', csvArg);
const lines = fs.readFileSync(csvPath, 'utf8').split('\n').filter(Boolean);
const gids = lines.slice(1).map(l => l.split(',')[0]).filter(Boolean);

const SBHOST = `${process.env.SUPABASE_PROJECT_ID}.supabase.co`;

(async () => {
  console.log(`Replaying ${gids.length} ${topicArg} events from ${csvArg}\n`);
  let ok = 0, err = 0;
  for (let i = 0; i < gids.length; i++) {
    const gid = gids[i];
    const payload = JSON.stringify({
      topic: topicArg,
      webHookEvent: {
        itemId: gid,
        occurredAt: new Date().toISOString(),
      },
    });
    // webhook-jobber verifies HMAC-SHA256 using JOBBER_CLIENT_SECRET as the key
    // (Jobber's webhook secret = their client secret). Same pattern as cron_jobber.js.
    const sig = crypto.createHmac('sha256', process.env.JOBBER_CLIENT_SECRET).update(payload).digest('base64');
    const r = await http({
      hostname: SBHOST,
      path: '/functions/v1/webhook-jobber',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-jobber-hmac-sha256': sig,
      },
    }, payload);
    if (r.status >= 200 && r.status < 300) ok++;
    else { err++; console.log(`  ✗ [${i+1}/${gids.length}] ${gid.slice(-12)}: HTTP ${r.status} ${r.body.slice(0, 100)}`); }
    if ((i + 1) % 25 === 0) console.log(`  progress ${i+1}/${gids.length} (ok=${ok}, err=${err})`);
    // Pace — webhook-jobber calls Jobber GraphQL, respect Jobber budget
    await new Promise(rs => setTimeout(rs, 500));
  }
  console.log(`\n=== Done: ${ok} ok, ${err} err ===`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
