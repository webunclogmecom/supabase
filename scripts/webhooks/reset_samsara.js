// ============================================================================
// reset_samsara.js — wipe + re-register Samsara webhooks with captured secrets
// ============================================================================
// Samsara generates a distinct signing secret per webhook registration; that
// secret is only returned once at creation time. When you register a webhook
// a second time for the same event type (by accident or otherwise), the old
// one keeps its now-lost secret and signs with it — all its events will fail
// HMAC verification on our side.
//
// This script:
//   1. Lists all current webhooks pointing at our Edge Function.
//   2. DELETEs every one of them.
//   3. Creates 6 fresh webhooks (one per event-type group matching prior setup).
//   4. Collects the 6 new signing secrets and prints them comma-joined for
//      SAMSARA_WEBHOOK_SECRETS (set this value in Supabase secrets).
//
// Flags:
//   --dry-run (default) — shows the plan
//   --execute           — performs the delete + re-create
//
// Safety: operates only on webhooks whose URL matches our Edge Function.
// ============================================================================

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const DRY = !process.argv.includes('--execute');
const TOKEN = process.env.SAMSARA_API_TOKEN;
if (!TOKEN) throw new Error('SAMSARA_API_TOKEN missing');

const EDGE_URL = 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/webhook-samsara';

// Target webhook set (matches the prior config one-for-one).
const TARGET_WEBHOOKS = [
  { name: 'Unclogme: New Address',         eventTypes: ['AddressCreated'] },
  { name: 'Unclogme: Address Updated',     eventTypes: ['AddressUpdated'] },
  { name: 'Unclogme: Address Deleted',     eventTypes: ['AddressDeleted'] },
  { name: 'Unclogme: New Driver',          eventTypes: ['DriverCreated'] },
  { name: 'Unclogme: Driver Updated',      eventTypes: ['DriverUpdated'] },
  { name: 'Unclogme: Alerts (geofence + fuel)', eventTypes: ['AlertIncident', 'AlertObjectEvent'] },
];

function api(method, path, body) {
  return new Promise((resolve, reject) => {
    const payload = body ? JSON.stringify(body) : null;
    const req = https.request({
      hostname: 'api.samsara.com',
      path,
      method,
      headers: {
        Authorization: `Bearer ${TOKEN}`,
        'Content-Type': 'application/json',
        ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}),
      },
    }, res => {
      let data = '';
      res.on('data', c => (data += c));
      res.on('end', () => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          try { resolve(data ? JSON.parse(data) : {}); } catch { resolve({}); }
        } else reject(new Error(`HTTP ${res.statusCode} ${method} ${path}: ${data.slice(0, 300)}`));
      });
    });
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

(async () => {
  console.log('='.repeat(60));
  console.log(`reset_samsara.js  Mode: ${DRY ? 'DRY-RUN' : 'EXECUTE'}`);
  console.log('='.repeat(60));

  // 1. List current webhooks
  const list = await api('GET', '/webhooks');
  const ours = (list.data || []).filter(w => (w.url || '').startsWith(EDGE_URL));
  const notOurs = (list.data || []).filter(w => !(w.url || '').startsWith(EDGE_URL));
  console.log(`current total: ${(list.data || []).length}`);
  console.log(`  ours (matching EDGE_URL): ${ours.length}`);
  console.log(`  others (will NOT touch):  ${notOurs.length}`);
  if (notOurs.length) notOurs.forEach(w => console.log(`    skip id=${w.id} url=${(w.url||'').slice(0,60)}`));

  if (DRY) {
    console.log(`\nDRY-RUN plan:`);
    console.log(`  - DELETE ${ours.length} existing webhook(s)`);
    console.log(`  - CREATE ${TARGET_WEBHOOKS.length} fresh webhook(s): ${TARGET_WEBHOOKS.map(t => t.name).join(' | ')}`);
    return;
  }

  // 2. Delete all ours
  console.log(`\nDeleting ${ours.length} existing webhook(s)...`);
  for (const w of ours) {
    await api('DELETE', `/webhooks/${w.id}`);
    console.log(`  deleted ${w.id} (${w.name})`);
  }

  // 3. Create 6 fresh
  console.log(`\nCreating ${TARGET_WEBHOOKS.length} fresh webhook(s)...`);
  const created = [];
  for (const t of TARGET_WEBHOOKS) {
    const body = { name: t.name, url: EDGE_URL, eventTypes: t.eventTypes };
    const resp = await api('POST', '/webhooks', body);
    const w = resp.data || resp || {};
    // Samsara returns the secret as `secretKey` on its /webhooks endpoint.
    const secret = w.secretKey || w.secret || w.signingSecret || null;
    created.push({ id: w.id, name: t.name, secret });
    console.log(`  created id=${w.id} ${t.name}  secret=${secret ? '(captured)' : '(MISSING — check UI)'}`);
  }

  const secretsJoined = created.map(c => c.secret).filter(Boolean).join(',');
  console.log(`\n${'='.repeat(60)}`);
  console.log('SECRETS — set this as SAMSARA_WEBHOOK_SECRETS in Supabase:');
  console.log(secretsJoined);
  console.log('='.repeat(60));
  console.log(`\nRun: npx supabase secrets set SAMSARA_WEBHOOK_SECRETS='${secretsJoined}' --project-ref wbasvhvvismukaqdnouk`);
})();
