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

// ---- Jobber queries/mutations ----------------------------------------------
const JOB_FIELDS = `id jobNumber title instructions jobStatus startAt endAt total
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
  const { data: cat } = await db.from("service_line_items").select("id, code, title, schedulable").in("id", ids);
  const byId = new Map((cat ?? []).map((c: any) => [c.id, c]));
  const lines: { name: string; unitPrice: number; quantity: number }[] = [];
  for (const s of services) {
    const c = byId.get(s.service_line_item_id);
    if (!c) return { err: `Service ${s.service_line_item_id} does not exist.` };
    if (!c.schedulable) return { err: `"${c.title}" is not a schedulable service.` };
    const price = Number(s.unit_price);
    if (!Number.isFinite(price) || price < 0) return { err: `"${c.title}" needs a valid price.` };
    // The name format is the taxonomy join key: `<code> - <title>` (measured live).
    lines.push({ name: `${c.code} - ${c.title}`, unitPrice: price, quantity: Number(s.quantity) > 0 ? Number(s.quantity) : 1 });
  }
  return { lines };
}

function jobToRecord(clientId: number, propertyId: number | null, j: any, includeLines: boolean, freq?: number | null) {
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

  // verify_jwt=true means the gateway verified the signature; the anon key would
  // also pass that, so require a real staff identity from the claims.
  try {
    const claims = JSON.parse(atob((req.headers.get("authorization") ?? "").split(" ")[1].split(".")[1]));
    const email = String(claims.email ?? "").toLowerCase();
    if (!claims.sub || (!email.endsWith("@ayache.com") && !email.endsWith("@unclogme.com"))) {
      return fail("forbidden", "Staff account required.");
    }
  } catch {
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
    const startDate = String(p.start_date ?? "");
    if (!/^\d{4}-\d{2}-\d{2}$/.test(startDate)) return fail("bad_request", "A start date is required.");

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
      // Behaviour-class title: 'Service Agreement%' prefix is load-bearing. Derive
      // from the first service; catalog titles already start 'Service Agreement - …'.
      const first = lines[0].name.replace(/^\d+\s*-\s*/, "");
      title = first.startsWith("Service Agreement") ? first : `Service Agreement - ${first}`;
    } else {
      // Exact string: ops.client_service_options matches lower(btrim(title))='service call'.
      title = "Service Call";
    }

    const input: Record<string, unknown> = {
      propertyId: propGid,
      title,
      invoicing: p.billing === "fixed"
        ? { invoicingType: "FIXED_PRICE", invoicingSchedule: "ON_COMPLETION" }
        : { invoicingType: "VISIT_BASED", invoicingSchedule: "PER_VISIT" },
      timeframe: { startAt: startDate },
      // NO `scheduling` — ever. See header.
    };
    const instructions = typeof p.instructions === "string" && p.instructions.trim() ? p.instructions.trim() : null;
    if (instructions) input.instructions = instructions;
    if (p.end_date && /^\d{4}-\d{2}-\d{2}$/.test(p.end_date)) {
      const days = Math.round((Date.parse(p.end_date) - Date.parse(startDate)) / 86_400_000);
      if (days > 0) (input as any).timeframe = { startAt: startDate, durationUnits: "DAYS", durationValue: days };
    }
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
    if (job.title !== title || job.property?.id !== propGid || etDate(job.startAt) !== startDate ||
        (lines.length && (job.lineItems?.nodes ?? []).length !== lines.length)) {
      return fail("verify_failed",
        "Jobber created the job but it doesn't match what was sent — check it in Jobber before retrying.",
        { jobber_number: job.jobNumber });
    }

    const { data: rec, error: recErr } = await db.rpc("fn_record_client_job",
      { p: jobToRecord(clientId, propertyId, job, kind === "SA", kind === "SA" ? freq : 0) });
    if (recErr) {
      // The one honest window: Jobber has the job, our DB write failed. The next
      // */5 poll imports it (createdAt cursor) — say so, do not pretend failure.
      return fail("db_write_failed",
        `The job WAS created in Jobber (#${job.jobNumber}) but saving it locally failed; it will appear here within ~5 minutes via the sync.`,
        { jobber_number: job.jobNumber });
    }
    return done({ job_id: rec.job_id, job_number: job.jobNumber, job_status: String(job.jobStatus).toLowerCase() });
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
  if (p.services !== undefined) {
    if (!isSA) return fail("bad_request", "Only Service Agreements carry service line items.");
    const r = await resolveServices(p.services ?? []);
    if (r.err) return fail("bad_request", r.err);
    wantLines = r.lines!;
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
    applied.push(...Object.keys(edit).map((k) => (k === "customFields" ? "frequency" : k === "timeframe" ? "dates" : k)));
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
    const toDelete = curLines.filter((n) => !wantByName.has(n.name));
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
  if (wantLines !== null) {
    const names = new Set((j.lineItems?.nodes ?? []).map((n: any) => n.name));
    for (const l of wantLines) {
      if (!names.has(l.name)) return fail("verify_failed", `Line item "${l.name}" did not land in Jobber — check Jobber.`, { applied });
    }
  }

  // 4. only now, our DB — from the READ-BACK, not from the patch
  const rec = jobToRecord(clientId, jobRow.property_id, j, isSA && wantLines !== null, newFreq);
  const { error: recErr } = await db.rpc("fn_record_client_job", { p: rec });
  if (recErr) {
    return fail("db_write_failed", "Saved and verified in Jobber but the local write failed; the 30-minute sync will settle it.", { applied });
  }
  return done({ job_id: jobId, applied });
});
