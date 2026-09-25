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
// ⚠ THE STATUS WRITE GOES THROUGH THE 3-ARG RPC, AND p_reason IS MANDATORY.
//    client.update_client_status has TWO overloads, and the 2-arg (p_client_id, p_status) is NOT a
//    stale-but-working copy: its entire body is `raise exception 'a reason is now required'`
//    (errcode 22023). So a 2-arg call fails LOUDLY, by design, and cannot half-write anything.
//    Only the 3-arg (..., p_reason) does the work, and it is the one that sets
//    status_source='manual' — the pin that stops webhook-jobber reactivating the client.
//    ⇒ The hazard here is a FAILED call, not silent drift. Read that the right way round: it is
//      why the deployed dialog broke outright in July rather than quietly corrupting rows.
//    It is called with the CALLER'S JWT so auth.uid() resolves and audit.logs attributes the change
//    to the human rather than to service_role.
//
// ✅ "ARCHIVE IS THE DELETE" (2026-09-18, audit Building Apps/Client App/docs/2026-09-18_client-delete-audit.md,
//    Fred: "go ahead with all the recommended"). Four additions, all additive on the wire:
//    - action:'preview' reads Jobber and our side and WRITES NOTHING, so the dialog can show open
//      jobs, isArchivable and the blockers we can count before the operator commits.
//    - a client with NO Jobber link (id 153 today) is archived HERE ONLY through the same 3-arg RPC,
//      returning jobber:'no_link' and stamping the ledger row event='archived_here_only', instead of
//      refusing and telling the operator to do that write by hand from Edit client status. The
//      unarchive direction still refuses: an unlinked row can never receive a job or a visit, so
//      "reactivating" it would promise a client that cannot be served.
//    - a client Jobber no longer HAS (client(id) null inside a well-formed reply: it was deleted in
//      the Jobber UI and the CLIENT_DESTROY never arrived) is likewise archived here only on
//      action:'archive', returning jobber:'not_found' and stamping event='deleted_in_jobber'. The old
//      not_in_jobber refusal sent the operator to Edit client status, which calls THIS function and
//      refused again: a client deleted in Jobber could not be made INACTIVE from the app at all.
//    - jobs(first:50) is a PAGE. The read now walks the connection with the cursor (up to 10 pages)
//      so every open job is seen and closed, instead of archiving with a 51st open job unseen;
//      only a client past the cap is refused (too_many_jobs_to_inspect), and only on archive of a
//      live client (unarchive and an already-archived client never needed the jobs).
//    - the ledger row the RPC writes is stamped event='archived' (client_status_changes.event,
//      migration 2026-09-18_0100), so Status history and the list can tell an archive from a plain
//      status change and from a deletion in the Jobber UI (deleted_in_jobber, written by webhook-jobber).
//    - the reply is honest about a failed write: ok:false status_write_failed when the only write
//      (our status) failed, never ok:true with a failed status_write buried inside.
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

