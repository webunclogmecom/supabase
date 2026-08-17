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
    // 🛑 THE GUARD STAYS. Its original reason was "a Service Call carries NO job line items",
    // which stopped being literally true on 2026-08-06 when SC jobs gained FEE lines.
    //
    // ✅ THE ACTUAL REASON, from Fred 2026-08-06 — and it is the mechanism, not a convention:
    // "if you add line items on a job, every visit will have for default those line items, and
    // we don't want that on the SC jobs, it's ok on the SA though."
    // Jobber INHERITS a job's line items onto every visit it creates. For a Service Agreement
    // that is exactly right — the agreed services repeat every visit. For a Service Call it is
    // wrong, because every call is different work, which is why SC SERVICES live on the VISIT
    // and never on the job. Fee lines are the deliberate exception: inheritance is the POINT
    // there, since the card/ACH fee is meant to ride every call ("it bills once per visit").
    // ⇒ A fixed-price SC would therefore invoice the inherited FEES alone and never the work.
    return { err: "A Service Call bills per visit — a fixed price would invoice only the job's fee lines, not the work, because a Service Call's services live on its visits." };
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

// ============================================================================
// FEE LINES (catalogue codes 25/26/27) — 2026-08-05, Fred
// ============================================================================
// 🛑 FEES TRAVEL IN THEIR OWN `fees` KEY AND THEIR OWN RESOLVER, ON PURPOSE.
// The obvious implementation — letting fee codes through resolveServices() — was
// designed, reviewed and REJECTED because it silently arms four separate defects,
// one of which destroys data:
//
//  1. `services.length === 0` is the "pick at least one service" guard. A fee would
//     satisfy it, so a user could uncheck every service, leave the pre-checked ACH
//     fee, and save. The job's 01-08 lines are stripped, it falls out of
//     fn_generate_sa_visits' EXISTS (reason in Service Agreement/Service Call and
//     code <> 08), and that same predicate feeds the generator's CLEANUP arm, which
//     runs `update visits set deleted_at = now()`. MEASURED EXPOSURE: 111 SA jobs /
//     486 future visits, and the 40-per-run abort guard never fires because no job
//     holds more than 40. Keeping fees out of `services` makes this UNREACHABLE
//     rather than defended against.
//  2. saTitle() runs on the emitted set, so the job title would become
//     "Service Agreement - Cleaning - Aux Cleaning & Credit card fee (3.53%)" —
//     and fn_generate_sa_visits copies the job title onto every visit it mints, so
//     the card-fee percentage would appear on the crew's Calendar and Field Portal.
//  3. Widening `isServiceLine` would delete 25/26/27 from `preserved`, disarming the
//     exact regression alarm rule 2c installed after the 2026-08-01 loss. 165 of the
//     175 non-service job lines ARE codes 25/26/27.
//  4. Delete-by-absence over lines this app has never written (all 166 were created
//     by a human in Jobber's UI, two of them the same day this shipped).
//
// ⇒ resolveServices(), saTitle(), isServiceLine() and the service half of toDelete
//   are BYTE-IDENTICAL to before this change. Keep them that way.
//
// HOW A FEE MAY BE DELETED (Fred chose delete-on-uncheck, so this had to be safe):
// the caller sends `rendered_fee_ids` — every fee it actually PUT ON SCREEN. A fee is
// removed only when it was rendered AND was not submitted, i.e. the user demonstrably
// saw that line and unchecked it. An old or cached bundle sends no `rendered_fee_ids`,
// so it can delete NOTHING. ⚠ This is deliberately NOT a "this build knows about fees"
// capability flag: that asserts the BUILD understands fees, while the delete decision
// needs the CALLER to have seen THIS line. The gap between those two propositions is
// exactly where the 2026-08-01 loss lived.
//
// PERCENT MODE IS COMPUTED HERE, NEVER BY THE CLIENT. The server already holds the
// service subtotal, and a stale bundle must not be able to decide what a customer is
// billed. Rate lives on service_line_items.default_rate_pct (2026-08-05_1806); the
// percent/amount MODE is derived by the UI, never stored.
// `expected_unit_price` is the amount the DIALOG DISPLAYED. In percent mode it is REQUIRED
// and must match what the server computes, which is how "the user saw what will be billed"
// becomes enforceable instead of hoped for. Without it, opening a job and pressing Save
// silently reprices the fee: measured, 7 live lines would move on the next save, including
// job 1777 by +$3.89 and three jobs by exactly +$0.01 (3.53% of $750 is $26.475 — a float
// `0.0353*750` truncates to 26.47 while exact arithmetic rounds to 26.48). A cent moved
// without anyone seeing it is still a bill nobody authorised.
type FeeReq = {
  service_line_item_id: number;
  mode?: string;
  unit_price?: number;
  quantity?: number;
  expected_unit_price?: number;
};

const isFeeReason = (r: unknown) => r === "fee" || r === "other";

