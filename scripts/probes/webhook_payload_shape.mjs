// Does webhook-jobber accept the payload shape REAL JOBBER actually sends?
//
// The docs (developer.getjobber.com/docs/using_jobbers_api/setting_up_webhooks) say Jobber POSTs:
//     { "data": { "webHookEvent": { "topic", "appId", "accountId", "itemId", "occurredAt" } } }
// Our handler reads payload.topic and payload.webHookEvent?.itemId - the FLAT shape - and every one
// of the 8,169 rows in webhook_events_log is flat with no appId and no accountId, i.e. they all look
// like our OWN sync-jobber-poll replays rather than anything Jobber sent.
//
// This probe settles it by sending both shapes, correctly signed, and comparing.
// Both are PROPERTY_UPDATE on an existing property: an idempotent re-sync, safe to repeat.
//
// Run: node --experimental-strip-types scripts/probes/webhook_payload_shape.mjs
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createClient } from '@supabase/supabase-js';
import { createHmac } from 'node:crypto';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const env = Object.fromEntries(readFileSync(join(ROOT, '.env'), 'utf8').split(/\r?\n/)
  .filter(l => /^[A-Z_]+=/.test(l))
  .map(l => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '').trim()]));
const U = `https://${env.SUPABASE_PROJECT_ID}.supabase.co`;
const SR = env.SUPABASE_SERVICE_ROLE_KEY;
const db = createClient(U, SR, { auth: { persistSession: false } });
const say = (...a) => console.log(...a);

const { data: link } = await db.from('entity_source_links').select('source_id')
  .eq('entity_type', 'property').eq('entity_id', 1091).eq('source_system', 'jobber').maybeSingle();
const { data: secretRow } = await db.from('webhook_tokens')
  .select('client_secret').eq('source_system', 'jobber').single();
if (!link?.source_id || !secretRow?.client_secret) { say('FATAL: missing fixture'); process.exit(1); }

const itemId = link.source_id;
const occurredAt = new Date().toISOString();

async function send(label, bodyObj) {
  const body = JSON.stringify(bodyObj);
  const sig = createHmac('sha256', secretRow.client_secret).update(body).digest('base64');
  const r = await fetch(`${U}/functions/v1/webhook-jobber`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-jobber-hmac-sha256': sig, 'x-sync-wait': '1' },
    body,
  });
  return { label, status: r.status, body: (await r.text()).slice(0, 160) };
}

// SHAPE A: what our code and our replays use
const flat = await send('FLAT (what our replays send)', {
  topic: 'PROPERTY_UPDATE',
  webHookEvent: { itemId, occurredAt },
});

// SHAPE B: what the DOCS say real Jobber sends
const nested = await send('NESTED (what the docs say Jobber sends)', {
  data: {
    webHookEvent: {
      topic: 'PROPERTY_UPDATE',
      appId: '00000000-0000-0000-0000-000000000000',
      accountId: 'MQ==',
      itemId,
      occurredAt,
    },
  },
});

say('Jobber docs payload: { data: { webHookEvent: { topic, appId, accountId, itemId, occurredAt } } }\n');
for (const r of [flat, nested]) say(`  ${r.label.padEnd(42)} HTTP ${r.status}  ${r.body}`);

const checks = [
  ['FLAT shape is accepted (proves the probe and signing work)', flat.status === 200],
  ['NESTED shape is ALSO accepted', nested.status === 200],
];
say('');
for (const [n, ok] of checks) say((ok ? 'PASS' : 'FAIL').padEnd(5), n);

if (flat.status === 200 && nested.status !== 200) {
  say('\n🛑 CONFIRMED: the endpoint accepts ONLY the flat shape.');
  say('   Real Jobber webhooks, which use the nested shape, would be REJECTED.');
  say('   ⇒ Everything in webhook_events_log is our own sync-jobber-poll replay traffic, and');
  say('     subscribing a new topic in the Developer Center would NOT work until this is fixed.');
}
process.exit(0);
