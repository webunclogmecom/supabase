#!/usr/bin/env node
// ============================================================================
// register-airtable.js — Register Airtable webhook subscriptions
// ============================================================================
// One-time setup: tells Airtable to POST change notifications to our Edge Function.
//
// Usage:
//   node scripts/webhooks/register-airtable.js [--list] [--delete <id>]
//
// Prerequisites:
//   - AIRTABLE_API_KEY in .env (personal access token with webhook:manage scope)
//   - AIRTABLE_BASE_ID in .env
//   - Supabase Edge Function deployed: webhook-airtable
//
// Airtable sunsets May 2026 — this is a temporary bridge.
// ============================================================================

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });

const https = require('https');

const API_KEY = process.env.AIRTABLE_API_KEY;
const BASE_ID = process.env.AIRTABLE_BASE_ID;
const SUPABASE_PROJECT = process.env.SUPABASE_PROJECT_ID || 'wbasvhvvismukaqdnouk';

if (!API_KEY || !BASE_ID) {
  console.error('AIRTABLE_API_KEY and AIRTABLE_BASE_ID required in .env');
  process.exit(1);
}

const WEBHOOK_URL = `https://${SUPABASE_PROJECT}.supabase.co/functions/v1/webhook-airtable`;

// ---- HTTP helper ----
function airtableRequest(method, path, body = null) {
  return new Promise((resolve, reject) => {
    const bodyStr = body ? JSON.stringify(body) : null;
    const req = https.request(
      {
        hostname: 'api.airtable.com',
        path,
        method,
        headers: {
          Authorization: `Bearer ${API_KEY}`,
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

// ---- List existing webhooks ----
async function listWebhooks() {
  const result = await airtableRequest('GET', `/v0/bases/${BASE_ID}/webhooks`);
  return result.webhooks ?? [];
}

// ---- Create webhook ----
async function createWebhook() {
  // Watch all tables for record changes
  const spec = {
    options: {
      filters: {
        dataTypes: ['tableData'],
        recordChangeScope: 'tblXXXXXX', // Will be replaced with actual table IDs
      },
    },
  };

  // Create webhook with notification URL
  const result = await airtableRequest('POST', `/v0/bases/${BASE_ID}/webhooks`, {
    notificationUrl: WEBHOOK_URL,
    specification: {
      options: {
        filters: {
          dataTypes: ['tableData'],
          // Watch all tables — the Edge Function filters by table ID
          fromSources: ['client', 'publicApi', 'formSubmission', 'automation'],
        },
      },
    },
  });

  return result;
}

// ---- Delete webhook ----
async function deleteWebhook(webhookId) {
  return airtableRequest('DELETE', `/v0/bases/${BASE_ID}/webhooks/${webhookId}`);
}

// ---- List tables (for reference) ----
async function listTables() {
  const result = await airtableRequest('GET', `/v0/meta/bases/${BASE_ID}/tables`);
  return result.tables ?? [];
}

// ---- Main ----
(async () => {
  const args = process.argv.slice(2);

  if (args.includes('--list')) {
    console.log('Existing Airtable webhooks:');
    const hooks = await listWebhooks();
    if (!hooks.length) {
      console.log('  (none)');
    } else {
      hooks.forEach((h) => {
        console.log(`  ${h.id}  ${h.notificationUrl ?? '(no URL)'}`);
        console.log(`    Created: ${h.createdTime}  Expires: ${h.expirationTime ?? 'N/A'}`);
        if (h.specification?.options?.filters) {
          console.log(`    Filters: ${JSON.stringify(h.specification.options.filters)}`);
        }
      });
    }
    return;
  }

  if (args.includes('--tables')) {
    console.log('Airtable tables in base:');
    const tables = await listTables();
    tables.forEach((t) => console.log(`  ${t.id}  ${t.name}`));
    console.log('\nUpdate TABLE_HANDLERS in webhook-airtable/index.ts with these IDs.');
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

  // Default: create webhook
  console.log('============================================================');
  console.log('Registering Airtable webhook');
  console.log(`Base: ${BASE_ID}`);
  console.log(`Target URL: ${WEBHOOK_URL}`);
  console.log('============================================================\n');

  // First, list tables for reference
  console.log('Tables in base:');
  try {
    const tables = await listTables();
    tables.forEach((t) => console.log(`  ${t.id}  ${t.name}`));
    console.log('');
  } catch (e) {
    console.warn(`Could not list tables: ${e.message}\n`);
  }

  // Check existing webhooks
  const existing = await listWebhooks();
  if (existing.length) {
    console.log(`Found ${existing.length} existing webhook(s).`);
    console.log('Run --list to see details, --delete <id> to remove.\n');
  }

  try {
    const result = await createWebhook();
    console.log('Webhook created:');
    console.log(`  ID: ${result.id}`);
    console.log(`  Expiration: ${result.expirationTime ?? 'N/A'}`);
    if (result.macSecretBase64) {
      console.log(`  HMAC Secret: ${result.macSecretBase64}`);
      console.log('  >>> Set this as AIRTABLE_WEBHOOK_SECRET in Supabase secrets!');
    }
    if (result.cursorForNextPayload !== undefined) {
      console.log(`  Initial cursor: ${result.cursorForNextPayload}`);
    }
  } catch (e) {
    console.error(`Failed to create webhook: ${e.message}`);
    process.exit(1);
  }

  console.log('\nDone. Important next steps:');
  console.log('  1. Run --tables and update TABLE_HANDLERS in webhook-airtable/index.ts');
  console.log('  2. Set AIRTABLE_WEBHOOK_SECRET in Supabase secrets');
  console.log('  3. Airtable webhooks expire after 7 days — renew before expiry');
})();
