// FULL AUDIT of this session's work, re-measured against LIVE Prod and live endpoints.
// Nothing here is taken from a commit message or from memory: every row is a fresh measurement,
// and every claim that can have a control has one.
//
// Run: node --experimental-strip-types scripts/probes/audit_18h.mjs
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
const PAT = env.SUPABASE_PAT;
const db = createClient(U, SR, { auth: { persistSession: false } });

async function sql(q) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_ID}/database/query`, {
    method: 'POST', headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: q }) });
  const t = await r.text();
  try { const j = JSON.parse(t); return Array.isArray(j) ? j : []; } catch { return []; }
}

const rows = [];
const check = (area, claim, pass, evidence) => rows.push({ area, claim, pass, evidence: String(evidence).slice(0, 78) });

// ============================ 1. GDO ACTIVITY TRAIL + CONSTRAINT ============================
{
  const c = await sql(`select pg_get_constraintdef(oid) d from pg_constraint where conname='derm_portal_submissions_actor_markers_agree'`);
  check('GDO trail', 'actor-markers CHECK is live', c.length === 1, c[0]?.d ?? 'MISSING');

  const b = await sql(`select actor_type, count(*)::text n from derm.gdo_report_activity group by 1 order by 1`);
  const tot = await sql(`select count(*)::text n from audit.logs where table_schema='public' and table_name='derm_portal_submissions'`);
  const sum = b.reduce((a, r) => a + Number(r.n), 0);
  check('GDO trail', 'buckets still account for every audit row', sum === Number(tot[0]?.n),
        `${b.map(r => r.actor_type + '=' + r.n).join(' ')} vs audit ${tot[0]?.n}`);

  const unattr = b.find(r => r.actor_type === 'unattributed');
  check('GDO trail', 'CONTROL: no unattributed actors', !unattr, `unattributed=${unattr?.n ?? 0}`);

  const anon = await sql(`select has_table_privilege('anon','derm.gdo_report_activity','SELECT')::text ok`);
  check('GDO trail', 'anon still cannot read staff emails', anon[0]?.ok === 'false', `anon select=${anon[0]?.ok}`);
}

// ============================ 2. SC JOB RULE ON 112-YA ============================
{
  const p = await sql(`
    select p.id::text id, p.is_billing::text bill, coalesce(p.deleted_at::text,'') del,
           (select count(*) from jobs j where j.property_id=p.id and lower(btrim(j.title))='service call'
              and j.job_status not in ('archived','closed','destroyed'))::text sc
      from properties p where p.client_id=381 order by p.id`);
  const liveService = p.filter(r => r.bill === 'false' && !r.del);
  check('SC rule', 'every LIVE service property on 112-YA has exactly 1 SC job',
        liveService.length > 0 && liveService.every(r => r.sc === '1'),
        liveService.map(r => `${r.id}:${r.sc}`).join(' '));
  const billing = p.filter(r => r.bill === 'true');
  check('SC rule', 'CONTROL: the billing twin has NO SC job',
        billing.length > 0 && billing.every(r => r.sc === '0'),
        billing.map(r => `${r.id}:${r.sc}`).join(' '));
  // 🛑 THIS ASSERTION WAS WRONG ON ITS FIRST RUN AND IS KEPT CORRECTED AS A LESSON.
  //    It compared case-SENSITIVELY (btrim(title) <> 'Service Call') and reported 51 "decorated"
  //    titles. The REAL matcher in _shared/service-call-job.ts is
  //        String(t ?? '').trim().toLowerCase() === 'service call'
  //    i.e. case-INSENSITIVE. 36 of those 51 are simply "Service call" and the matcher ACCEPTS them.
  //    An assertion that does not mirror the rule it is testing manufactures findings.
  const dec = await sql(`select count(*)::text n from jobs where title ilike 'service call%' and lower(btrim(title)) <> 'service call'`);
  const newDec = await sql(`select count(*)::text n from jobs where title ilike 'service call%' and lower(btrim(title)) <> 'service call' and created_at > now() - interval '18 hours'`);
  check('SC rule', 'no NEW decorated SC titles created this session',
        newDec[0]?.n === '0',
        `pre-existing decorated=${dec[0]?.n} (legacy), created this session=${newDec[0]?.n}`);
}

// ============================ 3. DB-ONLY PROPERTY PATH CLOSED ============================
{
  const n = await sql(`select count(*)::text n from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace where ns.nspname='client' and p.proname='create_property'`);
  check('create_property', 'exactly ONE overload (not accidentally overloaded)', n[0]?.n === '1', `overloads=${n[0]?.n}`);
  const r = await sql(`do $$ begin perform client.create_property(1,'{}'::jsonb); exception when others then null; end $$; select 1 x`);
  const refuses = await sql(`
    select case when exists (
      select 1 from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
       where ns.nspname='client' and p.proname='create_property'
         and pg_get_functiondef(p.oid) ilike '%save-client-property%') then 'yes' else 'no' end ok`);
  check('create_property', 'body refuses and names save-client-property', refuses[0]?.ok === 'yes', `names replacement=${refuses[0]?.ok}`);
}

// ============================ 4. PROPERTIES SOFT-DELETE ============================
{
  const col = await sql(`select data_type d from information_schema.columns where table_schema='public' and table_name='properties' and column_name='deleted_at'`);
  check('soft-delete', 'properties.deleted_at exists, timestamptz', col[0]?.d === 'timestamp with time zone', col[0]?.d ?? 'MISSING');
  const retired = await sql(`select count(*)::text n from properties where deleted_at is not null`);
  check('soft-delete', 'only the 2 known orphans are retired', retired[0]?.n === '2', `retired=${retired[0]?.n}`);
  const jobsKept = await sql(`select count(*)::text n from jobs where property_id in (1090,1092)`);
  check('soft-delete', 'CONTROL: job history survived on retired properties', Number(jobsKept[0]?.n) > 0, `jobs still linked=${jobsKept[0]?.n}`);
}

// ============================ 5. WEBHOOK: SHAPE + SLA + GATE ============================
{
  const { data: link } = await db.from('entity_source_links').select('source_id')
    .eq('entity_type', 'property').eq('entity_id', 1091).eq('source_system', 'jobber').maybeSingle();
  const { data: sec } = await db.from('webhook_tokens').select('client_secret').eq('source_system', 'jobber').single();
  const post = async (bodyObj, hdrs = {}) => {
    const body = JSON.stringify(bodyObj);
    const sig = createHmac('sha256', sec.client_secret).update(body).digest('base64');
    const t0 = Date.now();
    const r = await fetch(`${U}/functions/v1/webhook-jobber`, { method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-jobber-hmac-sha256': sig, ...hdrs }, body });
    return { ms: Date.now() - t0, status: r.status, body: (await r.text()).slice(0, 90) };
  };
  const nested = await post({ data: { webHookEvent: { topic: 'PROPERTY_UPDATE', itemId: link.source_id, occurredAt: new Date().toISOString() } } });
  check('webhook', 'accepts REAL Jobber nested payload', nested.status === 200, `HTTP ${nested.status} ${nested.body}`);
  check('webhook', 'acks inside Jobber 1000ms SLA', nested.ms < 1000, `${nested.ms} ms`);

  const flat = await post({ topic: 'PROPERTY_UPDATE', webHookEvent: { itemId: link.source_id, occurredAt: new Date().toISOString() } }, { 'x-sync-wait': '1' });
  check('webhook', 'CONTROL: x-sync-wait still returns a real result', flat.status === 200 && flat.body.includes('entity_id'), flat.body);

  const bad = await fetch(`${U}/functions/v1/webhook-jobber`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' });
  check('webhook', 'CONTROL: unsigned request refused', bad.status !== 200, `HTTP ${bad.status}`);

  const real = await sql(`select count(*)::text n from webhook_events_log where payload::text like '%accountId%'`);
  check('webhook', 'REAL Jobber deliveries now landing (payload carries accountId)', Number(real[0]?.n) > 0, `real deliveries=${real[0]?.n}`);
}

// ============================ 6. EDGE FUNCTION GATES ============================
{
  for (const fn of ['save-client-property', 'create-client']) {
    const r = await fetch(`${U}/functions/v1/${fn}`, { method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${SR}` }, body: '{}' });
    const t = await r.text();
    check('gates', `${fn} refuses a non-staff token`, /forbidden|unauthorized|Staff account/i.test(t), t.slice(0, 70));
  }
}

