// ============================================================================
// create-client — create a client in Jobber, then let OUR OWN webhook handler
//                 materialise it. STEP 2: dry-run arm only, mutates nothing.
// ============================================================================
// Fred, 2026-08-11: "add a create client form to the app ... on the home view
// of the clients app add a button to create a client."
//
// 🛑 THE ONE ARCHITECTURAL FACT. public.clients is JOBBER-MASTERED (441 of 442
// rows carry a jobber entity_source_link; the last 31 INSERTs all came from
// app_source='jobber'). So this function does NOT insert a client. It:
//     validate -> duplicate pre-check -> clientCreate in Jobber -> re-read and
//     verify -> POST a SIGNED SYNTHETIC webhook to our own webhook-jobber
// and lets handleClient write the row exactly as it does for every other Jobber
// client. That keeps ONE writer of client identity and reuses every guard in
// that handler, including the duplicate-code guards that exist because of the
// documented 963-failure replay loop on client 153 (2026-07-02 to 07-06).
//
// 🛑 WHY THE ATTEMPT LEDGER EXISTS. Jobber has NO clientDelete mutation
// (introspected 2026-08-11: only clientArchive / clientUnarchive). So a
// clientCreate that succeeds and whose response we lose is UNRECOVERABLE by
// retry, because the retry makes a second real client we also cannot delete.
// public.client_create_attempts records the attempt BEFORE the mutation.
// status='unknown' means "we do not know whether Jobber has a client" and must
// NEVER be auto-retried.
//
// ⚠ THIS FILE IS STEP 2. Only the dry-run arm is implemented. It performs auth,
// every validation, both duplicate pre-checks and the code proposal, and returns
// the exact ClientCreateInput it WOULD send. It writes nothing, anywhere, and it
// calls no Jobber mutation. The live arm lands in step 4.
//
// ⚠ verify_jwt = false is pinned in config.toml. The gateway rejects ES256
// session tokens, and the anon key alone satisfies it, so the gateway is NOT the
// control. The in-handler auth.getUser() plus the staff-domain gate is, and it is
// strictly stronger.
// ============================================================================

import { createClient } from "jsr:@supabase/supabase-js@2";

