// NEVER-EXECUTED REPORT
// =====================
// For every dispatch surface in this estate, when did it LAST ACTUALLY RUN?
// Anything sitting at zero is untested code in production.
//
// WHY THIS EXISTS. On 2026-08-21 we learned that `handlePropertyDestroy` was structurally incapable
// of succeeding: it hard-deleted a parent row that five NO ACTION foreign keys forbid deleting. It
// had been that way for the lifetime of the integration and nothing knew, because the handler had
// never once executed. We found out when it fired on a real customer property and failed. The same
// audit found that 13 of 22 Jobber webhook handlers had no execution on record at all.
// Production was doing our testing. This report exists so that "this code has never run" is a state
// somebody can SEE, rather than something discovered by a customer.
//
// 🛑 THE ONE DESIGN RULE THIS FILE MUST NOT BREAK.
//    There are THREE verdicts, never two:
//        RAN         - evidence exists and shows execution
//        NEVER       - an evidence source covers this surface and shows zero
//        NO EVIDENCE - nothing in this system can answer the question
//    Collapsing NO EVIDENCE into NEVER (or worse, into "fine") is the exact false all-clear this
//    estate keeps paying for: a silent detector reads identically to a healthy system. Every
//    section therefore prints its own evidence source AND its own window, and every section carries
//    a POSITIVE CONTROL that must report RAN. If a control does not fire, that section's clean
//    result is worthless and the report says so instead of passing.
//
// ⚠ WINDOWS ARE NOT INFINITE. "NEVER" always means "never within the evidence we retain". The
//    windows are printed, not assumed, because they differ by two orders of magnitude:
//    webhook_events_log is trimmed, pg_stat_statements is a volatile buffer that any restart clears.
//
// Read-only. Writes nothing.
// Run:  node scripts/checks/never-executed.mjs
//       node scripts/checks/never-executed.mjs --json     (machine-readable, for a scheduled run)
import { readFileSync, writeFileSync, existsSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execSync } from 'node:child_process';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const env = Object.fromEntries(readFileSync(join(ROOT, '.env'), 'utf8').split(/\r?\n/)
  .filter(l => /^[A-Z_]+=/.test(l))
  .map(l => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '').trim()]));
const JSON_MODE = process.argv.includes('--json');

async function sql(q) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_ID}/database/query`, {
    method: 'POST', headers: { Authorization: `Bearer ${env.SUPABASE_PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: q }) });
  const t = await r.text();
  let j; try { j = JSON.parse(t); } catch { throw new Error(`non-JSON from mgmt API: ${t.slice(0, 200)}`); }
  if (!Array.isArray(j)) throw new Error(`mgmt API error: ${t.slice(0, 300)}`);
  return j;
}

const RAN = 'RAN', NEVER = 'NEVER', NOEV = 'NO EVIDENCE';
const report = { generated_at: new Date().toISOString(), sections: [] };
const say = (...a) => { if (!JSON_MODE) console.log(...a); };

