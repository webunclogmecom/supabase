// 71_revert_test_visit_status.mjs
// Revert visit 3910 (Bagel Cove May 4) back to completed state.
// My Mark-complete-toggle test flipped it to scheduled. Restoring original.
import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'},
    body:JSON.stringify({query:sql}),
  });
  const body = await r.text();
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${body.slice(0, 600)}`);
  return JSON.parse(body);
}

console.log('=== Before ===');
console.log(await pg(`SELECT id, visit_status, completed_at FROM public.visits WHERE id=3910;`));

console.log('\n=== Revert: visit_status=completed, completed_at=original ===');
console.log(await pg(`
  UPDATE public.visits
  SET visit_status='completed', completed_at='2026-05-05T05:33:51+00:00'::timestamptz
  WHERE id=3910
  RETURNING id, visit_status, completed_at;
`));

console.log('\n=== After ===');
console.log(await pg(`SELECT id, visit_status, completed_at FROM public.visits WHERE id=3910;`));
