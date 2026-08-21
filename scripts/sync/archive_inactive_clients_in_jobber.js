// Archive, in Jobber, every client that is already INACTIVE here but still active there.
//
// WHY. Deactivating a client in the Client App writes public.clients.status='INACTIVE' and cleans up
// its future visits (soft-delete + Jobber push, via fn_clients_cleanup_sa_visits_on_status). It has
// never archived the CLIENT in Jobber. Measured 2026-08-21: 5 of 12 INACTIVE clients were still
// isArchived=false in Jobber, so ops working in Jobber still saw them as live.
//
// 🛑 THERE IS NO DELETE ON EITHER SIDE. Jobber exposes only clientArchive / clientUnarchive
//    (re-introspected live 2026-08-21: no clientDelete). Rule 6 forbids hard-deleting business data
//    here. "Delete a client" therefore means ARCHIVE in Jobber + INACTIVE here, and it is reversible
//    with clientUnarchive.
//
// SAFETY, and each of these exists because of a documented failure in this estate:
//  - DRY RUN BY DEFAULT. Pass --execute to write.
//  - IDEMPOTENT (rule 5): a client already archived in Jobber is skipped, not re-archived.
//  - THE PREDICATE IS RE-ASSERTED AT WRITE TIME, not captured minutes earlier: immediately before
//    each mutation it re-reads our status and Jobber's job list, so a client that was reactivated
//    while this ran cannot be archived anyway.
//  - REFUSES on open jobs. Jobber has no jobDelete; the only teardown is jobClose(DESTROY_ALL),
//    which destroys that job's visits. That is a decision for a person, never a side effect of a
//    tidy-up script.
//  - VERIFIES BY RE-READING. isArchived must come back true from a fresh query before the row is
//    counted as done. "The mutation returned no errors" is not evidence (feedback_split_transport_from_reaction).
//  - CONTENT-TYPE GUARD on every Jobber call: Jobber sheds load with an HTML waiting room at
//    HTTP 200 and no errors array, so status and shape both say success.
//
// Run:
//   cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase"
//   JT=$(cd ../Slack && ./jobber-token.sh) node scripts/sync/archive_inactive_clients_in_jobber.js
//   JT=$(cd ../Slack && ./jobber-token.sh) node scripts/sync/archive_inactive_clients_in_jobber.js --execute
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..', '..');
const env = Object.fromEntries(fs.readFileSync(path.join(ROOT, '.env'), 'utf8').split(/\r?\n/)
  .filter(l => /^[A-Z_]+=/.test(l))
  .map(l => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '').trim()]));
const JT = process.env.JT;
const EXECUTE = process.argv.includes('--execute');
if (!JT) { console.error('JT not set. Use: JT=$(cd ../Slack && ./jobber-token.sh) node ...'); process.exit(2); }

const TERMINAL = new Set(['archived', 'closed', 'destroyed']);

async function sql(q) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_ID}/database/query`, {
    method: 'POST', headers: { Authorization: `Bearer ${env.SUPABASE_PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: q }) });
  const t = await r.text();
  let j; try { j = JSON.parse(t); } catch { throw new Error(`non-JSON from mgmt API: ${t.slice(0, 200)}`); }
  if (!Array.isArray(j)) throw new Error(`mgmt API error: ${t.slice(0, 300)}`);
  return j;
}