// `servicesChanged` + `currentAmounts` implement Fred's rule (2026-08-05): "only reprice
// when the services actually changed". A percent fee already on the job KEEPS its amount
// on a save that did not touch the services, so opening a job and pressing Save can never
// move money. Repricing happens on exactly two occasions, both of them deliberate acts:
// the services really changed, or the fee is being added to the job now.
// ⚠ This deliberately leaves the three known one-cent divergences (jobs 1394/1598/1600,
// where a float 0.0353*750 truncated to 26.47 and exact arithmetic gives 26.48) alone
// rather than nudging three customers because our rounding differs. Job 1777, which is
// genuinely stale at $19.06 against a correct $22.95, is corrected the moment its services
// are next edited — which is the event that made it wrong in the first place.
async function resolveFees(
  fees: FeeReq[],
  renderedIds: number[],
  serviceSubtotal: number,
  servicesChanged: boolean,
  currentAmounts: Map<string, number>,
): Promise<{
  err?: string;
  lines?: { name: string; unitPrice: number; quantity: number }[];
  deletableNames?: Set<string>;
}> {
  // ⚠ DEDUPE BY ID. The catalogue lookup was already deduped, but the EMIT loop was not,
  // so the same fee sent twice produced two identical jobCreateLineItems rows — verify
  // passed (the name is present) and the job was then permanently tripped up by the
  // duplicate guard on every later save. Last-one-wins matches the dialog's semantics.
  // ⚠ ENTRY-LEVEL SHAPE, not just list-level. Both call sites now check `Array.isArray`,
  // but an array whose ENTRIES are null or primitives still reaches here, and
  // `f.service_line_item_id` on a null throws a TypeError. There is no top-level
  // try/catch around Deno.serve in this file, so that surfaces as a bare 500 rather than
  // a message naming the problem. It fails safe (it can never report success) and the
  // dialog cannot produce it, but the whole point of the list check was that malformed
  // input should fail READABLY. Doing it here rather than at the two call sites means
  // create and edit cannot drift apart again.
  if (Array.isArray(fees)) {
    for (const f of fees) {
      if (f === null || typeof f !== "object" || Array.isArray(f)) {
        return { err: "Each entry in `fees` must be an object with a service_line_item_id." };
      }
    }
  }
  const want = Array.isArray(fees)
    ? [...new Map(fees.map((f) => [f.service_line_item_id, f])).values()]
    : [];
  const rendered = Array.isArray(renderedIds) ? renderedIds : [];
  // Every submitted fee must have been rendered. Without this, a caller can write a line
  // it never showed the user, and that line is then outside the delete set forever.
  const renderedSet = new Set(rendered);
  for (const f of want) {
    if (!renderedSet.has(f.service_line_item_id)) {
      return { err: `Fee ${f.service_line_item_id} was submitted but not listed as rendered — refusing a line the dialog did not show.` };
    }
  }
  const ids = [...new Set([...want.map((f) => f.service_line_item_id), ...rendered])];
  if (!ids.length) return { lines: [], deletableNames: new Set<string>() };

  const { data: cat } = await db.from("service_line_items")
    .select("id, code, title, reason, schedulable, default_rate_pct").in("id", ids);
  const byId = new Map((cat ?? []).map((c: any) => [c.id, c]));

  // The deletable set is EXACTLY what the caller rendered — see the block comment.
  const deletableNames = new Set<string>();
  for (const id of rendered) {
    const c = byId.get(id);
    if (!c) return { err: `Fee ${id} does not exist.` };
    if (!isFeeReason(c.reason)) return { err: `"${c.title}" is not a fee line, so it cannot be sent as one.` };
    deletableNames.add(String(c.title).trim());
  }

  const lines: { name: string; unitPrice: number; quantity: number }[] = [];
  for (const f of want) {
    const c = byId.get(f.service_line_item_id);
    if (!c) return { err: `Fee ${f.service_line_item_id} does not exist.` };
    if (!isFeeReason(c.reason)) {
      return { err: `"${c.title}" is a service, not a fee — it belongs in the services list.` };
    }
    // Belt-and-braces: 25/26/27 must stay schedulable=false. That flag is what keeps a
    // credit-card fee out of the Calendar's New Visit picker and the vehicle resolution.
    if (c.schedulable) return { err: `"${c.title}" is marked schedulable and cannot be used as a fee.` };

    // Name first: the percent branch needs it to find what this fee is billing today.
    const name = String(c.title).trim();
    // Same prefix assertion the services path makes, and it holds for two-digit codes:
    // Number('25') = 25, so /^0?25\s*-/ matches "25 - Credit card fee (3.53%)".
    if (!new RegExp(`^0?${Number(c.code)}\\s*-`).test(name)) {
      return { err: `Catalog title for code ${c.code} lost its code prefix ("${name}") — tell Fred before saving fees.` };
    }

    let amount: number;
    // ⚠ QUANTITY IS FORCED TO 1 IN PERCENT MODE. `amount` is already the WHOLE fee, so a
    // quantity of 2 would bill 7.06% instead of 3.53% — and quantity is chosen by the
    // client, which must never be able to multiply a computed charge.
    let qty = Number(f.quantity) > 0 ? Number(f.quantity) : 1;
    const billedToday = currentAmounts.get(name);
    if (f.mode === "percent" && billedToday !== undefined && !servicesChanged) {
      // HOLD. This fee is already on the job and the services did not move, so there is
      // nothing to reprice and no money may change.
      amount = billedToday;
      qty = 1;
      // ⚠ The disclosure gate still applies, in the opposite direction. If the dialog
      // displayed a freshly-computed percentage while the server is holding the stored
      // amount, the user is looking at a number that is not what gets billed. The dialog's
      // contract is to show the amount CURRENTLY on the job whenever the services have not
      // changed; this is what makes that contract enforceable rather than aspirational.
      const shownHold = Number(f.expected_unit_price);
      if (Number.isFinite(shownHold) && Math.abs(shownHold - billedToday) >= 0.005) {
        return { err: `"${name}" is billing $${billedToday.toFixed(2)} on this job and the services haven't changed, but the screen showed $${shownHold.toFixed(2)}. Reopen the job so the amount on screen matches what is billed.` };
      }
    } else if (f.mode === "percent") {
      if (c.default_rate_pct == null) {
        return { err: `"${c.title}" has no percentage rate — send a precise amount instead.` };
      }
      if (!(serviceSubtotal > 0)) {
        return { err: `"${c.title}" is a percentage of the services, but this job has no service total to take a percentage of. Enter a precise amount instead, or price the services first.` };
      }
      // rate is in PERCENT UNITS (3.53 = 3.53%), so amount = rate * subtotal / 100.
      // Worked: 3.53 * 650 = 2294.5 -> round 2295 -> 22.95, i.e. 3.53% of $650.
      amount = Math.round(Number(c.default_rate_pct) * serviceSubtotal) / 100;
      qty = 1;
      // 🛑 DISCLOSURE GATE. The dialog must send the amount it showed, and it must match.
      const shown = Number(f.expected_unit_price);
      if (!Number.isFinite(shown)) {
        return { err: `"${c.title}" is a percentage line, so the dialog must send the amount it displayed (expected_unit_price) before it can be saved.` };
      }
      if (Math.abs(shown - amount) >= 0.005) {
        return { err: `"${c.title}" would be saved as $${amount.toFixed(2)} (${c.default_rate_pct}% of $${serviceSubtotal.toFixed(2)}), but the screen showed $${shown.toFixed(2)}. Reopen the job so you can see the current amount before saving.` };
      }
    } else {
      amount = Number(f.unit_price);
      if (!Number.isFinite(amount) || amount < 0) return { err: `"${c.title}" needs a valid amount.` };
      amount = Math.round(amount * 100) / 100;
    }
    lines.push({ name, unitPrice: amount, quantity: qty });
  }
  return { lines, deletableNames };
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
    // FEES AT CREATE — opened up 2026-08-07 (Fred, on being asked to make a Service
    // Agreement while switching a client to Recurring): "it didn't show the Fees line
    // items". It was an edit-only capability from 2026-08-05 to 2026-08-07, which meant
    // the ONE flow that forces a job to be created (Active to Recurring needs a current
    // format SA job) could not put the client's card fee on it, and the fee then had to
    // be added in a second pass nobody was prompted to make.
    // ⚠ Refuse only on an ACTUAL fee. A dialog that shares one patch builder will send
    // `rendered_fee_ids: []` on create too, and refusing that would break job creation
    // entirely with a message about fees the user never touched. A new job has nothing to
    // delete, so a rendered list alone is meaningless here and is simply ignored.
    // 🛑 SERVICE CALL STAYS REFUSED, AND THIS IS THE RULING, NOT AN OVERSIGHT. Fred,
    // 2026-08-06: "the SC shouldn't have any kind of Line Item ... SC can only have line
    // items at the moment of creating a visit." Jobber inherits a job's lines onto every
    // visit it creates, so a fee on an SC JOB silently becomes the default on every
    // future call. Do not re-derive an exception from the mechanism. See index.ts:931.
    // 🛑 SHAPE-VALIDATE BEFORE THE Array.isArray GATES BELOW READ IT. Every fee gate on
    // this path is `Array.isArray(p.fees) && p.fees.length`, so `fees` sent as an OBJECT
    // rather than a list evaluates false at every one of them: the job is created with no
    // fee and the response is `ok: true, fee_lines: []`. A billing miss reported as a
    // success is the one outcome this whole feature exists to prevent, and the edit path
    // already refuses the identical payload ("`fees` must be a list"). Silence here and a
    // refusal there is the asymmetry, not the strictness.
    if (p.fees !== undefined && !Array.isArray(p.fees)) return fail("bad_request", "`fees` must be a list.");
    if (p.rendered_fee_ids !== undefined && !Array.isArray(p.rendered_fee_ids)) {
      return fail("bad_request", "`rendered_fee_ids` must be a list.");
    }
    if (kind !== "SA" && Array.isArray(p.fees) && p.fees.length) {
      return fail("bad_request",
        "A Service Call job carries no line items at all, fees included. Everything it charges goes on the visit when the visit is created.");
    }
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

    // ---- FEES, resolved AFTER the services and kept OUT of them ---------------
    // 🛑 `title` is already fixed above, from `lines` ALONE. That ordering is
    // load-bearing, not incidental: saTitle() runs on the emitted set, and
    // fn_generate_sa_visits copies the job title onto every visit it mints, so a fee
    // reaching saTitle() would print "& Credit card fee (3.53%)" on the crew's Calendar
    // and on the client's Field Portal. Never move this block above the title.
    let createFeeLines: { name: string; unitPrice: number; quantity: number }[] = [];
    if (kind === "SA" && Array.isArray(p.fees) && p.fees.length) {
      // Same both-keys-or-neither contract the edit path enforces. It buys less here
      // (a new job has nothing to delete, so `rendered_fee_ids` is not acting as the
      // delete authority) but resolveFees still refuses a fee that was not rendered,
      // which is what stops a caller writing a line it never showed anyone.
      if (!Array.isArray(p.rendered_fee_ids)) {
        return fail("bad_request",
          "Fees must arrive with `rendered_fee_ids` listing every fee the dialog put on screen.");
      }
      // The percent base is the services in THIS payload; there is no prior job to read.
      const subtotal = lines.reduce((s, l) => s + l.unitPrice * l.quantity, 0);
      // `servicesChanged = true` and an EMPTY currentAmounts are both correct and both
      // deliberate: on a brand new job every service is new, so there is no stored amount
      // to hold and the "only reprice when the services actually changed" hold-branch is
      // unreachable by construction. The disclosure gate still applies in full, so a
      // percent fee must still send the amount the dialog displayed.
      const rf = await resolveFees(p.fees as FeeReq[], p.rendered_fee_ids as number[],
                                   subtotal, true, new Map<string, number>());
      if (rf.err) return fail("bad_request", rf.err);
      createFeeLines = rf.lines!;
    }
    // Everything that must land in Jobber, services first. The VERIFY below counts this,
    // not `lines`: counting services alone would pass while a fee silently failed to land,
    // which is the same shape as the 2026-08-01 loss.
    const allLines = [...lines, ...createFeeLines];

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
    if (allLines.length) {
      input.lineItems = allLines.map((l) => ({ ...l, saveToProductsAndServices: false }));
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
        (allLines.length && (job.lineItems?.nodes ?? []).length !== allLines.length)) {
      return fail("verify_failed",
        "Jobber created the job but it doesn't match what was sent — check it in Jobber before retrying.",
        { jobber_number: job.jobNumber });
    }
    // ⚠ The count above is a CARDINALITY check and cannot see a substitution at the same
    // count. The edit path asserts every wanted line by NAME (see the verify block near the
    // end of this file), so without this the newer path carried the weaker of the two
    // checks for the same class of failure. Assert names here too, fees included: a fee
    // that quietly does not land is a billing miss, which is the whole reason the fee lines
    // were added to the count in the first place.
    {
      const landed = new Set((job.lineItems?.nodes ?? []).map((n: any) => String(n.name)));
      for (const l of allLines) {
        if (!landed.has(l.name)) {
          return fail("verify_failed",
            `Jobber created the job but "${l.name}" is not on it — check it in Jobber before retrying.`,
            { jobber_number: job.jobNumber });
        }
      }
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
      fee_lines: createFeeLines.map((l) => ({ name: l.name, unit_price: l.unitPrice, quantity: l.quantity })),
      // See the block on the edit path's copy of this flag. An SA created WITH a start
      // date is the other moment visits become schedulable, so it carries the flag too:
      // without it, removing the "Generate visits" button would mean a brand new dated
      // agreement sat unscheduled until the 06:00 ET sweep.
      start_date_first_set: kind === "SA" && hasStart,
    });
  }

  // ---- shared resolution for edit/close/reopen -----------------------------
  const jobId = Number(body.job_id);
  if (!Number.isFinite(jobId)) return fail("bad_request", "job_id is required.");
  const { data: jobRow } = await db.from("jobs").select("id, client_id, property_id, title, frequency_days, start_at").eq("id", jobId).maybeSingle();
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

  // ---- approval-proof images for a frequency change -------------------------
  // Design: docs/superpowers/specs/2026-08-17-frequency-change-proof-upload-design.md
  // Validated HERE, before Jobber is touched, because a rejection after Jobber has committed
  // cannot be rolled back. The upload itself happens far below, only once the change row exists.
  // ⚠ Caps are enforced server-side as well as in the browser. The bucket also refuses >5MB, but
  //   relying on that would mean discovering the problem after Jobber was already written.
  const PROOF_MAX = 3;
  const PROOF_MAX_BYTES = 2_500_000;              // decoded; ~2MB after the client's re-encode
  type ProofIn = { file_name: string; content_type: string; data_base64: string };
  const proofRaw = Array.isArray(body.frequency_proof) ? body.frequency_proof : [];
  if (proofRaw.length > PROOF_MAX) {
    return fail("bad_request", `Attach at most ${PROOF_MAX} images as proof.`, { field: "frequency_proof" });
  }
  const proofIn: ProofIn[] = [];
  for (const raw of proofRaw) {
    const ct = String(raw?.content_type ?? "").toLowerCase();
    // Mirrors the bucket's allowed_mime_types. ⚠ A mime allow-list does NOT cover EXIF — the
    // browser re-encodes through a canvas to strip it, which is why only JPEG/PNG arrive here.
    if (ct !== "image/jpeg" && ct !== "image/png") {
      return fail("bad_request", "Proof images must be JPEG or PNG.", { field: "frequency_proof" });
    }
    const b64 = String(raw?.data_base64 ?? "").replace(/^data:[^;]+;base64,/, "");
    if (!b64) return fail("bad_request", "A proof image arrived empty.", { field: "frequency_proof" });
    // 4 base64 chars -> 3 bytes; cheap size check without decoding first.
    if (Math.floor(b64.length * 3 / 4) > PROOF_MAX_BYTES) {
      return fail("bad_request", "That image is too large even after compression. Try a screenshot rather than a photo.",
        { field: "frequency_proof" });
    }
    proofIn.push({
      file_name: String(raw?.file_name ?? "proof").slice(0, 120),
      content_type: ct,
      data_base64: b64,
    });
  }

  // Pre-flight EVERYTHING before the first mutation (the half-applied lesson).
  const edit: Record<string, unknown> = {};
  // 🛑 THE MOMENT AN AGREEMENT BECOMES SCHEDULABLE, and the reason the "Generate visits"
  // button could be dropped (Fred, 2026-08-07): "if we have a [job] that doesn't have a
  // Start Date, then when we add the start date it's like that generate button and
  // generates the visit ... That means we won't need the button Generate Visits."
  // A dateless SA with no visits is the ONE case fn_generate_sa_visits deliberately skips
  // ('no start date and no visits yet'), so the transition from no-date to date is exactly
  // when generation becomes possible. The flag is computed here and returned; the app runs
  // client.generate_visits_for_client, which is staff-gated, per-client and INSERT-only.
  // ⚠ Read from OUR MIRROR on purpose. It is what the dialog showed the user, and its two
  // failure modes are asymmetric: a false positive costs one wasted call that returns
  // "nothing to schedule" (generation is INSERT-only and dedupes within 7 days), while a
  // false negative cannot happen, because jobs.start_at is only ever written from a
  // verified Jobber read-back.
  let startDateFirstSet = false;
  if (p.start_date !== undefined || p.end_date !== undefined) {
    if (!isSA) return fail("bad_request", "Service Calls are on-demand and carry no dates — schedule the visit instead.");
    const sd = String(p.start_date ?? "");
    if (!/^\d{4}-\d{2}-\d{2}$/.test(sd)) return fail("bad_request", "A valid start date is required to change dates.");
    startDateFirstSet = !jobRow.start_at;
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
  // WHY A CADENCE CHANGE CARRIES A REASON (Fred, 2026-08-07): "When changing a Job
  // frequency we also need a reason for it, same as we ask for a reason when changing the
  // client status." Recorded in public.job_frequency_changes, the sibling of
  // public.client_status_changes (migration 2026-08-07_1235).
  // ⚠ public.jobs IS audited, so the VALUE change is already in audit.logs. What is being
  // captured here is the sentence a human typed, which no audit trigger can produce.
  // 🛑 THIS IS PERMISSIVE IN THIS DEPLOY AND DEMANDING IN THE NEXT ONE, ON PURPOSE.
  // docs/09-known-issues.md 0g: client.update_client_status's required third argument
  // shipped ahead of the UI that supplies it and broke every status change in the live app
  // for hours. So deploy A records a reason when one arrives and never asks for one;
  // the Lovable dialog then learns to ask; only then does deploy B turn the demand on.
  // The demand lives at the marker DEPLOY-B-FREQ-REASON below.
  let freqReason: string | null = null;
  let oldFreqForLog: number | null = null;
  if (p.frequency_days !== undefined) {
    if (!isSA) return fail("bad_request", "Frequency only applies to Service Agreements.");
    newFreq = Number(p.frequency_days);
    if (!Number.isFinite(newFreq) || newFreq < 1 || newFreq > 365) {
      return fail("bad_request", "Frequency must be between 1 and 365 days.");
    }
    // 🛑 `Number(null)` is 0, and `Number.isFinite(0)` is true, so writing this as
    //    Number.isFinite(Number(x)) ? Number(x) : null
    // makes the null branch DEAD and records old_frequency_days = 0 for a job that had
    // no cadence on record. That is a lie with a plausible face, because 0 is a real
    // live value on an SA job (all 23 Warranty-of-Drainage jobs carry it), so "was 0,
    // now 90" and "had none, now 90" become indistinguishable in the history.
    // Test it against null explicitly. Currently latent (0 of 176 non-archived SA jobs
    // hold a NULL frequency; the 347 that do are all archived), which is exactly why it
    // would have sat here unnoticed.
    const prevFreq = jobRow.frequency_days === null || jobRow.frequency_days === undefined
      ? null
      : (Number.isFinite(Number(jobRow.frequency_days)) ? Number(jobRow.frequency_days) : null);
    // Only an ACTUAL change is a change. Demanding a reason when the dialog resubmits the
    // same number would make every unrelated save impossible, and would fill the table
    // with rows recording that nothing happened (the DB constraint refuses those anyway).
    if (prevFreq !== newFreq) {
      oldFreqForLog = prevFreq;
      const r = String(p.frequency_reason ?? "").trim();
      // DEPLOY-B-FREQ-REASON: ON as of 2026-08-07, and only after the published bundle was
      // read to prove the dialog cannot send one without the other. The live chunk reads
      //   k !== ie.frequency && me && (m.frequency_days = ue, m.frequency_reason = O.trim())
      // so an empty reason means NEITHER key is sent and this branch is never reached from
      // the app at all. That check is what makes turning the refusal on safe rather than a
      // repeat of 0g; "the UI was asked to send it" would not have been.
      // 🛑 PROOF, NOT PROSE (Yannick, 2026-08-17): "in red its not about putting a few words
      // its about proof that it was approved, so we need the slack link OR a screenshot of
      // whatsapp". A 3-character floor accepted "ok" — a record that something was TYPED, not a
      // record that anyone APPROVED. The requirement is a LINK to the approval.
      //
      // ⚠ DEPLOY ORDER, AND THIS FILE ALREADY PAID FOR THE LESSON ONCE (see the
      // DEPLOY-B-FREQ-REASON note above, and known-issue 0g). This refusal was tightened only
      // AFTER the published bundle was read and proven to block a linkless save:
      //     $e = ke && !/https?:\/\/\S+/.test(reason)      // ke = frequency actually changed
      //     Be = p ? (… && !$e && …) : He                  // !$e is IN the submit-ready flag
      // so the dialog cannot send frequency_days with a linkless reason. Turning this on first
      // would have failed every frequency save from the then-current bundle.
      //
      // ⚠ ANY http(s) URL is accepted, not slack.com only. Over-narrowing would block a real
      // save with no workaround while screenshot upload is still deferred (Fred, same thread:
      // "when we need to save pictures in our DB, it needs to have a structure for it"), and the
      // approval may legitimately be linked from somewhere other than Slack.
      // 🛑 A LINK IS NOT REQUIRED. Fred, 2026-08-17, correcting my over-reading of Yannick's
      // "we need the slack link OR a screenshot of whatsapp":
      //   "Whatsapp is just an example, he meant any kind of image as proof … we can support that
      //    claim using a photo or the whole claim could be the photo … but something must be
      //    required, either they put a photo, or a text (message or link or anything)"
      // So the rule is AT LEAST ONE OF {text, image}, and the text may be a message, a link, or
      // anything. I had briefly made an http(s) URL mandatory, which blocked every cadence change
      // whose approval lived somewhere unlinkable — the exact case the image half exists to cover.
      //
      // ⚠ 10 rather than the original 3: Fred asked for "a real reason, not 3 characters of
      // anything", so "ok" / "n/a" / "yes" are still refused. Tunable; it is a lint, not a policy.
      // ⚠ RELAXING inverts the deploy order that TIGHTENING needed. This server change ships FIRST,
      // because a server that accepts more than the UI sends is always safe, whereas relaxing the UI
      // first would send text the server still refused. The tightening note above is the mirror case.
      // ⚠ When image upload lands, this becomes (text OK) || (>=1 image linked) — and the image arm
      // MUST be checked server-side too, or the requirement is only a UI suggestion.
      // 🛑 THE RULE IS (TEXT >= 10) || (>= 1 IMAGE), AND THE IMAGE ARM IS ENFORCED HERE.
      // Fred: "something must be required, either they put a photo, or a text (message or link or
      // anything)". If only the browser checked the image arm, the requirement would be a UI
      // suggestion — the same class of gap as every client-side-only validation in this repo.
      // ⚠ Read from body, NOT from the patch: the patch is diffed against Jobber field-groups, and a
      // base64 blob in there would be treated as a job attribute to push.
      if (r.length < 10 && proofIn.length === 0) {
        return fail("reason_required",
          "Give a real reason for the cadence change, or attach proof. A couple of characters is not a record.",
          { field: "frequency_reason" });
      }
      // 🛑 AN IMAGE-ONLY SAVE STILL NEEDS REASON TEXT, BECAUSE THE COLUMN DEMANDS IT.
      // public.job_frequency_changes.reason is NOT NULL with
      //   CHECK (reason ~ '[[:alnum:]]')            -- job_frequency_changes_reason_not_blank
      // so "" fails it. That insert runs AFTER Jobber is already committed, so the failure could not
      // be rolled back: the cadence would change in Jobber and be recorded nowhere, with only
      // frequency_reason_recorded:false to show for it. Found by reading the constraint rather than
      // by hitting it in production.
      // Fred's rule allows the photo to BE the whole claim ("the whole claim could be the photo"), so
      // the stored sentence points at the image instead of pretending to be a justification.
      // ⚠ Do NOT "simplify" this by relaxing the CHECK: a blank reason column would make every
      //   historical row's meaning ambiguous, and the CHECK is what keeps that table readable.
      freqReason = r.length > 0 ? r : "Approval proof attached as an image; see the attached file.";
    }
    edit.customFields = [{ customFieldConfigurationId: FREQ_CF_GID, valueNumeric: newFreq }];
  }
  let wantLines: { name: string; unitPrice: number; quantity: number }[] | null = null;
  // Lines found on the job that this call did not manage at all — returned to the UI.
  let preserved: string[] = [];
  // Every current line this call did NOT decide to delete. This is the regression
  // alarm asserted in the verify block; see the toDelete comment below for why it is
  // no longer the inverse of a regex.
  let survivors: string[] = [];
  // Resolved fee lines, hoisted so the verify block can assert they actually landed —
  // the same assertion the service lines get. A fee that silently fails to land is a
  // billing miss, so it does not get a weaker check than a service.
  let feeLinesForVerify: { name: string; unitPrice: number; quantity: number }[] = [];
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
  // FEES — parsed here, RESOLVED later inside the line-item block, because the
  // percent base needs the live Jobber read (a fee may be edited without touching
  // the services, in which case the subtotal comes from what is on the job now).
  // ⚠ `fees` and `rendered_fee_ids` are read INDEPENDENTLY of `services`, so a
  // fee-only edit works and does not drag the service diff along with it.
  let feeReq: { fees: FeeReq[]; rendered: number[] } | null = null;
  // 🛑 GATE ON THE PAYLOAD, NOT ON KEY PRESENCE. A dialog that shares one patch builder
  // sends `fees: []` and `rendered_fee_ids: []` on EVERY save, including Service Calls.
  // Keying on presence made that a "fee request", which then hit the SA-only refusal and
  // broke editing on all 270 live non-SA jobs (measured) — and on SA jobs it dragged two
  // extra Jobber reads and the stale-view refusal into saves that touch no fee at all,
  // while making the `no_changes` short-circuit unreachable. Empty-and-empty is a no-op.
  // ⚠ `fees: []` with a NON-empty rendered list is NOT a no-op: it means "remove them all".
  const feeKeysPresent = p.fees !== undefined || p.rendered_fee_ids !== undefined;
  const feeWorkRequested = feeKeysPresent &&
    (((Array.isArray(p.fees) ? p.fees.length : 0) > 0) ||
     ((Array.isArray(p.rendered_fee_ids) ? p.rendered_fee_ids.length : 0) > 0));
  if (feeKeysPresent && !feeWorkRequested) {
    // Shape-validate anyway so a malformed key still fails loudly rather than silently.
    if (p.fees !== undefined && !Array.isArray(p.fees)) return fail("bad_request", "`fees` must be a list.");
    if (p.rendered_fee_ids !== undefined && !Array.isArray(p.rendered_fee_ids)) {
      return fail("bad_request", "`rendered_fee_ids` must be a list.");
    }
  }
  if (feeWorkRequested) {
    // 🛑 A SERVICE CALL JOB CARRIES NO JOB-LEVEL LINE ITEMS AT ALL — NOT EVEN FEES.
    //
    // Fred, 2026-08-06, correcting me: "the SC shouldn't have any kind of Line Item … SC can
    // only have line items at the moment of creating a visit. Because it's for the visit."
    //
    // THE MECHANISM (also Fred): "if you add line items on a job, every visit will have for
    // default those line items, and we don't want that on the SC jobs, it's ok on the SA
    // though." Jobber INHERITS a job's line items onto every visit it creates. For a Service
    // Agreement that is the point — the agreed services repeat. For a Service Call every visit
    // is different work, so EVERYTHING it charges, fees included, is attached when the VISIT
    // is created.
    //
    // ⚠ I BUILT SC FEE SUPPORT ON 2026-08-06 AND IT WAS WRONG. Fred had told me the mechanism
    // and separately said an SC fee "bills once per visit"; I inferred that a job-level fee was
    // a wanted exception because it would ride every call. It is not an exception — the fee
    // bills per visit BECAUSE IT GOES ON THE VISIT. That inference was mine, never his.
    // ⇒ Do not re-derive this from the mechanism. A fee on an SC JOB is wrong even though it
    //   would "work", because it silently defaults onto every future visit of that job.
    if (!isSA) {
      return fail("bad_request", "A Service Call job carries no line items — its charges, fees included, go on the visit when the visit is created.");
    }
    // 🛑 BOTH KEYS OR NEITHER — same doctrine as the billing pair below, and for a worse
    // reason. The two carry OPPOSITE conventions: `rendered_fee_ids` is a statement of
    // fact ("I showed these"), `fees` is a desired end state ("keep exactly these"). If
    // `rendered_fee_ids` arrived alone, `fees ?? []` would read as "keep none" and EVERY
    // rendered fee would be deleted — the 2026-08-01 loss reintroduced through a new key,
    // and invisible because `survivors` and `preserved` both exclude those lines by
    // construction. A dialog that omits `fees` when no fee changed is the normal shape of
    // this file's own "only the provided groups are touched" contract, so this is a
    // likely payload, not an exotic one.
    if ((p.fees === undefined) !== (p.rendered_fee_ids === undefined)) {
      return fail("bad_request", "Send `fees` and `rendered_fee_ids` together — one without the other cannot say whether a missing fee means 'remove it' or 'I never saw it'.");
    }
    if (!Array.isArray(p.fees)) return fail("bad_request", "`fees` must be a list.");
    if (!Array.isArray(p.rendered_fee_ids)) return fail("bad_request", "`rendered_fee_ids` must be a list.");
    feeReq = { fees: p.fees as FeeReq[], rendered: p.rendered_fee_ids as number[] };
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

  // ⚠ JOBBER'S RULE, learned from a real userError on the first live custom-schedule
  // save (2026-08-03): "If invoicing recurrence is informed, startAt is required."
  // A job cannot carry a recurring invoice schedule unless it HAS a start date.
  // Confirmed read-only across all 444 live jobs, with no counterexample:
  //   recurrence + startAt = 27,  recurrence + NO startAt = 0
  // and 252 of those 444 have no startAt at all, so this is the majority case rather
  // than an edge one. Checked BEFORE the mutation, and against JOBBER rather than our
  // own jobs.start_at, because a stale local NULL would refuse a perfectly good save
  // (and a stale local date would let a doomed one through). Costs one read, and only
  // when a recurrence is being set without a date in the same patch.
  if ((edit.invoicing as Record<string, unknown> | undefined)?.recurrence && edit.timeframe === undefined) {
    const cur = await gql(token, Q_JOB, { id: jobGid });
    if (!cur.ok) {
      return fail("jobber_no_answer", "Couldn't reach Jobber to check the job's start date. Nothing was changed.");
    }
    if (!cur.data.job?.startAt) {
      // 🛑 The consequence sentence here was WRONG in its first version and is corrected,
      // because it would have scared a user off a safe edit. It said setting a start date
      // "lets the Calendar start generating this agreement's visits", full stop. Read
      // fn_generate_sa_visits: a dateless job is skipped ONLY when it ALSO has no visits
      //   delete from _sa_jobs where start_at is null and n_visits = 0;
      // and its own skip reason says so: 'no start date and no visits yet'. start_at is
      // merely the THIRD anchor choice, behind max_future then last_completed. So for a
      // job that already has visits, generation is already running and a start date
      // changes nothing about it. Measured on job 645: start_at NULL, yet 23 of its 24
      // visits were generated by supabase_cron, scheduled out to 2027-02-21.
      const hasVisits = Number(
        (await db.from("visits").select("id", { count: "exact", head: true })
          .eq("job_id", jobId).is("deleted_at", null)).count ?? 0,
      ) > 0;
      return fail("start_date_required",
        hasVisits
          ? "Jobber won't put a job on an invoice schedule until the job has a start date. Set this agreement's start date, then choose the schedule again. This job already has visits, so its Calendar schedule won't change."
          : "Jobber won't put a job on an invoice schedule until the job has a start date. Set this agreement's start date, then choose the schedule again. This job has no visits yet, so setting a start date will also let the Calendar begin generating them.");
    }
  }

  if (Object.keys(edit).length === 0 && wantLines === null && feeReq === null) {
    return done({ job_id: jobId, no_changes: true });
  }

  // ── FEE PREFLIGHT: everything that can say "no" runs BEFORE any Jobber mutation.
  // 🛑 A `bad_request` raised AFTER step 1 leaves Jobber holding the new frequency or
  // invoice schedule while `public.jobs` keeps the old one, `fn_record_client_job` never
  // runs, and the user is shown a validation error implying nothing saved. Those columns
  // are "last confirmed by us" and the drift reconciler does not compare them, so the
  // divergence is PERMANENT and the job half-applies again on every retry. Two live jobs
  // sit in exactly that shape today: 1369 (carries a duplicate fee line) and 1589 (a real
  // SA job with a $0.00 service subtotal and a fee), so this is measured, not theoretical.
  let feeLines: { name: string; unitPrice: number; quantity: number }[] = [];
  let deletableFeeNames = new Set<string>();
  let preLines: any[] = [];
  if (feeReq !== null) {
    const pre = await gql(token, Q_JOB, { id: jobGid });
    if (!pre.ok) {
      return fail("jobber_no_answer", "Jobber didn't answer while reading this job's line items. Nothing was changed.");
    }
    preLines = pre.data.job?.lineItems?.nodes ?? [];

    // ⚠ STALE-VIEW GUARD — the one thing `rendered_fee_ids` CANNOT do.
    // The dialog derives its checked state from OUR MIRROR, and the only refresh path is
    // pg_cron `jobber-job-drift-reconcile` at `15,45 * * * *` (verified; the */5 poll
    // touches no line items). So the mirror runs up to 30 minutes behind Jobber. Every one
    // of the existing fee lines was created by a human in Jobber's UI, which makes "a fee
    // added in Jobber a few minutes ago" the NORMAL case: it renders unchecked, and an
    // unchecked box would otherwise be read as "remove it". Comparing the two sides is
    // what distinguishes "the user unchecked this" from "the user was never shown it".
    // The code pattern here is a DETECTION heuristic only — it never decides a delete.
    // ⚠ COMPARE NAME **AND MONEY**, not membership. A membership-only check misses a price
    // corrected in Jobber inside the 30-minute window: the dialog still shows the old
    // amount, `toEdit` sees a difference and pushes the stale figure straight back, undoing
    // the correction silently. Code 27 is amount-mode only, so this is its ONLY protection.
    const looksLikeFee = (n: unknown) => /^\s*2[567]\s*-/.test(String(n ?? ""));
    const money = (v: unknown) => Number(v ?? 0).toFixed(2);
    const bag = (name: unknown, price: unknown, qty: unknown) =>
      `${String(name)}|${money(price)}|${money(qty)}`;
    const { data: mirrorRows, error: mirrorErr } = await db.from("line_items")
      .select("name, unit_price, quantity").eq("job_id", jobId).is("invoice_id", null);
    // A failed read returns an empty set — exactly the shape this guard exists to detect —
    // so it must be an error, never a silent pass.
    if (mirrorErr) {
      return fail("db_read_failed", "Couldn't check this job's fees against our records. Nothing was changed — try again.");
    }
    const jobberFees = new Set(preLines.filter((n: any) => looksLikeFee(n.name))
      .map((n: any) => bag(n.name, n.unitPrice, n.quantity)));
    const mirrorFees = new Set((mirrorRows ?? []).filter((r: any) => looksLikeFee(r.name))
      .map((r: any) => bag(r.name, r.unit_price, r.quantity)));
    const inSync = jobberFees.size === mirrorFees.size && [...jobberFees].every((n) => mirrorFees.has(n));
    if (!inSync) {
      return fail("stale_view", "This job's fees changed in Jobber since this dialog was opened, so what you're looking at is out of date. Close the job, reopen it, and make the change again.");
    }

    // Percent base: the services being SAVED when they are part of this edit, otherwise
    // the service lines currently on the job. Never the Jobber job total, which already
    // includes the fees themselves.
    const serviceSubtotal = wantLines !== null
      ? wantLines.reduce((a, l) => a + l.unitPrice * l.quantity, 0)
      : preLines.filter((n: any) => /^\s*0[1-8]\s*-/.test(String(n.name ?? "")))
          .reduce((a: number, n: any) => a + Number(n.unitPrice ?? 0) * Number(n.quantity ?? 0), 0);

    // Did the SERVICES actually move? Compare name+price+qty, not just membership, so a
    // price-only change still counts. `wantLines === null` means the services were not part
    // of this patch at all, which is by definition no change.
    const svcBag = (n: unknown, p: unknown, q: unknown) =>
      `${String(n)}|${Number(p ?? 0).toFixed(2)}|${Number(q ?? 0).toFixed(2)}`;
    const curSvc = new Set(preLines
      .filter((n: any) => /^\s*0[1-8]\s*-/.test(String(n.name ?? "")))
      .map((n: any) => svcBag(n.name, n.unitPrice, n.quantity)));
    const wantSvc = new Set((wantLines ?? []).map((l) => svcBag(l.name, l.unitPrice, l.quantity)));
    const servicesChanged = wantLines !== null &&
      (curSvc.size !== wantSvc.size || [...wantSvc].some((b) => !curSvc.has(b)));

    // What each fee bills TODAY, so an untouched percent fee can be held at its current
    // amount rather than recomputed.
    const currentAmounts = new Map<string, number>(
      preLines.map((n: any) => [String(n.name), Number(n.unitPrice ?? 0)]),
    );

    const rf = await resolveFees(feeReq.fees, feeReq.rendered, serviceSubtotal, servicesChanged, currentAmounts);
    if (rf.err) return fail("bad_request", rf.err);
    feeLines = rf.lines!;
    feeLinesForVerify = feeLines;
    deletableFeeNames = rf.deletableNames!;

    // ⚠ Guard over the UNION of rendered and submitted names. Checking only the rendered
    // set let a payload that submits a fee it never rendered slip past — and on job 1369
    // that silently doubles the card fee by editing one of two identical rows.
    for (const nm of new Set([...deletableFeeNames, ...feeLines.map((l) => l.name)])) {
      if (preLines.filter((n: any) => String(n.name) === nm).length > 1) {
        return fail("bad_request",
          `This job carries "${nm}" more than once in Jobber. Remove the duplicate there first — saving from here would merge them and change what the client is billed.`);
      }
    }
  }

  // 1. scalar groups in ONE jobEdit
  if (Object.keys(edit).length) {
    const res = await gql(token, M_EDIT, { jobId: jobGid, input: edit });
    if (!res.ok) return fail("jobber_rejected", `Jobber refused the edit: ${res.detail}`, { applied, start_date_first_set: startDateFirstSet });
    const uerr = ue(res.data.jobEdit);
    if (uerr) return fail("jobber_rejected", `Jobber refused the edit: ${uerr}`, { applied, start_date_first_set: startDateFirstSet });
    applied.push(...Object.keys(edit).map((k) =>
      k === "customFields" ? "frequency"
      : k === "timeframe" ? "dates"
      : k === "invoicing" ? "billing"
      : k));
  }

  // 2. line items: create-first, edit by Jobber id, delete LAST (never a
  //    zero-line window — the $0-invoice lesson).
  if (wantLines !== null || feeReq !== null) {
    const cur = await gql(token, Q_JOB, { id: jobGid });
    if (!cur.ok) return fail("jobber_no_answer", "Jobber didn't answer while reading line items.", { applied, failed: "line items" });
    const curLines: any[] = cur.data.job?.lineItems?.nodes ?? [];
    const curByName = new Map(curLines.map((n) => [n.name, n]));
    // 🛑 UNCHANGED, and the service half of the delete predicate below still depends
    // on it being exactly the inverse of what resolveServices() can emit.
    const isServiceLine = (name: unknown) => /^\s*0[1-8]\s*-/.test(String(name ?? ""));

    // Fees were resolved and fully validated in the PREFLIGHT above, before any Jobber
    // mutation. Nothing here may reject — from this point a failure is `partial_push`.
    const wantAll = [...(wantLines ?? []), ...feeLines];
    const wantByName = new Map(wantAll.map((l) => [l.name, l]));
    const toCreate = wantAll.filter((l) => !curByName.has(l.name));
    const toEdit = wantAll.filter((l) => {
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
    //
    // 2026-08-05: fees became deletable too, but ONLY the ones the caller rendered —
    // `deletableFeeNames` is built from `rendered_fee_ids`, never from a code pattern.
    // A caller that renders no fees (an old or cached bundle) therefore deletes no fees.
    // ⚠ THE SERVICE HALF IS GATED ON `wantLines !== null`: a fee-only edit must never
    // delete a service line just because it was not resubmitted.
    const toDelete = curLines.filter((n) =>
      ((wantLines !== null && isServiceLine(n.name)) || deletableFeeNames.has(String(n.name)))
      && !wantByName.has(n.name));
    // 🛑 SURVIVORS is the regression alarm, and it is computed from the delete decision
    // ACTUALLY TAKEN rather than as the complement of a regex. The old `preserved` was
    // the literal inverse of the delete predicate, so widening the predicate would have
    // silently shrunk the alarm at the same moment it needed to be loudest — 165 of the
    // 175 non-service job lines are exactly the codes now being made deletable.
    const deleteIds = new Set(toDelete.map((n) => String(n.id)));
    survivors = curLines.filter((n) => !deleteIds.has(String(n.id))).map((n) => String(n.name));
    // `preserved` = the non-service lines this call is LEAVING ALONE, and it is still the
    // rule-2c alarm, so it must not go vacuous. Filtering out every rendered fee would have
    // emptied it on precisely the saves it exists to watch: measured, 114 of the 114
    // non-service lines on live SA jobs are fee codes. Excluding only the fees actually
    // being REMOVED keeps it non-empty and, unlike `survivors`, keeps it derived from
    // INTENT rather than from the delete decision — so it can still contradict a wrong one.
    preserved = curLines
      .filter((n) => !isServiceLine(n.name) &&
        !(deletableFeeNames.has(String(n.name)) && !wantByName.has(n.name)))
      .map((n) => String(n.name));
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
  if (!ver.ok) return fail("verify_failed", "Saved in Jobber but the verification read failed — check Jobber.", { applied, start_date_first_set: startDateFirstSet });
  const j = ver.data.job;
  if (edit.timeframe && etDate(j.startAt) !== (edit.timeframe as any).startAt) {
    return fail("verify_failed", "Jobber accepted the date change but reads back a different date — check Jobber.", { applied, start_date_first_set: startDateFirstSet });
  }
  if (edit.instructions !== undefined && (j.instructions ?? "") !== edit.instructions) {
    return fail("verify_failed", "Jobber accepted the instructions but reads back different text — check Jobber.", { applied, start_date_first_set: startDateFirstSet });
  }
  if (edit.title !== undefined && j.title !== edit.title) {
    return fail("verify_failed", "Jobber accepted the services but the job title reads back differently — check Jobber.", { applied, start_date_first_set: startDateFirstSet });
  }
  if (bill) {
    const wantType = bill.billing_type === "fixed" ? "FIXED_PRICE" : "VISIT_BASED";
    if (String(j.billingType).toUpperCase() !== wantType) {
      return fail("verify_failed",
        `Jobber accepted the edit but the billing type reads back as ${j.billingType}, not ${wantType} — check it in Jobber.`,
        { applied, start_date_first_set: startDateFirstSet });
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
        { applied, start_date_first_set: startDateFirstSet });
    }
    // And assert the RULE ITSELF landed — the interval, the day, the weekdays. This
    // compares against recurrenceSchedule.calendarRule, which is the rule verbatim,
    // so a silently-coerced day or a dropped BYDAY fails loudly for EVERY shape
    // (weekly and nth-weekday included, which the old summary matcher could not check).
    const rmm = rruleMismatch(bill.invoice_rrule, j.invoiceSchedule?.recurrenceSchedule?.calendarRule);
    if (rmm) {
      return fail("verify_failed",
        `Jobber accepted the edit but stored a different invoice schedule (${rmm}). Its summary reads "${j.invoiceSchedule?.scheduleSummary ?? "?"}" — check it in Jobber.`,
        { applied, start_date_first_set: startDateFirstSet });
    }
  }
  // ⚠ THE CHECK WHOSE ABSENCE HID THE BUG. The old verify only asserted that
  // the WANTED lines landed, so deleting a fee line passed verification
  // cleanly. Assert the non-service lines we chose not to touch are still on
  // the job, so any future widening of `toDelete` fails loudly instead of
  // quietly costing money.
  // Two assertions, deliberately not one. `preserved` is derived from INTENT (what this
  // call meant to leave alone) and `survivors` from the DELETE DECISION actually taken.
  // Only the first can contradict a wrong decision; only the second catches a third-party
  // delete between the two reads. Rule 2c's alarm is the first one.
  if (preserved.length || survivors.length) {
    const names = new Set((j.lineItems?.nodes ?? []).map((n: any) => String(n.name)));
    const lost = [...new Set([...preserved, ...survivors])].filter((n) => !names.has(n));
    if (lost.length) {
      return fail("verify_failed",
        `Saved, but these line items are no longer on the Jobber job: ${lost.join(", ")}. Check the job in Jobber before editing it again.`,
        { applied, start_date_first_set: startDateFirstSet });
    }
  }
  if (wantLines !== null || feeLinesForVerify.length) {
    const names = new Set((j.lineItems?.nodes ?? []).map((n: any) => n.name));
    for (const l of [...(wantLines ?? []), ...feeLinesForVerify]) {
      if (!names.has(l.name)) return fail("verify_failed", `Line item "${l.name}" did not land in Jobber — check Jobber.`, { applied, start_date_first_set: startDateFirstSet });
    }
  }

  // 4. only now, our DB — from the READ-BACK, not from the patch.
  // `bill` is passed so billing_type / invoice_frequency / invoice_rrule are
  // persisted (they were previously never stored, which is why the dialog could
  // not show a job's real billing); it is undefined when billing was not part of
  // this edit, and fn_record_client_job is key-presence-aware, so the stored
  // values are then left alone rather than wiped.
  // 🛑 `includeLines` MUST cover a fee-only edit, and this is not cosmetic. The dialog
  // derives its checked state by joining the job's lines FROM OUR DB MIRROR against the
  // catalogue. If a fee is pushed to Jobber but not mirrored locally, the picker renders
  // that fee UNCHECKED, the next save reports it as rendered-and-not-submitted, and the
  // delete path removes a fee the user never touched. Mirroring it closes that loop.
  // Gated on isSA again: only a Service Agreement carries job-level line items at all, so only
  // an SA edit has any to mirror. `feeReq` can no longer be non-null on a non-SA job — the fee
  // branch above refuses those outright.
  const rec = jobToRecord(clientId, jobRow.property_id, j, isSA && (wantLines !== null || feeReq !== null), newFreq, bill ?? undefined);
  const { error: recErr } = await db.rpc("fn_record_client_job", { p: rec });
  if (recErr) {
    return fail("db_write_failed", "Saved and verified in Jobber but the local write failed; the 30-minute sync will settle it.", { applied, start_date_first_set: startDateFirstSet });
  }
  // 5. the cadence reason, LAST, and deliberately non-fatal.
  // Jobber already holds the new frequency and it has been read back and verified, so a
  // failure here cannot un-save anything. Reporting failure would be a lie about what
  // happened to the job. But it is not swallowed either: `frequency_reason_recorded`
  // comes back false and the UI can say the change went through while its note did not.
  let freqReasonRecorded: boolean | null = null;
  let freqChangeId: number | null = null;
  if (freqReason !== null && newFreq !== undefined) {
    const { data: fcRow, error: fcErr } = await db.from("job_frequency_changes").insert({
      job_id: jobId,
      client_id: clientId,
      old_frequency_days: oldFreqForLog,
      new_frequency_days: newFreq,
      reason: freqReason,
      changed_by: userData?.user?.id ?? null,
      changed_by_email: email,
    }).select("id").maybeSingle();
    freqReasonRecorded = !fcErr;
    freqChangeId = fcRow?.id ?? null;
  }

  // ---- approval-proof images: storage LAST, and only if the change is on the record ----------
  // 🛑 THE ORDER IS THE DESIGN. Jobber is committed and verified, the job is written, and the change
  // row exists BEFORE a single byte reaches storage. That is why there is no staging path and no
  // orphan sweeper: an object cannot exist for a change that did not happen. The alternative — the
  // browser uploading first — would need an INSERT policy on a bucket deliberately left closed, and
  // would leak a file on every abandoned save.
  //
  // 🛑 A FAILURE HERE MUST NOT REPORT THE SAVE AS FAILED. Jobber already holds the new cadence and
  // cannot be rolled back; claiming failure would send someone to re-apply a change that already
  // happened. Same posture as frequency_reason_recorded above. The count comes back so the UI can
  // say the cadence saved while its proof did not, and the operator can re-attach it.
  let proofSaved = 0;
  const proofErrors: string[] = [];
  if (proofIn.length && freqChangeId) {
    // employees.id, not the auth uid: photos.uploaded_by_employee_id is an FK to employees. No match
    // means NULL rather than a failed upload — attribution is not worth losing the evidence over, and
    // audit.logs records the real actor via jwt_claims->>'email' regardless.
    const { data: emp } = await db.from("employees").select("id").ilike("email", email).limit(1).maybeSingle();
    for (const img of proofIn) {
      try {
        const bytes = Uint8Array.from(atob(img.data_base64), (c) => c.charCodeAt(0));
        const ext = img.content_type === "image/png" ? "png" : "jpg";
        const path = `client-app/job-frequency/${jobId}/${crypto.randomUUID()}.${ext}`;
        const up = await db.storage.from("approval-proof")
          .upload(path, bytes, { contentType: img.content_type, upsert: false });
        if (up.error) { proofErrors.push(up.error.message); continue; }

        const { data: photo, error: pErr } = await db.from("photos").insert({
          storage_path: path,
          file_name: img.file_name,
          content_type: img.content_type,
          size_bytes: bytes.byteLength,
          uploaded_by_employee_id: emp?.id ?? null,
          source: "client_app_upload",
        }).select("id").single();
        if (pErr) { proofErrors.push(pErr.message); continue; }

        const { error: lErr } = await db.from("photo_links").insert({
          photo_id: photo.id,
          entity_type: "job_frequency_change",
          entity_id: freqChangeId,
          role: "approval_proof",
        });
        if (lErr) { proofErrors.push(lErr.message); continue; }
        proofSaved++;
      } catch (e) {
        proofErrors.push(e instanceof Error ? e.message : String(e));
      }
    }
  }
  // `preserved` is returned so the UI can say what it did NOT touch — a silent
  // "saved" is what let the fee-line deletion go unnoticed for a month.
  // `preserved` is returned so the UI can say what it did NOT touch. `fee_lines` is
  // returned so the dialog can show the amount a percent-mode fee actually resolved to —
  // the server computes it, so the client must be told rather than left to guess.
  return done({
    job_id: jobId,
    applied,
    preserved_line_items: preserved,
    fee_lines: feeLinesForVerify.map((l) => ({ name: l.name, unit_price: l.unitPrice, quantity: l.quantity })),
    // The app runs client.generate_visits_for_client when this is true. See the block
    // where it is computed for why our mirror is the right source for it.
    start_date_first_set: startDateFirstSet,
    frequency_reason_recorded: freqReasonRecorded,
    // How many proof images actually landed. Reported rather than thrown: see the block above for
    // why a storage failure cannot be allowed to look like a failed save.
    frequency_proof_saved: proofSaved,
    frequency_proof_attempted: proofIn.length,
    frequency_proof_error: proofErrors.length ? proofErrors.join("; ").slice(0, 300) : null,
  });
});
