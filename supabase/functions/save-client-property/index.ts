// save-client-property — create a property on an existing client, in Jobber first,
//                       and (2026-09-18) PREVIEW + REMOVE one, in Jobber first.
//
// 🛑 REMOVAL IS PERMANENT AND JOBBER GIVES NO WARNING. Measured on live Jobber 2026-09-18:
//    clientEdit(propertiesToDelete:[gid]) on a property that HAS a job returned userErrors [],
//    and a re-read showed BOTH the property AND the job as null. Jobber has no propertyArchive
//    and no propertyDelete (all 106 mutations introspected); propertiesToDelete on ClientEditInput
//    is the only lever, and it cascades silently. So the confirmation dialog in the Client App is
//    the ONLY guard that exists between an operator and permanent destruction of live work, and
//    `action:'preview'` exists to feed it the real blast radius.
//
// ⚠ WHY THERE IS NO 'ARCHIVE'. A local-only hide is WORSE than nothing: fn_jobber_resolve_property
//    matches only `deleted_at is null` and otherwise INSERTS, so the next Jobber touch would create a
//    DUPLICATE property row. Removal therefore has to be Jobber-first. Fred chose one-way Remove
//    (2026-09-18) over a fake 'restore' that would mint a NEW Jobber property id.
//
// WHY IT EXISTS. Fred, 2026-08-19: "when creating a property it should always, doesn't matter if
// it's at the Clients App or the Calendar App, it should always create a SC Job for that property."
// Phase 1 covered the property that arrives with a NEW client. This covers every property added to
// an EXISTING one, and it is the first code in this repo to call Jobber's propertyCreate.
//
// 🛑 JOBBER FIRST, THEN US. A property that exists only in our DB can never carry a job: jobCreate
//    needs a real Jobber propertyId, and the DB-only create path never registered one. That is the
//    whole reason the DB-only path is being closed alongside this.
//
// SHAPE, INTROSPECTED NOT ASSUMED (2026-08-20):
//    propertyCreate(clientId: EncodedId!, input: PropertyCreateInput!)
//    PropertyCreateInput { properties: [PropertyAttributes] }   <- the address is NESTED
//    A flat address was rejected at GraphQL VALIDATION once before, which was free only because a
//    validation failure creates nothing. Do not flatten it.
//
// 🛑 THE HELPERS BELOW ARE COPIED VERBATIM FROM save-client-contact/index.ts, NOT RETYPED — including
//    its content-type guard against Jobber's HTML waiting room (HTTP 200, text/html, no errors
//    array, which without the guard reads as a successful empty answer). A retyped body silently
//    drops whatever you fail to reproduce.
import { ensureServiceCallJob } from "../_shared/service-call-job.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const GQL_VERSION = "2026-04-16";

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  // ADR 016: server-to-server writes carry no browser Origin; without this the
  // audit row would land app_source='sql' instead of 'client-app'.
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

