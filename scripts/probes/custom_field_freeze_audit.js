// Read-only FREEZE AUDIT for a Jobber custom field mirrored through sync.source_field_shadow.
//
//   node scripts/probes/lock_box_freeze_audit.js                 # Lock Box/Key   (text)
//   node scripts/probes/lock_box_freeze_audit.js --field=gt      # Grease Trap size (numeric)
//
// Answers TWO questions, because "not frozen today" is the weaker one:
//   1. is conflict_at set right now?
//   2. would the NEXT Jobber-side edit freeze it? That is the shape that bit on 2026-09-02, and
//      it is invisible in question 1 - property 100 read "not frozen" right up until Jobber moved.
// Both are answered by CALLING sync.fn_shadow_decision, which is pure, rather than by re-reading
// the columns. Jobber is swept live so the recorded last-seen is checked against what Jobber
// actually holds rather than against itself.
//
// 🛑 TYPE IS LOAD-BEARING HERE. fn_shadow_decision compares jsonb by identity, so feeding a
// numeric field's value as a jsonb STRING makes "190" differ from 190 and every row reports a
// change that did not happen. The registry below carries the GraphQL fragment, the reader and the
// jsonb literal per field, so a second field cannot inherit the first one's type by accident.
//
// ⚠ AN "ARMED" ROW IS NOT AUTOMATICALLY A DEFECT, and the two fields differ. CONFLICT means both
// sides moved, which for the grease trap size can be a REAL and correct pending divergence: that
// column is edited in our apps (120 changes, 3 app_sources), and between an app edit and the next
// poll our value legitimately differs from the last-seen. For the lock box the same signal was a
// bookkeeping error - the shadow said we held nothing while the column held a code. Read
// our_seen vs our_column before calling anything a defect.
const fs = require('fs'), path = require('path');
const FIELDS = {
  lockbox: {
    label: 'Lock Box/Key',
    gid: 'gid://Jobber/CustomFieldConfigurationText/3061112',
    column: 'lock_box_key',
    fragment: '... on CustomFieldText{ label valueText }',
    read: (n) => (n.valueText != null ? String(n.valueText) : null),
    lit: (v) => (v === null || v === undefined ? "'null'::jsonb" : `to_jsonb('${String(v).replace(/'/g, "''")}'::text)`),
    hypothetical: "to_jsonb('ZZ-NEW'::text)",
  },
  gt: {
    label: 'Grease Trap size',
    gid: 'gid://Jobber/CustomFieldConfigurationNumeric/3061111',
    column: 'grease_trap_size_gallons',
    fragment: '... on CustomFieldNumeric{ label valueNumeric }',
    // a numeric custom field is materialised on every property and defaults to 0, so "no value"
    // and "somebody typed zero" arrive identically. That is why the shadow exists at all.
    read: (n) => (n.valueNumeric != null ? Number(n.valueNumeric) : null),
    lit: (v) => (v === null || v === undefined ? "'null'::jsonb" : `to_jsonb(${Number(v)})`),
    hypothetical: 'to_jsonb(9999)',
  },
};
const FIELD = FIELDS[(process.argv.find(a => /^--field=/.test(a))?.split('=')[1]) || 'lockbox'];
if (!FIELD) throw new Error('unknown --field, use lockbox or gt');

const repoRoot = 'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase';
const env = Object.fromEntries(
  fs.readFileSync(path.join(repoRoot, '.env'), 'utf8').split(/\r?\n/).filter(l => l.includes('='))
    .map(l => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]));

async function sql(q) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_ID}/database/query`,
    { method: 'POST', headers: { Authorization: `Bearer ${env.SUPABASE_PAT}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ query: q }) });
  const t = await r.text(); let j; try { j = JSON.parse(t); } catch { throw new Error('non-JSON: ' + t.slice(0,300)); }
  if (j && j.message) throw new Error(j.message);
  return j;
}

