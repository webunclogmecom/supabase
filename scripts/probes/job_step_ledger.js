// Probe for 2026-08-19_1930_client_create_attempts_job_step.sql
//
// Run it BEFORE the migration (the two real checks must FAIL, the control must PASS) and AFTER
// (everything must PASS). A probe whose control does not fire is an untested instrument, and its
// other results mean nothing.
require('dotenv').config({ path: __dirname + '/../../.env' });
const fs = require('fs');

async function sql(query) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query }),
  });
  const t = await r.text();
  try { return JSON.parse(t); } catch { return { error: t.slice(0, 300) }; }
}

(async () => {
  const out = [];

  const cols = await sql(`select column_name from information_schema.columns
    where table_schema='public' and table_name='client_create_attempts'
      and column_name in ('jobber_job_gid','job_id','job_step')`);
  const names = Array.isArray(cols) ? cols.map(c => c.column_name).sort() : [];
  out.push({ check: 'ledger columns exist', pass: names.length === 3, got: names.join(',') || '(none)' });

  const view = await sql(`select pg_get_viewdef('public.v_client_create_attention'::regclass, true) as def`);
  const def = Array.isArray(view) ? String(view[0].def) : '';
  out.push({ check: 'view has a job_step branch', pass: def.includes('job_step'), got: def.includes('job_step') ? 'present' : 'absent' });

  // POSITIVE CONTROL: must pass both before and after. If this fails, the probe cannot see the view
  // and neither result above means anything.
  out.push({ check: 'CONTROL: view still exposes what_to_do', pass: def.includes('what_to_do'), got: def.includes('what_to_do') ? 'present' : 'absent' });

  // GRANT CONTROL: the view carries a yannick_readonly SELECT grant. CREATE OR REPLACE preserves it;
  // a DROP + CREATE would silently revoke it. Measured before the migration: present.
  const grants = await sql(`select grantee, privilege_type from information_schema.role_table_grants
    where table_schema='public' and table_name='v_client_create_attention' and grantee='yannick_readonly'`);
  const hasYannick = Array.isArray(grants) && grants.some(g => g.privilege_type === 'SELECT');
  out.push({ check: 'CONTROL: yannick_readonly keeps SELECT on the view', pass: hasYannick, got: hasYannick ? 'SELECT present' : 'MISSING' });

  fs.writeFileSync(__dirname + '/job_step_ledger.out.json', JSON.stringify(out, null, 1));
  for (const o of out) console.log((o.pass ? 'PASS' : 'FAIL').padEnd(5), o.check, '|', o.got);
  process.exit(out.every(o => o.pass) ? 0 : 1);
})();
