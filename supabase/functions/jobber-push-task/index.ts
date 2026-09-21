// ============================================================================
// jobber-push-task — Calendar day markers → Jobber TASKS (Fred, 2026-08-06)
// ----------------------------------------------------------------------------
// Mirrors ops.calendar_day_markers (the Day Start / End / Dump route markers) into
// Jobber as Tasks, so the crew sees the shape of the day on their own schedule.
// The Calendar is the MASTER; Jobber follows.
//
//   op = 'upsert' -> taskCreate (no link yet) or taskEdit (already linked)
//   op = 'delete' -> taskDelete, then drop the link row
//
// 🛑 WHY TASKS AND NOT EVENTS — measured against the live API, and it CONTRADICTS Jobber AI,
// which recommended Events. The API exposes taskCreate / taskEdit / taskDelete but only
// **eventCreate**. Markers get dragged and removed constantly, so an Event-backed marker would
// strand an un-editable, un-deletable ghost on the crew's schedule on every move. Additionally
// Jobber AI itself notes an Event is "not a true single-person assignment ... visible to all team
// members". And the crew ALREADY uses Tasks exactly this way: 11 in one week, 7 with no client.
//
// 🛑 ASSIGNMENT SINCE 2026-09-16: THE MARKER'S DRIVER (Fred: "the task needs to be assigned to a driver
// instead, for it to be actually the driver to see this task"). ops.calendar_day_markers.employee_id
// names ONE person; the Task is titled "Day Start (Grecia)" and assigned to that person's Jobber user
// (entity_source_links, entity_type=employee). The marker's driver is AUTHORITATIVE: on an EDIT we send
// assignedTo even when it is empty, so a marker set back to Unassigned strips the previous driver from
// the Task (the Calendar is the master; the Task's own text says "Edit it there, not here"). On a CREATE
// an empty list is simply omitted. The read-back verifies the assignees, not only title and startAt.
// A Start placed BY TRUCK (2026-09-21, the Start pill picks a truck and derives the driver from that
// truck's first visit) carries BOTH vehicle_id and employee_id: the title names both, truck first
// ("Day Start (Cloggy, Grecia)"), and the assignment is still the one driver. Only rows with both set
// get the two-name title, so a driver-placed marker (vehicle_id NULL) reads exactly as before.
//
// LEGACY (rows placed before 2026-09-16: employee_id NULL, vehicle_id set) keep the previous rule,
// EVERYONE ON THAT TRUCK THAT DAY (Fred, 2026-08-06): a Jobber Task assigns to PEOPLE and `assignedTo`
// is a LIST. Measured over 30 days, a truck-day was NOT one driver: 42 had one, 13 had two, 2 had three.
// For those rows `assignedTo` is sent only when someone resolved: sending [] on an edit would STRIP an
// assignment a dispatcher set by hand, and "we don't know" must never overwrite "somebody decided".
// A marker with NEITHER a driver nor a truck is an Unassigned marker under the new model.
//
// AUTH: invoked by a DB trigger (pg_net) with a service_role bearer. Deployed verify_jwt=true, and
// the handler ALSO asserts role=service_role — the anon key is a validly signed JWT, so the gateway
// check alone is half a gate.
//
// ⚠ VERIFY-THEN-COMMIT. Per feedback_calendar_jobber_acid_writes: never record a link we have not
// confirmed. Every mutation is followed by a read-back of the Task from Jobber; only then is
// entity_source_links written. A push that 200s but did not take must NOT look like success.
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const GQL_VERSION = "2026-04-16";
const TZ = "America/New_York";

const db = createClient(SUPABASE_URL, SERVICE_KEY);            // public schema (webhook_tokens, links)
const ops = createClient(SUPABASE_URL, SERVICE_KEY, { db: { schema: "ops" } });

const ENTITY_TYPE = "calendar_day_marker";                      // entity_source_links.entity_type

