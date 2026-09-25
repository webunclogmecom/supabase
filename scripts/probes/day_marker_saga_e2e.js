// Live end-to-end test of the Jobber-first day-marker saga (2026-09-24_2100). Run from the Supabase folder:
//   node scripts/probes/day_marker_saga_e2e.js human   (a person's saves through save-day-marker)
//   node scripts/probes/day_marker_saga_e2e.js heal    (the three heals through heal-day-starts)
// It WRITES to Prod and to Jobber: markers and Tasks on 2027-01-13 for Fred / Yannick, one inert [TEST] dump
// visit on truck David, all removed at the end and read back as gone. The staff session is minted with the
// admin API for fred@ayache.com (no password, no email sent) and signed out at the end.

// End-to-end test of the Jobber-first marker saga on Prod (run from the Supabase folder).
// Fixtures: markers on 2027-01-13 for Fred (2) / Yannick (27), truck David (3); one inert dump visit.
// Every Jobber Task created here is deleted at the end and read back as gone. No token is printed.
// usage: node e2e.js <phase>   phases: human | heal | cleanup
require(require.resolve("dotenv", { paths: [process.cwd()] })).config({ quiet: true });
const URL = process.env.SUPABASE_URL, SRK = process.env.SUPABASE_SERVICE_ROLE_KEY;
const D = "2027-01-13";
const FRED = 2, YAN = 27, DAVID = 3;
const phase = process.argv[2] || "human";
let fails = 0;
const ok = (name, cond, detail = "") => { if (!cond) fails++; console.log(`${cond ? "PASS" : "FAIL"}  ${name}${detail ? "  -- " + detail : ""}`); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function sql(q) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`, {
    method: "POST", headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, "Content-Type": "application/json" },
    body: JSON.stringify({ query: q }) });
  const j = await r.json();
  if (!r.ok || j.message) throw new Error("SQL: " + JSON.stringify(j).slice(0, 400));
  return j;
}
let JT = null;
async function jobberToken() {
  if (!JT) JT = (await sql(`select access_token from public.webhook_tokens where source_system = 'jobber_write'`))[0].access_token;
  return JT;
}
async function gql(query, variables) {
  const r = await fetch("https://api.getjobber.com/api/graphql", { method: "POST",
    headers: { Authorization: `Bearer ${await jobberToken()}`, "Content-Type": "application/json", "X-JOBBER-GRAPHQL-VERSION": "2026-04-16" },
    body: JSON.stringify({ query, variables }) });
  return (r.headers.get("content-type") || "").includes("json") ? r.json() : { nonjson: true };
}
async function task(gid) {
  const j = await gql(`query($id: EncodedId!){ task(id: $id){ id title startAt assignedUsers(first:10){ nodes{ id name{ full } } } } }`, { id: gid });
  if (!j.data) return { unanswered: true };
  const t = j.data.task;
  return t ? { id: t.id, title: t.title, startAt: t.startAt, who: (t.assignedUsers?.nodes ?? []).map((u) => u.name.full.trim()).sort().join(",") } : null;
}
let JWT = null;
async function session() {
  const g = await fetch(`${URL}/auth/v1/admin/generate_link`, { method: "POST",
    headers: { apikey: SRK, Authorization: `Bearer ${SRK}`, "Content-Type": "application/json" },
    body: JSON.stringify({ type: "magiclink", email: "fred@ayache.com" }) }).then((r) => r.json());
  const hashed = g.hashed_token ?? g.properties?.hashed_token;
  const s = await fetch(`${URL}/auth/v1/verify`, { method: "POST", headers: { apikey: SRK, "Content-Type": "application/json" },
    body: JSON.stringify({ type: "magiclink", token_hash: hashed }) }).then((r) => r.json());
  if (!s.access_token) throw new Error("no session");
  JWT = s.access_token;
}
async function logout() {
  if (JWT) await fetch(`${URL}/auth/v1/logout?scope=local`, { method: "POST", headers: { apikey: SRK, Authorization: `Bearer ${JWT}` } });
}
async function save(body, auth = JWT) {
  const r = await fetch(`${URL}/functions/v1/save-day-marker`, { method: "POST",
    headers: { Authorization: `Bearer ${auth}`, "Content-Type": "application/json" }, body: JSON.stringify(body) });
  return { status: r.status, j: await r.json().catch(() => ({})) };
}
const row = async (id) => (await sql(`select m.id, m.marker_date, m.minutes, m.employee_id, m.vehicle_id, m.stale_reason, m.eta_minutes,
    m.push_changed_at, l.source_id as gid, l.synced_at, l.match_method,
    (select count(*) from ops.marker_jobber_claims c where c.marker_id = m.id)::int as claims
  from ops.calendar_day_markers m left join public.entity_source_links l
    on l.entity_type = 'calendar_day_marker' and l.source_system = 'jobber' and l.entity_id = m.id where m.id = ${Number(id)}`))[0] ?? null;
const et = (iso) => new Date(iso).toLocaleString("en-US", { timeZone: "America/New_York", hour: "numeric", minute: "2-digit" });

async function human() {
  await session();
  const created = [];
  try {
    // auth: no token, a service-role key, bad input
    ok("A1 no token -> 401", (await save({ op: "delete", marker_id: 1 }, "x")).status === 401 || (await save({ op: "delete", marker_id: 1 }, "x")).status === 403);
    ok("A2 service-role key -> 403", (await save({ op: "delete", marker_id: 1 }, SRK)).status === 403);
    let r = await save({ op: "create", marker: { marker_type: "end", marker_date: D, minutes: 600, employee_id: FRED, stale_reason: "x" } });
    ok("A3 a forbidden field -> 400, nothing sent", r.status === 400 && r.j.code === "invalid_input", JSON.stringify(r.j).slice(0, 120));
    r = await save({ op: "create", marker: { marker_type: "start", marker_date: D, minutes: 300, vehicle_id: DAVID, employee_id: null } });
    ok("A4 a truck Start without a driver -> 400", r.status === 400, r.j.message);
    r = await save({ op: "create", marker: { marker_type: "end", marker_date: "2027-03-14", minutes: 150, employee_id: FRED } });
    ok("A5 2:30 AM on the spring-forward date -> 400", r.status === 400 && /clocks jump/.test(r.j.message || ""), r.j.message);
    r = await save({ op: "create", marker: { marker_type: "end", marker_date: "2027-02-30", minutes: 600, employee_id: FRED } });
    ok("A6 a date that does not exist -> 400", r.status === 400, r.j.message);

    r = await save({ op: "update", marker_id: 5, patch: { minutes: 1 }, replace_marker_id: 5 });
    ok("A7 a marker replacing itself -> 400", r.status === 400, r.j.message);

    // T1 create
    r = await save({ op: "create", marker: { marker_type: "end", marker_date: D, minutes: 600, employee_id: FRED } });
    const id1 = r.j.marker_id; if (id1) created.push(id1);
    let m = await row(id1), t = m?.gid ? await task(m.gid) : null;
    ok("T1 create -> 200, row + link + Task", r.status === 200 && m && m.gid && t && t.title === "Day End (Fred)" && t.who === "Fred" && et(t.startAt) === "10:00 AM",
      `status ${r.status} ${JSON.stringify(t)}`);
    ok("T1b committed through the saga: stamp = synced_at, claim gone, match_method calendar_saga",
      m && m.push_changed_at === m.synced_at && m.claims === 0 && m.match_method === "calendar_saga", JSON.stringify(m));
    const gid1 = m?.gid;

    // T2 update the time: same Task
    r = await save({ op: "update", marker_id: id1, patch: { minutes: 630 } });
    m = await row(id1); t = await task(m.gid);
    ok("T2 update minutes -> same Task moved to 10:30", r.status === 200 && m.gid === gid1 && m.minutes === 630 && et(t.startAt) === "10:30 AM", JSON.stringify(t));

    // T3 driver change: retitled, reassigned
    r = await save({ op: "update", marker_id: id1, patch: { employee_id: YAN } });
    m = await row(id1); t = await task(m.gid);
    ok("T3 driver -> Yannick: retitled + reassigned", r.status === 200 && t.title === "Day End (Yannick)" && t.who.startsWith("Yannick"), JSON.stringify(t));

    // T4 the slot rule: another End for Yannick that day
    r = await save({ op: "create", marker: { marker_type: "end", marker_date: D, minutes: 700, employee_id: YAN } });
    ok("T4 second End for Yannick -> 409 already_exists naming the blocker", r.status === 409 && r.j.code === "already_exists" && r.j.blocking_marker_id === id1, JSON.stringify(r.j).slice(0, 160));

    // T5 replace in place: same row, same Task
    r = await save({ op: "create", marker: { marker_type: "end", marker_date: D, minutes: 700, employee_id: YAN }, replace_marker_id: id1 });
    m = await row(id1); t = await task(m.gid);
    ok("T5 replace in place -> same marker, same Task, 11:40", r.status === 200 && r.j.marker_id === id1 && m.gid === gid1 && et(t.startAt) === "11:40 AM" && r.j.replaced_in_place === true,
      `${r.status} ${JSON.stringify(r.j).slice(0, 120)} ${JSON.stringify(t)}`);

    // T6 a move onto an occupied slot: Fred's End moves to Yannick
    r = await save({ op: "create", marker: { marker_type: "end", marker_date: D, minutes: 800, employee_id: FRED } });
    const id2 = r.j.marker_id; if (id2) created.push(id2);
    const gid2 = (await row(id2))?.gid;
    r = await save({ op: "update", marker_id: id2, patch: { employee_id: YAN } });
    ok("T6 move Fred's End onto Yannick's -> 409 already_exists", r.status === 409 && r.j.code === "already_exists" && r.j.blocking_marker_id === id1, JSON.stringify(r.j).slice(0, 120));
    r = await save({ op: "update", marker_id: id2, patch: { employee_id: YAN }, replace_marker_id: id1 });
    m = await row(id1); t = await task(m.gid);
    const g2 = gid2 ? await task(gid2) : "no gid";
    ok("T6b ...with replace: Yannick's End takes 1:20 PM, Fred's End and its Task are gone",
      r.status === 200 && m.minutes === 800 && m.employee_id === YAN && et(t.startAt) === "1:20 PM" && (await row(id2)) === null && g2 === null,
      `${r.status} ${JSON.stringify(r.j).slice(0, 140)} fredTask=${JSON.stringify(g2)}`);

    // T7 busy: another writer holds the marker
    const tok = (await sql(`select ops.claim_day_marker(array[${id1}]::bigint[], 'e2e-test', 60) as t`))[0].t;
    r = await save({ op: "update", marker_id: id1, patch: { minutes: 810 } });
    ok("T7 claimed by another writer -> 409 busy, nothing changed", r.status === 409 && r.j.code === "busy" && (await row(id1)).minutes === 800, JSON.stringify(r.j));
    await sql(`select ops.release_day_marker('${tok}'::uuid, false)`);

    // T8 the net: a direct SQL write is pushed by the trigger, jobber-push-task v19 reconciles
    await sql(`update ops.calendar_day_markers set minutes = 820 where id = ${id1}`);
    let tn = null;
    for (let i = 0; i < 20; i++) { await sleep(1500); tn = await task(m.gid); if (tn && et(tn.startAt) === "1:40 PM") break; }
    m = await row(id1);
    ok("T8 a direct SQL write reaches Jobber through the net (1:40 PM), link synced, no claim left",
      tn && et(tn.startAt) === "1:40 PM" && m.claims === 0 && m.synced_at >= m.push_changed_at, `${JSON.stringify(tn)} ${JSON.stringify(m)}`);

    // T9 a Task deleted by hand in Jobber: the next save creates it again
    const del = await gql(`mutation($ids: [EncodedId!]!){ taskDelete(taskIds: $ids){ userErrors{ message } } }`, { ids: [m.gid] });
    ok("T9 (setup) Task deleted by hand in Jobber", !!del.data && (await task(m.gid)) === null);
    r = await save({ op: "update", marker_id: id1, patch: { minutes: 840 } });
    const m9 = await row(id1); t = m9?.gid ? await task(m9.gid) : null;
    ok("T9 the next save creates the Task again and relinks it", r.status === 200 && m9.gid && m9.gid !== m.gid && t && et(t.startAt) === "2:00 PM" && r.j.jobber_recreated === true,
      `${r.status} ${JSON.stringify(r.j).slice(0, 140)} ${JSON.stringify(t)}`);

    // T10 eta-only update: no Jobber call
    r = await save({ op: "update", marker_id: id1, patch: { eta_minutes: 12 } });
    ok("T10 a change Jobber cannot see -> 200, jobber_changed false", r.status === 200 && r.j.jobber_changed === false, JSON.stringify(r.j).slice(0, 120));

    // T11 dump marker
    r = await save({ op: "create", marker: { marker_type: "dump", marker_date: D, minutes: 900, employee_id: FRED, dump_site: "Homestead (000-DH)" } });
    const id3 = r.j.marker_id; if (id3) created.push(id3);
    const m3 = id3 ? await row(id3) : null; const t3 = m3?.gid ? await task(m3.gid) : null;
    ok("T11 dump -> 'Dump - Homestead (000-DH) (Fred)'", r.status === 200 && t3?.title === "Dump - Homestead (000-DH) (Fred)", JSON.stringify(t3));

    // T12 delete: Task proven gone, row + link gone; a second delete is not_found
    for (const id of [id3, id1]) {
      const before = await row(id);
      r = await save({ op: "delete", marker_id: id });
      const after = await row(id); const tg = before?.gid ? await task(before.gid) : null;
      ok(`T12 delete ${id} -> Task gone, row gone`, r.status === 200 && after === null && tg === null, `${r.status} ${JSON.stringify(r.j).slice(0, 100)}`);
    }
    r = await save({ op: "delete", marker_id: id1 });
    ok("T12b delete again -> 200 gone (idempotent)", r.status === 200 && r.j.outcome === "gone", JSON.stringify(r.j).slice(0, 100));
    const left = await sql(`select count(*)::int n from ops.marker_jobber_claims`);
    ok("T13 no claim left behind", left[0].n === 0, JSON.stringify(left));
  } finally {
    await logout();
    // leftover fixtures on D (a failed run): remove through the saga so their Tasks go too
    const rest = await sql(`select id from ops.calendar_day_markers where marker_date = '${D}'`);
    if (rest.length) { await session(); for (const x of rest) console.log("cleanup", x.id, (await save({ op: "delete", marker_id: x.id })).status); await logout(); }
  }
}

async function heal() {
  await session();
  let visit = null, sid = null;
  try {
    const kick = async () => { await sql(`update ops.start_heal_kick set requested_at = '-infinity'`); await sql(`select ops.refresh_start_flags()`); };
    // H1 remove: a truck Start on a day the truck has no visit is flagged at once and removed by the healer
    let r = await save({ op: "create", marker: { marker_type: "start", marker_date: D, minutes: 300, vehicle_id: DAVID, employee_id: FRED, eta_minutes: 40, eta_computed_at: new Date().toISOString() } });
    sid = r.j.marker_id; let m = sid ? await row(sid) : null; const g = m?.gid;
    ok("H1 (setup) truck Start with no visit: created and flagged 'no timed visit'", r.status === 200 && m?.stale_reason === "no timed visit", JSON.stringify(m));
    await sleep(11000); await kick();
    for (let i = 0; i < 25 && (await row(sid)); i++) await sleep(1500);
    ok("H1 the healer removes it Jobber-first: row gone, Task gone", (await row(sid)) === null && (await task(g)) === null, `task=${JSON.stringify(g ? await task(g) : null)}`);

    // fixture: an inert dump visit on truck David at 6:00 AM ET, driver Fred
    const v = await sql(`select (public.create_dump_visit(p_client_id => 365, p_job_id => 1720, p_property_id => 98,
        p_service_line_item_ids => array[28]::bigint[], p_visit_date => '${D}'::date,
        p_start_at => '${D} 06:00 America/New_York'::timestamptz, p_end_at => '${D} 06:30 America/New_York'::timestamptz,
        p_title => '[TEST] marker saga e2e', p_notes => null, p_driver_id => ${FRED}, p_team_ids => null,
        p_push_to_jobber => false, p_vehicle_id => ${DAVID})).id as id`);
    visit = Number(v[0].id);
    const fv = await sql(`select * from public.fn_start_first_visit('${D}', ${DAVID})`);
    ok("H2 (setup) the dump visit is David's first visit, driver Fred", fv[0]?.id === visit && fv[0]?.driver_id === FRED, JSON.stringify(fv[0]).slice(0, 200));
    // a derived Start that matches it: 6:00 - 40 - 30 = 4:50 AM
    r = await save({ op: "create", marker: { marker_type: "start", marker_date: D, minutes: 290, vehicle_id: DAVID, employee_id: FRED, source_visit_id: visit, eta_minutes: 40, eta_computed_at: new Date().toISOString() } });
    sid = r.j.marker_id; m = await row(sid);
    ok("H2 (setup) derived truck Start is fresh", r.status === 200 && m?.stale_reason === null, JSON.stringify(m));

    // H2 driver: the visit's driver becomes Yannick
    await sql(`begin; set local app.suppress_jobber_push = 'on'; update public.visits set assigned_driver_id = ${YAN} where id = ${visit}; update public.visit_assignments set employee_id = ${YAN} where visit_id = ${visit}; commit;`);
    await sleep(11000); await kick();
    for (let i = 0; i < 25 && (await row(sid))?.employee_id !== YAN; i++) await sleep(1500);
    m = await row(sid); let t = await task(m.gid);
    ok("H2 driver heal: the Start and its Task go to Yannick", m.employee_id === YAN && m.stale_reason === null && t.title === "Day Start (David, Yannick)" && t.who.startsWith("Yannick"),
      `${JSON.stringify(m)} ${JSON.stringify(t)}`);

    // H3 recompute: the visit moves to 7:00 AM
    await sql(`begin; set local app.suppress_jobber_push = 'on'; update public.visits set start_at = '${D} 07:00 America/New_York', end_at = '${D} 07:30 America/New_York' where id = ${visit}; commit;`);
    await sleep(11000); await kick();
    for (let i = 0; i < 30 && (await row(sid))?.stale_reason !== null; i++) await sleep(1500);
    await sleep(3000);
    m = await row(sid); t = await task(m.gid);
    const want = 420 - m.eta_minutes - 30;
    ok("H3 recompute: minute = 7:00 - ETA - 30, fresh, the same Task moved", m.stale_reason === null && m.minutes === want && Math.abs(new Date(t.startAt) - new Date(`${D}T00:00:00-05:00`) - want * 60000) < 60000,
      `${JSON.stringify(m)} ${JSON.stringify(t)} want=${want}`);

    // H4 remove after the visit goes: deleted
    const gid = m.gid;
    await sql(`select public.delete_calendar_visit(${visit})`); visit = null;
    await sleep(11000); await kick();
    for (let i = 0; i < 25 && (await row(sid)); i++) await sleep(1500);
    ok("H4 the visit is deleted -> the Start and its Task go", (await row(sid)) === null && (await task(gid)) === null);
    const runs = await sql(`select status, details->'healed' as healed, details->'results' as results from public.sync_log
      where sync_source = 'start-flags-heal' and started_at > now() - interval '10 minutes' order by started_at`);
    ok("H5 every healer run logged, none in error", runs.length >= 4 && runs.every((x) => x.status !== "error"), JSON.stringify(runs.map((x) => x.status)));
  } finally {
    if (visit) await sql(`select public.delete_calendar_visit(${visit})`).catch(() => {});
    const rest = await sql(`select id from ops.calendar_day_markers where marker_date = '${D}'`);
    for (const x of rest) console.log("cleanup", x.id, (await save({ op: "delete", marker_id: x.id })).status);
    await logout();
  }
}

(async () => {
  try {
    if (phase === "human") await human();
    else if (phase === "heal") await heal();
    console.log(`\n${fails === 0 ? "ALL PASSED" : fails + " FAILED"}`);
  } catch (e) { console.log("ERROR", e.message); process.exitCode = 1; }
})();
