// archive-client — "delete" a client: ARCHIVE it in Jobber, then mark it INACTIVE here.
//
// WHY IT EXISTS. Fred, 2026-08-21: "for the Clients App and the Jobber, for the deletion of a
// Client". Deactivating a client in the app has only ever written our own clients.status; it never
// told Jobber. Measured that day: 5 of 12 INACTIVE clients were still isArchived=false in Jobber,
// so anyone working in Jobber still saw them as live customers.
//
// 🛑 THERE IS NO DELETE ON EITHER SIDE, AND THE UI MUST NOT PROMISE ONE.
//    Jobber exposes only clientArchive / clientUnarchive (introspected live 2026-08-21: there is no
//    clientDelete). Rule 6 forbids hard-deleting business data here. So this is ARCHIVE + INACTIVE,
//    and it is reversible.
//
// 🛑 JOBBER FIRST, VERIFY, THEN US, AND THE ORDER IS THE WHOLE POINT.
//    Flipping our status first is exactly how those 5 clients drifted: our side said INACTIVE while
//    Jobber never heard about it. Nothing is written here until a FRESH re-read comes back
//    isArchived=true. A clean mutation response is not evidence (feedback_split_transport_from_reaction).
//
// ✅ AND ARCHIVING IS WHAT MAKES THE DEACTIVATION STICK. webhook-jobber reactivates a client it
//    finds active upstream, which is why clients.status_source='manual' exists as a pin. Once Jobber
//    agrees the client is archived, the two systems stop fighting over the row.
//
// ⚠ SIGNATURES ARE INTROSPECTED, NOT ASSUMED (2026-08-21). The first one cost a failed run today:
//    clientArchive(clientId: EncodedId!)          <- clientId, NOT id
//    jobClose(jobId: EncodedId!, input: JobCloseInput!)
//    JobCloseInput { modifyIncompleteVisitsBy: IncompleteVisitDecisionEnum, completedOn }
//    IncompleteVisitDecisionEnum = DESTROY_ALL | COMPLETE_PAST_DESTROY_FUTURE
//
// 🛑 OPEN JOBS ARE NEVER CLOSED SILENTLY. Fred's call: "ask me in the moment". Without
//    close_jobs:true this returns code='open_jobs' with the list and writes NOTHING, so the app can
//    show them and take a second, explicit confirmation.
//    ⚠ We pass DESTROY_ALL rather than COMPLETE_PAST_DESTROY_FUTURE deliberately. An incomplete
//      visit did not happen; COMPLETE_PAST would mark the past ones COMPLETED, which asserts work
//      was performed that was not. Destroying them is honest, marking them done is not.
//
// ⚠ THE STATUS WRITE GOES THROUGH THE 3-ARG RPC, AND THAT IS LOAD-BEARING.
//    client.update_client_status has TWO overloads. The 2-arg (p_client_id, p_status) is stale and
//    does NOT set status_source='manual'; only the 3-arg (..., p_reason) does. Calling the wrong one
//    leaves the deactivation unpinned and webhook-jobber will undo it. Same overload hazard that bit
//    client.create_property. It is called with the CALLER'S JWT so auth.uid() resolves and audit.logs
//    attributes the change to the human rather than to service_role.
//
// ⚠ THE HELPER BLOCK BELOW IS SPLICED BYTE-IDENTICALLY FROM save-client-property BY
//    scripts/probes/build_archive_client.mjs. Do not hand-edit it here; edit the source and re-run,
//    or the two copies drift and the content-type guard is exactly the kind of thing that gets lost.
import { createClient } from "jsr:@supabase/supabase-js@2";

const GQL_VERSION = "2026-04-16";

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  // ADR 016: server-to-server writes carry no browser Origin, so without this the audit row would
  // land app_source='sql' instead of 'client-app'.
  { global: { headers: { "x-app-source": "client-app" } } },
);

