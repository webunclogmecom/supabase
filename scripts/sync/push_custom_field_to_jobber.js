#!/usr/bin/env node
/**
 * OUTBOUND push of a value we hold into a Jobber custom field. DRY RUN BY DEFAULT.
 *
 *   node scripts/sync/push_custom_field_to_jobber.js --field=gt --properties=10,115
 *   node scripts/sync/push_custom_field_to_jobber.js --field=gt --properties=10,115 --apply
 *   node scripts/sync/push_custom_field_to_jobber.js --field=gt --only-if-jobber-empty
 *   (--all-jobber-zero is kept as an alias: 0 is only how a NUMERIC field spells empty)
 *
 * Fred, 2026-09-02: "push those 5 capacities to jobber. We need to have a two way with jobber
 * remember, so if jobber have a custom field which we also manage, we need that to be two way."
 * This is the missing half. Every custom field was inbound only until now, which is why 85
 * properties hold a grease trap capacity that Jobber has never heard of.
 *
 * ============================================================================
 * THE ORDER OF OPERATIONS IS THE ENTIRE SAFETY ARGUMENT. DO NOT REORDER IT.
 * ============================================================================
 * PUSH -> READ BACK -> then RECORD THE SHADOW. Each leg is load-bearing:
 *
 *  - Push WITHOUT recording the shadow and the row FREEZES on the very next poll.
 *    fn_shadow_decision would see the source move (0 -> 403) and our side move
 *    (our_seen -> 403) in the same comparison, and both-moved is CONFLICT by definition.
 *    The push would look successful while quietly arming a freeze.
 *
 *  - Record the shadow BEFORE a push that then fails and it is worse than a freeze: the
 *    shadow would claim Jobber holds 403 while Jobber still holds 0, so the next poll reads
 *    the true 0 as a fresh Jobber-side edit and ADOPTS it over a real capacity. That is
 *    silent data loss in the very column this script exists to propagate.
 *
 *  - Trusting the mutation's own echo instead of a re-read is the third way to get this
 *    wrong, and this estate has a documented case of a write path reporting success against
 *    a reply it never really received. The read-back is a SEPARATE request; if it disagrees
 *    the shadow is NOT touched and the run reports the failure.
 *
 * ============================================================================
 * WHAT IT REFUSES, AND WHY EACH REFUSAL EXISTS
 * ============================================================================
 *  - conflict_at is set        a human already owns this row; a push would bury the question
 *  - live Jobber != shadow     the SOURCE moved since we last looked, so this is a conflict to
 *                              be resolved, not a value to overwrite. Re-poll first.
 *  - our value is NULL         pushing null CLEARS the Jobber field. Needs --allow-clear:
 *                              "we have nothing" is not a reason to erase what they have.
 *  - config readOnly/archived  the edit cannot land; say so rather than write and hope
 *  - no shadow row             nothing to re-baseline, so the freeze guard above cannot be
 *                              honoured. Let the poll SEED it first.
 *  - property soft-deleted     it is gone upstream; three such rows already show as drift
 *  - billing property row      those carry the CLIENT gid with a _billing suffix, so a
 *                              Property gid never matches one. See Supabase/CLAUDE.md.
 *
 * A Jobber NUMERIC custom field reports an empty value as 0, not null. So "Jobber has 0" and
 * "nobody ever filled it in" are the SAME state, exactly as an absent day means both Closed and
 * never-recorded in the access schedule. That is why --only-if-jobber-empty is a deliberately
 * narrower selector than "everything that differs": overwriting an empty field destroys no
 * information, while overwriting Jobber's 2500 with our 1500 could destroy a number somebody
 * typed on purpose.
 *
 * EMPTY IS SPELLED DIFFERENTLY PER TYPE, and getting that wrong is silent. A TEXT field spells
 * empty as null or '', never 0. The first version of this flag tested the numeric spelling only,
 * so pointed at the lock box it marked EVERY row "Jobber holds a real value" and skipped the whole
 * estate - which prints as "nothing to push", indistinguishable from a genuinely clean estate.
 */
const fs = require('fs'), path = require('path');