// `version` added 2026-09-25 for the live-blocker invoice read only (see readLiveBlockers); every other
// call keeps GQL_VERSION. This block is no longer byte-identical to save-client-property.
async function gql(token: string, query: string, variables: Record<string, unknown>, _retry = 0, version = GQL_VERSION): Promise<GqlResult> {
  let r: Response;
  try {
    r = await fetch("https://api.getjobber.com/api/graphql", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${token}`,
        "Content-Type": "application/json",
        "X-JOBBER-GRAPHQL-VERSION": version,
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
      return gql(token, query, variables, _retry + 1, version);
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
  if (action !== "archive" && action !== "unarchive" && action !== "preview") {
    return fail("bad_request", "action must be 'archive', 'unarchive' or 'preview'.");
  }
  const resolveIn = parseResolve(body?.resolve);
  if (!resolveIn.ok) return fail("bad_request", resolveIn.message);
  if (resolveIn.list.length && action !== "archive") {
    return fail("bad_request", "Items to clear can only be sent with action 'archive'.");
  }
  // client.update_client_status refuses a blank reason and one over 500 characters (22023). Checked
  // here so it can never fail AFTER Jobber was changed and lose the record of what was cleared.
  if (action !== "preview" && (!reason || reason.length > 500)) {
    return fail("bad_request", "A reason of up to 500 characters is required. Nothing was changed.");
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
    // No Jobber record to archive. For 'archive' converge our side through the same RPC the linked
    // path uses (reason required, status_source pinned, ledger row, audit names the human); that is
    // byte-for-byte the write the old refusal told the operator to make by hand. For 'preview'
    // report it so the dialog can say "archives here only". For 'unarchive' refuse: see the header.
    if (action === "preview") {
      return done({ action, jobber: "no_link", status: row.status, open_jobs: [], is_archivable: null,
        more_jobs_than_inspected: false,
        blocker_counts: await countArchiveBlockers(clientId), history: await historyKept(clientId) });
    }
    if (action === "unarchive") {
      return fail("no_jobber_link",
        `${label} has no Jobber record, so it cannot be reactivated. Create the client again instead; this record stays as history.`);
    }
    const r = await setStatus(m[1], clientId, "INACTIVE", reason);
    if (!r.ok) return fail("status_write_failed", `${label} could not be marked archived here: ${r.message}. Nothing was changed.`);
    await stampLedger(r.result, "archived_here_only");
    return done({ action, jobber: "no_link", archived: false, jobs_closed: [], status_write: r });
  }

  const token = await getJobberToken();
  // jobs(first:50) is a PAGE. The first read carries pageInfo; readAllJobs() below walks the rest
  // with the cursor when a client has more, so open work is never left unseen on a later page.
  const READ =
    `query C($id:EncodedId!){ client(id:$id){ id isArchived isArchivable jobs(first:50){ nodes { id jobStatus jobNumber title } pageInfo { hasNextPage endCursor } } } }`;

  const before = await gql(token, READ, { id: link.source_id });
  if (!before.ok) {
    return fail("jobber_unavailable", `Jobber did not answer, so nothing was changed. (${before.detail})`);
  }
  // 🛑 A MISSING ANSWER IS NOT AN ABSENT CLIENT. The shared gql helper turns an unparseable or
  //    data-less JSON body into ok:true with data undefined (it must not be hand-edited here, see the
  //    header), and the converge arm below WRITES on a null client. So only a reply that carries the
  //    `client` key may proceed; anything else is Jobber not answering.
  if (before.data == null || typeof before.data !== "object" || !("client" in before.data)) {
    return fail("jobber_unavailable", "Jobber did not answer, so nothing was changed. (reply carried no client)");
  }
  const jc = before.data.client;
  if (!jc) {
    // A well-formed reply with client: null. gql() already separated this from busy / no_answer /
    // rejected, and the key check above from a data-less body, so Jobber is affirmatively saying it
    // holds no such client (deleted in its UI).
    if (action === "preview") {
      return done({ action, jobber: "not_found", status: row.status, open_jobs: [], is_archivable: null,
        more_jobs_than_inspected: false,
        blocker_counts: await countArchiveBlockers(clientId), history: await historyKept(clientId) });
    }
    if (action === "unarchive") {
      return fail("not_in_jobber",
        `${label} was deleted in Jobber, so it cannot be reactivated. Create the client again instead; this record stays as history.`);
    }
    const r = await setStatus(m[1], clientId, "INACTIVE", reason);
    if (!r.ok) return fail("status_write_failed", `${label} could not be marked archived here: ${r.message}. Nothing was changed.`);
    await stampLedger(r.result, "deleted_in_jobber");
    return done({ action, jobber: "not_found", archived: false, jobs_closed: [], status_write: r });
  }
  // The rest of the jobs, if any (bounded; a client past the cap is refused on archive only).
  const paged = await readAllJobs(token, link.source_id, jc);
  if (paged === "too_many" && action === "archive" && !jc.isArchived) {
    return fail("too_many_jobs_to_inspect",
      `${label} has more than ${MAX_JOB_PAGES * 50} jobs in Jobber, more than this can inspect. Archive it in Jobber directly, then use Archive client here to match. Nothing was changed.`);
  }

  const TERMINAL = new Set(["archived", "closed", "destroyed"]);
  const open = (jc.jobs?.nodes ?? []).filter((j: any) => !TERMINAL.has(String(j.jobStatus).toLowerCase()));
  const openList = open.map((j: any) => ({ id: j.id, number: j.jobNumber, title: j.title, status: j.jobStatus }));

  // ============================= PREVIEW ====================================
  // Read-only: what the Archive dialog shows BEFORE Save. Nothing is written on either side.
  if (action === "preview") {
    // The live list from Jobber, with the actions each item allows, when the write app can read
    // quotes/requests/invoices; null (with the reason) when it cannot, and the dialog falls back to
    // blocker_counts from our records.
    const live = jc.isArchived ? null : await readLiveBlockers(token, link.source_id);
    return done({
      action,
      jobber: jc.isArchived ? "archived" : "live",
      status: row.status,
      is_archivable: typeof jc.isArchivable === "boolean" ? jc.isArchivable : null,
      open_jobs: openList,
      more_jobs_than_inspected: paged === "too_many",
      // quotes / invoices from OUR records (a count is omitted, never zeroed, on a read error);
      // Jobber work requests are not in our DB and only show up as a refusal after the attempt.
      blocker_counts: await countArchiveBlockers(clientId),
      live_blockers: live?.ok ? groupBlockers(live.items, live.truncated) : null,
      live_blockers_unavailable: live && !live.ok ? live.kind : null,
      history: await historyKept(clientId),
    });
  }

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
  // Already archived upstream: converge our side and stop. Idempotent (rule 5).
  if (jc.isArchived) {
    const r = await setStatus(m[1], clientId, "INACTIVE", reason);
    if (r.ok) await stampLedger(r.result, "archived");
    if (!r.ok) return fail("status_write_failed", `${label} is archived in Jobber but could not be marked archived here: ${r.message}. Retry.`);
    return done({ action, already_archived: true, status_write: r, open_jobs_count: open.length, jobs_closed: [] });
  }

  // ---- live blockers: CHECKED BEFORE ANY WRITE (2026-09-25) -----------------
  // Fred: "when it get's blocked we need to show a reason why ... and in the case of pending
  // INVOICES/QUOTES ... show a confirmation dialog saying 'Close invoice' ... and continue the process".
  // Until this existed the teardown closed every job and only THEN learned Jobber would refuse the
  // archive, leaving the client ACTIVE with nothing open (176-SOU 2026-09-22, 201-ALA 2026-09-25).
  // Now what Jobber holds is read first, and anything the operator did not explicitly clear stops the
  // run before a single write.
  const live = await readLiveBlockers(token, link.source_id);
  const plan: Array<{ item: LiveItem; r: Resolve }> = [];
  if (live.ok) {
    const byGid = new Map(resolveIn.list.map((r) => [r.gid, r]));
    let unresolved = 0;
    for (const it of live.items) {
      const r = byGid.get(it.gid);
      if (r && it.actions.includes(r.action)) plan.push({ item: it, r }); else unresolved++;
    }
    if (live.truncated) {
      return fail("archive_blocked_preconditions",
        `${label} has more quotes, work requests or invoices in Jobber than this can check. Archive it in Jobber directly, then use Archive client here to match. Nothing was changed.`,
        { blockers: groupBlockers(live.items, true), open_jobs: openList, live: true, jobs_closed: [] });
    }
    if (unresolved) {
      const planned = new Set(plan.map((p) => p.item.gid));
      const cats = [...new Set(live.items.filter((i) => !planned.has(i.gid)).map((i) => BLOCKER_LABEL[CAT[i.kind]]))].join(", ");
      return fail("archive_blocked_preconditions",
        `Jobber will not archive ${label} while it still has open ${cats}. Nothing was changed. Clear them in Jobber, then try again.`,
        { blockers: groupBlockers(live.items, false), open_jobs: openList, live: true, jobs_closed: [] });
    }
  } else if (live.kind === "no_scope") {
    // The Jobber write app cannot read quotes/requests/invoices yet: keep the old path, where Jobber's
    // own refusal after the attempt names the blockers. Asking to clear something is refused outright.
    if (resolveIn.list.length) {
      return fail("blocker_actions_unavailable",
        "Invoices and work requests cannot be cleared from here yet: the Jobber connection needs invoice and request access. Clear them in Jobber, then try again. Nothing was changed.");
    }
  } else {
    return fail("jobber_unavailable", `Jobber did not answer, so nothing was changed. (${live.detail})`);
  }

  // ---- open jobs: ASK, never act -------------------------------------------
  if (open.length && !closeJobs) {
    return fail("open_jobs",
      `${label} still has ${open.length} open job${open.length === 1 ? "" : "s"} in Jobber. Closing a job destroys its remaining visits, so confirm before continuing.`,
      { jobs: openList });
  }

  // ---- clear the confirmed blockers: JOBBER FIRST, each verified by a re-read -
  // Only items Jobber holds RIGHT NOW as blockers are acted on; a resolve entry for anything else
  // (paid meanwhile, another client's id) never reaches a mutation because it is not in `plan`.
  // The status history is the Activity history: name what will be cleared, under the operator's reason.
  // Built and length-checked BEFORE the first Jobber write: the RPC refuses over 500 characters, and a
  // refusal after the write-offs would lose the only record of them (the status would then be written
  // later by the poll or a bare retry, without this list).
  let statusReason = reason;
  if (plan.length) {
    const head = `${reason}\n\nCleared in Jobber first: `;
    const room = 500 - head.length - 1;
    if (room < 60) {
      return fail("reason_too_long",
        "Shorten the reason to 400 characters or fewer so what is cleared in Jobber can be saved with it. Nothing was changed.");
    }
    let list = plan.map(({ item, r }) => summarizeAction(item, r)).join("; ");
    if (list.length > room) list = list.slice(0, room - 9) + " and more"; // ponytail: full list is in the log lines
    statusReason = head + list + ".";
  }

  const resolved: Array<{ kind: string; gid: string; number: string | null; action: string; status_after: string; summary: string }> = [];
  const closed: unknown[] = [];
  const already = () => {
    const d = [...resolved.map((x) => x.summary + (x.status_after === "unverified" ? " (not confirmed)" : "")),
      ...(closed.length ? [`${closed.length} job${closed.length === 1 ? "" : "s"} closed`] : [])];
    return d.length ? ` Already done in Jobber: ${d.join("; ")}.` : "";
  };
  for (const { item, r } of plan) {
    const out = await applyResolution(token, item, r);
    if (out.ok || out.unverified) {
      resolved.push({ kind: item.kind, gid: item.gid, number: item.number, action: r.action,
        status_after: out.ok ? out.status : "unverified", summary: summarizeAction(item, r) });
      // Who wrote off what. The status reason carries it too, but only once the archive completes.
      console.log(JSON.stringify({ fn: "archive-client", client_id: clientId, by: email, gid: item.gid, kind: item.kind,
        action: r.action, number: item.number, amount: item.outstanding ?? item.total, verified: out.ok }));
    }
    if (!out.ok) {
      return fail("blocker_action_failed",
        `${describeItem(item)}: ${out.message} No job was closed and ${label} was not archived.${already()}`,
        { resolved, jobs_closed: [] });
    }
  }

  // ---- explicit teardown ----------------------------------------------------
  if (open.length && closeJobs) {
    for (const j of open) {
      const res = await gql(token,
        `mutation X($jobId:EncodedId!,$input:JobCloseInput!){ jobClose(jobId:$jobId, input:$input){ job { id jobStatus } userErrors { message } } }`,
        { jobId: j.id, input: { modifyIncompleteVisitsBy: "DESTROY_ALL" } });
      if (!res.ok) {
        return fail("jobber_unavailable",
          `Closing job ${j.jobNumber} failed, so the client was NOT archived. (${res.detail})${already()}`, { jobs_closed: closed, resolved });
      }
      const err = ue(res.data?.jobClose);
      if (err) {
        return fail("job_close_failed",
          `Job ${j.jobNumber}: ${err}. The client was NOT archived.${already()}`, { jobs_closed: closed, resolved });
      }
      // A reply that does not return the job is not proof Jobber closed it.
      if (!res.data?.jobClose?.job?.id) {
        return fail("jobber_unavailable",
          `Jobber did not confirm closing job ${j.jobNumber}, so the client was NOT archived.${already()}`, { jobs_closed: closed, resolved });
      }
      closed.push({ number: j.jobNumber, status: res.data.jobClose.job.jobStatus });
    }
  }

  // ---- archive, then VERIFY BY RE-READING -----------------------------------
  const arch = await gql(token,
    `mutation A($clientId:EncodedId!){ clientArchive(clientId:$clientId){ client { id isArchived } userErrors { message } } }`,
    { clientId: link.source_id });
  if (!arch.ok) {
    return fail("jobber_unavailable",
      `Jobber did not complete the archive. The client was not marked inactive here. (${arch.detail})${already()}`, { jobs_closed: closed, resolved });
  }
  const aerr = ue(arch.data?.clientArchive);
  if (aerr) {
    // 🛑 STRUCTURED PRE-CONDITION REFUSAL (2026-09-01). Jobber will not archive a client that still
    // has open work requests, unresolved quotes, or unresolved invoices, and it says so in one
    // opaque userError string: "Archive, convert, or delete all work requests; Archive, convert, or
    // delete all quotes; Delete, void, or mark all invoices as paid or as bad debt" (measured on
    // 112-YA after every job was closed). Since 2026-09-25 the live pre-check above normally refuses
    // BEFORE any write and offers bad debt / archive for invoices and work requests; this arm remains
    // for the no-scope path and for a blocker that appeared between that read and this mutation.
    // So turn the opaque string into named categories the operator can act on, enriched where OUR DB
    // can count them. Our status is still not written.
    const blockers = parseArchiveBlockers(aerr);
    if (blockers.length) {
      const counts = await countArchiveBlockers(clientId); // best-effort; omits a count on any read error
      const detail = blockers.map((cat) => ({
        category: cat,
        source: cat === "work_requests" ? "jobber" : "db",
        // Requests are not in our DB, so there is never a count for them. quotes/invoices come from
        // OUR records and may be null if the read failed; null means "not counted", never "zero".
        count: cat === "quotes" ? (counts.open_quotes ?? null)
          : cat === "invoices" ? (counts.unresolved_invoices ?? null)
          : null,
        // The actual rows, so the operator is told WHICH quote or invoice to clear instead of being
        // sent to hunt. Absent for work_requests, which are not in our DB at all. An empty array here
        // means "we could not name them", never "there are none": Jobber's userError is what says a
        // blocker exists.
        items: cat === "quotes" ? (counts.quote_items ?? [])
          : cat === "invoices" ? (counts.invoice_items ?? [])
          : [],
      }));
      const human = blockers.map((c) => BLOCKER_LABEL[c]).join(", ");
      return fail("archive_blocked_preconditions",
        `${label} cannot be archived yet: Jobber still has open ${human}. Open the client in Jobber and clear them (quotes and work requests: archive, convert or delete; invoices: mark paid, void or bad debt; draft invoices: delete), then try again. The client was not marked inactive here.${already()}`,
        { blockers: detail, jobber_error: aerr, jobs_closed: closed, resolved });
    }
    return fail("archive_failed", `Jobber refused: ${aerr}${already()}`, { jobs_closed: closed, resolved });
  }

  // `&&` (not `||`) so TypeScript narrows the GqlResult union before .data is read.
  const after = await gql(token, READ, { id: link.source_id });
  const verified = after.ok && after.data?.client?.isArchived === true;
  if (!verified) {
    // 🛑 DO NOT touch our status here. An unverified archive is exactly the drift this exists to end.
    return fail("archive_unverified",
      `Jobber accepted the archive but re-reading the client does not show it archived. The client was not marked inactive here.${already()}`,
      { jobs_closed: closed, resolved });
  }

  const statusWrite = await setStatus(m[1], clientId, "INACTIVE", statusReason);
  if (statusWrite.ok) await stampLedger(statusWrite.result, "archived");
  return done({ action, archived: true, jobs_closed: closed, resolved, status_write: statusWrite });
});

// Marks the ledger row the RPC just wrote as an ARCHIVE (client_status_changes.event, 2026-09-18).
// Best effort and service_role: the status is already written and verified, and a missing stamp
// only costs the "Archived" chip its precision, never the archive. update_client_status returns
// noop with status_change_id null when the status did not move (already INACTIVE); nothing to stamp.
async function stampLedger(result: unknown, event: "archived" | "archived_here_only" | "deleted_in_jobber") {
  const id = Number((result as { status_change_id?: number } | null)?.status_change_id);
  if (!id) return;
  const { error } = await db.from("client_status_changes").update({ event }).eq("id", id);
  if (error) console.log(`[archive-client] ledger stamp failed for status_change ${id}: ${error.message}`);
}

// Walks the client's job connection past the first page (which the READ already holds), appending
// nodes onto jc.jobs.nodes in place. Returns "too_many" when the cap is reached with pages still
// left, "ok" otherwise. A transport failure mid-walk is treated as "too_many" for archive (nothing
// is written when open work may be unseen) and as complete-so-far for preview.
const MAX_JOB_PAGES = 10;
async function readAllJobs(token: string, gid: string, jc: any): Promise<"ok" | "too_many"> {
  let hasNext = jc.jobs?.pageInfo?.hasNextPage === true;
  let cursor: string | null = jc.jobs?.pageInfo?.endCursor ?? null;
  let pages = 1;
  while (hasNext) {
    if (pages >= MAX_JOB_PAGES || !cursor) return "too_many";
    const res = await gql(token,
      `query J($id:EncodedId!,$after:String){ client(id:$id){ jobs(first:50, after:$after){ nodes { id jobStatus jobNumber title } pageInfo { hasNextPage endCursor } } } }`,
      { id: gid, after: cursor });
    if (!res.ok) return "too_many";
    const page = res.data?.client?.jobs;
    if (!page || !Array.isArray(page.nodes)) return "too_many";   // no answer is not an empty page
    for (const n of page.nodes) jc.jobs.nodes.push(n);
    hasNext = page?.pageInfo?.hasNextPage === true;
    cursor = page?.pageInfo?.endCursor ?? null;
    pages++;
  }
  return "ok";
}

// What stays after an archive, for the dialog's "history kept" line. Counts only; a count is
// omitted on a read error rather than shown as zero.
async function historyKept(clientId: number): Promise<Record<string, number>> {
  const out: Record<string, number> = {};
  const tables: Array<[string, string, boolean]> = [
    ["visits", "visits", true], ["invoices", "invoices", false], ["derm_manifests", "manifests", true],
    ["derm_email_sends", "derm_emails", false], ["client_status_changes", "status_changes", false],
  ];
  for (const [table, key, softDeleted] of tables) {
    try {
      const base = db.from(table).select("id", { count: "exact", head: true }).eq("client_id", clientId);
      const { count, error } = softDeleted ? await base.is("deleted_at", null) : await base;
      if (!error && typeof count === "number") out[key] = count;
    } catch { /* omit */ }
  }
  return out;
}

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

// ---- structured archive-refusal helpers (2026-09-01) ------------------------
// Jobber refuses clientArchive until the client has no open work requests, no open quotes and all
// invoices resolved, reporting ALL of it in ONE opaque userError. parseArchiveBlockers turns that
// string into stable category keys. It is deliberately substring-based and count-free so it stays
// correct even when Jobber changes counts or wording, and so the categories our OAuth scope cannot
// read (requests) or must not touch (invoices) are still surfaced.
const BLOCKER_LABEL: Record<string, string> = {
  work_requests: "work requests",
  quotes: "quotes",
  invoices: "invoices",
};

function parseArchiveBlockers(msg: string): string[] {
  const m = (msg ?? "").toLowerCase();
  const cats: string[] = [];
  if (m.includes("work request")) cats.push("work_requests");
  if (m.includes("quote")) cats.push("quotes");
  if (m.includes("invoice")) cats.push("invoices");
  return cats;
}

// Best-effort enrichment from OUR DB (service_role). A count is OMITTED, never zeroed, on any error.
// A quote still blocks unless it is archived or converted ("archive, convert, or delete all quotes");
// an invoice still blocks unless paid, void or bad debt ("delete, void, or mark ... paid ... bad debt").
// Verified against 112-YA (client 381) 2026-09-01: 7 open quotes, 1 unresolved invoice. NOT IN also
// excludes NULL-status rows, the conservative direction for a convenience count. Jobber Requests are
// NOT in our DB, so they are never counted — they come only from the parsed userError text.
// 🛑 IT NOW RETURNS THE ITEMS, NOT ONLY A COUNT (2026-09-22). Diego hit this on 176-SOU and could not
// act on it: the reply said "Jobber still has open quotes, invoices" and nothing else, so the operator
// had to go and hunt for which ones. The blockers are in OUR database with a 100% Jobber link rate
// (measured: 265/265 quotes, 2631/2631 invoices), so naming them costs one extra select each.
//
// ⚠ The counts stay EXACTLY as they were and keep their meaning: null means "not counted", never
// "zero". `items` is best-effort in the same way, and a missing `items` must never be read as "there
// are none" - the categories come from Jobber's own userError, which is the authority on whether a
// blocker exists. Our rows only say WHICH.
//
// ⚠ The URL patterns were verified live in Jobber on 2026-09-22, not assumed:
//   gid://Jobber/Quote/52743720   -> https://secure.getjobber.com/quotes/52743720
//                                    (tab title "Quote for What Soup - 176-SOU - Jobber")
//   gid://Jobber/Invoice/165813891 -> https://secure.getjobber.com/invoices/165813891
// Per the parent CLAUDE.md rule 1b the id comes from entity_source_links, NEVER from the visible
// number, and an item with no link renders without one rather than as a dead link.
type BlockerItem = {
  kind: "quote" | "invoice";
  number: string | null;
  status: string | null;
  total: number | null;
  outstanding: number | null;
  title: string | null;
  url: string | null;
};

async function jobberUrlsFor(
  entityType: "quote" | "invoice",
  ids: number[],
): Promise<Map<number, string>> {
  const out = new Map<number, string>();
  if (!ids.length) return out;
  try {
    const { data, error } = await db.from("entity_source_links")
      .select("entity_id,source_id")
      .eq("entity_type", entityType).eq("source_system", "jobber")
      .in("entity_id", ids);
    if (error || !data) return out;
    const seg = entityType === "quote" ? "quotes" : "invoices";
    for (const row of data as Array<{ entity_id: number; source_id: string }>) {
      try {
        const m = /^gid:\/\/Jobber\/\w+\/(\d+)$/.exec(atob(row.source_id));
        if (m) out.set(row.entity_id, `https://secure.getjobber.com/${seg}/${m[1]}`);
      } catch { /* a malformed link just means no url for that row */ }
    }
  } catch { /* no urls, never fail the response */ }
  return out;
}

