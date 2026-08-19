// Rolled-back dry run of the jobs.property_id backfill, with a positive control that MUST fire.
//
// The control: a job that ALREADY has a property_id is included in the VALUES list pointed at a
// deliberately WRONG property. The statement's `and j.property_id is null` predicate must refuse to
// touch it. If that row changes, the guard is missing and the real run would corrupt correct data.
// A dry run that only shows the intended rows changing proves the statement works, never that it is
// safe.
require('dotenv').config({ path: __dirname + '/../../.env' });
const fs = require('fs');

async function sql(query) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query }),
  });
  const t = await r.text();
  try { return JSON.parse(t); } catch { throw new Error('SQL failed: ' + t.slice(0, 300)); }
}

(async () => {
  const resolved = JSON.parse(fs.readFileSync(__dirname + '/resolve_null_property_jobs.out.json', 'utf8'))
    .filter(o => o.verdict === 'RESOLVED');
  if (!resolved.length) throw new Error('nothing resolved - run resolve_null_property_jobs.js first');

  // the control row: a job that already HAS a property, aimed at the wrong one
  const [ctl] = await sql(`select id, property_id from jobs where property_id is not null order by id limit 1`);
  // ⚠ The wrong property must EXIST. property_id carries a foreign key, so aiming the control at a
  // non-existent id makes the mutated run abort on the FK instead of exercising the guard, and the
  // control then "fails" for the wrong reason. Measured: property 1 does not exist; min(id) is 2.
  const [alt] = await sql(`select id from properties where id <> ${Number(ctl.property_id)} order by id limit 1`);
  const wrongProp = Number(alt.id);

  const values = resolved.map(o => `(${o.id}, ${o.resolved_property_id})`).join(', ');
  const q = `
begin;
update public.jobs j
   set property_id = v.prop
  from (values ${values}, (${ctl.id}, ${wrongProp})) as v(job, prop)
 where j.id = v.job
   and j.property_id is null;

select
  (select count(*) from jobs where id in (${resolved.map(o => o.id).join(',')}) and property_id is not null)::text as intended_now_set,
  (select count(*) from jobs where id in (${resolved.map(o => o.id).join(',')}) and property_id is null)::text as intended_still_null,
  (select property_id from jobs where id = ${ctl.id})::text as control_property_id,
  (select count(*) from jobs j join (values ${values}) as v(job,prop) on v.job=j.id where j.property_id = v.prop)::text as landed_on_right_property,
  (select count(*) from jobs where property_id is null)::text as remaining_null_overall;
rollback;`;

  const rows = await sql(q);
  const r = Array.isArray(rows) ? rows[0] : rows;
  const expectedControl = String(ctl.property_id);

  const checks = [
    { name: `all ${resolved.length} intended rows got a property`, pass: r.intended_now_set === String(resolved.length), got: r.intended_now_set },
    { name: 'no intended row left NULL', pass: r.intended_still_null === '0', got: r.intended_still_null },
    { name: 'every row landed on the property JOBBER named', pass: r.landed_on_right_property === String(resolved.length), got: r.landed_on_right_property },
    { name: `CONTROL: job ${ctl.id} (already had a property) was NOT touched`, pass: r.control_property_id === expectedControl, got: `${r.control_property_id} (expected ${expectedControl})` },
  ];
  for (const c of checks) console.log((c.pass ? 'PASS' : 'FAIL').padEnd(5), c.name, '|', c.got);
  console.log('\nremaining NULL property_id after the (rolled back) run:', r.remaining_null_overall,
    `-> ${57 - resolved.length} would remain, all of them unresolvable`);

  const after = await sql(`select count(*)::text as n from jobs where property_id is null`);
  console.log('rollback confirmed, live NULL count still:', after[0].n);
  process.exit(checks.every(c => c.pass) ? 0 : 1);
})();