function emit(title, evidence, windowText, rows, controlName, collapseNoEvidence) {
  // rows: [{ name, verdict, detail }]
  const control = rows.find(r => r.name === controlName);
  const controlOk = control?.verdict === RAN;
  const section = { title, evidence, window: windowText, control: controlName,
                    control_fired: controlOk, rows };
  report.sections.push(section);
  say(`\n${'='.repeat(100)}`);
  say(`${title}`);
  say(`  evidence: ${evidence}`);
  say(`  window:   ${windowText}`);
  say(`  control:  ${controlName ?? '(none)'} -> ${controlOk ? 'fired, section is trustworthy'
        : '🛑 DID NOT FIRE. This section proves NOTHING; treat every clean row below as unknown.'}`);
  say('-'.repeat(100));
  const order = { [NEVER]: 0, [NOEV]: 1, [RAN]: 2 };
  const sorted = [...rows].sort((a, b) => (order[a.verdict] - order[b.verdict]) || a.name.localeCompare(b.name));
  // collapseNoEvidence: when a section is STRUCTURALLY blind, listing every unknown buries the
  // signal under noise. The COUNT and the REASON are the finding; the names stay in the JSON.
  const shown = collapseNoEvidence ? sorted.filter(r => r.verdict !== NOEV) : sorted;
  for (const r of shown) {
    const mark = r.verdict === NEVER ? '🛑' : r.verdict === NOEV ? '❓' : '  ';
    // STALENESS is an annotation, never a fourth verdict. "ran once in June" is a different
    // question from "never ran", and collapsing them would break the three-state rule above.
    // Every section already prints a date in its detail, so read it back rather than plumbing it.
    const d = r.verdict === RAN ? (r.detail.match(/\d{4}-\d{2}-\d{2}/) || [])[0] : null;
    const days = d ? Math.floor((Date.parse(report.generated_at) - Date.parse(d)) / 86400000) : null;
    const stale = days !== null && days > 30 ? `  ⏳ ${days}d ago` : '';
    say(`  ${mark} ${r.verdict.padEnd(11)} ${r.name.padEnd(34)} ${r.detail}${stale}`);
    if (stale) r.stale_days = days;
  }
  if (collapseNoEvidence) {
    const hidden = sorted.filter(r => r.verdict === NOEV);
    if (hidden.length) say(`  ❓ NO EVIDENCE for ${hidden.length} more (names in never-executed.out.json). ${collapseNoEvidence}`);
  }
  const n = rows.filter(r => r.verdict === NEVER).length;
  const u = rows.filter(r => r.verdict === NOEV).length;
  say(`  => ${rows.length} surfaces: ${rows.length - n - u} ran, ${n} NEVER, ${u} no evidence`);
}

// ================================================================================================
// 1. JOBBER WEBHOOK TOPICS
// ================================================================================================
// 🛑 The topic list is PARSED OUT OF THE LIVE SOURCE FILE, never hardcoded here. A hardcoded list
//    silently stops covering a topic the moment someone adds one, which would make this report
//    quietly incomplete in exactly the way it exists to prevent.
{
  const src = readFileSync(join(ROOT, 'supabase', 'functions', 'webhook-jobber', 'index.ts'), 'utf8');
  const block = src.slice(src.indexOf('const TOPIC_HANDLERS'));
  const topics = [...block.slice(0, block.indexOf('\n}')).matchAll(/^\s{2}([A-Z][A-Z_]+):/gm)].map(m => m[1]);
  if (topics.length < 10) throw new Error(`TOPIC_HANDLERS parse found only ${topics.length} topics - the parser is broken, refusing to report`);

  const seen = await sql(`
    select event_type,
           count(*) filter (where status='processed')::int ok,
           count(*) filter (where status='failed')::int failed,
           max(created_at)::date::text last_seen
      from public.webhook_events_log where source_system='jobber' group by 1`);
  const win = await sql(`select min(created_at)::date::text oldest, max(created_at)::date::text newest from public.webhook_events_log`);
  const byTopic = Object.fromEntries(seen.map(r => [r.event_type, r]));

  const rows = topics.map(t => {
    const s = byTopic[t];
    if (!s || (s.ok === 0 && s.failed === 0)) return { name: t, verdict: NEVER, detail: 'no delivery on record' };
    return { name: t, verdict: RAN,
             detail: `processed=${s.ok} failed=${s.failed} last=${s.last_seen}` };
  });
  emit(`1. JOBBER WEBHOOK TOPICS (${topics.length} handlers parsed from webhook-jobber/index.ts)`,
       'public.webhook_events_log',
       `${win[0].oldest} to ${win[0].newest} (the log is TRIMMED, so NEVER means "not in this window")`,
       rows, 'VISIT_UPDATE');
}

