// ============================================================================
// save-client-job — VERIFIED two-way job saga for the Client App (2026-07-30)
// ============================================================================
// Fred: "when creating the job, it has to be a two-way flow with Jobber, where if
// we edit it, create, or delete it has to have the same functionality with Jobber
// … every time we change this … we need to wait until that's reflected on Jobber."
//
// Design doc (the architecture decision + all measured Jobber facts):
//   docs/jobber-calendar-job-migration/2026-07-30_client-app-job-two-way-sync-design.md
//
// ORDER, same spine as save-calendar-visit: validate everything → mutate Jobber →
// RE-READ Jobber and verify → only then write our DB (fn_record_client_job, one
// transaction). Failure before the DB write leaves our side untouched and the
// dialog dirty. The app AWAITS this function — that await IS the loading toaster.
//
// ⚠ FACTS THIS FILE ENCODES (measured 2026-07-30, do not "simplify"):
// - There is NO jobDelete in Jobber. action='close' uses jobClose with
//   modifyIncompleteVisitsBy: DESTROY_ALL (required field, no default), which
//   destroys Jobber's incomplete visits and leaves the closed job forever.
// - jobCreate takes propertyId (EncodedId), NOT clientId — the client is implied.
// - invoicing{invoicingType, invoicingSchedule} is REQUIRED on create.
// - We NEVER send `scheduling`: our own daily generator mints SA visits; a
//   Jobber-side RRULE would double-generate. Jobs are born UNSCHEDULED in Jobber.
// - frequency lives in the "Frequency" NUMERIC custom field (config GID below).
// - Line items: name format `<code> - <title>` is load-bearing for the taxonomy
//   join; saveToProductsAndServices MUST be false (true pollutes the catalog).
// - SA titles start 'Service Agreement'; SC title is exactly 'Service Call'
//   (ops.client_service_options matches lower(btrim(title))='service call').
//   Title is a behaviour class — this fn derives it and never accepts free text.
// - Mutations return HTTP 200 with userErrors; success = no userErrors AND
//   payload.job != null AND the re-read matches. timeframe.startAt goes in as a
//   DATE; Job.startAt reads back as UTC DateTime — compare as ET dates.
// - The WRITE app's mutations never echo through webhooks, and the */5 poll
//   cursors jobs on createdAt — so this fn records the DB row + ESL link itself,
//   atomically. Our own fresh creates DO get replayed by the next poll (createdAt
//   > cursor); the ESL row routes that to a harmless same-values UPDATE.
// ============================================================================

import { createClient } from "jsr:@supabase/supabase-js@2";

const GQL_VERSION = "2026-04-16";
// CustomFieldConfigurationNumeric "Frequency", appliesTo ALL_JOBS (gid …/3743514).
// Account-stable; verified live 2026-07-30. If Jobber ever recreates the field the
// create/edit paths fail loudly with a userError naming the config — not silently.
const FREQ_CF_GID = "Z2lkOi8vSm9iYmVyL0N1c3RvbUZpZWxkQ29uZmlndXJhdGlvbk51bWVyaWMvMzc0MzUxNA==";

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  // ADR 016: server-to-server writes carry no browser Origin; without this header
  // every audit row would land app_source='sql'.
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

// userErrors → readable string, or null when clean
function ue(payload: any): string | null {
  const errs = payload?.userErrors;
  if (Array.isArray(errs) && errs.length) {
    return errs.map((e: any) => e.message).join("; ").slice(0, 300);
  }
  return null;
}

const etDate = (iso: string | null | undefined): string | null =>
  iso ? new Date(iso).toLocaleDateString("en-CA", { timeZone: "America/New_York" }) : null;

// SA title from the FULL service combination (Fred, 2026-07-30: "make it dynamic
// which changes depending on the combination of the Line Items"). Rule, shared
// verbatim with the UI preview — change both or neither:
//   per line name: strip the leading "NN - " code, strip a leading
//   "Service Agreement - " if present; join the parts with " & ";
//   title = "Service Agreement - " + joined.
// Lines arrive code-sorted from resolveServices, so the title is deterministic
// regardless of click order. Single-service titles are unchanged from before.
function saTitle(lineNames: string[]): string {
  const parts = lineNames.map((n) =>
    n.replace(/^\d+\s*-\s*/, "").replace(/^Service Agreement\s*-\s*/i, "").trim());
  return `Service Agreement - ${parts.join(" & ")}`;
}

