import { sql } from './calendar_task_esl.mjs'

const rows = await sql(`
  select c.relname,
         c.relrowsecurity as rls_on,
         c.relacl::text   as acl,
         has_table_privilege('authenticated','ops.'||c.relname,'SELECT') as authn_select,
         has_table_privilege('authenticated','ops.'||c.relname,'INSERT') as authn_insert,
         has_table_privilege('authenticated','ops.'||c.relname,'UPDATE') as authn_update,
         has_table_privilege('authenticated','ops.'||c.relname,'DELETE') as authn_delete,
         has_table_privilege('service_role','ops.'||c.relname,'INSERT')  as svc_insert
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'ops' and c.relname in ('calendar_tasks','calendar_task_assignees','visit_requests')
   order by c.relname`)

// CONTROL: ops.visit_requests is the shape we are copying. It must show authn SELECT-only.
const control = rows.find(r => r.relname === 'visit_requests')
if (!control) throw new Error('CONTROL MISSING: ops.visit_requests not found, probe is untrustworthy')
const controlOk = control.authn_select && !control.authn_insert && !control.svc_insert
console.log('CONTROL ops.visit_requests SELECT-only: ' + controlOk + '  (must be true)')

let fails = controlOk ? 0 : 1
for (const r of rows.filter(r => r.relname !== 'visit_requests')) {
  const good = r.rls_on && r.authn_select &&
    !r.authn_insert && !r.authn_update && !r.authn_delete && !r.svc_insert
  if (!good) fails++
  console.log(`  ops.${r.relname}: rls=${r.rls_on} authn(s/i/u/d)=${r.authn_select}/${r.authn_insert}/${r.authn_update}/${r.authn_delete} svc_insert=${r.svc_insert}  => ${good ? 'OK' : 'WRONG'}`)
}
if (rows.length < 3) console.log('  (tables not created yet)')
console.log('--- audit complete --- ' + JSON.stringify({ probe: 'calendar_task_grants', found: rows.length, failures: fails }))
process.exit(fails ? 1 : 0)
