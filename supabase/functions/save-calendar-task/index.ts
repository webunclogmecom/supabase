// ============================================================================================
// save-calendar-task — the SYNCHRONOUS Calendar Tasks saga (Fred, 2026-08-26)
// --------------------------------------------------------------------------------------------
// Office staff create a task in the Visit Calendar; it mirrors to Jobber as a Jobber TASK, and
// completion works from both sides. This function is the ONLY door through which our copy is
// written.
//
//     push to Jobber  ->  READ THE TASK BACK to verify  ->  only then call the RPC
//     on ANY failure: write NOTHING locally, return a typed error the app shows
//
// Fred, verbatim: "like a transaction ... if jobber gets an issue while completing it on our app,
// then our app also shows that error so it can't be completed. I don't want discrepancies."
//
// 🛑 WHY THIS IS NOT A TRIGGER + pg_net PUSH, which is what ops.calendar_day_markers does.
//    pg_net is FIRE-AND-FORGET: the transaction commits without waiting for the HTTP call, so it
//    structurally CANNOT fail closed and CANNOT return an error to the app. A trigger-based design
//    can only ever discover a Jobber failure after our row already claims success — which is the
//    exact discrepancy this feature exists to prevent. Synchronous is the requirement, not a style.
//
// 🛑 NOBODY HOLDS A WRITE GRANT ON ops.calendar_tasks — NOT EVEN service_role, and not this
//    function. Every write goes through ops.fn_record_calendar_task / ops.fn_delete_calendar_task
//    (SECDEF, EXECUTE to service_role only). There is no PostgREST write path to bypass, which is
//    what makes "our copy never claims something Jobber does not have" structural rather than a
//    convention. See docs/migrations/2026-08-26_1810 and _1820.
//
// ============================================================================================
// AUTH — verify_jwt = false, and that is DELIBERATE. Do not "harmonise" it to true.
// ============================================================================================
// This project signs session tokens with ES256 and the gateway rejects them on some functions with
// 401 UNAUTHORIZED_ASYMMETRIC_JWT, VARYING BY DEPLOYMENT VINTAGE: save-client-job hit exactly that
// and is deliberately verify_jwt=false, while save-calendar-visit (deployed earlier) accepts the
// same token at true. A function deployed today follows the newer precedent.
// The control is IN-HANDLER auth.getUser() + an @ayache.com/@unclogme.com domain gate, copied from
// adopt-visit-from-jobber. auth.getUser() round-trips to GoTrue and validates signature AND expiry
// against the real keys, which is STRICTLY STRONGER than the gateway check — the public anon key is
// itself a validly signed JWT and passes verify_jwt. A bare claim decode would verify nothing.
// ⚠ A service-role key is NOT a staff user: it carries no email, so it is refused 403. Verified.
//
// ============================================================================================
// THE HELPERS BELOW ARE COPIED BYTE-FOR-BYTE FROM jobber-push-task. DO NOT RETYPE THEM.
// ============================================================================================
// getJobberToken / gql / errsOf are lifted verbatim.
// 🛑 THERE IS NO BUILD STEP. An earlier version of this line said these were "sha256-checked at
//   build time" and that was FALSE: `supabase functions deploy` bundles and uploads and nothing
//   else runs, `npm test` is a stub, there are no active git hooks, and no CI workflow touches edge
//   functions. The check it named had never been committed. That is worse than having no check,
//   because a reader trusts the comment and skips verifying — the same false-all-clear shape this
//   file guards against everywhere else, aimed at itself.
//   ⇒ The check is REAL now and it is a probe someone RUNS, not a build step:
//        node scripts/probes/calendar_task_helpers_verbatim.mjs
//     It asserts the three helpers are byte-identical to jobber-push-task's, that etToUtcISO
//     DIFFERS, and that the buggy 12:00-UTC probe is absent here and present there — with a control
//     that fails if that probe string ever stops existing in the original. Run it after touching
//     this file or jobber-push-task. Nothing runs it for you.
// ⚠ etToUtcISO is the ONE DELIBERATE EXCEPTION — it is NOT identical, because the shared original
//   has a DST spring-forward bug that a timed task's read-back structurally cannot see. The long
//   explanation sits directly above the function; jobber-push-task and jobber-push-visit still
//   carry the bug and fixing them was out of scope here.
// Retyping is how 2026-08-06_1316 silently dropped six clauses from a live function. The two that
// carry the hardest-won logic:
//   * gql()'s HTML WAITING-ROOM CHECK. Jobber sheds load with text/html at HTTP 200; a naive helper
//     reads that as success with data: undefined.
//   * errsOf() reads BOTH GraphQL error channels. A schema error has data: null and an EMPTY
//     userErrors, so reading only userErrors makes it look like success.
// `bearerRole` is deliberately NOT copied: this one is browser-called and uses auth.getUser().
// `json` is the CORS-carrying version from adopt-visit-from-jobber instead of jobber-push-task's,
// because this function is called from a browser and a response with no CORS header is unreadable
// by the app no matter how correct its body is. Also verbatim, just from the other shipped source.
//
// ============================================================================================
// 🛑 AN ALL-DAY JOBBER TASK CARRIES A DATE. A FIRST VERSION OF THIS FILE CLAIMED IT DOES NOT.
// ============================================================================================
// THE WRONG CLAIM, recorded because it switched off a real gate for a day: "an all-day Jobber Task
// exposes no date at all", from a sample of 100 tasks in which all 3 all-day rows returned
// startAt/endAt/duration as null while 0 of 97 timed rows did. The correlation looked perfect. It
// was an artefact of the SAMPLE: `tasks(first:200, sort:{START_AT DESC})` caps at 100 nodes and
// sorts the un-dated rows to the front, so that page contained ALL of the un-dated tasks and NONE
// of the dated all-day ones. n=3, selected by the very field being measured, generalised into a
// claim about a TYPE — and then used to REMOVE the startAt check for every all-day save.
//
// RE-MEASURED over the FULL population (all 401 tasks, walked 5 pages, 2026-08-26):
//     all-day: 16   -> 13 carry startAt/endAt/duration normally, 3 are null
//     timed:  385   -> 0 null
//     all 13 dated all-day rows: startAt = ET 00:00:00, endAt = ET 23:59:59, duration = 1440
//     (one is legitimately MULTI-DAY: 2025-10-26 -> 2025-10-30, duration 7200)
// CONTROL that settles what the 3 nulls are: unfiltered totalCount = 401; filtering
// startAt between 2000 and 2100 returns 398. The 3 excluded are exactly the null ones, so they are
// UNSCHEDULED tasks, not dateless all-day tasks. Jobber's schema says the same thing:
// AppointmentEditScheduleInput is a union of `unschedule: True` | `schedule` | `scheduleAllDay:
// {startDate, endDate, timezone}` — all-day is a SCHEDULED state that carries a date.
//
// ⇒ THE DATE IS VERIFIABLE ON AN ALL-DAY TASK AND IS VERIFIED. verifyTask compares the ET CALENDAR
//   DATE of startAt (and of endAt) against task_date.
// ⇒ COMPARE THE ET DATE, NEVER THE INSTANT. Jobber normalises an all-day endAt to 23:59:59, so an
//   exact-instant comparison misses by one second — that is not a margin, it is a broken check.
// ⇒ WHY THIS MATTERS MOST HERE: taskCreate takes a UTC `startAt`, while Jobber's own all-day input
//   wants {startDate, timezone}. So "Jobber ignores what we sent and the task lands UNSCHEDULED"
//   is the most likely all-day failure mode — and it is exactly the one the removed check could
//   not see. A null startAt now fails verification instead of being waved through.
//
// ⚠ AN EMPTY ASSIGNEE LIST OMITS THE KEY, IT DOES NOT CLEAR. Sending assignedTo: [] would strip an
//   assignment a dispatcher set by hand in Jobber, and "we resolved nobody" must never overwrite
//   "somebody decided". So an empty resolved list omits assignedTo from Jobber AND omits
//   assignee_ids from the RPC, keeping both sides in agreement. The cost, stated plainly: v1 cannot
//   UNASSIGN. The response says so in `assignees_cleared: false` rather than failing silently.
//
// ⚠ emailAssignments IS NEVER SET. It mails real staff and is out of scope for v1.
//
// Jobber ops, all proven live 2026-08-25 (findings doc named at the bottom of this header):
//   create   taskCreate(clientId:, propertyId:, input:{...})  <- ONE call; the TOP-LEVEL
//            clientId/propertyId DO attach. They are field ARGS, not TaskCreateInput fields.
//   edit     taskEdit(taskId:, input:{... clientId, propertyId, assignedTo})  <- INSIDE the input
//            here; the asymmetry with taskCreate is real and was re-introspected 2026-08-26.
//   complete appointmentEditCompleteness(appointmentId: <Task GID>, input:{completed:})
//   delete   taskDelete(taskIds: [GID])   <- a LIST, not taskId.
//
// Docs (both under `Building Apps/Visit Calendar/docs/specs/`, NOT this repo):
//   2026-08-25-calendar-tasks-design.md           — the design
//   2026-08-25-calendar-tasks-jobber-findings.md  — the live Jobber contract tests
// ============================================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const GQL_VERSION = "2026-04-16";
const TZ = "America/New_York";

