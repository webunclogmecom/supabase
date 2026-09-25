// Live test of the NET for day markers (jobber-push-task v19): a SQL-created marker gets its Task, a save
// that died half-way (its claim left behind) is repaired by start-push-retry, a SQL delete removes the Task.
// Writes to Prod and Jobber on 2027-01-13, cleans up. Run from the Supabase folder:
//   node scripts/probes/day_marker_saga_net_e2e.js

// A save that died half-way: its claim is left behind (dirty). start-push-retry must hand the marker to
// jobber-push-task, which takes the claim over, makes the Task match the row, and removes the claim.
// Then the leftover sweep: nothing of the test is left on 2027-01-13.
require(require.resolve("dotenv", { paths: [process.cwd()] })).config({ quiet: true });
const e2e = null;
const D = "2027-01-13";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function sql(q) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`, {
    method: "POST", headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, "Content-Type": "application/json" },
    body: JSON.stringify({ query: q }) });
  const j = await r.json(); if (!r.ok || j.message) throw new Error(JSON.stringify(j).slice(0, 300)); return j;
}
async function gql(query, variables) {
  const tok = (await sql(`select access_token from public.webhook_tokens where source_system = 'jobber_write'`))[0].access_token;
  const r = await fetch("https://api.getjobber.com/api/graphql", { method: "POST",
    headers: { Authorization: `Bearer ${tok}`, "Content-Type": "application/json", "X-JOBBER-GRAPHQL-VERSION": "2026-04-16" },
    body: JSON.stringify({ query, variables }) });
  return r.json();
}
const task = async (gid) => (await gql(`query($id: EncodedId!){ task(id: $id){ id title startAt } }`, { id: gid })).data?.task ?? null;
let fails = 0;
const ok = (n, c, d = "") => { if (!c) fails++; console.log(`${c ? "PASS" : "FAIL"}  ${n}${d ? "  -- " + d : ""}`); };

(async () => {
  // a marker created by a SQL writer: the trigger net creates its Task (claim, create, relink)
  const [{ id }] = await sql(`insert into ops.calendar_day_markers (marker_type, marker_date, minutes, employee_id)
                              values ('end', '${D}', 600, 2) returning id`);
  let link = null;
  for (let i = 0; i < 20 && !link; i++) { await sleep(1500);
    link = (await sql(`select source_id, match_method from public.entity_source_links where entity_type = 'calendar_day_marker' and entity_id = ${id}`))[0] ?? null; }
  ok("N1 a SQL-created marker gets its Task through the net (relink)", link && link.match_method === "calendar_saga", JSON.stringify(link));
  let t = link ? await task(link.source_id) : null;
  ok("N1b Task is 'Day End (Fred)' at 10:00 AM ET", t?.title === "Day End (Fred)" && t.startAt === `${D}T15:00:00Z`, JSON.stringify(t));

  // simulate a save that died after changing Jobber: Jobber moved to 11:00, the row still says 10:00,
  // and the claim is left behind, expired
  await gql(`mutation($id: EncodedId!, $in: TaskEditInput!){ taskEdit(taskId: $id, input: $in){ task{ id } userErrors{ message } } }`,
            { id: link.source_id, in: { startAt: `${D}T16:00:00Z`, endAt: `${D}T16:30:00Z` } });
  const tok = (await sql(`select ops.claim_day_marker(array[${id}]::bigint[], 'e2e-crash', 60) as t`))[0].t;
  await sql(`select ops.release_day_marker('${tok}'::uuid, true);
             update ops.marker_jobber_claims set until = now() - interval '2 minutes' where marker_id = ${id};`);
  t = await task(link.source_id);
  ok("D1 (setup) Jobber now differs from the row (11:00 vs 10:00), claim left behind", t.startAt === `${D}T16:00:00Z`);
  await sql(`select ops.retry_marker_pushes()`);
  let claims = 1;
  for (let i = 0; i < 20 && claims; i++) { await sleep(1500);
    claims = (await sql(`select count(*)::int n from ops.marker_jobber_claims where marker_id = ${id}`))[0].n; }
  t = await task(link.source_id);
  ok("D2 start-push-retry repaired it: Task back at 10:00, claim gone", claims === 0 && t.startAt === `${D}T15:00:00Z`, JSON.stringify(t));
  const led = await sql(`select kind, attempts from ops.marker_push_retries where kind = 'claim' and marker_id = ${id}`);
  ok("D3 the retry ledger recorded one claim repair", led.length === 1 && led[0].attempts === 1, JSON.stringify(led));

  // remove it through the net too (a SQL delete): the Task goes, the link goes
  await sql(`delete from ops.calendar_day_markers where id = ${id}`);
  let gone = false;
  for (let i = 0; i < 20 && !gone; i++) { await sleep(1500);
    gone = (await sql(`select count(*)::int n from public.entity_source_links where entity_type = 'calendar_day_marker' and entity_id = ${id}`))[0].n === 0; }
  ok("N2 a SQL delete removes the Task and the link through the net", gone && (await task(link.source_id)) === null);

  // leftovers
  const left = await sql(`select
     (select count(*) from ops.calendar_day_markers where marker_date = '${D}')::int as markers,
     (select count(*) from ops.marker_jobber_claims)::int as claims,
     (select count(*) from public.visits where id in (8541, 8542) and deleted_at is null)::int as live_visits,
     (select count(*) from public.entity_source_links l where l.entity_type = 'calendar_day_marker'
        and not exists (select 1 from ops.calendar_day_markers m where m.id = l.entity_id))::int as orphan_links`);
  ok("L1 nothing left: 0 markers on the test day, 0 claims, fixture visits deleted, 0 orphan links",
     left[0].markers === 0 && left[0].claims === 0 && left[0].live_visits === 0 && left[0].orphan_links === 0, JSON.stringify(left[0]));
  await sql(`delete from ops.marker_push_retries where marker_id = ${id}`);
  console.log(`\n${fails ? fails + " FAILED" : "ALL PASSED"}`);
})().catch((e) => { console.log("ERROR", e.message); process.exitCode = 1; });
