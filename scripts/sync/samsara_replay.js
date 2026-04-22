// ============================================================================
// samsara_replay.js — pull live Samsara data + replay as synthetic webhook events
// ============================================================================
// Targets addresses + drivers only. Vehicle metadata updates aren't supported
// by the current webhook-samsara handler (that one is stats-telemetry only),
// so we leave vehicles for a separate path.
//
// Flow:
//   1. Fetch all /addresses  (paginated) → POST AddressUpdated per record
//   2. Fetch all /fleet/drivers          → POST DriverUpdated  per record
// Each POST is HMAC-signed with one of our registered webhook secretKeys.
// The Edge Function accepts any secret in SAMSARA_WEBHOOK_SECRETS, so this
// works regardless of which webhook the event would "normally" arrive through.
// ============================================================================

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const crypto = require('crypto');
const https = require('https');

const DRY = !process.argv.includes('--execute');
const ONLY = (process.argv.find(a => a.startsWith('--entity=')) || '').split('=')[1] || null;

const TOKEN = process.env.SAMSARA_API_TOKEN;
const WEBHOOK_URL = `${process.env.SUPABASE_URL}/functions/v1/webhook-samsara`;
// Any one registered secret suffices — Edge Function accepts any from the list.
const SECRET_LIST = process.env.SAMSARA_WEBHOOK_SECRETS || '';
const SECRET = SECRET_LIST.split(',')[0]?.trim();
if (!TOKEN) throw new Error('SAMSARA_API_TOKEN missing');
if (!SECRET) throw new Error('SAMSARA_WEBHOOK_SECRETS empty — run reset_samsara.js first');

function request(host, path, headers, method = 'GET', body = null) {
  return new Promise((resolve, reject) => {
    const payload = body ? JSON.stringify(body) : null;
    const req = https.request({
      hostname: host,
      path,
      method,
      headers: {
        ...headers,
        ...(payload ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) } : {}),
      },
    }, res => {
      let d = '';
      res.on('data', c => (d += c));
      res.on('end', () => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          try { resolve(JSON.parse(d || '{}')); } catch { resolve({ _raw: d }); }
        } else reject(new Error(`HTTP ${res.statusCode} ${method} ${host}${path}: ${d.slice(0, 300)}`));
      });
    });
    req.on('error', reject);
    req.setTimeout(60_000, () => req.destroy(new Error('timeout')));
    if (payload) req.write(payload);
    req.end();
  });
}

async function samsaraFetchAll(path) {
  const all = [];
  let after = null;
  do {
    const sep = path.includes('?') ? '&' : '?';
    const p = path + (after ? `${sep}after=${encodeURIComponent(after)}` : '');
    const r = await request('api.samsara.com', p, { Authorization: `Bearer ${TOKEN}` });
    const data = r.data || [];
    all.push(...data);
    after = r.pagination?.endCursor;
    if (!after || !r.pagination?.hasNextPage) break;
  } while (true);
  return all;
}

function signPayload(body) {
  return crypto.createHmac('sha256', SECRET).update(body).digest('base64');
}

async function postEvent(envelope) {
  const body = JSON.stringify(envelope);
  const res = await new Promise((resolve, reject) => {
    const u = new URL(WEBHOOK_URL);
    const req = https.request({
      hostname: u.hostname,
      path: u.pathname,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Samsara-Signature': signPayload(body),
        'Content-Length': Buffer.byteLength(body),
      },
    }, r => {
      let d = ''; r.on('data', c => (d += c));
      r.on('end', () => resolve({ status: r.statusCode, body: d }));
    });
    req.on('error', reject);
    req.setTimeout(60_000, () => req.destroy(new Error('timeout')));
    req.write(body);
    req.end();
  });
  return res;
}

async function replayAddresses() {
  console.log('\n[addresses] fetching from Samsara...');
  const addresses = await samsaraFetchAll('/addresses?limit=512');
  console.log(`  ${addresses.length} addresses`);
  if (DRY) return { table: 'addresses', fetched: addresses.length, ok: 0, fail: 0, dryRun: true };

  let ok = 0, fail = 0; const failures = [];
  for (let i = 0; i < addresses.length; i++) {
    const env = { eventType: 'AddressUpdated', data: { address: addresses[i] } };
    const r = await postEvent(env);
    if (r.status >= 200 && r.status < 300) ok++;
    else { fail++; failures.push({ id: addresses[i].id, status: r.status, body: r.body.slice(0, 150) }); }
    if ((i + 1) % 50 === 0 || i === addresses.length - 1) {
      process.stdout.write(`  ${i + 1}/${addresses.length} (ok=${ok} fail=${fail})\r`);
    }
  }
  console.log();
  if (failures.length) { console.log('  first 3:'); failures.slice(0, 3).forEach(f => console.log('   ', JSON.stringify(f))); }
  return { table: 'addresses', fetched: addresses.length, ok, fail };
}

async function replayDrivers() {
  console.log('\n[drivers] fetching from Samsara...');
  const drivers = await samsaraFetchAll('/fleet/drivers?limit=100');
  console.log(`  ${drivers.length} drivers`);
  if (DRY) return { table: 'drivers', fetched: drivers.length, ok: 0, fail: 0, dryRun: true };

  let ok = 0, fail = 0; const failures = [];
  for (let i = 0; i < drivers.length; i++) {
    const env = { eventType: 'DriverUpdated', data: { driver: drivers[i] } };
    const r = await postEvent(env);
    if (r.status >= 200 && r.status < 300) ok++;
    else { fail++; failures.push({ id: drivers[i].id, status: r.status, body: r.body.slice(0, 150) }); }
    if ((i + 1) % 20 === 0 || i === drivers.length - 1) {
      process.stdout.write(`  ${i + 1}/${drivers.length} (ok=${ok} fail=${fail})\r`);
    }
  }
  console.log();
  if (failures.length) { console.log('  first 3:'); failures.slice(0, 3).forEach(f => console.log('   ', JSON.stringify(f))); }
  return { table: 'drivers', fetched: drivers.length, ok, fail };
}

(async () => {
  console.log('='.repeat(60));
  console.log(`samsara_replay.js  Mode: ${DRY ? 'DRY-RUN' : 'EXECUTE'}`);
  console.log('='.repeat(60));

  const results = [];
  if (!ONLY || ONLY === 'addresses') results.push(await replayAddresses());
  if (!ONLY || ONLY === 'drivers')   results.push(await replayDrivers());

  console.log('\n' + '='.repeat(60));
  console.log('SUMMARY');
  console.table(results);

  const totalFail = results.reduce((s, r) => s + (r.fail || 0), 0);
  process.exit(totalFail > 0 ? 1 : 0);
})();