async function countArchiveBlockers(
  clientId: number,
): Promise<{ open_quotes?: number; unresolved_invoices?: number; quote_items?: BlockerItem[]; invoice_items?: BlockerItem[] }> {
  const out: { open_quotes?: number; unresolved_invoices?: number; quote_items?: BlockerItem[]; invoice_items?: BlockerItem[] } = {};
  try {
    const { data, count, error } = await db.from("quotes")
      .select("id,quote_number,quote_status,total,title", { count: "exact" })
      .eq("client_id", clientId)
      .not("quote_status", "in", "(archived,converted)")
      .order("quote_number", { ascending: true })
      .limit(25);
    if (!error && typeof count === "number") out.open_quotes = count;
    if (!error && data) {
      const urls = await jobberUrlsFor("quote", data.map((r: { id: number }) => r.id));
      out.quote_items = (data as Array<Record<string, unknown>>).map((r) => ({
        kind: "quote" as const,
        number: (r.quote_number as string) ?? null,
        status: (r.quote_status as string) ?? null,
        total: r.total == null ? null : Number(r.total),
        outstanding: null,
        title: ((r.title as string) ?? "").trim() || null,
        url: urls.get(r.id as number) ?? null,
      }));
    }
  } catch { /* omit the count, never fail the response */ }
  try {
    const { data, count, error } = await db.from("invoices")
      .select("id,invoice_number,invoice_status,total,outstanding_amount,subject", { count: "exact" })
      .eq("client_id", clientId)
      .not("invoice_status", "in", "(paid,void,bad_debt)")
      .order("invoice_number", { ascending: true })
      .limit(25);
    if (!error && typeof count === "number") out.unresolved_invoices = count;
    if (!error && data) {
      const urls = await jobberUrlsFor("invoice", data.map((r: { id: number }) => r.id));
      out.invoice_items = (data as Array<Record<string, unknown>>).map((r) => ({
        kind: "invoice" as const,
        number: (r.invoice_number as string) ?? null,
        status: (r.invoice_status as string) ?? null,
        total: r.total == null ? null : Number(r.total),
        outstanding: r.outstanding_amount == null ? null : Number(r.outstanding_amount),
        title: ((r.subject as string) ?? "").trim() || null,
        url: urls.get(r.id as number) ?? null,
      }));
    }
  } catch { /* omit the count, never fail the response */ }
  return out;
}