const db = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

const ENTITY_TYPE = "calendar_task";                            // entity_source_links.entity_type

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-api-version",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

// Every error carries {ok:false, code, message} in the BODY as well as an HTTP status, so the app
// can branch on `code` without parsing prose and without depending on the status reaching it.
// ⚠ NOTE FOR THE APP (Task 5): this differs from save-calendar-visit, which returns business
// failures at HTTP 200 with ok:false. Here a failure carries a REAL status (400/401/403/409/502),
// so supabase-js functions.invoke() resolves it as a FunctionsHttpError with data:null — the body
// must be read with `await error.context.json()`. Reading only `data.ok` will show a generic error
// instead of the typed one.
const fail = (status: number, code: string, message: string, extra: Record<string, unknown> = {}) =>
  json({ ok: false, code, message, ...extra }, status);

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

// ============================================================================================
// 🛑 THIS COPY OF etToUtcISO IS **DELIBERATELY NOT IDENTICAL** TO jobber-push-task's.
//    DO NOT "RESTORE" IT ON THE GROUNDS THAT THE COPIES SHOULD MATCH.
// ============================================================================================
// Everything else in this file's helper block IS byte-for-byte from jobber-push-task, and the
// build-time check still asserts that. This one is the single, deliberate exception, because the
// shared original has a DST SPRING-FORWARD BUG:
//
//   It probes the zone offset at 12:00 UTC — which is 07:00/08:00 ET, i.e. AFTER the 02:00
//   transition — and then applies that post-transition offset to minute 0, which is BEFORE it.
//   Measured on the original bytes:
//       2026-03-08 min 0   -> 2026-03-08T04:00:00Z -> ET 2026-03-07 23:00   *** wrong day ***
//       2027-03-14 min 0   -> 2027-03-14T04:00:00Z -> ET 2027-03-13 23:00   *** wrong day ***
//       2028-03-12 min 0   -> 2028-03-12T04:00:00Z -> ET 2028-03-11 23:00   *** wrong day ***
//       fall-back and ordinary dates: correct. minutes >= 120: correct.
//   So it is wrong for minutes 0-119 on exactly one date a year, in the direction that moves the
//   task to the PREVIOUS DAY.
//
// WHY IT HAD TO BE FIXED HERE AND NOT SHARED: for a TIMED task the read-back CANNOT SEE IT. We
//   send the wrong instant, Jobber stores and echoes exactly that instant, near() compares
//   instants, and verification PASSES. A task scheduled 00:30 ET on 2026-03-08 lands 23:30 ET on
//   2026-03-07 in Jobber while our copy says Mar 8 with verified:true — a written, verified-clean
//   discrepancy, which is the one thing this whole function exists to prevent.
//
// 🛑 jobber-push-task AND jobber-push-visit STILL CARRY THE BUG. Both are LIVE. Fixing the shared
//   source touches production functions that own the day markers and every Calendar visit push,
//   which was out of scope for the task that wrote this file. It is a real open item, not an
//   oversight: whoever picks it up should port the version below and re-verify both callers.
//
// HOW THIS ONE WORKS: it asks the zone for its offset AT THE CANDIDATE INSTANT rather than at an
//   arbitrary probe time, twice — the first pass guesses, the second settles the DST edge — and
//   then ROUND-TRIPS: it formats the answer back to ET and requires the wall clock it gets is the
//   wall clock that was asked for. That last step is what makes it honest rather than merely
//   better, and it is why the return type is nullable: 02:00-02:59 ET does not exist at all on a
//   spring-forward date, so there IS no correct instant and the caller is told so instead of being
//   handed a plausible wrong one.

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

// ============================================================================================
// Small local helpers
// ============================================================================================
const OPS = ["create", "edit", "complete", "delete"] as const;
type Op = (typeof OPS)[number];

// Key PRESENCE is the whole contract on the RPC side (a key present is written, a key absent is
// left alone), so presence has to be read the same way here rather than inferred from undefined.
const has = (o: Record<string, unknown>, k: string) => Object.prototype.hasOwnProperty.call(o, k);

const isIntIn = (v: unknown, lo: number, hi: number) =>
  typeof v === "number" && Number.isInteger(v) && v >= lo && v <= hi;