// Billing -> Jobber `invoicing`, in ONE place. It used to live inline in the
// create branch only, which is exactly why editing billing was a silent no-op:
// the edit branch never read billing_type / invoice_frequency at all, so a
// billing-only patch fell through to the `no_changes` early return and reported
// success while changing nothing (Fred, 2026-08-01).
// Returns the enum pair alongside the Jobber block so the caller can persist
// what was actually confirmed.
type Billing = {
  err?: string;
  invoicing?: Record<string, unknown>;
  billing_type?: string;
  invoice_frequency?: string;
  invoice_rrule?: string | null;
};
function resolveBilling(p: any, isSA: boolean, opts: { legacy: boolean }): Billing {
  // Back-compat: the pre-widening key `billing` ('per_visit'|'fixed') still maps
  // to the old two combinations, so an in-flight old bundle cannot break.
  const btype: string | null =
    p.billing_type === "visit_based" || p.billing_type === "fixed" ? p.billing_type
    : opts.legacy && p.billing === "per_visit" ? "visit_based"
    : opts.legacy && p.billing === "fixed" ? "fixed" : null;
  const bfreq: string | null =
    ["per_visit", "monthly_last_day", "once_closed", "as_needed", "custom"].includes(p.invoice_frequency)
      ? p.invoice_frequency
      : opts.legacy && p.billing === "per_visit" ? "per_visit"
      : opts.legacy && p.billing === "fixed" ? "once_closed" : null;
  if (!btype || !bfreq) {
    return { err: "Billing is required: choose a billing type and an invoice frequency." };
  }
  if (!isSA && btype === "fixed") {
    // A Service Call container carries NO job line items (the SA-has-lines rule),
    // and fixed-price invoices bill from job lines — a fixed-price SC would
    // invoice $0 forever.
    return { err: "A Service Call bills per visit — fixed price needs job-level line items, which Service Calls don't carry." };
  }
  // ⚠ JOBBER'S OWN RULE, learned the hard way 2026-08-01: PER_VISIT and
  // FIXED_PRICE are mutually exclusive. Sending the pair returns
  //   "If invoicing schedule is PER_VISIT invoicing type should be VISIT_BASE."
  //   "If invoicing type is FIXED_PRICE invoicing schedule can not be PER_VISIT"
  // Caught here so the user gets a sentence they can act on instead of two
  // raw Jobber userErrors — and so the invalid pair never reaches the API.
  if (btype === "fixed" && bfreq === "per_visit") {
    return { err: "Fixed price cannot invoice per visit — a fixed-price job bills a set amount on a schedule. Pick a different invoice frequency (for example on the last day of the month), or keep the billing type as Visit based." };
  }
  let rrule: string | null = null;
  if (bfreq === "custom") {
    rrule = String(p.invoice_rrule ?? "").trim();
    // Jobber's schema: "Must be prefixed with 'RRULE:'". Shape-validate so a
    // malformed rule fails here readably instead of as an opaque userError.
    if (!/^RRULE:FREQ=(DAILY|WEEKLY|MONTHLY|YEARLY)(;[A-Z]+=[A-Za-z0-9,+-]+)*$/.test(rrule)) {
      return { err: "The custom invoice schedule is invalid — it must be an RRULE like RRULE:FREQ=MONTHLY;INTERVAL=2." };
    }
  } else if (bfreq === "monthly_last_day") {
    rrule = "RRULE:FREQ=MONTHLY;BYMONTHDAY=-1";
  }
  const invoicing: Record<string, unknown> = {
    invoicingType: btype === "fixed" ? "FIXED_PRICE" : "VISIT_BASED",
    invoicingSchedule:
      bfreq === "per_visit" ? "PER_VISIT"
      : bfreq === "once_closed" ? "ON_COMPLETION"
      : bfreq === "as_needed" ? "NEVER"
      : "PERIODIC",
  };
  if (rrule) invoicing.recurrence = rrule;
  return { invoicing, billing_type: btype, invoice_frequency: bfreq, invoice_rrule: rrule };
}

// ---- RRULE read-back verification ------------------------------------------
// 🛑 CORRECTION, measured 2026-08-03. An earlier version of this file asserted that
// "Jobber exposes NO RRULE field on Job.invoiceSchedule" and therefore matched English
// tokens against the rendered `scheduleSummary`. THAT WAS WRONG, and it made the verify
// weaker than it needed to be while also leaving weekly / yearly / nth-weekday
// unverifiable (their wording had never been measured, so the token matcher had to
// return [] and assert nothing).
//
// `InvoiceSchedule.recurrenceSchedule.calendarRule` returns the rule VERBATIM.
// Introspected + read live, read-only, GQL 2026-04-16:
//   job 1202      FREQ=MONTHLY;BYMONTHDAY=-1
//   job 10000308  FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=22
//   job 10000414  recurrenceSchedule ABSENT (PER_VISIT)   <- negative control fired
// So the schedule is verifiable EXACTLY, for every shape, and no phrasing is guessed.
//
// Two normalizations are load-bearing, not cosmetic:
//   1. Jobber returns the rule WITHOUT the "RRULE:" prefix; we store it WITH one
//      (its own schema demands the prefix on write, and the DB CHECK requires it).
//   2. INTERVAL=1 is the RFC 5545 default and Jobber omits it on read-back. Without
//      collapsing it, every "Monthly on the 10th" save we send as INTERVAL=1 would
//      fail verification against a stored rule that simply left it out.
// List-valued parts (BYDAY, BYMONTHDAY) are compared as SETS — "MO,WE" and "WE,MO"
// are the same rule, and asserting on order would invent failures.
function parseRrule(s: string): Record<string, string> | null {
  const body = String(s ?? "").trim().replace(/^RRULE:/i, "");
  if (!body) return null;
  const out: Record<string, string> = {};
  for (const part of body.split(";")) {
    const i = part.indexOf("=");
    if (i < 1) continue;
    const k = part.slice(0, i).toUpperCase();
    let v = part.slice(i + 1).toUpperCase();
    if (v.includes(",")) v = v.split(",").map((x) => x.trim()).sort().join(",");
    out[k] = v;
  }
  if (out.INTERVAL === "1") delete out.INTERVAL;
  return out;
}
// null  => Jobber stored a rule that MEANS what we sent.
// string => a sentence naming the exact difference, for the verify_failed message.
function rruleMismatch(sent: string | null | undefined, got: string | null | undefined): string | null {
  const a = parseRrule(sent ?? "");
  if (!a) return null;                       // we sent no rule; nothing to assert
  const b = parseRrule(got ?? "");
  if (!b) return "Jobber stored no recurrence rule at all";
  const keys = [...new Set([...Object.keys(a), ...Object.keys(b)])].sort();
  const diffs = keys.filter((k) => a[k] !== b[k])
    .map((k) => `${k}: sent ${a[k] ?? "(none)"}, stored ${b[k] ?? "(none)"}`);
  return diffs.length ? diffs.join("; ") : null;
}
// The rule Jobber actually holds, re-prefixed for storage. This is what gets
// persisted — NOT the rule from the request — so invoice_rrule means "last confirmed
// by us" in the same sense billing_type already did.
function confirmedRrule(j: any): string | null {
  const cr = j?.invoiceSchedule?.recurrenceSchedule?.calendarRule;
  const body = String(cr ?? "").trim();
  if (!body) return null;
  return body.toUpperCase().startsWith("RRULE:") ? body : `RRULE:${body}`;
}

