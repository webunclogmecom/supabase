// ============================================================================
// sync-jobber-users — Jobber's team list into hr.jobber_users (2026-10-26)
// ============================================================================
// New hires (Trello zRTbWvXn). Fred: "needs to be reflected in jobber, same as when a staff member is inactive or active".
// Plan: Building Apps/HR App/docs/specs/2026-10-26-new-hires-plan.md. Table and writer:
// docs/migrations/2026-10-26_1700_hr_jobber_users_mirror.sql.
//
// Jobber -> DB only. Jobber's API cannot create a user, change a user's status or set a pay rate, so this reads the
// whole team every 15 minutes (pg_cron via fn_request_jobber_sync('users')) and hr.sync_jobber_users links a new person
// to the Jobber user with the same email. Every page is read before anything is written: a partial read would look
// like people leaving, and the writer refuses an empty list.
//
// AUTH: verify_jwt=true at the gateway + role=service_role in the handler (the anon key also passes verify_jwt).
// ============================================================================

import { createClient } from "jsr:@supabase/supabase-js@2";
import { isSecretKeyCaller } from "../_shared/service-caller.ts";

const GQL_VERSION = "2026-04-16";
const PAGE = 100;
const MAX_PAGES = 5;

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { global: { headers: { "x-app-source": "jobber" } } },
);

function bearerRole(req: Request): string | null {
  if (isSecretKeyCaller(req)) return "service_role";
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

// Same guards as sync-jobber-timesheets' gql: an HTML waiting room at HTTP 200 and a throttle are retried, an `errors`
// array throws, and a reply with no `data` key is a MISSING answer, never an empty one.
async function gql(token: string, query: string, variables?: unknown, _retry = 0): Promise<any> {
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
  return j.data;
}

const Q = `query($after: String) {
  users(first: ${PAGE}, after: $after) {
    nodes { id name { full } email { raw } phone { raw } status isAccountAdmin isAccountOwner createdAt lastLoginAt }
    pageInfo { hasNextPage endCursor }
  }
}`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok");
  if (bearerRole(req) !== "service_role") {
    return new Response(JSON.stringify({ error: "service_role required" }), { status: 403 });
  }
  const started = new Date().toISOString();
  const stats: Record<string, unknown> = { pages: 0, read: 0, errors: 0, error_samples: [] as string[] };
  const fail = (msg: string) => {
    stats.errors = (stats.errors as number) + 1;
    const s = stats.error_samples as string[];
    if (s.length < 3) s.push(msg);
    console.error(`[jobber-users] ${msg}`);
  };

  try {
    const token = await getReadToken();
    const users: unknown[] = [];
    let after: string | null = null;
    for (let page = 0; ; page++) {
      if (page >= MAX_PAGES) throw new Error(`more than ${MAX_PAGES * PAGE} users; refusing a partial read`);
      const data = await gql(token, Q, { after });
      const c = data.users;
      if (!c || !Array.isArray(c.nodes) || !c.pageInfo) throw new Error("Jobber reply has no users nodes/pageInfo");
      users.push(...c.nodes);
      stats.pages = page + 1;
      if (!c.pageInfo.hasNextPage) break;
      after = c.pageInfo.endCursor;
    }
    stats.read = users.length;
    const { data: res, error } = await db.schema("hr").rpc("sync_jobber_users", { p_users: users });
    if (error) fail(`hr.sync_jobber_users refused: ${error.message}`);
    else stats.result = res;
  } catch (e) {
    fail(`run failed: ${e instanceof Error ? e.message : e}`);
  }

  const result = (stats.result ?? {}) as { upserted?: number; linked?: unknown[] };
  const { error: logErr } = await db.from("sync_log").insert({
    sync_source: "jobber_users",
    started_at: started,
    finished_at: new Date().toISOString(),
    rows_updated: (result.upserted ?? 0) + (Array.isArray(result.linked) ? result.linked.length : 0),
    rows_errored: stats.errors as number,
    status: stats.errors ? "partial" : "success",
    details: stats,
  });
  if (logErr) console.error(`[jobber-users] sync_log insert failed: ${logErr.message}`);
  return new Response(JSON.stringify({ ok: !stats.errors, sync_log_error: logErr?.message ?? null, ...stats }), {
    status: stats.errors ? 500 : 200, headers: { "Content-Type": "application/json" },
  });
});
