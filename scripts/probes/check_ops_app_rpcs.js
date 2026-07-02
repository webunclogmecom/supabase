/* check_ops_app_rpcs.js — guard against ops-app-RPC drift (the 2026-07-03 bug).
 *
 * The Lovable apps (Calendar, etc.) use PostgREST clients scoped to the `ops` schema, so they
 * call ops.<fn> — thin wrappers that forward to public.<fn> (schema-per-app pattern). If a
 * migration changes public.<fn>'s signature but forgets to recreate the ops wrapper (or a
 * schema-unqualified DROP nukes it), the app breaks with "Could not find the function
 * ops.<fn>(...) in the schema cache". This probe catches that BEFORE the app does.
 *
 * Checks:
 *   1. Every CRITICAL ops RPC exists + anon has EXECUTE (hard-coded list the apps depend on).
 *   2. Every ops function that WRAPS a public one (its body calls public.<samename>) has the
 *      SAME max arg count as that public function — i.e. the wrapper isn't stale.
 * Emits a sentinel line + exits non-zero on any finding (so CI / the health check can gate on it).
 *   node scripts/probes/check_ops_app_rpcs.js
 */
const https = require('https');
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const PAT = process.env.SUPABASE_PAT, P = process.env.SUPABASE_PROJECT_ID;

// ops RPCs the apps call directly — must always exist in ops.
const CRITICAL = ['create_calendar_visit', 'edit_calendar_visit', 'ripple_reschedule_visit', 'delete_calendar_visit'];

function pg(q){return new Promise((res,rej)=>{const b=JSON.stringify({query:q});const r=https.request({hostname:'api.supabase.com',path:`/v1/projects/${P}/database/query`,method:'POST',headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json','Content-Length':Buffer.byteLength(b)}},x=>{let d='';x.on('data',c=>d+=c);x.on('end',()=>{let j;try{j=JSON.parse(d);}catch(e){return rej(new Error('pg parse: '+d.slice(0,200)));} if(!Array.isArray(j))return rej(new Error('pg error: '+JSON.stringify(j).slice(0,200))); res(j);});});r.on('error',rej);r.write(b);r.end();});}
const maxBy = (rows, key, val) => { const m={}; for (const r of rows) { const k=r[key]; m[k]=Math.max(m[k]??-1, Number(r[val])); } return m; };

(async () => {
  const findings = [];
  // one row per function (no SQL aggregates — aggregate in JS to avoid grouping pitfalls)
  const ops = await pg(`SELECT p.proname, p.pronargs, has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_exec,
    (pg_get_functiondef(p.oid) ILIKE '%public.'||p.proname||'%') AS is_wrapper
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='ops'`);
  const pub = await pg(`SELECT p.proname, p.pronargs FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public'`);

  // 1) critical present + granted
  const opsNames = new Set(ops.map(r => r.proname));
  const anonOk = new Set(ops.filter(r => r.anon_exec).map(r => r.proname));
  for (const c of CRITICAL) {
    if (!opsNames.has(c)) findings.push(`MISSING: ops.${c} does not exist (app calls it → schema-cache error)`);
    else if (!anonOk.has(c)) findings.push(`NO-GRANT: ops.${c} exists but anon lacks EXECUTE`);
  }

  // 2) wrapper drift vs public max arg count
  const opsMax = maxBy(ops.filter(r => r.is_wrapper), 'proname', 'pronargs');
  const pubMax = maxBy(pub, 'proname', 'pronargs');
  for (const name of Object.keys(opsMax)) {
    if (pubMax[name] != null && opsMax[name] !== pubMax[name])
      findings.push(`DRIFT: ops.${name} wraps public.${name} but arg counts differ (ops ${opsMax[name]} vs public ${pubMax[name]}) — recreate the ops wrapper`);
  }

  if (findings.length) { findings.forEach(f => console.log('  x ' + f)); console.log(`--- audit complete --- {"probe":"check_ops_app_rpcs","findings":${findings.length}}`); process.exit(1); }
  console.log(`ops app-RPCs OK: ${CRITICAL.length} critical present + granted, ${Object.keys(opsMax).length} wrappers all mirror public.`);
  console.log(`--- audit complete --- {"probe":"check_ops_app_rpcs","findings":0}`);
})().catch(e => { console.error('FATAL', e.message); process.exit(2); });