// Resolve OUR ids to Jobber GIDs through entity_source_links. Returns a Map; a missing id simply
// does not appear, and every caller REFUSES on a miss rather than dropping it.
async function gidsFor(entityType: string, ids: number[]): Promise<Map<number, string>> {
  const out = new Map<number, string>();
  if (!ids.length) return out;
  const { data, error } = await db.from("entity_source_links")
    .select("entity_id, source_id")
    .eq("entity_type", entityType).eq("source_system", "jobber").in("entity_id", ids);
  if (error) throw new Error(`${entityType} link lookup failed: ${error.message}`);
  for (const r of data ?? []) if (r.source_id) out.set(Number(r.entity_id), r.source_id as string);
  return out;
}

// 🛑 A PostgREST RPC error is mapped by SQLSTATE, not by message text. The codes are the contract
// ops.fn_record_calendar_task publishes (see 2026-08-26_1820); anything unmapped is a 500 on
// purpose, because an unrecognised failure must never be reported to the app as a tidy 400.
function mapRpcError(e: { code?: string; message?: string; details?: string; hint?: string }) {
  const msg = e?.message ?? "unknown database error";
  switch (e?.code) {
    case "22023": return { status: 400, code: "invalid_input", message: msg };
    case "23502": return { status: 400, code: "invalid_input", message: msg };
    case "22P02": return { status: 400, code: "invalid_input", message: msg };
    // The link row outlived its task. A real, benign race — not a bug — and the save is refused
    // rather than reporting a dead id as a success.
    case "23503": return { status: 409, code: "orphan_link", message: msg };
    // Should be unreachable: the RPC takes an xact advisory lock on the GID before it looks.
    case "23505": return { status: 409, code: "conflict", message: msg };
    case "PGRST202": return { status: 500, code: "rpc_missing", message: `RPC not found — ${msg}` };
    default: return { status: 500, code: "db_error", message: msg };
  }
}

const M_TASK_DELETE = `mutation($ids: [EncodedId!]!){ taskDelete(taskIds: $ids){
  userErrors{ message } } }`;

const Q_TASK = `query($id: EncodedId!){ task(id: $id){ id title instructions allDay startAt endAt
  isComplete client{ id } property{ id } assignedUsers(first: 30){ nodes{ id } } } }`;

// 🛑 POSITIVE PROOF THAT JOBBER ANSWERED, lifted from jobber-push-task's delete path. A response
// with NO `data` key (the HTML waiting room, a THROTTLED envelope, a JSON auth error) makes
// `undefined?.task?.id` falsy in exactly the same way a genuine {"data":{"task":null}} does.
// Absence of evidence must not be read as evidence of absence.
const answered = (res: unknown) =>
  !!res && typeof res === "object" &&
  Object.prototype.hasOwnProperty.call(res, "data") &&
  !!(res as { data?: unknown }).data && typeof (res as { data?: unknown }).data === "object";

// 🛑 THE READ-BACK GATE. Returns the list of things Jobber does NOT confirm; EMPTY means verified,
// and only an empty list is allowed to reach the RPC. A 200 with no userErrors is not proof Jobber
// holds what we think it holds — this is what turns "the mutation returned" into "the change is
// really there".
// It is a pure function on purpose: that is what lets it be unit-tested against real Jobber
// payloads WITHOUT performing a write, including the case that matters most — a mutation that
// reports success while the read-back disagrees.
// The ET CALENDAR DATE of an instant. This is the unit an all-day task is expressed in, and the
// only honest thing to compare it on: Jobber stores an all-day task as ET 00:00:00 -> ET 23:59:59,
// so comparing instants misses by a second while comparing dates is exact.
function etDateOf(iso: string | null | undefined): string | null {
  if (!iso) return null;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  return etWall(d.getTime()).date;      // one source of ET parts, shared with etToUtcISO
}

type TaskWant = {
  title: string; instructions: string | null; taskDate: string;
  allDay: boolean; startAt: string; endAt: string;
  // null = "make it none" (assert it IS none). undefined = "not stated" (assert nothing).
  clientGid: string | null | undefined; propertyGid: string | null | undefined;
  // null = we did NOT send assignedTo, so Jobber's set is none of our business on this save.
  assignedGids: string[] | null;
};
function verifyTask(t: any, want: TaskWant): string[] {
  const bad: string[] = [];
  if (!t || !t.id) { bad.push("Jobber did not return the task"); return bad; }
  if (t.title !== want.title) bad.push(`title (sent "${want.title}", Jobber has "${t.title}")`);
  if (t.allDay !== want.allDay) bad.push(`allDay (sent ${want.allDay}, Jobber has ${t.allDay})`);

  // instructions: NORMALISED, not exact. We compare trimmed-or-empty because Jobber may trim, and
  // a false refusal on whitespace would block a perfectly good save. It still catches the thing
  // worth catching: instructions that did not save at all, or saved as something else.
  const wantInstr = (want.instructions ?? "").trim();
  const gotInstr = (t.instructions ?? "").trim();
  if (wantInstr !== gotInstr) {
    // ⚠ Show the CONTENT, not just the lengths. "abc" vs "xyz" used to render as
    // `(sent 3 chars, Jobber has 3)`, which reads like agreement on a line reporting a refusal.
    const snip = (x: string) => x === "" ? "(empty)" : JSON.stringify(x.length > 40 ? x.slice(0, 40) + "…" : x);
    bad.push(`instructions (sent ${snip(wantInstr)}, Jobber has ${snip(gotInstr)})`);
  }

  // 🛑 THE DATE, ON BOTH KINDS OF TASK. An all-day task DOES carry a date (13 of 16 live all-day
  // tasks do; the 3 that do not are UNSCHEDULED — see the header). Comparing the ET calendar date
  // is what makes "Jobber dropped our startAt and left it unscheduled" — the most likely all-day
  // failure mode, because taskCreate takes a UTC instant while Jobber's all-day input wants
  // {startDate, timezone} — visible instead of silently accepted.
  if (want.allDay) {
    const gotStart = etDateOf(t.startAt);
    const gotEnd = etDateOf(t.endAt);
    if (!t.startAt) {
      bad.push("all-day task has NO date in Jobber (it is UNSCHEDULED, not all-day)");
    } else if (gotStart !== want.taskDate) {
      bad.push(`date (sent ${want.taskDate}, Jobber has ${gotStart} ET)`);
    }
    // We only ever create SINGLE-day all-day tasks, so a differing end date means Jobber made a
    // multi-day task we did not ask for. Multi-day all-day tasks do exist in this account (one
    // spans 2025-10-26 -> 2025-10-30), so this is a real state, not a theoretical one.
    if (t.endAt && gotEnd !== want.taskDate) {
      bad.push(`end date (sent ${want.taskDate}, Jobber has ${gotEnd} ET — a multi-day task)`);
    }
  } else {
    const near = (a: string | null, b: string) =>
      !!a && Math.abs(new Date(a).getTime() - new Date(b).getTime()) < 60_000;
    if (!near(t.startAt, want.startAt)) bad.push(`startAt (sent ${want.startAt}, Jobber has ${t.startAt})`);
    if (!near(t.endAt, want.endAt)) bad.push(`endAt (sent ${want.endAt}, Jobber has ${t.endAt})`);
  }

  // 🛑 EQUALITY, NOT "did it attach". `if (want.clientGid && ...)` skipped the check entirely when
  // we were DETACHING (clientGid null), so "our copy says no client, Jobber still says client X"
  // passed verification. The RPC clears the column on an explicit null, so that divergence was
  // real and reachable.
  // undefined = the caller never mentioned it, so this save did not touch it and has no business
  // asserting on it. null = an explicit detach, which IS asserted — that is finding 2.
  if (want.clientGid !== undefined) {
    const gotClient = t.client?.id ?? null;
    if (gotClient !== want.clientGid) {
      bad.push(`client (sent ${want.clientGid ?? "none"}, Jobber has ${gotClient ?? "none"})`);
    }
  }
  if (want.propertyGid !== undefined) {
    const gotProperty = t.property?.id ?? null;
    if (gotProperty !== want.propertyGid) {
      bad.push(`property (sent ${want.propertyGid ?? "none"}, Jobber has ${gotProperty ?? "none"})`);
    }
  }

  // 🛑 SET EQUALITY, NOT A SUBSET TEST. The old check only asked whether everything we sent was
  // present, so an EXTRA assignee Jobber kept verified clean. Whether taskEdit's assignedTo
  // replaces or appends is UNMEASURED (Task 8), and a subset test cannot tell the difference —
  // which is exactly why it has to be equality. assignedUsers(first:30) is already fetched.
  if (want.assignedGids !== null) {
    const got = (t.assignedUsers?.nodes ?? []).map((u: { id: string }) => u?.id).filter(Boolean).sort();
    const wanted = [...want.assignedGids].sort();
    if (got.length !== wanted.length || got.some((g: string, i: number) => g !== wanted[i])) {
      bad.push(`assignees (sent ${wanted.length}, Jobber has ${got.length}; sets differ)`);
    }
  }
  return bad;
}

