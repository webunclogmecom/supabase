// ============================================================================================
// day-marker-task: a Calendar day marker's Jobber Task, and the Jobber-first saga that changes it
// (2026-09-24, migration 2026-09-24_2100)
// --------------------------------------------------------------------------------------------
// Fred: "I was thinking that we do like with the visits, that it first confirms the data was changed
// in jobber being reflected in the app/db".
// Design: Building Apps/Visit Calendar/docs/specs/2026-09-24-jobber-first-day-markers-design.md
//
// THE ONE DEFINITION of what a marker (ops.calendar_day_markers) looks like in Jobber, and the only code
// that changes its Task. Three callers:
//   save-day-marker   a person, from the Visit Calendar          saveMarker()
//   heal-day-starts   the Start healer                          saveMarker()
//   jobber-push-task  the net: trigger pushes and start-push-retry  syncMarkerTask()
//
// 🛑 ONE WRITER PER MARKER. Every change to an existing marker first CLAIMS it (ops.claim_day_marker),
//    then pushes to Jobber, reads the Task back, and only then commits (ops.save_day_marker), and the
//    commit deletes the claim in the same transaction. No two Jobber writes to one Task can interleave,
//    which is what left Jobber a version behind before. A claim that is not committed (a crash, a Jobber
//    call with no answer, a compensation that failed) is RELEASED DIRTY: it stays, expired, and
//    start-push-retry has jobber-push-task repair the marker from it; the health check reports it after
//    20 minutes. A new marker needs no claim: nothing else can reach a row that does not exist yet.
//
// The Task (unchanged from jobber-push-task v18, measured live since 2026-08-17):
//   title       "Day Start (<owner>)" / "Day End (<owner>)" / "Dump - <site> (<owner>)"; owner = the driver,
//               or "<truck>, <driver>" when both are set, or the truck on the three legacy rows
//   window      the marker minute (ET) + 30 minutes, allDay false
//   assignedTo  the marker's driver (2026-09-16 model): sent on every edit, even empty (Unassigned strips
//               the previous driver); omitted when empty on a create. Legacy truck rows (no driver):
//               everyone on that truck that day, sent only when someone resolved.
//   read back   title, startAt within 60 s, and the assignee SET when assignedTo was sent.
//
// 🛑 THE HELPERS BELOW ARE COPIED, NOT RETYPED: getJobberToken, gql, errsOf from jobber-push-task (they
//    are byte-identical to save-calendar-task's, see scripts/probes/calendar_task_helpers_verbatim.mjs),
//    and etWall / tzOffsetMsAt / isRealCalendarDate / etToUtcISO from save-calendar-task, the DST-correct
//    copy. The old jobber-push-task etToUtcISO probed the zone at 12:00 UTC and put minutes 0-119 of a
//    spring-forward date on the PREVIOUS day; this one returns null for a time that does not exist.
// ============================================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const GQL_VERSION = "2026-04-16";
const TZ = "America/New_York";

const db = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });
const ops = createClient(SUPABASE_URL, SERVICE_KEY, { db: { schema: "ops" }, auth: { persistSession: false } });

export const ENTITY_TYPE = "calendar_day_marker";
const TITLES: Record<string, string> = { start: "Day Start", end: "Day End", dump: "Dump" };
const INSTRUCTIONS = "Route marker from the UnclogMe Visit Calendar. Edit it there, not here.";
const TASK_MINUTES = 30;          // the Task's visible extent on the crew's schedule
const CLAIM_SECONDS = 120;        // longer than a saga, even with Jobber throttling
const MARKER_COLS = "id, marker_date, marker_type, minutes, dump_site, vehicle_id, employee_id, " +
  "source_visit_id, eta_minutes, eta_computed_at, stale_reason";
// What a patch may change (the RPC enforces the same list). A marker's type, truck and dump site are fixed.
const PATCH_KEYS = ["marker_date", "minutes", "employee_id", "source_visit_id", "eta_minutes", "eta_computed_at"];
export const CREATE_KEYS = ["marker_type", "marker_date", "minutes", "dump_site", "vehicle_id", "employee_id",
  "source_visit_id", "eta_minutes", "eta_computed_at"];

// ---- results ---------------------------------------------------------------------------------------
export type Fail = {
  ok: false; status: number; code: string; message: string;
  dirty?: boolean;                        // a Jobber write may have landed without its commit
  [k: string]: unknown;
};
export type Ok = {
  ok: true; op: string; outcome: string; marker_id: number | null;
  marker: Record<string, unknown> | null; jobber_task: string | null; jobber_changed: boolean;
  [k: string]: unknown;
};
const fail = (status: number, code: string, message: string, extra: Record<string, unknown> = {}): Fail =>
  ({ ok: false, status, code, message, ...extra });

const MSG = {
  busy: "This marker is still being saved. Wait a moment and try again.",
  changed: "This marker was changed somewhere else while you were saving, so your change was not applied. The calendar now shows the latest version.",
  gone: "This marker was already removed.",
  lookup: "Couldn't read the driver or truck details, so nothing was changed. Try again.",
  rejected: "Jobber did not accept this change, so nothing was changed. Try again, and tell Fred if it keeps happening.",
  unavailable: "Jobber is not answering right now, so nothing was changed. Try again in a minute.",
  unverified: "Jobber did not confirm the change, so nothing was changed. Try again.",
  taken: "Another marker already holds this spot.",
};

// ============================================================================================
// Jobber helpers (copied, see the header)
// ============================================================================================
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

