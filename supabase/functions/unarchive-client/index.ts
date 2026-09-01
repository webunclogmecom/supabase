// unarchive-client — REACTIVATE a client: un-archive it in Jobber, reopen its Service Call, then
// mark it ACTIVE here. The mirror image of archive-client, and the reactivation entry the Client App
// uses when someone presses "Reopen" on the Service Call of an INACTIVE client.
//
// WHY IT EXISTS. Spec/plan 2026-09-01 (client job-status lifecycle). Deactivating a client closes ALL
// its jobs and archives it in Jobber (archive-client). Reactivating must UN-archive it and bring back
// exactly ONE way to serve it again — the Service Call — WITHOUT resurrecting the old Service
// Agreements. Fred: "reactivating a client from inactive reopens the SC job, but not the SA job; to
// make it recurrent again the app creates a NEW SA, it does not reopen an old one."
//
// 🛑 JOBBER FIRST, VERIFY, THEN US — same order and reason as archive-client.
//    Nothing is written to public.clients.status until a FRESH re-read comes back isArchived=false.
//    A clean mutation response is not evidence (feedback_split_transport_from_reaction). Confirmed on
//    the 112-YA sandbox 2026-09-01: Jobber exposes clientUnarchive(clientId: EncodedId!) and jobReopen
//    succeeds on an archived Service Call once the client is active.
//
// 🛑 WE REOPEN THE SERVICE CALL ONLY. This function REFUSES a non-SC job (SA / legacy), so it can never
//    be the path that quietly resurrects a Service Agreement — that has to be a deliberate "create a
//    new SA" in the app, which is what flips the client to RECURRING.
//
// ⚠ THE STATUS WRITE GOES THROUGH THE 3-ARG RPC, p_reason MANDATORY — identical to archive-client.
//    client.update_client_status has a 2-arg overload whose whole body is `raise 'a reason is now
//    required'` (22023), so a 2-arg call fails LOUDLY. Only the 3-arg does the work and pins
//    status_source='manual' — the pin that stops webhook-jobber's poll re-deciding the row. Called
//    with the CALLER'S JWT so auth.uid() resolves and audit.logs attributes the change to the human.
//
// ⚠ IDEMPOTENT (rule 5): a client already isArchived=false converges our side and returns; an SC
//    already open is left as-is. Re-running is safe.
//
// ⚠ THE HELPER BLOCK BELOW IS COPIED FROM archive-client (which was spliced from save-client-property
//    by scripts/probes/build_archive_client.mjs). Keep it byte-consistent with archive-client; the
//    content-type guard in gql() is the Jobber-waiting-room fix and must not be lost.
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
  // Content-type is the only honest discriminator here, because the status code lies. Without this
  // guard the HTML body becomes {} and the caller reads data as UNDEFINED and reports its own
  // not-found message — an outage reported as data corruption.
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

const TERMINAL = new Set(["archived", "closed", "destroyed"]);

