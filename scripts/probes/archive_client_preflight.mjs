// Preflight for the archive-client edge function: proves the things the function ASSUMES.
//
// Every check here exists because assuming it would fail SILENTLY at runtime:
//  1. the 3-arg update_client_status overload exists and pins status_source='manual'
//  2. it accepts the exact status strings the function sends ('INACTIVE' / 'ACTIVE')
//  3. `client` is exposed to PostgREST, or asUser.schema("client").rpc() 404s
//  4. `authenticated` can EXECUTE it, since it is called as the human, not as service_role
//  5. preview_client_status_change exists for the UI's blast-radius dialog
//
// 🛑 POSITIVE CONTROL: check 1 must find BOTH overloads. Finding one is how you convince yourself
//    there is no overload hazard when there is (feedback_confident_zero_is_a_broken_instrument).
import { readFileSync } from 'node:fs';
const env = Object.fromEntries(readFileSync('.env', 'utf8').split(/\r?\n/)
  .filter(l => /^[A-Z_]+=/.test(l))
  .map(l => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '').trim()]));

async function sql(q) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_ID}/database/query`, {
    method: 'POST', headers: { Authorization: `Bearer ${env.SUPABASE_PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: q }) });
  const t = await r.text();
  let j; try { j = JSON.parse(t); } catch { throw new Error(`non-JSON: ${t.slice(0, 200)}`); }
  if (!Array.isArray(j)) throw new Error(`mgmt API error: ${t.slice(0, 300)}`);
  return j;
}

const out = {};
let fails = 0;
const check = (name, ok, detail) => {
  if (!ok) fails++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ` -- ${detail}` : ''}`);
};

(async () => {
  // 1 + 2: the overloads, their arg lists, and whether each pins status_source
  const fns = await sql(`
    select p.proname,
           pg_get_function_identity_arguments(p.oid) args,
           pg_get_functiondef(p.oid) ~ 'status_source' pins_source,
           p.prosecdef security_definer,
           pg_get_functiondef(p.oid) body
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='client' and p.proname in ('update_client_status','preview_client_status_change')
     order by p.proname, args`);
  out.overloads = fns.map(f => ({ proname: f.proname, args: f.args, pins_source: f.pins_source }));
  console.log(JSON.stringify(out.overloads, null, 1));

  const three = fns.find(f => f.proname === 'update_client_status' && f.args.split(',').length === 3);
  const two   = fns.find(f => f.proname === 'update_client_status' && f.args.split(',').length === 2);
  check('BOTH update_client_status overloads visible (positive control)', !!three && !!two,
        `3-arg=${!!three} 2-arg=${!!two}`);
  check('the 3-arg overload pins status_source', !!three?.pins_source);
  // ⚠ READ THIS RESULT THE RIGHT WAY ROUND. The 2-arg overload is not a stale-but-working copy that
  //   forgets the pin; its ENTIRE BODY is `raise exception 'a reason is now required'` (22023). So it
  //   fails LOUDLY and cannot half-write. Asserting on its literal body, not on the absence of a
  //   string, because "does not contain status_source" is also true of a function that does nothing.
  check('the 2-arg overload is a hard refusal, not a silent unpinned write',
        /raise exception/i.test(two?.body ?? '') && !/update .*public\.clients/i.test(two?.body ?? ''),
        (two?.body ?? '').includes('a reason is now required') ? "raises 'a reason is now required'" : 'UNEXPECTED BODY');
  check('preview_client_status_change exists', fns.some(f => f.proname === 'preview_client_status_change'));

  // the accepted status vocabulary, read out of the body rather than assumed
  const accepted = [...new Set((three?.body ?? '').match(/'[A-Z_]{3,}'/g) ?? [])].join(' ');
  out.accepted_literals = accepted;
  check("the function sends 'INACTIVE' and 'ACTIVE', both of which appear in the body",
        accepted.includes("'INACTIVE'") && accepted.includes("'ACTIVE'"), accepted.slice(0, 160));

  // 3: schema routable through PostgREST.
  // ⚠ DO NOT ask Postgres for this. The first version of this check read
  //   current_setting('pgrst.db_schemas'), got '(unset)', and reported the schema NOT exposed while
  //   the Client App was calling client.* RPCs all day. Exposed-schemas is gateway config, not a
  //   Postgres GUC, so that query can only ever return unset: a check that cannot pass is not a
  //   check. Ask the ROUTER instead (feedback_verify_raw_signal_not_proxy).
  //   PGRST106 = schema not in the exposed list. ANY other reply, permission errors included,
  //   proves the route resolved.
  const rest = async (profile, fn, payload) => {
    const r = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/${fn}`, {
      method: 'POST',
      headers: { apikey: env.SUPABASE_SERVICE_ROLE_KEY, Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
                 'Content-Type': 'application/json', 'Content-Profile': profile },
      body: JSON.stringify(payload) });
    const t = await r.text();
    let code = ''; try { code = JSON.parse(t).code ?? ''; } catch { /* not json */ }
    return { status: r.status, code };
  };
  const routed = await rest('client', 'preview_client_status_change', { p_client_id: -1, p_status: 'INACTIVE' });
  // 🛑 POSITIVE CONTROL: a function that does not exist MUST come back PGRST202. Without it, a
  //    router that answered everything the same way would score as a pass.
  const control = await rest('public', 'nonexistent_control_fn_do_not_create', {});
  check('control: an unknown function returns PGRST202 (the router is answering honestly)',
        control.code === 'PGRST202', `HTTP ${control.status} ${control.code}`);
  check('`client` schema is routable through PostgREST (not PGRST106)',
        routed.code !== 'PGRST106', `HTTP ${routed.status} ${routed.code || '-'}`);
  out.pgrst_route = routed;

  // 4: EXECUTE grant for `authenticated` on the 3-arg overload specifically
  const grants = await sql(`
    select p.proname, pg_get_function_identity_arguments(p.oid) args,
           has_function_privilege('authenticated', p.oid, 'EXECUTE') auth_exec
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='client' and p.proname in ('update_client_status','preview_client_status_change')`);
  out.execute_grants = grants;
  const threeGrant = grants.find(g => g.proname === 'update_client_status' && g.args.split(',').length === 3);
  check('authenticated can EXECUTE the 3-arg overload', threeGrant?.auth_exec === true);
  check('authenticated can EXECUTE preview_client_status_change',
        grants.find(g => g.proname === 'preview_client_status_change')?.auth_exec === true);

  // context: how many clients would this button ever act on
  const counts = await sql(`
    select c.status, count(*)::int n,
           count(*) filter (where l.source_id is not null)::int with_jobber_link
      from public.clients c
      left join public.entity_source_links l
        on l.entity_type='client' and l.source_system='jobber' and l.entity_id=c.id
     group by 1 order by 2 desc`);
  out.status_counts = counts;
  console.log('\nclients by status:', JSON.stringify(counts));

  console.log(`\n${fails === 0 ? 'ALL CHECKS PASSED' : `${fails} CHECK(S) FAILED`}`);
  console.log('--- audit complete --- ' + JSON.stringify({ probe: 'archive_client_preflight', checks: 9, failures: fails }));
  process.exit(fails === 0 ? 0 : 1);
})();
