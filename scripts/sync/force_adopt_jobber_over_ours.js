#!/usr/bin/env node
/**
 * FORCE-ADOPT Jobber's value over ours, for rows where BOTH sides hold a real value.
 * DRY RUN BY DEFAULT. Pass --apply to write. NOT WIRED TO CRON, and it must never be.
 *
 * Fred, 2026-09-02, on the twelve properties where Jobber holds a different real number:
 * "2. Adopt jobbers data."
 *
 * ============================================================================
 * WHY THIS IS A SEPARATE SCRIPT AND NOT A FLAG ON adopt_jobber_custom_fields.js
 * ============================================================================
 * That script is the honest sync: it asks sync.fn_shadow_decision, which fires only when the
 * SOURCE moved. On these twelve rows the source did NOT move - Jobber holds exactly what we last
 * saw. OUR side moved, because staff typed a capacity in the Client App. The correct verdict there
 * is IGNORE, and the correct verdict for a Jobber-side edit arriving later is CONFLICT.
 *
 * So this is not adoption. It is a deliberate OVERRIDE that discards a value a person entered,
 * and it is named to make that impossible to mistake. Putting it behind a flag on the real sync
 * would be putting a data-losing branch inside the path that runs unattended.
 *
 * ============================================================================
 * WHAT IT DESTROYS, STATED PLAINLY
 * ============================================================================
 * Every one of these rows carries a real `client-app` edit by a named person - Serena,
 * contact@unclogme.com, Fred - several from the morning of 2026-09-02. This script overwrites
 * those with Jobber's number. That is what was asked for, and it is not recoverable from the
 * column afterwards, so:
 *   - it writes a BACKUP JSON to backups/ BEFORE the first write, including each row's audit
 *     history, and REFUSES to proceed if the backup cannot be written;
 *   - backups/ is gitignored, which is deliberate: these rows name clients and both repos are PUBLIC.
 *
 * ============================================================================
 * IT ALSO RE-BASELINES THE SHADOW, AND THAT IS NOT OPTIONAL
 * ============================================================================
 * After the override both systems agree, so the shadow must say so: source_value and our_value both
 * become Jobber's value. Skip that and the row stays armed - fn_shadow_decision would still see our
 * side as having moved, and the next Jobber edit would land as CONFLICT and freeze a row that is in
 * fact perfectly in sync.
 *
 * jsonb identity matters: 3061111 stores `number`, 3061112 stores `string`. Writing the numeric
 * field as a jsonb string makes "250" differ from 250 and every later poll reports a phantom change.
 */
const fs = require('fs'), path = require('path');

const APPLY = process.argv.includes('--apply');
const arg = (n) => (process.argv.find(a => a.startsWith('--' + n + '=')) || '').split('=').slice(1).join('=');

