// Verify a sample of visit assignments after Phase 5 execute.
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const SB_URL = process.env.SUPABASE_URL, KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const PROJECT = process.env.SUPABASE_PROJECT_ID, PAT = process.env.SUPABASE_PAT;

(async () => {
  const visits = await fetch(`https://api.supabase.com/v1/projects/${PROJECT}/database/query`, {
    method: 'POST', headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: `SELECT v.id, v.title, v.visit_date,
      (SELECT json_agg(json_build_object('emp_id', va.employee_id, 'name', e.full_name))
        FROM public.visit_assignments va JOIN public.employees e ON e.id=va.employee_id
        WHERE va.visit_id = v.id) AS db_emp,
      esl.source_id AS gid
      FROM public.visits v
      JOIN public.entity_source_links esl ON esl.entity_type='visit' AND esl.entity_id=v.id AND esl.source_system='jobber'
      WHERE v.visit_status='completed' AND v.visit_date BETWEEN '2026-05-15' AND '2026-05-28'
      ORDER BY v.visit_date DESC LIMIT 8` })
  }).then(r => r.json());

  const tk = (await fetch(`${SB_URL}/rest/v1/webhook_tokens?source_system=eq.jobber&select=access_token`, { headers: { apikey: KEY, Authorization: `Bearer ${KEY}` } }).then(r => r.json()))[0].access_token;

  for (const v of visits) {
    const jr = await fetch('https://api.getjobber.com/api/graphql', {
      method: 'POST', headers: { Authorization: `Bearer ${tk}`, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16' },
      body: JSON.stringify({ query: 'query($id: EncodedId!) { visit(id: $id) { assignedUsers { nodes { id name { full } } } } }', variables: { id: v.gid } })
    }).then(r => r.json());
    const jbNames = jr.data?.visit?.assignedUsers?.nodes?.map(n => n.name?.full).join(', ') || 'none';
    const dbNames = v.db_emp?.map(e => e.name).join(', ') || 'NONE';
    const match = dbNames === jbNames || (dbNames === 'NONE' && jbNames === 'none') ? '✅' : '❌';
    console.log(`${match} id=${v.id} ${v.visit_date}`);
    console.log(`    DB: ${dbNames}`);
    console.log(`    JB: ${jbNames}`);
  }
})().catch(e => { console.error(e); process.exit(1); });
