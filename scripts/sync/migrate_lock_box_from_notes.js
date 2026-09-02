#!/usr/bin/env node
/**
 * Move a lock box / gate code that is sitting in free text (access_notes or notes) into the
 * dedicated public.properties.lock_box_key column, then push it to Jobber so both sides agree.
 * DRY RUN BY DEFAULT. Pass --apply to write.
 *
 * WHY THESE ROWS EXIST. The property card's "Lock box / key" row was a HARDCODED em dash from the
 * day it shipped until 2026-09-02 - it never read the column at all. With the field invisible,
 * people put codes where they could see them, which was the notes. So this is not a data-entry
 * mistake to tidy up; it is the predictable consequence of an unwired field, and the fix for the
 * cause shipped first.
 *
 * WHAT IT DOES NOT DO: it does not delete or edit the note it read the code from. Removing client
 * free text is a destructive act nobody asked for, and the note often carries more than the code
 * ("CODE BOX: 6969" is the whole note, but "gate code 1234, ring the bell twice" is not). The
 * duplication is left visible on the card, where a human can decide.
 *
 * THE ORDER MATTERS, and it is not the obvious one:
 *   1. read Jobber's CURRENT value for the field
 *   2. SEED the shadow with (source = what Jobber holds now, our = what we hold now)
 *   3. write our column
 *   4. push to Jobber via push_custom_field_to_jobber.js semantics (push -> read back -> re-baseline)
 * Step 2 cannot be skipped and cannot be folded into step 3. push_custom_field_to_jobber.js
 * REFUSES a property with no shadow row, on purpose: with no baseline it cannot tell "our side
 * moved" from "we have never looked", so it cannot honour the freeze guard. Seeding first gives it
 * the baseline it needs. Writing our column BEFORE seeding would record our new value as the
 * baseline and lose the fact that the column was empty.
 */
const fs = require('fs'), path = require('path');

const APPLY = process.argv.includes('--apply');
const FIELD_KEY = 'gid://Jobber/CustomFieldConfigurationText/3061112';
const FIELD_LABEL = 'Lock Box/Key';
const CFG_ID = Buffer.from(FIELD_KEY).toString('base64');