const APPLY = process.argv.includes('--apply');
const ALLOW_CLEAR = process.argv.includes('--allow-clear');
// "Jobber is empty here" is the safe-to-push selector: overwriting an empty field destroys no
// information. Its SPELLING differs by type, and that is not cosmetic - a Jobber NUMERIC field
// reports empty as 0, a TEXT field as null or ''. The original flag name only described the
// numeric spelling, and used on the text field it skipped EVERY row (null !== 0), which reads as
// "nothing to push" rather than as a broken selector. --only-if-jobber-empty is the type-neutral
// name; the old one is kept as an alias so existing notes and commands still work.
const ONLY_EMPTY = process.argv.includes('--all-jobber-zero') || process.argv.includes('--only-if-jobber-empty');
const arg = (n) => (process.argv.find(a => a.startsWith('--' + n + '=')) || '').split('=').slice(1).join('=');

// Type is not a detail here. fn_shadow_decision compares jsonb by IDENTITY, so a numeric field
// recorded as a jsonb string makes "403" differ from 403 and every later poll reports a change
// that never happened. Measured 2026-09-02: 3061111 stores `number`, 3061112 stores `string`.
const FIELDS = {
  gt: {
    label: 'Grease Trap size',
    gid: 'gid://Jobber/CustomFieldConfigurationNumeric/3061111',
    column: 'grease_trap_size_gallons',
    fragment: '... on CustomFieldNumeric { label valueNumeric }',
    read: (n) => (n && n.valueNumeric != null ? Number(n.valueNumeric) : null),
    input: (v) => ({ valueNumeric: Number(v) }),
    clearInput: () => ({ valueNumeric: 0 }),
    lit: (v) => (v == null ? "'null'::jsonb" : 'to_jsonb(' + Number(v) + ')'),
    emptyIsZero: true,
  },
  lockbox: {
    label: 'Lock Box/Key',
    gid: 'gid://Jobber/CustomFieldConfigurationText/3061112',
    column: 'lock_box_key',
    fragment: '... on CustomFieldText { label valueText }',
    read: (n) => (n && n.valueText != null && n.valueText !== '' ? String(n.valueText) : null),
    input: (v) => ({ valueText: String(v) }),
    clearInput: () => ({ valueText: '' }),
    lit: (v) => (v == null ? "'null'::jsonb" : "to_jsonb('" + String(v).replace(/'/g, "''") + "'::text)"),
    emptyIsZero: false,
  },
};
const F = FIELDS[arg('field') || 'gt'];
if (!F) throw new Error('--field must be one of: ' + Object.keys(FIELDS).join(', '));

const repoRoot = path.resolve(__dirname, '..', '..');
const env = Object.fromEntries(
  fs.readFileSync(path.join(repoRoot, '.env'), 'utf8').split(/\r?\n/).filter(l => l.includes('='))
    .map(l => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]));

async function sql(query) {
  const r = await fetch('https://api.supabase.com/v1/projects/' + env.SUPABASE_PROJECT_ID + '/database/query',
    { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'Content-Type': 'application/json' },
      body: JSON.stringify({ query }) });
  const t = await r.text(); let j; try { j = JSON.parse(t); } catch { throw new Error('non-JSON: ' + t.slice(0, 200)); }
  if (j && j.message) throw new Error('SQL failed: ' + j.message);
  return j;
}

// The WRITE token. ./jobber-token.sh is read-only and cannot mutate.
async function writeToken() {
  const row = (await sql("select access_token, refresh_token, client_id, client_secret, expires_at::text e" +
    " from public.webhook_tokens where source_system='jobber_write'"))[0];
  if (!row) throw new Error('no jobber_write token row');
  if (new Date(row.e).getTime() > Date.now() + 120000) return row.access_token;
  const body = 'grant_type=refresh_token&refresh_token=' + encodeURIComponent(row.refresh_token) +
    '&client_id=' + encodeURIComponent(row.client_id) + '&client_secret=' + encodeURIComponent(row.client_secret);
  const tr = await fetch('https://api.getjobber.com/api/oauth/token',
    { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body });
  const t = await tr.json();
  const exp = JSON.parse(Buffer.from(t.access_token.split('.')[1], 'base64').toString()).exp * 1000;
  await sql("update public.webhook_tokens set access_token='" + t.access_token + "', refresh_token='" +
    (t.refresh_token || row.refresh_token) + "', expires_at='" + new Date(exp).toISOString() +
    "', updated_at=now() where source_system='jobber_write'");
  return t.access_token;
}

