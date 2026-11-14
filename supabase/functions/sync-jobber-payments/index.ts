// ============================================================================
// sync-jobber-payments — the timed net under the payment and payout webhooks (2026-11-14)
// ============================================================================
// Fred, 2026-11-14: "remember to have link a sync data to keep the data up to the date ... see if there is a way to
// have a good way to have that realtime, like with the webhook but if we need to have cronjob then decide the
// frequency of fetching that data". Real time is webhook-jobber's PAYMENT_* / PAYOUT_* handlers; this is the net for
// what a webhook misses (an event Jobber never sent, a handler that failed: webhooks are acknowledged first and never
// retried) and for the time before the topics are switched on in Jobber's Developer Center.
// Plan: Building Apps/Ops Portal/docs/specs/2026-11-13-jobber-payments-and-people.md, section C. Contract and the
// frequency decision: docs/reference/payments-copy.md.
//
// Two modes, Jobber -> DB only (this function contains no Jobber mutation):
//  - default, every 15 minutes: the 50 payment records Jobber changed last (sorted UPDATED_AT, newest first: a new
//    entry, a status change, an edit or a back-dated entry all surface there), every record ENTERED in the last
//    2 days (in case more than 50 changed at once, e.g. a batch of invoices), and every payout UPDATED in the last
//    2 days. No removals: none of these is a complete answer.
//  - ?mode=window[&days=35]: every record ENTERED in the window, complete or nothing. Held payments of the window that
//    Jobber did not return are re-read BY ID: a node is written (its entry date moved), a null is a removal
//    (deleted_at). public.fn_jobber_payments_unseen refuses an empty answer and a mass removal before any re-read.
//    Plus every payout updated in the window. Nightly.
// Payments filter by entry date only (no updatedAt filter), so a cursor cannot work for them; payouts filter by
// updatedAt, and a fixed 2-day look-back over a 15-minute cadence needs no stored cursor.
//
// A payment held because its invoice or quote is not in our database yet: that invoice or quote is replayed through
// webhook-jobber (signed, x-sync-wait), at most 10 per run, and the payment is written again. Its refund's original
// or a payout's payment: read by id and written first.
//
// TOKEN: the read app's (webhook_tokens 'jobber'), read raw: sync-jobber-poll is the one keeper of its refresh.
// AUTH: verify_jwt=true at the gateway + role=service_role in the handler (the anon key also passes verify_jwt).
// ============================================================================

import { createClient } from "jsr:@supabase/supabase-js@2";
import { isSecretKeyCaller } from "../_shared/service-caller.ts";
import {
  MONEY_ADJUSTMENTS, PAY_API_VERSION, PAYMENT_FIELDS, PAYOUT_FIELDS, jobberNumber, writePayments, writePayouts,
} from "../_shared/jobber-payments.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const db = createClient(SUPABASE_URL, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false, autoRefreshToken: false },
  global: { headers: { "x-app-source": "jobber" } },
});
const rpc = (fn: string, args: Record<string, unknown>) => db.rpc(fn, args) as unknown as Promise<{ data: any; error: { message: string } | null }>;

const PAGE = 25;            // a page of payment records asks ~2,450 points; payouts 10 a page ask ~4,100
const MAX_PAGES = 120;      // 3,000 records: far above a 35-day window (~600), so hitting it means something is wrong
const FLOOR = 3500;         // the poll's floor: leave it headroom on the shared read-app bucket
const MAX_IMPORTS = 10;