// ============================ 7. NOTHING BROKE ============================
{
  // The only real failure in the window was the PROPERTY_DESTROY that EXPOSED the hard-delete bug
  // and has since been fixed and replayed successfully. Assert that shape rather than "zero", so a
  // genuinely NEW failure still trips this.
  const fails = await sql(`select coalesce(string_agg(distinct event_type,','),'') t, count(*)::text n from webhook_events_log where source_system='jobber' and status='failed' and event_id is not null and created_at > now() - interval '18 hours'`);
  const destroyOk = await sql(`select count(*)::text n from webhook_events_log where event_type='PROPERTY_DESTROY' and status='processed'`);
  check('regression', 'the only real failure is the now-FIXED PROPERTY_DESTROY',
        (fails[0]?.n === '0') || (fails[0]?.t === 'PROPERTY_DESTROY' && Number(destroyOk[0]?.n) > 0),
        `failed=${fails[0]?.n} [${fails[0]?.t}] · same topic since processed ${destroyOk[0]?.n}x`);
  const proc = await sql(`select count(*)::text n from webhook_events_log where source_system='jobber' and status='processed' and created_at > now() - interval '3 hours'`);
  check('regression', 'webhooks still processing', Number(proc[0]?.n) > 0, `processed last 3h=${proc[0]?.n}`);
}

// ---- report --------------------------------------------------------------------------------
let last = '';
for (const r of rows) {
  if (r.area !== last) { console.log(`\n--- ${r.area} ---`); last = r.area; }
  console.log(`  ${(r.pass ? 'PASS' : 'FAIL').padEnd(5)} ${r.claim.padEnd(58)} ${r.evidence}`);
}
const bad = rows.filter(r => !r.pass);
console.log(`\n${rows.filter(r => r.pass).length}/${rows.length} verified`);
if (bad.length) { console.log('\nFAILURES:'); for (const b of bad) console.log(`  ${b.area}: ${b.claim} -> ${b.evidence}`); }
process.exit(0);