// ---- Jobber queries/mutations ----------------------------------------------
const JOB_FIELDS = `id jobNumber title instructions jobStatus startAt endAt total
  billingType invoiceSchedule { billingFrequency scheduleSummary
    recurrenceSchedule { calendarRule } }
  client { id } property { id }
  lineItems(first: 100) { nodes { id name quantity unitPrice totalPrice } }`;
const Q_JOB = `query($id: EncodedId!) { job(id: $id) { ${JOB_FIELDS} } }`;
const M_CREATE = `mutation($input: JobCreateAttributes!) {
  jobCreate(input: $input) { job { ${JOB_FIELDS} } userErrors { message path } } }`;
const M_EDIT = `mutation($jobId: EncodedId!, $input: JobEditInput!) {
  jobEdit(jobId: $jobId, input: $input) { job { ${JOB_FIELDS} } userErrors { message path } } }`;
const M_CLOSE = `mutation($jobId: EncodedId!) {
  jobClose(jobId: $jobId, input: { modifyIncompleteVisitsBy: DESTROY_ALL }) {
    job { id jobStatus } userErrors { message path } } }`;
const M_REOPEN = `mutation($jobId: EncodedId!) {
  jobReopen(jobId: $jobId) { job { id jobStatus } userErrors { message path } } }`;
const M_LI_CREATE = `mutation($jobId: EncodedId!, $input: JobCreateLineItemsInput!) {
  jobCreateLineItems(jobId: $jobId, input: $input) { job { id } userErrors { message path } } }`;
const M_LI_EDIT = `mutation($jobId: EncodedId!, $input: JobEditLineItemsInput!) {
  jobEditLineItems(jobId: $jobId, input: $input) { job { id } userErrors { message path } } }`;
const M_LI_DELETE = `mutation($jobId: EncodedId!, $input: JobDeleteLineItemsInput!) {
  jobDeleteLineItems(jobId: $jobId, input: $input) { job { id } userErrors { message path } } }`;

// ---- helpers ----------------------------------------------------------------
async function gidFor(entityType: string, entityId: number): Promise<string | null> {
  const { data } = await db.from("entity_source_links").select("source_id")
    .eq("entity_type", entityType).eq("source_system", "jobber").eq("entity_id", entityId).maybeSingle();
  return data?.source_id ?? null;
}

type Svc = { service_line_item_id: number; unit_price: number; quantity?: number };

async function resolveServices(services: Svc[]): Promise<{ err?: string; lines?: { name: string; unitPrice: number; quantity: number }[] }> {
  if (!Array.isArray(services) || services.length === 0) return { err: "Pick at least one service for a Service Agreement." };
  const ids = services.map((s) => s.service_line_item_id);
  const { data: cat } = await db.from("service_line_items").select("id, code, title, schedulable, reason").in("id", ids);
  const byId = new Map((cat ?? []).map((c: any) => [c.id, c]));
  const lines: { name: string; unitPrice: number; quantity: number }[] = [];
  // Deterministic order regardless of click order: catalog code order. The title
  // derivation below and the UI preview both depend on this.
  services = [...services].sort((a, b) => {
    const ca = byId.get(a.service_line_item_id)?.code ?? "99";
    const cb = byId.get(b.service_line_item_id)?.code ?? "99";
    return ca.localeCompare(cb);
  });
  for (const s of services) {
    const c = byId.get(s.service_line_item_id);
    if (!c) return { err: `Service ${s.service_line_item_id} does not exist.` };
    if (!c.schedulable) return { err: `"${c.title}" is not a schedulable service.` };
    // ⚠ HARD SA/SC SEPARATION (Fred, 2026-07-30): an SA job may only carry
    // reason='Service Agreement' lines (codes 01-08). SC lines (09-24) belong to
    // VISITS of a Service Call job, never to the job itself — a Service Call job
    // is an empty container by the sync's own rule (SA-has-lines/SC-has-none).
    if (c.reason !== "Service Agreement") {
      return { err: `"${c.title}" is a Service Call item — it goes on the visit, not on a Service Agreement job.` };
    }
    const price = Number(s.unit_price);
    if (!Number.isFinite(price) || price < 0) return { err: `"${c.title}" needs a valid price.` };
    // ⚠ service_line_items.title ALREADY carries the code prefix ("01 - Service
    // Agreement - …"), measured 2026-07-30. An earlier draft composed
    // `${code} - ${title}` and would have written "01 - 01 - …", silently breaking
    // the taxonomy join (lpad(substring(name from '^([0-9]+)'))) on every line.
    // The title IS the canonical line name. Belt-and-braces: assert the prefix.
    const name = c.title.trim();
    if (!new RegExp(`^0?${Number(c.code)}\\s*-`).test(name)) {
      return { err: `Catalog title for code ${c.code} lost its code prefix ("${name}") — tell Fred before creating jobs.` };
    }
    lines.push({ name, unitPrice: price, quantity: Number(s.quantity) > 0 ? Number(s.quantity) : 1 });
  }
  return { lines };
}