async function gql(query, variables = {}) {
  const r = await fetch('https://api.getjobber.com/api/graphql', {
    method: 'POST',
    headers: { Authorization: `Bearer ${JT}`, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16' },
    body: JSON.stringify({ query, variables }) });
  const ctype = r.headers.get('content-type') ?? '';
  if (!ctype.includes('json')) throw new Error(`Jobber returned ${ctype} at HTTP ${r.status} (waiting room?)`);
  const j = await r.json();
  if (j.errors?.length) throw new Error(`GraphQL: ${JSON.stringify(j.errors[0]).slice(0, 220)}`);
  if (!('data' in j)) throw new Error('Jobber reply carried no data key');
  return j.data;
}

const readClient = (gid) => gql(
  `query C($id:EncodedId!){ client(id:$id){ id isArchived companyName jobs(first:50){ nodes { id jobStatus } } } }`,
  { id: gid });

(async () => {
  const rows = await sql(`
    select c.id::int id, coalesce(c.client_code,'(nocode)') code, c.name, l.source_id
      from public.clients c
      left join public.entity_source_links l
        on l.entity_type='client' and l.source_system='jobber' and l.entity_id=c.id
     where c.status = 'INACTIVE'
     order by c.id`);

  console.log(`${EXECUTE ? 'EXECUTE' : 'DRY RUN'} — ${rows.length} INACTIVE clients here\n`);
  const summary = { archived: 0, already: 0, blocked_open_jobs: 0, no_link: 0, not_in_jobber: 0, failed: 0 };

  for (const r of rows) {
    const label = `${r.code.padEnd(10)} ${String(r.name).slice(0, 30).padEnd(31)}`;
    if (!r.source_id) { console.log(`  SKIP    ${label} no jobber link`); summary.no_link++; continue; }

    let c;
    try { c = (await readClient(r.source_id)).client; }
    catch (e) { console.log(`  ERROR   ${label} ${e.message.slice(0, 70)}`); summary.failed++; continue; }
    if (!c) { console.log(`  SKIP    ${label} not found in Jobber`); summary.not_in_jobber++; continue; }
    if (c.isArchived) { console.log(`  OK      ${label} already archived`); summary.already++; continue; }

    const open = (c.jobs?.nodes || []).filter(j => !TERMINAL.has(String(j.jobStatus).toLowerCase()));
    if (open.length) {
      console.log(`  BLOCKED ${label} ${open.length} open job(s): ${open.map(j => j.jobStatus).join(',')}`);
      console.log(`          Jobber has no jobDelete; closing a job destroys its visits, so that is a human decision.`);
      summary.blocked_open_jobs++; continue;
    }

    if (!EXECUTE) { console.log(`  WOULD   ${label} archive in Jobber`); continue; }

    // 🛑 RE-ASSERT THE PREDICATE AT WRITE TIME. Everything above may be minutes old.
    const stillInactive = await sql(`select status from public.clients where id = ${r.id}`);
    if (stillInactive[0]?.status !== 'INACTIVE') {
      console.log(`  ABORT   ${label} no longer INACTIVE here (now ${stillInactive[0]?.status}) — not archiving`);
      summary.failed++; continue;
    }

    let res;
    try {
      // ⚠ THE ARGUMENT IS `clientId`, NOT `id`. Introspected 2026-08-21 after a first run failed
      //   with "Field 'clientArchive' is missing required argument". It wrote nothing, because the
      //   whole mutation is rejected before it runs, which is the fail-closed design working.
      res = await gql(`mutation A($clientId:EncodedId!){ clientArchive(clientId:$clientId){ client { id isArchived } userErrors { message path } } }`,
                      { clientId: r.source_id });
    } catch (e) { console.log(`  ERROR   ${label} ${e.message.slice(0, 70)}`); summary.failed++; continue; }

    const ue = res.clientArchive?.userErrors ?? [];
    if (ue.length) { console.log(`  FAIL    ${label} userErrors: ${ue.map(u => u.message).join('; ').slice(0, 90)}`); summary.failed++; continue; }

    // VERIFY BY RE-READING. A clean mutation response is not evidence the state changed.
    const after = (await readClient(r.source_id)).client;
    if (after?.isArchived === true) { console.log(`  DONE    ${label} archived, verified`); summary.archived++; }
    else { console.log(`  FAIL    ${label} mutation returned clean but isArchived is still ${after?.isArchived}`); summary.failed++; }
  }

  console.log(`\n${JSON.stringify(summary)}`);
  if (!EXECUTE) console.log('\nDry run only. Re-run with --execute to apply.');
  console.log('--- audit complete --- ' + JSON.stringify({ probe: 'archive_inactive_clients', ...summary }));
})();
