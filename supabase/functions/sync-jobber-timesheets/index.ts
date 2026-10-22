// ============================================================================
// sync-jobber-timesheets — Jobber's time sheet into hr.time_entries (2026-10-22)
// ============================================================================
// Trello KqGyoiKQ. Fred: "for the hours worked from each of them we can use the Jobber timesheet."
// Plan: Building Apps/HR App/docs/specs/2026-10-22-hours-worked-from-jobber-timesheet.md
// The table, the writer and the hours rule: docs/migrations/2026-10-22_1940_hr_time_entries_from_jobber.sql
//
// Two modes, both Jobber -> DB only (this function never writes to Jobber):
//  - default: every entry Jobber UPDATED in the last 2 days (a clock-out, an edit, an approval). pg_cron every 30 min.
//  - ?mode=window[&days=35 | &from=YYYY-MM-DD]: EVERY entry STARTING in the window, passed to hr.sync_time_entries with
//    the window, which marks entries Jobber no longer returns as removed. Nightly with days=35; from= is the backfill.
//    🛑 The window is handed to the writer ONLY after every page was read with no error: a partial read would look like
//    deletions. The writer also refuses an empty answer over a window that holds entries.
//
// AUTH: verify_jwt=true at the gateway + role=service_role in the handler (the anon key also passes verify_jwt).
// ============================================================================

import { createClient } from "jsr:@supabase/supabase-js@2";

const GQL_VERSION = "2026-04-16";
const PAGE = 100;
const MAX_PAGES = 40;

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { global: { headers: { "x-app-source": "jobber" } } },
);

function bearerRole(req: Request): string | null {
  const m = (req.headers.get("authorization") || "").match(/^Bearer (.+)$/);
  if (!m) return null;
  try { return JSON.parse(atob(m[1].split(".")[1])).role ?? null; } catch { return null; }
}

async function getReadToken(): Promise<string> {
  const { data, error } = await db.from("webhook_tokens").select("access_token").eq("source_system", "jobber").single();
  if (error) throw new Error(`jobber read token read failed: ${error.message}`);
  if (!data?.access_token) throw new Error("no jobber read token");
  return data.access_token;
}

// Same guards as sync-jobber-job-drift's gql: an HTML waiting room at HTTP 200 and a throttle are retried, an `errors`
// array throws, and a reply with no `data` key is a MISSING answer, never an empty one.
async function gql(token: string, query: string, variables?: unknown, _retry = 0): Promise<{ data: any; available: number | null }> {
  const r = await fetch("https://api.getjobber.com/api/graphql", {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", "X-JOBBER-GRAPHQL-VERSION": GQL_VERSION },
    body: JSON.stringify({ query, variables }),
  });
  const ctype = r.headers.get("content-type") ?? "";
  if (!ctype.includes("json")) {
    if (_retry < 5) {
      await new Promise((s) => setTimeout(s, Math.min(30_000, 1_000 * Math.pow(2, _retry))));
      return gql(token, query, variables, _retry + 1);
    }
    throw new Error(`Jobber returned ${ctype || "no content-type"} at HTTP ${r.status} (busy/waiting room)`);
  }
  const j = await r.json().catch(() => ({}));
  const throttled = r.status === 429 ||
    (Array.isArray(j.errors) && j.errors.some((e: any) => e?.extensions?.code === "THROTTLED" || /throttl/i.test(e?.message || "")));
  if (throttled && _retry < 5) {
    await new Promise((s) => setTimeout(s, Math.min(30_000, 1_000 * Math.pow(2, _retry))));
    return gql(token, query, variables, _retry + 1);
  }
  if (j.errors || j.error) throw new Error(`GraphQL: ${JSON.stringify(j.errors ?? j.error).slice(0, 250)}`);
  if (j == null || typeof j !== "object" || !("data" in j) || j.data == null) {
    throw new Error(`Jobber returned no data key at HTTP ${r.status}`);
  }
  return { data: j.data, available: j.extensions?.cost?.throttleStatus?.currentlyAvailable ?? null };
}

