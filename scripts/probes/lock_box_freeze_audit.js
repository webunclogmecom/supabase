// Read-only audit of every lock-box shadow row.
// Answers TWO questions, because "not frozen today" is the weaker one:
//   1. is conflict_at set right now?
//   2. would the NEXT Jobber-side edit freeze it? That is the defect the repair fixed, and it
//      is invisible in question 1 - property 100 read "not frozen" right up until Jobber moved.
// Both are answered by CALLING sync.fn_shadow_decision, which is a pure decision function, not
// by re-reading the columns I just wrote. Jobber is swept live so source_value is checked against
// what Jobber actually holds rather than against what we last recorded.
const fs = require('fs'), path = require('path');
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
  const Q = `query($after:String){ properties(first:100, after:$after){ pageInfo{hasNextPage endCursor} nodes{ id customFields{ __typename ... on CustomFieldText{ label valueText } } } } }`;
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
      const f = (n.customFields||[]).find(c => c.label === 'Lock Box/Key');
      live.set(n.id, f && f.valueText != null ? String(f.valueText) : null);
    }
    if (!j.data.properties.pageInfo.hasNextPage) break;
    after = j.data.properties.pageInfo.endCursor;
  }

  const rows = await sql(`
    select s.entity_id as property_id, c.client_code,
           p.lock_box_key                as our_column,
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
     where s.field_key = 'gid://Jobber/CustomFieldConfigurationText/3061112'
     order by s.entity_id`);

  // Ask the real decision function what happens next, for each row, in ONE round trip.
  // p_exists is true for all of these (they all have a shadow row).
  const cases = rows.map(r => {
    const jobberNow = live.has(r.jobber_gid) ? live.get(r.jobber_gid) : undefined;
    return { ...r, jobber_now: jobberNow };
  });
  const vals = cases.map(r => {
    const j = r.jobber_now === undefined || r.jobber_now === null ? 'null' : `to_jsonb('${String(r.jobber_now).replace(/'/g,"''")}'::text)`;
    const ss = r.shadow_source === null ? 'null' : `to_jsonb('${r.shadow_source.replace(/'/g,"''")}'::text)`;
    const ol = r.our_column === null ? `'null'::jsonb` : `to_jsonb('${r.our_column.replace(/'/g,"''")}'::text)`;
    const os = r.shadow_our === null ? `'null'::jsonb` : `to_jsonb('${r.shadow_our.replace(/'/g,"''")}'::text)`;
    // EDIT scenario: pretend somebody types a new code in Jobber tomorrow.
    return `(${r.property_id}, sync.fn_shadow_decision(true, ${j}, ${ss}, ${ol}, ${os}),
              sync.fn_shadow_decision(true, to_jsonb('ZZ-NEW'::text), ${ss}, ${ol}, ${os}))`;
  }).join(',');
  const decisions = await sql(
    `select * from (values ${vals}) as t(property_id, decision_unchanged, decision_if_jobber_edits)`);
  const byId = new Map(decisions.map(d => [d.property_id, d]));

  let bad = [];
  for (const r of cases) {
    const d = byId.get(r.property_id) || {};
    const armed = d.decision_if_jobber_edits === 'CONFLICT';
    const drift = r.shadow_source !== (r.jobber_now ?? null);
    if (r.frozen_now || armed) bad.push({ ...r, ...d });
    r._d = d; r._drift = drift;
  }

  console.log(JSON.stringify({
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
