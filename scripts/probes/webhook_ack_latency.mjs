// Measure what JOBBER actually waits for on webhook-jobber.
//
// 🛑 WHY A DIRECT TIMING AND NOT webhook_events_log.processing_ms: since the 2026-08-20 ack-first
//    change, processing_ms measures the BACKGROUND work, not the response. Reading that column as
//    the SLA metric would now be measuring the wrong thing entirely.
//
// Jobber's rule, verbatim from developer.getjobber.com: "Webhook requests must be responded to
// within 1 second of receipt ... If response times consistently exceed the 1-second limit ... Jobber
// may disable the app's webhooks."
//
// Sends a REAL, correctly-signed PROPERTY_UPDATE for a property that already exists. That handler is
// an idempotent re-sync from Jobber, so it is safe to repeat and changes nothing.
//
// Run: node --experimental-strip-types scripts/probes/webhook_ack_latency.mjs
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

// a real, existing property so the handler does real work
const { data: link } = await db.from('entity_source_links').select('source_id')
  .eq('entity_type', 'property').eq('entity_id', 1091).eq('source_system', 'jobber').maybeSingle();
if (!link?.source_id) { say('FATAL: no jobber link for property 1091'); process.exit(1); }

const { data: secretRow } = await db.from('webhook_tokens')
  .select('client_secret').eq('source_system', 'jobber').single();
if (!secretRow?.client_secret) { say('FATAL: no webhook secret'); process.exit(1); }

const payload = JSON.stringify({
  topic: 'PROPERTY_UPDATE',
  webHookEvent: { itemId: link.source_id, occurredAt: new Date().toISOString() },
});
const sig = createHmac('sha256', secretRow.client_secret).update(payload).digest('base64');

async function timed(label, extraHeaders) {
  const t0 = Date.now();
  const r = await fetch(`${U}/functions/v1/webhook-jobber`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-jobber-hmac-sha256': sig, ...extraHeaders },
    body: payload,
  });
  const body = await r.text();
  const ms = Date.now() - t0;
  return { label, ms, status: r.status, body: body.slice(0, 120) };
}

say('Jobber SLA: respond within 1000 ms.\n');

// ---- ARM A: the async path, what real Jobber traffic now gets --------------------------------
const a = [];
for (let i = 0; i < 3; i++) a.push(await timed('async', {}));
for (const r of a) say(`  ASYNC (real Jobber path)   ${String(r.ms).padStart(5)} ms  HTTP ${r.status}  ${r.body}`);

// ---- ARM B: the sync escape hatch, what our own replays use -----------------------------------
const b = await timed('sync', { 'x-sync-wait': '1' });
say(`  SYNC  (x-sync-wait, ours)  ${String(b.ms).padStart(5)} ms  HTTP ${b.status}  ${b.body}`);

// ---- CONTROL: an UNSIGNED request must still be refused ---------------------------------------
const t0 = Date.now();
const bad = await fetch(`${U}/functions/v1/webhook-jobber`, {
  method: 'POST', headers: { 'Content-Type': 'application/json' }, body: payload });
say(`  CONTROL unsigned           ${String(Date.now() - t0).padStart(5)} ms  HTTP ${bad.status}  (must NOT be 200)`);

const worstAsync = Math.max(...a.map(r => r.ms));
const checks = [
  ['every async ack is under Jobber\'s 1000 ms limit', a.every(r => r.ms < 1000)],
  ['async acks are HTTP 200', a.every(r => r.status === 200)],
  ['async body is an acknowledgement, not a result', a.every(r => r.body.includes('accepted'))],
  ['the sync escape hatch still returns a real result', b.status === 200 && b.body.includes('entity_id')],
  ['sync is SLOWER than async (proves async really deferred the work)', b.ms > worstAsync],
  ['CONTROL: unsigned request refused', bad.status !== 200],
];
say('');
for (const [n, ok] of checks) say((ok ? 'PASS' : 'FAIL').padEnd(5), n);
say(`\n${checks.filter(c => c[1]).length}/${checks.length} passed`);
say(`\nworst async ack: ${worstAsync} ms   |   sync path: ${b.ms} ms`);
process.exit(checks.every(c => c[1]) ? 0 : 1);