// 🛑 DELETE A JOBBER TASK AND PROVE IT IS GONE. Used both for a real delete and for compensating
// a create we could not record. The old compensation asserted `rolled_back: true` from
// "the mutation returned without an error" — the exact standard this file rejects everywhere else,
// and in the worst possible place, because this boolean decides whether an operator is told "no
// orphan" or "MANUAL CLEANUP NEEDED". It now reads the task back, like the delete branch always did.
//
// Returns:
//   gone:true            -> proven absent by read-back. Safe to drop our side.
//   gone:false + reason  -> either still there, or Jobber never answered. NEVER treat as gone.
// `alreadyGone` distinguishes "the mutation errored but the task is absent anyway" (an idempotent
// re-delete) from "the mutation errored and the task is still there".
// `kind` is STRUCTURED so the caller never has to sniff the prose. An earlier caller did
// `del.reason?.includes("rejected")` to choose an error code — correct at the time and coupled to
// wording, which is a defect waiting for someone to improve a sentence.
//   "rejected"    Jobber actively refused and the task is still there.
//   "unanswered"  we cannot tell — including a refusal we could not follow up. Not the same thing.
async function deleteAndVerify(token: string, gid: string): Promise<
  { gone: boolean; alreadyGone: boolean; kind: "gone" | "rejected" | "unanswered"; reason: string | null }
> {
  const res = await gql(token, M_TASK_DELETE, { ids: [gid] });
  const errs = errsOf(res, "taskDelete");

  // Read back regardless of what the mutation said. A mutation error on an ALREADY-deleted id is
  // the wedge case (finding 7): without this, a retry after an unconfirmed delete would keep
  // erroring forever and the link could never be removed.
  const check = await gql(token, Q_TASK, { id: gid });
  if (!answered(check)) {
    // UNANSWERED even when the mutation errored: the salient fact is that we cannot tell whether
    // the task is gone, not that a call was refused. Reporting this as "rejected" would tell an
    // operator something more definite than we actually know.
    return { gone: false, alreadyGone: false, kind: "unanswered", reason: errs.length
      ? `Jobber rejected the delete (${errs.join("; ")}) and then did not answer the read-back, so we cannot tell whether the task is gone`
      : "Jobber did not answer the read-back, so we cannot tell whether the task is gone" };
  }
  if (check.data.task?.id) {
    return { gone: false, alreadyGone: false, kind: "rejected", reason: errs.length
      ? `Jobber rejected the delete: ${errs.join("; ")}`
      : "Jobber reported no error but the task is still there" };
  }
  // Absent. If the mutation errored, the task was already gone — a retry of a delete that had in
  // fact succeeded. That is the outcome the caller asked for, so it is a success.
  return { gone: true, alreadyGone: errs.length > 0, kind: "gone", reason: null };
}