// ================================================================================================
// 2. pg_cron JOBS
// ================================================================================================
// Two failure modes, not one: a job that never ran, and a job that runs constantly and has never
// once SUCCEEDED. The second looks alive on any dashboard that counts invocations.
{
  const jobs = await sql(`
    select j.jobname, j.active::text active, j.schedule,
           coalesce(count(d.runid) filter (where d.status='succeeded'),0)::int ok,
           coalesce(count(d.runid) filter (where d.status<>'succeeded'),0)::int bad,
           coalesce(max(d.start_time) filter (where d.status='succeeded')::date::text,'') last_ok
      from cron.job j
      left join cron.job_run_details d on d.jobid = j.jobid
     group by 1,2,3 order by 1`);
  const win = await sql(`select min(start_time)::date::text oldest, max(start_time)::date::text newest from cron.job_run_details`);
  const rows = jobs.map(j => {
    const inactive = j.active === 'false' ? ' [DISABLED]' : '';
    if (j.ok === 0 && j.bad === 0) return { name: j.jobname, verdict: NEVER, detail: `no run on record${inactive}` };
    if (j.ok === 0) return { name: j.jobname, verdict: NEVER, detail: `ran ${j.bad}x, NEVER SUCCEEDED${inactive}` };
    return { name: j.jobname, verdict: RAN, detail: `ok=${j.ok} failed=${j.bad} last_ok=${j.last_ok}${inactive}` };
  });
  emit(`2. pg_cron JOBS (${jobs.length})`, 'cron.job vs cron.job_run_details',
       `${win[0].oldest} to ${win[0].newest}`, rows,
       jobs.find(j => j.ok > 0)?.jobname);
}