// ---- live archive blockers + the actions an operator may take on them (2026-09-25) ------------------
// Read from JOBBER with the write app, which needs read_quotes/read_requests/read_invoices plus
// write_invoices/write_requests (Fred approved adding them 2026-09-25). Without them readLiveBlockers
// returns no_scope and the handler keeps the pre-2026-09-25 path, so this is safe to deploy first.
// What blocks is Jobber's own rule, quoted from its userError: "Archive, convert, or delete all work
// requests; Archive, convert, or delete all quotes; Delete, void, or mark all invoices as paid or as
// bad debt". Actions offered:
//   invoice (awaiting_payment / past_due / sent_not_due) -> bad_debt   (invoiceClose BAD_DEBT)
//   work request                                          -> archive    (requestArchive)
//   quote                                                 -> none: Jobber has no quote archive mutation
//   draft invoice                                         -> none: it has to be deleted in Jobber
// 🛑 VOID IS NOT OFFERED YET. invoiceVoid exists only from API 2026-09-09, where the status reads
// "voided", a value the 2026-04-16 invoice sync has never seen. It turns on after a voided test invoice
// is proven harmless to that sync.
type LiveItem = {
  kind: "quote" | "invoice" | "request"; gid: string; number: string | null; status: string | null;
  total: number | null; outstanding: number | null; title: string | null; url: string | null; actions: string[];
};
type Resolve = { gid: string; action: "bad_debt" | "archive" };
type Live = { ok: true; items: LiveItem[]; truncated: boolean } | { ok: false; kind: "no_scope" | "unavailable"; detail: string };

