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
// 🛑 IT MIRRORS COMPLETION AND NOTHING ELSE. Not the title, not the schedule, not the assignees.
//    Two reasons, both load-bearing:
//      * Jobber's Task type has NO updatedAt and NO createdAt (measured: `Task.updatedAt` ->
//        "Field 'updatedAt' doesn't exist on type 'Task'"), so a retitled or rescheduled task is
//        indistinguishable from an untouched one. There is nothing to detect.
//      * A completion-only payload is provably non-destructive: the recorder loads the whole row
//        under FOR UPDATE and resolves every column as `CASE WHEN p ? 'key' THEN ... ELSE v_cur.x`,
//        so an absent key is carried forward. Adding task_date/minutes would re-enter the all_day
//        recompute and the duration_minutes re-derivation ladder, and that safety argument stops
//        holding. Do NOT extend this payload "while we are in there".
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
//    Together these reduce a window spanning the whole batch to two round trips. That is a genuine
//    narrowing and NOT a proof. A real fix needs a version token both sides can compare, and Jobber
//    exposes none. Documented rather than implied.
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

const Q_PAGE = `query($ids: [EncodedId!], $first: Int!, $after: String){
  tasks(first: $first, after: $after, filter: { ids: $ids }){
    totalCount
    pageInfo{ hasNextPage endCursor }
    nodes{ id isComplete }
  } }`;

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
    const { data: openRows, error: openErr } = await db.schema("ops").from("calendar_tasks")
      .select("id, is_complete").eq("is_complete", false);
    if (openErr) { errors.push(`open-task read failed: ${openErr.message}`); return await finish("attention", 500); }
    const { data: recentRows, error: recentErr } = await db.schema("ops").from("calendar_tasks")
      .select("id, is_complete").eq("is_complete", true).gte("completed_at", cutoff);
    if (recentErr) { errors.push(`recent-task read failed: ${recentErr.message}`); return await finish("attention", 500); }

    const ours = new Map<number, boolean>();
    for (const r of [...(openRows ?? []), ...(recentRows ?? [])]) ours.set(Number(r.id), r.is_complete === true);
    details.watching = { open: openRows?.length ?? 0, recently_completed: recentRows?.length ?? 0, window_days: REOPEN_WINDOW_DAYS };

    if (ours.size === 0) return await finish("ok");

    // ---- 2. GIDs. There is no FK to entity_source_links, so no embed: two reads, joined here. --
    const { data: links, error: linkErr } = await db.from("entity_source_links")
      .select("entity_id, source_id").eq("entity_type", ENTITY_TYPE)
      .eq("source_system", "jobber").in("entity_id", [...ours.keys()]);
    if (linkErr) { errors.push(`link read failed: ${linkErr.message}`); return await finish("attention", 500); }

    const gidByTask = new Map<number, string>();
    const taskByGid = new Map<string, number>();
    for (const l of links ?? []) {
      if (!l.source_id) continue;
      gidByTask.set(Number(l.entity_id), l.source_id as string);
      taskByGid.set(l.source_id as string, Number(l.entity_id));
    }
    // A tracked task with no link row cannot be asked about. It is an orphan of the same class the
    // recorder raises 23503 on, and it is surfaced rather than silently skipped.
    const unlinked = [...ours.keys()].filter((id) => !gidByTask.has(id));
    if (unlinked.length) details.unlinked_task_ids = unlinked;

    const gids = [...taskByGid.keys()];
    if (gids.length === 0) return await finish(unlinked.length ? "attention" : "ok");

    const token = await getJobberToken();

    // ---- 3. WALK. The ids filter is uncapped; the page is capped at 100 and truncates silently. --
    const seen = new Map<string, boolean>();
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
      for (const n of t.nodes ?? []) if (n?.id) seen.set(n.id, n.isComplete === true);
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

    // ---- 5. Adopt the differences ------------------------------------------------------------
    for (const [gid, jobberComplete] of seen) {
      const taskId = taskByGid.get(gid);
      if (taskId === undefined) continue;              // Jobber returned an id we did not ask about
      const oursComplete = ours.get(taskId);
      if (oursComplete === undefined || oursComplete === jobberComplete) continue;

      // (b) RE-READ THIS ONE TASK immediately before writing. The batch read may be many seconds
      // old by now, and expected_is_complete cannot see a Jobber-side change (header, point 3).
      const confirm: any = await gql(token, Q_PAGE, { ids: [gid], first: 1, after: null });
      if (!answered(confirm) || errsOf(confirm, "tasks").length) {
        errors.push(`${gid}: could not re-read before adopting; skipped`);
        unadopted++;
        continue;
      }
      const node = (confirm.data?.tasks?.nodes ?? [])[0];
      if (!node || node.id !== gid || (node.isComplete === true) !== jobberComplete) {
        // It changed under us, or vanished. Either way this cycle's conclusion is stale.
        conflicts.push(gid);
        unadopted++;
        continue;
      }

      // completed_at only matters when adopting a COMPLETION. An un-completion clears the triple,
      // and the recorder deliberately discards completed_at/completed_source when is_complete=false.
      const p: Record<string, unknown> = {
        jobber_gid: gid,
        is_complete: jobberComplete,
        expected_is_complete: oursComplete,     // (a) the optimistic-concurrency guard, ZZ002
      };
      if (jobberComplete) {
        const budgetLeft = Date.now() - t0 < SEARCH_BUDGET_MS;
        const { iso, probes } = budgetLeft
          ? await findCompletedAt(token, gid)
          : { iso: null, probes: 0 };
        if (!budgetLeft) details.search_budget_spent = true;
        if (iso) {
          p.completed_at = iso;
        } else {
          // Do NOT fail the adopt over a timestamp. Estimate, and make the estimate VISIBLE —
          // nothing on the row distinguishes an exact value from a guess.
          p.completed_at = new Date().toISOString();
          estimated.push(gid);
        }
        p.completed_source = "jobber";          // must be exactly this; a CHECK enforces the pair
        details[`probes_${gid.slice(-8)}`] = probes;
      }

      const { error: rpcErr } = await db.schema("ops")
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
    }

    // ---- 6. Undated tasks: surface, never mirror ----------------------------------------------
    // ops.calendar_tasks.task_date is NOT NULL with no default, so "unscheduled" is structurally
    // unrepresentable for us — and anyone in the Jobber UI can unschedule a task we own
    // (AppointmentEditScheduleInput has `unschedule: True`, while TaskEditInput has no such field,
    // so our own saga can never produce one). We never send task_date, so our row keeps the date it
    // had; that is the intended outcome and it is a real discrepancy an operator must see.
    if (seen.size) {
      const res: any = await gql(token, `query($ids:[EncodedId!]){
        tasks(first: ${PAGE}, filter:{ ids:$ids }){ nodes{ id startAt } } }`,
        { ids: [...seen.keys()].slice(0, PAGE) });
      if (answered(res) && !errsOf(res, "tasks").length) {
        for (const n of res.data?.tasks?.nodes ?? []) {
          if (n?.id && n.startAt === null) dateUnrepresentable.push(n.id);
        }
      }
    }

    const status = (errors.length || missing.length || conflicts.length || dateUnrepresentable.length)
      ? "attention" : "ok";
    return await finish(status);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error(`[task-poll] unhandled: ${msg}`);
    errors.push(`unhandled: ${msg}`);
    return await finish("attention", 500);
  }
});