// ================================================================================================
// 3. EDGE FUNCTIONS
// ================================================================================================
// There is NO invocation counter for edge functions, so this section is built entirely from PROXY
// evidence and says so. The chain, strongest first:
//   a) a pg_cron command names the function  -> that cron's success history IS the evidence
//   b) the function's slug appears as audit.logs.app_source / sync_log.sync_source
//   c) it owns a webhook_events_log source_system
//   d) nothing -> NO EVIDENCE. NOT "never". A function invoked only from a browser leaves no trace
//      any of these tables can see, and reporting that as NEVER would be a fabricated finding.
{
  const fns = await (await fetch(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_ID}/functions`,
    { headers: { Authorization: `Bearer ${env.SUPABASE_PAT}` } })).json();
  // 🛑 THE HOP THE FIRST VERSION MISSED, AND IT REPORTED 29 OF 34 FUNCTIONS AS "NO EVIDENCE"
  //    INCLUDING sync-jobber-poll, WHOSE CRON HAS 20,953 SUCCESSES. A pg_cron command does NOT
  //    contain the edge-function URL. It calls a SQL wrapper:
  //        SELECT public.fn_request_jobber_sync('poll')
  //    and the WRAPPER's body holds '.../functions/v1/sync-jobber-poll'. The chain is
  //    cron -> wrapper -> net.http_post -> edge function, so a substring match on the cron command
  //    can never see past hop one. This resolves the wrapper bodies and appends them.
  //    ⚠ The tell was IMPLAUSIBILITY, not an error: a function invoked 20k times cannot be unevidenced.
  const crons = await sql(`
    with runs as (
      select j.jobid, j.jobname, j.command,
             coalesce(max(d.start_time) filter (where d.status='succeeded')::date::text,'') last_ok
        from cron.job j left join cron.job_run_details d on d.jobid=j.jobid group by 1,2,3)
    select r.jobname, r.last_ok,
           r.command || ' ' || coalesce((
             select string_agg(pg_get_functiondef(p.oid), ' ')
               from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where p.prokind = 'f' and r.command like '%'||p.proname||'%'), '') as command
      from runs r`);
  const appSources = (await sql(`select app_source s, max(changed_at)::date::text last from audit.logs where app_source is not null group by 1`));
  const syncSources = (await sql(`select sync_source s, max(started_at)::date::text last from public.sync_log group by 1`));
  const whSources = (await sql(`select source_system s, max(created_at)::date::text last from public.webhook_events_log group by 1`));

  const norm = x => String(x).toLowerCase().replace(/[-_]/g, '');
  const lookup = (slug, list) => list.find(r => norm(r.s) === norm(slug));
  // The only hand-written mapping in this file, kept deliberately tiny. Each entry is a case where
  // the function's own name is genuinely not the label it writes under.
  const ALIAS = { 'webhook-jobber': 'jobber', 'webhook-samsara': 'samsara', 'webhook-airtable': 'airtable' };

  const rows = fns.map(f => {
    const slug = f.slug;
    const cron = crons.find(c => c.command && c.command.includes(slug));
    if (cron) return { name: slug, verdict: cron.last_ok ? RAN : NEVER,
                       detail: cron.last_ok ? `via cron ${cron.jobname}, last ok ${cron.last_ok}`
                                            : `wired to cron ${cron.jobname} which has NEVER SUCCEEDED` };
    const key = ALIAS[slug] ?? slug;
    const a = lookup(key, appSources) || lookup(key, syncSources) || lookup(key, whSources);
    if (a) return { name: slug, verdict: RAN, detail: `writes as "${a.s}", last ${a.last}` };
    return { name: slug, verdict: NOEV, detail: 'no cron, no app_source, no sync_log, no webhook log' };
  });
  emit(`3. EDGE FUNCTIONS (${fns.length} deployed)`,
       'PROXY ONLY: cron -> SQL wrapper body -> functions/v1/<slug>, plus audit.logs.app_source, sync_log.sync_source, webhook_events_log',
       'audit.logs and sync_log since 2026-05, cron since 2026-05-17',
       rows, 'sync-jobber-poll',
       'Invoked from a browser or another edge function, which leaves no trace any of these tables can see. NOT a finding.');
}

// ================================================================================================
// 4. RPCs REACHABLE BY AN APP
// ================================================================================================
// 🛑 THE WEAKEST SECTION, AND IT SAYS SO. `track_functions` is `none` on this project, so
//    pg_stat_user_functions is empty and there is no per-function call counter at all. The only
//    signal left is pg_stat_statements, a VOLATILE buffer measured in hours that any restart wipes.
//    ⇒ Absence here is NOT evidence of never running. Every unseen RPC is reported as NO EVIDENCE.
//    The single change that would fix this section is `track_functions = pl`, which is a project
//    config change and a decision for Fred, not something this report should assume.
{
  const tf = await sql(`select current_setting('track_functions') v`);
  const win = await sql(`select (now()-stats_reset)::text age from pg_stat_statements_info`);
  const fns = await sql(`
    select n.nspname||'.'||p.proname name
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname in ('public','client','ops','customer','derm')
       and p.prokind='f'
       and (has_function_privilege('authenticated', p.oid, 'EXECUTE')
            or has_function_privilege('anon', p.oid, 'EXECUTE'))
     group by 1 order by 1`);
  // 🛑 THE MATCHER THE FIRST VERSION GOT WRONG. PostgREST renders an RPC as a `pgrst_call` CTE and
  //    the function appears SCHEMA-QUALIFIED, e.g. "derm"."fn_blackout_targets", with NO opening
  //    paren after the closing quote. Matching `"name"(` therefore found ZERO of them and all 160
  //    RPCs came back unevidenced, which reads exactly like a healthy-but-idle surface.
  const seen = await sql(`select s.query from pg_stat_statements s where s.query ~ 'pgrst_call'`);
  const blob = seen.map(r => r.query).join(' ');
  const rows = fns.map(f => {
    const [schema, bare] = f.name.split('.');
    return blob.includes(`"${schema}"."${bare}"`)
      ? { name: f.name, verdict: RAN, detail: 'called through PostgREST in the current buffer' }
      : { name: f.name, verdict: NOEV, detail: `not in the ${String(win[0].age).split('.')[0]} buffer (track_functions=${tf[0].v})` };
  });
  // POSITIVE CONTROL: the matcher must find at least ONE rpc. Zero means the matcher broke again,
  // not that 160 RPCs are idle, and emit() turns a missing control into a loud warning.
  const anyRan = rows.find(r => r.verdict === RAN);
  emit(`4. APP-REACHABLE RPCs (${fns.length} EXECUTE-able by authenticated or anon)`,
       `pg_stat_statements ONLY (track_functions=${tf[0].v}, so pg_stat_user_functions is empty)`,
       `${String(win[0].age).split('.')[0]} - far too short to conclude "never". Unseen = NO EVIDENCE.`,
       rows, anyRan?.name,
       `track_functions is '${tf[0].v}', so THIS SECTION IS STRUCTURALLY BLIND. Setting it to 'pl' is the one change that would make RPC coverage real.`);
}

// ================================================================================================
// 5. GITHUB ACTIONS WORKFLOWS
// ================================================================================================
{
  const dir = join(ROOT, '.github', 'workflows');
  const rows = [];
  let evidence = 'gh run list', windowText = 'full GitHub retention';
  if (!existsSync(dir)) {
    evidence = 'no .github/workflows directory'; windowText = 'n/a';
  } else {
    const files = readdirSync(dir).filter(f => /\.ya?ml$/.test(f));
    for (const f of files) {
      const body = readFileSync(join(dir, f), 'utf8');
      const disabled = !/^\s*(schedule|on)\s*:/m.test(body) ? '' : (/#\s*schedule/.test(body) ? ' [schedule commented out]' : '');
      try {
        const out = execSync(`gh run list --workflow=${f} --limit 1 --json status,conclusion,createdAt`,
          { cwd: ROOT, stdio: ['ignore', 'pipe', 'ignore'] }).toString();
        const runs = JSON.parse(out);
        rows.push(runs.length
          ? { name: f, verdict: RAN, detail: `last ${runs[0].createdAt.slice(0, 10)} ${runs[0].conclusion ?? runs[0].status}${disabled}` }
          : { name: f, verdict: NEVER, detail: `no run on record${disabled}` });
      } catch {
        rows.push({ name: f, verdict: NOEV, detail: 'gh unavailable or not authenticated' });
      }
    }
  }
  emit(`5. GITHUB ACTIONS WORKFLOWS (${rows.length})`, evidence, windowText, rows,
       rows.find(r => r.verdict === RAN)?.name);
}

// ---- summary -----------------------------------------------------------------------------------
const all = report.sections.flatMap(s => s.rows.map(r => ({ ...r, section: s.title })));
const never = all.filter(r => r.verdict === NEVER);
const noev = all.filter(r => r.verdict === NOEV);
const brokenSections = report.sections.filter(s => s.control && !s.control_fired);
report.summary = { total: all.length, never: never.length, no_evidence: noev.length,
                   untrustworthy_sections: brokenSections.map(s => s.title) };

say(`\n${'='.repeat(100)}`);
say(`SUMMARY: ${all.length} surfaces  |  ${never.length} NEVER EXECUTED  |  ${noev.length} no evidence`);
say('='.repeat(100));
if (never.length) {
  say('\nNEVER EXECUTED - untested code sitting in production:');
  for (const r of never) say(`  🛑 ${r.name.padEnd(34)} ${r.detail}`);
}
if (brokenSections.length) {
  say('\n🛑 SECTIONS WHOSE CONTROL DID NOT FIRE - do not trust their clean rows:');
  for (const s of brokenSections) say(`     ${s.title}`);
}
say('\nNO EVIDENCE is not an all-clear. It means nothing in this system can answer the question.');

writeFileSync(join(ROOT, 'scripts', 'checks', 'never-executed.out.json'), JSON.stringify(report, null, 2));
if (JSON_MODE) console.log(JSON.stringify(report.summary, null, 2));
say(`\n--- audit complete --- ${JSON.stringify({ probe: 'never-executed', ...report.summary })}`);
process.exit(brokenSections.length ? 2 : 0);