(async () => {
  const token = require('child_process').execSync('bash ./jobber-token.sh',
    { cwd: path.resolve(repoRoot, '..', 'Slack') }).toString().trim();
  const Q = `query($after:String){ properties(first:100, after:$after){ pageInfo{hasNextPage endCursor} nodes{ id customFields{ __typename ${FIELD.fragment} } } } }`;
  const live = new Map();
  let after = null;
  for (let i = 0; i < 20; i++) {
    const r = await fetch('https://api.getjobber.com/api/graphql', { method:'POST',
      headers:{Authorization:'Bearer '+token,'X-JOBBER-GRAPHQL-VERSION':'2026-04-16','Content-Type':'application/json'},
      body: JSON.stringify({query:Q, variables:{after}})});
    const ct = r.headers.get('content-type')||'';
    if (!ct.includes('json')) throw new Error(`Jobber returned ${ct} at HTTP ${r.status}`);
    const j = await r.json();
    if (!j.data) throw new Error('Jobber replied with no data key');
    for (const n of j.data.properties.nodes) {
      const f = (n.customFields||[]).find(c => c.label === FIELD.label);
      live.set(n.id, f ? FIELD.read(f) : undefined);
    }
    if (!j.data.properties.pageInfo.hasNextPage) break;
    after = j.data.properties.pageInfo.endCursor;
  }

  const rows = await sql(`
    select s.entity_id as property_id, c.client_code,
           p.__COLUMN__                  as our_column,
           s.our_value    #>> '{}'       as shadow_our,
           s.source_value #>> '{}'       as shadow_source,
           (s.conflict_at is not null)   as frozen_now,
           s.conflict_count,
           l.source_id                   as jobber_gid
      from sync.source_field_shadow s
      join public.properties p on p.id = s.entity_id
      join public.clients c on c.id = p.client_id
      left join public.entity_source_links l
        on l.entity_type='property' and l.source_system='jobber' and l.entity_id = s.entity_id
     where s.field_key = '__GID__'
     order by s.entity_id`
      .replace('__COLUMN__', FIELD.column).replace('__GID__', FIELD.gid));

  // Ask the real decision function what happens next, for each row, in ONE round trip.
  // p_exists is true for all of these (they all have a shadow row).
  const cases = rows.map(r => {
    const jobberNow = live.has(r.jobber_gid) ? live.get(r.jobber_gid) : undefined;
    return { ...r, jobber_now: jobberNow };
  });
  const vals = cases.map(r => {
    const j  = FIELD.lit(r.jobber_now);
    const ss = FIELD.lit(r.shadow_source);
    const ol = FIELD.lit(r.our_column);
    const os = FIELD.lit(r.shadow_our);
    // EDIT scenario: pretend somebody types a new value in Jobber tomorrow.
    return `(${r.property_id}, sync.fn_shadow_decision(true, ${j}, ${ss}, ${ol}, ${os}),
              sync.fn_shadow_decision(true, ${FIELD.hypothetical}, ${ss}, ${ol}, ${os}))`;
  }).join(',');
  const decisions = await sql(
    `select * from (values ${vals}) as t(property_id, decision_unchanged, decision_if_jobber_edits)`);
  const byId = new Map(decisions.map(d => [d.property_id, d]));

  let bad = [];
  for (const r of cases) {
    const d = byId.get(r.property_id) || {};
    const armed = d.decision_if_jobber_edits === 'CONFLICT';
    const norm = (v) => (v === undefined || v === null ? null : String(v));
    const drift = norm(r.shadow_source) !== norm(r.jobber_now);
    if (r.frozen_now || armed) bad.push({ ...r, ...d });
    r._d = d; r._drift = drift;
  }

  console.log(JSON.stringify({
    field: FIELD.label,
    shadow_rows: cases.length,
    frozen_now: cases.filter(r => r.frozen_now).length,
    armed_to_freeze_on_next_jobber_edit: cases.filter(r => byId.get(r.property_id)?.decision_if_jobber_edits === 'CONFLICT').length,
    decision_if_nothing_changes: cases.reduce((a, r) => { const k = r._d.decision_unchanged || '?'; a[k] = (a[k]||0)+1; return a; }, {}),
    decision_if_jobber_edits: cases.reduce((a, r) => { const k = r._d.decision_if_jobber_edits || '?'; a[k] = (a[k]||0)+1; return a; }, {}),
    shadow_source_disagrees_with_live_jobber: cases.filter(r => r._drift).map(r => ({
      property: r.property_id, client: r.client_code, shadow_saw: r.shadow_source, jobber_now: r.jobber_now })),
    problems: bad,
  }, null, 1));
  process.exit(bad.length ? 1 : 0);
})().catch(e => { console.error('FAILED: ' + e.message); process.exit(2); });