function jobToRecord(
  clientId: number, propertyId: number | null, j: any, includeLines: boolean,
  freq?: number | null, billing?: Billing,
) {
  const rec: Record<string, unknown> = {
    gid: j.id,
    client_id: clientId,
    property_id: propertyId,
    job_number: String(j.jobNumber),
    title: j.title,
    job_status: j.jobStatus,
    start_at: j.startAt ?? "",
    end_at: j.endAt ?? "",
    total: j.total != null ? String(j.total) : "",
    notes: j.instructions ?? null,
  };
  if (freq !== undefined) rec.frequency_days = freq == null ? "" : String(freq);
  // Billing is recorded ONLY when this call actually set it, and only after the
  // caller has verified j.billingType reads back as the requested type. The
  // columns are `last confirmed by us`, never a guess — a NULL means "we have
  // never confirmed this job's billing", which the UI must surface as a
  // question rather than defaulting to Visit based (2026-08-01_1120 header).
  // ⚠ Key-presence-aware on the DB side: omitting these leaves them untouched.
  if (billing?.billing_type) {
    rec.billing_type = billing.billing_type;
    rec.invoice_frequency = billing.invoice_frequency ?? "";
    // ⚠ The RULE comes from the VERIFIED READ-BACK (recurrenceSchedule.calendarRule),
    // not from the request — the caller has already failed the save if the two
    // disagree, so by here they mean the same thing, and taking Jobber's copy keeps
    // the column honestly "what Jobber holds". It also stores Jobber's canonical
    // form (it drops a redundant INTERVAL=1), so our value and theirs stay
    // byte-comparable for future drift checks. Falls back to the requested rule only
    // when Jobber exposes none, which for a non-recurring schedule is correct: "".
    rec.invoice_rrule = confirmedRrule(j) ?? billing.invoice_rrule ?? "";
  }
  if (includeLines) {
    rec.line_items = (j.lineItems?.nodes ?? []).map((n: any) => ({
      name: n.name, quantity: String(n.quantity), unit_price: String(n.unitPrice),
      total_price: n.totalPrice != null ? String(n.totalPrice) : null,
    }));
  }
  return rec;
}

