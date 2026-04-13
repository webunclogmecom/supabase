#!/usr/bin/env node
// ============================================================================
// register-jobber.js — Register Jobber webhook subscriptions
// ============================================================================
// One-time setup: tells Jobber where to POST webhook events.
//
// Usage:
//   node scripts/webhooks/register-jobber.js [--list] [--delete <id>]
//
// Prerequisites:
//   - JOBBER_ACCESS_TOKEN in .env (valid OAuth token)
//   - Supabase Edge Function deployed: webhook-jobber
//   - JOBBER_WEBHOOK_SECRET set in both Jobber app and Supabase secrets
//
// Jobber sunsets May 2026 — this is a temporary bridge.
// ============================================================================

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });

const https = require('https');

const TOKEN = process.env.JOBBER_ACCESS_TOKEN;
const SUPABASE_PROJECT = process.env.SUPABASE_PROJECT_ID || 'wbasvhvvismukaqdnouk';

if (!TOKEN) {
  console.error('JOBBER_ACCESS_TOKEN not found in .env');
  process.exit(1);
}

// Edge Function URL where Jobber will send webhooks
const WEBHOOK_URL = `https://${SUPABASE_PROJECT}.supabase.co/functions/v1/webhook-jobber`;

// Topics to subscribe to
const TOPICS = [
  'CLIENT_CREATE',
  'CLIENT_UPDATE',
  'VISIT_CREATE',
  'VISIT_UPDATE',
  'JOB_CREATE',
  'JOB_UPDATE',
  'INVOICE_CREATE',
  'INVOICE_UPDATE',
  'QUOTE_CREATE',
  'QUOTE_UPDATE',
];

// ---- Jobber GraphQL helper ----
function jobberGql(query, variables = {}) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ query, variables });
    const req = https.request(
      {
        hostname: 'api.getjobber.com',
        path: '/api/graphql',
        method: 'POST',
        headers: {
          Authorization: `Bearer ${TOKEN}`,
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(body),
        },
      },
      (res) => {
        let data = '';
        res.on('data', (c) => (data += c));
        res.on('end', () => {
          try {
            const json = JSON.parse(data);
            if (json.errors?.length) {
              reject(new Error(`GraphQL error: ${JSON.stringify(json.errors[0])}`));
            } else {
              resolve(json.data);
            }
          } catch (e) {
            reject(new Error(`Bad response: ${data.slice(0, 300)}`));
          }
        });
      }
    );
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

// ---- List existing webhooks ----
async function listWebhooks() {
  const data = await jobberGql(`
    query {
      webhooks(first: 50) {
        nodes {
          id
          topic
          url
          createdAt
        }
      }
    }
  `);
  return data.webhooks?.nodes ?? [];
}

// ---- Create a webhook subscription ----
async function createWebhook(topic) {
  const data = await jobberGql(
    `mutation CreateWebhook($input: WebhookCreateInput!) {
      webhookCreate(input: $input) {
        webhook { id topic url }
        userErrors { message path }
      }
    }`,
    { input: { topic, url: WEBHOOK_URL } }
  );

  if (data.webhookCreate?.userErrors?.length) {
    throw new Error(`Failed: ${JSON.stringify(data.webhookCreate.userErrors)}`);
  }
  return data.webhookCreate?.webhook;
}

// ---- Delete a webhook ----
async function deleteWebhook(id) {
  const data = await jobberGql(
    `mutation DeleteWebhook($id: EncodedId!) {
      webhookDelete(id: $id) {
        webhook { id }
        userErrors { message }
      }
    }`,
    { id }
  );
  return data.webhookDelete;
}

// ---- Main ----
(async () => {
  const args = process.argv.slice(2);

  if (args.includes('--list')) {
    console.log('Existing Jobber webhooks:');
    const hooks = await listWebhooks();
    if (!hooks.length) {
      console.log('  (none)');
    } else {
      hooks.forEach((h) => console.log(`  ${h.id}  ${h.topic.padEnd(20)}  ${h.url}`));
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

  // Default: register all topics
  console.log('============================================================');
  console.log('Registering Jobber webhooks');
  console.log(`Target URL: ${WEBHOOK_URL}`);
  console.log('============================================================\n');

  // Check existing
  const existing = await listWebhooks();
  const existingTopics = new Set(existing.map((h) => h.topic));

  for (const topic of TOPICS) {
    if (existingTopics.has(topic)) {
      console.log(`  [skip] ${topic} — already registered`);
      continue;
    }
    try {
      const wh = await createWebhook(topic);
      console.log(`  [ok]   ${topic} → ${wh.id}`);
    } catch (e) {
      console.error(`  [fail] ${topic}: ${e.message}`);
    }
  }

  console.log('\nDone. Run with --list to verify.');
})();