// The ET wall-clock parts of an instant. One source of ET parts for the whole file.
function etWall(utcMs: number): { date: string; minutes: number; seconds: number } {
  const p = new Intl.DateTimeFormat("en-CA", {
    timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false,
  }).formatToParts(new Date(utcMs))
    .reduce((a, x) => (a[x.type] = x.value, a), {} as Record<string, string>);
  const hh = p.hour === "24" ? 0 : Number(p.hour);          // Intl can emit hour 24 for midnight
  return {
    date: `${p.year}-${p.month}-${p.day}`,
    minutes: hh * 60 + Number(p.minute),
    seconds: Number(p.second),
  };
}

// The zone's UTC offset in effect AT a given instant. Derived by asking the zone, never from a
// table: format the instant in ET, read those wall-clock parts back as if they were UTC, subtract.
function tzOffsetMsAt(utcMs: number): number {
  const w = etWall(utcMs);
  const [y, m, d] = w.date.split("-").map(Number);
  const asIfUTC = Date.UTC(y, m - 1, d, Math.floor(w.minutes / 60), w.minutes % 60, w.seconds);
  return asIfUTC - utcMs;
}

// 🛑 IS THIS A REAL DAY ON THE CALENDAR? `^\d{4}-\d{2}-\d{2}$` is a SHAPE check, not a date check:
// it happily admits 2026-02-30, 2026-04-31, 2026-13-05 and 2026-00-10. Those all make etToUtcISO
// return null too, and null is otherwise the spring-forward-gap signal — so without this the caller
// told someone that 2026-02-30 was fine except for daylight saving. Same fail-closed 400 either
// way; the difference is whether the explanation is true.
// Round-trip rather than range-check the parts: Date.UTC ROLLS OVER (2026-02-30 -> Mar 2), and
// setUTCFullYear is used because Date.UTC remaps years 0-99 into 1900+.
function isRealCalendarDate(dateISO: string): boolean {
  const [y, m, d] = dateISO.split("-").map(Number);
  if (!Number.isInteger(y) || !Number.isInteger(m) || !Number.isInteger(d)) return false;
  if (m < 1 || m > 12 || d < 1 || d > 31) return false;
  const t = new Date(0);
  t.setUTCFullYear(y, m - 1, d);
  t.setUTCHours(0, 0, 0, 0);
  return t.getUTCFullYear() === y && t.getUTCMonth() === m - 1 && t.getUTCDate() === d;
}

// task_date + minutes (minute-of-day, ET) -> a UTC instant, or NULL if that ET wall time does not
// exist on that date (the spring-forward gap).
// ⚠ It also returns null for an impossible DATE, which is why the handler validates the date with
// isRealCalendarDate FIRST — see the DST-gap message at the call site. Two causes, one signal, so
// the ordering is what keeps the two explanations apart.
function etToUtcISO(dateISO: string, minutes: number): string | null {
  const [y, m, d] = dateISO.split("-").map(Number);
  if (!y || !m || !d) return null;
  // The requested wall time, read as if it were UTC. This is not an instant yet, it is a label.
  const wall = Date.UTC(y, m - 1, d, Math.floor(minutes / 60), minutes % 60, 0);
  // Pass 1 guesses with the offset at the label; pass 2 re-probes AT THE CANDIDATE. One pass alone
  // is wrong on both DST edges — that is precisely the original's failure.
  let utcMs = wall - tzOffsetMsAt(wall);
  utcMs = wall - tzOffsetMsAt(utcMs);
  // ROUND-TRIP OR REFUSE.
  const back = etWall(utcMs);
  if (back.date !== dateISO || back.minutes !== minutes) return null;
  return new Date(utcMs).toISOString();
}

// 🛑 POSITIVE PROOF THAT JOBBER ANSWERED. A response with NO `data` key (the HTML waiting room, a
// THROTTLED envelope, a JSON auth error) makes `undefined?.task?.id` falsy in exactly the same way a
// genuine {"data":{"task":null}} does. Absence of evidence must not be read as evidence of absence.
const answered = (res: unknown) =>
  !!res && typeof res === "object" &&
  Object.prototype.hasOwnProperty.call(res, "data") &&
  !!(res as { data?: unknown }).data && typeof (res as { data?: unknown }).data === "object";

// ============================================================================================
// The marker's Task: who it is for, and what it says (from jobber-push-task v18, unchanged)
// ============================================================================================
type Marker = {
  id: number; marker_date: string; marker_type: string; minutes: number; dump_site: string | null;
  vehicle_id: number | null; employee_id: number | null; source_visit_id: number | null;
  eta_minutes: number | null; eta_computed_at: string | null; stale_reason: string | null;
  gid: string | null;                       // the linked Jobber Task, from entity_source_links
};
type Want = { title: string; startAt: string; endAt: string; assignedTo: string[]; assignedSent: boolean };

