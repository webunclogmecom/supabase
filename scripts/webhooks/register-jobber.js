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
          'X-JOBBER-GRAPHQL-VERSION': '2026-04-13',
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

// Note 2026-05-05: Jobber's current GraphQL API has NO query to list existing
// webhook endpoints (only WebHookEvent singular lookup). webhookEndpointCreate
// returns a userError if a duplicate exists, which we treat as "already done"
// — fully idempotent.

// ---- Create a webhook subscription ----
async function createWebhook(topic) {
  const data = await jobberGql(
    `mutation CreateWebhook($input: WebhookEndpointCreateInput!) {
      webhookEndpointCreate(input: $input) {
        webhookEndpoint { id topic url }
        userErrors { message path }
      }
    }`,
    { input: { topic, url: WEBHOOK_URL } }
  );

  const result = data.webhookEndpointCreate;
  const errs = result?.userErrors ?? [];
  // Detect "already registered" — message wording varies across Jobber API
  // versions, so we match defensively on common substrings.
  const dupErr = errs.find(e => /already|exists|duplicate/i.test(e.message || ''));
  if (dupErr) return { skipped: true, reason: dupErr.message };
  if (errs.length) throw new Error(`Failed: ${JSON.stringify(errs)}`);
  return result?.webhookEndpoint;
}

// ---- Delete a webhook ----
async function deleteWebhook(id) {
  const data = await jobberGql(
    `mutation DeleteWebhook($id: EncodedId!) {
      webhookEndpointDelete(id: $id) {
        deletedId
        userErrors { message }
      }
    }`,
    { id }
  );
  return data.webhookEndpointDelete;
}

// ---- Main ----
(async () => {
  const args = process.argv.slice(2);

  if (args.includes('--list')) {
    console.log("Jobber's current API has no list-webhooks query — only");
    console.log('per-topic webhookEndpointCreate (which returns userError on');
    console.log('duplicate). To audit subscriptions, check webhook_events_log');
    console.log('for which topics have actually delivered events recently.');
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

  // Try to register every topic. Jobber returns userError if already exists.
  for (const topic of TOPICS) {
    try {
      const result = await createWebhook(topic);
      if (result.skipped) console.log(`  [skip] ${topic} — already registered (${result.reason.slice(0, 60)})`);
      else console.log(`  [ok]   ${topic} → ${result.id}`);
    } catch (e) {
      console.error(`  [fail] ${topic}: ${e.message}`);
    }
  }

  console.log('\nDone.');
})();
