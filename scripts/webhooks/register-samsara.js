#!/usr/bin/env node
// ============================================================================
// register-samsara.js — Register Samsara webhook subscriptions
// ============================================================================
// PERMANENT INTEGRATION — Samsara stays after Jobber/Airtable sunset.
//
// Usage:
//   node scripts/webhooks/register-samsara.js [--list] [--delete <id>]
//
// Prerequisites:
//   - SAMSARA_API_TOKEN in .env
//   - Supabase Edge Function deployed: webhook-samsara
//
// Samsara event types registered:
//   - AddressCreated, AddressUpdated, AddressDeleted → client GPS
//   - DriverCreated, DriverUpdated → employee records
//   - VehicleStatsSnapshot → vehicle_fuel_readings (fuel levels)
//   - AlertTriggered (geofence) → visit GPS enrichment
// ============================================================================

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });

const https = require('https');

const TOKEN = process.env.SAMSARA_API_TOKEN;
const SUPABASE_PROJECT = process.env.SUPABASE_PROJECT_ID || 'wbasvhvvismukaqdnouk';

if (!TOKEN) {
  console.error('SAMSARA_API_TOKEN not found in .env');
  process.exit(1);
}

const WEBHOOK_URL = `https://${SUPABASE_PROJECT}.supabase.co/functions/v1/webhook-samsara`;

// ---- HTTP helper ----
function samsaraRequest(method, path, body = null) {
  return new Promise((resolve, reject) => {
    const bodyStr = body ? JSON.stringify(body) : null;
    const req = https.request(
      {
        hostname: 'api.samsara.com',
        path,
        method,
        headers: {
          Authorization: `Bearer ${TOKEN}`,
          'Content-Type': 'application/json',
          ...(bodyStr ? { 'Content-Length': Buffer.byteLength(bodyStr) } : {}),
        },
      },
      (res) => {
        let data = '';
        res.on('data', (c) => (data += c));
        res.on('end', () => {
          if (res.statusCode >= 200 && res.statusCode < 300) {
            try {
              resolve(JSON.parse(data));
            } catch {
              resolve(data);
            }
          } else {
            reject(new Error(`HTTP ${res.statusCode}: ${data.slice(0, 500)}`));
          }
        });
      }
    );
    req.on('error', reject);
    if (bodyStr) req.write(bodyStr);
    req.end();
  });
}

// ---- Event Subscription types to register ----
const EVENT_SUBSCRIPTIONS = [
  // Address events → client GPS + geofence updates
  { eventType: 'AddressCreated', name: 'Unclogme: New Address' },
  { eventType: 'AddressUpdated', name: 'Unclogme: Address Updated' },
  { eventType: 'AddressDeleted', name: 'Unclogme: Address Deleted' },
  // Driver events → employee records
  { eventType: 'DriverCreated', name: 'Unclogme: New Driver' },
  { eventType: 'DriverUpdated', name: 'Unclogme: Driver Updated' },
];

// ---- List existing webhooks ----
async function listWebhooks() {
  const result = await samsaraRequest('GET', '/webhooks');
  return result.data ?? result.webhooks ?? [];
}

// ---- Create event subscription webhook ----
async function createEventWebhook(eventType, name) {
  return samsaraRequest('POST', '/webhooks', {
    name,
    url: WEBHOOK_URL,
    eventTypes: [eventType],
  });
}

// ---- Create alert webhook (for geofence events) ----
async function createAlertWebhook() {
  // Samsara alerts use a different registration flow
  // Alert webhooks are configured in the Samsara dashboard
  // but can also be set via API
  return samsaraRequest('POST', '/webhooks', {
    name: 'Unclogme: Geofence & Vehicle Stats',
    url: WEBHOOK_URL,
    eventTypes: [
      'GeofenceEntry',
      'GeofenceExit',
      'VehicleStatsSnapshot',
    ],
  });
}

// ---- Delete webhook ----
async function deleteWebhook(webhookId) {
  return samsaraRequest('DELETE', `/webhooks/${webhookId}`);
}

// ---- List addresses (for verification) ----
async function listAddresses() {
  const result = await samsaraRequest('GET', '/addresses?limit=50');
  return result.data ?? [];
}

// ---- List vehicles (for verification) ----
async function listVehicles() {
  const result = await samsaraRequest('GET', '/fleet/vehicles?limit=50&types=');  // /fleet/vehicles may need params
  return result.data ?? result.vehicles ?? [];
}