const CAT: Record<string, string> = { quote: "quotes", invoice: "invoices", request: "work_requests" };
const MAX_RESOLVE = 50;
const LIVE_PAGES = 10;
const QUOTE_DONE = new Set(["archived", "converted"]);
const REQUEST_DONE = new Set(["archived", "converted"]);
const INVOICE_DONE = new Set(["paid", "bad_debt", "voided"]);
const INVOICE_ACTIONABLE = new Set(["awaiting_payment", "past_due", "sent_not_due"]);

function parseResolve(raw: unknown): { ok: true; list: Resolve[] } | { ok: false; message: string } {
  if (raw == null) return { ok: true, list: [] };
  if (!Array.isArray(raw) || raw.length > MAX_RESOLVE) {
    return { ok: false, message: `resolve must be a list of at most ${MAX_RESOLVE} items.` };
  }
  const list: Resolve[] = [];
  const seen = new Set<string>();
  for (const r of raw as Array<Record<string, unknown>>) {
    const gid = String(r?.gid ?? "").trim();
    const action = String(r?.action ?? "");
    if (!gid || (action !== "bad_debt" && action !== "archive")) {
      return { ok: false, message: "Each item to clear needs its Jobber id and an action (bad_debt or archive)." };
    }
    if (seen.has(gid)) return { ok: false, message: "The same item was listed twice." };
    seen.add(gid);
    list.push({ gid, action });
  }
  return { ok: true, list };
}

