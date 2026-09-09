// ============================================================================
// sync-jobber-invoice-drift — the invoice reconcile (2026-09-09)
// ============================================================================
// Fred: "you would need a plan for a good link between our DB invoice data to the Jobber invoice.
// So we don't get dupes, we stay syncd (cron job), and if i need to double check with Jobber is
// simple." This is the "stay syncd" half.
//
// 🛑 WHY THE */5 POLL DOES NOT ALREADY DO THIS. The poll pulls invoices with
//    `filter:{updatedAt:{after: <cursor>}}` and advances `sync_cursors.invoices`. **A cursor poll
//    can never revisit a row it has already passed.** Once the cursor moves beyond an invoice's
//    updatedAt, that invoice is never looked at again, so if our copy was wrong at that moment it
//    stays wrong for ever. Measured 2026-09-09: Davinci #2320 and Tower 41 #2333 had been claiming
//    $863.44 since April while Jobber recorded both as paid. Nothing in the system could have found
//    them. Jobs and visits already have a drift reconciler for exactly this reason; invoices did not.
//
// 🛑 AND WHY THIS READS JOBBER RATHER THAN raw.jobber_pull_invoices, WHICH LOOKS FREE.
//    raw already holds a Jobber payload for every linked invoice, so comparing raw against live
//    costs no API budget at all. **It is wrong.** raw is a STAGING BUFFER, not a mirror: a DESTROY
//    never restages, because the poll cannot pull an object that no longer exists, so raw stays
//    frozen at the last successful pull. Measured on the same 5 divergent rows: on 3 of them OUR
//    row was correct (`destroyed`) and raw held a stale pre-deletion snapshot saying past_due /
//    draft / awaiting_payment. A raw-based reconciler would have RESURRECTED three deleted invoices
//    and added $361.32 of phantom receivable. **The divergence runs both ways and only Jobber can
//    say which way.**
//
// DIRECTION: Jobber -> DB only. Jobber is the billing master (workspace rule 4). This function
// contains no mutations and can never write to Jobber.
//
// ⚠ BILLING SETTINGS ARE OUT OF SCOPE by Fred's explicit instruction: `jobs.billing_type`,
//   `jobs.invoice_frequency`, `jobs.invoice_rrule` are never read or written here. This adopts
//   invoice ROW data only: status, total, balance, deposit, issued/due dates.
//
// ⚠ LINE ITEMS ARE ALSO OUT OF SCOPE, deliberately. handleInvoice already wipes-and-replaces them
//   on every replay, and pulling lineItems here would multiply the query cost several-fold for a
//   field that is not what goes wrong. If invoice line items ever need reconciling, price it first.
//
// ============================================================================
// SCOPE: NON-TERMINAL INVOICES ONLY, AND THAT IS A DECISION, NOT AN OVERSIGHT
//
// Candidates are invoices whose status is NOT one of paid / bad_debt / destroyed.
// Measured 2026-09-09: awaiting_payment 134, past_due 39, draft 7 = **180 rows**, against 2,390
// paid. Those 180 are the entire money-at-risk set: an invoice we wrongly believe is OPEN is one we
// chase a customer for.
//
// ⚠ THE KNOWN GAP: an invoice we believe is PAID that Jobber later reopens is not checked. That is
//   the cheaper error (we under-claim rather than over-claim) and the far rarer event, and covering
//   it would mean sweeping 2,390 rows. If that becomes real, add a rotating slice of paid invoices
//   rather than widening this predicate wholesale, and re-price it first.
//
// COST, measured against live Jobber before shipping (never estimated):
//   25 aliased invoice reads in ONE request  ->  requestedQueryCost 275, actualQueryCost 275
//   so ~11 per invoice, and a full 180-row sweep is ~1,980 of a 10,000 bucket restoring 500/s.
// ⚠ requested == actual here, unlike the property sweep where actual exceeded requested by 53%.
//   Re-price if you add a field: `extensions.cost` is on every response.
//
// ⚠ `invoices(filter:{ids:[...]})` DOES NOT EXIST — Jobber rejects it with
//   "InputObject 'InvoiceFilterAttributes' doesn't accept argument 'ids'". That is why this batches
//   with GraphQL ALIASES (a0:, a1:, ...) rather than the ids filter the job reconciler uses.
//
// AUTH: verify_jwt=true at the gateway + role=service_role in the handler (the anon key also
// passes verify_jwt). Never deploy --no-verify-jwt.
// ============================================================================

import { createClient } from "jsr:@supabase/supabase-js@2";

const GQL_VERSION = "2026-04-16";
const BATCH = 25;                       // 275 cost/request, measured
const BATCH_PAUSE_MS = 250;
const MAX_CONSECUTIVE_BATCH_FAILURES = 3;
const THROTTLE_FLOOR = 3500;            // leave headroom for whatever pulls next
const TERMINAL = ["paid", "bad_debt", "destroyed"];

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// x-app-source 'jobber': these writes ADOPT Jobber's state, the same attribution the visit and job
// drift adopt paths use (ADR 016).
const db = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
  global: { headers: { "x-app-source": "jobber" } },
});

