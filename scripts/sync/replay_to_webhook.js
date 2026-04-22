// ============================================================================
// replay_to_webhook.js — replay flagged raw.jobber_pull_* rows to webhook-jobber
// ============================================================================
// Pattern: for each row where needs_populate=TRUE, synthesize a Jobber-style
// webhook payload (topic + itemId GID), sign with JOBBER_CLIENT_SECRET, POST to
// the deployed webhook-jobber Edge Function. That handler re-queries Jobber
// GraphQL, upserts into public.* via entity_source_links — proven path.
//
// On success for a row, clear needs_populate so re-runs don't duplicate work.
//
// Flags:
//   --dry-run     (default) prints what would happen
//   --execute     actually POSTs
//   --entity=X    run only one entity (clients, jobs, visits, invoices, quotes)
//   --limit=N     cap rows per entity (useful for smoke tests)
// ============================================================================

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const crypto = require('crypto');
const https = require('https');
const { newQuery } = require('../populate/lib/db');

const args = process.argv.slice(2);
const DRY = !args.includes('--execute');
const ONLY = (args.find(a => a.startsWith('--entity=')) || '').split('=')[1] || null;
const LIMIT = parseInt((args.find(a => a.startsWith('--limit=')) || '').split('=')[1] || '0', 10);

const WEBHOOK_URL = `${process.env.SUPABASE_URL}/functions/v1/webhook-jobber`;
const SECRET = process.env.JOBBER_CLIENT_SECRET;
if (!SECRET) throw new Error('JOBBER_CLIENT_SECRET missing in .env');

// Entity → topic mapping. Use *_UPDATE so handlers upsert (create-or-update path).
const ENTITIES = [
  { name: 'clients',    rawTable: 'jobber_pull_clients',    topic: 'CLIENT_UPDATE' },
  { name: 'jobs',       rawTable: 'jobber_pull_jobs',       topic: 'JOB_UPDATE' },
  { name: 'visits',     rawTable: 'jobber_pull_visits',     topic: 'VISIT_UPDATE' },
  { name: 'invoices',   rawTable: 'jobber_pull_invoices',   topic: 'INVOICE_UPDATE' },
  { name: 'quotes',     rawTable: 'jobber_pull_quotes',     topic: 'QUOTE_UPDATE' },
];
// NOTE: properties and users aren't handled by webhook-jobber directly;
//       populate.js derives properties from jobs/client relations.

function signPayload(body) {
  return crypto.createHmac('sha256', SECRET).update(body).digest('base64');
}

function post(url, body, headers) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const req = https.request({
      hostname: u.hostname,
      path: u.pathname,
      method: 'POST',
      headers: { ...headers, 'Content-Length': Buffer.byteLength(body) },
    }, (res) => {
      let data = '';
      res.on('data', (c) => (data += c));
      res.on('end', () => resolve({ status: res.statusCode, body: data }));
    });
    req.on('error', reject);
    req.setTimeout(60_000, () => req.destroy(new Error('timeout')));
    req.write(body);
    req.end();
  });
}

async function replayOne(topic, gid) {
  const payload = { topic, webHookEvent: { itemId: gid, occurredAt: new Date().toISOString() } };
  const body = JSON.stringify(payload);
  const signature = signPayload(body);
  const r = await post(WEBHOOK_URL, body, {
    'Content-Type': 'application/json',
    'x-jobber-hmac-sha256': signature,
  });
  return r;
}

async function replayEntity(entity) {
  console.log(`\n[${entity.name}] start`);
  const limitClause = LIMIT ? `LIMIT ${LIMIT}` : '';
  const rows = await newQuery(
    `SELECT data->>'id' AS gid FROM raw.${entity.rawTable} WHERE needs_populate=TRUE ${limitClause};`
  );
  console.log(`  ${rows.length} rows to replay (topic=${entity.topic})`);

  if (DRY) {
    console.log(`  DRY-RUN — would POST ${rows.length} ${entity.topic} events`);
    return { entity: entity.name, pulled: rows.length, ok: 0, fail: 0, dryRun: true };
  }

  let ok = 0, fail = 0;
  const failures = [];
  for (let i = 0; i < rows.length; i++) {
    const gid = rows[i].gid;
    try {
      const r = await replayOne(entity.topic, gid);
      if (r.status >= 200 && r.status < 300) {
        ok++;
        // Clear the flag so we don't re-replay
        await newQuery(
          `UPDATE raw.${entity.rawTable} SET needs_populate=FALSE WHERE data->>'id'=${quote(gid)};`
        );
      } else {
        fail++;
        failures.push({ gid, status: r.status, body: r.body.slice(0, 200) });
      }
    } catch (err) {
      fail++;
      failures.push({ gid, error: err.message });
    }
    if ((i + 1) % 25 === 0 || i === rows.length - 1) {
      process.stdout.write(`  ${i + 1}/${rows.length} done (ok=${ok} fail=${fail})\r`);
    }
  }
  console.log();
  if (failures.length) {
    console.log(`  First 3 failures:`);
    failures.slice(0, 3).forEach(f => console.log('   ', JSON.stringify(f)));
  }
  return { entity: entity.name, pulled: rows.length, ok, fail };
}

function quote(v) { return "'" + String(v).replace(/'/g, "''") + "'"; }

(async () => {
  console.log('='.repeat(70));
  console.log('replay_to_webhook.js');
  console.log(`Mode:   ${DRY ? 'DRY-RUN' : 'EXECUTE'}`);
  console.log(`Entity: ${ONLY || 'all'}`);
  if (LIMIT) console.log(`Limit:  ${LIMIT} per entity`);
  console.log('='.repeat(70));

  const targets = ONLY ? ENTITIES.filter(e => e.name === ONLY) : ENTITIES;
  if (!targets.length) { console.error(`No entity matches --entity=${ONLY}`); process.exit(1); }

  const results = [];
  for (const e of targets) results.push(await replayEntity(e));

  console.log('\n' + '='.repeat(70));
  console.log('SUMMARY');
  console.table(results);

  const totalFail = results.reduce((s, r) => s + (r.fail || 0), 0);
  process.exit(totalFail > 0 ? 1 : 0);
})();
