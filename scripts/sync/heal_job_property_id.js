// Self-healing sweep for public.jobs.property_id.
//
// DRY RUN BY DEFAULT. Pass --execute to write.
//
// 🛑 WHY THIS EXISTS AND WHY IT IS NOT A handleJob FIX. jobs.property_id is set by handleJob only
//    when the property is already linked at import time. That assignment is CORRECT; the problem is
//    that it never runs again. sync-jobber-poll pages jobs on CURSOR_FIELD.jobs = 'createdAt', so a
//    job is never re-pulled once it is behind the cursor, and a property that gets linked later
//    (the hourly property sweep runs on its own schedule) can never reach the job row.
//    ⚠ Switching that cursor to updatedAt would NOT fix it either: linking a property is OUR event,
//      not a Jobber edit, so Jobber's updatedAt does not move. Nothing upstream signals it. That is
//      why a local heal is the right shape.
//
// 🛑 IT ASKS JOBBER, PER JOB. The property is never inferred from the client, the address, the
//    client's other properties, or the job's visits. Jobber owns jobs (CLAUDE.md rule 4).
//
// 🛑 CONTENT-TYPE GUARD. Jobber sheds load with an HTML waiting room at HTTP 200 and no errors
//    array. Unguarded, that reads as "this job has no property", which would be a silent wrong
//    answer feeding a write.
//
// SAFE TO RE-RUN: the UPDATE re-asserts `property_id is null`, so it cannot fire on a row that has
// since been filled, and public.jobs is audited, so every change keeps its old_row.
require('dotenv').config({ path: __dirname + '/../../.env' });
const { execSync } = require('child_process');

const EXECUTE = process.argv.includes('--execute');
const TERMINAL = ['archived', 'closed', 'destroyed'];

const token = (process.env.JOBBER_TOKEN || '').trim() ||
  execSync('bash ./jobber-token.sh', { cwd: 'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Slack' }).toString().trim();
if (!token) { console.error('No Jobber token.'); process.exit(1); }

async function sql(query) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query }),
  });
  const t = await r.text();
  try { return JSON.parse(t); } catch { throw new Error('SQL failed: ' + t.slice(0, 300)); }
}

async function gql(query, variables) {
  const r = await fetch('https://api.getjobber.com/api/graphql', {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16' },
    body: JSON.stringify({ query, variables }),
  });
  const ctype = r.headers.get('content-type') ?? '';
  if (!ctype.includes('json')) throw new Error(`Jobber waiting room: ${ctype} at HTTP ${r.status}`);
  const j = await r.json();
  if (!('data' in j)) throw new Error('Jobber reply carried no data key');
  return j;
}

(async () => {
  const jobs = await sql(`
    select j.id, j.job_number, j.title, j.job_status,
           (select e.source_id from entity_source_links e
             where e.entity_type='job' and e.entity_id=j.id and e.source_system='jobber') as job_gid
      from jobs j
     where j.property_id is null
     order by (j.job_status not in (${TERMINAL.map(s => `'${s}'`).join(',')})) desc, j.id`);

  if (!jobs.length) { console.log('nothing to heal: no job carries a NULL property_id'); return; }

  const links = await sql(`select source_id, entity_id from entity_source_links
                            where entity_type='property' and source_system='jobber'`);
  const byGid = new Map(links.map(l => [String(l.source_id), Number(l.entity_id)]));

  const resolved = [];
  const skipped = [];
  let consecutiveFailures = 0;
  for (const j of jobs) {
    if (!j.job_gid) { skipped.push({ id: j.id, why: 'no jobber link' }); continue; }
    let res;
    try { res = await gql(`query($id: EncodedId!){ job(id:$id){ id property { id } } }`, { id: j.job_gid }); consecutiveFailures = 0; }
    catch (e) {
      skipped.push({ id: j.id, why: String(e.message).slice(0, 80) });
      // 🛑 CIRCUIT BREAKER. A real Jobber outage must stop the run, not walk the whole fleet
      //    reporting "unreadable" 57 times and burning the rate limit.
      if (++consecutiveFailures >= 10) { console.error('ABORTING: 10 consecutive Jobber failures'); process.exit(2); }
      continue;
    }
    const propGid = res.data?.job?.property?.id ?? null;
    if (!propGid) { skipped.push({ id: j.id, why: 'no property in Jobber' }); continue; }
    const ours = byGid.get(String(propGid));
    if (!ours) { skipped.push({ id: j.id, why: 'property not linked here' }); continue; }
    resolved.push({ id: j.id, prop: ours, live: !TERMINAL.includes(String(j.job_status)) });
    await new Promise(r => setTimeout(r, 120));
  }

  console.log(`${jobs.length} jobs with a NULL property_id | ${resolved.length} resolved (${resolved.filter(r => r.live).length} live) | ${skipped.length} skipped`);
  for (const s of skipped) console.log(`  skip job ${s.id}: ${s.why}`);

  if (!resolved.length) { console.log('nothing to write'); return; }
  if (!EXECUTE) {
    console.log('\nDRY RUN. Would set:');
    for (const r of resolved) console.log(`  job ${r.id} -> property ${r.prop}${r.live ? '  (LIVE)' : ''}`);
    console.log('\nRe-run with --execute to write.');
    return;
  }

  const values = resolved.map(r => `(${r.id}, ${r.prop})`).join(', ');
  await sql(`update public.jobs j set property_id = v.prop
               from (values ${values}) as v(job, prop)
              where j.id = v.job and j.property_id is null`);

  const [after] = await sql(`select count(*)::text as n from jobs j
     join (values ${values}) as v(job,prop) on v.job=j.id
    where j.property_id is distinct from v.prop`);
  if (after.n !== '0') { console.error(`VERIFY FAILED: ${after.n} rows are not on the property Jobber named`); process.exit(1); }
  console.log(`wrote ${resolved.length} rows; all verified against the property Jobber named`);
})();