// ---- Jobber write token (same row + refresh flow as jobber-push-visit) ------
async function getJobberToken(): Promise<string> {
  const { data, error } = await db.from("webhook_tokens")
    .select("access_token,refresh_token,client_id,client_secret,expires_at")
    .eq("source_system", "jobber_write").single();
  if (error || !data) throw new Error("no jobber_write token row");
  if (new Date(data.expires_at).getTime() > Date.now() + 120_000) return data.access_token;
  const body = `grant_type=refresh_token&refresh_token=${encodeURIComponent(data.refresh_token)}` +
    `&client_id=${encodeURIComponent(data.client_id)}&client_secret=${encodeURIComponent(data.client_secret)}`;
  const r = await fetch("https://api.getjobber.com/api/oauth/token", {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body,
  });
  if (!r.ok) throw new Error(`token refresh failed ${r.status}: ${(await r.text()).slice(0, 150)}`);
  const t = await r.json();
  const exp = JSON.parse(atob(t.access_token.split(".")[1])).exp * 1000;
  await db.from("webhook_tokens").update({
    access_token: t.access_token, refresh_token: t.refresh_token || data.refresh_token,
    expires_at: new Date(exp).toISOString(), updated_at: new Date().toISOString(),
  }).eq("source_system", "jobber_write");
  return t.access_token;
}

