// ============================================================================
// airtable_replay.js — fetch all records from Airtable + replay to webhook-airtable
// ============================================================================
// Uses Path B (Bearer token) of webhook-airtable, which calls the same handlers
// that real-time Airtable automations call. Idempotent via findEntityBySourceId.
//
// Tables → entities:
//   Clients        → client         (service_configs, client.client_code)
//   DERM           → derm_manifest  (derm_manifests)
//   Route Creation → route          (routes)
//   Past Due       → receivable     (receivables)
// ============================================================================

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const DRY = !process.argv.includes('--execute');
const ONLY = (process.argv.find(a => a.startsWith('--entity=')) || '').split('=')[1] || null;

const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
const TOKEN = process.env.AIRTABLE_WEBHOOK_TOKEN;
if (!TOKEN) throw new Error('AIRTABLE_WEBHOOK_TOKEN missing in .env');
const WEBHOOK_URL = `${process.env.SUPABASE_URL}/functions/v1/webhook-airtable`;

if (!AT_KEY || !AT_BASE) throw new Error('AIRTABLE_API_KEY or AIRTABLE_BASE_ID missing');

const TABLES = [
  { name: 'Clients', entity: 'client' },
  { name: 'DERM', entity: 'derm_manifest' },
  { name: 'Route Creation', entity: 'route' },
  { name: 'Past due', entity: 'receivable' },  // lowercase 'd' per Airtable
  { name: 'PRE-POST insptection', entity: 'inspection' }, // typo is Airtable's canonical name
];

function httpsGet(host, path, headers) {
  return new Promise((resolve, reject) => {
    https.request({ hostname: host, path, headers }, r => {
      let d = '';
      r.on('data', c => d += c);
      r.on('end', () => {
        if (r.statusCode >= 200 && r.statusCode < 300) {
          try { resolve(JSON.parse(d)); } catch (e) { reject(new Error('bad json: ' + d.slice(0, 300))); }
        } else reject(new Error(`HTTP ${r.statusCode} ${host}${path}: ${d.slice(0, 300)}`));
      });
    }).on('error', reject).end();
  });
}

async function fetchAllRecords(tableName) {
  const all = [];
  let offset = null;
  do {
    const q = new URLSearchParams();
    q.set('pageSize', '100');
    if (offset) q.set('offset', offset);
    const r = await httpsGet('api.airtable.com', `/v0/${AT_BASE}/${encodeURIComponent(tableName)}?${q}`, {
      Authorization: `Bearer ${AT_KEY}`,
    });
    all.push(...(r.records || []));
    offset = r.offset;
  } while (offset);
  return all;
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
      res.on('data', c => (data += c));
      res.on('end', () => resolve({ status: res.statusCode, body: data }));
    });
    req.on('error', reject);
    req.setTimeout(60_000, () => req.destroy(new Error('timeout')));
    req.write(body);
    req.end();
  });
}

async function replayRecord(entity, rec) {
  const payload = {
    entity,
    recordId: rec.id,
    fields: rec.fields,
    changeType: 'updated',
  };
  return post(WEBHOOK_URL, JSON.stringify(payload), {
    'Content-Type': 'application/json',
    Authorization: `Bearer ${TOKEN}`,
  });
}

(async () => {
  console.log('='.repeat(60));
  console.log(`airtable_replay.js  Mode: ${DRY ? 'DRY-RUN' : 'EXECUTE'}`);
  console.log('='.repeat(60));

  const targets = ONLY ? TABLES.filter(t => t.entity === ONLY) : TABLES;
  const summary = [];

  for (const t of targets) {
    console.log(`\n[${t.name} → ${t.entity}]`);
    const records = await fetchAllRecords(t.name);
    console.log(`  fetched ${records.length} records`);

    if (DRY) { summary.push({ table: t.name, fetched: records.length, ok: 0, fail: 0, dryRun: true }); continue; }

    let ok = 0, fail = 0; const failures = [];
    for (let i = 0; i < records.length; i++) {
      try {
        const r = await replayRecord(t.entity, records[i]);
        if (r.status >= 200 && r.status < 300) ok++;
        else { fail++; failures.push({ id: records[i].id, status: r.status, body: r.body.slice(0, 150) }); }
      } catch (err) { fail++; failures.push({ id: records[i].id, error: err.message }); }
      if ((i + 1) % 50 === 0 || i === records.length - 1) {
        process.stdout.write(`  ${i + 1}/${records.length} (ok=${ok} fail=${fail})\r`);
      }
    }
    console.log();
    if (failures.length) {
      console.log(`  first 3 failures:`);
      failures.slice(0, 3).forEach(f => console.log('   ', JSON.stringify(f)));
    }
    summary.push({ table: t.name, fetched: records.length, ok, fail });
  }

  console.log('\n' + '='.repeat(60));
  console.log('SUMMARY');
  console.table(summary);
  const totalFail = summary.reduce((s, r) => s + (r.fail || 0), 0);
  process.exit(totalFail > 0 ? 1 : 0);
})();
