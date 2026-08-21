// FULL AUDIT of the property estate against Jobber, run BEFORE deciding whether an orphan
// reconciler is needed (Fred, 2026-08-21: "do a full audit first to make sure you need that or if
// you need more").
//
// 🛑 THE FINDING THAT MAKES A NAIVE DIFF DANGEROUS, AND IT IS MEASURED, NOT ASSUMED:
//    public.properties holds TWO different kinds of row and they link to DIFFERENT Jobber objects.
//      service properties (464 live) -> entity_source_links.source_id is a Jobber PROPERTY gid
//      billing properties  (432 live) -> source_id is the client's gid with a literal '_billing'
//                                        SUFFIX, e.g. 'Z2lk...OTE1OTI3NzA=_billing'. It is a
//                                        SYNTHETIC key: Jobber models a billing address as part of
//                                        the Client, not as a Property, so there is no Property gid
//                                        to store and the suffix keeps it from colliding with the
//                                        client's own link row.
//    A reconciler that diffed all 898 links against Jobber's property list would find every billing
//    row "missing from Jobber" and retire all 432 of them. So the two halves are audited SEPARATELY
//    and the service/billing split is asserted at the top as a control.
//
// 🛑 AND THE FIRST RUN OF THIS PROBE GOT THE BILLING HALF WRONG, WHICH IS THE MORE USEFUL LESSON.
//    It compared '<clientGid>_billing' against Jobber's '<clientGid>' and reported 432 of 432
//    billing rows as "client gone from Jobber". A 100% failure rate is the signature of a broken
//    comparison, not of broken data. Worse, the diagnostic that was supposed to check it made the
//    bug INVISIBLE: base64-decoding the value prints 'gid://Jobber/Client/91592770' cleanly, because
//    the decoder stops at the '==' padding and silently discards the '_billing' bytes that were the
//    entire point. ⇒ Compare RAW stored bytes; decode only to read, never to compare.
//
// Read-only. Writes nothing. Emits JSON to scripts/probes/property_estate_audit.out.json.
//
// Run:
//   cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase"
//   JT=$(cd ../Slack && ./jobber-token.sh) node scripts/probes/property_estate_audit.mjs
import { readFileSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const env = Object.fromEntries(readFileSync(join(ROOT, '.env'), 'utf8').split(/\r?\n/)
  .filter(l => /^[A-Z_]+=/.test(l))
  .map(l => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '').trim()]));
const JT = process.env.JT;
if (!JT) { console.error('JT (jobber token) not set. Use: JT=$(cd ../Slack && ./jobber-token.sh) node ...'); process.exit(2); }

const GQL_VERSION = '2026-04-16';

async function sql(q) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_ID}/database/query`, {
    method: 'POST', headers: { Authorization: `Bearer ${env.SUPABASE_PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: q }) });
  const t = await r.text();
  let j; try { j = JSON.parse(t); } catch { throw new Error(`non-JSON from mgmt API: ${t.slice(0, 200)}`); }
  if (!Array.isArray(j)) throw new Error(`mgmt API error: ${t.slice(0, 300)}`);
  return j;
}