function bearerRole(req: Request): string | null {
  if (isSecretKeyCaller(req)) return "service_role";
  const m = (req.headers.get("authorization") || "").match(/^Bearer (.+)$/);
  if (!m) return null;
  try { return JSON.parse(atob(m[1].split(".")[1])).role ?? null; } catch { return null; }
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
let available: number | null = null;

// Same guards as sync-jobber-timesheets: an HTML waiting room at HTTP 200 and a throttle are retried, an errors array
// (or the singular "error" of an inactive account) throws, a reply with no data key is a MISSING answer and throws.
async function gql(token: string, query: string, variables: Record<string, unknown> = {}, retry = 0): Promise<any> {
  if (available != null && available < FLOOR) await sleep(Math.min(20_000, Math.ceil(((FLOOR - available) / 500) * 1000)));
  const r = await fetch("https://api.getjobber.com/api/graphql", {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", "X-JOBBER-GRAPHQL-VERSION": PAY_API_VERSION },
    body: JSON.stringify({ query, variables }),
  });
  const ctype = r.headers.get("content-type") ?? "";
  if (!ctype.includes("json")) {
    if (retry < 5) { await sleep(Math.min(30_000, 1_000 * 2 ** retry)); return gql(token, query, variables, retry + 1); }
    throw new Error(`Jobber returned ${ctype || "no content-type"} at HTTP ${r.status} (busy/waiting room)`);
  }
  const j = await r.json().catch(() => null);
  const t = j?.extensions?.cost?.throttleStatus;
  if (typeof t?.currentlyAvailable === "number") available = t.currentlyAvailable;
  const throttled = r.status === 429 ||
    (Array.isArray(j?.errors) && j.errors.some((e: any) => e?.extensions?.code === "THROTTLED" || /throttl/i.test(e?.message || "")));
  if (throttled && retry < 5) { await sleep(Math.min(30_000, 2_000 * 2 ** retry)); return gql(token, query, variables, retry + 1); }
  if (j?.errors || j?.error) throw new Error(`GraphQL: ${JSON.stringify(j.errors ?? j.error).slice(0, 250)}`);
  if (j == null || typeof j !== "object" || !("data" in j) || j.data == null) throw new Error(`Jobber returned no data key at HTTP ${r.status}`);
  return j.data;
}

// Every page, or a throw: a partial read must never look like a complete one. firstPages: read only that many pages
// on purpose (the newest changes), never used where completeness matters.
async function listAll(token: string, field: string, args: string, vars: Record<string, unknown>, fields: string, size: number, firstPages = 0) {
  const out: any[] = [];
  let after: string | null = null;
  for (let page = 0; ; page++) {
    if (firstPages && page >= firstPages) return out;
    if (page >= MAX_PAGES) throw new Error(`${field}: more than ${MAX_PAGES} pages; refusing a partial read`);
    const data = await gql(token, `query($after: String${args ? ", " + args : ""}) { ${field}(first: ${size}, after: $after${vars.f !== undefined ? ", filter: $f" : ""}${vars.s !== undefined ? ", sort: $s" : ""}) { pageInfo { hasNextPage endCursor } nodes { ${fields} } } }`, { after, ...vars });
    const c = data[field];
    if (!c || !Array.isArray(c.nodes) || !c.pageInfo) throw new Error(`Jobber reply has no ${field} nodes/pageInfo`);
    out.push(...c.nodes);
    if (!c.pageInfo.hasNextPage) return out;
    after = c.pageInfo.endCursor;
  }
}

async function hmacB64(secret: string, payload: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(payload));
  return btoa(String.fromCharCode(...new Uint8Array(sig)));
}