async function gql(token: string, query: string, variables: Record<string, unknown>, _retry = 0,
                   opts: { noRetry?: boolean } = {}): Promise<GqlResult> {
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
  // 🛑 A BODY THAT DOES NOT PARSE IS A MISSING ANSWER, NOT AN EMPTY ONE. The old `catch { j = {} }`
  //    turned a truncated reply into `data: undefined`, which every absence branch downstream reads
  //    as "the thing is gone".
  let j: any;
  try { j = await r.json(); }
  catch (e) {
    return { ok: false, kind: "no_answer",
      detail: `Jobber sent a ${ctype} body that did not parse: ${e instanceof Error ? e.message : e}` };
  }
  const throttled = r.status === 429 ||
    (Array.isArray(j.errors) && j.errors.some((e: any) => e?.extensions?.code === "THROTTLED" || /throttl/i.test(e?.message || "")));
  if (throttled) {
    // 🛑 NEVER AUTO-RETRY A DESTRUCTIVE MUTATION. propertiesToDelete is irreversible and `ue()` only
    //    inspects the LAST attempt, so a retry could delete on an earlier attempt and then report a
    //    later one. The caller passes noRetry for those.
    if (opts.noRetry) return { ok: false, kind: "busy", detail: "throttled (not retried: destructive)" };
    if (_retry < 5) {
      await new Promise((res) => setTimeout(res, 400 * Math.pow(2, _retry)));
      return gql(token, query, variables, _retry + 1, opts);
    }
    return { ok: false, kind: "busy", detail: "throttled after 5 retries" };
  }
  // 🛑 4xx TOO, NOT JUST 5xx. A 401 from a revoked-but-unexpired token arrives as JSON
  //    ({"error":"unauthorized"}) with NO `errors` array, so without this it reached the caller as
  //    ok:true / data:undefined, and every `?.property ? live : not_found` read it as "already gone".
  if (r.status >= 400) return { ok: false, kind: "no_answer", detail: `HTTP ${r.status}` };
  if (Array.isArray(j.errors) && j.errors.length) {
    return { ok: false, kind: "rejected", detail: j.errors.map((e: any) => e.message).join("; ").slice(0, 300) };
  }
  // 🛑 AND THE DATA KEY ITSELF. A well-formed JSON reply carrying no `data` is a MISSING ANSWER.
  //    Same rule as sync-jobber-job-drift: never hand a missing answer to an absence comparison.
  if (j == null || typeof j !== "object" || !("data" in j)) {
    return { ok: false, kind: "no_answer", detail: "Jobber replied without a data key" };
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
  const action = String(body?.action ?? "create").trim().toLowerCase();
  if (action === "preview" || action === "remove") {
    return await handlePropertyRemoval(body, action, email);
  }
  if (action !== "create") return fail("bad_request", `Unknown action '${action}'.`);

  const clientId = Number(body?.client_id);
  const street = String(body?.street ?? "").trim();
  const city = String(body?.city ?? "").trim();
  const postalCode = String(body?.postal_code ?? "").trim();
  if (!clientId || !street || !city || !postalCode) {
    return fail("bad_request", "client_id, street, city and postal_code are all required.");
  }

  // ---- resolve the client's Jobber GID, FAIL CLOSED ------------------------
  // A discarded error here would read as "not in Jobber" and refuse a client that is fine, or let us
  // proceed with an undefined id. Distinguish the two.
  const { data: link, error: linkErr } = await db
    .from("entity_source_links").select("source_id")
    .eq("entity_type", "client").eq("entity_id", clientId).eq("source_system", "jobber").maybeSingle();
  if (linkErr) return fail("lookup_failed", `Could not read the client's Jobber link: ${linkErr.message}`);
  if (!link?.source_id) {
    return fail("not_in_jobber", "This client is not linked to Jobber, so a property cannot be created there.");
  }

  let token: string;
  try { token = await getJobberToken(); }
  catch (e) { return fail("jobber_unavailable", `Could not obtain a Jobber token: ${e instanceof Error ? e.message : e}`); }

  const created = await gql(token,
    `mutation($clientId: EncodedId!, $input: PropertyCreateInput!) {
       propertyCreate(clientId: $clientId, input: $input) {
         properties { id address { street1 city postalCode } }
         userErrors { message }
       }
     }`,
    { clientId: link.source_id,
      input: { properties: [{ address: { street1: street, city, postalCode, province: "FL", country: "USA" } }] } });

  if (!created.ok) return fail("jobber_unavailable", `Jobber did not answer: ${created.detail}`);
  const uerr = ue(created.data?.propertyCreate);
  if (uerr) return fail("jobber_rejected", uerr);

  // ---- verify BY VALUE, not by cardinality --------------------------------
  // 🛑 "properties.length === 1" would pass if Jobber echoed a DIFFERENT property. Match the street
  //    we asked for, or we cannot claim the thing created is the thing we wanted.
  const node = (created.data?.propertyCreate?.properties ?? [])
    .find((p: any) => String(p?.address?.street1 ?? "").trim().toLowerCase() === street.toLowerCase());
  if (!node?.id) {
    return fail("verify_failed",
      "Jobber accepted the request but did not return the property we asked for. Check Jobber before retrying.");
  }

  // ---- materialise through handleProperty, the ONE writer -------------------
  // 🛑 CHECK THE RESULT. create-client discards its PROPERTY_CREATE replay result, which is exactly
  //    why its property leg carries no verification. That is precedent NOT to copy.
  const { data: secretRow } = await db.from("webhook_tokens")
    .select("client_secret").eq("source_system", "jobber").single();
  if (!secretRow?.client_secret) {
    return fail("verify_failed",
      "Created in Jobber but the webhook secret is missing, so we could not import it.",
      { jobber_property_gid: node.id });
  }
  const payload = JSON.stringify({
    topic: "PROPERTY_CREATE",
    webHookEvent: { itemId: node.id, occurredAt: new Date().toISOString() },
  });
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(secretRow.client_secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sigBuf = await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(payload));
  const sig = btoa(String.fromCharCode(...new Uint8Array(sigBuf)));
  const rp = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/webhook-jobber`, {
    method: "POST",
    // 🛑 x-sync-wait IS REQUIRED HERE. Since 2026-08-20 webhook-jobber acknowledges real Jobber
    //    traffic immediately and processes in the background (Jobber's 1-second SLA). Without this
    //    header the reply is {accepted:true} with NO entity_id, and the check below would report
    //    import_failed for a property that imported perfectly.
    headers: { "Content-Type": "application/json", "x-jobber-hmac-sha256": sig, "x-sync-wait": "1" },
    body: payload,
  });
  const rj = await rp.json().catch(() => ({}));
  const propertyId = Number(rj?.entity_id);
  if (!(propertyId > 0)) {
    // entity_id 0 means handleProperty DEFERRED because the owning client is not canonical here.
    // The property is real in Jobber either way, so say so rather than implying nothing happened.
    return fail("import_failed",
      "Created in Jobber but our importer did not record it. The property exists in Jobber and needs a look.",
      { jobber_property_gid: node.id, entity_id: rj?.entity_id });
  }

  // ---- the Service Call job, via the ONE definition of the rule -------------
  const job = await ensureServiceCallJob({
    db, authHeader: req.headers.get("authorization") ?? "", clientId, propertyId,
  });

  return done({
    property_id: propertyId,
    jobber_property_gid: node.id,
    job: {
      step: job.ok ? (job.created ? "created" : "existing") : "failed",
      job_id: job.ok ? job.job_id : null,
      note: job.detail,
    },
    // ONE boolean the caller can act on: a property with no Service Call job cannot be dispatched.
    schedulable: job.ok,
  });
});

// ============================================================================
// PREVIEW + REMOVE (2026-09-18)
// ============================================================================
// Contract: { action:'preview'|'remove', property_id } (+ acknowledgements[] on remove).
// The staff gate in Deno.serve has already run by the time these are reached.
//
// This block was rewritten after a four-lens adversarial review of its first draft. The findings it
// encodes are all real and were each demonstrated against the live system; the comments below name
// them so a future edit cannot quietly undo one.

type Ack = { key: string; label: string };

// 🛑 A BILLING PROPERTY'S entity_source_links.source_id IS A **CLIENT** GID WITH A `_billing` SUFFIX.
//    Measured 2026-09-18: `Z2lkOi8vSm9iYmVyL0NsaWVudC8xMzg0MjE5OTQ=_billing` decodes to
//    `gid://Jobber/Client/138421994`. Feeding that to `property(id:)` returns null, which the first
//    draft read as "already gone in Jobber" and then soft-deleted a LIVE billing address while
//    telling the operator Jobber no longer had it. Worse, anything that strips the suffix would hand
//    a CLIENT gid to propertiesToDelete. So: every gid is shape-checked before use, on the RAW bytes
//    (base64-decoding alone would discard the suffix and make the two shapes look identical).
function propertyGidOrNull(raw: unknown): string | null {
  const s = String(raw ?? "");
  if (!s || s.endsWith("_billing")) return null;
  let decoded = "";
  try { decoded = atob(s); } catch { return null; }
  return /^gid:\/\/Jobber\/Property\/\d+$/.test(decoded) ? s : null;
}

async function buildPropertyPreview(propertyId: number, token: string | null) {
  const { data: prop, error: propErr } = await db
    .from("properties")
    .select("id, client_id, name, address, city, state, zip, is_billing, is_primary, deleted_at")
    .eq("id", propertyId).maybeSingle();
  if (propErr) return { err: fail("lookup_failed", `Could not read the property: ${propErr.message}`) };
  if (!prop) return { err: fail("not_found", `Property ${propertyId} does not exist.`) };
  if (prop.deleted_at) return { err: fail("already_removed", "This property has already been removed.") };

  // A billing address is not a service address: in Jobber it is part of the CLIENT record, and
  // propertiesToDelete cannot express it. Refuse before any Jobber call rather than half-doing it.
  if (prop.is_billing === true) {
    return { err: fail("billing_row_not_removable",
      "This is the client's billing address, which lives on the client record in Jobber and cannot be removed as a property. Change it in Jobber if it is wrong.") };
  }

  const { data: client, error: cErr } = await db
    .from("clients").select("id, client_code, name, status").eq("id", prop.client_id).maybeSingle();
  if (cErr) return { err: fail("lookup_failed", `Could not read the client: ${cErr.message}`) };

  const visitIdsR = await db.from("visits").select("id").eq("property_id", propertyId).is("deleted_at", null);
  if (visitIdsR.error) return { err: fail("lookup_failed", `Could not read this property's visits: ${visitIdsR.error.message}`) };
  const visitIds = (visitIdsR.data ?? []).map((v: { id: number }) => v.id);

  const [jobsR, schedR, doneR, invR, manR, gdoR, conR, scR, sibR, linkR] = await Promise.all([
    db.from("jobs").select("id, title, job_status").eq("property_id", propertyId),
    db.from("visits").select("id", { count: "exact", head: true })
      .eq("property_id", propertyId).eq("visit_status", "scheduled").is("deleted_at", null),
    db.from("visits").select("id", { count: "exact", head: true })
      .eq("property_id", propertyId).eq("visit_status", "completed").is("deleted_at", null),
    db.from("visits").select("invoice_id").eq("property_id", propertyId).not("invoice_id", "is", null),
    visitIds.length
      ? db.from("manifest_visits").select("manifest_id").in("visit_id", visitIds)
      : Promise.resolve({ data: [] as { manifest_id: number }[], error: null }),
    db.from("gdos").select("id", { count: "exact", head: true }).eq("property_id", propertyId),
    db.from("client_contacts").select("id", { count: "exact", head: true }).eq("property_id", propertyId),
    db.from("service_configs").select("id", { count: "exact", head: true }).eq("property_id", propertyId),
    // 🛑 SIBLINGS = OTHER **SERVICE** ADDRESSES. Counting the billing duplicate (461 of them exist)
    //    suppressed the "only address" warning almost everywhere it was true. Exclude self AND billing.
    db.from("properties").select("id", { count: "exact", head: true })
      .eq("client_id", prop.client_id).neq("id", propertyId)
      .not("is_billing", "is", true).is("deleted_at", null),
    db.from("entity_source_links").select("source_id")
      .eq("entity_type", "property").eq("entity_id", propertyId).eq("source_system", "jobber").maybeSingle(),
  ]);

  // 🛑 EVERY ERROR, NOT JUST TWO. These counts drive the consent checkboxes for an irreversible
  //    delete. The first draft checked only jobsR and linkR, so a failed scheduled-visit read became
  //    `?? 0`, which DELETED the acknowledgement that consents to destroying those visits. A count we
  //    could not read must refuse, never read as zero.
  const reads: Array<[string, { error: unknown }]> = [
    ["jobs", jobsR], ["scheduled visits", schedR], ["completed visits", doneR], ["invoices", invR],
    ["DERM manifests", manR as { error: unknown }], ["GDO permits", gdoR], ["contacts", conR],
    ["service configs", scR], ["other addresses", sibR], ["the Jobber link", linkR],
  ];
  for (const [what, r] of reads) {
    const e = r.error as { message?: string } | null;
    if (e) return { err: fail("lookup_failed", `Could not read ${what}: ${e.message ?? "unknown error"}. Nothing was changed.`) };
  }

  // Every job on the property is destroyed by Jobber, whatever its status here, so the only use of a
  // status filter is to WORD the warning. The gate below uses the union with Jobber's own count.
  const TERMINAL = ["archived", "destroyed"];
  const allJobs = jobsR.data ?? [];
  const openJobs = allJobs.filter((j: { job_status: string | null }) => !TERMINAL.includes(String(j.job_status ?? "")));
  const gid = propertyGidOrNull(linkR.data?.source_id);
  const hasUnusableLink = !!linkR.data?.source_id && !gid;

  // ---- Jobber's side -------------------------------------------------------
  let jobber: "live" | "not_found" | "no_link" | "unknown" = gid ? "unknown" : "no_link";
  let jClientGid: string | null = null;
  let jCounts: { jobs: number | null; quotes: number | null; requests: number | null } =
    { jobs: null, quotes: null, requests: null };
  if (gid && token) {
    const q = await gql(token,
      `query($id: EncodedId!) { property(id: $id) { id client { id }
         jobs(first: 1) { totalCount } quotes(first: 1) { totalCount } requests(first: 1) { totalCount } } }`,
      { id: gid });
    if (q.ok) {
      // Only a WELL-FORMED answer may produce an absence verdict. gql now rejects 4xx, a missing
      // `data` key and an unparseable body, so ok:true here really is an answer.
      jobber = q.data?.property ? "live" : "not_found";
      if (q.data?.property) {
        jClientGid = q.data.property.client?.id ? String(q.data.property.client.id) : null;
        jCounts = {
          jobs: q.data.property.jobs?.totalCount ?? null,
          quotes: q.data.property.quotes?.totalCount ?? null,
          requests: q.data.property.requests?.totalCount ?? null,
        };
      }
    }
  }

  const isOnly = (sibR.count ?? 0) === 0;
  const jobsToDestroy = Math.max(openJobs.length, jCounts.jobs ?? 0);
  const acks: Ack[] = [];
  if (jobber !== "not_found") {
    acks.push({ key: "permanent",
      label: "I understand this deletes the property in Jobber permanently, and it cannot be undone there." });
  }
  if (jobsToDestroy > 0) {
    // 🛑 KEYED ON THE COUNT. A count-blind key let a dialog that showed "1 job" satisfy the re-check
    //    after the real number grew to 6, which is exactly the staleness this guard exists to catch.
    acks.push({ key: `jobs:${jobsToDestroy}`,
      label: `I understand Jobber will also destroy ${jobsToDestroy} job${jobsToDestroy === 1 ? "" : "s"} on this property` +
        (jCounts.jobs !== null && jCounts.jobs !== openJobs.length ? ` (${openJobs.length} open here, ${jCounts.jobs} in Jobber)` : "") +
        ", together with any visits still attached to them." });
  }
  if ((schedR.count ?? 0) > 0) {
    acks.push({ key: `visits:${schedR.count}`,
      label: `I understand ${schedR.count} scheduled visit${schedR.count === 1 ? "" : "s"} will disappear from the Calendar.` });
  }
  if ((jCounts.quotes ?? 0) > 0) {
    acks.push({ key: `quotes:${jCounts.quotes}`,
      label: `I understand ${jCounts.quotes} quote${jCounts.quotes === 1 ? "" : "s"} in Jobber will go with it.` });
  }
  if ((jCounts.requests ?? 0) > 0) {
    acks.push({ key: `requests:${jCounts.requests}`,
      label: `I understand ${jCounts.requests} request${jCounts.requests === 1 ? "" : "s"} in Jobber will go with it.` });
  }
  if (isOnly) {
    acks.push({ key: "only_property",
      label: "I understand this is the client's only service address, so the client will be left without one." });
  }

  return {
    preview: {
      client: { id: client?.id ?? prop.client_id, code: client?.client_code ?? null, name: client?.name ?? null },
      property: {
        id: prop.id, name: prop.name,
        address: [prop.address, prop.city, prop.state, prop.zip].filter(Boolean).join(", "),
        is_billing: false, is_primary: prop.is_primary === true,
      },
      jobber,
      jobber_property_gid: gid,
      jobber_client_gid: jClientGid,
      link_unusable: hasUnusableLink,
      destroyed_in_jobber: {
        open_jobs: openJobs.map((j: { id: number; title: string | null; job_status: string | null }) =>
          ({ id: j.id, title: j.title, status: j.job_status })),
        jobs_total: jobsToDestroy,
        jobber_job_count: jCounts.jobs,
        quotes: jCounts.quotes,
        requests: jCounts.requests,
        scheduled_visits: schedR.count ?? 0,
      },
      kept_here: {
        completed_visits: doneR.count ?? 0,
        invoices: new Set((invR.data ?? []).map((v: { invoice_id: number }) => v.invoice_id)).size,
        derm_manifests: new Set(((manR.data ?? []) as { manifest_id: number }[]).map((m) => m.manifest_id)).size,
        gdo_permits: gdoR.count ?? 0,
        contacts: conR.count ?? 0,
        service_configs: scR.count ?? 0,
      },
      is_only_property: isOnly,
      required_acknowledgements: acks,
    },
    gid,
    jClientGid,
    jCounts,
  };
}

async function handlePropertyRemoval(body: unknown, action: string, actorEmail: string): Promise<Response> {
  const b = body as Record<string, unknown> | null;
  const propertyId = Number(b?.property_id);
  if (!propertyId) return fail("bad_request", "property_id is required.");

  let token: string | null = null;
  try { token = await getJobberToken(); }
  catch (e) {
    if (action === "remove") {
      return fail("jobber_unavailable", `Could not obtain a Jobber token: ${e instanceof Error ? e.message : e}`);
    }
    token = null; // preview still renders, reporting jobber:"unknown"
  }

  const built = await buildPropertyPreview(propertyId, token);
  if ("err" in built && built.err) return built.err;
  const preview = built.preview!;
  const gid = built.gid ?? null;

  if (action === "preview") return done({ preview });

  // ---- REMOVE --------------------------------------------------------------
  const got: string[] = Array.isArray(b?.acknowledgements) ? (b!.acknowledgements as unknown[]).map(String) : [];
  const need = preview.required_acknowledgements.map((a) => a.key);
  const missing = need.filter((k) => !got.includes(k));
  if (missing.length) {
    return fail("acknowledgements_required",
      "What this removes has changed since the dialog was opened, or not every box was ticked. Read it again before continuing.",
      { missing, preview });
  }

  // 🛑 FAIL CLOSED ON ANYTHING WE COULD NOT ESTABLISH. Each of these used to proceed.
  if (preview.jobber === "unknown") {
    return fail("jobber_unavailable",
      "We could not ask Jobber about this property, so nothing was deleted. Try again shortly.", { preview });
  }
  if (preview.jobber === "no_link") {
    return fail("not_in_jobber",
      "This address has no Jobber link here, so we cannot confirm what removing it would destroy, and a local-only removal would be re-created as a duplicate on the next sync. Nothing was changed. Link or remove it in Jobber first.",
      { preview });
  }
  if (preview.link_unusable) {
    return fail("link_unusable",
      "This address's Jobber link is not a property id, so we will not issue a delete against it. Nothing was changed.",
      { preview });
  }
  if (preview.jobber === "live" &&
      (built.jCounts.jobs === null || built.jCounts.quotes === null || built.jCounts.requests === null)) {
    return fail("jobber_unavailable",
      "Jobber did not tell us how much work is attached to this address, so we will not delete it blind. Try again shortly.",
      { preview });
  }

  if (preview.jobber === "live") {
    const { data: clink, error: clinkErr } = await db.from("entity_source_links").select("source_id")
      .eq("entity_type", "client").eq("entity_id", preview.client.id).eq("source_system", "jobber").maybeSingle();
    if (clinkErr) return fail("lookup_failed", `Could not read the client's Jobber link: ${clinkErr.message}`);
    if (!clink?.source_id) {
      return fail("not_in_jobber",
        "The property is in Jobber but its client is not linked here, so we cannot issue the delete. Nothing was changed.");
    }
    // 🛑 PROVE THE TWO GIDS BELONG TOGETHER BEFORE DELETING. clientEdit takes a client id and a list
    //    of property ids; if our client link pointed at a different Jobber client than the property
    //    actually belongs to, we would be issuing a delete against someone else's record. Compare the
    //    RAW stored strings — never decoded values.
    if (!built.jClientGid || String(built.jClientGid) !== String(clink.source_id)) {
      return fail("owner_mismatch",
        "Jobber says this address belongs to a different client than the one linked here, so nothing was deleted. This needs a look before it can be removed.",
        { preview });
    }
    // 🛑 propertiesToDelete lives on ClientEditInput; Jobber has NO propertyDelete mutation.
    //    noRetry: this is irreversible and ue() only inspects the last attempt.
    const del = await gql(token!,
      `mutation($id: EncodedId!, $input: ClientEditInput!) {
         clientEdit(clientId: $id, input: $input) { client { id } userErrors { message path } } }`,
      { id: clink.source_id, input: { propertiesToDelete: [gid] } }, 0, { noRetry: true });

    // 🛑 A LOST ANSWER IS NOT "NOTHING HAPPENED". The request may well have landed. Both the
    //    no-answer and the userError paths therefore RE-READ before they report anything, because a
    //    userError is a claim about the request, not an observation of Jobber's state.
    const uerr = del.ok ? ue(del.data?.clientEdit) : null;
    const claimFailed = !del.ok || !!uerr;

    const check = await gql(token!, `query($id: EncodedId!) { property(id: $id) { id } }`, { id: gid });
    if (!check.ok) {
      return fail("verify_unknown",
        claimFailed
          ? `Jobber did not confirm the delete (${(!del.ok ? del.detail : uerr) ?? "no detail"}) and we could not re-read the property to find out what actually happened. Check Jobber before retrying - do NOT assume nothing was deleted.`
          : "Jobber accepted the delete but we could not re-read the property to confirm. Check Jobber before retrying - do not assume it failed.",
        { preview });
    }
    if (check.data?.property) {
      // The re-read is the authority: it is still there, so nothing was destroyed.
      return claimFailed
        ? fail("jobber_rejected", (!del.ok ? del.detail : uerr) ?? "Jobber refused the delete.", { preview })
        : fail("verify_failed",
            "Jobber reported no error but the property is still there. Nothing was changed on our side.", { preview });
    }
    // Gone, whatever the mutation claimed. Fall through and record it.
  }

  // ---- materialise through handlePropertyDestroy, the ONE writer ------------
  // Jobber sends its own PROPERTY_DESTROY too; that handler is idempotent (`.is('deleted_at', null)`),
  // so this replay and the real webhook cannot fight over the retirement timestamp.
  const { data: secretRow, error: secErr } = await db.from("webhook_tokens")
    .select("client_secret").eq("source_system", "jobber").single();
  if (!secErr && gid && secretRow?.client_secret) {
    const payload = JSON.stringify({
      topic: "PROPERTY_DESTROY",
      webHookEvent: { itemId: gid, occurredAt: new Date().toISOString() },
    });
    const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(secretRow.client_secret),
      { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    const sigBuf = await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(payload));
    const sig = btoa(String.fromCharCode(...new Uint8Array(sigBuf)));
    await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/webhook-jobber`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-jobber-hmac-sha256": sig, "x-sync-wait": "1" },
      body: payload,
    }).catch(() => null);
  }

  // Belt and braces: a replay that failed must not leave the row live here after Jobber deleted it.
  const { error: sdErr } = await db.from("properties")
    .update({ deleted_at: new Date().toISOString() })
    .eq("id", propertyId).is("deleted_at", null);
  if (sdErr) {
    return fail("import_failed",
      `Removed in Jobber but we could not mark it removed here: ${sdErr.message}. It needs a look.`,
      { jobber: preview.jobber });
  }

  const { data: after } = await db.from("properties").select("deleted_at").eq("id", propertyId).maybeSingle();
  // ⚠ The write runs as service_role, so audit.logs carries app_source='client-app' with no user id -
  //   the same shape as every other edge-function write here. The actor is logged explicitly so the
  //   decision is attributable even though the row is not.
  console.log(`[save-client-property] removed property ${propertyId} (${preview.property.address}) ` +
    `for ${preview.client.code} by ${actorEmail}; jobber=${preview.jobber}; acks=${need.join(",")}`);
  return done({
    removed: true,
    jobber: preview.jobber,   // live = deleted there · not_found = it was already gone
    property_id: propertyId,
    property_address: preview.property.address,
    client_code: preview.client.code,
    removed_by: actorEmail,
    deleted_at: after?.deleted_at ?? null,
    destroyed_in_jobber: preview.destroyed_in_jobber,
    kept_here: preview.kept_here,
  });
}