// ---- Fetch current vehicle stats (for initial fuel reading) ----
async function fetchVehicleStats() {
  const result = await samsaraRequest('GET', '/fleet/vehicles/stats?types=fuelPercent,obdOdometerMeters,engineStates&decorations=name');
  return result.data ?? [];
}

// ---- Main ----
(async () => {
  const args = process.argv.slice(2);

  if (args.includes('--list')) {
    console.log('Existing Samsara webhooks:');
    const hooks = await listWebhooks();
    if (!hooks.length) {
      console.log('  (none)');
    } else {
      hooks.forEach((h) => {
        console.log(`  ${h.id}  ${h.name ?? '(unnamed)'}`);
        console.log(`    URL: ${h.url}`);
        console.log(`    Events: ${(h.eventTypes ?? []).join(', ')}`);
      });
    }
    return;
  }

  if (args.includes('--vehicles')) {
    console.log('Samsara vehicles:');
    const vehicles = await listVehicles();
    vehicles.forEach((v) => console.log(`  ${v.id}  ${v.name}`));
    return;
  }

  if (args.includes('--addresses')) {
    console.log('Samsara addresses (first 50):');
    const addrs = await listAddresses();
    addrs.forEach((a) => console.log(`  ${a.id}  ${a.name}`));
    console.log(`  (${addrs.length} shown)`);
    return;
  }

  if (args.includes('--fuel')) {
    console.log('Current vehicle fuel levels:');
    try {
      const stats = await fetchVehicleStats();
      for (const v of stats) {
        const fuel = v.fuelPercent?.value ?? v.fuelPercent ?? 'N/A';
        const odo = v.obdOdometerMeters?.value ?? 'N/A';
        const engine = v.engineStates?.[0]?.value ?? 'N/A';
        console.log(`  ${(v.name ?? v.id).padEnd(15)} Fuel: ${fuel}%  Odometer: ${odo}m  Engine: ${engine}`);
      }
    } catch (e) {
      console.error(`Failed to fetch vehicle stats: ${e.message}`);
    }
    return;
  }

  if (args.includes('--delete')) {
    const idx = args.indexOf('--delete');
    const id = args[idx + 1];
    if (!id) {
      console.error('Usage: --delete <webhook_id>');
      process.exit(1);
    }
    console.log(`Deleting webhook ${id}...`);
    await deleteWebhook(id);
    console.log('Deleted.');
    return;
  }

  // Default: register all subscriptions
  console.log('============================================================');
  console.log('Registering Samsara webhooks');
  console.log(`Target URL: ${WEBHOOK_URL}`);
  console.log('============================================================\n');

  // Check existing
  const existing = await listWebhooks();
  const existingUrls = new Set(existing.filter((h) => h.url === WEBHOOK_URL).map((h) => (h.eventTypes ?? []).join(',')));

  console.log(`Found ${existing.length} existing webhook(s).\n`);

  // Register event subscriptions
  console.log('Event subscriptions:');
  for (const sub of EVENT_SUBSCRIPTIONS) {
    try {
      const result = await createEventWebhook(sub.eventType, sub.name);
      const id = result.data?.id ?? result.id ?? '???';
      console.log(`  [ok]   ${sub.eventType.padEnd(20)} → ${id}`);
      if (result.data?.secret || result.secret) {
        console.log(`         Secret: ${result.data?.secret ?? result.secret}`);
        console.log(`         >>> Set this as SAMSARA_WEBHOOK_SECRET in Supabase secrets!`);
      }
    } catch (e) {
      console.error(`  [fail] ${sub.eventType}: ${e.message.slice(0, 200)}`);
    }
  }

  // Register alert webhook (geofence + vehicle stats)
  console.log('\nAlert webhook (geofence + fuel stats):');
  try {
    const result = await createAlertWebhook();
    const id = result.data?.id ?? result.id ?? '???';
    console.log(`  [ok]   Geofence & VehicleStats → ${id}`);
  } catch (e) {
    console.error(`  [fail] ${e.message.slice(0, 200)}`);
    console.log('  Note: Some event types may need to be configured in the Samsara dashboard.');
  }

  console.log('\nDone. Verify with --list.');
  console.log('\nNext steps:');
  console.log('  1. Set SAMSARA_WEBHOOK_SECRET in Supabase Edge Function secrets');
  console.log('  2. Test with --fuel to verify current fuel data');
  console.log('  3. Check webhook-samsara Edge Function logs for incoming events');
})();