const FIELDS = {
  gt: {
    label: 'Grease Trap size',
    gid: 'gid://Jobber/CustomFieldConfigurationNumeric/3061111',
    column: 'grease_trap_size_gallons',
    fragment: '... on CustomFieldNumeric { label valueNumeric }',
    read: (n) => (n && n.valueNumeric != null ? Number(n.valueNumeric) : null),
    lit: (v) => (v == null ? 'null' : String(Number(v))),
    jlit: (v) => (v == null ? "'null'::jsonb" : 'to_jsonb(' + Number(v) + ')'),
    emptyIsZero: true,
  },
  lockbox: {
    label: 'Lock Box/Key',
    gid: 'gid://Jobber/CustomFieldConfigurationText/3061112',
    column: 'lock_box_key',
    fragment: '... on CustomFieldText { label valueText }',
    read: (n) => (n && n.valueText != null && n.valueText !== '' ? String(n.valueText) : null),
    lit: (v) => (v == null ? 'null' : "'" + String(v).replace(/'/g, "''") + "'"),
    jlit: (v) => (v == null ? "'null'::jsonb" : "to_jsonb('" + String(v).replace(/'/g, "''") + "'::text)"),
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

async function jobberToken() {
  return require('child_process').execSync('bash ./jobber-token.sh',
    { cwd: path.resolve(repoRoot, '..', 'Slack') }).toString().trim();
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

const readQ = 'query($id:EncodedId!){ property(id:$id){ id customFields { __typename ' + F.fragment + ' } } }';

// F.read takes the matching custom-field NODE, not the property. Passing the property makes it
// read `undefined` and return null for every row, which presents as a confident "0 to override"
// rather than an error. That is exactly what it did on the first run.
const readField = (prop) => F.read((prop.customFields || []).find(c => c.label === F.label));

(async () => {
  const ids = (arg('properties') || '').split(',').map(s => s.trim()).filter(Boolean).map(Number);
  const where = ids.length ? 'p.id in (' + ids.join(',') + ')' : 'true';

  const rows = await sql(
    'select p.id, c.client_code, c.name, p.' + F.column + ' as ours,'
    + " s.source_value #>> '{}' as shadow_source, s.our_value #>> '{}' as shadow_our,"
    + ' (s.conflict_at is not null) as frozen, l.source_id'
    + ' from public.properties p'
    + ' join public.clients c on c.id = p.client_id'
    + " left join public.entity_source_links l"
    + "   on l.entity_type='property' and l.source_system='jobber' and l.entity_id = p.id"
    + ' left join sync.source_field_shadow s'
    + "   on s.entity_id = p.id and s.field_key = '" + F.gid + "'"
    + ' where ' + where + ' and p.deleted_at is null and p.is_billing = false'
    + '   and l.source_id is not null and s.entity_id is not null'
    + ' order by p.id');

  const token = await jobberToken();

  // Only rows where BOTH sides hold a real value and they disagree. A Jobber 0 is its EMPTY, not a
  // decision, so it can never win here - that direction is push_custom_field_to_jobber.js's job.
  const plan = [];
  let sawRealJobberValue = 0;
  for (const r of rows) {
    const live = readField((await gql(token, readQ, { id: r.source_id })).property);
    if (live != null && (!F.emptyIsZero || Number(live) !== 0)) sawRealJobberValue++;
    const liveReal = F.emptyIsZero ? (live != null && Number(live) !== 0) : (live != null && live !== '');
    const oursReal = r.ours != null && String(r.ours) !== '';
    if (!liveReal || !oursReal) continue;
    if (String(live) === String(r.ours)) continue;
    plan.push({ ...r, live });
  }

  // POSITIVE CONTROL. A zero-length plan is a legitimate answer, but only if the reader can see
  // ANY real Jobber value at all. Across hundreds of linked properties, reading a real value from
  // none of them means the extractor is broken, not that the estate is in sync - and a broken
  // extractor reports "nothing to do", which is indistinguishable from success.
  if (rows.length > 20 && sawRealJobberValue === 0) {
    throw new Error('POSITIVE CONTROL FAILED: read ' + rows.length + ' linked properties and found a real '
      + F.label + ' on none of them. The custom-field reader is broken; refusing to report a plan.');
  }

  console.log(JSON.stringify({
    mode: APPLY ? 'APPLY' : 'DRY RUN', field: F.label, examined: rows.length,
    jobber_rows_with_a_real_value: sawRealJobberValue, to_override: plan.length,
    plan: plan.map(p => ({ property: p.id, client: p.client_code, ours_now: p.ours,
      jobber_wins_with: p.live, frozen: p.frozen })),
  }, null, 1));

  if (!plan.length) { console.log('\nNothing to override.'); return; }
  if (!APPLY) { console.log('\nDry run. Nothing written. Re-run with --apply.'); return; }

  // BACKUP FIRST, INCLUDING AUDIT HISTORY. Refuse to write anything if this fails.
  // audit.logs columns are: record_pk, app_source, changed_at, changed_by, db_role, jwt_claims,
  // request_context, txid. There is no changed_by_email - the email lives inside jwt_claims.
  const hist = await sql(
    'select record_pk, app_source, changed_at::text,'
    + " coalesce(jwt_claims->>'email', changed_by::text, db_role) as changed_by_who,"
    + " old_row->>'" + F.column + "' as old_val, new_row->>'" + F.column + "' as new_val"
    + " from audit.logs where table_name='properties'"
    + '  and record_pk in (' + plan.map(p => "'{\"id\":" + p.id + "}'::jsonb").join(',') + ')'
    + "  and (old_row->>'" + F.column + "') is distinct from (new_row->>'" + F.column + "')"
    + ' order by changed_at desc limit 500');

  const backupDir = path.join(repoRoot, '..', 'backups');
  const stamp = (await sql("select to_char(now() at time zone 'America/New_York','YYYY-MM-DD_HH24MI') s"))[0].s;
  const backupPath = path.join(backupDir, stamp + '_force_adopt_jobber_' + F.column + '.json');
  fs.mkdirSync(backupDir, { recursive: true });
  fs.writeFileSync(backupPath, JSON.stringify({
    what: 'Values in public.properties.' + F.column + ' immediately BEFORE Jobber was forced over them',
    why: 'Fred 2026-09-02: "2. Adopt jobbers data." on the rows where both sides held a real value',
    field: F.label, field_key: F.gid,
    rows: plan.map(p => ({ property_id: p.id, client_code: p.client_code, client_name: p.name,
      our_value_before: p.ours, jobber_value_applied: p.live,
      shadow_source_before: p.shadow_source, shadow_our_before: p.shadow_our })),
    audit_history: hist,
  }, null, 2));
  const check = JSON.parse(fs.readFileSync(backupPath, 'utf8'));
  if (!check.rows || check.rows.length !== plan.length) throw new Error('backup did not read back intact - refusing to write');
  console.log('\nBACKUP WRITTEN: ' + backupPath + ' (' + check.rows.length + ' rows, ' + hist.length + ' audit entries)');

  const done = [], failed = [];
  for (const p of plan) {
    try {
      await sql(
        "do $ov$ begin"
        + " perform set_config('request.headers','{\"x-app-source\":\"force-adopt-jobber\"}',true);"
        + ' update public.properties set ' + F.column + ' = ' + F.lit(p.live) + ' where id = ' + p.id + ';'
        // Both sides now agree, so the shadow must say so or the row stays armed to freeze.
        + " perform sync.fn_record_shadow('property', " + p.id + ", 'jobber', '" + F.gid + "', '"
        + F.label.replace(/'/g, "''") + "', " + F.jlit(p.live) + ', ' + F.jlit(p.live) + ', ' + F.jlit(p.live) + ');'
        + ' end $ov$;');
      const back = (await sql('select ' + F.column + ' as v from public.properties where id = ' + p.id))[0].v;
      if (String(back) !== String(p.live)) throw new Error('read-back is ' + JSON.stringify(back) + ', expected ' + JSON.stringify(p.live));
      done.push({ property: p.id, client: p.client_code, was: p.ours, now: back });
    } catch (e) {
      failed.push({ property: p.id, client: p.client_code, error: e.message });
    }
  }
  console.log('\n' + JSON.stringify({ overridden: done.length, failed: failed.length, done, failed }, null, 1));
  if (failed.length) process.exit(1);
})().catch(e => { console.error('FAILED:', e.message); process.exit(1); });