function jobberWebUrl(seg: string, gid: string): string | null {
  try {
    const m = /^gid:\/\/Jobber\/\w+\/(\d+)$/.exec(atob(gid));
    return m ? `https://secure.getjobber.com/${seg}/${m[1]}` : null;
  } catch { return null; }
}

function toLiveItem(key: string, n: any): LiveItem | null {
  const num = (v: unknown) => (v == null ? null : Number(v));
  if (key === "quotes") {
    const st = String(n?.quoteStatus ?? "").toLowerCase();
    if (QUOTE_DONE.has(st)) return null;
    return { kind: "quote", gid: n.id, number: n.quoteNumber == null ? null : String(n.quoteNumber), status: st || null,
      total: num(n.amounts?.total), outstanding: null, title: String(n.title ?? "").trim() || null,
      url: jobberWebUrl("quotes", n.id), actions: [] };
  }
  if (key === "requests") {
    const st = String(n?.requestStatus ?? "").toLowerCase();
    if (REQUEST_DONE.has(st)) return null;
    return { kind: "request", gid: n.id, number: null, status: st || null, total: null, outstanding: null,
      title: String(n.title ?? "").trim() || null, url: n.jobberWebUri ?? null, actions: ["archive"] };
  }
  const st = String(n?.invoiceStatus ?? "").toLowerCase();
  if (INVOICE_DONE.has(st)) return null;
  return { kind: "invoice", gid: n.id, number: n.invoiceNumber == null ? null : String(n.invoiceNumber), status: st || null,
    total: num(n.amounts?.total), outstanding: num(n.amounts?.invoiceBalance), title: String(n.subject ?? "").trim() || null,
    url: jobberWebUrl("invoices", n.id), actions: INVOICE_ACTIONABLE.has(st) ? ["bad_debt"] : [] };
}