function bearerRole(req: Request): string | null {
  const m = (req.headers.get("authorization") || "").match(/^Bearer (.+)$/);
  if (!m) return null;
  try { return JSON.parse(atob(m[1].split(".")[1])).role ?? null; } catch { return null; }
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function jobberToken(): Promise<string> {
  const { data, error } = await db.from("webhook_tokens").select("access_token")
    .eq("source_system", "jobber").maybeSingle();
  if (error || !data?.access_token) throw new Error(`no jobber token: ${error?.message ?? "missing"}`);
  return data.access_token as string;
}

let throttleAvailable = Number.POSITIVE_INFINITY;

/**
 * One GraphQL round trip.
 *
 * 🛑 THE THREE GUARDS HERE ARE THE WHOLE SAFETY ARGUMENT, because the caller's "Jobber returned
 *    null for this invoice" branch MARKS IT DESTROYED. A missing answer coerced into a neutral one
 *    is how this estate has previously soft-deleted 756 live visits.
 *      1. content-type: Jobber sheds load with an HTML "Waiting Room" page at HTTP 200.
 *      2. a `data` key must be present: a throttle or error payload parses cleanly and then reads
 *         as "no rows".
 *      3. any `errors` array is fatal for the batch.
 *    Each one THROWS. Nothing downstream is allowed to see an absence it cannot distinguish from
 *    an answer.
 */
async function gql(token: string, query: string): Promise<Record<string, unknown>> {
  const r = await fetch("https://api.getjobber.com/api/graphql", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      "X-JOBBER-GRAPHQL-VERSION": GQL_VERSION,
    },
    body: JSON.stringify({ query }),
  });

  const ctype = r.headers.get("content-type") ?? "";
  if (!ctype.includes("json")) {
    throw new Error(`jobber returned ${ctype || "no content-type"} at HTTP ${r.status} (waiting room?)`);
  }
  const j = await r.json();
  if (Array.isArray(j?.errors) && j.errors.length) {
    throw new Error(`jobber graphql error: ${JSON.stringify(j.errors[0]?.message ?? j.errors[0])}`);
  }
  if (!j || typeof j !== "object" || !("data" in j) || j.data == null) {
    throw new Error("jobber reply carried no data key");
  }

  const t = j?.extensions?.cost?.throttleStatus;
  if (t?.currentlyAvailable != null) throttleAvailable = Number(t.currentlyAvailable);

  return j.data as Record<string, unknown>;
}

/** Pace against the leaky bucket rather than discovering the ceiling as an error. */
async function payThrottle() {
  if (!Number.isFinite(throttleAvailable) || throttleAvailable >= THROTTLE_FLOOR) return;
  const need = THROTTLE_FLOOR - throttleAvailable;
  await sleep(Math.min(10_000, Math.ceil((need / 500) * 1000)));
}