// ============================================================================
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsPreflight(req) });
  if (req.method !== "POST") return fail("method", "POST only");

  // AUTH — in-handler, NOT gateway verify_jwt. Measured 2026-07-30: this project
  // signs session tokens with ES256 and the gateway's verify_jwt rejects them
  // outright (401 UNAUTHORIZED_ASYMMETRIC_JWT), so verify_jwt=false in config.toml
  // is deliberate and documented there. auth.getUser() round-trips to GoTrue,
  // which validates signature + expiry against the real keys — and is STRONGER
  // than the gateway check, which the public anon key also passes. A bare claim
  // decode here would verify nothing (signature unchecked).
  const m = (req.headers.get("authorization") ?? "").match(/^Bearer (.+)$/);
  if (!m) return fail("forbidden", "Staff account required.");
  const { data: userData, error: userErr } = await db.auth.getUser(m[1]);
  const email = String(userData?.user?.email ?? "").toLowerCase();
  if (userErr || !userData?.user?.id ||
      (!email.endsWith("@ayache.com") && !email.endsWith("@unclogme.com"))) {
    return fail("forbidden", "Staff account required.");
  }

  let body: any;
  try { body = await req.json(); } catch { return fail("bad_request", "Invalid JSON body."); }
  const action = String(body.action ?? "");
  const clientId = Number(body.client_id);
  if (!["create", "edit", "close", "reopen"].includes(action)) return fail("bad_request", "Unknown action.");
  if (!Number.isFinite(clientId)) return fail("bad_request", "client_id is required.");

  let token: string;
  try { token = await getJobberToken(); } catch (e) {
    return fail("jobber_unreachable", "Couldn't reach Jobber. Nothing was saved on either side.", { detail: String(e) });
  }

  // ==========================================================================
  // CREATE
  // ==========================================================================
  if (action === "create") {
    const p = body.patch ?? {};
    const kind = p.kind === "SA" ? "SA" : p.kind === "SC" ? "SC" : null;
    if (!kind) return fail("bad_request", "Job kind must be Service Agreement or Service Call.");
    const propertyId = Number(p.property_id);
    if (!Number.isFinite(propertyId)) return fail("bad_request", "A property is required.");
    // Service Calls are ON-DEMAND (Fred, 2026-07-30): no start date — the job is a
    // container; scheduling happens per-visit when the call comes in. Only an SA
    // carries a timeframe.
    // ⚠ START DATE IS OPTIONAL ON AN SA AS OF 2026-07-31 (Fred): "i want to have
    // the option of not setting a Start Date, first, because we might want to add
    // that later, and when we do that we can then run the cron job of creating the
    // visits". A dateless SA is a real state: the agreement exists, scheduling has
    // not begun. The visit generator refuses to schedule such a job until a date
    // is set (the not-started guard in public.fn_generate_sa_visits) — WITHOUT
    // that guard the generator would anchor on today+frequency and start booking
    // trucks immediately, the exact opposite of the ask.
    const startDate = String(p.start_date ?? "");
    const hasStart = /^\d{4}-\d{2}-\d{2}$/.test(startDate);
    if (kind === "SA" && startDate !== "" && !hasStart) {
      return fail("bad_request", "Start date must be a real date (YYYY-MM-DD), or left empty.");
    }

    // Property must belong to this client AND be Jobber-linked (jobCreate takes
    // propertyId; the client is implied by it).
    const { data: prop } = await db.from("properties").select("id, client_id").eq("id", propertyId).maybeSingle();
    if (!prop || prop.client_id !== clientId) return fail("bad_request", "That property does not belong to this client.");
    const propGid = await gidFor("property", propertyId);
    if (!propGid) return fail("property_not_in_jobber", "This property is not in Jobber yet, so a job cannot be created on it.");

    const freq = kind === "SA" ? Number(p.frequency_days) : 0;
    if (kind === "SA" && (!Number.isFinite(freq) || freq < 1 || freq > 365)) {
      return fail("bad_request", "A Service Agreement needs a frequency between 1 and 365 days.");
    }

    let lines: { name: string; unitPrice: number; quantity: number }[] = [];
    let title: string;
    if (kind === "SA") {
      const r = await resolveServices(p.services ?? []);
      if (r.err) return fail("bad_request", r.err);
      lines = r.lines!;
      // Behaviour-class title: 'Service Agreement%' prefix is load-bearing.
      // Derived from the FULL combination — rule in saTitle(), shared with the UI.
      title = saTitle(lines.map((l) => l.name));
    } else {
      // Exact string: ops.client_service_options matches lower(btrim(title))='service call'.
      title = "Service Call";
    }

    // ---- BILLING, widened to Jobber parity (Fred, 2026-07-30) -------------
    // Two axes, exactly like Jobber's own form: billing TYPE (visit_based |
    // fixed) and invoice FREQUENCY (per_visit | monthly_last_day | once_closed
    // | as_needed | custom+RRULE). Mapping to the API per the billing reference
    // doc (Building Apps/Client App/docs/2026-07-30_jobber-job-billing-reference.md):
    //   per_visit        -> PER_VISIT
    //   monthly_last_day -> PERIODIC + RRULE:FREQ=MONTHLY;BYMONTHDAY=-1
    //   once_closed      -> ON_COMPLETION
    //   as_needed        -> NEVER   (nothing is ever generated; Jobber's "no reminders")
    //   custom           -> PERIODIC + caller-supplied RRULE (validated shape)
    // Back-compat: the pre-widening key `billing` ('per_visit'|'fixed') still
    // maps to the old two combinations, so an in-flight old bundle cannot break.
    const bill = resolveBilling(p, kind === "SA", { legacy: true });
    if (bill.err) return fail("bad_request", bill.err);
    const invoicing = bill.invoicing!;
    const btype = bill.billing_type!;

    const input: Record<string, unknown> = {
      propertyId: propGid,
      title,
      invoicing,
      // NO `scheduling` — ever. See header. And NO timeframe for an SC (on-demand).
    };
    // A dateless SA sends NO timeframe at all — Jobber accepts that (it fills its
    // own default startAt for undated jobs, the same behaviour an SC relies on).
    if (kind === "SA" && hasStart) {
      input.timeframe = { startAt: startDate };
      if (p.end_date && /^\d{4}-\d{2}-\d{2}$/.test(p.end_date)) {
        const days = Math.round((Date.parse(p.end_date) - Date.parse(startDate)) / 86_400_000);
        if (days > 0) input.timeframe = { startAt: startDate, durationUnits: "DAYS", durationValue: days };
      }
    }
    const instructions = typeof p.instructions === "string" && p.instructions.trim() ? p.instructions.trim() : null;
    if (instructions) input.instructions = instructions;
    if (lines.length) {
      input.lineItems = lines.map((l) => ({ ...l, saveToProductsAndServices: false }));
    }
    if (kind === "SA") {
      input.customFields = [{ customFieldConfigurationId: FREQ_CF_GID, valueNumeric: freq }];
    }

    const res = await gql(token, M_CREATE, { input });
    if (!res.ok) {
      const map: Record<string, [string, string]> = {
        busy: ["jobber_busy", "Jobber is busy right now. Wait a moment and press Save again — nothing was created."],
        unreachable: ["jobber_unreachable", "Couldn't reach Jobber. Nothing was created on either side."],
        no_answer: ["jobber_no_answer", "Jobber didn't answer. It may or may not have created the job — check Jobber before retrying."],
        rejected: ["jobber_rejected", `Jobber refused the job: ${res.detail}`],
      };
      const [code, message] = map[res.kind];
      return fail(code, message);
    }
    const uerr = ue(res.data.jobCreate);
    if (uerr) return fail("jobber_rejected", `Jobber refused the job: ${uerr}`);
    const job = res.data.jobCreate.job;
    if (!job) return fail("jobber_refused_no_reason", "Jobber returned no job and no reason. Nothing was saved on our side.");

    // VERIFY the returned object (the create payload IS a fresh server read).
    // The date check applies only when we SENT a timeframe (SA): an SC has none,
    // and Jobber fills its own default startAt for undated jobs.
    if (job.title !== title || job.property?.id !== propGid ||
        (kind === "SA" && hasStart && etDate(job.startAt) !== startDate) ||
        (lines.length && (job.lineItems?.nodes ?? []).length !== lines.length)) {
      return fail("verify_failed",
        "Jobber created the job but it doesn't match what was sent — check it in Jobber before retrying.",
        { jobber_number: job.jobNumber });
    }
    // Billing verify: the TYPE must read back exactly.
    const wantType = btype === "fixed" ? "FIXED_PRICE" : "VISIT_BASED";
    if (String(job.billingType).toUpperCase() !== wantType) {
      return fail("verify_failed",
        `Jobber created the job but its billing type reads back as ${job.billingType}, not ${wantType} — check it in Jobber.`,
        { jobber_number: job.jobNumber });
    }
    // ...and so must the SCHEDULE. This branch previously asserted the type alone,
    // so a created job's invoice schedule was never verified at all even though
    // jobToRecord goes on to store invoice_frequency + invoice_rrule as confirmed.
    const wantSchedC = String((bill.invoicing as Record<string, unknown>)?.invoicingSchedule ?? "");
    const gotSchedC = String(job.invoiceSchedule?.billingFrequency ?? "").toUpperCase();
    if (wantSchedC && gotSchedC && gotSchedC !== wantSchedC.toUpperCase()) {
      return fail("verify_failed",
        `Jobber created the job but its invoice schedule reads back as ${gotSchedC}, not ${wantSchedC} — check it in Jobber.`,
        { jobber_number: job.jobNumber });
    }
    const rmmC = rruleMismatch(bill.invoice_rrule, job.invoiceSchedule?.recurrenceSchedule?.calendarRule);
    if (rmmC) {
      return fail("verify_failed",
        `Jobber created the job but stored a different invoice schedule (${rmmC}). Its summary reads "${job.invoiceSchedule?.scheduleSummary ?? "?"}" — check it in Jobber.`,
        { jobber_number: job.jobNumber });
    }

    const { data: rec, error: recErr } = await db.rpc("fn_record_client_job",
      { p: jobToRecord(clientId, propertyId, job, kind === "SA", kind === "SA" ? freq : 0, bill) });
    if (recErr) {
      // The one honest window: Jobber has the job, our DB write failed. The next
      // */5 poll imports it (createdAt cursor) — say so, do not pretend failure.
      return fail("db_write_failed",
        `The job WAS created in Jobber (#${job.jobNumber}) but saving it locally failed; it will appear here within ~5 minutes via the sync.`,
        { jobber_number: job.jobNumber });
    }
    return done({
      job_id: rec.job_id, job_number: job.jobNumber, job_status: String(job.jobStatus).toLowerCase(),
      billing: { type: job.billingType, schedule_summary: job.invoiceSchedule?.scheduleSummary ?? null },
    });
  }

  // ---- shared resolution for edit/close/reopen -----------------------------
  const jobId = Number(body.job_id);
  if (!Number.isFinite(jobId)) return fail("bad_request", "job_id is required.");
  const { data: jobRow } = await db.from("jobs").select("id, client_id, property_id, title, frequency_days").eq("id", jobId).maybeSingle();
  if (!jobRow || jobRow.client_id !== clientId) return fail("bad_request", "That job does not belong to this client.");
  const jobGid = await gidFor("job", jobId);
  if (!jobGid) return fail("job_not_in_jobber", "This job has no Jobber link, so it cannot be synced. Tell Fred.");

  // ==========================================================================
  // CLOSE ("delete": no jobDelete exists — jobClose destroys incomplete visits)
  // ==========================================================================
  if (action === "close") {
    const res = await gql(token, M_CLOSE, { jobId: jobGid });
    if (!res.ok) return fail("jobber_rejected", `Jobber refused to close the job: ${res.detail}`);
    const uerr = ue(res.data.jobClose);
    if (uerr) return fail("jobber_rejected", `Jobber refused to close the job: ${uerr}`);
    const st = String(res.data.jobClose.job?.jobStatus ?? "archived").toLowerCase();
    const { error: recErr } = await db.rpc("fn_record_client_job", { p: { gid: jobGid, job_status: st } });
    if (recErr) return fail("db_write_failed", "Closed in Jobber but the local update failed; the 30-minute sync will settle it.");
    const { data: n } = await db.rpc("fn_close_job_visits", { p_job_id: jobId });
    return done({ job_id: jobId, job_status: st, visits_removed: n ?? 0 });
  }

  // ==========================================================================
  // REOPEN
  // ==========================================================================
  if (action === "reopen") {
    const res = await gql(token, M_REOPEN, { jobId: jobGid });
    if (!res.ok) return fail("jobber_rejected", `Jobber refused to reopen the job: ${res.detail}`);
    const uerr = ue(res.data.jobReopen);
    if (uerr) return fail("jobber_rejected", `Jobber refused to reopen the job: ${uerr}`);
    const st = String(res.data.jobReopen.job?.jobStatus ?? "active").toLowerCase();
    const { error: recErr } = await db.rpc("fn_record_client_job", { p: { gid: jobGid, job_status: st } });
    if (recErr) return fail("db_write_failed", "Reopened in Jobber but the local update failed; the 30-minute sync will settle it.");
    return done({ job_id: jobId, job_status: st });
  }

  // ==========================================================================
  // EDIT — change-aware: only the provided groups are touched
  // ==========================================================================
  const p = body.patch ?? {};
  const applied: string[] = [];
  const isSA = String(jobRow.title ?? "").toLowerCase().startsWith("service agreement");

  // Pre-flight EVERYTHING before the first mutation (the half-applied lesson).
  const edit: Record<string, unknown> = {};
  if (p.start_date !== undefined || p.end_date !== undefined) {
    if (!isSA) return fail("bad_request", "Service Calls are on-demand and carry no dates — schedule the visit instead.");
    const sd = String(p.start_date ?? "");
    if (!/^\d{4}-\d{2}-\d{2}$/.test(sd)) return fail("bad_request", "A valid start date is required to change dates.");
    const tf: Record<string, unknown> = { startAt: sd };
    if (p.end_date && /^\d{4}-\d{2}-\d{2}$/.test(p.end_date)) {
      const days = Math.round((Date.parse(p.end_date) - Date.parse(sd)) / 86_400_000);
      if (days <= 0) return fail("bad_request", "The end date must be after the start date.");
      tf.durationUnits = "DAYS"; tf.durationValue = days;
    }
    edit.timeframe = tf;
  }
  if (p.instructions !== undefined) {
    edit.instructions = typeof p.instructions === "string" ? p.instructions.trim() : "";
  }
  let newFreq: number | undefined;
  if (p.frequency_days !== undefined) {
    if (!isSA) return fail("bad_request", "Frequency only applies to Service Agreements.");
    newFreq = Number(p.frequency_days);
    if (!Number.isFinite(newFreq) || newFreq < 1 || newFreq > 365) {
      return fail("bad_request", "Frequency must be between 1 and 365 days.");
    }
    edit.customFields = [{ customFieldConfigurationId: FREQ_CF_GID, valueNumeric: newFreq }];
  }
  let wantLines: { name: string; unitPrice: number; quantity: number }[] | null = null;
  // Non-service (fee/admin) lines found on the job — never touched, asserted
  // still present in the verify block. See the toDelete comment below.
  let preserved: string[] = [];
  if (p.services !== undefined) {
    if (!isSA) return fail("bad_request", "Only Service Agreements carry service line items.");
    const r = await resolveServices(p.services ?? []);
    if (r.err) return fail("bad_request", r.err);
    wantLines = r.lines!;
    // The SA title is DERIVED from the full service combination, so changing the
    // services makes the stored title stale — "Service Agreement - Pumping" on a
    // job that now also cleans. jobEdit accepts `title` (verified against
    // JobEditInput), and it is still never free text: it is recomputed by the
    // same saTitle() the create path and the UI preview use.
    // ⚠ The 'Service Agreement' PREFIX is a behaviour class the backend branches
    // on (isSA above, ops.client_service_options, client.fn_is_current_sa_job) —
    // saTitle always emits it, so re-deriving can never reclassify the job.
    const reTitle = saTitle(wantLines.map((l) => l.name));
    if (reTitle !== jobRow.title) edit.title = reTitle;
  }
  // BILLING on edit (added 2026-08-01). Previously the edit branch never read
  // these keys at all, so a billing-only patch fell straight through to the
  // no_changes return below and reported success having changed nothing.
  // ⚠ BOTH keys are required together, deliberately: Jobber's `invoicing` block needs
  // invoicingType AND invoicingSchedule, so a half patch could silently downgrade a
  // custom schedule. Requiring the pair keeps intent explicit.
  // 🛑 The ORIGINAL justification for that rule was WRONG and is corrected here rather
  // than left in place: it said inference was impossible because "Job.invoiceSchedule
  // exposes billingFrequency and a summary string, not the rule". It exposes
  // recurrenceSchedule.calendarRule, which IS the rule (measured 2026-08-03). So the
  // pair could now be inferred from a Jobber read. The requirement is kept anyway —
  // explicit intent beats inference for a field that decides when a client is billed,
  // and the caller (the job dialog) sends the trio together, so it costs nothing.
  let bill: Billing | null = null;
  // ⚠ `invoice_rrule` MUST be in this condition. Until 2026-08-03 it was not, and the
  // consequence was the exact defect the comment block above was written to fix,
  // reintroduced one key over: a patch carrying ONLY invoice_rrule (a user moving a
  // custom schedule from the 10th to the 15th, with the type and frequency unchanged)
  // never entered this branch, `edit` stayed empty, and the call returned
  // `no_changes: true` — a silent false success. Latent until the custom-schedule UI
  // shipped, at which point it becomes the single most likely billing edit there is.
  if (p.billing_type !== undefined || p.invoice_frequency !== undefined || p.invoice_rrule !== undefined) {
    if (p.billing_type === undefined || p.invoice_frequency === undefined) {
      return fail("bad_request", "Send the billing type and the invoice frequency together — a partial billing change could overwrite the other half.");
    }
    const r = resolveBilling(p, isSA, { legacy: false });
    if (r.err) return fail("bad_request", r.err);
    bill = r;
    edit.invoicing = r.invoicing;
  }

  if (Object.keys(edit).length === 0 && wantLines === null) {
    return done({ job_id: jobId, no_changes: true });
  }

  // 1. scalar groups in ONE jobEdit
  if (Object.keys(edit).length) {
    const res = await gql(token, M_EDIT, { jobId: jobGid, input: edit });
    if (!res.ok) return fail("jobber_rejected", `Jobber refused the edit: ${res.detail}`, { applied });
    const uerr = ue(res.data.jobEdit);
    if (uerr) return fail("jobber_rejected", `Jobber refused the edit: ${uerr}`, { applied });
    applied.push(...Object.keys(edit).map((k) =>
      k === "customFields" ? "frequency"
      : k === "timeframe" ? "dates"
      : k === "invoicing" ? "billing"
      : k));
  }

  // 2. line items: create-first, edit by Jobber id, delete LAST (never a
  //    zero-line window — the $0-invoice lesson).
  if (wantLines !== null) {
    const cur = await gql(token, Q_JOB, { id: jobGid });
    if (!cur.ok) return fail("jobber_no_answer", "Jobber didn't answer while reading line items.", { applied, failed: "line items" });
    const curLines: any[] = cur.data.job?.lineItems?.nodes ?? [];
    const curByName = new Map(curLines.map((n) => [n.name, n]));
    const wantByName = new Map(wantLines.map((l) => [l.name, l]));
    const toCreate = wantLines.filter((l) => !curByName.has(l.name));
    const toEdit = wantLines.filter((l) => {
      const c = curByName.get(l.name);
      return c && (Number(c.unitPrice) !== l.unitPrice || Number(c.quantity) !== l.quantity);
    });
    // 🛑 DELETE ONLY *SERVICE* LINES (catalogue codes 01-08). A job also carries
    // fee/admin lines the Services picker never shows and the caller therefore
    // never submits — so the old predicate (`everything not submitted`) silently
    // STRIPPED THEM FROM JOBBER on any service edit. Measured 2026-08-01 over
    // the 175 live SA jobs: 110 of them carry at least one such line —
    //   "25 - Credit card fee (3.53%)"  61 jobs, $885.50
    //   "26 - ACH Fee (1%)"             47 jobs, $151.50
    //   "27 - GDO Online Reporting"      7 jobs,  $85.00
    // The verify block below only asserts that the WANTED lines landed, so the
    // loss was invisible on both sides. Codes 01-08 are exactly what
    // resolveServices() can produce (service_line_items.reason='Service
    // Agreement'), which is what makes this predicate the correct inverse.
    // ⚠ NEVER widen this to "everything not submitted" again.
    const isServiceLine = (name: unknown) => /^\s*0[1-8]\s*-/.test(String(name ?? ""));
    const toDelete = curLines.filter((n) => isServiceLine(n.name) && !wantByName.has(n.name));
    preserved = curLines.filter((n) => !isServiceLine(n.name)).map((n) => String(n.name));
    if (toCreate.length) {
      const res = await gql(token, M_LI_CREATE, { jobId: jobGid, input: { lineItems: toCreate.map((l) => ({ ...l, saveToProductsAndServices: false })) } });
      const err = !res.ok ? res.detail : ue(res.data.jobCreateLineItems);
      if (err) return fail("partial_push", `The other changes were saved in Jobber, but adding line items failed: ${err}`, { applied, failed: "line items" });
    }
    if (toEdit.length) {
      const res = await gql(token, M_LI_EDIT, { jobId: jobGid, input: { lineItems: toEdit.map((l) => ({ lineItemId: curByName.get(l.name).id, unitPrice: l.unitPrice, quantity: l.quantity })) } });
      const err = !res.ok ? res.detail : ue(res.data.jobEditLineItems);
      if (err) return fail("partial_push", `The other changes were saved in Jobber, but editing line items failed: ${err}`, { applied, failed: "line items" });
    }
    if (toDelete.length) {
      const res = await gql(token, M_LI_DELETE, { jobId: jobGid, input: { lineItemIds: toDelete.map((n) => n.id) } });
      const err = !res.ok ? res.detail : ue(res.data.jobDeleteLineItems);
      if (err) return fail("partial_push", `The other changes were saved in Jobber, but removing old line items failed: ${err}`, { applied, failed: "line items" });
    }
    applied.push("line items");
  }

  // 3. VERIFY: re-read and compare every changed group (ET dates, not raw strings)
  const ver = await gql(token, Q_JOB, { id: jobGid });
  if (!ver.ok) return fail("verify_failed", "Saved in Jobber but the verification read failed — check Jobber.", { applied });
  const j = ver.data.job;
  if (edit.timeframe && etDate(j.startAt) !== (edit.timeframe as any).startAt) {
    return fail("verify_failed", "Jobber accepted the date change but reads back a different date — check Jobber.", { applied });
  }
  if (edit.instructions !== undefined && (j.instructions ?? "") !== edit.instructions) {
    return fail("verify_failed", "Jobber accepted the instructions but reads back different text — check Jobber.", { applied });
  }
  if (edit.title !== undefined && j.title !== edit.title) {
    return fail("verify_failed", "Jobber accepted the services but the job title reads back differently — check Jobber.", { applied });
  }
  if (bill) {
    const wantType = bill.billing_type === "fixed" ? "FIXED_PRICE" : "VISIT_BASED";
    if (String(j.billingType).toUpperCase() !== wantType) {
      return fail("verify_failed",
        `Jobber accepted the edit but the billing type reads back as ${j.billingType}, not ${wantType} — check it in Jobber.`,
        { applied });
    }
    // ⚠ THE GAP THIS CLOSES. Until 2026-08-03 the verify asserted ONLY billingType,
    // yet jobToRecord writes billing_type AND invoice_frequency AND invoice_rrule —
    // the last two straight from resolveBilling(), i.e. from what the CALLER ASKED
    // FOR. So a schedule change was recorded as confirmed even if Jobber applied
    // something else. (The 2026-08-01_1120 migration header claimed all three came
    // from "the VERIFIED post-mutation read". Only one of them did.)
    const wantSched = String((bill.invoicing as Record<string, unknown>)?.invoicingSchedule ?? "");
    const gotSched = String(j.invoiceSchedule?.billingFrequency ?? "").toUpperCase();
    if (wantSched && gotSched && gotSched !== wantSched.toUpperCase()) {
      return fail("verify_failed",
        `Jobber accepted the edit but the invoice schedule reads back as ${gotSched}, not ${wantSched} — check it in Jobber.`,
        { applied });
    }
    // And assert the RULE ITSELF landed — the interval, the day, the weekdays. This
    // compares against recurrenceSchedule.calendarRule, which is the rule verbatim,
    // so a silently-coerced day or a dropped BYDAY fails loudly for EVERY shape
    // (weekly and nth-weekday included, which the old summary matcher could not check).
    const rmm = rruleMismatch(bill.invoice_rrule, j.invoiceSchedule?.recurrenceSchedule?.calendarRule);
    if (rmm) {
      return fail("verify_failed",
        `Jobber accepted the edit but stored a different invoice schedule (${rmm}). Its summary reads "${j.invoiceSchedule?.scheduleSummary ?? "?"}" — check it in Jobber.`,
        { applied });
    }
  }
  // ⚠ THE CHECK WHOSE ABSENCE HID THE BUG. The old verify only asserted that
  // the WANTED lines landed, so deleting a fee line passed verification
  // cleanly. Assert the non-service lines we chose not to touch are still on
  // the job, so any future widening of `toDelete` fails loudly instead of
  // quietly costing money.
  if (preserved.length) {
    const names = new Set((j.lineItems?.nodes ?? []).map((n: any) => String(n.name)));
    const lost = preserved.filter((n) => !names.has(n));
    if (lost.length) {
      return fail("verify_failed",
        `Saved, but these non-service line items are no longer on the Jobber job: ${lost.join(", ")}. Check the job in Jobber before editing it again.`,
        { applied });
    }
  }
  if (wantLines !== null) {
    const names = new Set((j.lineItems?.nodes ?? []).map((n: any) => n.name));
    for (const l of wantLines) {
      if (!names.has(l.name)) return fail("verify_failed", `Line item "${l.name}" did not land in Jobber — check Jobber.`, { applied });
    }
  }

  // 4. only now, our DB — from the READ-BACK, not from the patch.
  // `bill` is passed so billing_type / invoice_frequency / invoice_rrule are
  // persisted (they were previously never stored, which is why the dialog could
  // not show a job's real billing); it is undefined when billing was not part of
  // this edit, and fn_record_client_job is key-presence-aware, so the stored
  // values are then left alone rather than wiped.
  const rec = jobToRecord(clientId, jobRow.property_id, j, isSA && wantLines !== null, newFreq, bill ?? undefined);
  const { error: recErr } = await db.rpc("fn_record_client_job", { p: rec });
  if (recErr) {
    return fail("db_write_failed", "Saved and verified in Jobber but the local write failed; the 30-minute sync will settle it.", { applied });
  }
  // `preserved` is returned so the UI can say what it did NOT touch — a silent
  // "saved" is what let the fee-line deletion go unnoticed for a month.
  return done({ job_id: jobId, applied, preserved_line_items: preserved });
});