async function readLiveBlockers(token: string, gid: string): Promise<Live> {
  const conns: Array<[string, string]> = [
    ["quotes", "id quoteNumber quoteStatus title amounts { total }"],
    ["requests", "id title requestStatus jobberWebUri"],
    ["invoices", "id invoiceNumber invoiceStatus subject amounts { total invoiceBalance }"],
  ];
  const items: LiveItem[] = [];
  let truncated = false;
  for (const [key, sel] of conns) {
    let after: string | null = null;
    for (let page = 0; ; page++) {
      if (page >= LIVE_PAGES) { truncated = true; break; }
      // 🛑 Invoices are read at 2026-09-09. At 2026-04-16 a VOIDED invoice reads "awaiting_payment" with a
      // 0 balance (measured on test invoice #3247, 2026-09-25), so it would show as a blocker offering
      // bad debt, although Jobber counts a voided invoice as resolved.
      const res = await gql(token,
        `query L($id:EncodedId!,$after:String){ client(id:$id){ ${key}(first:50, after:$after){ nodes { ${sel} } pageInfo { hasNextPage endCursor } } } }`,
        { id: gid, after }, 0, key === "invoices" ? "2026-09-09" : GQL_VERSION);
      if (!res.ok) {
        const noScope = res.kind === "rejected" && /permission|scope|not authori[sz]ed|access denied/i.test(res.detail);
        return { ok: false, kind: noScope ? "no_scope" : "unavailable", detail: res.detail };
      }
      // 🛑 A missing connection is NOT an empty one. Treating it as [] would read "no blockers" and let
      // the teardown run: the exact partial archive this check exists to prevent.
      const conn = res.data?.client?.[key];
      if (!conn || !Array.isArray(conn.nodes)) return { ok: false, kind: "unavailable", detail: `Jobber's reply carried no ${key}` };
      for (const n of conn.nodes) { const it = toLiveItem(key, n); if (it) items.push(it); }
      if (conn.pageInfo?.hasNextPage !== true) break;
      after = conn.pageInfo?.endCursor ?? null;
      if (!after) { truncated = true; break; }
    }
  }
  return { ok: true, items, truncated };
}

