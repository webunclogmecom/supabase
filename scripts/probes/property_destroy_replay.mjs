// Replay the PROPERTY_DESTROY that FAILED, and prove the soft-delete fix works.
//
// On 2026-08-21 05:24:57 the first real PROPERTY_DESTROY this integration ever received failed:
//   "violates foreign key constraint jobs_property_id_fkey on table jobs"
// because handlePropertyDestroy hard-deleted a parent whose soft-deleted child still held the FK.
//
// This sends the SAME event again (Jobber's own at-least-once semantics make a redelivery a normal
// thing, not a hack) and checks the outcome that matters: the property is RETIRED, still PRESENT,
// and its job history is intact.
//
// Run: node --experimental-strip-types scripts/probes/property_destroy_replay.mjs
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

const { data: secretRow } = await db.from('webhook_tokens')
  .select('client_secret').eq('source_system', 'jobber').single();

// The two orphans: 1090 (the failed destroy) and 1092 (deleted in Jobber earlier, never notified).
const TARGETS = [1090, 1092];

say('BEFORE');
for (const id of TARGETS) {
  const { data: p } = await db.from('properties').select('id,address,deleted_at').eq('id', id).maybeSingle();
  say(`  property ${id}: ${p ? `present, deleted_at=${p.deleted_at ?? 'NULL (live)'}` : 'ABSENT'}  ${p?.address ?? ''}`);
}

say('\nREPLAY (nested shape, exactly as Jobber sends it)');
for (const id of TARGETS) {
  const { data: link } = await db.from('entity_source_links').select('source_id')
    .eq('entity_type', 'property').eq('entity_id', id).eq('source_system', 'jobber').maybeSingle();
  if (!link?.source_id) { say(`  ${id}: no jobber link, skipped`); continue; }

  const body = JSON.stringify({
    data: { webHookEvent: {
      topic: 'PROPERTY_DESTROY', appId: 'replay', accountId: 'replay',
      itemId: link.source_id, occurredAt: new Date().toISOString(),
    } },
  });
  const sig = createHmac('sha256', secretRow.client_secret).update(body).digest('base64');
  const r = await fetch(`${U}/functions/v1/webhook-jobber`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-jobber-hmac-sha256': sig, 'x-sync-wait': '1' },
    body,
  });
  say(`  property ${id}: HTTP ${r.status}  ${(await r.text()).slice(0, 120)}`);
}

say('\nAFTER');
const results = [];
for (const id of TARGETS) {
  const { data: p } = await db.from('properties').select('id,deleted_at').eq('id', id).maybeSingle();
  const { data: jobs } = await db.from('jobs').select('id,job_status').eq('property_id', id);
  results.push({ id, present: !!p, retired: !!p?.deleted_at, jobs: jobs?.length ?? 0 });
  say(`  property ${id}: present=${!!p}  deleted_at=${p?.deleted_at ?? 'NULL'}  jobs still linked=${jobs?.length ?? 0}`);
}

// CONTROL: a live property must be untouched by all of this.
const { data: live } = await db.from('properties').select('id,deleted_at').eq('id', 1091).maybeSingle();
say(`\n  CONTROL property 1091 (still live in Jobber): deleted_at=${live?.deleted_at ?? 'NULL'}`);

const checks = [
  ['1090 was RETIRED, not deleted (row still present)', results[0].present && results[0].retired],
  ['1092 was RETIRED, not deleted (row still present)', results[1].present && results[1].retired],
  ['job history survived on 1090 (FK intact, nothing cascaded away)', results[0].jobs > 0],
  ['CONTROL: live property 1091 untouched', !!live && live.deleted_at === null],
];
say('');
for (const [n, ok] of checks) say((ok ? 'PASS' : 'FAIL').padEnd(5), n);
say(`\n${checks.filter(c => c[1]).length}/${checks.length} passed`);
process.exit(checks.every(c => c[1]) ? 0 : 1);
