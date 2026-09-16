// ============================================================================================
// poll-calendar-tasks — the Calendar Tasks safety net (Fred, 2026-08-26)
// --------------------------------------------------------------------------------------------
// save-calendar-task is the door: every write goes push -> read-back -> RPC, so our copy can never
// claim something Jobber does not have. But Jobber is also a UI. A tech completes a task in the
// Jobber mobile app and nothing tells us. This is the only thing that closes that direction.
//
// Every 5 minutes (cron 'calendar-task-poll' at 2-57/5): ask Jobber about OUR OWN task GIDs, read
// isComplete, and mirror any change back through ops.fn_record_calendar_task.
//
// 🛑 IT ADOPTS isComplete IN BOTH DIRECTIONS. Design spec §3.2, and the reason is structural rather
//    than a preference: every completion WE store was verified in Jobber before it was written, so
//    for this one field Jobber is authoritative by construction. The two can only disagree when
//    somebody changed it on the Jobber side, and adopting makes them agree again.
//
// 🛑 SINCE 2026-09-16 IT MIRRORS EVERYTHING JOBBER CAN CHANGE, NOT ONLY COMPLETION. Fred, recorded:
//    "when I make a change on the Calendar app for the task it needs to be reflected on Jobber, and
//    vice versa ... the title or the description or the assigned person". Until then this file
//    mirrored isComplete and nothing else, for two reasons that were re-examined and do not hold
//    against that requirement:
//      * "Jobber's Task has no updatedAt, so a retitled task is indistinguishable from an untouched
//        one." True, and irrelevant to VALUE adoption: the same argument that makes completion safe
//        makes every field safe. Every value we hold was verified in Jobber by save-calendar-task
//        before it was written, so a DIFFERENCE can only have been made on the Jobber side, and
//        adopting it makes the two agree again. No updatedAt is needed to decide who is newer,
//        because our side never holds a value Jobber did not confirm.
//      * "A completion-only payload is provably non-destructive; sending task_date/minutes re-enters
//        the all_day and duration ladders." Also true, and now deliberate: the schedule payload is
//        derived from Jobber's own startAt/endAt/allDay (the ET date and minute, the window length),
//        so what re-enters those ladders IS Jobber's state, which is the state we want stored.
//    What it adopts, per task we hold: title, instructions, the schedule (task_date/minutes/
//    duration, including task_date NULL for an unscheduled Task since 2026-09-16_1300), client and
//    property (through their link rows), the assignee set (through employee links), and isComplete
//    exactly as before. What it will NOT do: adopt a client, property or assignee it cannot map to
//    one of our rows (logged under unmapped_*, the field is left alone), or delete a task Jobber no
//    longer has (rule 6; surfaced under `missing`).
//    It also DISCOVERS tasks created in Jobber (section 6): createdAt after the last successful
//    discovery (public.sync_cursors entity 'calendar_tasks'), plus the scheduled horizon, each new
//    GID recorded through the same recorder. GIDs linked to a calendar_day_marker are NEVER imported:
//    those Tasks are the Calendar's own route markers, mirrored by jobber-push-task.
//    ⚠ The race the completion path already documents (item 3 below) applies to every field: the
//    re-read immediately before the RPC now compares the WHOLE adoptable fingerprint, not only
//    isComplete, so a task that moved under us in any field is skipped and retried in five minutes.
//
// ============================================================================================
// THE THREE THINGS THAT MAKE THIS CORRECT RATHER THAN PLAUSIBLE
// ============================================================================================
// 1. PAGINATION IS REQUIRED, AND SO IS THE COMPLETENESS ASSERTION.
//    Jobber's page cap is 100 and truncation is SILENT — measured on the live API: first:500
//    returns nodes=100, totalCount=401, hasNextPage=true, errors=null, HTTP 200. The `ids` FILTER
//    is uncapped; the response PAGE is not. So you may send 401 ids and get back 100 nodes.
//    Worse, an id Jobber does not have is omitted with no error at all (measured: a bogus id ->
//    totalCount 0, errors null). Combine the two and a naive poll reports every task past the
//    hundredth as "missing from Jobber", every five minutes, forever, while adopting none of their
//    completions. So: walk after/endCursor to hasNextPage=false, and ASSERT collected === totalCount
//    before treating any absence as meaningful. If that assertion fails we adopt nothing and emit
//    no missing list, because a partial read cannot tell absence from truncation.
//
// 2. completed_at IS JOBBER'S INSTANT, NOT NOTICE-TIME.
//    `Task.completedAt` does not exist as a readable field, but `TaskFilterAttributes.completedAt`
//    is a working range filter over it (measured: no filter 401, after 2000-01-01 309, after
//    2026-08-01 25, after 2099 0, before 2020 0 — monotonic and bounded, and the 309 matches a full
//    walk of isComplete=true exactly). So the instant is recoverable by binary search on a single
//    id. `after: X` true means completedAt > X, so the largest X for which it holds bounds the
//    answer to (X, X+1s]; we record X+1s so the stored value is NEVER EARLIER than the real event.
//    Falling back to now() would silently turn completed_at into "when we noticed", wrong by up to
//    the poll interval, and nothing on the row distinguishes an exact value from an estimate —
//    completed_source='jobber' does not carry precision. When the search cannot converge we DO fall
//    back to now(), and the GID is listed under completed_at_estimated in sync_log.details so the
//    estimate is visible rather than indistinguishable.
//    ⚠ HONEST GAP: nothing has cross-checked that Jobber's completedAt is the true completion
//      instant rather than a derived value. It is accurate to the second RELATIVE TO WHAT JOBBER
//      STORES, which is the best available and strictly better than notice-time.
//
// 3. THE RACE IS REAL AND IS ONLY NARROWED, NOT CLOSED.
//    The saga is not one transaction: save-calendar-task reads the row, then makes three HTTP round
//    trips, then calls the RPC. A poll adopting a completion can land on a stale snapshot and
//    clobber a reopen the office just made — the exact discrepancy this feature exists to prevent,
//    manufactured by the safety net. Two guards, and NEITHER is sufficient alone:
//      (a) `expected_is_complete` in the RPC payload (2026-08-26_1850) raises ZZ002 if our stored
//          value is not what we read. This catches a concurrent write that CHANGED our row.
//      (b) A single-task re-read of isComplete from Jobber IMMEDIATELY before the RPC. This catches
//          the case (a) cannot see: if the office's action leaves our stored value exactly where
//          the poll expected it, (a) passes. Example: our=true, Jobber=false, poll reads false;
//          office completes it in the Calendar (Jobber->true, our stays true); poll's
//          expected_is_complete=true still matches, and without (b) it would write false against a
//          Jobber that says true.
//    (b) is called TWICE: once early as a cheap bail-out, and once IMMEDIATELY BEFORE the RPC.
//    The second placement is the one that matters and it was wrong in the first version of this
//    file, which did the re-read before findCompletedAt. Measured on a real production task:
//        findCompletedAt   32 probes  4851 ms
//        single re-read               155 ms
//    so a re-read placed before the search left a ~4.85 SECOND residual on the COMPLETION path --
//    about 31x the call meant to shrink it, and completions are the case this function exists to
//    catch. (SEARCH_BUDGET_MS gates whether a search STARTS, not how long it runs.) With the
//    confirm moved after the search, the residual is ONE RPC ROUND TRIP.
//    ⚠ Even so: a genuine narrowing, NOT a proof. A real fix needs a version token both sides can
//    compare, and Jobber's Task exposes none. Documented rather than implied.
//
// ============================================================================================
// AUTH: verify_jwt = true. Invoked by pg_cron via net.http_post with a service_role bearer, and the
// handler ALSO asserts role=service_role, because the public anon key is a validly signed JWT and
// would pass the gateway on its own. Same shape as jobber-push-task. Never deploy --no-verify-jwt.
//
// OBSERVABILITY: this function writes its OWN public.sync_log row. The cron wrapper cannot:
// `PERFORM net.http_post` only ENQUEUES, so the cron run reports succeeded whatever happens next —
// measured across the full history, cron.job_run_details holds 99,697 succeeded against 1 failed.
// And net._http_response has NO url column and ~6h retention, so after that there is no evidence an
// invocation happened at all. Without the sync_log row the job is green forever and the missing
// list is seen by nobody.
// ⚠ The column is `sync_source`, NOT `source`.
// ============================================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const GQL_VERSION = "2026-04-16";
const SYNC_SOURCE = "calendar-task-poll";