// ============================================================================
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsPreflight(req) });
  if (req.method !== "POST") return fail("method_not_allowed", "POST only.");

  // ---- staff gate (stricter than the gateway's verify_jwt) ------------------
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
  const jobId = Number(body?.job_id);            // the Service Call to reopen (our public.jobs.id)
  const reason = String(body?.reason ?? "").trim() || null;
  if (!clientId) return fail("bad_request", "client_id is required.");
  if (!jobId) return fail("bad_request", "job_id (the Service Call to reopen) is required.");

  // ---- our client row + its Jobber link ------------------------------------
  const { data: row, error: rowErr } = await db.from("clients")
    .select("id,name,client_code,status").eq("id", clientId).maybeSingle();
  // 🛑 DESTRUCTURE THE ERROR: a discarded error returns data:null and the guard fails OPEN.
  if (rowErr) return fail("db_error", rowErr.message);
  if (!row) return fail("not_found", `No client ${clientId} here.`);
  const label = row.client_code ?? row.name;

  const { data: cLink, error: cLinkErr } = await db.from("entity_source_links")
    .select("source_id").eq("entity_type", "client").eq("source_system", "jobber")
    .eq("entity_id", clientId).maybeSingle();
  if (cLinkErr) return fail("db_error", cLinkErr.message);
  if (!cLink?.source_id) {
    return fail("no_jobber_link",
      `${label} has no Jobber link, so it cannot be un-archived there. Change its status here instead.`);
  }

  // ---- the Service Call job: must exist, belong to this client, and BE an SC -
  const { data: jobRow, error: jobErr } = await db.from("jobs")
    .select("id,client_id,job_number,title").eq("id", jobId).maybeSingle();
  if (jobErr) return fail("db_error", jobErr.message);
  if (!jobRow) return fail("not_found", `No job ${jobId} here.`);
  if (Number(jobRow.client_id) !== clientId) {
    return fail("bad_request", `Job ${jobRow.job_number} does not belong to ${label}.`);
  }
  // 🛑 SC ONLY. Reactivation reopens the Service Call; SA/legacy stays closed by design.
  const isSC = String(jobRow.title ?? "").trim().toLowerCase() === "service call";
  if (!isSC) {
    return fail("not_service_call",
      `Reactivation only reopens the Service Call. Job ${jobRow.job_number} is "${jobRow.title}". ` +
      `To make ${label} recurrent again, create a new Service Agreement.`);
  }

  const { data: jLink, error: jLinkErr } = await db.from("entity_source_links")
    .select("source_id").eq("entity_type", "job").eq("source_system", "jobber")
    .eq("entity_id", jobId).maybeSingle();
  if (jLinkErr) return fail("db_error", jLinkErr.message);
  if (!jLink?.source_id) {
    return fail("no_jobber_link_job", `Service Call ${jobRow.job_number} has no Jobber link.`);
  }
  const clientGid = cLink.source_id;
  const jobGid = jLink.source_id;

  const token = await getJobberToken();

  // ---- read the client; un-archive is Jobber-first + verified ---------------
  const before = await gql(token,
    `query C($id:EncodedId!){ client(id:$id){ id isArchived } }`, { id: clientGid });
  if (!before.ok) {
    return fail("jobber_unavailable", `Jobber did not answer, so nothing was changed. (${before.detail})`);
  }
  const jc = before.data?.client;
  if (!jc) return fail("not_in_jobber", "Jobber has no client at that id. Nothing was changed.");

  let unarchived = false;
  if (jc.isArchived) {
    const un = await gql(token,
      `mutation U($clientId:EncodedId!){ clientUnarchive(clientId:$clientId){ client { id isArchived } userErrors { message } } }`,
      { clientId: clientGid });
    if (!un.ok) {
      return fail("jobber_unavailable", `Jobber did not complete the un-archive, so nothing was changed here. (${un.detail})`);
    }
    const uerr = ue(un.data?.clientUnarchive);
    if (uerr) return fail("unarchive_failed", `Jobber refused to un-archive ${label}: ${uerr}`);

    // `&&` (not `||`) so TypeScript narrows the GqlResult union before .data is read.
    const back = await gql(token, `query C($id:EncodedId!){ client(id:$id){ id isArchived } }`, { id: clientGid });
    const backOk = back.ok && back.data?.client?.isArchived === false;
    if (!backOk) {
      // 🛑 DO NOT touch our status: an unverified un-archive is exactly the drift this order prevents.
      return fail("unarchive_unverified",
        "Jobber accepted the un-archive but re-reading the client still shows it archived. Nothing was changed here.");
    }
    unarchived = true;
  }

  // ---- reopen the Service Call (only if it is terminal in Jobber) ------------
  const jRead = await gql(token,
    `query J($id:EncodedId!){ job(id:$id){ id jobStatus jobNumber } }`, { id: jobGid });
  if (!jRead.ok) {
    return fail("jobber_unavailable",
      `Client is un-archived, but reading the Service Call failed, so it was not reopened. (${jRead.detail})`,
      { unarchived });
  }
  const jNode = jRead.data?.job;
  if (!jNode) {
    return fail("not_in_jobber", "Client un-archived, but Jobber has no job at that id.", { unarchived });
  }

  let scStatus = String(jNode.jobStatus ?? "").toLowerCase();
  let scReopened = false;
  if (TERMINAL.has(scStatus)) {
    const rr = await gql(token,
      `mutation R($jobId:EncodedId!){ jobReopen(jobId:$jobId){ job { id jobStatus } userErrors { message path } } }`,
      { jobId: jobGid });
    if (!rr.ok) {
      return fail("job_reopen_failed",
        `Client is un-archived, but Jobber refused to reopen Service Call ${jobRow.job_number}: ${rr.detail}. ` +
        `Its status here has NOT been changed.`, { unarchived });
    }
    const rerr = ue(rr.data?.jobReopen);
    if (rerr) {
      return fail("job_reopen_failed",
        `Client is un-archived, but Jobber refused to reopen Service Call ${jobRow.job_number}: ${rerr}. ` +
        `Its status here has NOT been changed.`, { unarchived });
    }
    scStatus = String(rr.data?.jobReopen?.job?.jobStatus ?? "active").toLowerCase();
    scReopened = true;
  }

  // ---- record the SC's status locally (sanctioned path; attributes the human) -
  // Minimal payload: an existing job is matched by gid and only job_status is written (title etc.
  // COALESCE to their stored values). Same shape save-client-job uses for its reopen.
  const { error: recErr } = await db.rpc("fn_record_client_job",
    { p: { gid: jobGid, job_status: scStatus, actor_email: email } });
  if (recErr) {
    // Soft: Jobber is correct; the */5 poll + drift will settle our copy. Still flip the client
    // status so the app reflects reactivation.
    // (fall through to the status write; report the recording miss.)
  }

  // ---- flip our client status to ACTIVE, as the CALLER, pinning status_source='manual' ----
  const statusWrite = await setStatus(m[1], clientId,
    reason ?? `Client App: reactivated (reopened Service Call #${jobRow.job_number})`);

  return done({
    action: "unarchive",
    unarchived,
    sc_job_id: jobId,
    sc_job_number: jobRow.job_number,
    sc_reopened: scReopened,
    sc_job_status: scStatus,
    job_record_written: !recErr,
    status_write: statusWrite,
  });
});

// Writes ACTIVE through the 3-ARG overload, as the CALLER, so the gate inside the RPC still applies,
// status_source is pinned to 'manual', and audit.logs names the human.
async function setStatus(jwt: string, clientId: number, reason: string | null) {
  const asUser = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: `Bearer ${jwt}`, "x-app-source": "client-app" } } },
  );
  const { data, error } = await asUser.schema("client").rpc("update_client_status", {
    p_client_id: clientId, p_status: "ACTIVE", p_reason: reason,
  });
  // 🛑 DESTRUCTURE THE ERROR. A discarded error returns data:null and the guard fails OPEN.
  if (error) return { ok: false, message: error.message };
  return { ok: true, result: data };
}
