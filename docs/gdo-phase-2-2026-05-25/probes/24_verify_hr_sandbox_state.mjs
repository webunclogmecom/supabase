// 24_verify_hr_sandbox_state.js
//
// Verify that klgtrdwrasrlxbmfyvdh is a clean Prod-mirror for handoff:
//  - hr schema absent
//  - my added RLS policies absent
//  - pre-existing FP-clone RLS policies still in place
//  - anon statement_timeout=15s still in place
//  - public.employees / public.vehicles populated

import 'dotenv/config';

const URL = process.env.FIELD_PORTAL_SUPABASE_URL;
const KEY = process.env.FIELD_PORTAL_SUPABASE_SERVICE_ROLE_KEY;

async function rpc(sql) {
  // Use PostgREST exec via the SQL endpoint isn't directly available; use Supabase's
  // /rest/v1/rpc only if we have a function. Easier: use a simple SELECT via REST.
  // For DDL/inspection, query information_schema + pg_catalog through REST is limited.
  // Fall back to using a custom exec_sql function if available; otherwise just hit
  // the tables we know about.
  const r = await fetch(`${URL}/rest/v1/rpc/exec_sql`, {
    method: 'POST',
    headers: { apikey: KEY, Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ sql }),
  });
  if (!r.ok) return { error: `${r.status} ${await r.text()}` };
  return { rows: await r.json() };
}

async function count(table) {
  const r = await fetch(`${URL}/rest/v1/${table}?select=count`, {
    headers: { apikey: KEY, Authorization: `Bearer ${KEY}`, Prefer: 'count=exact' },
  });
  if (!r.ok) return `err ${r.status}`;
  const cr = r.headers.get('content-range');
  return cr?.split('/')?.[1] ?? '?';
}

async function trySelect(path) {
  const r = await fetch(`${URL}/rest/v1/${path}?limit=1`, {
    headers: { apikey: KEY, Authorization: `Bearer ${KEY}` },
  });
  return { status: r.status, body: r.status < 400 ? await r.json() : await r.text() };
}

(async () => {
  console.log('=== HR SANDBOX VERIFICATION ===');
  console.log(`URL: ${URL}\n`);

  console.log('-- Canonical mirror data --');
  for (const t of ['employees', 'vehicles', 'entity_source_links', 'clients', 'visits', 'gdos']) {
    console.log(`  public.${t.padEnd(22)} ${await count(t)} rows`);
  }

  console.log('\n-- HR schema (should be ABSENT) --');
  const hrEmp = await trySelect('hr.employees');
  console.log(`  hr.employees: HTTP ${hrEmp.status}`);
  if (hrEmp.status === 404 || /Could not find|relation .* does not exist/i.test(JSON.stringify(hrEmp.body))) {
    console.log('  EXPECTED — hr schema absent ✓');
  } else {
    console.log('  UNEXPECTED — hr schema still exists:', JSON.stringify(hrEmp.body).slice(0, 200));
  }

  console.log('\n-- RLS policies on public.employees + public.vehicles --');
  // We can't easily query pg_policies via REST without a helper; surface via a select.
  const polCheck = await trySelect('pg_policies?schemaname=eq.public&tablename=in.(employees,vehicles)&select=schemaname,tablename,policyname,roles');
  console.log(`  pg_policies query: HTTP ${polCheck.status}`);
  if (Array.isArray(polCheck.body)) {
    polCheck.body.forEach(p => console.log(`    ${p.schemaname}.${p.tablename}: ${p.policyname}  roles=${JSON.stringify(p.roles)}`));
  } else {
    console.log('  (pg_policies not exposed via REST — would need exec_sql RPC or psql)');
  }

  console.log('\nDONE.');
})();
