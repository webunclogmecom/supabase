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
// 🛑 RETRY SAFETY IS DATA, NOT A LIST THE UI MEMORISES. Every failure carries `retry`, and the
// dialog branches on it. The previous shape forced the UI to hard-code which codes were dangerous,
// and it named only `needs_reconciliation` -- while `verify_failed` and `import_failed` are exactly
// the same danger class (Jobber HAS the client, we could not confirm or import it). A retry on
// either of those, after the user reopens the dialog and gets a fresh key, creates a SECOND real
// client that no API can delete.
//
//   safe            nothing was created; the form can resubmit freely
//   same_key_only   an attempt is live; resubmitting the SAME key is safe, a new key is not
//   never           Jobber may hold a client we did not import; a human must look first
//
// Unlisted codes default to "never" on purpose: the fail-safe answer to "I do not know" is
// "do not retry", not "go ahead".
const RETRY: Record<string, "safe" | "same_key_only" | "never"> = {
  method_not_allowed: "safe",
  unauthorized: "safe",
  bad_request: "safe",
  code_taken: "safe",
  jobber_unavailable: "safe",
  jobber_rejected: "safe",
  in_flight: "same_key_only",
  needs_reconciliation: "never",
  verify_failed: "never",
  import_failed: "never",
  already_created: "never",
};
function fail(code: string, message: string, extra: Record<string, unknown> = {}) {
  return new Response(JSON.stringify({ ok: false, code, message, retry: RETRY[code] ?? "never", ...extra }),
    { status: 200, headers: hdrs() });
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

  // 🛑 THE PROPOSAL MUST SEE IN-FLIGHT RESERVATIONS, NOT JUST COMMITTED CLIENTS.
  // Found by testing the concurrency fix rather than by reading it: two simultaneous
  // creates were correctly reduced to one winner, and then the loser's suggested
  // replacement code was THE CODE IT HAD JUST BEEN REFUSED. The winner's client did
  // not exist in public.clients yet -- it only existed as a ledger reservation --
  // so this scan could not see it and happily re-proposed the same number.
  //
  // Reading the ledger here also fixes the problem one layer earlier: two users
  // opening the form at the same moment now see 300 and 301, so the collision is
  // avoided before either of them types anything, instead of being reported at
  // submit time.
  const { data: held } = await db.from("client_create_attempts")
    .select("code_number")
    .in("status", ["started", "unknown", "created", "orphaned"])
    .not("code_number", "is", null);
  const reserved = new Set<number>((held ?? []).map((h: any) => Number(h.code_number)).filter((n: number) => n > 0));

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

  // Committed clients AND live reservations both make a number unavailable.
  const taken = new Set<number>([...parsed.map((p) => p.num), ...reserved]);
  const maxNormal = Math.max(
    0,
    ...parsed.filter((p) => p.num < RESERVED_FLOOR).map((p) => p.num),
    ...[...reserved].filter((n) => n < RESERVED_FLOOR),
  );
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

  const dryRun = body?.dry_run === true; // live is the default now; the UI must opt IN to a preview

  // ---- validate ------------------------------------------------------------
  const name = norm(body?.name);
  if (!name) return fail("bad_request", "Client name is required.", { field: "name" });
  if (name.length > 120) return fail("bad_request", "Client name is too long (120 max).", { field: "name" });
  if (CODE_ANYWHERE.test(name)) {
    return fail("bad_request",
      "Do not put the client code in the name. The code has its own field; Jobber's display name is composed from both.",
      { field: "name" });
  }
  if (JUNK_NAME(name)) {
    return fail("bad_request",
      `"${name}" matches our test/junk name filter, so our sync would create it in Jobber and then refuse to import it. ` +
      `Names starting with "test" or "NOT USE", and names of the form "X 12", are rejected here on purpose.`,
      { field: "name" });
  }

  // ---- propose_only: the form's live client-code default -------------------
  // The form needs a proposed code while the user is still typing the name, and
  // proposeCode() reuses an EXISTING brand's tag when the name matches one, which
  // needs every client_code in the table. A browser cannot do that without either
  // fetching all 443 clients or reimplementing the scheme, and a second
  // implementation is one that drifts. So the proposal stays server-side and the
  // form asks for it.
  //
  // Deliberately BEFORE the address requirement and the Jobber calls: it is a
  // suggestion, not an attempt, and it must be cheap enough to run on a debounce.
  // It creates nothing and writes no ledger row.
  if (body?.propose_only === true) {
    return done({ proposal: await proposeCode(name) });
  }

  const isCompany = body?.is_company !== false; // default: a business
  const street = norm(body?.street);
  const city = norm(body?.city);
  const postalCode = norm(body?.postal_code);
  if (!street || !city || !postalCode) {
    return fail("bad_request",
      "Street, city and ZIP are required. A client with no property cannot be given a job later: jobCreate needs a Jobber propertyId, and our own create-property path never registers one.",
      { fields: [!street ? "street" : null, !city ? "city" : null, !postalCode ? "postal_code" : null].filter(Boolean) });
  }

  const email_in = norm(body?.email);
  const phone_in = norm(body?.phone);

  // ---- client code: proposal, shape, uniqueness ----------------------------
  const proposal = await proposeCode(name);
  const supplied = norm(body?.client_code).toUpperCase();
  const code = supplied || proposal.code;
  if (!CODE_EXACT.test(code)) {
    return fail("bad_request", `Client code "${code}" is not in the NNN-XXX format (for example ${proposal.code}).`,
      { field: "client_code", next_free: proposal.code });
  }

  // DB uniqueness across ALL rows, INACTIVE included (the partial index does not defend those)
  const { data: clash } = await db.from("clients").select("id,name,status,client_code").eq("client_code", code);
  if (clash && clash.length) {
    // ONE payload shape for both collision sources. The DB branch used to return
    // `holders` and the Jobber branch `jobber_holders` under the SAME error code,
    // so a dialog reading one rendered an empty list for the other. `next_free` is
    // what makes Fred's requirement work: the user changes this one field, with a
    // single click, and keeps everything else they typed.
    return fail("code_taken", `Client code ${code} is already held by ${clash[0].name} (${clash[0].status}).`,
      { field: "client_code", next_free: proposal.code !== code ? proposal.code : null,
        holders: clash.map((c: any) => ({ source: "db", id: c.id, name: c.name, status: c.status, client_code: c.client_code })) });
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
      { field: "client_code", next_free: proposal.code !== code ? proposal.code : null,
        holders: codeHeldInJobber.map((n: any) => ({ source: "jobber", id: n.id, name: n.name, client_code: cfCode(n) })) });
  }

  // ---- duplicate name pre-check, both sides --------------------------------
  // 🛑 TWO SEARCHES, AND THE SECOND ONE IS THE POINT. `ilike '%<full name>%'` only
  // matches a client whose name CONTAINS the new name, so it catches a re-entry of
  // an existing client but is BLIND to a new location, which is the commonest real
  // near-duplicate we have. Measured 2026-08-12 with both controls: "Pura Vida Sunny
  // Isles Beach Marina" returned 0/0 and did not warn, while bare "Pura Vida"
  // returned 5/5 and "Qxzzy Vornblat Holdings" returned 0/0. So the check was alive
  // and discriminating, and still silent on the case it exists for. Found by
  // creating a client through the UI and noticing the confirmation step never came.
  //
  // The fix costs nothing new: brandKey() is already computed for the code proposal,
  // and when the proposal reports "reused existing brand", that IS a duplicate
  // signal we were throwing away.
  const brand = brandKey(name);
  const [{ data: byFull }, { data: byBrand }] = await Promise.all([
    db.from("clients").select("id,name,status,client_code").ilike("name", `%${name}%`).limit(5),
    brand ? db.from("clients").select("id,name,status,client_code").ilike("name", `${brand}%`).limit(5)
          : Promise.resolve({ data: [] as any[] }),
  ]);
  const seenDb = new Set<number>();
  const dbDupes = [...(byFull ?? []), ...(byBrand ?? [])]
    .filter((r: any) => !seenDb.has(r.id) && seenDb.add(r.id))
    .slice(0, 5);

  const nameSearch = await gql(token, Q_SEARCH, { t: name });
  if (!nameSearch.ok) return fail("jobber_unavailable", `Jobber duplicate check failed (${nameSearch.kind}): ${nameSearch.detail}`);
  // Jobber's searchTerm behaves the same way, so the brand needs its own query there
  // too. Skipped when the brand IS the name, which would just repeat the call.
  let jobberNodes = nameSearch.data?.clients?.nodes ?? [];
  if (brand && brand !== name.toLowerCase()) {
    const brandSearch = await gql(token, Q_SEARCH, { t: brand });
    if (!brandSearch.ok) return fail("jobber_unavailable", `Jobber brand duplicate check failed (${brandSearch.kind}): ${brandSearch.detail}`);
    jobberNodes = [...jobberNodes, ...(brandSearch.data?.clients?.nodes ?? [])];
  }
  const seenJb = new Set<string>();
  const jobberDupes = jobberNodes
    .filter((n: any) => !seenJb.has(n.id) && seenJb.add(n.id))
    .slice(0, 5)
    .map((n: any) => ({ id: n.id, name: n.name, code: cfCode(n) }));

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

  const duplicate_check = {
    db: dbDupes ?? [],
    jobber: jobberDupes,
    jobber_total: nameSearch.data?.clients?.totalCount ?? 0,
    // The caller decides. Jobber does not enforce name uniqueness and two
    // locations of one brand are legitimate, so this warns, it does not block.
    possible_duplicate: (dbDupes?.length ?? 0) > 0 || jobberDupes.length > 0,
  };

  // ---- non-blocking WARNINGS -----------------------------------------------
  // Fred, 2026-08-12: "remember we need warnings, required of key data, etc."
  // These do not stop the create. They are things that will be silently wrong
  // afterwards if nobody looks, which is worse than an error.
  const warnings: { field: string; message: string }[] = [];

  // 1. COUNTY. properties.county is inferred from the city by a hardcoded list in
  //    webhook-jobber (inferCountyFromCity), which returns NULL for anything not
  //    in it -- and its Broward set has six entries. Measured 2026-08-12: 18 live
  //    properties carry a NULL county from real cities (Davie, Plantation, Coral
  //    Springs, Palmetto Bay, Oakland Park...). County drives DERM routing, so a
  //    silent NULL matters.
  //    ⚠ Deliberately NOT a copy of that list. Duplicating it would drift the
  //    moment either side is edited. Instead ask the live data whether we have
  //    ever resolved a county for this city, which stays true by construction.
  //    ⚠ AND IT ASKS THE RIGHT QUESTION, WHICH TOOK TWO GOES. The first version
  //    asked "do we know this city's county?" and went quiet for Davie, because one
  //    Davie property carries a hand-set 'Broward'. But inferCountyFromCity still
  //    does not know Davie, so a NEW Davie property is still created NULL. The
  //    operative question is "does the importer RESOLVE this city?", and the
  //    observable proxy for that is whether any property in the city was left NULL.
  const { data: cityRows } = await db.from("properties").select("county").ilike("city", city);
  const known = (cityRows ?? []).map((r: any) => r.county).filter(Boolean);
  const anyNull = (cityRows ?? []).some((r: any) => !r.county);
  if (!cityRows || cityRows.length === 0) {
    warnings.push({ field: "city", message:
      `We have no property in "${city}" yet, so its county will probably be left blank. ` +
      `County drives DERM routing; set it once the client exists.` });
  } else if (anyNull) {
    warnings.push({ field: "city", message:
      `Our importer does not recognise "${city}", so this property will very likely be created with a blank county` +
      (known.length ? `. Existing records put ${city} in ${[...new Set(known)].join("/")}, so set that afterwards.` : `. Set it once the client exists.`) });
  }

  // 2. The address is sent to Jobber with province FL and country USA hardcoded.
  if (!/^\d{5}(-\d{4})?$/.test(postalCode)) {
    warnings.push({ field: "postal_code", message:
      `"${postalCode}" is not a 5-digit US ZIP. The address is filed as Florida, USA.` });
  }
  if (email_in && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email_in)) {
    warnings.push({ field: "email", message: `"${email_in}" does not look like an email address. It is sent to Jobber as typed.` });
  }

  // 3. A supplied code that reuses an existing NUMBER. Legitimate for the 000 dump
  //    band, and 247-EC/247-LOU shows it also happens by accident, so: warn, never block.
  if (supplied && Number.isFinite(Number(code.split("-")[0]))) {
    const n = Number(code.split("-")[0]);
    const { data: sameNum } = await db.from("clients")
      .select("client_code,name").like("client_code", `${String(n).padStart(3, "0")}-%`).limit(3);
    if (sameNum && sameNum.length) {
      warnings.push({ field: "client_code", message:
        `Number ${String(n).padStart(3, "0")} is already used by ${sameNum.map((c: any) => `${c.client_code} (${c.name})`).join(", ")}. ` +
        `The client code scheme treats the NUMBER as the identity, so this is usually a mistake outside the 000 dump band.` });
    }
  }

  if (dryRun) {
    return done({
      dry_run: true,
      would_send: { mutation: "clientCreate", input },
      client_code: { value: code, source: supplied ? "supplied" : "proposed", proposal },
      duplicate_check,
      warnings,
      requested_by: email,
    });
  }

  // ==========================================================================
  // LIVE ARM. Everything above this line rejects BEFORE any Jobber write, which
  // is the half-applied lesson from save-client-job: a validation failure raised
  // AFTER the mutation leaves Jobber changed and our DB not.
  // ==========================================================================

  // ---- idempotency: the ledger row goes in BEFORE the irreversible call ----
  const idem: string = typeof body?.idempotency_key === "string" && body.idempotency_key.length >= 8
    ? body.idempotency_key
    : crypto.randomUUID();

  const { data: prior } = await db.from("client_create_attempts")
    .select("status, jobber_client_gid").eq("idempotency_key", idem).maybeSingle();
  if (prior) {
    // 🛑 NEVER auto-retry an 'unknown'. Jobber has no clientDelete, so a second
    // clientCreate makes a second real client that nobody can remove.
    if (prior.status === "unknown") {
      return fail("needs_reconciliation",
        "A previous attempt with this key reached Jobber and we never saw the answer. Someone has to check Jobber before this is retried.");
    }
    if (prior.status === "created") {
      return fail("already_created", "This request was already completed.", { jobber_client_gid: prior.jobber_client_gid });
    }
    if (prior.status === "started") {
      return fail("in_flight", "An attempt with this key is already running.");
    }
    // 'failed' is the one status that is safe to retry: it means we are certain
    // no Jobber client exists.
  }

  // ==========================================================================
  // 🛑 THIS INSERT IS THE TRANSACTION FRED ASKED FOR. It is the ONLY atomic step
  // available to us, and it does three jobs at once.
  //
  // It was an UPSERT, which is not a lock: ON CONFLICT DO UPDATE resolves a
  // collision by overwriting and NEVER raises. Measured 2026-08-12 against Prod
  // -- two identical upserts both reported success, a plain INSERT raised 23505.
  // So the in_flight guard above (a plain SELECT) plus an upsert was a TOCTOU
  // window: a double-click, or any two concurrent submissions of the SAME key,
  // both saw prior=null, both "reserved", and both reached clientCreate. Two real
  // Jobber clients, one of them recorded nowhere.
  //
  // ⚠ AND THE OBVIOUS RESERVATION WOULD NOT HAVE CLOSED THE REAL RACE. The
  // measured collision is three DIFFERENT code strings sharing ONE NUMBER
  // (300-ADG / 300-BBG / 300-GGG), because the proposal is max(number)+1 from an
  // unlocked read. client_code_scheme.md says the NUMBER is the identity and the
  // tag is cosmetic, so the reservation has to be on the number as well as the
  // string. Both indexes live in 2026-08-12_1930.
  //
  // Three constraints, one statement, no window:
  //   client_create_attempts_pkey         -> the same key twice  = in_flight
  //   client_create_attempts_code_uniq    -> the same code twice = code_taken
  //   client_create_attempts_number_uniq  -> the same NUMBER     = code_taken
  // ==========================================================================
  const codeNumber = Number(code.split("-")[0]);
  const { error: reserveErr } = await db.from("client_create_attempts").insert({
    idempotency_key: idem, requested_by: email, payload: input as any, status: "started",
    client_code: code, code_number: Number.isFinite(codeNumber) ? codeNumber : null,
  });
  if (reserveErr) {
    // 23505 is the whole point of this branch: something else got here first, and
    // we have NOT called Jobber. Nothing exists, nothing to clean up, and the
    // user keeps every field they typed.
    if (reserveErr.code === "23505") {
      const which = String(reserveErr.message || "");
      if (which.includes("client_create_attempts_pkey")) {
        return fail("in_flight",
          "This exact request is already running. Wait for it to finish rather than starting another one.",
          { idempotency_key: idem });
      }
      // A concurrent attempt holds this code or this number. Re-propose so the
      // user gets a working suggestion instead of having to guess a free number.
      const fresh = await proposeCode(name);
      return fail("code_taken",
        `Someone else is creating a client with code ${code} right now. Pick a different code; ${fresh.code} is free.`,
        { field: "client_code", next_free: fresh.code, holders: [], concurrent: true });
    }
    return fail("jobber_unavailable", `Could not reserve the client code: ${reserveErr.message}`);
  }

  // ---- the irreversible call ----------------------------------------------
  const M_CREATE = `mutation($input: ClientCreateInput!) {
    clientCreate(input: $input) { client { id name companyName } userErrors { message path } } }`;
  const created = await gql(token, M_CREATE, { input });

  if (!created.ok) {
    // "rejected" is a GraphQL error array: the query never executed, so nothing
    // was created and this is safely retryable. Anything else means we do not know.
    const certain = created.kind === "rejected";
    await db.from("client_create_attempts").update({
      status: certain ? "failed" : "unknown", failure_reason: `${created.kind}: ${created.detail}`.slice(0, 300),
    }).eq("idempotency_key", idem);
    return certain
      ? fail("jobber_rejected", `Jobber rejected the request and created nothing: ${created.detail}`)
      : fail("needs_reconciliation",
          `We could not confirm whether Jobber created this client (${created.kind}). Do not retry; check Jobber first.`,
          { idempotency_key: idem });
  }

  const ueMsg = (created.data?.clientCreate?.userErrors ?? []).map((e: any) => e.message).join("; ");
  if (ueMsg) {
    await db.from("client_create_attempts").update({ status: "failed", failure_reason: ueMsg.slice(0, 300) }).eq("idempotency_key", idem);
    return fail("jobber_rejected", ueMsg);
  }

  const gid: string = created.data.clientCreate.client.id;
  // 🛑 RECORD THE GID, DO NOT CLAIM SUCCESS YET. This line used to set
  // status='created' right here, BEFORE the re-read verify and BEFORE the import.
  // Both of those failure paths then returned without touching the ledger, so an
  // attempt whose client exists in Jobber but never reached our DB was filed as
  // 'created' -- which 2026-08-11_1900's header defines as "Jobber confirmed on
  // re-read AND webhook-jobber returned a positive entity_id", i.e. exactly the
  // two things that had not happened. The documented reconcile query over
  // status='unknown' therefore returned nothing and the orphan was invisible.
  await db.from("client_create_attempts").update({ jobber_client_gid: gid }).eq("idempotency_key", idem);

  // ---- re-read and verify BY VALUE, not by cardinality ---------------------
  const Q_VERIFY = `query($id: EncodedId!) { client(id: $id) {
    id name companyName isCompany
    customFields { __typename ... on CustomFieldText { label valueText } }
    clientProperties(first: 5) { nodes { id } } } }`;
  const back = await gql(token, Q_VERIFY, { id: gid });
  const verified = back.ok ? back.data?.client : null;
  const propGid: string | null = verified?.clientProperties?.nodes?.[0]?.id ?? null;
  if (!verified || cfCode(verified) !== code) {
    // The client EXISTS. Do not archive as compensation, and do not retry.
    // Mark it so v_client_create_attention surfaces it; the reservation stays
    // held, which is correct, because Jobber really does hold this code.
    await db.from("client_create_attempts")
      .update({ status: "orphaned", failure_reason: "created in Jobber but did not read back as expected" })
      .eq("idempotency_key", idem);
    return fail("verify_failed",
      "The client was created in Jobber but did not read back as expected. It exists; someone should look at it before anything else is done.",
      { jobber_client_gid: gid, idempotency_key: idem });
  }

  // ---- materialise through OUR OWN handler, CLIENT then PROPERTY ------------
  // handleProperty defers with entity_id 0 when the owning client is not canonical
  // yet, so this order is load-bearing rather than stylistic.
  const { data: secretRow } = await db.from("webhook_tokens").select("client_secret").eq("source_system", "jobber").single();
  if (!secretRow?.client_secret) {
    return fail("verify_failed", "Created in Jobber but the webhook secret is missing, so we could not import it.",
      { jobber_client_gid: gid, idempotency_key: idem });
  }
  const replay = async (topic: string, itemId: string) => {
    const payload = JSON.stringify({ topic, webHookEvent: { itemId, occurredAt: new Date().toISOString() } });
    const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(secretRow.client_secret),
      { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    const sigBuf = await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(payload));
    const sig = btoa(String.fromCharCode(...new Uint8Array(sigBuf)));
    const r = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/webhook-jobber`, {
      method: "POST", headers: { "Content-Type": "application/json", "x-jobber-hmac-sha256": sig }, body: payload });
    try { return await r.json(); } catch { return {}; }
  };

  const rc = await replay("CLIENT_UPDATE", gid);
  const clientId = Number(rc?.entity_id);
  if (!(clientId > 0)) {
    // entity_id -1 means webhook-jobber's junk-name filter fired. We reject those
    // names before the mutation, so this should be unreachable.
    await db.from("client_create_attempts")
      .update({ status: "orphaned", failure_reason: `webhook-jobber returned entity_id ${rc?.entity_id}` })
      .eq("idempotency_key", idem);
    return fail("import_failed",
      "Created in Jobber but our importer did not accept it. The client exists in Jobber and needs a look.",
      { jobber_client_gid: gid, entity_id: rc?.entity_id, idempotency_key: idem });
  }
  if (propGid) await replay("PROPERTY_CREATE", propGid);

  // ---- repair the primary property (see 2026-08-11_2030) -------------------
  // Jobber back-fills billingAddress from properties[0] regardless of what we
  // send, so the billing row is created first and takes primary, leaving the
  // real, job-capable property non-primary. CLIENT-before-PROPERTY is required,
  // so this cannot be fixed by reordering.
  await db.rpc("fn_fix_billing_primary_property", { p_client_id: clientId });

  // ---- report what LANDED, not what we intended ----------------------------
  // 🛑 THIS RETURNED `client_code: code` -- the value we ASKED for, never re-read.
  // handleClient (webhook-jobber:426) deliberately DROPS the code and imports the
  // client anyway when a non-INACTIVE client already holds it, logging a
  // client_insert_potential_dup warning. So the row can legitimately land with
  // client_code = NULL while this function cheerfully reported success with a
  // code. That is not hypothetical: it happened on 2026-08-12 at 11:50 ET during
  // development (webhook_events_log holds the warning) and the user-facing answer
  // still said the code was assigned. A success message that asserts something
  // untrue is worse than an error.
  const { data: landedRow } = await db.from("clients").select("client_code").eq("id", clientId).maybeSingle();
  const landedCode: string | null = landedRow?.client_code ?? null;

  await db.from("client_create_attempts").update({
    status: "created", jobber_property_gid: propGid, client_id: clientId,
  }).eq("idempotency_key", idem);

  return done({
    client_id: clientId,
    client_code: landedCode,
    client_code_requested: code,
    // The caller must be told when these differ. The client is real and usable,
    // but it has no code, and somebody has to assign one.
    code_assigned: landedCode === code,
    code_warning: landedCode === code ? null
      : `The client was created, but the code ${code} could not be assigned because another client already holds it. This client currently has ${landedCode ? `code ${landedCode}` : "NO client code"} and needs one set manually.`,
    jobber_client_gid: gid,
    duplicate_check,
    idempotency_key: idem,
  });
});