// Deliberately narrow. A code is extracted ONLY when the note is essentially just the code, so a
// note that also carries instructions is left for a human rather than half-parsed.
const PATTERNS = [
  /^\s*(?:lock\s?box|lockbox|code\s?box|box\s?code|gate\s?code|key\s?pad|keypad|combo|combination)\s*(?:code)?\s*[:#-]?\s*([A-Za-z0-9-]{2,20})\s*$/i,
];

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

async function writeToken() {
  const row = (await sql("select access_token, refresh_token, client_id, client_secret, expires_at::text e"
    + " from public.webhook_tokens where source_system='jobber_write'"))[0];
  if (!row) throw new Error('no jobber_write token row');
  if (new Date(row.e).getTime() > Date.now() + 120000) return row.access_token;
  const body = 'grant_type=refresh_token&refresh_token=' + encodeURIComponent(row.refresh_token)
    + '&client_id=' + encodeURIComponent(row.client_id) + '&client_secret=' + encodeURIComponent(row.client_secret);
  const tr = await fetch('https://api.getjobber.com/api/oauth/token',
    { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body });
  const t = await tr.json();
  const exp = JSON.parse(Buffer.from(t.access_token.split('.')[1], 'base64').toString()).exp * 1000;
  await sql("update public.webhook_tokens set access_token='" + t.access_token + "', refresh_token='"
    + (t.refresh_token || row.refresh_token) + "', expires_at='" + new Date(exp).toISOString()
    + "', updated_at=now() where source_system='jobber_write'");
  return t.access_token;
}

async function gql(token, query, variables) {
  const r = await fetch('https://api.getjobber.com/api/graphql', { method: 'POST',
    headers: { Authorization: 'Bearer ' + token, 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16', 'Content-Type': 'application/json' },
    body: JSON.stringify({ query, variables }) });
  const ctype = r.headers.get('content-type') || '';
  if (!ctype.includes('json')) throw new Error('Jobber returned ' + ctype + ' at HTTP ' + r.status + ' (waiting room?)');
  const j = await r.json();
  if (!('data' in j)) throw new Error('Jobber replied with no data key: ' + JSON.stringify(j).slice(0, 300));
  if (j.errors && j.errors.length) throw new Error('Jobber errors: ' + JSON.stringify(j.errors).slice(0, 400));
  return j.data;
}

const FRAG = '... on CustomFieldText { label valueText }';
const readQ = 'query($id:EncodedId!){ property(id:$id){ id customFields { __typename ' + FRAG + ' } } }';
const editM = 'mutation($id:EncodedId!, $input:PropertyEditInput!){ propertyEdit(propertyId:$id, input:$input){'
  + ' property { id customFields { __typename ' + FRAG + ' } } userErrors { message path } } }';
const readField = (p) => {
  const n = (p.customFields || []).find(c => c.label === FIELD_LABEL);
  return n && n.valueText != null && n.valueText !== '' ? String(n.valueText) : null;
};
const jlit = (v) => (v == null ? "'null'::jsonb" : "to_jsonb('" + String(v).replace(/'/g, "''") + "'::text)");

(async () => {
  const rows = await sql(
    'select p.id, c.client_code, p.lock_box_key, p.access_notes, p.notes, l.source_id,'
    + ' (s.entity_id is not null) as has_shadow'
    + ' from public.properties p'
    + ' join public.clients c on c.id = p.client_id'
    + " left join public.entity_source_links l"
    + "   on l.entity_type='property' and l.source_system='jobber' and l.entity_id = p.id"
    + " left join sync.source_field_shadow s"
    + "   on s.entity_id = p.id and s.field_key = '" + FIELD_KEY + "'"
    + ' where p.deleted_at is null and p.is_billing = false and p.lock_box_key is null'
    + '   and coalesce(btrim(p.access_notes),' + "''" + ') <> ' + "''"
    + ' order by p.id');

  const plan = [];
  for (const r of rows) {
    let code = null;
    for (const re of PATTERNS) { const m = re.exec(r.access_notes || ''); if (m) { code = m[1]; break; } }
    if (!code) { plan.push({ ...r, action: 'SKIP', why: 'note is not just a code: ' + JSON.stringify((r.access_notes || '').slice(0, 60)) }); continue; }
    if (!r.source_id) { plan.push({ ...r, code, action: 'SKIP', why: 'no jobber link' }); continue; }
    plan.push({ ...r, code, action: 'MIGRATE' });
  }
  const go = plan.filter(p => p.action === 'MIGRATE');

  console.log(JSON.stringify({
    mode: APPLY ? 'APPLY' : 'DRY RUN',
    properties_with_an_access_note_and_no_lock_box: rows.length,
    to_migrate: go.length,
    plan: plan.map(p => ({ property: p.id, client: p.client_code, action: p.action,
      code: p.code || null, note: (p.access_notes || '').slice(0, 60), why: p.why })),
  }, null, 1));

  if (!APPLY) { console.log('\nDry run. Nothing written. Re-run with --apply.'); return; }
  if (!go.length) { console.log('\nNothing to migrate.'); return; }

  const token = await writeToken();
  const done = [], failed = [];
  for (const p of go) {
    try {
      // 1. what does Jobber hold right now
      const before = readField((await gql(token, readQ, { id: p.source_id })).property);
      if (before != null && before !== p.code) {
        throw new Error('Jobber already holds ' + JSON.stringify(before) + ' - not overwriting, a human should reconcile');
      }
      // 2. SEED the shadow at the CURRENT state, before our column moves
      if (!p.has_shadow) {
        await sql("select sync.fn_record_shadow('property', " + p.id + ", 'jobber', '" + FIELD_KEY + "', '"
          + FIELD_LABEL + "', " + jlit(before) + ', ' + jlit(null) + ", 'null'::jsonb)");
      }
      // 3. our column
      await sql("do $mg$ begin"
        + " perform set_config('request.headers','{\"x-app-source\":\"lock-box-note-migration\"}',true);"
        + " update public.properties set lock_box_key = '" + p.code.replace(/'/g, "''") + "' where id = " + p.id + ';'
        + ' end $mg$;');
      // 4. push, then read back, then re-baseline - never a different order
      const res = await gql(token, editM, { id: p.source_id,
        input: { customFields: [{ customFieldConfigurationId: CFG_ID, valueText: p.code }] } });
      const ue = res.propertyEdit && res.propertyEdit.userErrors;
      if (ue && ue.length) throw new Error('userErrors ' + JSON.stringify(ue));
      const back = readField((await gql(token, readQ, { id: p.source_id })).property);
      if (String(back) !== String(p.code)) throw new Error('READ-BACK MISMATCH: Jobber holds ' + JSON.stringify(back));
      await sql("select sync.fn_record_shadow('property', " + p.id + ", 'jobber', '" + FIELD_KEY + "', '"
        + FIELD_LABEL + "', " + jlit(back) + ', ' + jlit(back) + ', ' + jlit(back) + ')');
      done.push({ property: p.id, client: p.client_code, code: p.code, jobber_before: before, jobber_after: back });
    } catch (e) {
      failed.push({ property: p.id, client: p.client_code, error: e.message });
    }
  }
  console.log('\n' + JSON.stringify({ migrated: done.length, failed: failed.length, done, failed }, null, 1));
  if (failed.length) process.exit(1);
})().catch(e => { console.error('FAILED:', e.message); process.exit(1); });