// ---- CORS (echo the requested headers — the save-calendar-visit lesson) ----
const ALLOW_FALLBACK = "authorization, x-client-info, apikey, content-type, x-supabase-api-version";
function corsPreflight(req: Request) {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": req.headers.get("access-control-request-headers") ?? ALLOW_FALLBACK,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Max-Age": "86400",
  };
}
function hdrs() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": ALLOW_FALLBACK,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Content-Type": "application/json",
  };
}
function fail(code: string, message: string, extra: Record<string, unknown> = {}) {
  return new Response(JSON.stringify({ ok: false, code, message, ...extra }), { status: 200, headers: hdrs() });
}
function done(body: Record<string, unknown>) {
  return new Response(JSON.stringify({ ok: true, ...body }), { status: 200, headers: hdrs() });
}

// ---- Jobber WRITE token (jobber_write row + refresh; NOT the read app) ------
async function getJobberToken(): Promise<string> {
  const { data, error } = await db.from("webhook_tokens")
    .select("access_token,refresh_token,client_id,client_secret,expires_at")
    .eq("source_system", "jobber_write").single();
  if (error || !data) throw new Error("no jobber_write token row");
  if (new Date(data.expires_at).getTime() > Date.now() + 120_000) return data.access_token;
  const body = `grant_type=refresh_token&refresh_token=${encodeURIComponent(data.refresh_token)}` +
    `&client_id=${encodeURIComponent(data.client_id)}&client_secret=${encodeURIComponent(data.client_secret)}`;
  const r = await fetch("https://api.getjobber.com/api/oauth/token", {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body });
  if (!r.ok) throw new Error(`token refresh failed ${r.status}`);
  const t = await r.json();
  const exp = JSON.parse(atob(t.access_token.split(".")[1])).exp * 1000;
  await db.from("webhook_tokens").update({
    access_token: t.access_token, refresh_token: t.refresh_token || data.refresh_token,
    expires_at: new Date(exp).toISOString(), updated_at: new Date().toISOString(),
  }).eq("source_system", "jobber_write");
  return t.access_token;
}

type GqlResult = { ok: true; data: any } | { ok: false; kind: "busy" | "unreachable" | "no_answer" | "rejected"; detail: string };

