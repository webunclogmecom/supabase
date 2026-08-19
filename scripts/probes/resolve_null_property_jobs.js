// READ-ONLY. Asks Jobber which property each NULL-property_id job actually sits on, and maps the
// answer back to our property id through entity_source_links. Writes a resolution file; writes
// NOTHING to the DB.
//
// 🛑 Jobber is the source of truth for jobs (CLAUDE.md rule 4). We do not guess the property from
//    the client, the address, or anything else: we ask, per job.
// 🛑 CONTENT-TYPE GUARD. Jobber sheds load with an HTML "waiting room" at HTTP 200, no errors array.
//    Without this check a shed request returns data:undefined and reads as "this job has no
//    property", which is exactly the false answer that would make a backfill wrong.
require('dotenv').config({ path: __dirname + '/../../.env' });
const fs = require('fs');
const { execSync } = require('child_process');

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
  try { return JSON.parse(t); } catch { throw new Error('SQL failed: ' + t.slice(0, 200)); }
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
  if (!('data' in j)) throw new Error('Jobber reply carried no data key: ' + JSON.stringify(j).slice(0, 200));
  return j;
}

(async () => {
  const jobs = await sql(`
    select j.id, j.job_number, j.title, j.job_status, j.client_id,
           (select e.source_id from entity_source_links e
             where e.entity_type='job' and e.entity_id=j.id and e.source_system='jobber') as job_gid
      from jobs j
     where j.property_id is null
     order by (j.job_status not in ('archived','closed','destroyed')) desc, j.id`);

  // our property id for a Jobber property GID
  const links = await sql(`select source_id, entity_id from entity_source_links
                            where entity_type='property' and source_system='jobber'`);
  const byGid = new Map(links.map(l => [String(l.source_id), Number(l.entity_id)]));

  const out = [];
  for (const j of jobs) {
    const live = !['archived', 'closed', 'destroyed'].includes(String(j.job_status));
    if (!j.job_gid) { out.push({ ...j, live, verdict: 'NO_JOBBER_LINK' }); continue; }
    let res;
    try { res = await gql(`query($id: EncodedId!){ job(id:$id){ id jobNumber jobStatus property { id } client { id } } }`, { id: j.job_gid }); }
    catch (e) { out.push({ ...j, live, verdict: 'JOBBER_UNREADABLE', detail: String(e.message) }); continue; }

    const job = res.data?.job;
    if (!job) { out.push({ ...j, live, verdict: 'NOT_IN_JOBBER' }); continue; }
    const propGid = job.property?.id ?? null;
    if (!propGid) { out.push({ ...j, live, verdict: 'NO_PROPERTY_IN_JOBBER' }); continue; }
    const ourProp = byGid.get(String(propGid));
    out.push({
      ...j, live, jobber_property_gid: propGid,
      resolved_property_id: ourProp ?? null,
      verdict: ourProp ? 'RESOLVED' : 'PROPERTY_NOT_LINKED_HERE',
    });
    await new Promise(r => setTimeout(r, 120)); // be polite to the API
  }

  fs.writeFileSync(__dirname + '/resolve_null_property_jobs.out.json', JSON.stringify(out, null, 1));

  const by = {};
  for (const o of out) by[o.verdict] = (by[o.verdict] || 0) + 1;
  console.log('jobs examined:', out.length);
  console.log('verdicts:', JSON.stringify(by));
  console.log('\nLIVE jobs:');
  for (const o of out.filter(x => x.live)) {
    console.log(` job ${o.id} #${o.job_number} "${o.title}" [${o.job_status}] client ${o.client_id} -> ${o.verdict}` +
      (o.resolved_property_id ? ` property ${o.resolved_property_id}` : ''));
  }
  const resolvable = out.filter(o => o.verdict === 'RESOLVED');
  console.log(`\nRESOLVED total: ${resolvable.length} (live: ${resolvable.filter(o => o.live).length})`);
})();