function groupBlockers(items: LiveItem[], truncated: boolean) {
  const out: Array<Record<string, unknown>> = [];
  for (const cat of ["work_requests", "quotes", "invoices"]) {
    const its = items.filter((i) => CAT[i.kind] === cat);
    if (its.length) out.push({ category: cat, source: "jobber", count: truncated ? null : its.length, items: its });
  }
  return out;
}

function money(n: number | null): string {
  return n == null ? "" : ` ($${n.toFixed(2)})`;
}
function describeItem(it: LiveItem): string {
  if (it.kind === "invoice") return `Invoice #${it.number ?? "?"}`;
  if (it.kind === "quote") return `Quote #${it.number ?? "?"}`;
  return `Work request${it.title ? ` "${it.title}"` : ""}`;
}
function summarizeAction(it: LiveItem, r: Resolve): string {
  if (it.kind === "invoice" && r.action === "bad_debt") return `invoice #${it.number ?? "?"} marked as bad debt${money(it.outstanding ?? it.total)}`;
  if (it.kind === "request" && r.action === "archive") return `work request${it.title ? ` "${it.title}"` : ""} archived`;
  return `${describeItem(it)}: ${r.action}`;
}

// One confirmed action, Jobber first, and the FRESH re-read decides, whatever the mutation reply said.
// A clean reply is not evidence (feedback_split_transport_from_reaction); a timeout or a refusal can
// equally hide a write that landed. A re-read that itself fails returns unverified: the caller reports
// the item as "not confirmed" instead of claiming either outcome.
type Applied = { ok: true; status: string } | { ok: false; message: string; unverified?: boolean };
async function applyResolution(token: string, it: LiveItem, r: Resolve): Promise<Applied> {
  let mutation: string, vars: Record<string, unknown>, payloadKey: string, readKey: string, statusField: string, want: string, wantLabel: string;
  if (it.kind === "invoice" && r.action === "bad_debt") {
    mutation = `mutation B($id:EncodedId!,$input:InvoiceCloseInput!){ invoiceClose(id:$id, input:$input){ invoice { id invoiceStatus } userErrors { message } } }`;
    vars = { id: it.gid, input: { closeOption: "BAD_DEBT" } };
    payloadKey = "invoiceClose"; readKey = "invoice"; statusField = "invoiceStatus"; want = "bad_debt"; wantLabel = "bad debt";
  } else if (it.kind === "request" && r.action === "archive") {
    mutation = `mutation R($id:EncodedId!){ requestArchive(requestId:$id){ request { id requestStatus } userErrors { message } } }`;
    vars = { id: it.gid };
    payloadKey = "requestArchive"; readKey = "request"; statusField = "requestStatus"; want = "archived"; wantLabel = "archived";
  } else {
    return { ok: false, message: "That action is not available for this item." };
  }
  const res = await gql(token, mutation, vars);
  const err = res.ok ? ue(res.data?.[payloadKey]) : null;
  const back = await gql(token, `query V($id:EncodedId!){ ${readKey}(id:$id){ id ${statusField} } }`, { id: it.gid });
  const node = back.ok ? back.data?.[readKey] : undefined;
  if (!node) {
    const what = !res.ok ? "Jobber did not answer" : err ? `Jobber refused (${err})` : "Jobber accepted it";
    return { ok: false, unverified: true, message: `${what}, and re-reading it to confirm failed, so whether it changed is not known.` };
  }
  const st = String(node[statusField] ?? "").toLowerCase();
  if (st === want) return { ok: true, status: st };
  if (!res.ok) return { ok: false, message: `Jobber did not answer, and re-reading shows "${st}".` };
  if (err) return { ok: false, message: `Jobber refused: ${err}` };
  return { ok: false, message: `Jobber accepted it, but re-reading shows "${st}", not ${wantLabel}.` };
}