const db = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

// The recorder's writes are Jobber's state being mirrored, so the audit trail labels them 'jobber'
// and get_record_history reads them as 'Created in Jobber' / 'Completed in Jobber' / 'Changed in
// Jobber'. A SEPARATE client so the token refresh (public.webhook_tokens, which IS audited) and the
// sync_log / sync_cursors writes keep exactly the label they have today.
// NEVER add x-actor-name here: the 'jobber' branch prints that header as a person's name.
const rpcDb = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false },
  global: { headers: { "x-app-source": "jobber" } },
});

const ENTITY_TYPE = "calendar_task";
const PAGE = 100;                       // Jobber's measured hard cap; asking for more is silently 100
const MAX_PAGES = 60;                   // 6,000 tasks. A runaway cursor must end, loudly.
const REOPEN_WINDOW_DAYS = 30;          // how far back a completed task stays watched (see below)

// 🛑 A TIME BUDGET FOR THE TIMESTAMP SEARCHES, because they are the only unbounded work here.
// Measured on a real production task completed in March 2025: 32 probes, 5.07 SECONDS. That is fine
// for the 7 completions/week this normally sees, but a burst of twenty would run for a minute and a
// half, and the cron wrapper's net.http_post stops waiting long before that. So the searches get a
// budget: once it is spent, the remaining adoptions still happen, they just carry an ESTIMATED
// completed_at and say so in completed_at_estimated. Adopting late with a good timestamp is worse
// than adopting now with a flagged one, because the completion itself is the thing the office needs
// to see. The budget is on ELAPSED TIME rather than a probe count so it holds however slow Jobber is.
const SEARCH_BUDGET_MS = 20_000;
// Discovery (section 6): how far back the FIRST run looks for Jobber-created tasks, the scheduled
// horizon walked every run, and the per-cycle import cap (the rest is deferred, never dropped).
const DISCOVERY_FIRST_RUN_DAYS = 30;
const DISCOVERY_HORIZON_BACK_DAYS = 30;
const DISCOVERY_HORIZON_AHEAD_DAYS = 60;
const DISCOVERY_CAP = 50;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