async function gql(token, query, variables) {
  const r = await fetch('https://api.getjobber.com/api/graphql', { method: 'POST',
    headers: { Authorization: 'Bearer ' + token, 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16', 'Content-Type': 'application/json' },
    body: JSON.stringify({ query, variables }) });
  // Jobber sheds load with an HTML waiting room at HTTP 200: the status lies, the content-type
  // does not. And a well-formed reply with no `data` key is a throttle, never "the field is empty".
  const ctype = r.headers.get('content-type') || '';
  if (!ctype.includes('json')) throw new Error('Jobber returned ' + ctype + ' at HTTP ' + r.status + ' (waiting room?)');
  const j = await r.json();
  if (!('data' in j)) throw new Error('Jobber replied with no data key: ' + JSON.stringify(j).slice(0, 300));
  if (j.errors && j.errors.length) throw new Error('Jobber errors: ' + JSON.stringify(j.errors).slice(0, 400));
  return j.data;
}

const readQ = 'query($id:EncodedId!){ property(id:$id){ id customFields { __typename ' + F.fragment + ' } } }';
const editM = 'mutation($id:EncodedId!, $input:PropertyEditInput!){ propertyEdit(propertyId:$id, input:$input){' +
  ' property { id customFields { __typename ' + F.fragment + ' } } userErrors { message path } } }';

const cfgId = Buffer.from(F.gid).toString('base64');
const readField = (prop) => F.read((prop.customFields || []).find(c => c.label === F.label));

(async () => {
  const ids = (arg('properties') || '').split(',').map(s => s.trim()).filter(Boolean).map(Number);
  if (!ids.length && !ONLY_EMPTY) throw new Error('pass --properties=1,2,3 or --only-if-jobber-empty');

  // When no explicit list is given, consider only rows where we hold something Jobber does not
  // already match. The per-row guards below still apply to every one of them.
  const where = ids.length
    ? 'p.id in (' + ids.join(',') + ')'
    : 'p.deleted_at is null and p.' + F.column + ' is not null'
      + ' and to_jsonb(p.' + F.column + ') is distinct from s.source_value';

  const rows = await sql(
    'select p.id, c.client_code, c.name, p.' + F.column + ' as ours, p.deleted_at, p.is_billing,'
    + " l.source_id, s.source_value #>> '{}' as shadow_source, jsonb_typeof(s.source_value) as shadow_type,"
    + ' (s.conflict_at is not null) as frozen, (s.entity_id is not null) as has_shadow'
    + ' from public.properties p'
    + ' join public.clients c on c.id = p.client_id'
    + " left join public.entity_source_links l"
    + "   on l.entity_type='property' and l.source_system='jobber' and l.entity_id = p.id"
    + ' left join sync.source_field_shadow s'
    + "   on s.entity_id = p.id and s.field_key = '" + F.gid + "'"
    + ' where ' + where + ' order by p.id');

  const token = await writeToken();

  // readOnly would make every edit below impossible, and is worth knowing before the first write.
  const cfgs = await gql(token,
    'query { customFieldConfigurations(first:50){ nodes { __typename'
    + ' ... on CustomFieldConfigurationNumeric { id name readOnly archived }'
    + ' ... on CustomFieldConfigurationText { id name readOnly archived } } } }');
  const cfg = (cfgs.customFieldConfigurations.nodes || []).find(n => n.id === cfgId);
  if (!cfg) throw new Error('custom field configuration not found in Jobber: ' + F.gid);
  if (cfg.readOnly) throw new Error('config "' + cfg.name + '" is readOnly - cannot push');
  if (cfg.archived) throw new Error('config "' + cfg.name + '" is archived - cannot push');

  // Jobber's numeric empty is 0 while our absent is null. Treat them as one state, or every
  // never-filled field reads as "the source moved" and nothing is ever pushable.
  const norm = (v) => (F.emptyIsZero && (v === 0 || v === null)) ? 0 : v;
  // Type-aware "Jobber has nothing here". A NUMERIC field spells empty as 0; a TEXT field spells
  // it as null or ''. Testing the numeric spelling against a text field marks every empty row as
  // "Jobber holds a real value" and skips the whole estate.
  const jobberEmpty = (v) => F.emptyIsZero ? (v === 0 || v === null || v === undefined)
                                           : (v === null || v === undefined || v === '');

  const plan = [];
  for (const r of rows) {
    const refuse = (why) => plan.push({ id: r.id, client_code: r.client_code, action: 'REFUSE', why });
    if (r.deleted_at) { refuse('property is soft-deleted'); continue; }
    if (r.is_billing) { refuse('billing row, carries a Client gid not a Property gid'); continue; }
    if (!r.source_id) { refuse('no jobber link'); continue; }
    if (!r.has_shadow) { refuse('no shadow row - let the poll SEED it first'); continue; }
    if (r.frozen) { refuse('conflict_at is set - a human owns this row'); continue; }
    if (r.ours == null && !ALLOW_CLEAR) { refuse('our value is NULL - would clear Jobber, needs --allow-clear'); continue; }

    const live = readField((await gql(token, readQ, { id: r.source_id })).property);
    const shadow = r.shadow_source === null ? null
      : (r.shadow_type === 'number' ? Number(r.shadow_source) : r.shadow_source);
    if (norm(live) !== norm(shadow)) {
      refuse('live Jobber (' + JSON.stringify(live) + ') differs from what we last saw ('
        + JSON.stringify(shadow) + ') - the SOURCE moved, resolve as a conflict, do not overwrite');
      continue;
    }
    const ours = r.ours == null ? null : (F.emptyIsZero ? Number(r.ours) : String(r.ours));
    const row = { id: r.id, client_code: r.client_code, source_id: r.source_id, live, ours };
    if (norm(ours) === norm(live)) { plan.push({ ...row, action: 'SKIP', why: 'already equal in Jobber' }); continue; }
    if (ONLY_EMPTY && !jobberEmpty(live)) {
      plan.push({ ...row, action: 'SKIP',
        why: 'Jobber holds a real value (' + JSON.stringify(live) + ') - needs a human, not an overwrite' });
      continue;
    }
    plan.push({ ...row, action: 'PUSH' });
  }

  const push = plan.filter(p => p.action === 'PUSH');
  console.log(JSON.stringify({
    mode: APPLY ? 'APPLY' : 'DRY RUN',
    field: F.label, config: cfg.name, readOnly: cfg.readOnly,
    considered: plan.length,
    to_push: push.length,
    refused: plan.filter(p => p.action === 'REFUSE').length,
    skipped: plan.filter(p => p.action === 'SKIP').length,
    refusals: plan.filter(p => p.action === 'REFUSE').map(p => ({ property: p.id, client: p.client_code, why: p.why })),
    skips: plan.filter(p => p.action === 'SKIP').map(p => ({ property: p.id, client: p.client_code, why: p.why })),
    plan: push.map(p => ({ property: p.id, client: p.client_code, jobber_now: p.live, we_will_write: p.ours })),
  }, null, 1));

  if (!APPLY) { console.log('\nDry run. Nothing written to Jobber. Re-run with --apply.'); return; }
  if (!push.length) { console.log('\nNothing to push.'); return; }

  const done = [], failed = [];
  for (const p of push) {
    try {
      const input = { customFields: [Object.assign({ customFieldConfigurationId: cfgId },
        p.ours == null ? F.clearInput() : F.input(p.ours))] };
      const res = await gql(token, editM, { id: p.source_id, input });
      const ue = res.propertyEdit && res.propertyEdit.userErrors;
      if (ue && ue.length) throw new Error('userErrors ' + JSON.stringify(ue));

      // SEPARATE request. The mutation's own echo is not evidence.
      const back = readField((await gql(token, readQ, { id: p.source_id })).property);
      const want = p.ours == null ? (F.emptyIsZero ? 0 : null) : p.ours;
      const ok = F.emptyIsZero ? Number(back) === Number(want) : String(back) === String(want);
      if (!ok) throw new Error('READ-BACK MISMATCH: Jobber holds ' + JSON.stringify(back)
        + ', expected ' + JSON.stringify(want));

      // Only now. Re-baseline BOTH sides to the value that is now true in both systems, so the
      // next poll sees an unchanged source and returns IN_SYNC instead of freezing the row.
      await sql("select sync.fn_record_shadow('property', " + p.id + ", 'jobber', '" + F.gid + "', '"
        + F.label.replace(/'/g, "''") + "', " + F.lit(back) + ', ' + F.lit(back) + ', ' + F.lit(back) + ')');
      done.push({ property: p.id, client: p.client_code, wrote: want, read_back: back });
    } catch (e) {
      failed.push({ property: p.id, client: p.client_code, error: e.message });
    }
  }
  console.log('\n' + JSON.stringify({ pushed: done.length, failed: failed.length, done, failed }, null, 1));
  if (failed.length) process.exit(1);
})().catch(e => { console.error('FAILED:', e.message); process.exit(1); });