// Who is on this truck on this date? (legacy rows only: Fred, 2026-08-06, "assign it to whoever is on
// that truck that day"). Returns Jobber user ids, possibly several, possibly none; null = the lookup FAILED.
async function assigneesFor(vehicleId: number | null, dateISO: string): Promise<string[] | null> {
  if (!vehicleId) return [];
  const { data: visits, error: vErr } = await ops.from("v_calendar_visit")
    .select("driver_id").eq("vehicle_id", vehicleId).eq("visit_date", dateISO)
    .not("driver_id", "is", null);
  if (vErr) { console.error("[task] driver lookup failed:", vErr.message); return null; }
  const driverIds = [...new Set((visits ?? []).map((v: any) => v.driver_id))];
  if (!driverIds.length) return [];

  const { data: links, error: lErr } = await db.from("entity_source_links")
    .select("entity_id, source_id")
    .eq("entity_type", "employee").eq("source_system", "jobber").in("entity_id", driverIds);
  if (lErr) { console.error("[task] employee link lookup failed:", lErr.message); return null; }

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
// null = the lookup itself FAILED. It must never collapse into [] (2026-09-23): on an edit, [] is sent
// as assignedTo and strips the driver from the Task, and the read-back then confirms the strip because
// it compares against the same []. So a transient database error removed a driver from their Day Start
// and reported ok:true.
async function assigneeForEmployee(employeeId: number): Promise<string[] | null> {
  const { data: link, error } = await db.from("entity_source_links")
    .select("source_id").eq("entity_type", "employee").eq("source_system", "jobber")
    .eq("entity_id", employeeId).maybeSingle();
  if (error) { console.error("[task] employee link lookup failed:", error.message); return null; }
  if (!link?.source_id) { console.warn(`[task] employee ${employeeId} has no Jobber user link`); return []; }
  return [link.source_id];
}

// A lookup that ERRORS stops the push: nothing is sent, the Task and the link stay as they were.
function lookupFail(what: string, message: string): Fail {
  console.error(`[task] ${what} lookup failed, nothing pushed: ${message}`);
  return fail(503, "lookup_failed", MSG.lookup, { detail: `${what}: ${message}` });
}

// deno-lint-ignore no-explicit-any
async function describe(m: Record<string, any>, isEdit: boolean): Promise<{ ok: true; want: Want } | Fail> {
  // Who the marker belongs to, for the title: the driver (2026-09-16 model), else the legacy truck.
  // A Start placed BY TRUCK (2026-09-21) carries both, and its title names both, truck first:
  // "Day Start (Cloggy, Grecia)". The assignment is still the driver's alone (driverModel below).
  const driverModel = m.employee_id != null || m.vehicle_id == null;
  let owner: string | null = null;
  let truckName: string | null = null;
  if (m.vehicle_id) {
    const { data: v, error: vErr } = await db.from("vehicles").select("name").eq("id", m.vehicle_id).maybeSingle();
    if (vErr) return lookupFail("truck name", vErr.message);
    truckName = v?.name ?? null;
  }
  if (m.employee_id != null) {
    const { data: e, error: eErr } = await db.from("employees").select("full_name").eq("id", m.employee_id).maybeSingle();
    if (eErr) return lookupFail("driver name", eErr.message);
    const driverName = e?.full_name ?? null;
    owner = [truckName, driverName].filter(Boolean).join(", ") || null;
  } else {
    owner = truckName;
  }

  const startAt = etToUtcISO(m.marker_date, m.minutes);
  if (!startAt) {
    const hh = Math.floor(m.minutes / 60), mm = String(m.minutes % 60).padStart(2, "0");
    return fail(400, "invalid_input",
      `There is no ${hh === 0 ? 12 : hh > 12 ? hh - 12 : hh}:${mm} ${hh < 12 ? "AM" : "PM"} on ${m.marker_date}: the clocks jump from 2:00 to 3:00 AM that morning. Pick another time.`);
  }
  // 30 minutes is the marker's nominal block, a visible extent on the schedule rather than a sliver.
  const endAt = new Date(new Date(startAt).getTime() + TASK_MINUTES * 60_000).toISOString();

  const label = TITLES[m.marker_type] ?? m.marker_type;
  const title = [
    label,
    m.marker_type === "dump" && m.dump_site ? `- ${m.dump_site}` : null,
    owner ? `(${owner})` : null,
  ].filter(Boolean).join(" ");

  const resolved = m.employee_id != null
    ? await assigneeForEmployee(m.employee_id)
    : await assigneesFor(m.vehicle_id, m.marker_date);
  if (resolved === null) return lookupFail("driver link", "see the log line above");

  // Driver model: the marker's driver is authoritative, so an EDIT always carries assignedTo (an empty
  // list strips the previous driver when the marker became Unassigned); a CREATE omits an empty list.
  // Legacy truck rows: assignedTo is sent ONLY when we actually resolved someone. Sending [] on an edit
  // would strip an assignment a dispatcher may have set by hand in Jobber.
  const assignedSent = driverModel ? (resolved.length > 0 || isEdit) : resolved.length > 0;
  return { ok: true, want: { title, startAt, endAt, assignedTo: resolved, assignedSent } };
}

function taskInput(want: Want): Record<string, unknown> {
  const input: Record<string, unknown> = {
    title: want.title, instructions: INSTRUCTIONS, startAt: want.startAt, endAt: want.endAt, allDay: false,
  };
  if (want.assignedSent) input.assignedTo = want.assignedTo;
  return input;
}

// The read-back gate: what Jobber does NOT confirm. Empty = verified. A 200 with no userErrors is not proof.
function verify(t: any, want: Want): string[] {
  if (!t?.id) return ["Jobber did not return the task"];
  const bad: string[] = [];
  if (t.title !== want.title) bad.push(`title (sent "${want.title}", Jobber has "${t.title}")`);
  if (!t.startAt || Math.abs(new Date(t.startAt).getTime() - new Date(want.startAt).getTime()) >= 60_000) {
    bad.push(`startAt (sent ${want.startAt}, Jobber has ${t.startAt})`);
  }
  // When we asserted WHO the Task is for, the read-back must agree, as a set (2026-09-16).
  if (want.assignedSent) {
    const got = ((t.assignedUsers?.nodes ?? []).map((u: any) => u?.id).filter(Boolean) as string[]).sort();
    const wanted = [...want.assignedTo].sort();
    if (got.length !== wanted.length || got.some((g, i) => g !== wanted[i])) {
      bad.push(`assignees (sent ${wanted.length}, Jobber has ${got.length}; sets differ)`);
    }
  }
  return bad;
}

const Q_TASK = `query($id: EncodedId!){ task(id: $id){ id title startAt endAt
  assignedUsers(first:10){ nodes{ id name{ full } } } } }`;
const M_TASK_CREATE = `mutation($in: TaskCreateInput!){ taskCreate(input: $in){ task{ id } userErrors{ message } } }`;
const M_TASK_EDIT = `mutation($id: EncodedId!, $in: TaskEditInput!){
  taskEdit(taskId: $id, input: $in){ task{ id } userErrors{ message } } }`;
// 🛑 taskDelete takes taskIdS, a LIST. A mistyped argument is a schema error in top-level `errors`.
const M_TASK_DELETE = `mutation($ids: [EncodedId!]!){ taskDelete(taskIds: $ids){ userErrors{ message } } }`;

function jobberFail(res: unknown, errs: string[], what: string): Fail {
  console.error(`[day-marker] Jobber ${what} failed: ${errs.join("; ")}`);
  return answered(res)
    ? fail(502, "jobber_rejected", MSG.rejected, { jobber_errors: errs })
    : fail(502, "jobber_unavailable", MSG.unavailable, { jobber_errors: errs });
}

// DELETE A JOBBER TASK AND PROVE IT IS GONE (save-calendar-task's deleteAndVerify, same outcomes).
// Read back whatever the mutation said: a delete of a Task that is ALREADY gone errors, and returning on
// that error would wedge every retry for ever.
async function deleteAndVerify(token: string, gid: string): Promise<
  { gone: boolean; alreadyGone: boolean; kind: "gone" | "rejected" | "unanswered"; reason: string | null }
> {
  const res = await gql(token, M_TASK_DELETE, { ids: [gid] });
  const errs = errsOf(res, "taskDelete");
  const check = await gql(token, Q_TASK, { id: gid });
  if (!answered(check)) {
    return { gone: false, alreadyGone: false, kind: "unanswered", reason: errs.length
      ? `Jobber rejected the delete (${errs.join("; ")}) and then did not answer the read-back`
      : "Jobber did not answer the read-back" };
  }
  if (check.data.task?.id) {
    return { gone: false, alreadyGone: false, kind: "rejected", reason: errs.length
      ? `Jobber rejected the delete: ${errs.join("; ")}` : "Jobber reported no error but the task is still there" };
  }
  return { gone: true, alreadyGone: errs.length > 0, kind: "gone", reason: null };
}

// Push `want` to the Task `gid` (edit), or to a new Task (create) when there is none or it was deleted by
// hand in Jobber; then read it back. `mutated` = a Jobber write may have landed although the push failed.
type Pushed = { ok: true; gid: string; created: boolean } | (Fail & { mutated: boolean; orphan?: string | null });
async function pushTask(token: string, gid: string | null, want: Want): Promise<Pushed> {
  let created = false;
  let sent = want;
  if (gid) {
    const res = await gql(token, M_TASK_EDIT, { id: gid, in: taskInput(want) });
    const errs = errsOf(res, "taskEdit");
    if (errs.length) {
      const back = await gql(token, Q_TASK, { id: gid });
      if (answered(back) && back.data.task === null) {
        console.warn(`[day-marker] Task ${gid} no longer exists in Jobber; creating it again`);
        gid = null;
      } else {
        return { ...jobberFail(res, errs, "taskEdit"), mutated: !answered(res) };
      }
    }
  }
  if (!gid) {
    // a create omits an empty assignee list (there is nobody to strip)
    sent = { ...want, assignedSent: want.assignedTo.length > 0 };
    const res = await gql(token, M_TASK_CREATE, { in: taskInput(sent) });
    const errs = errsOf(res, "taskCreate");
    if (errs.length) return { ...jobberFail(res, errs, "taskCreate"), mutated: false };
    gid = res?.data?.taskCreate?.task?.id ?? null;
    if (!gid) return { ...fail(502, "jobber_unverified", MSG.unverified), mutated: false };
    created = true;
  }
  const check = await gql(token, Q_TASK, { id: gid });
  const bad = answered(check) ? verify(check.data.task, sent) : ["Jobber did not answer the read-back"];
  if (bad.length) {
    console.error(`[day-marker] Jobber did not confirm Task ${gid}: ${bad.join("; ")}`);
    if (created) {
      // A Task we cannot track would be an orphan on the crew's schedule: remove it, and say so if we can't.
      const del = await deleteAndVerify(token, gid);
      if (!del.gone) console.error(`[day-marker] ORPHANED Jobber task ${gid}: created, not confirmed, and not removed. MANUAL CLEANUP NEEDED.`);
      return { ...fail(502, "jobber_unverified", MSG.unverified, { mismatches: bad }), mutated: false, orphan: del.gone ? null : gid };
    }
    return { ...fail(502, "jobber_unverified", MSG.unverified, { mismatches: bad }), mutated: true };
  }
  return { ok: true, gid, created };
}

// ============================================================================================
// Database steps
// ============================================================================================
async function readMarker(id: number): Promise<Marker | null | Fail> {
  const { data: row, error } = await ops.from("calendar_day_markers").select(MARKER_COLS).eq("id", id).maybeSingle();
  if (error) return lookupFail("marker", error.message);
  if (!row) return null;
  const { data: link, error: lErr } = await db.from("entity_source_links").select("source_id")
    .eq("entity_type", ENTITY_TYPE).eq("source_system", "jobber").eq("entity_id", id).maybeSingle();
  if (lErr) return lookupFail("Jobber link", lErr.message);
  return { ...(row as unknown as Omit<Marker, "gid">), gid: (link?.source_id as string | undefined) ?? null };
}
const isFail = (x: unknown): x is Fail => !!x && typeof x === "object" && (x as Fail).ok === false;

// What the caller read before it touched Jobber: the six columns Jobber can see, and the linked Task.
const expectOf = (m: Marker) => ({
  marker_date: m.marker_date, marker_type: m.marker_type, minutes: m.minutes, vehicle_id: m.vehicle_id,
  employee_id: m.employee_id, dump_site: m.dump_site, link_gid: m.gid,
});

type Committed = { ok: true; outcome: string; marker: Record<string, unknown> | null; before: Record<string, unknown> | null };
async function commit(op: string, markerId: number | null, token: string | null, expect: unknown,
                      values: unknown, task: { gid: string; title: string } | null, heal: unknown): Promise<Committed | Fail> {
  const { data, error } = await ops.rpc("save_day_marker", {
    p_op: op, p_marker_id: markerId, p_token: token, p_expect: expect, p_values: values, p_task: task, p_heal: heal,
  });
  if (error) {
    const msg = error.message ?? "database error";
    switch (error.code) {
      case "ZZ002": case "ZZ005": return fail(409, "changed_elsewhere", MSG.changed, { db_code: error.code });
      case "ZZ004": return fail(409, "busy", MSG.busy);
      case "P0002": return fail(404, "not_found", MSG.gone);
      case "23505": return fail(409, "already_exists", MSG.taken, { db_code: error.code });
      case "22023": case "23514": case "23502": case "22P02": case "23503": case "22007": case "22008":
        return fail(400, "invalid_input", msg, { db_code: error.code });
      default:
        console.error(`[day-marker] save_day_marker ${op} failed: ${error.code} ${msg}`);
        return fail(500, "db_error", "The calendar could not save the change. Try again.", { db_code: error.code });
    }
  }
  const out = (data ?? {}) as Record<string, unknown>;
  const outcome = String(out.outcome ?? "");
  if (!["saved", "healed", "deleted", "relinked", "gone"].includes(outcome)) {
    // a healer refusal re-checked under the lock (off, changed, frozen, unresolvable, a plan refusal)
    return fail(409, "refused", "The automatic fix no longer applies.", { outcome, result: out });
  }
  return { ok: true, outcome, marker: (out.marker as Record<string, unknown>) ?? null,
           before: (out.before as Record<string, unknown>) ?? null };
}

async function claim(ids: number[], holder: string): Promise<string | Fail> {
  const { data, error } = await ops.rpc("claim_day_marker", { p_marker_ids: ids, p_holder: holder, p_seconds: CLAIM_SECONDS });
  if (error) {
    if (error.code === "ZZ004") return fail(409, "busy", MSG.busy);
    return lookupFail("claim", error.message);
  }
  return String(data);
}
async function release(token: string, dirty: boolean): Promise<void> {
  const { error } = await ops.rpc("release_day_marker", { p_token: token, p_dirty: dirty });
  if (error) console.error(`[day-marker] release (${dirty ? "dirty" : "clean"}) failed: ${error.message}`);
}

async function jobberToken(): Promise<string | Fail> {
  try { return await getJobberToken(); } catch (e) {
    console.error("[day-marker] Jobber token:", e instanceof Error ? e.message : String(e));
    return fail(502, "jobber_unavailable", MSG.unavailable);
  }
}

// ============================================================================================
// Validation of the row a save would produce (a person's and the healer's alike)
// ============================================================================================
const isPosInt = (v: unknown) => typeof v === "number" && Number.isInteger(v) && v > 0;
async function exists(table: string, id: number): Promise<boolean | Fail> {
  const { data, error } = await db.from(table).select("id").eq("id", id).maybeSingle();
  if (error) return lookupFail(table, error.message);
  return !!data;
}
async function validate(t: Record<string, unknown>): Promise<Fail | null> {
  const type = t.marker_type;
  if (type !== "start" && type !== "end" && type !== "dump") return fail(400, "invalid_input", "The marker must be a Start, an End or a Dump.");
  const date = t.marker_date;
  if (typeof date !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(date) || !isRealCalendarDate(date)) {
    return fail(400, "invalid_input", "The marker needs a real date.");
  }
  if (typeof t.minutes !== "number" || !Number.isInteger(t.minutes) || t.minutes < 0 || t.minutes > 1439) {
    return fail(400, "invalid_input", "The marker needs a time of day.");
  }
  const site = t.dump_site;
  if (type === "dump" ? (typeof site !== "string" || !site) : site != null) {
    return fail(400, "invalid_input", type === "dump" ? "A Dump marker needs a dump site." : "Only a Dump marker has a dump site.");
  }
  for (const k of ["vehicle_id", "employee_id", "source_visit_id"]) {
    if (t[k] != null && !isPosInt(t[k])) return fail(400, "invalid_input", `${k} must be an id.`);
  }
  if (t.vehicle_id != null) {
    // 13p: a Start placed by truck carries its driver. A row with a truck and no driver would take the
    // legacy branch and assign the Task to everyone on that truck.
    if (type !== "start") return fail(400, "invalid_input", "Only a Start of day can be placed by truck.");
    if (t.employee_id == null) {
      return fail(400, "invalid_input", "A Start placed by truck needs its driver. Set a driver on the truck's first visit first.");
    }
  }
  if (t.eta_minutes != null && !(typeof t.eta_minutes === "number" && Number.isInteger(t.eta_minutes) && t.eta_minutes >= 0)) {
    return fail(400, "invalid_input", "The drive time must be a whole number of minutes.");
  }
  if (t.eta_computed_at != null && (typeof t.eta_computed_at !== "string" || Number.isNaN(Date.parse(t.eta_computed_at)))) {
    return fail(400, "invalid_input", "eta_computed_at must be a timestamp.");
  }
  for (const [k, table, what] of [["employee_id", "employees", "driver"], ["vehicle_id", "vehicles", "truck"],
                                  ["source_visit_id", "visits", "visit"]] as const) {
    if (t[k] == null) continue;
    const e = await exists(table, t[k] as number);
    if (isFail(e)) return e;
    if (!e) return fail(400, "invalid_input", `That ${what} does not exist.`);
  }
  return null;
}

// The marker that already holds the slot `t` would take (the two unique rules), other than `selfId`.
async function findBlocking(t: Record<string, unknown>, selfId: number | null): Promise<Record<string, unknown> | null | Fail> {
  let q;
  if ((t.marker_type === "start" || t.marker_type === "end") && t.vehicle_id == null) {
    q = ops.from("calendar_day_markers").select(MARKER_COLS)
      .eq("marker_date", t.marker_date as string).eq("marker_type", t.marker_type as string).is("vehicle_id", null);
    q = t.employee_id == null ? q.is("employee_id", null) : q.eq("employee_id", t.employee_id as number);
  } else if (t.marker_type === "start" && t.vehicle_id != null) {
    q = ops.from("calendar_day_markers").select(MARKER_COLS)
      .eq("marker_date", t.marker_date as string).eq("marker_type", "start").eq("vehicle_id", t.vehicle_id as number);
  } else {
    return null;                              // Dump markers repeat freely
  }
  if (selfId != null) q = q.neq("id", selfId);
  const { data, error } = await q.limit(1);
  if (error) return lookupFail("slot", error.message);
  return ((data ?? []) as unknown as Record<string, unknown>[])[0] ?? null;
}
const alreadyExists = (b: Record<string, unknown>) =>
  fail(409, "already_exists", MSG.taken, { blocking_marker_id: b.id, blocking: b });

const pick = (o: Record<string, unknown>, keys: string[]) =>
  Object.fromEntries(keys.filter((k) => Object.prototype.hasOwnProperty.call(o, k)).map((k) => [k, o[k]]));
const visibleChange = (a: Record<string, unknown>, b: Record<string, unknown>) =>
  a.marker_date !== b.marker_date || a.minutes !== b.minutes || (a.employee_id ?? null) !== (b.employee_id ?? null);

// ============================================================================================
// The steps, each holding the claim `token` for the marker it touches
// ============================================================================================

// Make the marker's Task match its CURRENT row: edit it, or create it when it has none or it was deleted
// by hand, then commit the link (relink). Used to put Jobber back after a refused or failed commit, and by
// the net. A row that moved in between (a direct SQL write) is re-read, 3 rounds at most.
async function reconcileHeld(token: string, jt: string, id: number): Promise<Ok | Fail> {
  for (let round = 1; round <= 3; round++) {
    const cur = await readMarker(id);
    if (isFail(cur)) return { ...cur, dirty: true };
    if (!cur) {
      const c = await commit("delete", id, token, null, null, null, null);   // drops the claim
      return isFail(c) ? { ...c, dirty: true }
        : { ok: true, op: "reconcile", outcome: "gone", marker_id: id, marker: null, jobber_task: null, jobber_changed: false };
    }
    const d = await describe(cur, !!cur.gid);
    if (!d.ok) return { ...d, dirty: true };
    const p = await pushTask(jt, cur.gid, d.want);
    if (!p.ok) return { ...p, dirty: true };
    const c = await commit("relink", id, token, expectOf(cur), null, { gid: p.gid, title: d.want.title }, null);
    if (!isFail(c)) {
      return { ok: true, op: "reconcile", outcome: p.created ? "created" : "edited", marker_id: id,
               marker: c.marker, jobber_task: p.gid, jobber_changed: true };
    }
    if (p.created) {
      const del = await deleteAndVerify(jt, p.gid);         // not linked: it must not stay on the schedule
      if (!del.gone) console.error(`[day-marker] ORPHANED Jobber task ${p.gid} (reconcile of marker ${id}). MANUAL CLEANUP NEEDED.`);
    }
    if (c.code !== "changed_elsewhere") return { ...c, dirty: true };
  }
  return fail(500, "not_settled", "The marker kept changing while its Jobber Task was being updated.", { dirty: true });
}

// A Jobber write landed but the commit did not: put Jobber back to the committed row. The result says
// whether that worked (dirty = false) or the claim must stay for the retry (dirty = true).
async function putBack(token: string, jt: string, id: number, why: Fail): Promise<Fail> {
  const r = await reconcileHeld(token, jt, id);
  if (r.ok) return { ...why, dirty: false, jobber_restored: true };
  console.error(`[day-marker] marker ${id}: Jobber changed, the commit failed (${why.code}), and putting Jobber back failed (${r.code}). start-push-retry will repair it.`);
  return { ...why, dirty: true, jobber_restored: false };
}

async function updateHeld(token: string, jtRef: { t: string | null }, id: number, patch: Record<string, unknown>,
                          heal: Record<string, unknown> | null, slot: Record<string, unknown> | null): Promise<Ok | Fail> {
  const cur = await readMarker(id);
  if (isFail(cur)) return cur;
  if (!cur) return fail(404, "not_found", MSG.gone);
  // Replace in place: the marker in the slot must still be the kind of marker the caller is replacing.
  if (slot && (slot.marker_type !== cur.marker_type || (slot.vehicle_id ?? null) !== cur.vehicle_id
               || slot.marker_date !== cur.marker_date
               || (cur.vehicle_id == null && (slot.employee_id ?? null) !== cur.employee_id))) {
    return fail(409, "changed_elsewhere", MSG.changed);
  }
  const target: Record<string, unknown> = { ...cur, ...patch };
  const bad = await validate(target);
  if (bad) return bad;
  if (target.marker_date !== cur.marker_date || (target.employee_id ?? null) !== cur.employee_id) {
    const b = await findBlocking(target, id);
    if (isFail(b)) return b;
    if (b) return alreadyExists(b);
  }

  // Nothing Jobber can see changes (the drive time, the source visit): the database only.
  if (!visibleChange(target, cur)) {
    const c = await commit("update", id, token, expectOf(cur), patch, null, heal);
    if (isFail(c)) return c;
    return { ok: true, op: "update", outcome: c.outcome, marker_id: id, marker: c.marker, jobber_task: cur.gid, jobber_changed: false };
  }

  const d = await describe(target, !!cur.gid);
  if (!d.ok) return d;
  if (!jtRef.t) { const t = await jobberToken(); if (isFail(t)) return t; jtRef.t = t; }
  const jt = jtRef.t;
  const p = await pushTask(jt, cur.gid, d.want);
  if (!p.ok) {
    if (p.orphan) console.error(`[day-marker] ORPHANED Jobber task ${p.orphan} (marker ${id}). MANUAL CLEANUP NEEDED.`);
    return { ...p, dirty: p.mutated };
  }
  const c = await commit("update", id, token, expectOf(cur), patch, { gid: p.gid, title: d.want.title }, heal);
  if (isFail(c)) {
    if (p.created) {
      // the Task was new (the old one gone, or none): remove it, the row keeps what it had
      const del = await deleteAndVerify(jt, p.gid);
      if (!del.gone) console.error(`[day-marker] ORPHANED Jobber task ${p.gid} (marker ${id}). MANUAL CLEANUP NEEDED.`);
      return { ...c, dirty: !del.gone };
    }
    return await putBack(token, jt, id, c);
  }
  return { ok: true, op: "update", outcome: c.outcome, marker_id: id, marker: c.marker, jobber_task: p.gid,
           jobber_changed: true, jobber_recreated: p.created && !!cur.gid };
}

async function deleteHeld(token: string, jtRef: { t: string | null }, id: number,
                          heal: Record<string, unknown> | null): Promise<Ok | Fail> {
  const cur = await readMarker(id);
  if (isFail(cur)) return cur;
  if (!cur) {
    const c = await commit("delete", id, token, null, null, null, heal);    // 'gone', drops the claim
    return isFail(c) ? c : { ok: true, op: "delete", outcome: "gone", marker_id: id, marker: null, jobber_task: null, jobber_changed: false };
  }
  // A person removes what they saw, whatever changed since; the healer re-checks everything.
  const expect = heal ? expectOf(cur) : { link_gid: cur.gid };
  if (cur.gid) {
    if (!jtRef.t) { const t = await jobberToken(); if (isFail(t)) return t; jtRef.t = t; }
    const del = await deleteAndVerify(jtRef.t, cur.gid);
    if (!del.gone) {
      console.error(`[day-marker] Task ${cur.gid} of marker ${id} was not deleted: ${del.reason}`);
      return del.kind === "unanswered"
        ? fail(502, "jobber_unavailable", MSG.unavailable, { dirty: true })
        : fail(502, "jobber_rejected", MSG.rejected, { detail: del.reason });
    }
  }
  const c = await commit("delete", id, token, expect, null, null, heal);
  if (isFail(c)) {
    // The Task is gone but the marker stays (a visit came back, the marker moved, a database error):
    // give it its Task again.
    return cur.gid && jtRef.t ? await putBack(token, jtRef.t, id, c) : c;
  }
  return { ok: true, op: "delete", outcome: c.outcome, marker_id: id, marker: c.marker, jobber_task: cur.gid,
           jobber_changed: !!cur.gid };
}

// ============================================================================================
// saveMarker: a person's or the healer's change
// ============================================================================================
export type SaveRequest = {
  op: "create" | "update" | "delete";
  markerId?: number | null;
  values?: Record<string, unknown>;          // create: the new marker
  patch?: Record<string, unknown>;           // update: the changed keys (PATCH_KEYS)
  // The marker already in the slot. create: that marker is updated IN PLACE (same row, same Task).
  // update (a move onto an occupied slot): that marker takes this one's values, then this one is removed.
  replaceMarkerId?: number | null;
  heal?: Record<string, unknown> | null;     // the healer's re-check, see ops.save_day_marker
  holder: string;                            // who is saving, for the claim
};

export async function saveMarker(req: SaveRequest): Promise<Ok | Fail> {
  const jt: { t: string | null } = { t: null };
  try {
    // ---- a new marker: no claim, nothing else can reach it yet ------------------------------------
    if (req.op === "create" && req.replaceMarkerId == null) {
      const values = req.values ?? {};
      const bad = await validate(values);
      if (bad) return bad;
      const b = await findBlocking(values, null);
      if (isFail(b)) return b;
      if (b) return alreadyExists(b);
      const d = await describe(values, false);
      if (!d.ok) return d;
      const t = await jobberToken(); if (isFail(t)) return t;
      const p = await pushTask(t, null, d.want);
      if (!p.ok) {
        if (p.orphan) console.error(`[day-marker] ORPHANED Jobber task ${p.orphan} (new marker). MANUAL CLEANUP NEEDED.`);
        return p;
      }
      const c = await commit("create", null, null, null, values, { gid: p.gid, title: d.want.title }, null);
      if (isFail(c)) {
        const del = await deleteAndVerify(t, p.gid);
        if (!del.gone) console.error(`[day-marker] ORPHANED Jobber task ${p.gid}: created, the marker was not saved, and the Task was not removed. MANUAL CLEANUP NEEDED.`);
        if (c.code === "already_exists") {                 // a slot taken between the check and the commit
          const again = await findBlocking(values, null);
          if (!isFail(again) && again) return alreadyExists(again);
        }
        return c;
      }
      const id = Number(c.marker?.id);
      return { ok: true, op: "create", outcome: "saved", marker_id: id, marker: c.marker, jobber_task: p.gid, jobber_changed: true };
    }

    // ---- everything else changes an existing marker: claim it first ------------------------------
    const main = req.op === "create" ? null : Number(req.markerId);
    if (req.op !== "create" && !isPosInt(main)) return fail(400, "invalid_input", "marker_id is required.");
    const ids = [main, req.replaceMarkerId ?? null].filter((x): x is number => x != null);
    const token = await claim(ids, req.holder);
    if (isFail(token)) return token;

    let res: Ok | Fail;
    try {
      if (req.op === "create") {
        // Replace IN PLACE: the marker in the slot takes the new values; same row, same Task.
        const v = req.values ?? {};
        res = await updateHeld(token, jt, req.replaceMarkerId!, Object.fromEntries(PATCH_KEYS.map((k) => [k, v[k] ?? null])),
                               null, v);
        if (res.ok) res = { ...res, op: "create", replaced_in_place: true };
      } else if (req.op === "update" && req.replaceMarkerId != null) {
        // A move onto an occupied slot: the marker there takes this one's values, then this one goes.
        // In that order, so a failure half-way loses nothing.
        const cur = await readMarker(main!);
        if (isFail(cur)) res = cur;
        else if (!cur) res = fail(404, "not_found", MSG.gone);
        else {
          const target: Record<string, unknown> = { ...cur, ...(req.patch ?? {}) };
          const r1 = await updateHeld(token, jt, req.replaceMarkerId, Object.fromEntries(PATCH_KEYS.map((k) => [k, target[k] ?? null])),
                                      null, target);
          if (!r1.ok) res = r1;
          else {
            const r2 = await deleteHeld(token, jt, main!, null);
            res = r2.ok
              ? { ...r1, op: "update", replaced_marker_id: req.replaceMarkerId, removed_marker_id: main }
              : { ...r2, code: "partly_moved", status: 500,
                  message: "The marker was placed on the new spot, but the one it came from could not be removed. Remove it by hand." };
          }
        }
      } else if (req.op === "update") {
        res = await updateHeld(token, jt, main!, req.patch ?? {}, req.heal ?? null, null);
      } else {
        res = await deleteHeld(token, jt, main!, req.heal ?? null);
      }
    } catch (e) {
      console.error("[day-marker] unexpected:", e instanceof Error ? e.message : String(e));
      res = fail(500, "unexpected", "Something went wrong, and the change may not be complete. The calendar now shows what was saved.", { dirty: true });
    }
    // A commit removed its own claim. Whatever is left: dirty (Jobber may differ, the retry repairs it) or clean.
    await release(token, !res.ok && !!res.dirty);
    return res;
  } catch (e) {
    console.error("[day-marker] unexpected:", e instanceof Error ? e.message : String(e));
    return fail(500, "unexpected", "Something went wrong and nothing was saved.");
  }
}

// ============================================================================================
// syncMarkerTask: the net (jobber-push-task). Make Jobber match the database for one marker.
// ============================================================================================
// op 'upsert': the marker exists; edit its Task, or create it (no link, or deleted by hand), and commit
//              the link. op 'delete': the marker is gone; delete its Task and drop the link.
// Busy (another writer holds the marker) is not an error: that writer's commit, or the retry, covers it.
export async function syncMarkerTask(op: "upsert" | "delete", markerId: number): Promise<Record<string, unknown>> {
  const token = await claim([markerId], "jobber-push-task");
  if (isFail(token)) return { ok: false, busy: token.code === "busy", error: token.message };
  let out: Record<string, unknown>;
  let dirty = false;
  try {
    const jt = await jobberToken();
    if (isFail(jt)) { dirty = true; out = { ok: false, error: jt.message }; }
    else {
      const cur = await readMarker(markerId);
      if (isFail(cur)) { dirty = true; out = { ok: false, error: cur.message }; }
      else if (cur) {
        const r = await reconcileHeld(token, jt, markerId);
        dirty = !r.ok && !!r.dirty;
        out = r.ok ? { ok: true, op: r.outcome === "created" ? "create" : "edit", task: r.jobber_task }
                   : { ok: false, error: r.message, code: r.code };
      } else {
        // The marker is gone: its Task goes, then its link. The link is the only handle on the Task, so it
        // is dropped ONLY on proof the Task is gone (entity_source_links has no audit trail).
        const { data: link, error: lErr } = await db.from("entity_source_links").select("id, source_id")
          .eq("entity_type", ENTITY_TYPE).eq("entity_id", markerId).eq("source_system", "jobber").maybeSingle();
        if (lErr) { dirty = true; out = { ok: false, error: `link lookup failed: ${lErr.message}` }; }
        else if (!link) { out = { ok: true, skipped: "no jobber link" }; }
        else {
          const del = await deleteAndVerify(jt, link.source_id);
          if (!del.gone) { dirty = true; out = { ok: false, task: link.source_id, error: `${del.reason}; link KEPT` }; }
          else {
            const { error: uErr } = await db.from("entity_source_links").delete().eq("id", link.id);
            if (uErr) { dirty = true; out = { ok: false, task: link.source_id, task_gone: true, error: `the task is gone in Jobber but the link could not be removed: ${uErr.message}` }; }
            else out = { ok: true, op: "delete", task: link.source_id, verified_gone: true, already_gone: del.alreadyGone };
          }
        }
      }
    }
  } catch (e) {
    dirty = true;
    out = { ok: false, error: e instanceof Error ? e.message : String(e) };
  }
  if (op === "delete" && out.op === "edit") out.note = "the marker still exists, so its Task was updated instead of deleted";
  await release(token, dirty);
  return out;
}