const num = (x: unknown) => (x === null || x === undefined ? null : Number(x));

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { status: 200 });
  if (bearerRole(req) !== "service_role") {
    return new Response(JSON.stringify({ error: "service_role required" }), { status: 401 });
  }

  const startedAt = new Date().toISOString();
  const t0 = Date.now();
  const stats = {
    candidates: 0, checked: 0, adopted: 0, destroyed: 0,
    unchanged: 0, batches_ok: 0, batches_failed: 0,
  };
  const changes: Record<string, unknown>[] = [];
  const errors: string[] = [];

  try {
    const token = await jobberToken();

    // ---- candidates -------------------------------------------------------------------------
    // Oldest-checked first, so a capped run ROTATES rather than starving its tail. That defect is
    // documented in the poll's replay loop and is easy to reproduce accidentally.
    const { data: rows, error: qErr } = await db
      .from("invoices")
      .select("id, invoice_status, total, outstanding_amount, deposit_amount, updated_at")
      .not("invoice_status", "in", `(${TERMINAL.join(",")})`)
      .order("updated_at", { ascending: true })
      .limit(400);
    if (qErr) throw new Error(`candidate query failed: ${qErr.message}`);

    const ours = rows ?? [];
    stats.candidates = ours.length;

    // resolve each to its Jobber GID; an invoice with no link cannot exist since 2026-09-09_1140,
    // but read it rather than assuming.
    const { data: links, error: lErr } = await db
      .from("entity_source_links")
      .select("entity_id, source_id")
      .eq("entity_type", "invoice").eq("source_system", "jobber")
      .in("entity_id", ours.map((r) => r.id));
    if (lErr) throw new Error(`link query failed: ${lErr.message}`);

    const gidOf = new Map<number, string>();
    for (const l of links ?? []) gidOf.set(Number(l.entity_id), String(l.source_id));

    const work = ours.filter((r) => gidOf.has(Number(r.id)));
    if (work.length !== ours.length) {
      errors.push(`${ours.length - work.length} candidate(s) had no Jobber link and were skipped`);
    }

    let consecutiveFailures = 0;

    for (let i = 0; i < work.length; i += BATCH) {
      const slice = work.slice(i, i + BATCH);
      const query = `query { ${slice.map((r, n) =>
        `a${n}: invoice(id: "${gidOf.get(Number(r.id))}") { id invoiceNumber invoiceStatus issuedDate dueDate amounts { total invoiceBalance depositAmount } }`
      ).join(" ")} }`;

      let data: Record<string, unknown>;
      try {
        await payThrottle();
        data = await gql(token, query);
        consecutiveFailures = 0;
        stats.batches_ok++;
      } catch (e) {
        stats.batches_failed++;
        consecutiveFailures++;
        errors.push(`batch @${i}: ${String((e as Error).message).slice(0, 200)}`);
        // 🛑 Stop a sweep that cannot reach Jobber at all rather than walking the fleet retrying.
        if (consecutiveFailures >= MAX_CONSECUTIVE_BATCH_FAILURES) {
          errors.push(`circuit breaker: ${consecutiveFailures} consecutive batch failures, aborting`);
          break;
        }
        continue;   // this batch's invoices are simply not checked this run
      }

      for (let n = 0; n < slice.length; n++) {
        const mine = slice[n];
        const theirs = data[`a${n}`] as Record<string, any> | null | undefined;
        stats.checked++;

        // ---- Jobber says this invoice no longer exists ------------------------------------
        // Reachable ONLY because gql() threw on every shape that could mean "no answer": a
        // non-JSON body, an errors array, or a missing data key. So a null here is Jobber
        // affirmatively saying the object is gone.
        if (theirs === null) {
          if (mine.invoice_status !== "destroyed") {
            const { error } = await db.from("invoices")
              .update({ invoice_status: "destroyed", outstanding_amount: 0 })
              .eq("id", mine.id);
            if (error) { errors.push(`invoice ${mine.id} destroy-mark failed: ${error.message}`); continue; }
            stats.destroyed++;
            changes.push({ id: mine.id, change: "destroyed", was: mine.invoice_status });
          } else {
            stats.unchanged++;
          }
          continue;
        }
        if (theirs === undefined) {   // alias absent entirely: treat as not-checked, never as gone
          errors.push(`invoice ${mine.id}: alias a${n} missing from the reply`);
          continue;
        }

        // ---- compare, and write only on a real difference ----------------------------------
        const jStatus  = String(theirs.invoiceStatus ?? "").toLowerCase() || null;
        const jTotal   = num(theirs.amounts?.total);
        const jBalance = num(theirs.amounts?.invoiceBalance);
        const jDeposit = num(theirs.amounts?.depositAmount);

        const patch: Record<string, unknown> = {};
        if (jStatus && jStatus !== mine.invoice_status) patch.invoice_status = jStatus;
        if (jTotal   !== null && jTotal   !== num(mine.total))              patch.total = jTotal;
        if (jBalance !== null && jBalance !== num(mine.outstanding_amount)) patch.outstanding_amount = jBalance;
        if (jDeposit !== null && jDeposit !== num(mine.deposit_amount))     patch.deposit_amount = jDeposit;
        if (theirs.issuedDate) patch.sent_at = theirs.issuedDate;
        if (theirs.dueDate)    patch.due_date = theirs.dueDate;

        // dates are echoed on every row; only count a change when a MONEY or STATUS field moved
        const material = ["invoice_status", "total", "outstanding_amount", "deposit_amount"]
          .some((k) => k in patch);
        if (!material) { stats.unchanged++; continue; }

        const { error } = await db.from("invoices").update(patch).eq("id", mine.id);
        if (error) { errors.push(`invoice ${mine.id} update failed: ${error.message}`); continue; }
        stats.adopted++;
        changes.push({
          id: mine.id, number: theirs.invoiceNumber,
          from: { status: mine.invoice_status, total: num(mine.total), balance: num(mine.outstanding_amount) },
          to:   { status: jStatus, total: jTotal, balance: jBalance },
        });
      }

      if (i + BATCH < work.length) await sleep(BATCH_PAUSE_MS);
    }
  } catch (e) {
    errors.push(`run failed: ${String((e as Error).message).slice(0, 300)}`);
  }

  // 🛑 ALWAYS write the sync_log row, on every path. pg_cron reports `succeeded` for the HTTP
  //    request regardless of what happened inside, so this row is the only observability there is.
  const status = errors.length === 0 ? "success"
               : stats.checked > 0   ? "partial"
               : "error";
  await db.from("sync_log").insert({
    sync_source: "jobber-invoice-drift",
    status,
    started_at: startedAt,
    finished_at: new Date().toISOString(),
    details: {
      ...stats,
      duration_s: Math.round((Date.now() - t0) / 1000),
      throttle_left: Number.isFinite(throttleAvailable) ? throttleAvailable : null,
      changes: changes.slice(0, 50),
      ...(errors.length ? { errors: errors.slice(0, 20) } : {}),
    },
  });

  return new Response(JSON.stringify({ status, ...stats, errors: errors.slice(0, 5) }), {
    status: 200, headers: { "Content-Type": "application/json" },
  });
});