// ============================================================================================
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return fail(405, "method_not_allowed", "POST only.");

  // ---- AUTH: a real, staff-domain human. Never service_role-by-default. --------------------
  const m = (req.headers.get("authorization") ?? "").match(/^Bearer (.+)$/);
  if (!m) return fail(401, "unauthorized", "Sign in again.");
  const { data: userData, error: userErr } = await db.auth.getUser(m[1]);
  const email = (userData?.user?.email ?? "").toLowerCase();
  if (userErr || !email || (!email.endsWith("@ayache.com") && !email.endsWith("@unclogme.com"))) {
    return fail(403, "forbidden", "Not a staff account.");
  }

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return fail(400, "bad_request", "Malformed JSON."); }
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return fail(400, "bad_request", "Body must be a JSON object.");
  }

  const op = String(body.op ?? "") as Op;
  if (!OPS.includes(op)) {
    return fail(400, "bad_request", `op must be one of ${OPS.join(" | ")}.`);
  }

  // Tracked OUTSIDE the try so the CATCH can still name the task. gql() calls fetch(), which
  // rejects on a network failure — without this, a throw between a successful taskCreate and the
  // RPC reached the generic catch and returned a bare fail(500,"unexpected") with NO gid, leaving
  // a real Task on the crew's schedule with nothing in our system pointing at it.
  let createdGid: string | null = null;

  try {
    // ========================================================================================
    // 1. Resolve the existing task + its Jobber GID (everything except create)
    // ========================================================================================
    let link: { id: number; source_id: string } | null = null;
    let cur: Record<string, unknown> | null = null;
    let taskId = 0;

    if (op !== "create") {
      taskId = Number(body.task_id);
      if (!Number.isInteger(taskId) || taskId <= 0) {
        return fail(400, "bad_request", "task_id is required for this op.");
      }
      const { data: l, error: lErr } = await db.from("entity_source_links")
        .select("id, source_id").eq("entity_type", ENTITY_TYPE)
        .eq("entity_id", taskId).eq("source_system", "jobber").maybeSingle();
      if (lErr) return fail(500, "db_error", `link lookup failed: ${lErr.message}`);
      if (!l?.source_id) {
        return fail(409, "not_linked",
          "This task has no Jobber link, so there is nothing to change in Jobber. Refusing rather than writing a local-only change.");
      }
      link = l as { id: number; source_id: string };

      const { data: row, error: rErr } = await db.schema("ops").from("calendar_tasks")
        .select("*").eq("id", taskId).maybeSingle();
      if (rErr) return fail(500, "db_error", `task read failed: ${rErr.message}`);
      if (!row) {
        // The link row outlived its task — the same state the RPC raises 23503 on. Caught here so
        // it is reported before anything is pushed to Jobber.
        return fail(409, "orphan_link",
          `entity_source_links says Jobber task ${link.source_id} is calendar task ${taskId}, but that task no longer exists. Refusing.`);
      }
      cur = row as Record<string, unknown>;
      // ⚠ The current assignee set is deliberately NOT fetched. It used to be, and to be restated
      // on every edit — which is what made an edit refuse outright when a PRE-EXISTING assignee's
      // Jobber link had since been removed, blocking an unrelated title change. An unstated
      // assignee list now leaves Jobber and our copy alone, which is what patch semantics mean.
    }

    // ========================================================================================
    // 2. THE DELETE PATH — Jobber first, positive proof, then the RPC.
    // ========================================================================================
    if (op === "delete") {
      const token = await getJobberToken();

      // deleteAndVerify reads the task back whatever the mutation said, which is what makes a
      // RETRY work. Finding 7: if Jobber's read-back failed AFTER the delete had actually
      // succeeded, the link was correctly kept — but every retry then called taskDelete on a dead
      // id, and if that errors the branch used to return jobber_rejected forever with no way to
      // ever remove the link. Now an errored delete whose read-back proves the task is absent is
      // treated as the success it is.
      const del = await deleteAndVerify(token, link!.source_id);
      if (!del.gone) {
        return fail(502, del.kind === "rejected" ? "jobber_rejected" : "jobber_unverified",
          `${del.reason}. Nothing was deleted on our side — the link is KEPT so the task can still be reached. Retry once Jobber is responding.`,
          { jobber_task: link!.source_id });
      }
      if (del.alreadyGone) {
        console.warn(`[calendar-task] taskDelete errored but ${link!.source_id} is absent — treating as an idempotent re-delete`);
      }

      // Jobber has confirmed it is gone. Only now does our copy change.
      const { data: removed, error: dErr } = await db.schema("ops")
        .rpc("fn_delete_calendar_task", { p_task_id: taskId, p_actor_email: email });
      if (dErr) {
        // ⚠ NOT COMPENSABLE, and said out loud rather than buried. The Jobber Task is already gone
        // and cannot be un-deleted; our row survives. This is the one residual window in the saga.
        const mapped = mapRpcError(dErr);
        console.error(`[calendar-task] DELETE OUT OF STEP: Jobber task ${link!.source_id} is gone but calendar task ${taskId} could not be removed: ${mapped.message}`);
        return fail(mapped.status, "local_delete_failed",
          `The Jobber task was deleted but our copy could not be removed (${mapped.message}). The two are now out of step — retry the delete.`,
          { jobber_deleted: true, jobber_task: link!.source_id, db_code: dErr.code });
      }
      return json({
        ok: true, op: "delete", task_id: taskId, jobber_task: link!.source_id,
        verified_gone: true, already_gone_in_jobber: del.alreadyGone, row_removed: removed === true,
      });
    }

    // ========================================================================================
    // 2b. COMPLETE — its own mutation, and it touches NO other field.
    // 🛑 IT RUNS BEFORE THE MERGE ON PURPOSE. An earlier version fell through section 3 first,
    // which resolved the task's client/property to Jobber GIDs and REFUSED with client_unlinked if
    // that link had since been removed — blocking a completion for a reason completion has nothing
    // to do with. Completion needs only the task's own GID and the requested boolean.
    // ========================================================================================
    if (op === "complete") {
      // Validate BEFORE fetching a Jobber token: a request that is about to 400 should not cost an
      // OAuth round trip (and a refresh write) on the way there.
      if (typeof body.completed !== "boolean") {
        return fail(400, "invalid_input", "completed must be true or false.");
      }
      const wanted = body.completed;
      const token = await getJobberToken();
      const res = await gql(token, `mutation($id: EncodedId!, $c: Boolean!){
        appointmentEditCompleteness(appointmentId: $id, input: { completed: $c }){
          appointment{ id } userErrors{ message } } }`, { id: link!.source_id, c: wanted });
      const errs = errsOf(res, "appointmentEditCompleteness");
      if (errs.length) {
        return fail(502, "jobber_rejected",
          `Jobber refused the completion change, so it was not applied here either: ${errs.join("; ")}`,
          { jobber_errors: errs });
      }

      // READ IT BACK. isComplete must be exactly what we asked for.
      const check = await gql(token, Q_TASK, { id: link!.source_id });
      const t = check?.data?.task;
      if (!answered(check) || !t || t.isComplete !== wanted) {
        return fail(502, "jobber_unverified",
          "Jobber did not confirm the completion change, so nothing was changed here. Try again.",
          { expected: { isComplete: wanted }, got: t ? { isComplete: t.isComplete } : null });
      }

      const { data: recId, error: rpcErr } = await db.schema("ops")
        .rpc("fn_record_calendar_task", {
          p: {
            jobber_gid: link!.source_id,
            is_complete: wanted,
            // completed_source is REQUIRED when is_complete is true, and it is 'calendar' because
            // the Calendar is what made this call. The poll writes 'jobber' for the other side.
            ...(wanted ? { completed_source: "calendar", completed_at: new Date().toISOString() } : {}),
          },
          p_actor_email: email,
        });
      if (rpcErr) {
        const mapped = mapRpcError(rpcErr);
        return fail(mapped.status, mapped.code,
          `Jobber accepted the change but our copy could not be updated: ${mapped.message}`,
          { jobber_task: link!.source_id, jobber_is_complete: wanted, db_code: rpcErr.code });
      }
      return json({
        ok: true, op: "complete", task_id: Number(recId), jobber_task: link!.source_id,
        is_complete: wanted, verified: true,
      });
    }

    // ========================================================================================
    // 3. Merge the requested change onto the current state.
    //    The SAME merged values go to Jobber and to the RPC, so the two cannot describe
    //    different things — that is the point of merging here instead of patching twice.
    // ========================================================================================
    const title = has(body, "title") ? String(body.title ?? "").trim() : String(cur?.title ?? "");
    if (!title) return fail(400, "invalid_input", "title is required and may not be blank (Jobber requires it too).");

    const instructions = has(body, "instructions")
      ? (body.instructions === null ? null : String(body.instructions))
      : ((cur?.instructions as string | null) ?? null);

    const taskDate = has(body, "task_date") ? String(body.task_date ?? "") : String(cur?.task_date ?? "");
    if (!/^\d{4}-\d{2}-\d{2}$/.test(taskDate)) {
      return fail(400, "invalid_input", "task_date is required and must be YYYY-MM-DD.");
    }
    // 🛑 THE SHAPE CHECK ABOVE IS NOT A DATE CHECK. It admits 2026-02-30 / 2026-04-31 / 2026-13-05
    // / 2026-00-10, all of which then make etToUtcISO return null — the SAME signal the
    // spring-forward gap uses — so an impossible date used to be explained as a daylight-saving
    // problem. Both refuse and write nothing; only one of them was telling the truth.
    if (!isRealCalendarDate(taskDate)) {
      return fail(400, "invalid_input",
        `${taskDate} is not a real date on the calendar. Check the day and month.`);
    }

    // ---- all-day vs timed -------------------------------------------------------------------
    // 🛑 all_day is DERIVED from minutes on the RPC side and an explicit null RAISES 22023, so the
    // app's convenience flag is translated into minutes HERE and `all_day` is never forwarded.
    // That also makes {...task, all_day: task.all_day ?? null} — the natural client spread — safe.
    let allDay: boolean;
    if (has(body, "minutes")) allDay = body.minutes === null;
    else if (has(body, "all_day")) allDay = body.all_day === true;
    else if (cur) allDay = cur.all_day === true;
    else return fail(400, "invalid_input", "A new task needs either minutes (0-1439) or all_day: true.");

    let minutes: number | null = null;
    if (!allDay) {
      const raw = has(body, "minutes") ? body.minutes : cur?.minutes;
      if (!isIntIn(raw, 0, 1439)) {
        return fail(400, "invalid_input", "minutes must be a whole number of minutes past ET midnight (0-1439), or null for an all-day task.");
      }
      minutes = raw as number;
    }

    // ⚠ duration is resolved AFTER all_day, and is sent EXPLICITLY on every timed save. A task
    // leaving all-day whose payload omits duration_minutes would otherwise be reset to the column
    // default of 30 by the RPC, silently shrinking a task the office never touched the length of.
    let duration = 30;
    if (!allDay) {
      if (has(body, "duration_minutes")) {
        if (!isIntIn(body.duration_minutes, 1, 1440)) {
          return fail(400, "invalid_input", "duration_minutes must be a whole number between 1 and 1440.");
        }
        duration = body.duration_minutes as number;
      } else if (cur && cur.all_day !== true) {
        duration = Number(cur.duration_minutes ?? 30);
      }
    }

    // ---- FK targets: validated BEFORE Jobber is touched -------------------------------------
    // An unknown client/property/visit id would come back from the RPC as a 23503 foreign-key
    // violation AFTER the Jobber write had already landed, and 23503 is also the orphan-link code,
    // so it would be reported as the wrong thing entirely. Check first; fail before pushing.
    //
    // 🛑 TRI-STATE, LIKE ASSIGNEES: `undefined` = the caller did not mention it, so leave BOTH
    // sides alone. This is the THIRD appearance of one shape — an operation refusing because of a
    // field it does not touch. It blocked completion on a stale client link, it blocked an edit on
    // a stale assignee link, and it would have blocked a TITLE-ONLY edit with client_unlinked when
    // a pre-existing client's link row had since vanished. Deciding it deliberately rather than by
    // omission: an unstated field is not a decision, so it must not be resolved, sent, or asserted.
    // A DETACH is still a stated `client_id: null`, so finding 2 stays fixed — the difference
    // between "make it none" and "do not touch it" is exactly key presence.
    // On a CREATE there is no previous value, so an absent key genuinely means "none".
    const stated = (k: string) => op === "create" || has(body, k);
    const pickId = (k: string): number | null | undefined => {
      if (!stated(k)) return undefined;
      const raw = has(body, k) ? body[k] : null;
      return raw === null || raw === undefined ? null : Number(raw);
    };
    const clientId = pickId("client_id");
    const propertyId = pickId("property_id");
    const visitId = pickId("visit_id");
    for (const [k, v] of [["client_id", clientId], ["property_id", propertyId], ["visit_id", visitId]] as const) {
      if (v !== undefined && v !== null && (!Number.isInteger(v) || v <= 0)) {
        return fail(400, "invalid_input", `${k} must be a positive integer or null.`);
      }
    }
    for (const [k, v, table] of [["client_id", clientId, "clients"], ["property_id", propertyId, "properties"], ["visit_id", visitId, "visits"]] as const) {
      if (v === undefined || v === null) continue;
      const { data: found, error: fErr } = await db.from(table).select("id").eq("id", v).maybeSingle();
      if (fErr) return fail(500, "db_error", `${table} lookup failed: ${fErr.message}`);
      if (!found) return fail(400, "invalid_input", `${k} ${v} does not exist.`);
    }

    // ---- assignees ---------------------------------------------------------------------------
    let assigneeIds: number[] | null = null;              // null = "not stated", leave both sides alone
    if (has(body, "assignee_ids")) {
      const arr = body.assignee_ids;
      if (arr !== null && !Array.isArray(arr)) {
        return fail(400, "invalid_input", "assignee_ids must be an array of employee ids, or null.");
      }
      const list = (arr ?? []) as unknown[];
      if (list.some((x) => !isIntIn(x, 1, Number.MAX_SAFE_INTEGER))) {
        return fail(400, "invalid_input", "assignee_ids may contain only positive whole employee ids.");
      }
      assigneeIds = [...new Set(list as number[])];
    }
    // ⚠ NOT stated = leave BOTH sides alone. An earlier version restated the CURRENT set on every
    // edit, which meant an edit refused outright if a pre-existing assignee's Jobber link had since
    // been removed — the same over-coupling that made completion depend on the client link.

    let assignedGids: string[] | null = null;   // null = do not send assignedTo, do not assert on it
    if (assigneeIds?.length) {
      const map = await gidsFor("employee", assigneeIds);
      const missing = assigneeIds.filter((id) => !map.has(id));
      // 🛑 REFUSE rather than drop. jobber-push-task drops an unlinked driver because a route
      // marker is still worth showing; here a dropped assignee IS a discrepancy — our row would
      // claim an assignment Jobber never received, which is the one thing this feature exists to
      // prevent. Fail closed and name the employees so it is actionable.
      if (missing.length) {
        return fail(400, "assignee_unlinked",
          `These employees have no linked Jobber user, so Jobber cannot be told about the assignment: ${missing.join(", ")}. Nothing was saved.`,
          { unlinked_employee_ids: missing });
      }
      assignedGids = assigneeIds.map((id) => map.get(id)!);
    }

    // undefined = not stated: do not resolve it, do not send it, do not assert on it.
    let clientGid: string | null | undefined = clientId === undefined ? undefined : null;
    let propertyGid: string | null | undefined = propertyId === undefined ? undefined : null;
    if (clientId !== undefined && clientId !== null) {
      const map = await gidsFor("client", [clientId]);
      clientGid = map.get(clientId) ?? null;
      if (!clientGid) {
        return fail(400, "client_unlinked",
          `Client ${clientId} has no linked Jobber client, so the task cannot be attached to it in Jobber. Nothing was saved.`);
      }
    }
    if (propertyId !== undefined && propertyId !== null) {
      const map = await gidsFor("property", [propertyId]);
      propertyGid = map.get(propertyId) ?? null;
      if (!propertyGid) {
        return fail(400, "property_unlinked",
          `Property ${propertyId} has no linked Jobber property, so the task cannot be attached to it in Jobber. Nothing was saved.`);
      }
    }

    // ---- the Jobber time window -------------------------------------------------------------
    // ET midnight for an all-day task, matching exactly how Jobber stores its own: all 13 dated
    // all-day tasks in this account read ET 00:00:00 -> ET 23:59:59 with duration 1440.
    //
    // 🛑 THE END IS DERIVED FROM THE ET WALL CLOCK, NOT start + 24h. On a spring-forward date the
    //    ET day is only 23 HOURS long, so `startAt + 1440min - 1s` lands at 00:59:59 the NEXT day
    //    and verifyTask's end-date check would refuse every all-day save on that date. Asking for
    //    ET 23:59 on the same date is correct on all three kinds of day.
    const startAt = etToUtcISO(taskDate, allDay ? 0 : (minutes as number));
    if (startAt === null) {
      // Only reachable in the spring-forward gap: 02:00-02:59 ET does not exist on that date.
      return fail(400, "invalid_input",
        `There is no ${String(Math.floor((minutes ?? 0) / 60)).padStart(2, "0")}:${String((minutes ?? 0) % 60).padStart(2, "0")} on ${taskDate} in Eastern Time — the clocks jump from 02:00 to 03:00 that morning. Pick another time.`);
    }
    const endBase = allDay ? etToUtcISO(taskDate, 1439) : null;
    if (allDay && endBase === null) {
      return fail(500, "unexpected", `Could not derive the end of ${taskDate} in Eastern Time.`);
    }
    const endAt = allDay
      ? new Date(new Date(endBase as string).getTime() + 59_000).toISOString()   // ET 23:59:00 -> 23:59:59
      : new Date(new Date(startAt).getTime() + duration * 60_000).toISOString();

    // ========================================================================================
    // 5. CREATE / EDIT
    // ========================================================================================
    const token = await getJobberToken();

    const input: Record<string, unknown> = { title, instructions, startAt, endAt, allDay };
    // ⚠ OMIT the key when nobody is resolved, never send []. Sending [] strips an assignment a
    // dispatcher set by hand in Jobber. assignedGids is null exactly when the caller did not state
    // an assignee list, and verifyTask then asserts nothing about Jobber's set either.
    if (assignedGids?.length) input.assignedTo = assignedGids;

    if (op === "edit") {
      // 🛑 SEND THE DETACH. taskEdit carries clientId/propertyId INSIDE the input (the mirror image
      // of taskCreate), and TaskEditInput.clientId is NULLABLE. An earlier version wrote
      // `if (clientGid) input.clientId = clientGid`, which OMITTED the key when detaching — so
      // Jobber kept the old client while the RPC's patch semantics cleared our column on the
      // explicit null. Our copy said "no client", Jobber said "client X", and the old verifyTask
      // guarded with `if (want.clientGid && ...)` so nothing caught it. Both are fixed: the key is
      // always sent, and verifyTask now compares for EQUALITY including null.
      if (clientGid !== undefined) input.clientId = clientGid;        // null = an explicit DETACH
      if (propertyGid !== undefined) input.propertyId = propertyGid;
    }

    let gid = link?.source_id ?? "";
    // Tracked OUTSIDE the try/catch region below so that a THROW after taskCreate succeeded still
    // reports the gid. gql() calls fetch(), which rejects on a network failure — without this, a
    // throw between the create and the RPC reached the generic catch and returned a bare
    // fail(500,"unexpected") with no gid at all, leaving a real Task on the crew's schedule with
    // nothing in our system pointing at it. See the catch at the end of the handler.
    if (op === "edit") {
      const res = await gql(token, `mutation($id: EncodedId!, $in: TaskEditInput!){
        taskEdit(taskId: $id, input: $in){ task{ id } userErrors{ message } } }`,
        { id: gid, in: input });
      const errs = errsOf(res, "taskEdit");
      if (errs.length) {
        return fail(502, "jobber_rejected",
          `Jobber refused the change, so nothing was saved here either: ${errs.join("; ")}`,
          { jobber_errors: errs });
      }
    } else {
      // taskCreate takes clientId/propertyId as TOP-LEVEL ARGS, not input fields. They are only
      // declared when we actually have one — an explicit null on a nullable arg is a behaviour
      // nobody has measured, and there is no reason to find out the hard way on a real create.
      const decls = ["$in: TaskCreateInput!"];
      const args = ["input: $in"];
      const vars: Record<string, unknown> = { in: input };
      if (clientGid) { decls.push("$clientId: EncodedId"); args.push("clientId: $clientId"); vars.clientId = clientGid; }
      if (propertyGid) { decls.push("$propertyId: EncodedId"); args.push("propertyId: $propertyId"); vars.propertyId = propertyGid; }
      const res = await gql(token, `mutation(${decls.join(", ")}){
        taskCreate(${args.join(", ")}){ task{ id } userErrors{ message } } }`, vars);
      const errs = errsOf(res, "taskCreate");
      if (errs.length) {
        return fail(502, "jobber_rejected",
          `Jobber refused to create the task, so nothing was saved here: ${errs.join("; ")}`,
          { jobber_errors: errs });
      }
      gid = res?.data?.taskCreate?.task?.id ?? "";
      if (!gid) {
        return fail(502, "jobber_unverified",
          "Jobber reported no error but returned no task id, so we cannot record the task. Nothing was saved.");
      }
      createdGid = gid;          // from here on, a throw MUST still name this task
    }

    // ---- READ THE TASK BACK. A 200 with no userErrors is not proof Jobber holds what we think. --
    const check = await gql(token, Q_TASK, { id: gid });
    // `answered` first: a reply with NO data key (the HTML waiting room, a THROTTLED envelope, a
    // JSON auth error) must read as "Jobber did not answer", not as "the task is not there".
    const t = answered(check) ? check.data.task : null;
    const mismatches = verifyTask(t, {
      title, instructions, taskDate, allDay, startAt, endAt, clientGid, propertyGid, assignedGids,
    });

    if (mismatches.length) {
      // On a CREATE the Task now exists in Jobber and we are refusing to record it, so it would be
      // an orphan nobody can reach. Compensate exactly as jobber-push-task does. On an EDIT the
      // Task legitimately pre-exists and must survive.
      let rolledBack = false;
      if (op === "create") {
        // ⚠ PROVEN by read-back, not inferred from "the mutation returned without an error".
        // This boolean decides whether an operator is told "no orphan" or "MANUAL CLEANUP NEEDED",
        // which makes it the worst possible place to relax the standard the line above enforces.
        const del = await deleteAndVerify(token, gid);
        rolledBack = del.gone;
        createdGid = del.gone ? null : gid;
      }
      // 🛑 LOG THE ORPHAN SERVER-SIDE. Reporting it only in the HTTP body means no trace at all if
      // the app does not surface `note`.
      if (op === "create" && !rolledBack) {
        console.error(`[calendar-task] ORPHANED Jobber task ${gid}: created, verification failed (${mismatches.join("; ")}), rollback did NOT confirm. MANUAL CLEANUP NEEDED.`);
      }
      return fail(502, "jobber_unverified",
        `Jobber did not confirm the change (${mismatches.join("; ")}), so nothing was saved here.`,
        {
          jobber_task: gid,
          rolled_back: op === "create" ? rolledBack : undefined,
          note: op === "create"
            ? (rolledBack ? "The Jobber task was removed, no orphan." : `ORPHANED Jobber task ${gid} — MANUAL CLEANUP NEEDED.`)
            : undefined,
        });
    }

    // ========================================================================================
    // 6. Jobber has confirmed. ONLY NOW is our copy written.
    // ========================================================================================
    // 🛑 The RPC's own traps, all handled above and restated here so nobody re-introduces them:
    //   * `all_day` is NEVER sent — it is derived, and an explicit null raises 22023.
    //   * an all-day task sends `minutes: null` EXPLICITLY (the only way to convert timed ->
    //     all-day) and omits duration_minutes (it is discarded on an all-day row anyway).
    //   * a timed task ALWAYS sends duration_minutes, so leaving all-day cannot silently reset it.
    //   * p_actor_email comes from auth.getUser(), never from the caller, and has NO DEFAULT —
    //     omitting it is a PGRST202 404, not a readable error.
    const p: Record<string, unknown> = {
      jobber_gid: gid,
      title, instructions, task_date: taskDate,
      minutes: allDay ? null : minutes,
    };
    // Key presence is the RPC's contract too: an absent key leaves the column alone, an explicit
    // null clears it. Sending an inherited value would be a no-op at best and, on a row someone
    // else just changed, a silent revert.
    if (clientId !== undefined) p.client_id = clientId;
    if (propertyId !== undefined) p.property_id = propertyId;
    if (visitId !== undefined) p.visit_id = visitId;
    if (!allDay) p.duration_minutes = duration;
    // Omitted when empty, matching the omitted assignedTo above so the two sides agree.
    if (assigneeIds?.length) p.assignee_ids = assigneeIds;

    const { data: recId, error: rpcErr } = await db.schema("ops")
      .rpc("fn_record_calendar_task", { p, p_actor_email: email });

    if (rpcErr) {
      let rolledBack = false;
      if (op === "create") {
        const del = await deleteAndVerify(token, gid);      // read-back proof, same as above
        rolledBack = del.gone;
        createdGid = del.gone ? null : gid;
      }
      const mapped = mapRpcError(rpcErr);
      console.error(`[calendar-task] RPC failed on ${op} (task ${gid}): ${mapped.message}; rolledBack=${rolledBack}`);
      if (op === "create" && !rolledBack) {
        console.error(`[calendar-task] ORPHANED Jobber task ${gid}: created but not recorded and rollback did NOT confirm. MANUAL CLEANUP NEEDED.`);
      }
      return fail(mapped.status, mapped.code,
        op === "create"
          ? `The Jobber task was created but our copy could not be recorded: ${mapped.message}`
          : `Jobber accepted the change but our copy could not be updated: ${mapped.message}`,
        {
          jobber_task: gid, db_code: rpcErr.code,
          rolled_back: op === "create" ? rolledBack : undefined,
          note: op === "create"
            ? (rolledBack ? "The Jobber task was removed, no orphan." : `ORPHANED Jobber task ${gid} — MANUAL CLEANUP NEEDED.`)
            : undefined,
        });
    }

    return json({
      ok: true, op, task_id: Number(recId), jobber_task: gid,
      title, task_date: taskDate, all_day: allDay,
      minutes: allDay ? null : minutes,
      duration_minutes: allDay ? 1440 : duration,
      // ⚠ Reports what was actually APPLIED, not what was asked for. An earlier version echoed the
      // request, so a caller sending [] saw `assignees: []` while nothing had been cleared.
      // null = the caller did not state a list, so neither side was touched.
      assignees_applied: assignedGids === null ? null : assigneeIds,
      assignees_unchanged: assignedGids === null,
      // v1 cannot UNASSIGN: an empty list omits the key on both sides rather than sending [].
      assignees_cleared: false,
      // Now TRUE on every save. The date IS verified on an all-day task, by comparing the ET
      // calendar date of Jobber's startAt — see verifyTask and the header. It used to be
      // `!allDay`, a false negative on every all-day save AND the flag for a check that had been
      // switched off on a premise that turned out to be wrong.
      date_verified_in_jobber: true,
      verified: true,
    });
  } catch (e) {
    // Anything unhandled reaches here. Nothing local has been written on any path that throws
    // before the RPC, and the app is told plainly rather than being shown a silent success.
    const msg = e instanceof Error ? e.message : String(e);
    // 🛑 THE DETAIL STAYS ON THE SERVER. getJobberToken() throws with up to 150 characters of
    // Jobber's OAuth error body in the message; returning that to a browser leaks upstream detail
    // to anyone who can make the call fail. The log keeps it, the caller gets a flat message.
    console.error(`[calendar-task] unhandled${createdGid ? ` (Jobber task ${createdGid} may be ORPHANED)` : ""}: ${msg}`);
    // 🛑 IF A TASK WAS CREATED AND WE ARE THROWING, NAME IT. Otherwise a real Task sits on the
    // crew's schedule with nothing in our system pointing at it and no way to find it again.
    if (createdGid) {
      console.error(`[calendar-task] ORPHANED Jobber task ${createdGid}: created, then an unhandled failure before it could be recorded. MANUAL CLEANUP NEEDED.`);
      return fail(500, "unexpected",
        "Something went wrong after the task was created in Jobber, and it could not be recorded here. The Jobber task may need to be removed by hand.",
        { jobber_task: createdGid, rolled_back: false, note: `ORPHANED Jobber task ${createdGid} — MANUAL CLEANUP NEEDED.` });
    }
    return fail(500, "unexpected", "Something went wrong and nothing was saved.");
  }
});
