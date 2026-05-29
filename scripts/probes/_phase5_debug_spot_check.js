// Spot-check Phase 5 — pick 5 completed visits that HAVE DB assignments and
// compare to Jobber's assignedUsers, see if the mapping is the bug.
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const URL = process.env.SUPABASE_URL, KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const PROJECT = process.env.SUPABASE_PROJECT_ID, PAT = process.env.SUPABASE_PAT;

async function rest(p) {
  return (await fetch(URL + '/rest/v1' + p, { headers: { apikey: KEY, Authorization: 'Bearer ' + KEY } })).json();
}
async function pg(q) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROJECT}/database/query`, {
    method: 'POST', headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: q })
  });
  return r.json();
}

(async () => {
  const tk = (await rest('/webhook_tokens?source_system=eq.jobber&select=access_token'))[0].access_token;

  // 5 sample visits with DB assignments
  const sample = await pg(`
    SELECT v.id, v.title, v.visit_date,
           (SELECT array_agg(va.employee_id::text) FROM public.visit_assignments va WHERE va.visit_id = v.id) AS db_emp_ids,
           (SELECT array_agg(e.full_name) FROM public.visit_assignments va JOIN public.employees e ON e.id=va.employee_id WHERE va.visit_id = v.id) AS db_names,
           esl.source_id AS gid
    FROM public.visits v
    JOIN public.entity_source_links esl ON esl.entity_type='visit' AND esl.entity_id=v.id AND esl.source_system='jobber'
    WHERE v.visit_status='completed' AND v.id IN (SELECT visit_id FROM public.visit_assignments)
    ORDER BY v.visit_date DESC LIMIT 5;
  `);

  for (const v of sample) {
    const jr = await fetch('https://api.getjobber.com/api/graphql', {
      method: 'POST', headers: { Authorization: 'Bearer ' + tk, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16' },
      body: JSON.stringify({ query: 'query($id: EncodedId!) { visit(id: $id) { id assignedUsers { nodes { id name { full } } } } }', variables: { id: v.gid } })
    });
    const j = await jr.json();
    const jbNodes = j.data?.visit?.assignedUsers?.nodes || [];
    const jbGids = jbNodes.map(n => n.id);
    let mapped = [];
    if (jbGids.length > 0) {
      const eMap = await pg(`SELECT esl.entity_id AS emp_id, esl.source_id AS gid, e.full_name FROM public.entity_source_links esl JOIN public.employees e ON e.id = esl.entity_id WHERE esl.entity_type='employee' AND esl.source_system='jobber' AND esl.source_id IN (${jbGids.map(x => "'" + x + "'").join(',')});`);
      mapped = eMap;
    }
    console.log(`\n=== Visit ${v.id} | ${v.visit_date} | ${(v.title || '').slice(0, 60)} ===`);
    console.log(`  DB assignments: ${v.db_names ? v.db_names.join(', ') : 'NONE'} (ids: ${v.db_emp_ids ? v.db_emp_ids.join(', ') : 'NONE'})`);
    console.log(`  Jobber assignedUsers: ${jbNodes.map(n => n.name?.full || '?').join(', ') || 'NONE'} (${jbGids.length} users)`);
    console.log(`  Jobber GIDs: ${jbGids.join(', ') || 'none'}`);
    console.log(`  Mapped Jobber→DB: ${mapped.map(m => `${m.full_name} (id=${m.emp_id})`).join(', ') || 'none mapped'}`);
  }
})().catch(e => { console.error(e); process.exit(1); });
