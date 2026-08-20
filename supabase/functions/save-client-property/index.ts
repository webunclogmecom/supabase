// save-client-property — create a property on an existing client, in Jobber first.
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
    headers: { "Content-Type": "application/json", "x-jobber-hmac-sha256": sig },
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
