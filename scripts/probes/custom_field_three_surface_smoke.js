#!/usr/bin/env node
/**
 * THREE-SURFACE SMOKE TEST for the synced Jobber property custom fields. READ-ONLY.
 *
 *   node scripts/probes/custom_field_three_surface_smoke.js --field=lockbox
 *   node scripts/probes/custom_field_three_surface_smoke.js --field=gt
 *
 * Fred, 2026-09-02: "We need to smoke tests the props to make sure they work on jobber, and that
 * it also reflects in our clients app too."
 *
 * ============================================================================
 * WHY THREE SURFACES AND NOT TWO
 * ============================================================================
 * "Our side agrees with Jobber" is the obvious check and it is NOT sufficient, because the Client
 * App does not read our side. It reads the `client.properties` VIEW. Those can disagree, and they
 * HAVE: on 2026-09-02 `lock_box_key` was written to public.properties and exposed nowhere, so the
 * modal rendered an empty box over a stored 5713 and the two-surface check would have passed.
 * So each property is checked at all three:
 *
 *   1. public.properties.<column>     what we store
 *   2. client.properties.<column>     what the Client App can actually SELECT
 *   3. Jobber, swept live             what the field really holds upstream
 *
 * A row is OK only when all three agree. Anything else is reported with the surface that differs.
 *
 * ⚠ THIS PROVES THE DATA REACHES THE APP'S QUERY, NOT THAT THE APP DRAWS IT. Those are different
 * failures and this estate has hit the second one: the property card's "Lock box / key" row was a
 * HARDCODED em dash for every property, so all three surfaces agreed perfectly while the screen
 * showed nothing. Pair this with a look at the rendered card - see the changelog entry for
 * 2026-09-02 (2nd).
 *
 * ⚠ POSITIVE CONTROL. A sweep that finds no values at all is a broken instrument, not a clean
 * estate: it exits non-zero rather than reporting "0 mismatches". Jobber's numeric empty is 0 and
 * its text empty is null/'' - the comparison normalises those against our NULL rather than
 * treating them as a difference, or every never-filled property would report as a mismatch.
 */
const fs = require('fs'), path = require('path');
const arg = (n) => (process.argv.find(a => a.startsWith('--' + n + '=')) || '').split('=').slice(1).join('=');

const FIELDS = {
  gt: {
    label: 'Grease Trap size',
    base: 'grease_trap_size_gallons',
    view: 'grease_capacity_gallons',   // the view RENAMES it; the app binds this name
    fragment: '... on CustomFieldNumeric { label valueNumeric }',
    read: (n) => (n && n.valueNumeric != null ? Number(n.valueNumeric) : null),
    empty: (v) => v === null || v === undefined || Number(v) === 0,
    same: (a, b) => Number(a) === Number(b),
  },
  lockbox: {
    label: 'Lock Box/Key',
    base: 'lock_box_key',
    view: 'lock_box_key',
    fragment: '... on CustomFieldText { label valueText }',
    read: (n) => (n && n.valueText != null && n.valueText !== '' ? String(n.valueText) : null),
    empty: (v) => v === null || v === undefined || String(v).trim() === '',
    same: (a, b) => String(a) === String(b),
  },
};
const F = FIELDS[arg('field') || 'lockbox'];
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

(async () => {
  const token = require('child_process').execSync('bash ./jobber-token.sh',
    { cwd: path.resolve(repoRoot, '..', 'Slack') }).toString().trim();

  const Q = 'query($after:String){ properties(first:100, after:$after){ pageInfo{hasNextPage endCursor}'
    + ' nodes{ id customFields{ __typename ' + F.fragment + ' } } } }';
  const live = new Map();
  let after = null, scanned = 0, populated = 0;
  for (let i = 0; i < 25; i++) {
    const r = await fetch('https://api.getjobber.com/api/graphql', { method: 'POST',
      headers: { Authorization: 'Bearer ' + token, 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16', 'Content-Type': 'application/json' },
      body: JSON.stringify({ query: Q, variables: { after } }) });
    const ctype = r.headers.get('content-type') || '';
    if (!ctype.includes('json')) throw new Error('Jobber returned ' + ctype + ' at HTTP ' + r.status + ' (waiting room?)');
    const j = await r.json();
    if (!j.data) throw new Error('Jobber replied with no data key');
    for (const n of j.data.properties.nodes) {
      const v = F.read((n.customFields || []).find(c => c.label === F.label));
      live.set(n.id, v); scanned++; if (!F.empty(v)) populated++;
    }
    if (!j.data.properties.pageInfo.hasNextPage) break;
    after = j.data.properties.pageInfo.endCursor;
  }
  if (scanned > 50 && populated === 0) {
    throw new Error('POSITIVE CONTROL FAILED: scanned ' + scanned + ' Jobber properties and found a '
      + F.label + ' on none of them. The reader is broken; refusing to report "no mismatches".');
  }

  // BOTH our surfaces in one statement, so they cannot be read at two different moments.
  const rows = await sql(
    'select p.id, c.client_code, p.' + F.base + ' as base, v.' + F.view + ' as view_val, l.source_id'
    + ' from public.properties p'
    + ' join public.clients c on c.id = p.client_id'
    + ' left join client.properties v on v.id = p.id'
    + " left join public.entity_source_links l"
    + "   on l.entity_type='property' and l.source_system='jobber' and l.entity_id = p.id"
    + ' where p.deleted_at is null and p.is_billing = false'
    + '   and p.' + F.base + ' is not null'
    + ' order by p.id');

  const bad = { base_vs_view: [], base_vs_jobber: [], missing_from_view: [], unlinked: [] };
  let ok = 0;
  for (const r of rows) {
    if (r.view_val === null || r.view_val === undefined) { bad.missing_from_view.push({ property: r.id, client: r.client_code, base: r.base }); continue; }
    if (!F.same(r.base, r.view_val)) { bad.base_vs_view.push({ property: r.id, client: r.client_code, base: r.base, view: r.view_val }); continue; }
    if (!r.source_id || !live.has(r.source_id)) { bad.unlinked.push({ property: r.id, client: r.client_code, base: r.base }); continue; }
    const j = live.get(r.source_id);
    if (F.empty(j) || !F.same(r.base, j)) { bad.base_vs_jobber.push({ property: r.id, client: r.client_code, base: r.base, jobber: j }); continue; }
    ok++;
  }

  const failures = bad.base_vs_view.length + bad.base_vs_jobber.length + bad.missing_from_view.length;
  console.log(JSON.stringify({
    field: F.label,
    jobber_properties_scanned: scanned,
    jobber_populated: populated,
    we_hold_a_value: rows.length,
    ALL_THREE_AGREE: ok,
    mismatches: failures,
    detail: bad,
  }, null, 1));

  if (failures) { console.error('\nFAIL: ' + failures + ' propert' + (failures === 1 ? 'y' : 'ies') + ' disagree across surfaces'); process.exit(1); }
  console.log('\nPASS: all ' + ok + ' agree across public.properties, client.properties and Jobber.'
    + (bad.unlinked.length ? ' (' + bad.unlinked.length + ' unlinked/not in the Jobber sweep, not counted)' : ''));
})().catch(e => { console.error('ERROR: ' + e.message); process.exit(2); });