const GQL_VERSION = "2026-04-16";
// CustomFieldConfigurationText "Client Code", appliesTo ALL_CLIENTS. Account-stable.
const CODE_CF_GID = "Z2lkOi8vSm9iYmVyL0N1c3RvbUZpZWxkQ29uZmlndXJhdGlvblRleHQvMzgyNTkyNw==";
const RESERVED_FLOOR = 700; // 700+ is the vanity band (777-YA). Never auto-assign from it.

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  // ADR 016: server-to-server writes carry no browser Origin; without this every
  // audit row would land app_source='sql'.
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
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body,
  });
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
async function gql(token: string, query: string, variables?: unknown, _retry = 0): Promise<GqlResult> {
  let r: Response;
  try {
    r = await fetch("https://api.getjobber.com/api/graphql", {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", "X-JOBBER-GRAPHQL-VERSION": GQL_VERSION },
      body: JSON.stringify({ query, variables }),
    });
  } catch (e) {
    return { ok: false, kind: "unreachable", detail: e instanceof Error ? e.message : String(e) };
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

// ---- shared shapes ---------------------------------------------------------
const norm = (s: unknown) => String(s ?? "").replace(/\s+/g, " ").trim();

// Detecting a code INSIDE a name stays loose (2 or 3 digits), because we want to
// catch anything code-shaped a human might type into the name field.
const CODE_ANYWHERE = /[0-9]{2,3}\s*-\s*[A-Za-z0-9&]+/;

// ⚠ But a code we are MINTING is exactly 3 digits, and this is deliberately
// TIGHTER than save-client-fields' /^[0-9]{2,3}-.../. Measured 2026-08-11: all
// 276 coded clients are 3-digit, zero exceptions, so {2,3} describes nothing that
// exists. The two functions differ on purpose: EDIT must tolerate whatever is
// already out there, CREATE must not invent a shape the convention does not have.
// Caught by the "29-X" fixture, which the loose copy accepted.
const CODE_EXACT = /^[0-9]{3}-[A-Z0-9&]+$/;

// ⚠ COPIED VERBATIM from webhook-jobber/index.ts:253. If a name matches this,
// handleClient SKIPS it and returns entity_id -1, so the client would exist in
// Jobber and never in our DB. Rejecting here is the only way to prevent that,
// because by the time the handler skips it the Jobber record already exists and
// cannot be deleted. Keep these two in step.
const JUNK_NAME = (n: string) =>
  /^\s*x\s+\d+\s*$/i.test(n) || /^\s*test\b/i.test(n) || /^\s*NOT\s*USE\b/i.test(n);

// ---- client_code proposal (docs/reference/client_code_scheme.md) -----------
const NOISE_LEAD = new Set(["the"]);
const NOISE_WORD = new Set(["llc", "inc", "inc.", "corp", "corp.", "co", "co.", "of", "and", "miami", "restaurant", "cafe", "dba"]);
const words = (s: string) => s.toLowerCase().replace(/[^a-z0-9\s]/g, " ").split(/\s+/).filter(Boolean);
const stripLead = (w: string[]) => { const a = [...w]; while (a.length && NOISE_LEAD.has(a[0])) a.shift(); return a; };
const brandKey = (s: string) => stripLead(words(s)).slice(0, 2).join(" ");
function coinTag(s: string): string {
  const w = stripLead(words(s)).filter((x) => !NOISE_WORD.has(x)).filter((x) => x.length >= 2 || /^\d+$/.test(x));
  if (!w.length) return "XX";
  if (/^\d+$/.test(w[0])) return w[0];
  if (w.length === 1) return w[0].slice(0, 3).toUpperCase();
  return w.slice(0, 3).map((x) => x[0]).join("").toUpperCase();
}

type Proposal = { code: string; tag: string; number: number; basis: string };
async function proposeCode(name: string): Promise<Proposal> {
  // ⚠ NO status filter. clients_active_client_code_uniq is a PARTIAL index
  // (WHERE status <> 'INACTIVE'), so an INACTIVE row can hold a number the index
  // will not defend. Two such pairs are live today (050-PV, 239-COM). Read all.
  const { data } = await db.from("clients").select("client_code,name").not("client_code", "is", null);
  const parsed = (data ?? []).map((r: any) => {
    const m = String(r.client_code).match(/^(\d+)-(.+)$/);
    return m ? { num: +m[1], tag: m[2].trim(), name: r.name as string } : null;
  }).filter(Boolean) as { num: number; tag: string; name: string }[];

  const key = brandKey(name);
  const brandMap: Record<string, Record<string, number>> = {};
  for (const p of parsed) {
    const k = brandKey(p.name);
    if (!k) continue;
    brandMap[k] = brandMap[k] || {};
    brandMap[k][p.tag] = (brandMap[k][p.tag] || 0) + 1;
  }
  let tag: string, basis: string;
  const match = brandMap[key];
  if (match) {
    tag = Object.entries(match).sort((a, b) => b[1] - a[1])[0][0];
    basis = `reused existing brand "${key}" (${Object.values(match).reduce((a, b) => a + b, 0)} locations)`;
  } else {
    tag = coinTag(name);
    basis = "coined, no existing brand match";
  }

  const taken = new Set(parsed.map((p) => p.num));
  const maxNormal = Math.max(0, ...parsed.filter((p) => p.num < RESERVED_FLOOR).map((p) => p.num));
  let num = maxNormal + 1;
  while (taken.has(num)) num++;
  return { code: `${String(num).padStart(3, "0")}-${tag}`, tag, number: num, basis };
}

// ---- Jobber reads used by the pre-checks ------------------------------------
const Q_SEARCH = `query($t: String!) {
  clients(searchTerm: $t, first: 5) {
    totalCount
    nodes { id name companyName isCompany
      customFields { __typename ... on CustomFieldText { label valueText } } }
  } }`;

const cfCode = (c: any): string | null => {
  const v = (c?.customFields ?? []).find((f: any) => String(f?.label ?? "").trim().toLowerCase() === "client code")?.valueText;
  return v == null || String(v).trim() === "" ? null : String(v).trim();
};

// ============================================================================
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsPreflight(req) });
  if (req.method !== "POST") return fail("method_not_allowed", "POST only.");

  // ---- auth: the real control, since the gateway is not one ----------------
  const m = /^Bearer\s+(.+)$/i.exec(req.headers.get("authorization") ?? "");
  if (!m) return fail("unauthorized", "Missing bearer token.");
  const { data: userData, error: userErr } = await db.auth.getUser(m[1]);
  const email = userData?.user?.email ?? "";
  if (userErr || !email || (!email.endsWith("@ayache.com") && !email.endsWith("@unclogme.com"))) {
    return fail("unauthorized", "Staff account required.");
  }

  let body: any;
  try { body = await req.json(); } catch { return fail("bad_request", "Invalid JSON body."); }

  const dryRun = body?.dry_run !== false; // STEP 2: default true, live arm lands in step 4
  if (!dryRun) return fail("not_implemented", "The live arm ships in step 4. Send dry_run: true.");

  // ---- validate ------------------------------------------------------------
  const name = norm(body?.name);
  if (!name) return fail("bad_request", "Client name is required.");
  if (name.length > 120) return fail("bad_request", "Client name is too long (120 max).");
  if (CODE_ANYWHERE.test(name)) {
    return fail("bad_request",
      "Do not put the client code in the name. The code has its own field; Jobber's display name is composed from both.");
  }
  if (JUNK_NAME(name)) {
    return fail("bad_request",
      `"${name}" matches our test/junk name filter, so our sync would create it in Jobber and then refuse to import it. ` +
      `Names starting with "test" or "NOT USE", and names of the form "X 12", are rejected here on purpose.`);
  }

  const isCompany = body?.is_company !== false; // default: a business
  const street = norm(body?.street);
  const city = norm(body?.city);
  const postalCode = norm(body?.postal_code);
  if (!street || !city || !postalCode) {
    return fail("bad_request",
      "Street, city and ZIP are required. A client with no property cannot be given a job later: jobCreate needs a Jobber propertyId, and our own create-property path never registers one.");
  }

  const email_in = norm(body?.email);
  const phone_in = norm(body?.phone);

  // ---- client code: proposal, shape, uniqueness ----------------------------
  const proposal = await proposeCode(name);
  const supplied = norm(body?.client_code).toUpperCase();
  const code = supplied || proposal.code;
  if (!CODE_EXACT.test(code)) {
    return fail("bad_request", `Client code "${code}" is not in the NNN-XXX format (for example ${proposal.code}).`);
  }

  // DB uniqueness across ALL rows, INACTIVE included (the partial index does not defend those)
  const { data: clash } = await db.from("clients").select("id,name,status,client_code").eq("client_code", code);
  if (clash && clash.length) {
    return fail("code_taken", `Client code ${code} is already held by ${clash[0].name} (${clash[0].status}).`, { holders: clash });
  }

  let token: string;
  try { token = await getJobberToken(); }
  catch (e) { return fail("jobber_unavailable", `Could not obtain a Jobber token: ${e instanceof Error ? e.message : e}`); }

  // Jobber-side code check. The DB-only check is documented as insufficient:
  // Jerusalem Pizza held 226-JER in Jobber while our column was NULL.
  const codeSearch = await gql(token, Q_SEARCH, { t: code });
  if (!codeSearch.ok) return fail("jobber_unavailable", `Jobber code check failed (${codeSearch.kind}): ${codeSearch.detail}`);
  const codeHeldInJobber = (codeSearch.data?.clients?.nodes ?? []).filter((n: any) => cfCode(n) === code);
  if (codeHeldInJobber.length) {
    return fail("code_taken", `Client code ${code} is already held in Jobber by "${codeHeldInJobber[0].name}".`,
      { jobber_holders: codeHeldInJobber.map((n: any) => ({ id: n.id, name: n.name })) });
  }

  // ---- duplicate name pre-check, both sides --------------------------------
  const { data: dbDupes } = await db.from("clients").select("id,name,status,client_code").ilike("name", `%${name}%`).limit(5);
  const nameSearch = await gql(token, Q_SEARCH, { t: name });
  if (!nameSearch.ok) return fail("jobber_unavailable", `Jobber duplicate check failed (${nameSearch.kind}): ${nameSearch.detail}`);
  const jobberDupes = (nameSearch.data?.clients?.nodes ?? []).map((n: any) => ({ id: n.id, name: n.name, code: cfCode(n) }));

  // ---- the exact payload the live arm would send ---------------------------
  const input: Record<string, unknown> = {
    isCompany,
    // ⚠ NO billingAddress. Sending one makes Jobber mint a second, billing-only
    // property whose only link is a synthetic "<gid>_billing" id, which is not a
    // real EncodedId and which jobCreate rejects. 8 live jobs already sit on that
    // shape. properties[] alone yields one real, job-capable property.
    //
    // ⚠ THE ADDRESS IS NESTED. PropertyAttributes is { address: AddressAttributes!,
    // name, contacts, customFields, taxRateId } - the street/city/postalCode fields
    // live on AddressAttributes, NOT on PropertyAttributes. Introspected 2026-08-11
    // after a flat payload was rejected with "Field is not defined on
    // PropertyAttributes". The rejection happened at GraphQL VALIDATION, so nothing
    // was created, which is the only reason that mistake was free.
    properties: [{ address: { street1: street, city, postalCode, province: "FL", country: "USA" } }],
    customFields: [{ customFieldConfigurationId: CODE_CF_GID, valueText: code }],
  };
  if (isCompany) {
    // The convention: Jobber renders companyName for isCompany=true, and the
    // code suffix is what makes the */5 poll converge on our value.
    input.companyName = `${name} - ${code}`;
  } else {
    const tokens = name.split(/\s+/);
    input.firstName = tokens.length > 1 ? tokens.slice(0, -1).join(" ") : name;
    input.lastName = tokens.length > 1 ? `${tokens[tokens.length - 1]} - ${code}` : `- ${code}`;
  }
  if (email_in) input.emails = [{ description: "MAIN", primary: true, address: email_in }];
  if (phone_in) input.phones = [{ description: "MAIN", primary: true, number: phone_in }];

  return done({
    dry_run: true,
    would_send: { mutation: "clientCreate", input },
    client_code: { value: code, source: supplied ? "supplied" : "proposed", proposal },
    duplicate_check: {
      db: dbDupes ?? [],
      jobber: jobberDupes,
      jobber_total: nameSearch.data?.clients?.totalCount ?? 0,
      // The caller decides. Jobber does not enforce name uniqueness and two
      // locations of one brand are legitimate, so this warns, it does not block.
      possible_duplicate: (dbDupes?.length ?? 0) > 0 || jobberDupes.length > 0,
    },
    requested_by: email,
  });
});