// ---- Jobber write token: copied verbatim from jobber-push-task -----------------------------
// NOTE: this reads the `jobber_write` row like jobber-push-task does, not the read-only `jobber`
// row. This function only READS from Jobber, so either would work; the write token is used because
// this file's helper is the byte-identical copy and forking it to change one string is exactly the
// retyping that 2026-08-06_1316 punished. Both rows refresh the same way.
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

// Throttle-aware GraphQL, copied verbatim from jobber-push-task. The waiting-room content-type
// check is the load-bearing part: Jobber sheds load with text/html at HTTP 200, and every naive
// helper reads that as success with data: undefined.
async function gql(token: string, query: string, variables?: unknown, _retry = 0): Promise<any> {
  const r = await fetch("https://api.getjobber.com/api/graphql", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`, "Content-Type": "application/json",
      "X-JOBBER-GRAPHQL-VERSION": GQL_VERSION,
    },
    body: JSON.stringify({ query, variables }),
  });
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
    console.log(`[task-poll] throttled — backoff ${waitMs}ms (retry ${_retry + 1}/5)`);
    await new Promise((s) => setTimeout(s, waitMs));
    return gql(token, query, variables, _retry + 1);
  }
  return j;
}

// Reads BOTH GraphQL error channels. A schema error has data:null and an EMPTY userErrors, so a
// userErrors-only reader calls it success. Copied verbatim from jobber-push-task.
function errsOf(res: any, field: string): string[] {
  const top = Array.isArray(res?.errors) ? res.errors.map((e: any) => e?.message ?? String(e)) : [];
  const user = (res?.data?.[field]?.userErrors ?? []).map((e: any) => e?.message ?? String(e));
  return [...top, ...user].filter(Boolean);
}

const answered = (res: unknown) =>
  !!res && typeof res === "object" &&
  Object.prototype.hasOwnProperty.call(res, "data") &&
  !!(res as { data?: unknown }).data && typeof (res as { data?: unknown }).data === "object";

// The whole adoptable surface in one node shape, shared by the ids walk, the re-read and discovery.
const NODE_FIELDS = `id isComplete title instructions allDay startAt endAt
      client{ id } property{ id } assignedUsers(first: 30){ nodes{ id } }`;
const Q_PAGE = `query($ids: [EncodedId!], $first: Int!, $after: String){
  tasks(first: $first, after: $after, filter: { ids: $ids }){
    totalCount
    pageInfo{ hasNextPage endCursor }
    nodes{ ${NODE_FIELDS} }
  } }`;
const Q_CREATED = `query($after: ISO8601DateTime!, $first: Int!, $cursor: String){
  tasks(first: $first, after: $cursor, filter: { createdAt: { after: $after } }){
    totalCount
    pageInfo{ hasNextPage endCursor }
    nodes{ ${NODE_FIELDS} }
  } }`;
const Q_WINDOW = `query($from: ISO8601DateTime!, $to: ISO8601DateTime!, $first: Int!, $cursor: String){
  tasks(first: $first, after: $cursor, filter: { startAt: { after: $from, before: $to } }){
    totalCount
    pageInfo{ hasNextPage endCursor }
    nodes{ ${NODE_FIELDS} }
  } }`;

// ---- ET wall clock of a Jobber instant (the unit our rows are stored in) ---------------------
// Intl gives the zone's own offset for that instant, so DST is handled by the zone data, never by
// a hardcoded -04:00/-05:00. Same shape as save-calendar-task's etWall, kept local to this file.
const ET_FMT = new Intl.DateTimeFormat("en-US", {
  timeZone: "America/New_York", hourCycle: "h23",
  year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit",
});
function etWallOf(iso: string): { date: string; minutes: number } | null {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  const p: Record<string, string> = {};
  for (const part of ET_FMT.formatToParts(d)) p[part.type] = part.value;
  const hh = Number(p.hour) % 24;
  return { date: `${p.year}-${p.month}-${p.day}`, minutes: hh * 60 + Number(p.minute) };
}

// What our row would look like if it mirrored this Jobber node. `null` duration = leave ours.
type Derived = {
  title: string; instructions: string | null;
  taskDate: string | null; minutes: number | null; duration: number | null;
  clientGid: string | null; propertyGid: string | null; assignedGids: string[]; isComplete: boolean;
};
function derive(n: any): Derived | null {
  const title = String(n?.title ?? "").trim();
  if (!title) return null;                                  // the recorder refuses a blank title
  let taskDate: string | null = null, minutes: number | null = null, duration: number | null = null;
  if (n.startAt) {
    const w = etWallOf(n.startAt);
    if (!w) return null;
    taskDate = w.date;
    if (n.allDay === true) {
      minutes = null;                                       // all-day: the recorder derives 1440
    } else {
      minutes = w.minutes;
      if (n.endAt) {
        const len = Math.round((new Date(n.endAt).getTime() - new Date(n.startAt).getTime()) / 60_000);
        if (Number.isFinite(len) && len >= 1 && len <= 1440) duration = len;
      }
    }
  }
  return {
    title,
    instructions: (n.instructions ?? null) === null ? null : String(n.instructions),
    taskDate, minutes, duration,
    clientGid: n.client?.id ?? null,
    propertyGid: n.property?.id ?? null,
    assignedGids: ((n.assignedUsers?.nodes ?? []) as { id: string }[]).map((u) => u?.id).filter(Boolean).sort(),
    isComplete: n.isComplete === true,
  };
}
// One string per node, so "did it move under us" is a single comparison covering every field.
const fingerprint = (d: Derived | null) => d === null ? "invalid" : JSON.stringify(d);

// ============================================================================================
// Recover Jobber's own completion instant by binary search on the completedAt RANGE FILTER.
// Returns an ISO string, or null when the search cannot converge (the caller then estimates).
// `after: X` true means completedAt > X. We keep the largest X that is still true, so the answer
// lies in (lo, lo+1s]; returning lo+1s makes the stored value never EARLIER than the real event.
// ============================================================================================
async function countAfter(token: string, gid: string, whenISO: string): Promise<number | null> {
  const res = await gql(token, `query($ids:[EncodedId!], $after: ISO8601DateTime!){
    tasks(first:1, filter:{ ids:$ids, completedAt:{ after:$after } }){ totalCount } }`,
    { ids: [gid], after: whenISO });
  if (!answered(res) || errsOf(res, "tasks").length) return null;
  const n = res.data?.tasks?.totalCount;
  return typeof n === "number" ? n : null;
}

// Re-read ONE task and say whether Jobber still reports the STATE we are about to act on: the whole
// adoptable fingerprint since 2026-09-16, not only isComplete.
//   "ok"          it still matches; safe to proceed
//   "changed"     it moved under us, or vanished. This cycle's conclusion is stale.
//   "unreadable"  Jobber did not answer. NOT the same as "changed": we know nothing, so we must not
//                 adopt AND must not report a conflict, because both would be claims we cannot make.
async function confirmStillIs(
  token: string, gid: string, expected: string,
): Promise<"ok" | "changed" | "unreadable"> {
  const res: any = await gql(token, Q_PAGE, { ids: [gid], first: 1, after: null });
  if (!answered(res) || errsOf(res, "tasks").length) return "unreadable";
  const node = (res.data?.tasks?.nodes ?? [])[0];
  if (!node || node.id !== gid) return "changed";
  return fingerprint(derive(node)) === expected ? "ok" : "changed";
}

async function findCompletedAt(token: string, gid: string): Promise<{ iso: string | null; probes: number }> {
  let probes = 0;
  // Bracket: lo must be TRUE (completed after lo), hi must be FALSE. Both are asserted, not assumed —
  // a bracket that does not actually bracket makes every bisection below meaningless.
  let lo = new Date("2000-01-01T00:00:00Z").getTime();
  let hi = Date.now() + 60_000;
  probes++;
  const loTrue = await countAfter(token, gid, new Date(lo).toISOString());
  if (loTrue === null || loTrue < 1) return { iso: null, probes };      // not completed, or unreadable
  probes++;
  const hiTrue = await countAfter(token, gid, new Date(hi).toISOString());
  if (hiTrue === null || hiTrue > 0) return { iso: null, probes };      // upper bound is not an upper bound
  // Bisect to a 1-second interval. ~41 probes worst case over 26 years; in practice far fewer
  // because completions cluster near now. Cost is trivial: a first:1 count against a bucket of
  // maximumAvailable 10000 restoring at 500/s, and there were 7 completions in the last 7 days.
  while (hi - lo > 1000 && probes < 60) {
    const mid = lo + Math.floor((hi - lo) / 2);
    probes++;
    const n = await countAfter(token, gid, new Date(mid).toISOString());
    if (n === null) return { iso: null, probes };                      // transport failure mid-search
    if (n > 0) lo = mid; else hi = mid;
  }
  if (hi - lo > 1000) return { iso: null, probes };                    // did not converge
  return { iso: new Date(lo + 1000).toISOString(), probes };
}

// ============================================================================================
Deno.serve(async (req) => {
  const startedAt = new Date().toISOString();
  const t0 = Date.now();

  if (req.method !== "POST") return json({ ok: false, error: "POST only" }, 405);

  // AUTH: the gateway verified the signature; this asserts WHICH key. The anon key is a validly
  // signed JWT, so verify_jwt alone is half a gate on a function holding the Jobber token.
  const tok = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  let role: string | null = null;
  try {
    const p = tok.split(".");
    if (p.length === 3) {
      const pad = p[1].replace(/-/g, "+").replace(/_/g, "/");
      role = JSON.parse(atob(pad + "=".repeat((4 - (pad.length % 4)) % 4)))?.role ?? null;
    }
  } catch { role = null; }
  if (role !== "service_role") return json({ ok: false, error: "forbidden" }, 403);

  const details: Record<string, unknown> = {};
  const missing: string[] = [];
  const dateUnrepresentable: string[] = [];
  const conflicts: string[] = [];
  const estimated: string[] = [];
  const errors: string[] = [];
  let checked = 0, adopted = 0, unadopted = 0;

  // A run that ends in the catch still writes its sync_log row. A safety net that fails silently is
  // the thing this whole feature is guarding against.
  const finish = async (status: string, httpStatus = 200) => {
    const durationSeconds = Math.round((Date.now() - t0) / 1000);
    const body = {
      ok: status === "ok", status, checked, adopted, unadopted,
      missing, date_unrepresentable: dateUnrepresentable, conflicts,
      completed_at_estimated: estimated, errors, duration_seconds: durationSeconds, ...details,
    };
    const { error: logErr } = await db.from("sync_log").insert({
      sync_source: SYNC_SOURCE,               // ⚠ sync_source, NOT source
      started_at: startedAt,
      finished_at: new Date().toISOString(),
      rows_updated: adopted,
      rows_errored: errors.length + conflicts.length,
      duration_seconds: durationSeconds,
      status,
      details: body,
      error_details: errors.length ? { errors } : null,
    });
    if (logErr) console.error(`[task-poll] sync_log write failed: ${logErr.message}`);
    return json(body, httpStatus);
  };

  try {
    // ---- 1. OUR working set ------------------------------------------------------------------
    // Open tasks always. PLUS tasks completed recently, because we mirror UN-completions too and a
    // completed task can be reopened in Jobber — but watching every completed task forever would
    // grow the working set without bound (about 374 tasks/year), so it is windowed. A reopen older
    // than the window is not mirrored; that is a deliberate, stated limit, not an oversight.
    const cutoff = new Date(Date.now() - REOPEN_WINDOW_DAYS * 86_400_000).toISOString();
    const COLS = "id, title, instructions, task_date, minutes, duration_minutes, all_day, client_id, property_id, is_complete, calendar_task_assignees(employee_id)";
    const { data: openRows, error: openErr } = await db.schema("ops").from("calendar_tasks")
      .select(COLS).eq("is_complete", false);
    if (openErr) { errors.push(`open-task read failed: ${openErr.message}`); return await finish("attention", 500); }
    const { data: recentRows, error: recentErr } = await db.schema("ops").from("calendar_tasks")
      .select(COLS).eq("is_complete", true).gte("completed_at", cutoff);
    if (recentErr) { errors.push(`recent-task read failed: ${recentErr.message}`); return await finish("attention", 500); }

    type OurRow = {
      id: number; title: string; instructions: string | null; task_date: string | null; minutes: number | null;
      duration_minutes: number; all_day: boolean; client_id: number | null; property_id: number | null;
      is_complete: boolean; assignees: number[];
    };
    const ours = new Map<number, OurRow>();
    for (const r of [...(openRows ?? []), ...(recentRows ?? [])] as any[]) {
      ours.set(Number(r.id), {
        id: Number(r.id), title: String(r.title ?? ""), instructions: r.instructions ?? null,
        task_date: r.task_date ?? null, minutes: r.minutes ?? null, duration_minutes: Number(r.duration_minutes ?? 30),
        all_day: r.all_day === true, client_id: r.client_id ?? null, property_id: r.property_id ?? null,
        is_complete: r.is_complete === true,
        assignees: ((r.calendar_task_assignees ?? []) as { employee_id: number }[]).map((a) => Number(a.employee_id)).sort((a, b) => a - b),
      });
    }
    details.watching = { open: openRows?.length ?? 0, recently_completed: recentRows?.length ?? 0, window_days: REOPEN_WINDOW_DAYS };

    // The link maps used by adoption AND discovery: Jobber GID <-> our id, for employees, clients,
    // properties, and every Task GID we already hold under ANY entity type (a calendar_day_marker's
    // Task must never be discovered as a calendar task).
    const linkMap = async (entityType: string): Promise<Map<string, number>> => {
      const m = new Map<string, number>();
      const { data, error } = await db.from("entity_source_links")
        .select("entity_id, source_id").eq("entity_type", entityType).eq("source_system", "jobber");
      if (error) { errors.push(`${entityType} link read failed: ${error.message}`); return m; }
      for (const l of data ?? []) if (l.source_id) m.set(String(l.source_id), Number(l.entity_id));
      return m;
    };
    const employeeByGid = await linkMap("employee");
    const clientByGid = await linkMap("client");
    const propertyByGid = await linkMap("property");
    const markerGids = new Set((await linkMap("calendar_day_marker")).keys());
    const unmapped = { employees: new Set<string>(), clients: new Set<string>(), properties: new Set<string>() };

    // Turn a derived Jobber node into a recorder payload, restricted to `keys`, mapping GIDs to our
    // ids. Returns null when a field we were asked to adopt cannot be represented (an assignee,
    // client or property with no link row): then that field is left alone and logged.
    const payloadFor = (d: Derived, keys: Set<string>): Record<string, unknown> => {
      const p: Record<string, unknown> = {};
      if (keys.has("title")) p.title = d.title;
      if (keys.has("instructions")) p.instructions = d.instructions;
      if (keys.has("schedule")) {
        p.task_date = d.taskDate;
        p.minutes = d.minutes;
        if (d.taskDate !== null && d.minutes !== null && d.duration !== null) p.duration_minutes = d.duration;
      }
      if (keys.has("client")) {
        if (d.clientGid === null) p.client_id = null;
        else if (clientByGid.has(d.clientGid)) p.client_id = clientByGid.get(d.clientGid);
        else unmapped.clients.add(d.clientGid);
      }
      if (keys.has("property")) {
        if (d.propertyGid === null) p.property_id = null;
        else if (propertyByGid.has(d.propertyGid)) p.property_id = propertyByGid.get(d.propertyGid);
        else unmapped.properties.add(d.propertyGid);
      }
      if (keys.has("assignees")) {
        const missing = d.assignedGids.filter((g) => !employeeByGid.has(g));
        if (missing.length) missing.forEach((g) => unmapped.employees.add(g));
        else p.assignee_ids = d.assignedGids.map((g) => employeeByGid.get(g)!).sort((a, b) => a - b);
      }
      return p;
    };
    // Which adoptable fields differ between our row and the Jobber node.
    const diffKeys = (o: OurRow, d: Derived): Set<string> => {
      const k = new Set<string>();
      if (o.title.trim() !== d.title) k.add("title");
      if ((o.instructions ?? "").trim() !== (d.instructions ?? "").trim()) k.add("instructions");
      const ourDur = o.all_day ? null : o.duration_minutes;
      if (o.task_date !== d.taskDate || o.minutes !== d.minutes ||
          (d.duration !== null && d.minutes !== null && ourDur !== d.duration)) k.add("schedule");
      const dClient = d.clientGid === null ? null : (clientByGid.get(d.clientGid) ?? undefined);
      if (dClient !== undefined && dClient !== o.client_id) k.add("client");
      if (dClient === undefined) unmapped.clients.add(d.clientGid as string);
      const dProp = d.propertyGid === null ? null : (propertyByGid.get(d.propertyGid) ?? undefined);
      if (dProp !== undefined && dProp !== o.property_id) k.add("property");
      if (dProp === undefined) unmapped.properties.add(d.propertyGid as string);
      const dAss = d.assignedGids.map((g) => employeeByGid.get(g));
      if (dAss.every((x) => x !== undefined)) {
        const a = (dAss as number[]).sort((x, y) => x - y);
        if (a.length !== o.assignees.length || a.some((x, i) => x !== o.assignees[i])) k.add("assignees");
      } else d.assignedGids.filter((g) => !employeeByGid.has(g)).forEach((g) => unmapped.employees.add(g));
      if (o.is_complete !== d.isComplete) k.add("completion");
      return k;
    };

    // ---- 2. GIDs. There is no FK to entity_source_links, so no embed: two reads, joined here. --
    const gidByTask = new Map<number, string>();
    const taskByGid = new Map<string, number>();
    if (ours.size > 0) {
      const { data: links, error: linkErr } = await db.from("entity_source_links")
        .select("entity_id, source_id").eq("entity_type", ENTITY_TYPE)
        .eq("source_system", "jobber").in("entity_id", [...ours.keys()]);
      if (linkErr) { errors.push(`link read failed: ${linkErr.message}`); return await finish("attention", 500); }
      for (const l of links ?? []) {
        if (!l.source_id) continue;
        gidByTask.set(Number(l.entity_id), l.source_id as string);
        taskByGid.set(l.source_id as string, Number(l.entity_id));
      }
      // A tracked task with no link row cannot be asked about. It is an orphan of the same class the
      // recorder raises 23503 on, and it is surfaced rather than silently skipped.
      const unlinked = [...ours.keys()].filter((id) => !gidByTask.has(id));
      if (unlinked.length) details.unlinked_task_ids = unlinked;
    }
    const gids = [...taskByGid.keys()];

    const token = await getJobberToken();

    // ---- 3. WALK. The ids filter is uncapped; the page is capped at 100 and truncates silently. --
    const seen = new Map<string, any>();                 // gid -> the raw Jobber node
    if (gids.length > 0) {
      let after: string | null = null;
      let totalCount: number | null = null;
      let pages = 0;
      let walkComplete = false;
      for (;;) {
        const res: any = await gql(token, Q_PAGE, { ids: gids, first: PAGE, after });
        const e = errsOf(res, "tasks");
        if (e.length || !answered(res) || !res.data?.tasks) {
          errors.push(`Jobber read failed on page ${pages + 1}: ${e.join("; ") || "no data in the reply"}`);
          break;
        }
        const t = res.data.tasks;
        totalCount = typeof t.totalCount === "number" ? t.totalCount : totalCount;
        for (const n of t.nodes ?? []) if (n?.id) seen.set(n.id, n);
        pages++;
        if (!t.pageInfo?.hasNextPage) { walkComplete = true; break; }
        after = t.pageInfo.endCursor ?? null;
        if (!after) { errors.push("hasNextPage was true but endCursor was null"); break; }
        if (pages >= MAX_PAGES) { errors.push(`walk exceeded ${MAX_PAGES} pages`); break; }
      }
      details.pages = pages;
      details.total_count = totalCount;
      details.collected = seen.size;

      // 🛑 THE COMPLETENESS ASSERTION. Without it, a truncated read is indistinguishable from
      // "Jobber no longer has these", and every task past the hundredth is reported missing forever.
      const complete = walkComplete && totalCount !== null && seen.size === totalCount;
      details.walk_complete = complete;
      if (!complete) {
        errors.push(`incomplete walk: collected ${seen.size} of totalCount ${totalCount} over ${pages} page(s); adopting nothing and emitting no missing list this cycle`);
        return await finish("attention");
      }

      checked = seen.size;

      // ---- 4. Missing from Jobber: SURFACE, never auto-delete (rule 6) --------------------------
      // Debounced by a re-read: between taskDelete and fn_delete_calendar_task the saga leaves our
      // row present while Jobber has already dropped it, so a normal delete would fire a false alert
      // on every run. Re-checking the row still exists right now collapses that window.
      const absentGids = gids.filter((g) => !seen.has(g));
      if (absentGids.length) {
        const absentIds = absentGids.map((g) => taskByGid.get(g)!).filter(Boolean);
        const { data: still } = await db.schema("ops").from("calendar_tasks").select("id").in("id", absentIds);
        const stillThere = new Set((still ?? []).map((r: { id: number }) => Number(r.id)));
        for (const g of absentGids) {
          const id = taskByGid.get(g)!;
          if (stillThere.has(id)) missing.push(g);      // still ours, genuinely absent from Jobber
        }
      }

      // ---- 5. Adopt the differences, field by field ------------------------------------------
      const fieldCounts: Record<string, number> = {};
      for (const [gid, node] of seen) {
        const taskId = taskByGid.get(gid);
        if (taskId === undefined) continue;              // Jobber returned an id we did not ask about
        const o = ours.get(taskId);
        if (!o) continue;
        const d = derive(node);
        if (d === null) { errors.push(`${gid}: Jobber node not representable (blank title or unreadable date); skipped`); continue; }
        const keys = diffKeys(o, d);
        if (keys.size === 0) continue;
        const expected = fingerprint(d);

        // (b) EARLY BAIL-OUT. Cheap (~155ms) and it avoids paying for a timestamp search on a task
        // that has already moved under us. This is NOT the one that bounds the race window -- see the
        // second call, immediately before the RPC.
        const early = await confirmStillIs(token, gid, expected);
        if (early !== "ok") {
          if (early === "unreadable") errors.push(`${gid}: could not re-read before adopting; skipped`);
          else conflicts.push(gid);
          unadopted++;
          continue;
        }

        const p: Record<string, unknown> = {
          jobber_gid: gid,
          expected_is_complete: o.is_complete,     // (a) the optimistic-concurrency guard, ZZ002
          ...payloadFor(d, keys),
        };
        // completed_at only matters when adopting a COMPLETION. An un-completion clears the triple,
        // and the recorder deliberately discards completed_at/completed_source when is_complete=false.
        if (keys.has("completion")) {
          p.is_complete = d.isComplete;
          if (d.isComplete) {
            const budgetLeft = Date.now() - t0 < SEARCH_BUDGET_MS;
            const { iso, probes } = budgetLeft
              ? await findCompletedAt(token, gid)
              : { iso: null, probes: 0 };
            if (!budgetLeft) details.search_budget_spent = true;
            if (iso) {
              p.completed_at = iso;
            } else {
              // Do NOT fail the adopt over a timestamp. Estimate, and make the estimate VISIBLE --
              // nothing on the row distinguishes an exact value from a guess.
              p.completed_at = new Date().toISOString();
              estimated.push(gid);
            }
            p.completed_source = "jobber";          // must be exactly this; a CHECK enforces the pair
            details[`probes_${gid.slice(-8)}`] = probes;
          }
        }
        // Every differing field was unmappable (an assignee, client or property with no link row):
        // nothing to write, and the gap is already listed under unmapped_*.
        const adoptable = Object.keys(p).filter((k) => k !== "jobber_gid" && k !== "expected_is_complete");
        if (adoptable.length === 0) { unadopted++; continue; }

        // 🛑 THE RE-READ THAT ACTUALLY BOUNDS THE WINDOW, and it has to be HERE, after the timestamp
        // search rather than before it. findCompletedAt measured 32 probes / 4851 ms on a real
        // production task against 155 ms for this call, so a re-read placed before the search leaves
        // a ~4.85 SECOND hole -- roughly 31x the thing it was meant to shrink -- on the completion
        // path, which is the case this whole function exists to catch. SEARCH_BUDGET_MS gates whether
        // a search STARTS, not how long it runs, so a search begun just inside the budget still runs
        // its full length. From here the residual is one RPC round trip.
        const late = await confirmStillIs(token, gid, expected);
        if (late !== "ok") {
          if (late === "unreadable") errors.push(`${gid}: could not confirm before writing; skipped`);
          else conflicts.push(gid);
          unadopted++;
          continue;
        }

        const { error: rpcErr } = await rpcDb.schema("ops")
          .rpc("fn_record_calendar_task", { p, p_actor_email: null });   // machine actor, NO DEFAULT

        if (rpcErr) {
          if (rpcErr.code === "ZZ002") {
            // Somebody wrote between our read and our write. Benign: drop it and retry in 5 minutes.
            conflicts.push(gid);
          } else {
            errors.push(`${gid}: ${rpcErr.code ?? "?"} ${rpcErr.message ?? ""}`.trim());
          }
          unadopted++;
          continue;
        }
        adopted++;
        for (const k of keys) fieldCounts[k] = (fieldCounts[k] ?? 0) + 1;
      }
      details.fields_adopted = fieldCounts;
    }

    // ---- 6. DISCOVERY: tasks created in Jobber that we do not hold (2026-09-16) -----------------
    // Two walks, each with the same completeness assertion as section 3: tasks CREATED after the
    // last successful discovery (public.sync_cursors, entity 'calendar_tasks'; 30 days back on the
    // first run) so unscheduled tasks are reachable, plus tasks SCHEDULED in the horizon
    // [today - 30d, today + 60d]. A GID already linked to a calendar task is skipped; a GID linked to
    // a calendar_day_marker is NEVER imported (those are the Calendar's own route markers). Capped
    // per cycle; the remainder is counted, never silently dropped, and picked up next cycle because
    // the cursor only advances on a complete createdAt walk.
    const allTaskGids = new Set((await linkMap(ENTITY_TYPE)).keys());
    const { data: curRow, error: curErr } = await db.from("sync_cursors")
      .select("last_synced_at").eq("entity", "calendar_tasks").maybeSingle();
    if (curErr) errors.push(`discovery cursor read failed: ${curErr.message}`);
    const since = curRow?.last_synced_at
      ? new Date(curRow.last_synced_at).toISOString()
      : new Date(Date.now() - DISCOVERY_FIRST_RUN_DAYS * 86_400_000).toISOString();
    const horizonFrom = new Date(Date.now() - DISCOVERY_HORIZON_BACK_DAYS * 86_400_000).toISOString();
    const horizonTo = new Date(Date.now() + DISCOVERY_HORIZON_AHEAD_DAYS * 86_400_000).toISOString();

    const discovered = new Map<string, any>();
    const walkInto = async (query: string, vars: Record<string, unknown>, label: string): Promise<boolean> => {
      let cursor: string | null = null, pages = 0, total: number | null = null, got = 0, complete = false;
      for (;;) {
        const res: any = await gql(token, query, { ...vars, first: PAGE, cursor });
        const e = errsOf(res, "tasks");
        if (e.length || !answered(res) || !res.data?.tasks) {
          errors.push(`discovery (${label}) read failed on page ${pages + 1}: ${e.join("; ") || "no data in the reply"}`);
          break;
        }
        const t = res.data.tasks;
        total = typeof t.totalCount === "number" ? t.totalCount : total;
        for (const n of t.nodes ?? []) if (n?.id) { discovered.set(n.id, n); got++; }
        pages++;
        if (!t.pageInfo?.hasNextPage) { complete = true; break; }
        cursor = t.pageInfo.endCursor ?? null;
        if (!cursor) { errors.push(`discovery (${label}): hasNextPage true but endCursor null`); break; }
        if (pages >= MAX_PAGES) { errors.push(`discovery (${label}) exceeded ${MAX_PAGES} pages`); break; }
      }
      const ok = complete && total !== null && got === total;
      if (!ok) errors.push(`discovery (${label}) incomplete: ${got} of ${total} over ${pages} page(s); cursor not advanced`);
      return ok;
    };
    const createdOk = await walkInto(Q_CREATED, { after: since }, "createdAt");
    const windowOk = await walkInto(Q_WINDOW, { from: horizonFrom, to: horizonTo }, "startAt window");

    let discoveredNew = 0, discoveredSkippedCap = 0, discoveredMarkers = 0;
    for (const [gid, node] of discovered) {
      if (allTaskGids.has(gid) || taskByGid.has(gid)) continue;
      if (markerGids.has(gid)) { discoveredMarkers++; continue; }
      if (discoveredNew >= DISCOVERY_CAP) { discoveredSkippedCap++; continue; }
      const d = derive(node);
      if (d === null) { errors.push(`discovery: ${gid} not representable (blank title or unreadable date); skipped`); continue; }
      const p: Record<string, unknown> = {
        jobber_gid: gid,
        ...payloadFor(d, new Set(["title", "instructions", "schedule", "client", "property", "assignees"])),
        is_complete: d.isComplete,
      };
      if (d.isComplete) {
        const budgetLeft = Date.now() - t0 < SEARCH_BUDGET_MS;
        const { iso } = budgetLeft ? await findCompletedAt(token, gid) : { iso: null };
        if (iso) p.completed_at = iso; else { p.completed_at = new Date().toISOString(); estimated.push(gid); }
        p.completed_source = "jobber";
      }
      const { error: rpcErr } = await rpcDb.schema("ops")
        .rpc("fn_record_calendar_task", { p, p_actor_email: null });
      if (rpcErr) { errors.push(`discovery: ${gid}: ${rpcErr.code ?? "?"} ${rpcErr.message ?? ""}`.trim()); continue; }
      discoveredNew++;
      adopted++;
    }
    details.discovery = {
      since, created_walk_complete: createdOk, window_walk_complete: windowOk,
      candidates: discovered.size, imported: discoveredNew, marker_tasks_ignored: discoveredMarkers,
      over_cap_deferred: discoveredSkippedCap, cap: DISCOVERY_CAP,
    };
    // The cursor advances to THIS run's start only when the createdAt walk was complete and nothing
    // was deferred by the cap, so a task created during the run, or left over, is seen next time.
    if (createdOk && discoveredSkippedCap === 0) {
      const { error: upErr } = await db.from("sync_cursors").upsert({
        entity: "calendar_tasks", last_synced_at: startedAt, last_run_started: startedAt,
        last_run_finished: new Date().toISOString(), last_run_status: "success", last_error: null,
        rows_pulled: discovered.size, rows_populated: discoveredNew, updated_at: new Date().toISOString(),
      }, { onConflict: "entity" });
      if (upErr) errors.push(`discovery cursor write failed: ${upErr.message}`);
    }

    const unmappedAny = unmapped.employees.size + unmapped.clients.size + unmapped.properties.size > 0;
    if (unmappedAny) {
      details.unmapped = {
        employees: [...unmapped.employees], clients: [...unmapped.clients], properties: [...unmapped.properties],
      };
    }

    const status = (errors.length || missing.length || conflicts.length || unmappedAny)
      ? "attention" : "ok";
    return await finish(status);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error(`[task-poll] unhandled: ${msg}`);
    errors.push(`unhandled: ${msg}`);
    return await finish("attention", 500);
  }
});
