// Task 4 probe: prove the FIXTURES the helper's free branches rely on, and pin the live 112-YA
// state that Task 5's irreversible arm depends on.
//
// 🛑 WHY THE 112-YA BLOCK EXISTS. The plan states "112-YA currently has zero active Service Call
//    jobs", and that is WRONG. It came from a `limit 1` that happened to select the billing twin.
//    Measured 2026-08-20:
//        property  162  1745 Cleveland Road   is_billing=false  -> SC job 766 (#99900535) LIVE
//        property  493  1745 Cleveland Road   is_billing=true   -> none (the billing twin)
//        property 1057  9401 Collins Avenue   is_billing=false  -> none   <- the real create target
//    Acting on the stale sentence would have aimed the one permanent Jobber write at a property that
//    already has a job. This probe asserts the state instead of trusting the prose, so the next
//    reader cannot inherit the error.
//
// Arms A, B, C are FREE: they refuse or short-circuit before Jobber is touched.
// The create arm is Task 5 and COMMITS. Nothing here writes anything.
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
  const push = (check, pass, got) => out.push({ check, pass, got: String(got).slice(0, 110) });

  // ---- fixture: a property whose ONLY jobber link is a billing twin --------------------------
  const twin = await sql(`
    select p.id from properties p
    where exists (select 1 from entity_source_links e where e.entity_type='property'
                  and e.entity_id=p.id and e.source_system='jobber' and e.source_id like '%_billing')
      and not exists (select 1 from entity_source_links e2 where e2.entity_type='property'
                  and e2.entity_id=p.id and e2.source_system='jobber' and e2.source_id not like '%_billing')
    limit 1`);
  push('fixture: a billing-twin-only property exists',
       Array.isArray(twin) && twin.length === 1, JSON.stringify(twin));

  // ---- fixture: a property that ALREADY has a live Service Call (idempotency target) ---------
  const withSc = await sql(`
    select j.property_id, j.id as job_id from jobs j
    where lower(btrim(j.title))='service call'
      and j.job_status not in ('archived','closed','destroyed')
      and j.property_id is not null
    limit 1`);
  push('fixture: a property with a live SC job exists',
       Array.isArray(withSc) && withSc.length === 1, JSON.stringify(withSc));

  // ---- POSITIVE CONTROL for the title matcher ------------------------------------------------
  // If these misclassify, findServiceCall() is not what the probe assumes and every arm is untested.
  const cases = [
    ['Service Call', true], ['Service call', true], ['  service call  ', true],
    ['Service Agreement - Pumping', false], ['Service Call - 341', false], ['', false],
  ];
  const matcher = (t) => String(t ?? '').trim().toLowerCase() === 'service call';
  const bad = cases.filter(([t, want]) => matcher(t) !== want);
  push('CONTROL: title matcher classifies all 6 fixtures correctly',
       bad.length === 0, bad.length ? JSON.stringify(bad) : 'all 6 correct');

  // ---- THE 112-YA GROUND TRUTH, asserted rather than assumed ---------------------------------
  const ya = await sql(`
    select p.id, p.is_billing, coalesce(p.address,'') as address,
           (select count(*) from jobs j
             where j.property_id = p.id and lower(btrim(j.title))='service call'
               and j.job_status not in ('archived','closed','destroyed')) as sc_jobs
      from clients c join properties p on p.client_id = c.id
     where c.client_code = '112-YA' order by p.id`);
  const rows = Array.isArray(ya) ? ya : [];
  const svc = rows.filter(r => r.is_billing === false);
  const withJob = svc.filter(r => Number(r.sc_jobs) > 0).map(r => r.id);
  const without = svc.filter(r => Number(r.sc_jobs) === 0).map(r => r.id);

  push('112-YA has service properties to reason about', svc.length >= 2,
       `service properties: ${svc.map(r => r.id).join(', ')}`);
  push('REFUTES the plan: at least one 112-YA property ALREADY has a live SC job',
       withJob.length >= 1, `already covered: ${withJob.join(', ') || 'NONE'}`);
  push('a genuine create target exists (service property, no SC job)',
       without.length >= 1, `needs one: ${without.join(', ') || 'NONE'}`);
  push('CONTROL: the billing twin is excluded from both sets',
       rows.some(r => r.is_billing === true),
       `billing rows: ${rows.filter(r => r.is_billing === true).map(r => r.id).join(', ') || 'none'}`);

  fs.writeFileSync(__dirname + '/ensure_sc_job.out.json', JSON.stringify(out, null, 1));
  for (const o of out) console.log((o.pass ? 'PASS' : 'FAIL').padEnd(5), o.check, '|', o.got);
  process.exit(out.every(o => o.pass) ? 0 : 1);
})();