const Q = `query($after: String, $f: TimeSheetEntriesFilterAttributes) {
  timeSheetEntries(first: ${PAGE}, after: $after, filter: $f) {
    nodes {
      id startAt endAt ticking approved timeSheetCategory note updatedAt
      user { id name { full } }
      approvedBy { id }
      targetItem { __typename ... on Visit { id } ... on Job { id } ... on Assessment { id } }
    }
    pageInfo { hasNextPage endCursor }
  }
}`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok");
  if (bearerRole(req) !== "service_role") {
    return new Response(JSON.stringify({ error: "service_role required" }), { status: 403 });
  }
  const url = new URL(req.url);
  const windowMode = url.searchParams.get("mode") === "window";
  const started = new Date().toISOString();
  const stats: Record<string, unknown> = { mode: windowMode ? "window" : "updated", pages: 0, read: 0, errors: 0, error_samples: [] as string[] };
  const fail = (msg: string) => {
    stats.errors = (stats.errors as number) + 1;
    const s = stats.error_samples as string[];
    if (s.length < 3) s.push(msg);
    console.error(`[timesheets] ${msg}`);
  };

  try {
    let filter: Record<string, unknown>;
    let windowFrom: string | null = null, windowTo: string | null = null;
    if (windowMode) {
      const from = url.searchParams.get("from");
      const days = Number(url.searchParams.get("days") ?? 35);
      if (from && !/^\d{4}-\d{2}-\d{2}$/.test(from)) throw new Error("from must be YYYY-MM-DD");
      if (!from && !(days > 0 && days <= 400)) throw new Error("days must be 1 to 400");
      windowFrom = from ? new Date(`${from}T00:00:00-05:00`).toISOString() : new Date(Date.now() - days * 864e5).toISOString();
      windowTo = new Date(Date.now() + 864e5).toISOString();
      filter = { startAt: { after: windowFrom, before: windowTo } };
    } else {
      filter = { updatedAt: { after: new Date(Date.now() - 2 * 864e5).toISOString() } };
    }
    stats.window_from = windowFrom; stats.window_to = windowTo;

    const token = await getReadToken();
    const entries: unknown[] = [];
    let after: string | null = null;
    for (let page = 0; ; page++) {
      if (page >= MAX_PAGES) throw new Error(`more than ${MAX_PAGES * PAGE} entries; refusing a partial read`);
      const { data, available } = await gql(token, Q, { after, f: filter });
      const c = data.timeSheetEntries;
      if (!c || !Array.isArray(c.nodes) || !c.pageInfo) throw new Error("Jobber reply has no timeSheetEntries nodes/pageInfo");
      entries.push(...c.nodes);
      stats.pages = page + 1;
      if (!c.pageInfo.hasNextPage) break;
      after = c.pageInfo.endCursor;
      if (available != null && available < 3000) await new Promise((s) => setTimeout(s, 6000));
    }
    stats.read = entries.length;

    const { data: res, error } = await db.schema("hr").rpc("sync_time_entries", {
      p_entries: entries, p_window_from: windowFrom, p_window_to: windowTo,
    });
    if (error) fail(`hr.sync_time_entries refused: ${error.message}`);
    else stats.result = res;
  } catch (e) {
    fail(`run failed: ${e instanceof Error ? e.message : e}`);
  }

  const result = (stats.result ?? {}) as Record<string, number>;
  const { error: logErr } = await db.from("sync_log").insert({
    sync_source: windowMode ? "jobber_timesheets_window" : "jobber_timesheets",
    started_at: started,
    finished_at: new Date().toISOString(),
    rows_updated: (result.inserted ?? 0) + (result.updated ?? 0) + (result.removed ?? 0),
    rows_errored: stats.errors as number,
    status: stats.errors ? "partial" : "success",
    details: stats,
  });
  if (logErr) console.error(`[timesheets] sync_log insert failed: ${logErr.message}`);
  return new Response(JSON.stringify({ ok: !stats.errors, sync_log_error: logErr?.message ?? null, ...stats }), {
    status: stats.errors ? 500 : 200, headers: { "Content-Type": "application/json" },
  });
});