// Throttle-aware GraphQL, mirroring jobber-push-visit. Jobber's API is a cost-based leaky bucket;
// without backoff a burst silently loses mutations.
async function gql(token: string, query: string, variables?: unknown, _retry = 0): Promise<any> {
  const r = await fetch("https://api.getjobber.com/api/graphql", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`, "Content-Type": "application/json",
      "X-JOBBER-GRAPHQL-VERSION": GQL_VERSION,
    },
    body: JSON.stringify({ query, variables }),
  });
  // 🛑 Jobber sheds load with an HTML "Waiting Room" page at HTTP 200 (measured live 2026-08-13).
  // `.catch(() => ({}))` below turns that into an empty object, which every reader here treats as
  // "no errors, no data" — i.e. success with nothing in it. Returned as a synthetic top-level
  // `errors` envelope so errsOf() picks it up and callers fail closed, matching this helper's
  // existing return shape rather than introducing a second one.
  const ctype = r.headers.get("content-type") ?? "";
  if (!ctype.includes("json")) {
    return { errors: [{ message: `Jobber returned ${ctype || "an unknown content type"} at HTTP ${r.status} (its waiting room), not GraphQL` }] };
  }
  const j = await r.json().catch(() => ({}));
  const throttled = r.status === 429 ||
    (Array.isArray(j.errors) && j.errors.some((e: any) =>
      e?.extensions?.code === "THROTTLED" || /throttl/i.test(e?.message || "")));
  if (throttled && _retry < 5) {
    const waitMs = Math.min(30_000, 1_000 * Math.pow(2, _retry)) + _retry * 250;
    console.log(`[task] throttled — backoff ${waitMs}ms (retry ${_retry + 1}/5)`);
    await new Promise((s) => setTimeout(s, waitMs));
    return gql(token, query, variables, _retry + 1);
  }
  return j;
}

function bearerRole(req: Request): string | null {
  const tok = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  const p = tok.split(".");
  if (p.length !== 3) return null;
  try {
    const pad = p[1].replace(/-/g, "+").replace(/_/g, "/");
    return JSON.parse(atob(pad + "=".repeat((4 - (pad.length % 4)) % 4)))?.role ?? null;
  } catch { return null; }
}

// marker_date + minutes (minute-of-day, ET) -> a UTC instant.
// ⚠ Built by asking the ZONE for its offset on that date rather than hardcoding -04:00/-05:00.
// A fixed offset is correct for half the year and silently an hour out for the other half, and
// these markers bracket overnight routes where an hour matters.
function etToUtcISO(dateISO: string, minutes: number): string {
  const hh = String(Math.floor(minutes / 60)).padStart(2, "0");
  const mm = String(minutes % 60).padStart(2, "0");
  // Probe the offset at midday on that date to avoid DST-transition edges.
  const probe = new Date(`${dateISO}T12:00:00Z`);
  const tzName = new Intl.DateTimeFormat("en-US", {
    timeZone: TZ, timeZoneName: "longOffset",
  }).formatToParts(probe).find((p) => p.type === "timeZoneName")?.value ?? "GMT-05:00";
  const off = tzName.replace("GMT", "") || "-05:00";
  return new Date(`${dateISO}T${hh}:${mm}:00${off}`).toISOString();
}

// 🛑 READ BOTH ERROR CHANNELS. A GraphQL response carries TWO kinds of failure and they live in
// different places: a SCHEMA/validation error (wrong argument name, bad type) lands in top-level
// `errors` with `data: null`, while a business rejection lands in `data.<field>.userErrors`. Reading
// only userErrors makes a schema error look like success — that is precisely how a mistyped
// taskDelete argument deleted our link and left the Jobber task alive.
function errsOf(res: any, field: string): string[] {
  const top = Array.isArray(res?.errors) ? res.errors.map((e: any) => e?.message ?? String(e)) : [];
  const user = (res?.data?.[field]?.userErrors ?? []).map((e: any) => e?.message ?? String(e));
  return [...top, ...user].filter(Boolean);
}

// Who is on this truck on this date? (Fred, 2026-08-06: "assign it to whoever is on that truck that
// day.") Returns Jobber user ids, possibly several, possibly none.
//
// 🛑 IT IS OFTEN MORE THAN ONE PERSON, AND assignedTo IS A LIST — SO ASSIGN THEM ALL. Measured over
// 30 days: 42 truck-days had one driver, 13 had two, 2 had three. Picking "the" driver would put the
// marker on the wrong person's schedule roughly a quarter of the time.
//
// 🛑 AND IT IS OFTEN NOBODY YET, WHICH IS NORMAL, NOT AN ERROR. Markers get placed ahead of time.
// Over the next 14 days ALL 50 visits carry a truck but only 11 carry a driver. So an empty result is
// the common case for a future marker: return [], leave the Task unassigned, never guess. A later
// re-push picks the driver up once it is known (taskEdit accepts assignedTo).
//
// driver_id on ops.v_calendar_visit is COALESCE(GPS actual, assigned) — the app's canonical
// "effective driver" — so this matches what the Calendar itself shows for that day.
async function assigneesFor(vehicleId: number | null, dateISO: string): Promise<string[]> {
  if (!vehicleId) return [];
  const { data: visits, error: vErr } = await ops.from("v_calendar_visit")
    .select("driver_id").eq("vehicle_id", vehicleId).eq("visit_date", dateISO)
    .not("driver_id", "is", null);
  if (vErr) { console.error("[task] driver lookup failed:", vErr.message); return []; }
  const driverIds = [...new Set((visits ?? []).map((v: any) => v.driver_id))];
  if (!driverIds.length) return [];

  const { data: links, error: lErr } = await db.from("entity_source_links")
    .select("entity_id, source_id")
    .eq("entity_type", "employee").eq("source_system", "jobber").in("entity_id", driverIds);
  if (lErr) { console.error("[task] employee link lookup failed:", lErr.message); return []; }

  const found = (links ?? []).map((l: any) => l.source_id).filter(Boolean);
  // A driver with no Jobber user link is dropped rather than failing the push — the marker is still
  // worth showing. Log it, because it means someone's employee link is missing.
  if (found.length < driverIds.length) {
    const linked = new Set((links ?? []).map((l: any) => l.entity_id));
    console.warn(`[task] drivers with no Jobber user link: ${driverIds.filter((d) => !linked.has(d)).join(",")}`);
  }
  return found;
}

// The marker's own driver (2026-09-16 model): that employee's Jobber user, or [] when the employee has
// no Jobber link (logged, not a failure: the marker is still worth showing, unassigned).
async function assigneeForEmployee(employeeId: number): Promise<string[]> {
  const { data: link, error } = await db.from("entity_source_links")
    .select("source_id").eq("entity_type", "employee").eq("source_system", "jobber")
    .eq("entity_id", employeeId).maybeSingle();
  if (error) { console.error("[task] employee link lookup failed:", error.message); return []; }
  if (!link?.source_id) { console.warn(`[task] employee ${employeeId} has no Jobber user link`); return []; }
  return [link.source_id];
}

const TITLES: Record<string, string> = { start: "Day Start", end: "Day End", dump: "Dump" };

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("POST only", { status: 405 });
  if (bearerRole(req) !== "service_role") {
    return new Response(JSON.stringify({ ok: false, error: "forbidden" }), {
      status: 403, headers: { "Content-Type": "application/json" },
    });
  }

  let body: { op?: string; marker_id?: number };
  try { body = await req.json(); } catch { return json({ ok: false, error: "invalid json" }, 400); }
  const op = body.op, markerId = Number(body.marker_id);
  if (!markerId || !["upsert", "delete"].includes(op ?? "")) {
    return json({ ok: false, error: "need { op: 'upsert'|'delete', marker_id }" }, 400);
  }

  const token = await getJobberToken();

  // Existing link, if any. This is what decides create vs edit, and it is the ONLY place the
  // Jobber id lives — there is deliberately no jobber_task_id column (Supabase CLAUDE.md rule #1).
  const { data: link } = await db.from("entity_source_links")
    .select("id, source_id").eq("entity_type", ENTITY_TYPE)
    .eq("entity_id", markerId).eq("source_system", "jobber").maybeSingle();

  // ---- DELETE ----------------------------------------------------------------
  if (op === "delete") {
    if (!link) return json({ ok: true, skipped: "no jobber link" });
    // 🛑 taskDelete takes taskIdS — a LIST. Not taskId. Getting this wrong is not a loud failure:
    // a schema error lands in the response's TOP-LEVEL `errors`, `data` comes back null, and a
    // `res?.data?.taskDelete?.userErrors ?? []` read sees an empty array and concludes success. That
    // is exactly how the first version deleted the LINK while leaving the Task alive in Jobber —
    // an orphan nobody could ever clean up through the app. Hence errsOf() below, which reads both.
    const res = await gql(token, `mutation($ids: [EncodedId!]!){ taskDelete(taskIds: $ids){
      userErrors{ message } } }`, { ids: [link.source_id] });
    const errs = errsOf(res, "taskDelete");
    if (errs.length) return json({ ok: false, error: errs.join("; ") }, 200);

    // ⚠ VERIFY THE REMOTE EFFECT, not just the absence of an error. Read the Task back: it must be
    // gone. Only then drop the link. Dropping the link first is unrecoverable — without it there is
    // no handle on the Task at all.
    const check = await gql(token, `query($id: EncodedId!){ task(id: $id){ id } }`, { id: link.source_id });

    // 🛑 REQUIRE POSITIVE PROOF THAT JOBBER ANSWERED (2026-08-14). The check below used to be
    // `if (check?.data?.task?.id) keep-link`, which only kept the link when the Task was FOUND.
    // Every other outcome fell through to the delete — including a response with no `data` at all
    // (Jobber's HTML waiting room, a THROTTLED envelope, a JSON auth error), because
    // `undefined?.task?.id` is falsy in exactly the same way as a genuine `{"data":{"task":null}}`.
    // Absence of evidence was being read as evidence of absence, and the function then reported
    // `verified_gone: true`.
    // ⚠ That is UNRECOVERABLE, which is why it gets a positive test rather than a tidier negative
    //   one: entity_source_links carries NO audit trigger (0 rows in audit.logs), so once the link
    //   row is gone the Task GID exists nowhere in our system and the Task lives on the crew's
    //   Jobber schedule forever. A marker drag is delete+insert, so it would also mint a second one.
    // The link is the only handle we have. Drop it ONLY on proof the Task is really gone.
    const answered = !!check && typeof check === "object" &&
      Object.prototype.hasOwnProperty.call(check, "data") &&
      !!check.data && typeof check.data === "object";
    if (!answered) {
      return json({ ok: false, task: link.source_id,
        error: "verify unconfirmed — Jobber did not return an answer, so the task may still exist; link KEPT. Retry once Jobber is responding." }, 200);
    }
    if (check.data.task?.id) {
      return json({ ok: false, error: "verify failed — task still exists in Jobber; link KEPT", task: link.source_id }, 200);
    }
    await db.from("entity_source_links").delete().eq("id", link.id);
    return json({ ok: true, op: "delete", task: link.source_id, verified_gone: true });
  }

  // ---- UPSERT ----------------------------------------------------------------
  const { data: m } = await ops.from("calendar_day_markers")
    .select("id, marker_date, marker_type, minutes, dump_site, vehicle_id, employee_id").eq("id", markerId).maybeSingle();
  if (!m) return json({ ok: false, error: `marker ${markerId} not found` }, 404);

  // Who the marker belongs to, for the title: the driver (2026-09-16 model), else the legacy truck.
  // A Start placed BY TRUCK (2026-09-21) carries both, and its title names both, truck first:
  // "Day Start (Cloggy, Grecia)". The assignment is still the driver's alone (driverModel below).
  const driverModel = m.employee_id != null || m.vehicle_id == null;
  let owner: string | null = null;
  const truckName = m.vehicle_id
    ? (await db.from("vehicles").select("name").eq("id", m.vehicle_id).maybeSingle()).data?.name ?? null
    : null;
  if (m.employee_id != null) {
    const { data: e } = await db.from("employees").select("full_name").eq("id", m.employee_id).maybeSingle();
    const driverName = e?.full_name ?? null;
    owner = [truckName, driverName].filter(Boolean).join(", ") || null;
  } else {
    owner = truckName;
  }

  const startAt = etToUtcISO(m.marker_date, m.minutes);
  // 30 minutes is the marker's nominal block — matches DEPOT_DURATION in the reference prototype
  // and gives the Task a visible extent on the schedule rather than a zero-length sliver.
  const endAt = new Date(new Date(startAt).getTime() + 30 * 60_000).toISOString();

  const label = TITLES[m.marker_type] ?? m.marker_type;
  const title = [
    label,
    m.marker_type === "dump" && m.dump_site ? `- ${m.dump_site}` : null,
    owner ? `(${owner})` : null,
  ].filter(Boolean).join(" ");

  const assignedTo = m.employee_id != null
    ? await assigneeForEmployee(m.employee_id)
    : await assigneesFor(m.vehicle_id, m.marker_date);

  // Driver model: the marker's driver is authoritative, so an EDIT always carries assignedTo (an empty
  // list strips the previous driver when the marker became Unassigned); a CREATE omits an empty list.
  // Legacy truck rows: assignedTo is sent ONLY when we actually resolved someone. Sending [] on an edit
  // would strip an assignment a dispatcher may have set by hand in Jobber, which is a silent destructive
  // write; "we don't know" must not overwrite "somebody decided".
  const input: Record<string, unknown> = {
    title,
    instructions: "Route marker from the UnclogMe Visit Calendar. Edit it there, not here.",
    startAt, endAt, allDay: false,
  };
  const assignedSent = driverModel ? (assignedTo.length > 0 || !!link) : assignedTo.length > 0;
  if (assignedSent) input.assignedTo = assignedTo;

  let taskId = link?.source_id as string | undefined;
  if (taskId) {
    const res = await gql(token, `mutation($id: EncodedId!, $in: TaskEditInput!){
      taskEdit(taskId: $id, input: $in){ task{ id } userErrors{ message } } }`, { id: taskId, in: input });
    const errs = errsOf(res, "taskEdit");
    if (errs.length) return json({ ok: false, error: errs.join("; ") }, 200);
  } else {
    const res = await gql(token, `mutation($in: TaskCreateInput!){
      taskCreate(input: $in){ task{ id } userErrors{ message } } }`, { in: input });
    const errs = errsOf(res, "taskCreate");
    if (errs.length) return json({ ok: false, error: errs.join("; ") }, 200);
    taskId = res?.data?.taskCreate?.task?.id;
    if (!taskId) return json({ ok: false, error: "taskCreate returned no id" }, 200);
  }

  // ⚠ VERIFY BEFORE COMMITTING THE LINK. A 200 with no userErrors is not proof Jobber holds what we
  // think. Read the Task back and confirm the fields; only then record the link. Without this a
  // failed-but-quiet push leaves a marker that CLAIMS it synced, which is the exact false success
  // the Calendar/Jobber write rule exists to prevent.
  const check = await gql(token, `query($id: EncodedId!){ task(id: $id){ id title startAt endAt
    assignedUsers(first:10){ nodes{ id name{ full } } } } }`, { id: taskId });
  const t = check?.data?.task;
  // A verify failure on the CREATE path leaves a Task we cannot track; undo it, the same compensation
  // the link-write failure below has always had (2026-09-16: before this, a failed verify on create
  // left the Task alive and the next upsert would have minted a second one). On an EDIT the Task
  // legitimately pre-exists and must survive.
  const verifyFailed = async (error: string, detail: Record<string, unknown>) => {
    let rolledBack = false;
    if (!link) {
      const del = await gql(token, `mutation($ids: [EncodedId!]!){ taskDelete(taskIds: $ids){
        userErrors{ message } } }`, { ids: [taskId] });
      rolledBack = errsOf(del, "taskDelete").length === 0;
      console.error(`[task] ${error}; created task ${taskId} rolledBack=${rolledBack}`);
    }
    return json({ ok: false, error, ...detail, jobber_task: taskId, rolled_back: rolledBack }, 200);
  };
  const startMatches = t?.startAt && Math.abs(new Date(t.startAt).getTime() - new Date(startAt).getTime()) < 60_000;
  if (!t || t.title !== title || !startMatches) {
    return await verifyFailed("verify failed — Jobber did not confirm the task; link NOT recorded", {
      expected: { title, startAt }, got: t ? { title: t.title, startAt: t.startAt } : null,
    });
  }
  // When we asserted WHO the Task is for, the read-back must agree, as a set (2026-09-16). A driver
  // change that Jobber quietly ignored would otherwise be recorded as synced.
  if (assignedSent) {
    const got = ((t.assignedUsers?.nodes ?? []).map((u: any) => u?.id).filter(Boolean) as string[]).sort();
    const want = [...assignedTo].sort();
    if (got.length !== want.length || got.some((g, i) => g !== want[i])) {
      return await verifyFailed("verify failed: Jobber did not confirm the assignees; link NOT recorded", {
        expected: { assignedTo: want }, got: { assignedTo: got },
      });
    }
  }

  // ⚠ THE LINK WRITE MUST FAIL LOUDLY. An earlier version ignored this error and it bit immediately:
  // entity_source_links carries a CHECK WHITELIST on entity_type, 'calendar_day_marker' was not in it,
  // the insert was rejected 23514, and the function still returned ok:true having created a real
  // Jobber Task. That is WORSE than a failed push, because the next upsert sees no link and creates a
  // SECOND Task. If we cannot record the link, we must undo the Task we just made, or we leak orphans.
  const { error: linkErr } = await db.from("entity_source_links").upsert({
    entity_type: ENTITY_TYPE, entity_id: markerId, source_system: "jobber",
    source_id: taskId, source_name: title, match_method: "calendar_push",
    synced_at: new Date().toISOString(),
  }, { onConflict: "entity_type,entity_id,source_system" });

  if (linkErr) {
    // Compensate: we created it, we cannot track it, so remove it. Only for the CREATE path — on an
    // edit the Task legitimately pre-exists and must survive.
    let rolledBack = false;
    if (!link) {
      const del = await gql(token, `mutation($ids: [EncodedId!]!){ taskDelete(taskIds: $ids){
        userErrors{ message } } }`, { ids: [taskId] });
      rolledBack = errsOf(del, "taskDelete").length === 0;
    }
    console.error(`[task] link write failed: ${linkErr.message}; rolledBack=${rolledBack}`);
    return json({
      ok: false, error: `link write failed: ${linkErr.message}`,
      jobber_task: taskId, rolled_back: rolledBack,
      note: rolledBack ? "Jobber task deleted, no orphan" : "MANUAL CLEANUP MAY BE NEEDED",
    }, 200);
  }

  return json({
    ok: true, op: link ? "edit" : "create", task: taskId, title, startAt, endAt,
    assigned: (t.assignedUsers?.nodes ?? []).map((u: any) => u?.name?.full).filter(Boolean),
    assigned_count: assignedTo.length,
  });
});

function json(b: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json" } });
}