async function run(windowMode: boolean, days: number, fromParam: string | null) {
  const started = new Date().toISOString();
  const stats: Record<string, any> = { mode: windowMode ? "window" : "recent", errors: 0, error_samples: [] as string[] };
  const fail = (msg: string) => {
    stats.errors++;
    if (stats.error_samples.length < 5) stats.error_samples.push(msg.slice(0, 300));
    console.error(`[payments] ${msg}`);
  };
  try {
    const { data: tok, error: tokErr } = await db.from("webhook_tokens").select("access_token, client_secret").eq("source_system", "jobber").single();
    if (tokErr || !tok?.access_token) throw new Error(`jobber read token read failed: ${tokErr?.message ?? "missing"}`);
    const token = tok.access_token as string;

    const readPayment = async (gid: string) =>
      (await gql(token, `query($id: EncodedId!) { paymentRecord(id: $id) { ${PAYMENT_FIELDS} } }`, { id: gid })).paymentRecord ?? null;
    let imports = 0;
    const importDep = async (kind: "invoice" | "quote", gid: string) => {
      if (imports >= MAX_IMPORTS) { stats.imports_capped = (stats.imports_capped ?? 0) + 1; return; }
      imports++;
      const payload = JSON.stringify({ topic: kind === "invoice" ? "INVOICE_UPDATE" : "QUOTE_UPDATE", webHookEvent: { itemId: gid, occurredAt: new Date().toISOString() } });
      const r = await fetch(`${SUPABASE_URL}/functions/v1/webhook-jobber`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "x-jobber-hmac-sha256": await hmacB64(tok.client_secret as string, payload), "x-sync-wait": "1" },
        body: payload,
      });
      if (!r.ok) throw new Error(`import of ${kind} ${jobberNumber(gid)} through webhook-jobber failed: HTTP ${r.status} ${(await r.text()).slice(0, 200)}`);
    };

    if (!windowMode) {
      const byUpdate = await listAll(token, "paymentRecords", "$s: PaymentRecordSortAttributes", { s: { key: "UPDATED_AT", direction: "DESCENDING" } }, PAYMENT_FIELDS, PAGE, 2);
      const since = new Date(Date.now() - 2 * 864e5).toISOString();
      const recent = await listAll(token, "paymentRecords", "$f: PaymentRecordFilterAttributes, $s: PaymentRecordSortAttributes",
        { f: { entryDate: { after: since } }, s: { key: "ENTRY_DATE", direction: "ASCENDING" } }, PAYMENT_FIELDS, PAGE);
      const byNum = new Map<string, any>();
      for (const n of [...byUpdate, ...recent]) byNum.set(jobberNumber(n.id) ?? n.id, n);
      stats.read = { by_update: byUpdate.length, entered_2_days: recent.length, distinct: byNum.size };
      stats.payments = await writePayments(rpc, [...byNum.values()], [], readPayment, importDep);
      const payouts = await listAll(token, "payoutRecords", "$f: PayoutFilterAttributes", { f: { updatedAt: { after: since } } }, PAYOUT_FIELDS, 10);
      stats.read.payouts = payouts.length;
      stats.payouts = await writePayouts(rpc, payouts, [], readPayment, importDep);
    } else {
      if (fromParam && !/^\d{4}-\d{2}-\d{2}$/.test(fromParam)) throw new Error("from must be YYYY-MM-DD");
      if (!fromParam && !(days > 0 && days <= 400)) throw new Error("days must be 1 to 400");
      const from = fromParam ? new Date(`${fromParam}T00:00:00-05:00`).toISOString() : new Date(Date.now() - days * 864e5).toISOString();
      const to = new Date(Date.now() + 864e5).toISOString();
      stats.window = { from, to };
      const all = await listAll(token, "paymentRecords", "$f: PaymentRecordFilterAttributes, $s: PaymentRecordSortAttributes",
        { f: { entryDate: { after: from, before: to } }, s: { key: "ENTRY_DATE", direction: "ASCENDING" } }, PAYMENT_FIELDS, PAGE);
      const money = all.filter((n) => MONEY_ADJUSTMENTS.includes(n.adjustmentType));
      stats.read = { records: all.length, money: money.length };
      stats.payments = await writePayments(rpc, all, [], readPayment, importDep);
      // Removals: only from a complete answer, only what a read by id confirms.
      const { data: u, error: uErr } = await db.rpc("fn_jobber_payments_unseen", { p_from: from, p_to: to, p_seen: money.map((n) => n.id) });
      if (uErr) throw new Error(`fn_jobber_payments_unseen refused: ${uErr.message}`);
      const unseen: string[] = u?.unseen ?? [];
      const found: any[] = [];
      const gone: string[] = [];
      for (const gid of unseen) {
        const n = await readPayment(gid);
        if (n) found.push(n); else gone.push(gid);
      }
      stats.unseen = { held_in_window: u?.held, unseen: unseen.length, moved: found.length, gone: gone.length };
      for (let i = 0; i < Math.max(gone.length, found.length ? 1 : 0); i += 20) {
        const w = await writePayments(rpc, i === 0 ? found : [], gone.slice(i, i + 20), readPayment, importDep);
        stats.unseen.removed = (stats.unseen.removed ?? 0) + (w.removed ?? 0);
      }
      const payouts = await listAll(token, "payoutRecords", "$f: PayoutFilterAttributes", { f: { updatedAt: { after: from } } }, PAYOUT_FIELDS, 10);
      stats.read.payouts = payouts.length;
      stats.payouts = await writePayouts(rpc, payouts, [], readPayment, importDep);
    }
    const stillHeld = (stats.payments?.held?.length ?? 0) + (stats.payouts?.held?.length ?? 0);
    if (stillHeld) fail(`${stillHeld} still held (waiting for a record not in our database): ${JSON.stringify([...(stats.payments?.held ?? []), ...(stats.payouts?.held ?? [])].slice(0, 3))}`);
  } catch (e) {
    fail(`run failed: ${e instanceof Error ? e.message : e}`);
  }
  stats.throttle_left = available;

  const p = stats.payments ?? {}, o = stats.payouts ?? {};
  const { error: logErr } = await db.from("sync_log").insert({
    sync_source: windowMode ? "jobber_payments_window" : "jobber_payments",
    started_at: started,
    finished_at: new Date().toISOString(),
    rows_inserted: (p.inserted ?? 0) + (o.inserted ?? 0),
    rows_updated: (p.updated ?? 0) + (o.updated ?? 0) + (stats.unseen?.removed ?? 0),
    rows_errored: stats.errors,
    status: stats.errors ? "partial" : "success",
    details: stats,
  });
  if (logErr) console.error(`[payments] sync_log insert failed: ${logErr.message}`);
  return { ok: !stats.errors, sync_log_error: logErr?.message ?? null, ...stats };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok");
  if (bearerRole(req) !== "service_role") {
    return new Response(JSON.stringify({ error: "service_role required" }), { status: 403 });
  }
  const url = new URL(req.url);
  const windowMode = url.searchParams.get("mode") === "window";
  const days = Number(url.searchParams.get("days") ?? 35);
  const from = url.searchParams.get("from");
  if (req.headers.get("x-sync-wait") === "1") {
    const res = await run(windowMode, days, from);
    return new Response(JSON.stringify(res), { status: res.ok ? 200 : 500, headers: { "Content-Type": "application/json" } });
  }
  // @ts-ignore EdgeRuntime is provided by the Supabase Edge runtime. pg_net gives up after ~5 s; the run continues.
  EdgeRuntime.waitUntil(run(windowMode, days, from));
  return new Response(JSON.stringify({ accepted: true }), { status: 202, headers: { "Content-Type": "application/json" } });
});