async function gql(token: string, query: string, variables: Record<string, unknown>, _retry = 0): Promise<GqlResult> {
  let r: Response;
  try {
    r = await fetch("https://api.getjobber.com/api/graphql", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${token}`,
        "Content-Type": "application/json",
        "X-JOBBER-GRAPHQL-VERSION": GQL_VERSION,
      },
      body: JSON.stringify({ query, variables }),
    });
  } catch (e) {
    return { ok: false, kind: "unreachable", detail: e instanceof Error ? e.message : String(e) };
  }
  // 🛑 JOBBER SHEDS LOAD WITH AN HTML "WAITING ROOM" PAGE AT HTTP 200 (measured 2026-08-13).
  // Not 429, not 5xx, no `errors` array - a text/html body with a 200. The inherited helper did
  // `try { j = await r.json() } catch { j = {} }`, so that body became {}, sailed past both the
  // status check and the errors check, and returned ok:true with data UNDEFINED. Every caller
  // then read `data?.client` as null and reported its own not-found message: this function said
  // "Jobber has no client at that id - the link is stale", which sends someone to repair a link
  // that is perfectly healthy. An outage was being reported as data corruption.
  // Content-type is the only honest discriminator here, because the status code lies.
  const ctype = r.headers.get("content-type") ?? "";
  if (!ctype.includes("json")) {
    return { ok: false, kind: "busy",
      detail: `Jobber returned ${ctype || "an unknown content type"} at HTTP ${r.status} (its waiting room), not GraphQL` };
  }
  let j: any = {};
  try { j = await r.json(); } catch { j = {}; }
  const throttled = r.status === 429 ||
    (Array.isArray(j.errors) && j.errors.some((e: any) => e?.extensions?.code === "THROTTLED" || /throttl/i.test(e?.message || "")));
  if (throttled) {
    if (_retry < 5) {
      await new Promise((res) => setTimeout(res, 400 * Math.pow(2, _retry)));
      return gql(token, query, variables, _retry + 1);
    }
    return { ok: false, kind: "busy", detail: "throttled after 5 retries" };
  }
  if (r.status >= 500) return { ok: false, kind: "no_answer", detail: `HTTP ${r.status}` };
  if (Array.isArray(j.errors) && j.errors.length) {
    return { ok: false, kind: "rejected", detail: j.errors.map((e: any) => e.message).join("; ").slice(0, 300) };
  }
  return { ok: true, data: j.data };
}

function ue(payload: any): string | null {
  const errs = payload?.userErrors;
  if (Array.isArray(errs) && errs.length) return errs.map((e: any) => e.message).join("; ").slice(0, 300);
  return null;
}

// ============================================================================
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsPreflight(req) });
  if (req.method !== "POST") return fail("method_not_allowed", "POST only.");

  // ---- staff gate ----------------------------------------------------------
  // Stricter than the gateway's verify_jwt, which the public anon key also passes.
  const m = (req.headers.get("authorization") ?? "").match(/^Bearer (.+)$/);
  if (!m) return fail("forbidden", "Staff account required.");
  const { data: userData, error: userErr } = await db.auth.getUser(m[1]);
  const email = String(userData?.user?.email ?? "").toLowerCase();
  if (userErr || !userData?.user?.id ||
      (!email.endsWith("@ayache.com") && !email.endsWith("@unclogme.com"))) {
    return fail("forbidden", "Staff account required.");
  }

  const body = await req.json().catch(() => null);
  const clientId = Number(body?.client_id);
  const action = String(body?.action ?? "archive").toLowerCase();
  const closeJobs = body?.close_jobs === true;
  const reason = String(body?.reason ?? "").trim() || null;
  if (!clientId) return fail("bad_request", "client_id is required.");
  if (action !== "archive" && action !== "unarchive") {
    return fail("bad_request", "action must be 'archive' or 'unarchive'.");
  }

  // ---- our row + its Jobber link ------------------------------------------
  const { data: row, error: rowErr } = await db.from("clients")
    .select("id,name,client_code,status").eq("id", clientId).maybeSingle();
  // 🛑 DESTRUCTURE THE ERROR: a discarded error returns data:null and the guard fails OPEN.
  if (rowErr) return fail("db_error", rowErr.message);
  if (!row) return fail("not_found", `No client ${clientId} here.`);
  const label = row.client_code ?? row.name;

  const { data: link, error: linkErr } = await db.from("entity_source_links")
    .select("source_id").eq("entity_type", "client").eq("source_system", "jobber")
    .eq("entity_id", clientId).maybeSingle();
  if (linkErr) return fail("db_error", linkErr.message);
  if (!link?.source_id) {
    return fail("no_jobber_link",
      `${label} has no Jobber link, so it cannot be archived there. Change its status here instead.`);
  }

  const token = await getJobberToken();
  const READ =
    `query C($id:EncodedId!){ client(id:$id){ id isArchived jobs(first:50){ nodes { id jobStatus jobNumber title } } } }`;

  const before = await gql(token, READ, { id: link.source_id });
  if (!before.ok) {
    return fail("jobber_unavailable", `Jobber did not answer, so nothing was changed. (${before.detail})`);
  }
  const jc = before.data?.client;
  if (!jc) return fail("not_in_jobber", "Jobber has no client at that id. Nothing was changed.");

  // ============================ UNARCHIVE ===================================
  if (action === "unarchive") {
    if (!jc.isArchived) {
      const r = await setStatus(m[1], clientId, "ACTIVE", reason);
      return done({ action, already: true, status_write: r });
    }
    const un = await gql(token,
      `mutation U($clientId:EncodedId!){ clientUnarchive(clientId:$clientId){ client { id isArchived } userErrors { message } } }`,
      { clientId: link.source_id });
    if (!un.ok) {
      return fail("jobber_unavailable", `Jobber did not complete the unarchive, so nothing was changed here. (${un.detail})`);
    }
    const uerr = ue(un.data?.clientUnarchive);
    if (uerr) return fail("unarchive_failed", `Jobber refused: ${uerr}`);

    // `&&` (not `||`) so TypeScript narrows the GqlResult union before .data is read.
    const back = await gql(token, READ, { id: link.source_id });
    const backOk = back.ok && back.data?.client?.isArchived === false;
    if (!backOk) {
      return fail("unarchive_unverified",
        "Jobber accepted the unarchive but re-reading the client still shows it archived. Nothing was changed here.");
    }
    const r = await setStatus(m[1], clientId, "ACTIVE", reason);
    return done({ action, unarchived: true, status_write: r });
  }

  // ============================= ARCHIVE ====================================
  const TERMINAL = new Set(["archived", "closed", "destroyed"]);
  const open = (jc.jobs?.nodes ?? []).filter((j: any) => !TERMINAL.has(String(j.jobStatus).toLowerCase()));

  // Already archived upstream: converge our side and stop. Idempotent (rule 5).
  if (jc.isArchived) {
    const r = await setStatus(m[1], clientId, "INACTIVE", reason);
    return done({ action, already_archived: true, status_write: r, open_jobs: open.length });
  }

  // ---- open jobs: ASK, never act -------------------------------------------
  if (open.length && !closeJobs) {
    return fail("open_jobs",
      `${label} still has ${open.length} open job${open.length === 1 ? "" : "s"} in Jobber. Closing a job destroys its remaining visits, so confirm before continuing.`,
      { jobs: open.map((j: any) => ({ id: j.id, number: j.jobNumber, title: j.title, status: j.jobStatus })) });
  }

  // ---- explicit teardown ----------------------------------------------------
  const closed: unknown[] = [];
  if (open.length && closeJobs) {
    for (const j of open) {
      const res = await gql(token,
        `mutation X($jobId:EncodedId!,$input:JobCloseInput!){ jobClose(jobId:$jobId, input:$input){ job { id jobStatus } userErrors { message } } }`,
        { jobId: j.id, input: { modifyIncompleteVisitsBy: "DESTROY_ALL" } });
      if (!res.ok) {
        return fail("jobber_unavailable",
          `Closing job ${j.jobNumber} failed, so the client was NOT archived. (${res.detail})`, { jobs_closed: closed });
      }
      const err = ue(res.data?.jobClose);
      if (err) {
        return fail("job_close_failed",
          `Job ${j.jobNumber}: ${err}. The client was NOT archived.`, { jobs_closed: closed });
      }
      closed.push({ number: j.jobNumber, status: res.data?.jobClose?.job?.jobStatus });
    }
  }

  // ---- archive, then VERIFY BY RE-READING -----------------------------------
  const arch = await gql(token,
    `mutation A($clientId:EncodedId!){ clientArchive(clientId:$clientId){ client { id isArchived } userErrors { message } } }`,
    { clientId: link.source_id });
  if (!arch.ok) {
    return fail("jobber_unavailable",
      `Jobber did not complete the archive, so nothing was changed here. (${arch.detail})`, { jobs_closed: closed });
  }
  const aerr = ue(arch.data?.clientArchive);
  if (aerr) return fail("archive_failed", `Jobber refused: ${aerr}`, { jobs_closed: closed });

  // `&&` (not `||`) so TypeScript narrows the GqlResult union before .data is read.
  const after = await gql(token, READ, { id: link.source_id });
  const verified = after.ok && after.data?.client?.isArchived === true;
  if (!verified) {
    // 🛑 DO NOT touch our status here. An unverified archive is exactly the drift this exists to end.
    return fail("archive_unverified",
      "Jobber accepted the archive but re-reading the client does not show it archived. Nothing was changed here.",
      { jobs_closed: closed });
  }

  const statusWrite = await setStatus(m[1], clientId, "INACTIVE", reason);
  return done({ action, archived: true, jobs_closed: closed, status_write: statusWrite });
});

// Writes our side through the 3-ARG overload, as the CALLER, so the gate inside the RPC still
// applies, status_source is pinned to 'manual', and audit.logs names the human.
async function setStatus(jwt: string, clientId: number, status: string, reason: string | null) {
  const asUser = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: `Bearer ${jwt}`, "x-app-source": "client-app" } } },
  );
  const { data, error } = await asUser.schema("client").rpc("update_client_status", {
    p_client_id: clientId, p_status: status, p_reason: reason,
  });
  // 🛑 DESTRUCTURE THE ERROR. A discarded error returns data:null and the guard fails OPEN.
  if (error) return { ok: false, message: error.message };
  return { ok: true, result: data };
}