// 🛑 CONTENT-TYPE GUARD. Jobber sheds load with an HTML "waiting room" at HTTP 200 and no errors
//    array, so status and shape both say success. See Supabase/CLAUDE.md.
async function gql(query, variables = {}) {
  const r = await fetch('https://api.getjobber.com/api/graphql', {
    method: 'POST',
    headers: { Authorization: `Bearer ${JT}`, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': GQL_VERSION },
    body: JSON.stringify({ query, variables }),
  });
  const ctype = r.headers.get('content-type') ?? '';
  if (!ctype.includes('json')) throw new Error(`Jobber returned ${ctype} at HTTP ${r.status} (waiting room?)`);
  const j = await r.json();
  if (j.errors?.length) throw new Error(`GraphQL: ${JSON.stringify(j.errors[0]).slice(0, 300)}`);
  if (!('data' in j)) throw new Error('Jobber reply carried no data key');
  return j.data;
}

async function pullAll(name, fields) {
  const out = [];
  let after = null, page = 0;
  while (page++ < 200) {
    const q = `query P($after:String,$first:Int!){ ${name}(after:$after, first:$first){ pageInfo{hasNextPage endCursor} nodes{ ${fields} } } }`;
    const d = await gql(q, { after, first: 100 });
    const conn = d[name];
    if (!conn) throw new Error(`no ${name} connection in reply`);
    out.push(...conn.nodes);
    if (!conn.pageInfo.hasNextPage) break;
    after = conn.pageInfo.endCursor;
  }
  return out;
}

const report = { generated_at: new Date().toISOString(), checks: [], findings: {} };
const check = (name, pass, evidence) => {
  report.checks.push({ name, pass, evidence: String(evidence) });
  console.log(`  ${(pass ? 'PASS' : 'FAIL').padEnd(5)} ${name.padEnd(62)} ${evidence}`);
};

// ============================================================================================
console.log('\n=== 0. CONTROL: the two link kinds are really different objects ===');
// ============================================================================================
const split = await sql(`
  select p.is_billing::text bill, (p.deleted_at is null)::text live,
         case when l.source_id is null then 'none'
              when l.source_id like 'Z2lkOi8vSm9iYmVyL1Byb3BlcnR5%' then 'property'
              when l.source_id like 'Z2lkOi8vSm9iYmVyL0NsaWVudC%'   then 'client'
              else 'other' end kind,
         count(*)::int n
    from public.properties p
    left join public.entity_source_links l
      on l.entity_type='property' and l.source_system='jobber' and l.entity_id=p.id
   group by 1,2,3`);
report.findings.link_kinds = split;
const billingOnClientGid = split.filter(r => r.bill === 'true' && r.kind === 'property').reduce((a, r) => a + r.n, 0);
const serviceOnClientGid = split.filter(r => r.bill === 'false' && r.kind === 'client').reduce((a, r) => a + r.n, 0);
check('billing rows NEVER carry a Jobber Property gid', billingOnClientGid === 0, `billing-with-property-gid=${billingOnClientGid}`);
const suffix = await sql(`
  select count(*) filter (where l.source_id like '%\_billing')::int with_suffix,
         count(*)::int total
    from public.entity_source_links l join public.properties p on p.id = l.entity_id
   where l.entity_type='property' and l.source_system='jobber' and p.is_billing`);
check('EVERY billing link carries the _billing suffix', suffix[0].with_suffix === suffix[0].total,
      `${suffix[0].with_suffix}/${suffix[0].total} suffixed`);
check('service rows NEVER carry a Jobber Client gid', serviceOnClientGid === 0, `service-with-client-gid=${serviceOnClientGid}`);
const other = split.filter(r => r.kind === 'other').reduce((a, r) => a + r.n, 0);
check('CONTROL: no link points at an unexpected Jobber object', other === 0, `other-kind links=${other}`);

// ============================================================================================
console.log('\n=== 1. Pull the live Jobber estate ===');
// ============================================================================================
const jProps = await pullAll('properties', 'id client { id } address { street city province postalCode }');
const jClients = await pullAll('clients', 'id isArchived companyName firstName lastName');
const jPropIds = new Set(jProps.map(p => p.id));
const jClientIds = new Set(jClients.map(c => c.id));
const jArchived = new Set(jClients.filter(c => c.isArchived).map(c => c.id));
report.findings.jobber = { properties: jProps.length, clients: jClients.length, archived_clients: jArchived.size };
console.log(`  Jobber: ${jProps.length} properties, ${jClients.length} clients (${jArchived.size} archived)`);
check('CONTROL: the Jobber sweep returned a plausible estate', jProps.length > 300 && jClients.length > 300,
      `${jProps.length} properties / ${jClients.length} clients`);

// ============================================================================================
console.log('\n=== 2. SERVICE properties: which of ours no longer exist in Jobber ===');
// ============================================================================================
const ours = await sql(`
  select p.id::int id, p.client_id::int client_id, c.client_code, c.name client_name, c.status client_status,
         coalesce(p.address,'') address, p.deleted_at::text deleted_at, p.created_at::text created_at,
         l.source_id
    from public.properties p
    join public.clients c on c.id = p.client_id
    left join public.entity_source_links l
      on l.entity_type='property' and l.source_system='jobber' and l.entity_id=p.id
   where not p.is_billing`);
const liveService = ours.filter(r => !r.deleted_at);
const orphans = liveService.filter(r => r.source_id && !jPropIds.has(r.source_id));
const unlinked = liveService.filter(r => !r.source_id);
report.findings.service = {
  live: liveService.length, orphans: orphans.length, unlinked: unlinked.length,
  orphan_rows: orphans.map(o => ({ id: o.id, client: o.client_code, address: o.address, created_at: o.created_at })),
  unlinked_rows: unlinked.map(o => ({ id: o.id, client: o.client_code, address: o.address, created_at: o.created_at })),
};
console.log(`  live service properties: ${liveService.length}`);
console.log(`  ORPHANS (linked, absent from Jobber): ${orphans.length}`);
for (const o of orphans) console.log(`     ${o.id}  ${String(o.client_code ?? '?').padEnd(9)} ${String(o.address ?? '').slice(0, 46)}`);
console.log(`  UNLINKED (no jobber link at all): ${unlinked.length}`);
for (const o of unlinked) console.log(`     ${o.id}  ${String(o.client_code ?? '?').padEnd(9)} ${String(o.address ?? '').slice(0, 46)}`);

// ============================================================================================
console.log('\n=== 3. The inverse: Jobber properties we do not hold ===');
// ============================================================================================
const ourPropGids = new Set(ours.filter(r => r.source_id).map(r => r.source_id));
const missing = jProps.filter(p => !ourPropGids.has(p.id));
report.findings.missing_from_us = {
  count: missing.length,
  on_archived_client: missing.filter(p => jArchived.has(p.client?.id)).length,
  sample: missing.slice(0, 25).map(p => ({ gid: p.id, client: p.client?.id, address: [p.address?.street, p.address?.city].filter(Boolean).join(', ') })),
};
console.log(`  Jobber properties with no row here: ${missing.length} (${report.findings.missing_from_us.on_archived_client} on archived clients)`);

// ============================================================================================
console.log('\n=== 4. BILLING properties: audited against CLIENTS, not properties ===');
// ============================================================================================
const billing = await sql(`
  select p.id::int id, c.client_code, c.status client_status, p.deleted_at::text deleted_at, l.source_id
    from public.properties p
    join public.clients c on c.id = p.client_id
    left join public.entity_source_links l
      on l.entity_type='property' and l.source_system='jobber' and l.entity_id=p.id
   where p.is_billing`);
const liveBilling = billing.filter(r => !r.deleted_at);
// ⚠ STRIP THE SUFFIX. Comparing the stored value directly is what produced the false 432.
const baseGid = s => s ? s.replace(/_billing$/, '') : null;
const billingGone = liveBilling.filter(r => r.source_id && !jClientIds.has(baseGid(r.source_id)));
const billingArchived = liveBilling.filter(r => r.source_id && jArchived.has(baseGid(r.source_id)));
report.findings.billing = {
  live: liveBilling.length, client_gone_from_jobber: billingGone.length,
  client_archived_in_jobber: billingArchived.length,
  unlinked: liveBilling.filter(r => !r.source_id).length,
  gone_rows: billingGone.map(b => ({ id: b.id, client: b.client_code, status: b.client_status })),
};
console.log(`  live billing rows: ${liveBilling.length}`);
console.log(`  their client is GONE from Jobber: ${billingGone.length}`);
console.log(`  their client is ARCHIVED in Jobber: ${billingArchived.length}`);
console.log(`  no link at all: ${report.findings.billing.unlinked}`);
// CONTROL: the vast majority of billing rows MUST resolve to a live Jobber client. If this ever
// reports near-total loss again, suspect the comparison before believing the data.
check('billing rows overwhelmingly resolve to a live Jobber client',
      billingGone.length < liveBilling.length * 0.05,
      `${liveBilling.length - billingGone.length}/${liveBilling.length} resolve`);

// ============================================================================================
console.log('\n=== 5. Blast radius: what still references each orphan ===');
// ============================================================================================
if (orphans.length) {
  const ids = orphans.map(o => o.id).join(',');
  const radius = await sql(`
    select p.id::int id,
           (select count(*) from public.jobs   j where j.property_id = p.id)::int jobs,
           (select count(*) from public.jobs   j where j.property_id = p.id
              and j.job_status not in ('archived','closed','destroyed'))::int jobs_open,
           (select count(*) from public.visits v where v.property_id = p.id and v.deleted_at is null)::int visits,
           (select count(*) from public.visits v where v.property_id = p.id and v.deleted_at is null
              and v.visit_status not in ('completed','cancelled'))::int visits_pending,
           (select count(*) from public.gdos g where g.property_id = p.id)::int gdos,
           (select count(*) from public.client_locations cl where cl.property_id = p.id)::int client_locations,
           (select count(*) from public.service_configs sc where sc.property_id = p.id)::int service_configs
      from public.properties p where p.id in (${ids}) order by p.id`);
  report.findings.orphan_blast_radius = radius;
  for (const r of radius) console.log(`     ${String(r.id).padEnd(5)} jobs=${r.jobs} (open ${r.jobs_open})  visits=${r.visits} (pending ${r.visits_pending})  gdos=${r.gdos}  locations=${r.client_locations}  configs=${r.service_configs}`);
  const scheduled = radius.reduce((a, r) => a + r.visits_pending, 0);
  check('no orphan has PENDING visits still scheduled on it', scheduled === 0, `pending visits on orphans=${scheduled}`);
} else {
  check('no orphan has PENDING visits still scheduled on it', true, 'no orphans');
}

// ============================================================================================
console.log('\n=== 6. Link integrity ===');
// ============================================================================================
const dupes = await sql(`
  select 'two properties share one jobber gid' as issue, count(*)::int n from (
    select source_id from public.entity_source_links
     where entity_type='property' and source_system='jobber'
     group by source_id having count(*) > 1) x
  union all
  select 'one property carries two jobber links', count(*)::int from (
    select entity_id from public.entity_source_links
     where entity_type='property' and source_system='jobber'
     group by entity_id having count(*) > 1) y
  union all
  select 'link points at a property row that no longer exists', count(*)::int
    from public.entity_source_links l
   where l.entity_type='property' and l.source_system='jobber'
     and not exists (select 1 from public.properties p where p.id = l.entity_id)`);
report.findings.link_integrity = dupes;
for (const d of dupes) check(`link integrity: ${d.issue}`, d.n === 0, `n=${d.n}`);

// ============================================================================================
console.log('\n=== 7. Would the DESTROY handler ever hit a billing row? ===');
// ============================================================================================
// handlePropertyDestroy looks up by entity_source_links source_id. Billing rows carry CLIENT gids,
// so a PROPERTY_DESTROY payload cannot match one. Assert that rather than assume it.
const crossable = await sql(`
  select count(*)::int n from public.entity_source_links l
   join public.properties p on p.id = l.entity_id
  where l.entity_type='property' and l.source_system='jobber' and p.is_billing
    and l.source_id like 'Z2lkOi8vSm9iYmVyL1Byb3BlcnR5%'`);
check('PROPERTY_DESTROY can never resolve to a billing row', crossable[0].n === 0, `billing rows reachable by a Property gid=${crossable[0].n}`);

// ---- write + summarise ----------------------------------------------------------------------
writeFileSync(join(ROOT, 'scripts', 'probes', 'property_estate_audit.out.json'), JSON.stringify(report, null, 2));
const failed = report.checks.filter(c => !c.pass);
console.log(`\n${report.checks.filter(c => c.pass).length}/${report.checks.length} checks passed`);
if (failed.length) { console.log('\nFAILURES:'); for (const f of failed) console.log(`  ${f.name} -> ${f.evidence}`); }
console.log('\n--- audit complete --- ' + JSON.stringify({
  probe: 'property_estate_audit',
  orphans: orphans.length, unlinked_service: unlinked.length,
  missing_from_us: missing.length, billing_client_gone: billingGone.length,
}));
